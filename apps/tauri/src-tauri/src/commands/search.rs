//! Search everything's side here (the Mac's `AppModel.searchDocuments` and `SearchCenter`): gathers what only this side
//! holds as documents with passages (every message of every conversation with Nook, the transcripts of agent sessions,
//! every chat app's messages, call notes and memories), searches them (`nook_core::search`), and runs Search with AI
//! (`SearchAI`): the brain plans the searches and answers from what they found. The interface adds the actions,
//! Settings pages and the filters, and draws the panel (`CommandPalette.svelte`).

use std::sync::Mutex;
use std::time::{Duration, Instant};

use nook_core::agents::transcript::{self, ChatKind};
use nook_core::search::{self, Document, Hit, Passage, Request, Source};
use tauri::{AppHandle, Manager};

use crate::agents::AgentsState;
use crate::brain::BrainState;
use crate::services::Services;
use crate::state::AppState;

type Res<T> = Result<T, String>;

/// The documents, kept for a few seconds: a search per keystroke does not gather and fold everything again.
static CACHE: Mutex<Option<(Instant, std::sync::Arc<Vec<Document>>)>> = Mutex::new(None);
const FRESH: Duration = Duration::from_secs(8);
/// The earlier sessions whose transcripts are read, newest first (each is cached by `transcript::recent`).
const PAST_SESSIONS: usize = 150;
const RUNS: usize = 100;

fn app_name(app: &str) -> String {
    match app {
        "whatsapp" => "WhatsApp".into(),
        "telegram" => "Telegram".into(),
        "signal" => "Signal".into(),
        "messenger" => "Messenger".into(),
        "instagram" => "Instagram".into(),
        "x" | "twitter" => "X".into(),
        "linkedin" => "LinkedIn".into(),
        "slack" => "Slack".into(),
        "teams" => "Teams".into(),
        "messages" | "imessage" => "Messages".into(),
        other => {
            let mut c = other.chars();
            c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
        }
    }
}

fn agent_passages(path: &str, agent: &str) -> Vec<Passage> {
    if path.is_empty() {
        return vec![];
    }
    transcript::recent(path, transcript::FULL_LIMIT)
        .into_iter()
        .filter(|m| m.kind != ChatKind::Thinking && !m.text.trim().is_empty())
        .map(|m| Passage::new(m.text, if m.kind == ChatKind::User { "me" } else { agent }, None, Some(m.id)))
        .collect()
}

