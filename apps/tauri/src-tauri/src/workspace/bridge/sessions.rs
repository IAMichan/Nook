//! The bridge's tools for other sessions (`WorkspaceBridge+Sessions` and `sessionSend` on the Mac): `session_start`
//! (1–20 top-level sessions), `session_send` (a message as an agent, never as the user) and `session_wait`. The
//! argument rules are in `core/src/workspace/bridge_sessions.rs`.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use chrono::{DateTime, Local, Utc};
use nook_core::agents::sessions::SessionMarks;
use nook_core::i18n::{tr, trf};
use nook_core::workspace::bridge::{question_verdict, BridgeCaller, BridgeTool, Reason, ToolResult, Verdict};
use nook_core::workspace::bridge_sessions::{
    self as args, OrganizeAction, PendingApprovalNotice, PendingQuestionView, Place, QuestionAction, SendMode, StartSession,
};
use nook_core::workspace::delegation;
use nook_core::workspace::models::{branch_name, ExecutionMode, IsolationMode, NewRunConfig, PermissionPolicy, RunProvider};
use nook_core::workspace::paths;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use tauri::{AppHandle, Emitter, Manager};
use uuid::Uuid;

use super::{audit, check, enabled, refusal, serde_plain, workspace, Context};
use crate::agents::{lock, AgentsState};
use crate::workspace::automation::{self, AutomationState};

/// What a call with a `client_request_id` answered, so a retry does nothing twice. Kept while Nook runs.
static ANSWERED: Mutex<Option<HashMap<String, ToolResult>>> = Mutex::new(None);

pub(super) fn once_key(tool: BridgeTool, caller: &BridgeCaller, a: &Map<String, Value>) -> Option<String> {
    let key = a.get("client_request_id").and_then(Value::as_str).map(str::trim).filter(|k| !k.is_empty())?;
    Some(format!("{}|{}|{key}", tool.name(), caller.key()))
}

pub(super) fn answered(key: &Option<String>) -> Option<ToolResult> {
    let key = key.as_ref()?;
    lock(&ANSWERED).as_ref()?.get(key).cloned()
}

pub(super) fn remember(key: &Option<String>, result: &ToolResult) {
    if let Some(key) = key {
        lock(&ANSWERED).get_or_insert_with(HashMap::new).insert(key.clone(), result.clone());
    }
}

fn provider_named(name: &str, default: RunProvider) -> Result<RunProvider, String> {
    let name = name.trim().to_lowercase();
    if name.is_empty() {
        return Ok(default);
    }
    RunProvider::ALL
        .into_iter()
        .find(|p| p.id() == name || p.display_name().to_lowercase() == name)
        .ok_or_else(|| format!("Unknown agent \"{name}\". Call orchestrator_capabilities for the list."))
}

fn tilde(path: &str) -> String {
    let home = dirs::home_dir().map(|h| h.to_string_lossy().into_owned()).unwrap_or_default();
    match path.strip_prefix(&home) {
        Some(rest) if !home.is_empty() => format!("~{rest}"),
        _ => path.to_string(),
    }
}

/// Where the sessions of an approval card will work.
fn place_line(place: &Place, folder: &str) -> String {
    match place {
        Place::Yours(_) => trf("Ernaast, in {folder}", "Beside it, in {folder}", &[("folder", &tilde(folder))]),
        Place::Folder(..) => tilde(folder),
        Place::Worktree(_, base) => trf(
            "{folder} · elk in een nieuwe worktree vanaf {base}",
            "{folder} · each in a new worktree from {base}",
            &[("folder", &tilde(folder)), ("base", &base.clone().unwrap_or_else(|| "HEAD".into()))],
        ),
        Place::Scratch => tr("Elk in een nieuwe map zonder project", "Each in a new folder without a project").into(),
    }
}

