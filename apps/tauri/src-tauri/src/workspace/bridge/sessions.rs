//! The bridge's tools for other sessions (`WorkspaceBridge+Sessions` and `sessionSend` on the Mac): `session_start`
//! (1–20 top-level sessions), `session_send` (a message as an agent, never as the user) and `session_wait`. The
//! argument rules are in `core/src/workspace/bridge_sessions.rs`.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use nook_core::i18n::{tr, trf};
use nook_core::workspace::bridge::{BridgeCaller, BridgeTool, Reason, ToolResult, Verdict};
use nook_core::workspace::bridge_sessions::{self as args, Place, SendMode, StartSession};
use nook_core::workspace::delegation;
use nook_core::workspace::models::{branch_name, ExecutionMode, IsolationMode, NewRunConfig, PermissionPolicy, RunProvider};
use nook_core::workspace::paths;
use serde_json::{json, Map, Value};
use tauri::AppHandle;
use uuid::Uuid;

use super::{audit, check, refusal, workspace, Context};
use crate::agents::lock;
use crate::workspace::automation;

/// What a call with a `client_request_id` answered, so a retry does nothing twice. Kept while Nook runs.
static ANSWERED: Mutex<Option<HashMap<String, ToolResult>>> = Mutex::new(None);

fn once_key(tool: BridgeTool, caller: &BridgeCaller, a: &Map<String, Value>) -> Option<String> {
    let key = a.get("client_request_id").and_then(Value::as_str).map(str::trim).filter(|k| !k.is_empty())?;
    Some(format!("{}|{}|{key}", tool.name(), caller.key()))
}

fn answered(key: &Option<String>) -> Option<ToolResult> {
    let key = key.as_ref()?;
    lock(&ANSWERED).as_ref()?.get(key).cloned()
}

fn remember(key: &Option<String>, result: &ToolResult) {
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
        let items: Vec<String> = plan.sessions.iter().map(|s| format!("- {}", s.task)).collect();
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
    for (session, provider) in plan.sessions.iter().zip(&providers) {
        started.push(start_one(app, session, *provider, &plan.place, &folder, caller));
    }
    let ok = started.iter().any(|s| s.get("sessionId").is_some());
    let text = serde_json::to_string_pretty(&json!({"sessions": started})).unwrap_or_default();
    let result = if ok { ToolResult::text(text) } else { ToolResult::error(text) };
    remember(&key, &result);
    Ok(result)
}

/// One session of a `session_start` call: its answer with the id, or why it did not start.
fn start_one(app: &AppHandle, session: &StartSession, provider: RunProvider, place: &Place, folder: &str, caller: &BridgeCaller) -> Value {
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
        profile_id: automation::default_profile(app, provider),
        model: if session.model.is_empty() {
            settings.default_models.get(provider.id()).cloned().unwrap_or_default()
        } else {
            session.model.clone()
        },
        // They ask like any other session: the user raises their rights themselves.
        permission: if caps.policies.contains(&PermissionPolicy::Ask) {
            PermissionPolicy::Ask
        } else {
            caps.policies.first().copied().unwrap_or_default()
        },
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
            ws.manager.note(id, &started_by(caller));
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