fn gather(app: &AppHandle) -> Vec<Document> {
    let mut docs = Vec::new();

    // Conversations with Nook, every message.
    app.state::<AppState>().with_chat(|chat| {
        for c in chat.conversations.iter().filter(|c| !c.messages.is_empty()) {
            let mut flags = vec![];
            if c.pinned {
                flags.push("pinned".to_string());
            }
            if c.archived {
                flags.push("archived".to_string());
            }
            if c.unread {
                flags.push("unread".to_string());
            }
            docs.push(Document {
                id: format!("conversation:{}", c.id),
                kind: "conversation".into(),
                title: c.title.clone(),
                subtitle: c.preview(),
                date: Some(c.updated),
                flags,
                boost: if c.pinned { 0.4 } else { 0.0 },
                passages: c
                    .messages
                    .iter()
                    .filter(|m| !m.text.trim().is_empty() && !m.is_error)
                    .map(|m| Passage::new(m.text.clone(), if m.from_user { "me" } else { "nook" }, Some(m.date), Some(m.id.clone())))
                    .collect(),
                ..Default::default()
            });
        }
    });

    // Agent sessions: the ones Nook runs, the ones it follows, and every earlier one, with their transcripts.
    let mut seen = std::collections::HashSet::new();
    if let Some(ws) = app.try_state::<crate::workspace::WorkspaceState>() {
        let mut runs = ws.manager.runs();
        runs.sort_by_key(|r| std::cmp::Reverse(r.updated_at));
        for run in runs.into_iter().take(RUNS) {
            if let Some(s) = &run.provider_session_id {
                seen.insert(s.clone());
            }
            let agent = run.provider.display_name().to_string();
            let mut passages = vec![Passage::new(run.task.clone(), "me", Some(run.created_at), None)];
            passages.extend(ws.manager.timeline(run.id).into_iter().filter_map(|e| {
                use nook_core::workspace::models::EventKind;
                let author = match e.kind {
                    EventKind::User => "me",
                    EventKind::Assistant | EventKind::Result => agent.as_str(),
                    _ => return None,
                };
                (!e.text.trim().is_empty()).then(|| Passage::new(e.text, author, Some(e.date), Some(e.id.to_string())))
            }));
            let project = run.project_name();
            use nook_core::workspace::models::RunStatus;
            let mut flags = Vec::new();
            if run.status.is_active() {
                flags.push("running".to_string());
            }
            match run.status {
                RunStatus::WaitingApproval => flags.push("waiting".to_string()),
                RunStatus::Failed => flags.push("failed".to_string()),
                RunStatus::Completed => flags.push("done".to_string()),
                _ => {}
            }
            if run.archived {
                flags.push("archived".to_string());
                flags.push("settled".to_string());
            }
            docs.push(Document {
                id: format!("run:{}", run.id),
                kind: "session".into(),
                title: run.title.clone(),
                subtitle: [agent.as_str(), project.as_str(), run.branch.as_deref().unwrap_or("")].iter().filter(|s| !s.is_empty()).cloned().collect::<Vec<_>>().join(" · "),
                date: Some(run.updated_at),
                flags,
                facets: [("agent".to_string(), agent.clone()), ("project".to_string(), project.clone())]
                    .into_iter()
                    .chain(run.branch.clone().map(|b| ("branch".to_string(), b)))
                    .collect(),
                boost: if run.status.is_active() { 0.3 } else { 0.0 },
                passages,
            });
        }
    }
    let agents = app.state::<AgentsState>();
    for s in agents.hub.sessions().into_iter().filter(|s| !s.id.starts_with("run:") && !s.transcript_path.is_empty()) {
        if !s.session_id.is_empty() {
            seen.insert(s.session_id.clone());
        }
        let mut passages = agent_passages(&s.transcript_path, &s.name);
        if passages.is_empty() {
            passages = [(&s.last_prompt, "me"), (&s.last_reply, s.name.as_str())]
                .into_iter()
                .filter(|(t, _)| !t.is_empty())
                .map(|(t, a)| Passage::new(t.clone(), a, s.updated, None))
                .collect();
        }
        use nook_core::agents::models::AgentStatus;
        let mut flags = Vec::new();
        match s.status {
            AgentStatus::Running => flags.push("running".to_string()),
            AgentStatus::Waiting => flags.push("waiting".to_string()),
            AgentStatus::Failed => flags.push("failed".to_string()),
            AgentStatus::Done => flags.push("done".to_string()),
            AgentStatus::Detected => {}
        }
        docs.push(Document {
            id: s.id.clone(),
            kind: "session".into(),
            title: if s.summary.is_empty() { s.project.clone() } else { s.summary.clone() },
            subtitle: format!("{} · {}", s.name, s.project),
            date: s.updated.or(s.started),
            flags,
            facets: [("agent".to_string(), s.name.clone()), ("project".to_string(), s.project.clone())].into_iter().collect(),
            boost: if s.status == AgentStatus::Running { 0.3 } else { 0.0 },
            passages,
        });
    }
    let past = crate::agents::lock(&agents.last_history).sessions.clone();
    for p in past.into_iter().filter(|p| !seen.contains(&p.session_id)).take(PAST_SESSIONS) {
        let kind = serde_json::to_value(p.agent).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default();
        let agent = p.agent.name().to_string();
        let project = std::path::Path::new(&p.cwd).file_name().map(|f| f.to_string_lossy().to_string()).unwrap_or_default();
        let mut facets: std::collections::BTreeMap<String, String> =
            [("agent".to_string(), format!("{agent} {}", p.model).trim().to_string()), ("project".to_string(), project.clone())].into_iter().collect();
        if !p.branch.is_empty() {
            facets.insert("branch".into(), p.branch.clone());
        }
        let mut passages = agent_passages(&p.path, &agent);
        if passages.is_empty() {
            passages = [(&p.last_prompt, "me"), (&p.last_reply, agent.as_str())]
                .into_iter()
                .filter(|(t, _)| !t.is_empty())
                .map(|(t, a)| Passage::new(t.clone(), a, Some(p.ended), None))
                .collect();
        }
        docs.push(Document {
            id: format!("past:{kind}:{}", p.session_id),
            kind: "session".into(),
            title: p.title.clone(),
            subtitle: [agent.as_str(), project.as_str(), p.branch.as_str()].iter().filter(|s| !s.is_empty()).cloned().collect::<Vec<_>>().join(" · "),
            date: Some(p.ended),
            flags: vec!["done".into(), "settled".into()],
            facets,
            passages,
            ..Default::default()
        });
    }

    // Every chat app's chats, the same way for each (WhatsApp, Telegram, Signal, Slack…).
    if let Some(connectors) = app.try_state::<crate::connectors::Connectors>() {
        connectors.env.chats.read(|inbox| {
            for t in inbox.threads.values() {
                let app_title = app_name(&t.app);
                let mut flags = vec![];
                if t.unread > 0 {
                    flags.push("unread".to_string());
                }
                if t.is_group() {
                    flags.push("group".to_string());
                }
                let mut facets: std::collections::BTreeMap<String, String> = [("app".to_string(), app_title.clone())].into_iter().collect();
                if let Some(members) = t.members.as_ref().filter(|m| !m.is_empty()) {
                    facets.insert("people".into(), members.join(" "));
                }
                docs.push(Document {
                    id: format!("chat:{}:{}", t.app, t.id),
                    kind: "chat".into(),
                    title: t.name.clone(),
                    subtitle: t.account.as_ref().map_or(app_title.clone(), |a| format!("{app_title} · {a}")),
                    date: Some(t.last()),
                    flags,
                    facets,
                    boost: if t.unread > 0 { 0.3 } else { 0.0 },
                    passages: t
                        .messages
                        .iter()
                        .filter(|m| !m.deleted && !m.text.trim().is_empty())
                        .map(|m| {
                            let author = if m.from_me { "me".to_string() } else if m.sender.is_empty() { t.name.clone() } else { m.sender.clone() };
                            Passage::new(m.text.clone(), author, Some(m.date), Some(m.id.clone()))
                        })
                        .collect(),
                });
            }
        });
    }

    // Call notes: the summary, key points, to-dos and every line, by who said it.
    if let Some(services) = app.try_state::<Services>() {
        let notes = services.notes.lock().unwrap_or_else(|e| e.into_inner());
        for note in &notes.notes {
            let names: std::collections::HashMap<&str, String> =
                note.speakers.iter().map(|s| (s.id.as_str(), if s.is_me { "me".to_string() } else { s.name.clone() })).collect();
            let mut passages = vec![];
            if let Some(summary) = note.summary.as_ref().filter(|s| !s.is_empty()) {
                passages.push(Passage::new(summary.clone(), "", Some(note.start), None));
            }
            passages.extend(note.key_points.iter().map(|k| Passage::new(k.clone(), "", Some(note.start), None)));
            passages.extend(note.todos.iter().map(|t| Passage::new(t.text.clone(), t.owner.clone().unwrap_or_default(), Some(note.start), None)));
            passages.extend(note.lines.iter().map(|l| {
                let date = note.start + chrono::Duration::milliseconds((l.start * 1000.0) as i64);
                Passage::new(l.text.clone(), names.get(l.speaker.as_str()).cloned().unwrap_or_else(|| l.speaker.clone()), Some(date), Some(l.id.clone()))
            }));
            let speakers = note.speakers.iter().filter(|s| !s.is_me).map(|s| s.name.clone()).collect::<Vec<_>>().join(" ");
            let mut facets: std::collections::BTreeMap<String, String> = [("speaker".to_string(), speakers.clone())].into_iter().collect();
            if let Some(app) = &note.app {
                facets.insert("app".into(), app.clone());
            }
            docs.push(Document {
                id: format!("note:{}", note.id),
                kind: "note".into(),
                title: note.title.clone(),
                subtitle: [note.app.clone().unwrap_or_default(), speakers].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" · "),
                date: Some(note.end.unwrap_or(note.start)),
                flags: vec![serde_json::to_value(note.status).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default()],
                facets,
                passages,
                ..Default::default()
            });
        }
    }

    // Memories, by what they say and who they are about.
    if let Some(brain) = app.try_state::<BrainState>() {
        for item in brain.memory.items() {
            let kind = serde_json::to_value(item.kind).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default();
            let mut flags = vec![kind.clone()];
            if item.pinned {
                flags.push("pinned".into());
            }
            if item.local_only {
                flags.push("local".into());
            }
            docs.push(Document {
                id: format!("memory:{}", item.id),
                kind: "memory".into(),
                title: item.text.clone(),
                subtitle: item.subject.clone(),
                date: Some(item.updated),
                flags,
                facets: [("type".to_string(), kind)].into_iter().collect(),
                boost: if item.pinned { 0.2 } else { 0.0 },
                passages: vec![],
            });
        }
    }
    docs
}