/// The first line of a session another agent started.
fn started_by(caller: &BridgeCaller) -> String {
    if caller.run.is_some() && !caller.title.is_empty() {
        trf(
            "Gestart door {agent} in de sessie ‘{title}’",
            "Started by {agent} in the session “{title}”",
            &[("agent", &caller.agent), ("title", &caller.title)],
        )
    } else {
        trf("Gestart door {agent}", "Started by {agent}", &[("agent", &caller.agent)])
    }
}

pub(super) async fn session_start(
    app: &AppHandle,
    a: &Map<String, Value>,
    caller: &BridgeCaller,
    context: &Context,
) -> Result<ToolResult, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let plan = args::start(a, &caller.directory)?;
    // Starting idle (a title and no first message) is not something sessions here can do yet.
    if plan.sessions.iter().any(|s| s.task.is_empty()) {
        return Err("Nook on this computer cannot start a session without a first message yet: give each session a task.".into());
    }
    let folder = match plan.place.folder() {
        Some(path) => {
            let expanded = match path.strip_prefix("~/") {
                Some(rest) => dirs::home_dir().map(|h| h.join(rest).to_string_lossy().into_owned()).unwrap_or_else(|| path.into()),
                None => path.into(),
            };
            let normalized = paths::normalize(&expanded);
            if normalized.is_empty() || paths::verdict(&normalized) != paths::Verdict::Ok {
                return Err(format!("That folder cannot be used: {path}"));
            }
            normalized
        }
        None => String::new(),
    };
    let default = lock(&ws.settings).default_provider;
    let providers = plan.sessions.iter().map(|s| provider_named(&s.agent, default)).collect::<Result<Vec<_>, _>>()?;
    if let Some(p) = providers.iter().find(|p| !super::tasks::installed(**p)) {
        return Err(format!("{} is not installed.", p.display_name()));
    }
    // The account and rights of each session, checked before the approval card (`StartChoice` on the Mac).
    let mut choices: Vec<StartChoice> = Vec::new();
    for (index, (session, provider)) in plan.sessions.iter().zip(&providers).enumerate() {
        let which = if plan.sessions.len() == 1 { String::new() } else { format!(" (session {})", index + 1) };
        let mut profile_id = automation::default_profile(app, *provider);
        let mut account_label = String::new();
        if !session.account.is_empty() {
            let accounts = account_choices(app, *provider);
            let Some(id) = args::start_account(&session.account, &accounts) else {
                let list: Vec<String> = accounts.iter().map(|(id, label)| format!("{id} ({label})")).collect();
                return Err(format!("Unknown {} account \"{}\"{which}; its accounts: {}.", provider.display_name(), session.account, list.join(", ")));
            };
            account_label = accounts.iter().find(|(i, _)| *i == id).map(|(_, l)| l.clone()).unwrap_or_default();
            profile_id = id;
        }
        let permission = args::start_rights(session.rights, caller.permission, &provider.capabilities().policies).map_err(|e| e + &which)?;
        choices.push(StartChoice { profile_id, permission, account_label });
    }
    if let Verdict::Refuse(reason) = check(app, BridgeTool::SessionStart, caller, None) {
        return Err(refusal(reason).into());
    }
    let key = once_key(BridgeTool::SessionStart, caller, a);
    if let Some(result) = answered(&key) {
        return Ok(result);
    }
    if let Verdict::Ask(_) = check(app, BridgeTool::SessionStart, caller, None) {
        let title = if plan.sessions.len() == 1 {
            trf(
                "{agent} wil een {provider}-sessie starten",
                "{agent} wants to start a {provider} session",
                &[("agent", &caller.agent), ("provider", &providers[0].display_name())],
            )
        } else {
            let mut names: Vec<&str> = providers.iter().map(|p| p.display_name()).collect();
            names.sort_unstable();
            names.dedup();
            trf(
                "{agent} wil {n} sessies starten ({providers})",
                "{agent} wants to start {n} sessions ({providers})",
                &[("agent", &caller.agent), ("n", &plan.sessions.len()), ("providers", &names.join(", "))],
            )
        };
        let items: Vec<String> = plan.sessions.iter().zip(&choices).map(|(s, c)| format!("- {}{}", s.task, account_rights_note(s, c))).collect();
        let detail = format!("{}\n\n{}", place_line(&plan.place, &folder), items.join("\n"));
        let note = tr(
            "De agent krijgt alleen deze opdracht te zien, nooit je gesprek, en heeft nooit meer rechten dan de sessie die hem start.",
            "The agent sees only this brief, never your conversation, and never has more rights than the session that starts it.",
        );
        if !ws.bridge.ask(app, caller, BridgeTool::SessionStart, title, detail, note.into(), &context.connection).await {
            let what: Vec<&str> = plan.sessions.iter().map(|s| s.task.as_str()).collect();
            audit(app, BridgeTool::SessionStart, caller, &what.join(" · "), "niet toegestaan");
            return Err(refusal(Reason::Delegation).into());
        }
    }
    let mut started = Vec::new();
    for ((session, provider), choice) in plan.sessions.iter().zip(&providers).zip(&choices) {
        started.push(start_one(app, session, *provider, choice, &plan.place, &folder, caller));
    }
    let ok = started.iter().any(|s| s.get("sessionId").is_some());
    let text = serde_json::to_string_pretty(&json!({"sessions": started})).unwrap_or_default();
    let result = if ok { ToolResult::text(text) } else { ToolResult::error(text) };
    remember(&key, &result);
    Ok(result)
}

