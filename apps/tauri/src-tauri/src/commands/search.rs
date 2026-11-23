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

// ── Music & Spotify Web API PKCE Commands (SV-30..SV-38, BR-28) ──

use nook_core::platform::NowPlaying;
use nook_core::services::dictation_lang::{self, DictationLanguageSettings};
use nook_core::services::music::{
    LoadState, MusicArtist, MusicOutput, MusicPlayerStats, MusicPlaylist, MusicTrack, PlayQueue, QueueEntry,
};
use nook_core::services::music_history::{MusicHistory, MusicListening, MusicPlay, MusicStats, StatsPeriod};
use nook_core::services::spotify::{self, SpotifyConfig, SpotifySearchCatalog};
use nook_core::services::transcribe::{self, ReusableModelCopy, SpeechModelCatalogEntry};

static MUSIC_QUEUE: std::sync::LazyLock<Mutex<PlayQueue>> = std::sync::LazyLock::new(|| Mutex::new(PlayQueue::default()));
static MUSIC_LISTENING: std::sync::LazyLock<Mutex<MusicListening>> =
    std::sync::LazyLock::new(|| Mutex::new(MusicListening::default()));

/// Synchronizes the currently playing track from `platform.media.now_playing()` into [`MusicHistory`] and [`MusicListening`].
fn sync_now_playing(app: &AppHandle) -> (Option<NowPlaying>, MusicHistory) {
    let services = app.state::<Services>();
    let now_playing = services.platform.media.now_playing();
    let mut history = MusicHistory::load();
    let mut dirty = false;

    let draft_play = now_playing.as_ref().and_then(|np| {
        let title = np.title.trim();
        if title.is_empty() {
            return None;
        }
        let track = MusicTrack {
            id: String::new(),
            title: title.to_string(),
            artist: np.artist.clone(),
            duration: np.duration.unwrap_or(0.0).max(0.0) as u32,
            artwork_url: np.artwork.clone(),
            album: np.album.clone(),
        };
        if np.playing {
            let before = history.recent.tracks.first().cloned();
            history.recent.add(track);
            if history.recent.tracks.first() != before.as_ref() {
                dirty = true;
            }
        }
        Some(MusicPlay {
            id: String::new(),
            title: title.to_string(),
            artist: np.artist.clone(),
            album: np.album.clone(),
            app: if np.app.is_empty() { "Player".into() } else { np.app.clone() },
            artwork_url: np.artwork.clone(),
            duration: np.duration.unwrap_or(0.0).max(0.0) as u32,
            listened: 0,
            played_at: chrono::Utc::now(),
        })
    });

    let is_playing = now_playing.as_ref().is_some_and(|n| n.playing);
    let finished = MUSIC_LISTENING
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .update(draft_play, is_playing, chrono::Utc::now());
    if let Some(play) = finished {
        history.add(play);
        dirty = true;
    }
    if dirty {
        let _ = history.save();
    }
    (now_playing, history)
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MusicOverviewView {
    pub spotify_connected: bool,
    pub spotify_client_id: String,
    pub spotify_redirect_uri: String,
    pub spotify_user: Option<String>,
    pub spotify_pending_url: Option<String>,
    pub now_playing: Option<NowPlaying>,
    pub recent: Vec<MusicTrack>,
    pub searches: Vec<String>,
    pub nook_queue: Vec<QueueEntry>,
    pub spotify_queue: Vec<MusicTrack>,
    pub playlists: Vec<MusicPlaylist>,
    pub outputs: Vec<MusicOutput>,
    pub streak: u32,
    pub week_seconds: u32,
    pub week_plays: u32,
}

#[tauri::command]
pub async fn music_overview(app: AppHandle) -> Res<MusicOverviewView> {
    let (now_playing, history) = sync_now_playing(&app);
    let cfg = SpotifyConfig::load();
    let connected = cfg.connected();
    let nook_queue = MUSIC_QUEUE.lock().unwrap_or_else(|e| e.into_inner()).entries.clone();
    let local_vol = app.state::<Services>().platform.media.volume();
    let local_out = vec![spotify::local_computer_output(local_vol)];

    let (spotify_queue, playlists, connect_devs) = if connected {
        let q = spotify::player_queue().await.unwrap_or_default();
        let p = spotify::user_playlists().await.unwrap_or_default();
        let d = spotify::connect_devices().await.unwrap_or_default();
        (q, p, d)
    } else {
        (Vec::new(), Vec::new(), Vec::new())
    };

    let outputs = spotify::merge_outputs(local_out, connect_devs);
    let now = chrono::Utc::now();
    let offset = *chrono::Local::now().offset();
    let week = MusicStats::new(&history.plays, StatsPeriod::Week, now, offset);

    Ok(MusicOverviewView {
        spotify_connected: connected,
        spotify_client_id: cfg.client_id,
        spotify_redirect_uri: cfg.redirect_uri,
        spotify_user: cfg.session.as_ref().and_then(|s| s.display_name.clone().or_else(|| s.user_id.clone())),
        spotify_pending_url: cfg.pending.as_ref().map(|p| p.authorize_url.clone()),
        now_playing,
        recent: history.recent.tracks,
        searches: history.searches,
        nook_queue,
        spotify_queue,
        playlists,
        outputs,
        streak: week.streak,
        week_seconds: week.seconds,
        week_plays: week.plays,
    })
}

#[tauri::command]
pub async fn music_search(query: String, remember: Option<bool>, forget: Option<String>) -> Res<SpotifySearchCatalog> {
    let mut history = MusicHistory::load();
    if let Some(f) = forget.as_deref().filter(|s| !s.is_empty()) {
        history.forget_search(f);
        let _ = history.save();
    }
    let clean = query.trim();
    if clean.is_empty() {
        return Ok(SpotifySearchCatalog::default());
    }
    if remember.unwrap_or(true) {
        history.remember_search(clean);
        let _ = history.save();
    }
    let mut catalog = spotify::search_catalog(clean, 24).await;
    if catalog.tracks.is_empty() {
        let lower = clean.to_lowercase();
        let local_matches: Vec<MusicTrack> = history
            .recent
            .tracks
            .iter()
            .filter(|t| {
                t.title.to_lowercase().contains(&lower)
                    || t.artist.to_lowercase().contains(&lower)
                    || t.album.to_lowercase().contains(&lower)
            })
            .cloned()
            .collect();
        if !local_matches.is_empty() {
            catalog.tracks = local_matches;
        }
    }
    Ok(catalog)
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MusicQueueView {
    pub state: LoadState,
    pub nook_queue: Vec<QueueEntry>,
    pub spotify_queue: Vec<MusicTrack>,
}

#[tauri::command]
pub async fn music_queue(remove_id: Option<String>, clear: Option<bool>, play_entry_id: Option<String>) -> Res<MusicQueueView> {
    let mut to_play: Option<MusicTrack> = None;
    {
        let mut q = MUSIC_QUEUE.lock().unwrap_or_else(|e| e.into_inner());
        if clear == Some(true) {
            q.clear();
        }
        if let Some(rid) = remove_id.as_deref().filter(|s| !s.is_empty()) {
            q.remove(rid);
        }
        if let Some(pid) = play_entry_id.as_deref().filter(|s| !s.is_empty()) {
            to_play = q.take(Some(pid));
        }
    }
    if let Some(track) = to_play {
        if !track.id.is_empty() {
            let _ = spotify::play_uri(&track.id, None, None).await;
        }
        let mut h = MusicHistory::load();
        h.recent.add(track);
        let _ = h.save();
    }
    let nook_queue = MUSIC_QUEUE.lock().unwrap_or_else(|e| e.into_inner()).entries.clone();
    match spotify::player_queue().await {
        Ok(spotify_queue) => Ok(MusicQueueView {
            state: LoadState::Done,
            nook_queue,
            spotify_queue,
        }),
        Err(f) => Ok(MusicQueueView {
            state: LoadState::from_failure(&f),
            nook_queue,
            spotify_queue: Vec::new(),
        }),
    }
}

#[tauri::command]
pub async fn music_queue_add(
    track: MusicTrack,
    play_now: Option<bool>,
    context_uri: Option<String>,
    device_id: Option<String>,
) -> Res<MusicQueueView> {
    if play_now == Some(true) {
        let target = if track.id.is_empty() {
            context_uri.clone().unwrap_or_default()
        } else {
            track.id.clone()
        };
        if !target.is_empty() {
            spotify::play_uri(&target, context_uri.as_deref(), device_id.as_deref())
                .await
                .map_err(|e| e.to_string())?;
        }
        if !track.title.is_empty() {
            let mut h = MusicHistory::load();
            h.recent.add(track);
            let _ = h.save();
        }
    } else {
        let mut added_remote = false;
        if nook_core::services::music::is_spotify_uri(&track.id) {
            added_remote = spotify::add_to_player_queue(&track.id).await.is_ok();
        }
        if !added_remote {
            let mut q = MUSIC_QUEUE.lock().unwrap_or_else(|e| e.into_inner());
            let mut queued_track = track;
            if queued_track.id.is_empty() {
                queued_track.id = format!("local:{}:{}", queued_track.artist, queued_track.title);
            }
            q.append(queued_track);
        } else {
            let mut q = MUSIC_QUEUE.lock().unwrap_or_else(|e| e.into_inner());
            q.append(track);
        }
    }
    music_queue(None, None, None).await
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MusicPlaylistsView {
    pub state: LoadState,
    pub playlists: Vec<MusicPlaylist>,
    pub selected_id: Option<String>,
    pub tracks: Vec<MusicTrack>,
}

#[tauri::command]
pub async fn music_playlists(playlist_id: Option<String>) -> Res<MusicPlaylistsView> {
    let playlists = match spotify::user_playlists().await {
        Ok(list) => list,
        Err(f) => {
            return Ok(MusicPlaylistsView {
                state: LoadState::from_failure(&f),
                playlists: Vec::new(),
                selected_id: None,
                tracks: Vec::new(),
            })
        }
    };
    let selected = playlist_id
        .filter(|s| !s.trim().is_empty())
        .or_else(|| playlists.first().map(|p| p.id.clone()));
    let tracks = if let Some(sel) = selected.as_deref() {
        spotify::playlist_tracks(sel).await.unwrap_or_default()
    } else {
        Vec::new()
    };
    Ok(MusicPlaylistsView {
        state: LoadState::Done,
        playlists,
        selected_id: selected,
        tracks,
    })
}

#[tauri::command]
pub async fn music_playlist_create(name: String, description: Option<String>, public: Option<bool>) -> Res<MusicPlaylist> {
    spotify::create_playlist(&name, description.as_deref(), public.unwrap_or(false))
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn music_playlist_modify(
    playlist_id: String,
    action: String,
    name: Option<String>,
    track_uri: Option<String>,
) -> Res<MusicPlaylistsView> {
    match action.as_str() {
        "rename" => {
            let new_name = name.unwrap_or_default();
            spotify::rename_playlist(&playlist_id, &new_name).await.map_err(|e| e.to_string())?;
        }
        "delete" => {
            spotify::delete_playlist(&playlist_id).await.map_err(|e| e.to_string())?;
            return music_playlists(None).await;
        }
        "add_track" => {
            let uri = track_uri.unwrap_or_default();
            spotify::add_tracks_to_playlist(&playlist_id, &[uri]).await.map_err(|e| e.to_string())?;
        }
        "remove_track" => {
            let uri = track_uri.unwrap_or_default();
            spotify::remove_tracks_from_playlist(&playlist_id, &[uri])
                .await
                .map_err(|e| e.to_string())?;
        }
        "play" => {
            let target = track_uri.as_deref().unwrap_or(&playlist_id);
            spotify::play_uri(target, Some(&playlist_id), None)
                .await
                .map_err(|e| e.to_string())?;
        }
        other => return Err(format!("Unknown playlist action: {other}")),
    }
    music_playlists(Some(playlist_id)).await
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MusicLibraryView {
    pub state: LoadState,
    pub time_range: String,
    pub player_stats: MusicPlayerStats,
    pub recent: Vec<MusicTrack>,
    pub local_top_tracks: Vec<nook_core::services::music_history::TrackRank>,
    pub local_top_artists: Vec<nook_core::services::music_history::ArtistRank>,
}

#[tauri::command]
pub async fn music_library(time_range: Option<String>) -> Res<MusicLibraryView> {
    let range = time_range.unwrap_or_else(|| "medium_term".into());
    let mut history = MusicHistory::load();
    if let Ok(imported) = spotify::recent_plays().await {
        for p in imported.iter().rev() {
            history.recent.add(p.track());
        }
        if history.merge(imported) {
            let _ = history.save();
        }
    }
    let now = chrono::Utc::now();
    let offset = *chrono::Local::now().offset();
    let stats_month = MusicStats::new(&history.plays, StatsPeriod::Month, now, offset);

    let (state, player_stats) = match spotify::top_stats(Some(&range)).await {
        Ok(ps) => (LoadState::Done, ps),
        Err(f) => {
            let fallback = MusicPlayerStats {
                app: "Nook".into(),
                tracks: stats_month.top_tracks.iter().map(|r| r.track.clone()).collect(),
                artists: stats_month
                    .top_artists
                    .iter()
                    .map(|a| MusicArtist {
                        name: a.name.clone(),
                        plays: Some(a.plays),
                        artwork_url: a.artwork_url.clone(),
                    })
                    .collect(),
            };
            (LoadState::from_failure(&f), fallback)
        }
    };

    Ok(MusicLibraryView {
        state,
        time_range: range,
        player_stats,
        recent: history.recent.tracks,
        local_top_tracks: stats_month.top_tracks,
        local_top_artists: stats_month.top_artists,
    })
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MusicHistoryStatsView {
    pub stats: MusicStats,
    pub change_percent: Option<i32>,
    pub total_plays: usize,
    pub recent: Vec<MusicTrack>,
    pub searches: Vec<String>,
}

#[tauri::command]
pub async fn music_history_stats(period: Option<StatsPeriod>, clear: Option<bool>) -> Res<MusicHistoryStatsView> {
    let mut history = MusicHistory::load();
    if clear == Some(true) {
        history.clear();
        let _ = history.save();
    } else if let Ok(imported) = spotify::recent_plays().await {
        if history.merge(imported) {
            let _ = history.save();
        }
    }
    let chosen = period.unwrap_or(StatsPeriod::Week);
    let now = chrono::Utc::now();
    let offset = *chrono::Local::now().offset();
    let stats = MusicStats::new(&history.plays, chosen, now, offset);
    let change_percent = stats.change();
    Ok(MusicHistoryStatsView {
        stats,
        change_percent,
        total_plays: history.plays.len(),
        recent: history.recent.tracks,
        searches: history.searches,
    })
}

#[tauri::command]
pub async fn music_outputs(app: AppHandle) -> Res<Vec<MusicOutput>> {
    let local_vol = app.state::<Services>().platform.media.volume();
    let local = vec![spotify::local_computer_output(local_vol)];
    let connect = spotify::connect_devices().await.unwrap_or_default();
    Ok(spotify::merge_outputs(local, connect))
}

#[tauri::command]
pub async fn music_select_output(app: AppHandle, device_id: String, play: Option<bool>) -> Res<Vec<MusicOutput>> {
    if !device_id.trim().is_empty() && device_id != "local:default" {
        spotify::select_connect_device(&device_id, play.unwrap_or(true))
            .await
            .map_err(|e| e.to_string())?;
    }
    music_outputs(app).await
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpotifyConnectStatus {
    pub connected: bool,
    pub client_id: String,
    pub redirect_uri: String,
    pub authorize_url: Option<String>,
    pub user_id: Option<String>,
    pub display_name: Option<String>,
}

#[tauri::command]
pub async fn music_spotify_connect(
    app: AppHandle,
    client_id: Option<String>,
    redirect_uri: Option<String>,
    callback_code: Option<String>,
) -> Res<SpotifyConnectStatus> {
    if let Some(code) = callback_code.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        let session = spotify::complete_pkce(code).await.map_err(|e| e.to_string())?;
        let cfg = SpotifyConfig::load();
        return Ok(SpotifyConnectStatus {
            connected: true,
            client_id: session.client_id,
            redirect_uri: cfg.redirect_uri,
            authorize_url: None,
            user_id: session.user_id,
            display_name: session.display_name,
        });
    }

    let cfg = SpotifyConfig::load();
    let cid = client_id
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(&cfg.client_id);
    let pending = spotify::begin_pkce(cid, redirect_uri.as_deref()).map_err(|e| e.to_string())?;
    let _ = app.state::<Services>().platform.system.open_url(&pending.authorize_url);

    let expected_state = pending.state.clone();
    let app_clone = app.clone();
    tauri::async_runtime::spawn(async move {
        if let Some(code) = spotify::await_loopback_callback(expected_state, Duration::from_secs(180)).await {
            if let Ok(session) = spotify::complete_pkce(&code).await {
                let _ = tauri::Emitter::emit(&app_clone, "music-spotify-connected", &session.display_name);
            }
        }
    });

    Ok(SpotifyConnectStatus {
        connected: false,
        client_id: pending.client_id,
        redirect_uri: pending.redirect_uri,
        authorize_url: Some(pending.authorize_url),
        user_id: None,
        display_name: None,
    })
}

#[tauri::command]
pub fn music_spotify_disconnect() -> Res<SpotifyConnectStatus> {
    spotify::disconnect();
    let cfg = SpotifyConfig::load();
    Ok(SpotifyConnectStatus {
        connected: false,
        client_id: cfg.client_id,
        redirect_uri: cfg.redirect_uri,
        authorize_url: None,
        user_id: None,
        display_name: None,
    })
}

// ── SV-47, SV-48, SV-49: Voice Multi-Language Dictation & Hugging Face / Parakeet Model Discovery Commands ──

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DictationLanguageOption {
    pub code: String,
    pub name: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VoiceDictationLanguagesView {
    pub settings: DictationLanguageSettings,
    pub candidates: Vec<String>,
    pub available: Vec<DictationLanguageOption>,
    pub context_preview: String,
}

#[tauri::command]
pub fn voice_dictation_languages(
    app: AppHandle,
    update: Option<DictationLanguageSettings>,
) -> Res<VoiceDictationLanguagesView> {
    let mut settings = match update {
        Some(mut next) => {
            next.normalize();
            let _ = next.save();
            next
        }
        None => DictationLanguageSettings::load(),
    };
    settings.normalize();
    let app_lang = nook_core::i18n::language();
    let sys_locale: Vec<String> = std::env::var("LC_ALL")
        .or_else(|_| std::env::var("LANG"))
        .ok()
        .filter(|v| !v.trim().is_empty())
        .into_iter()
        .collect();
    let candidates: Vec<String> = settings
        .candidates(&sys_locale, &[], app_lang)
        .into_iter()
        .map(str::to_string)
        .collect();
    let available: Vec<DictationLanguageOption> = dictation_lang::LANGUAGES
        .iter()
        .map(|(code, name)| DictationLanguageOption {
            code: (*code).to_string(),
            name: (*name).to_string(),
        })
        .collect();
    let context_preview = crate::services::flow::initial_prompt(&app);
    Ok(VoiceDictationLanguagesView {
        settings,
        candidates,
        available,
        context_preview,
    })
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VoiceModelsView {
    pub catalog: Vec<SpeechModelCatalogEntry>,
    pub reusable: Vec<ReusableModelCopy>,
    pub models_dir: String,
    pub linked_path: Option<String>,
}

#[tauri::command]
pub fn voice_reusable_models(reuse_model_id: Option<String>, snapshot_path: Option<String>) -> Res<VoiceModelsView> {
    let models_dir = transcribe::speech_models_dir();
    let mut linked_path = None;
    if let (Some(id), Some(path)) = (
        reuse_model_id.as_deref().filter(|s| !s.is_empty()),
        snapshot_path.as_deref().filter(|s| !s.is_empty()),
    ) {
        let dest = transcribe::reuse_hf_model(id, std::path::Path::new(path), &models_dir).map_err(|e| e.to_string())?;
        linked_path = Some(dest.to_string_lossy().to_string());
    }
    Ok(VoiceModelsView {
        catalog: transcribe::model_catalog(),
        reusable: transcribe::discover_reusable_models(),
        models_dir: models_dir.to_string_lossy().to_string(),
        linked_path,
    })
}