fn documents(app: &AppHandle) -> std::sync::Arc<Vec<Document>> {
    {
        let cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((at, docs)) = cache.as_ref() {
            if at.elapsed() < FRESH {
                return docs.clone();
            }
        }
    }
    let docs = std::sync::Arc::new(gather(app));
    *CACHE.lock().unwrap_or_else(|e| e.into_inner()) = Some((Instant::now(), docs.clone()));
    docs
}

/// The documents that hold what is typed, with the passage that matched. Runs off the main thread: the first search
/// reads the transcripts.
#[tauri::command]
pub async fn search_everything(app: AppHandle, request: Request) -> Res<Vec<Hit>> {
    tauri::async_runtime::spawn_blocking(move || search::search(&documents(&app), &request)).await.map_err(|e| e.to_string())
}

/// Search with AI, step one: the brain turns the question into searches. Empty when it gave none in time; the
/// interface then searches the question's own words.
#[tauri::command]
pub async fn search_ai_plan(app: AppHandle, question: String) -> Res<Vec<String>> {
    let settings = app.state::<AppState>().settings();
    let env = crate::commands::chat::brain_env(&app, &settings);
    let today = chrono::Local::now().format("%Y-%m-%d").to_string();
    let prompt = search::plan_prompt(&question, &today);
    let reply = tokio::time::timeout(Duration::from_secs(30), nook_core::brain::service::complete(&settings, &env, search::PLAN_SYSTEM, &prompt)).await;
    Ok(reply.ok().and_then(Result::ok).map(|r| search::queries_from_plan(&r)).unwrap_or_default())
}