/// The account and rights one session of a `session_start` call runs with, checked before the approval card.
struct StartChoice {
    profile_id: String,
    permission: PermissionPolicy,
    /// The account's name when the caller chose one, for the approval card.
    account_label: String,
}

/// The agent's accounts as (`id`, name) pairs: the main account by the agent's name, extra ones by their label.
fn account_choices(app: &AppHandle, provider: RunProvider) -> Vec<(String, String)> {
    let Some(agents) = app.try_state::<AgentsState>() else { return vec![(provider.id().into(), provider.display_name().into())] };
    let profiles = lock(&agents.profiles).profiles(provider.kind());
    profiles.into_iter().map(|p| {
        let label = if p.label.is_empty() { provider.display_name().to_string() } else { p.label.clone() };
        (p.id, label)
    }).collect()
}

/// " · Account Work · Allow edits" on the approval card, for what the caller chose itself (`accountRightsNote`).
fn account_rights_note(session: &StartSession, choice: &StartChoice) -> String {
    let mut parts: Vec<String> = Vec::new();
    if !session.account.is_empty() && !choice.account_label.is_empty() {
        parts.push(trf("Account {name}", "Account {name}", &[("name", &choice.account_label)]));
    }
    if session.rights.is_some() {
        parts.push(match choice.permission {
            PermissionPolicy::Ask => tr("Alles vragen", "Ask for everything").to_string(),
            PermissionPolicy::AcceptEdits => tr("Bewerkingen toestaan", "Allow edits").to_string(),
            PermissionPolicy::Bypass => tr("Alles toestaan", "Allow everything").to_string(),
        });
    }
    if parts.is_empty() { String::new() } else { format!(" · {}", parts.join(" · ")) }
}

/// One session of a `session_start` call: its answer with the id, or why it did not start.
fn start_one(
    app: &AppHandle,
    session: &StartSession,
    provider: RunProvider,
    choice: &StartChoice,
    place: &Place,
    folder: &str,
    caller: &BridgeCaller,
) -> Value {
    let Some(ws) = workspace(app) else { return json!({"title": session.task, "error": "Nook is not ready."}) };
    let name = session.task.clone();
    let settings = lock(&ws.settings).clone();
    let caps = provider.capabilities();
    let mut project = folder.to_string();
    let mut isolation = IsolationMode::Folder;
    let mut base = String::new();
    match place {
        Place::Yours(_) | Place::Folder(..) => {}
        Place::Worktree(_, b) => {
            isolation = IsolationMode::Worktree;
            base = b.clone().or_else(|| ws.manager.git().and_then(|g| g.current_branch(folder))).unwrap_or_default();
        }
        Place::Scratch => {
            let day = chrono::Local::now().format("%Y-%m-%d").to_string();
            let dir = nook_core::paths::dot_nook().join("scratch").join(args::scratch_folder_name(&day, &name, Uuid::new_v4()));
            if std::fs::create_dir_all(&dir).is_err() {
                return json!({"title": name, "error": "Nook could not make a folder for it."});
            }
            project = dir.to_string_lossy().into_owned();
        }
    }
    let config = NewRunConfig {
        title: session.title.clone(),
        task: session.task.clone(),
        provider,
        profile_id: choice.profile_id.clone(),
        model: if session.model.is_empty() {
            settings.default_models.get(provider.id()).cloned().unwrap_or_default()
        } else {
            session.model.clone()
        },
        // Ask like any other session, unless the caller chose rights (never more than its own).
        permission: choice.permission,
        mode: if session.plan && caps.plan_mode { ExecutionMode::Plan } else { ExecutionMode::Agent },
        isolation,
        branch_name: if isolation == IsolationMode::Worktree { branch_name(&name, Uuid::new_v4()) } else { String::new() },
        base_branch: base,
        project_path: project.clone(),
        ..NewRunConfig::default()
    };
    // The caller asked for this place and the user approved it: a second agent in a folder is the point here.
    match ws.manager.start(config, true) {
        Ok(id) => {
            ws.manager.note_origin(id, &started_by(caller));
            automation::title_new_session(app, id, !session.title.is_empty());
            audit(app, BridgeTool::SessionStart, caller, &format!("{} · {name}", provider.display_name()), &id.to_string());
            let run = ws.manager.run(id);
            let mut answer = json!({
                "sessionId": id.to_string(),
                "title": run.as_ref().map(|r| r.title.clone()).unwrap_or_else(|| name.clone()),
                "agent": provider.display_name(),
                "status": run.as_ref().map(|r| super::serde_plain(&r.status)).unwrap_or_else(|| "preparing".into()),
                "folder": run.as_ref().map(|r| r.working_directory.clone()).unwrap_or(project),
            });
            if let Some(branch) = run.and_then(|r| r.branch).filter(|_| isolation == IsolationMode::Worktree) {
                answer["branch"] = branch.into();
            }
            answer
        }
        Err(e) => {
            audit(app, BridgeTool::SessionStart, caller, &name, &format!("mislukt: {e}"));
            json!({"title": name, "agent": provider.display_name(), "error": format!("Nook could not start it: {e}")})
        }
    }
}