/// Search with AI, step two: the brain answers from the sources the searches found, citing them as [1], [2]….
#[tauri::command]
pub async fn search_ai_answer(app: AppHandle, question: String, sources: Vec<Source>) -> Res<String> {
    let settings = app.state::<AppState>().settings();
    let env = crate::commands::chat::brain_env(&app, &settings);
    let prompt = search::answer_prompt(&question, &sources, &settings.language_instruction(&question));
    let reply = tokio::time::timeout(Duration::from_secs(90), nook_core::brain::service::complete(&settings, &env, search::ANSWER_SYSTEM, &prompt))
        .await
        .map_err(|_| "timeout".to_string())?
        .map_err(|e| e.to_string())?;
    Ok(search::clean_answer(&reply))
}

/// Opens a call note from search as the Mac does: a new conversation with the note as Nook's message, so you can ask
/// about it right there. Returns the conversation's id.
#[tauri::command]
pub fn search_open_note(app: AppHandle, id: String) -> Res<String> {
    let services = app.state::<Services>();
    let (title, markdown) = services
        .notes
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&id)
        .map(|n| (n.title.clone(), nook_core::services::notes::markdown(n)))
        .ok_or("note not found")?;
    let state = app.state::<AppState>();
    let conversation = state.with_chat(|c| {
        let cid = c.new_conversation();
        if let Some(conv) = c.get_mut(&cid) {
            let mut message = nook_core::nooks::ChatMessage::nook(&markdown);
            message.sources = vec![nook_core::i18n::tr("Gespreksnotitie", "Call note").to_string()];
            conv.messages.push(message);
            conv.title = title;
            conv.updated = chrono::Utc::now();
        }
        cid
    });
    state.save_chat();
    let _ = tauri::Emitter::emit(&app, "nook-updated", &conversation);
    Ok(conversation)
}

/// Nook's buddy moment shown last (SV-19), or `None` when quiet/disabled/none due. Pass `dismiss_id` to dismiss a
/// currently surfaced moment. The moments themselves are planned by the half-minute timer in `services::buddy`.
#[tauri::command]
pub fn buddy_moment(app: AppHandle, dismiss_id: Option<String>) -> Option<nook_core::services::buddy::BuddyMomentView> {
    crate::services::buddy::current(&app, dismiss_id.as_deref())
}

/// "Breathe with Nook now" (Settings › Appearance) and "Breathe along" on a break: a minute of slow breathing in the bar.
#[tauri::command]
pub fn buddy_breathe(app: AppHandle) {
    crate::services::buddy::breathe(&app);
}