pub(super) async fn session_send(
    app: &AppHandle,
    a: &Map<String, Value>,
    caller: &BridgeCaller,
    context: &Context,
) -> Result<ToolResult, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let message = a.get("message").and_then(Value::as_str).unwrap_or("").trim().to_string();
    if message.is_empty() {
        return Err("Give the message to send.".into());
    }
    let id = a.get("session_id").and_then(Value::as_str).and_then(|s| Uuid::parse_str(s.trim()).ok());
    let target = id.and_then(|id| ws.manager.run(id)).ok_or("No such session. Use an id from session_list.")?;
    if caller.run.as_deref() == Some(target.id.to_string().as_str()) {
        return Err("You cannot send a message to your own session.".into());
    }
    let mode = args::send_mode(a.get("mode"))?;
    if mode == SendMode::Steer && target.status.is_active() && !target.provider.capabilities().steering {
        return Err(format!(
            "{} cannot take a message during its turn here. Use mode queue, auto or restart.",
            target.provider.display_name()
        ));
    }
    if let Verdict::Refuse(reason) = check(app, BridgeTool::SessionSend, caller, None) {
        return Err(refusal(reason).into());
    }
    let key = once_key(BridgeTool::SessionSend, caller, a);
    if let Some(result) = answered(&key) {
        return Ok(result);
    }
    if let Verdict::Ask(_) = check(app, BridgeTool::SessionSend, caller, None) {
        let title = trf(
            "{agent} wil een bericht sturen naar de sessie “{title}”",
            "{agent} wants to send a message to the session “{title}”",
            &[("agent", &caller.agent), ("title", &target.title)],
        );
        let note = tr(
            "De andere agent krijgt het als bericht van een agent, niet als jouw eigen opdracht.",
            "The other agent receives it as a message from an agent, not as your own instruction.",
        );
        if !ws.bridge.ask(app, caller, BridgeTool::SessionSend, title, message.clone(), note.into(), &context.connection).await {
            audit(app, BridgeTool::SessionSend, caller, &target.title, "niet toegestaan");
            return Err(refusal(Reason::Delegation).into());
        }
    }
    // The receiver is told this is another agent's message, never the user's own words.
    let framed = args::framed_agent_message(&message, &args::origin(&caller.agent, &caller.title));
    let manager = ws.manager.clone();
    let busy = target.status.is_active();
    let steerable = target.provider.capabilities().steering;
    let outcome = match mode {
        _ if !busy => manager.send(target.id, &framed).map(|_| "Sent."),
        SendMode::Queue => {
            manager.enqueue(target.id, &framed);
            Ok("Queued: the session is busy and receives it after its current turn.")
        }
        SendMode::Auto if steerable && manager.steer(target.id, &framed) => Ok("Steered: the running turn takes it now."),
        SendMode::Auto => {
            manager.enqueue(target.id, &framed);
            Ok("Queued: the session is busy and receives it after its current turn.")
        }
        SendMode::Steer if manager.steer(target.id, &framed) => Ok("Steered: the running turn takes it now."),
        SendMode::Steer => Err("The session's turn could not take the message. Send it again with mode queue.".to_string()),
        SendMode::Restart => {
            manager.stop(target.id);
            manager.wait_idle(target.id, Duration::from_secs(10)).await;
            manager.send(target.id, &framed).map(|_| "Restarted: the running turn stops and starts again with your message.")
        }
    };
    match outcome {
        Ok(text) => {
            audit(app, BridgeTool::SessionSend, caller, &target.title, text.split(':').next().unwrap_or(text));
            let result = ToolResult::text(text);
            remember(&key, &result);
            Ok(result)
        }
        Err(e) => {
            audit(app, BridgeTool::SessionSend, caller, &target.title, "niet verstuurd");
            Err(e)
        }
    }
}

/// Until one (or all) of these sessions is done with its turn or asks the user something, at most the timeout. Any
/// session may be waited for: reading a session's state is a read, as `session_read` is.
pub(super) async fn session_wait(app: &AppHandle, a: &Map<String, Value>) -> Result<ToolResult, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let ids = args::wait_sessions(a.get("session_ids"))?;
    if !ids.iter().all(|id| ws.manager.run(*id).is_some()) {
        return Err("No such session among these ids. Use ids from session_list or session_start.".into());
    }
    let all = a.get("mode").and_then(Value::as_str) == Some("all");
    let timeout = delegation::wait_seconds(a.get("timeout_seconds").and_then(Value::as_i64));
    let deadline = Instant::now() + Duration::from_secs(timeout);
    loop {
        let snapshots: Vec<_> = ids.iter().filter_map(|id| ws.manager.run(*id)).map(|r| delegation::snapshot(&ws.manager, &r)).collect();
        let over = delegation::wait_is_over(&snapshots, all);
        if over || Instant::now() >= deadline {
            return Ok(ToolResult::text(args::render_session_wait(&snapshots, !over)));
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

// MARK: session_search (AG-06)

pub(super) async fn session_search(app: &AppHandle, a: &Map<String, Value>, caller: &BridgeCaller) -> Result<ToolResult, String> {
    if let Verdict::Refuse(reason) = check(app, BridgeTool::SessionSearch, caller, None) {
        return Err(refusal(reason).into());
    }
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let query = args::parse_search(a)?;
    let manager = ws.manager.clone();
    let result = tauri::async_runtime::spawn_blocking(move || {
        let mut runs = if let Some(id) = query.session_id {
            manager.run(id).into_iter().collect::<Vec<_>>()
        } else {
            manager.runs()
        };
        runs.sort_by_key(|r| std::cmp::Reverse(r.updated_at));
        let project_filter = query.project.as_deref().map(str::to_lowercase);
        let mut matches = Vec::new();
        for run in runs {
            if !query.include_archived && run.archived {
                continue;
            }
            if let Some(filter) = &project_filter {
                let p_name = run.project_name().to_lowercase();
                let p_dir = run.working_directory.to_lowercase();
                if !p_name.contains(filter) && !p_dir.contains(filter) {
                    continue;
                }
            }
            let events = manager.timeline(run.id);
            let status = serde_plain(&run.status);
            if let Some(hit) = args::search_run(&run, &events, &status, &query.query) {
                matches.push(hit);
                if matches.len() >= query.limit {
                    break;
                }
            }
        }
        args::render_search_results(&matches, &query.query)
    })
    .await
    .map_err(|e| e.to_string())?;
    Ok(ToolResult::text(result))
}

// MARK: session_organize (AG-06)

/// Persisted pin / snooze metadata managed by the bridge when the user organizes sessions via an agent.
#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct OrganizeMeta {
    pinned: BTreeSet<String>,
    snoozed: BTreeMap<String, DateTime<Utc>>,
}

static ORGANIZE_META: Mutex<Option<OrganizeMeta>> = Mutex::new(None);

fn organize_meta_file() -> std::path::PathBuf {
    nook_core::paths::support_directory().join("session-organize.json")
}

fn with_organize_meta<R>(f: impl FnOnce(&mut OrganizeMeta) -> R) -> R {
    let mut guard = lock(&ORGANIZE_META);
    let meta = guard.get_or_insert_with(|| {
        std::fs::read(organize_meta_file())
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    });
    let out = f(meta);
    if let Ok(bytes) = serde_json::to_vec_pretty(meta) {
        let _ = nook_core::paths::write_atomic(&organize_meta_file(), &bytes);
    }
    out
}

pub(super) async fn session_organize(
    app: &AppHandle,
    a: &Map<String, Value>,
    caller: &BridgeCaller,
    context: &Context,
) -> Result<ToolResult, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let req = args::parse_organize(a)?;
    let mut targets = Vec::with_capacity(req.session_ids.len());
    for id in &req.session_ids {
        let run = ws.manager.run(*id).ok_or_else(|| format!("No such session: {id}. Use an id from session_list."))?;
        targets.push(run);
    }
    match check(app, BridgeTool::SessionOrganize, caller, None) {
        Verdict::Refuse(reason) => return Err(refusal(reason).into()),
        Verdict::Ask(_) => {
            let desc = args::describe_organize(&req.action);
            let title = if targets.len() == 1 {
                trf(
                    "{agent} wil sessie “{title}” organiseren ({action})",
                    "{agent} wants to organize session “{title}” ({action})",
                    &[("agent", &caller.agent), ("title", &targets[0].title), ("action", &desc)],
                )
            } else {
                trf(
                    "{agent} wil {n} sessies organiseren ({action})",
                    "{agent} wants to organize {n} sessions ({action})",
                    &[("agent", &caller.agent), ("n", &targets.len()), ("action", &desc)],
                )
            };
            let list: Vec<String> = targets.iter().map(|r| format!("- {} ({})", r.title, r.id)).collect();
            let detail = format!("{desc}\n\n{}", list.join("\n"));
            let note = tr(
                "Dit wijzigt alleen hoe deze sessies in Nook geordend staan.",
                "This only changes how these sessions are organized in Nook.",
            );
            if !ws.bridge.ask(app, caller, BridgeTool::SessionOrganize, title, detail, note.into(), &context.connection).await {
                audit(app, BridgeTool::SessionOrganize, caller, &desc, "niet toegestaan");
                return Err(refusal(Reason::NeedsReview).into());
            }
        }
        Verdict::Allow => {}
    }

    let now = Utc::now();
    let snooze_until = match &req.action {
        OrganizeAction::Snooze(choice) => Some(choice.resolve(now, &Local)),
        _ => None,
    };

    for run in &targets {
        let list_id = format!("run:{}", run.id);
        let mark_key = SessionMarks::key(run.provider.display_name(), run.provider_session_id.as_deref(), &list_id);
        match &req.action {
            OrganizeAction::Pin => {
                with_organize_meta(|m| {
                    m.pinned.insert(list_id.clone());
                });
            }
            OrganizeAction::Unpin => {
                with_organize_meta(|m| {
                    m.pinned.remove(&list_id);
                });
            }
            OrganizeAction::Settle => {
                if let Some(agents) = app.try_state::<AgentsState>() {
                    let mut marks = lock(&agents.marks);
                    marks.mark(&mark_key);
                    marks.mark(&list_id);
                }
            }
            OrganizeAction::Reopen => {
                if let Some(agents) = app.try_state::<AgentsState>() {
                    let mut marks = lock(&agents.marks);
                    marks.reopen_by_user(&mark_key, now);
                    marks.reopen_by_user(&list_id, now);
                }
            }
            OrganizeAction::Snooze(_) => {
                if let Some(until) = snooze_until {
                    with_organize_meta(|m| {
                        m.snoozed.insert(list_id.clone(), until);
                    });
                }
            }
            OrganizeAction::Wake => {
                with_organize_meta(|m| {
                    m.snoozed.remove(&list_id);
                });
            }
            OrganizeAction::Archive => ws.manager.set_archived(run.id, true),
            OrganizeAction::Unarchive => ws.manager.set_archived(run.id, false),
            OrganizeAction::MarkUnread => {
                if let Some(agents) = app.try_state::<AgentsState>() {
                    lock(&agents.marks).mark_unread(&list_id);
                }
            }
            OrganizeAction::MarkRead => {
                if let Some(agents) = app.try_state::<AgentsState>() {
                    lock(&agents.marks).visit(&list_id, now);
                }
            }
            OrganizeAction::Rename(title) => ws.manager.rename(run.id, title),
        }
    }

    let desc = args::describe_organize(&req.action);
    let ids: Vec<String> = targets.iter().map(|r| r.id.to_string()).collect();
    let _ = app.emit(
        "session-organize",
        json!({
            "sessionIds": ids,
            "action": desc,
            "snoozeUntil": snooze_until.map(|t| t.to_rfc3339()),
        }),
    );
    let _ = app.emit("agents-changed", ());
    let _ = app.emit("workspace-changed", ());
    audit(app, BridgeTool::SessionOrganize, caller, &format!("{} ({})", desc, ids.len()), "gedaan");

    let names: Vec<String> = targets.iter().map(|r| format!("\"{}\" ({})", r.title, r.id)).collect();
    Ok(ToolResult::text(format!("Updated ({desc}): {}", names.join(", "))))
}

// MARK: session_questions (AG-06)

pub(super) async fn session_questions(
    app: &AppHandle,
    a: &Map<String, Value>,
    caller: &BridgeCaller,
    context: &Context,
) -> Result<ToolResult, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let action = args::parse_questions(a)?;

    match action {
        QuestionAction::List { session_id } => {
            if let Verdict::Refuse(reason) = question_verdict(caller, false, false, enabled(app)) {
                return Err(refusal(reason).into());
            }
            let runs = match session_id {
                Some(id) => ws.manager.run(id).into_iter().collect::<Vec<_>>(),
                None => ws.manager.runs(),
            };
            let mut questions = Vec::new();
            let mut approvals = Vec::new();
            for run in &runs {
                for q in ws.manager.questions(run.id) {
                    questions.push(PendingQuestionView {
                        session_id: run.id,
                        session_title: run.title.clone(),
                        agent: run.provider.display_name().into(),
                        request_id: q.id,
                        items: q.items,
                    });
                }
                for p in ws.manager.permissions(run.id) {
                    approvals.push(PendingApprovalNotice {
                        session_id: Some(run.id),
                        agent: run.provider.display_name().into(),
                        tool: p.tool,
                        title: p.summary,
                    });
                }
            }
            Ok(ToolResult::text(args::render_questions_list(&questions, &approvals)))
        }
        QuestionAction::Read { session_id, request_id } => {
            if let Verdict::Refuse(reason) = question_verdict(caller, false, false, enabled(app)) {
                return Err(refusal(reason).into());
            }
            let run = ws.manager.run(session_id).ok_or("No such session. Use an id from session_list.")?;
            let list = ws.manager.questions(run.id);
            let q = match request_id {
                Some(ref rid) => list.into_iter().find(|q| q.id == *rid),
                None => list.into_iter().next(),
            }
            .ok_or("This session has no pending multiple-choice question.")?;
            Ok(ToolResult::text(args::render_question_detail(&PendingQuestionView {
                session_id: run.id,
                session_title: run.title,
                agent: run.provider.display_name().into(),
                request_id: q.id,
                items: q.items,
            })))
        }
        QuestionAction::Answer { session_id, request_id, answers } => {
            let run = ws.manager.run(session_id).ok_or("No such session. Use an id from session_list.")?;
            let own_task = caller
                .run
                .as_deref()
                .and_then(|r| Uuid::parse_str(r).ok())
                .zip(app.try_state::<AutomationState>())
                .is_some_and(|(parent_id, auto)| auto.links.link(session_id).is_some_and(|link| link.parent == parent_id));

            let list = ws.manager.questions(run.id);
            let q = match request_id {
                Some(ref rid) => list.into_iter().find(|q| q.id == *rid),
                None => list.into_iter().next(),
            }
            .ok_or("This session has no matching pending multiple-choice question. Note: permission approvals cannot be answered via session_questions.")?;

            let selections = args::resolve_question_selections(&q.items, &answers)?;

            match question_verdict(caller, true, own_task, enabled(app)) {
                Verdict::Refuse(reason) => return Err(refusal(reason).into()),
                Verdict::Ask(_) => {
                    let title = trf(
                        "{agent} wil een vraag beantwoorden voor sessie “{title}”",
                        "{agent} wants to answer a question for session “{title}”",
                        &[("agent", &caller.agent), ("title", &run.title)],
                    );
                    let summary: Vec<String> = q
                        .items
                        .iter()
                        .zip(&selections)
                        .map(|(item, sel)| format!("- {}: {}", item.question, sel.join(", ")))
                        .collect();
                    let note = tr(
                        "De andere agent krijgt deze keuzes als antwoord op zijn meerkeuzevraag.",
                        "The other agent receives these choices as the answer to its multiple-choice question.",
                    );
                    if !ws
                        .bridge
                        .ask(app, caller, BridgeTool::SessionQuestions, title, summary.join("\n"), note.into(), &context.connection)
                        .await
                    {
                        audit(app, BridgeTool::SessionQuestions, caller, &run.title, "niet toegestaan");
                        return Err(refusal(Reason::Delegation).into());
                    }
                }
                Verdict::Allow => {}
            }

            ws.manager.answer_question(run.id, &q.id, &selections)?;
            let chosen = selections.iter().flatten().cloned().collect::<Vec<_>>().join(", ");
            audit(app, BridgeTool::SessionQuestions, caller, &run.title, &chosen);
            Ok(ToolResult::text(format!("Answered pending question {} in \"{}\" with: {chosen}", q.id, run.title)))
        }
    }
}
