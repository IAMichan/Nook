//! The companion's `remote` area on Windows and Linux: what the Mac's `CompanionServer+Remote.swift` answers, from this
//! app's own workspace. Starting a session, reading its conversation (and older pages, and one entry in full), older
//! sessions and search, renaming and archiving, steering and pictures with a message, its changes, its terminals and
//! its folder. The shapes and limits are in `nook_core::companion::remote_digest`.
//!
//! What a phone may touch is narrowed here as on the Mac: only a folder the user already worked in, never "allow
//! everything", nothing outside the session's folder and no secrets by name. Every side effect is audited.

use std::collections::VecDeque;
use std::path::Path;
use std::sync::{Arc, Mutex};

use base64::Engine as _;
use nook_core::agents::models::AgentSession;
use nook_core::companion::remote_digest::{self as rd, FileChunk, FolderEntry, TerminalDigest, TimelineEntry};
use nook_core::companion::sessions::{self, HUB_PREFIX};
use nook_core::companion::{
    feature, server, CompanionError, CompanionOp, CompanionPolicy, CompanionRequest, CompanionResponse, SessionDigest,
};
use nook_core::workspace::manager::Manager;
use nook_core::workspace::models::{ExecutionMode, IsolationMode, NewRunConfig, RunProvider, WorkspaceRun};
use nook_core::workspace::paths::{self, Verdict};
use nook_core::workspace::settings::WorkspaceSettings;
use serde::Serialize;
use tauri::{AppHandle, Manager as _};
use uuid::Uuid;

use super::Companion;
use crate::agents::{lock, AgentsState};
use crate::workspace::WorkspaceState;

/// The `feature` names this area can answer: everything below once the workspace is there, and starting a session
/// only where agents run on this computer.
pub fn features(app: &AppHandle) -> Vec<&'static str> {
    if app.try_state::<WorkspaceState>().is_none() {
        return Vec::new();
    }
    let mut list = vec![
        feature::TIMELINE,
        feature::FULL_TRANSCRIPT,
        feature::HISTORY,
        feature::MANAGE,
        feature::STEER,
        feature::IMAGES,
        feature::DIFF,
        feature::WORKSPACE,
        feature::FILE_PREVIEW,
    ];
    if crate::platform::capabilities().local_agents {
        list.insert(0, feature::START);
    }
    list
}

/// The answer to one of this area's ops; `None` when it cannot.
pub async fn handle(app: &AppHandle, request: &CompanionRequest, _device: &str) -> Option<CompanionResponse> {
    let manager = app.try_state::<WorkspaceState>()?.manager.clone();
    let response = match request.op {
        CompanionOp::Options => options(app, request, manager).await,
        CompanionOp::Start => start(app, request, manager).await,
        CompanionOp::Timeline => timeline(app, request, manager).await,
        CompanionOp::Entry => entry(app, request, manager).await,
        CompanionOp::History => history(request, manager).await,
        CompanionOp::Manage => manage(app, request, manager).await,
        CompanionOp::Send => send(app, request, manager).await,
        CompanionOp::Diff => diff(app, request, manager).await,
        CompanionOp::Terminals => terminals(app, request, &manager),
        CompanionOp::Files => files(app, request, &manager).await,
        CompanionOp::FileData => file_data(app, request, &manager).await,
        _ => return None,
    };
    Some(response)
}

// MARK: Helpers

fn fail(request: &CompanionRequest, error: CompanionError) -> CompanionResponse {
    CompanionResponse::failure(&request.id, error)
}

fn fail_with(request: &CompanionRequest, error: CompanionError, message: impl Into<String>) -> CompanionResponse {
    CompanionResponse { message: Some(message.into()), ..fail(request, error) }
}

fn json<T: Serialize>(value: &T) -> Option<serde_json::Value> {
    serde_json::to_value(value).ok()
}

/// In the audit log as the Mac writes it: `companion_<action>`.
fn audit(app: &AppHandle, action: &str, detail: &str) {
    if let Some(state) = app.try_state::<crate::state::AppState>() {
        state.store.audit(&format!("companion_{action}"), detail, "ok");
    }
}

async fn blocking<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> Option<T> {
    tauri::async_runtime::spawn_blocking(f).await.ok()
}

/// The session list the phone gets with an answer that changed something, as `list` gives it.
async fn listed(app: &AppHandle) -> Vec<SessionDigest> {
    let Some(server) = app.try_state::<Companion>().map(|c| c.server.clone()) else { return Vec::new() };
    server::digests(server.sessions().await)
}

fn run_of(manager: &Manager, session: &str) -> Option<WorkspaceRun> {
    Uuid::parse_str(session).ok().and_then(|id| manager.run(id))
}

/// An agent in a terminal or editor (through hooks), by its digest id (`hub:<key>`).
fn hub_session(app: &AppHandle, session: &str) -> Option<AgentSession> {
    let key = session.strip_prefix(HUB_PREFIX)?;
    app.try_state::<AgentsState>()?.hub.sessions().into_iter().find(|s| s.id == key)
}

fn seconds(date: Option<chrono::DateTime<chrono::Utc>>) -> f64 {
    date.map(|d| d.timestamp_millis() as f64 / 1000.0).unwrap_or_default()
}

/// The folder a session works in: a session Nook runs, or an agent in a terminal (its working directory).
fn session_folder(app: &AppHandle, manager: &Manager, session: &str) -> Option<String> {
    if let Some(run) = run_of(manager, session) {
        return Some(run.working_directory);
    }
    hub_session(app, session).map(|s| s.cwd)
}

/// Where pictures from the phone are kept for agents (as the Mac's `CompanionImages`).
fn images_folder() -> std::path::PathBuf {
    nook_core::paths::support_directory().join("images")
}

/// Agents that can start here: this computer runs agents, and the agent is installed.
fn launchable() -> Vec<RunProvider> {
    if !crate::platform::capabilities().local_agents {
        return Vec::new();
    }
    RunProvider::ALL
        .into_iter()
        .filter(|p| {
            let found = nook_core::agents::find_executable(p.kind()).map(|e| e.to_string_lossy().into_owned());
            nook_core::workspace::driver::session_executable(*p, found).is_some()
        })
        .collect()
}

/// The models the composer offers an agent ("" is the agent's own default), with the remembered one.
fn models(provider: RunProvider, settings: &WorkspaceSettings) -> Vec<String> {
    let mut list: Vec<String> = provider.suggested_models().into_iter().map(str::to_string).collect();
    let mut remembered = vec![settings.model(provider)];
    remembered.extend(settings.folder_choices.values().filter_map(|c| c.agents.get(provider.id()).map(|a| a.model.clone())));
    for model in remembered {
        if !list.contains(&model) {
            list.push(model);
        }
    }
    list.truncate(16);
    list
}

fn model_name(model: &str) -> String {
    if model.is_empty() {
        nook_core::i18n::tr("Standaard", "Default").into()
    } else {
        CompanionPolicy::excerpt(model).chars().take(80).collect()
    }
}

fn settings(app: &AppHandle) -> WorkspaceSettings {
    app.try_state::<WorkspaceState>().map(|ws| lock(&ws.settings).clone()).unwrap_or_default()
}

fn projects(settings: &WorkspaceSettings) -> Vec<String> {
    nook_core::workspace::bridge_nook::projects(settings, &|p| Path::new(p).is_dir())
}

// MARK: Starting a session

async fn options(app: &AppHandle, request: &CompanionRequest, manager: Arc<Manager>) -> CompanionResponse {
    let settings = settings(app);
    let agents: Vec<rd::LaunchAgent> = launchable()
        .into_iter()
        .map(|provider| rd::LaunchAgent {
            id: provider.id().into(),
            name: provider.display_name().into(),
            can_plan: provider.capabilities().plan_mode,
            models: Some(models(provider, &settings).iter().map(|m| rd::LaunchModel { id: m.clone(), name: model_name(m) }).collect()),
            default_model: Some(settings.model(provider)),
            can_main_thread: None,
        })
        .collect();
    let paths = projects(&settings);
    let m = manager.clone();
    let infos = blocking(move || {
        let can_git = m.git_available();
        // Each folder asks git a few things; side by side, so a long list stays quick.
        std::thread::scope(|scope| {
            let handles: Vec<_> = paths.iter().map(|p| scope.spawn(|| m.inspect_project(p))).collect();
            handles.into_iter().filter_map(|h| h.join().ok()).map(|info| (info, can_git)).collect::<Vec<_>>()
        })
    })
    .await
    .unwrap_or_default();
    let projects: Vec<rd::LaunchProject> = infos
        .into_iter()
        .filter(|(info, _)| info.verdict == Verdict::Ok)
        .map(|(info, can_git)| rd::LaunchProject {
            can_worktree: can_git && info.repo_root.is_some() && info.has_commits,
            path: info.path,
            name: info.name,
        })
        .collect();
    let last = paths::normalize(&settings.last_project);
    let default_project = if projects.iter().any(|p| p.path == last) { Some(last) } else { projects.first().map(|p| p.path.clone()) };
    // The phone's form opens on one project, with what the user last chose there.
    let choices = default_project.as_ref().and_then(|p| settings.folder_choices.get(p));
    let has = |p: RunProvider| agents.iter().any(|a| a.id == p.id());
    let default_agent = choices
        .map(|c| c.provider)
        .filter(|p| has(*p))
        .or(Some(settings.default_provider).filter(|p| has(*p)))
        .map(|p| p.id().to_string())
        .or_else(|| agents.first().map(|a| a.id.clone()));
    let options = rd::LaunchOptions {
        default_plan: choices.map(|c| c.mode).unwrap_or(settings.default_mode) == ExecutionMode::Plan,
        default_worktree: choices.map(|c| c.isolation).unwrap_or(settings.default_isolation) == IsolationMode::Worktree,
        agents,
        projects,
        default_agent,
        default_project,
    };
    CompanionResponse { launch: json(&options), ..CompanionResponse::success(&request.id) }
}

/// Sessions started from a phone, by the request that started them, so a request sent again (from the phone's
/// outbox, after a lost answer) gives the same session instead of a second one.
static STARTED: Mutex<VecDeque<(String, String)>> = Mutex::new(VecDeque::new());

fn started(request: &str) -> Option<String> {
    STARTED.lock().unwrap_or_else(|e| e.into_inner()).iter().find(|(r, _)| r == request).map(|(_, s)| s.clone())
}

/// Starts a session the way the composer would, with the remembered account, model and effort for that agent in that
/// folder, and at most "allow edits".
async fn start(app: &AppHandle, request: &CompanionRequest, manager: Arc<Manager>) -> CompanionResponse {
    if let Some(created) = started(&request.id) {
        return CompanionResponse { sessions: Some(listed(app).await), created: Some(created), ..CompanionResponse::success(&request.id) };
    }
    let Some(launch) = &request.launch else { return fail(request, CompanionError::BadRequest) };
    let Some(provider) = RunProvider::ALL.into_iter().find(|p| p.id() == launch.agent).filter(|p| launchable().contains(p)) else {
        return fail(request, CompanionError::BadRequest);
    };
    let Some(words) = CompanionPolicy::clean_message(&launch.task) else { return fail(request, CompanionError::BadRequest) };
    // Pictures from the phone go to the agent as paths below the words, as from the composer.
    let asked = CompanionRequest { text: Some(words), ..request.clone() };
    let Some(task) = rd::message(&asked, &images_folder()) else { return fail(request, CompanionError::BadRequest) };
    let settings = settings(app);
    // Only a folder the user already worked in: the phone cannot point an agent at an arbitrary path.
    let project = paths::normalize(&launch.project);
    if !projects(&settings).contains(&project) {
        return fail(request, CompanionError::NotAllowedFromPhone);
    }
    let capabilities = provider.capabilities();
    let plan = launch.plan && capabilities.plan_mode;
    let choices = settings.folder_choices.get(&project);
    let agent_choice = choices.and_then(|c| c.agents.get(provider.id()));
    let profile = agent_choice.map(|c| c.profile_id.clone()).filter(|p| !p.is_empty()).unwrap_or_else(|| {
        app.try_state::<AgentsState>().map(|a| lock(&a.profiles).preferred(provider.kind()).id).unwrap_or_else(|| provider.id().into())
    });
    // A model from the phone only when it is one the composer offers this agent; else the remembered one.
    let model = match &launch.model {
        Some(m) if models(provider, &settings).contains(m) => m.clone(),
        _ => agent_choice.map(|c| c.model.clone()).unwrap_or_else(|| settings.model(provider)),
    };
    let preferred =
        choices.map(|c| c.permission).filter(|p| capabilities.policies.contains(p)).unwrap_or_else(|| settings.permission(provider));
    let title: String = launch.title.as_deref().unwrap_or_default().trim().chars().filter(|c| !c.is_control()).take(80).collect();
    let mut config = NewRunConfig {
        title: title.clone(),
        task: task.clone(),
        provider,
        profile_id: profile,
        model,
        effort: agent_choice.and_then(|c| c.effort.clone()).or_else(|| settings.default_efforts.get(provider.id()).cloned()),
        mode: if plan { ExecutionMode::Plan } else { ExecutionMode::Agent },
        permission: rd::phone_permission(provider, preferred, plan),
        project_path: project.clone(),
        worktree_root: settings.worktree_root.clone(),
        isolation: IsolationMode::Folder,
        ..Default::default()
    };
    let worktree = launch.worktree;
    let m = manager.clone();
    let outcome = blocking(move || -> Result<Uuid, Option<String>> {
        if worktree {
            let info = m.inspect_project(&project);
            if !m.git_available() || info.repo_root.is_none() || !info.has_commits {
                return Err(None);
            }
            config.isolation = IsolationMode::Worktree;
            config.base_branch = match info.default_base.filter(|b| info.branches.contains(b)) {
                Some(base) => base,
                None => info.current_branch.or_else(|| info.branches.first().cloned()).unwrap_or_default(),
            };
            config.branch_name = nook_core::workspace::models::branch_name(&task, Uuid::new_v4());
        }
        // A folder another session works in is refused, as in the composer; the phone can pick a worktree instead.
        m.start(config, false).map_err(Some)
    })
    .await
    .unwrap_or(Err(Some(String::new())));
    let id = match outcome {
        Ok(id) => id,
        Err(None) => return fail(request, CompanionError::BadRequest),
        Err(Some(message)) => return fail_with(request, CompanionError::Failed, message),
    };
    crate::workspace::automation::title_new_session(app, id, !title.is_empty());
    {
        let mut list = STARTED.lock().unwrap_or_else(|e| e.into_inner());
        list.push_back((request.id.clone(), id.to_string()));
        if list.len() > 64 {
            list.pop_front();
        }
    }
    audit(app, "start", &format!("{} · {}", provider.display_name(), manager.run(id).map(|r| r.title).unwrap_or_default()));
    CompanionResponse { sessions: Some(listed(app).await), created: Some(id.to_string()), ..CompanionResponse::success(&request.id) }
}

// MARK: A session's conversation

/// A session's conversation (`before`: the page older than that entry): a session Nook runs, or the transcript of an
/// agent in a terminal. `None` for a session that is gone.
async fn timeline_entries(app: &AppHandle, manager: Arc<Manager>, session: &str, before: Option<String>) -> Option<Vec<TimelineEntry>> {
    if session.starts_with(HUB_PREFIX) {
        let found = hub_session(app, session)?;
        let date = seconds(found.updated.or(found.started));
        let path = found.transcript_path;
        return blocking(move || {
            let messages = if path.is_empty() {
                vec![]
            } else {
                nook_core::agents::transcript::recent(&path, nook_core::agents::transcript::FULL_LIMIT)
            };
            rd::transcript_page(&messages, date, before.as_deref())
        })
        .await;
    }
    let id = Uuid::parse_str(session).ok().filter(|id| manager.run(*id).is_some())?;
    // Off the runtime: a timeline that is not in memory yet comes from disk.
    blocking(move || rd::timeline_page(&manager.timeline(id), before.as_deref())).await
}

async fn timeline(app: &AppHandle, request: &CompanionRequest, manager: Arc<Manager>) -> CompanionResponse {
    let Some(session) = request.session.clone() else { return fail(request, CompanionError::UnknownSession) };
    // `item`: the oldest entry the phone has, and it wants the page before it.
    let Some(entries) = timeline_entries(app, manager, &session, request.item.clone()).await else {
        return fail(request, CompanionError::UnknownSession);
    };
    CompanionResponse {
        timeline: json(&entries),
        timeline_session: Some(session),
        timeline_before: request.item.clone(),
        ..CompanionResponse::success(&request.id)
    }
}

/// One entry of a session's conversation in full, for an entry the timeline clipped.
async fn entry(app: &AppHandle, request: &CompanionRequest, manager: Arc<Manager>) -> CompanionResponse {
    let (Some(session), Some(item)) = (request.session.clone(), request.item.clone()) else {
        return fail(request, CompanionError::BadRequest);
    };
    let text = if session.starts_with(HUB_PREFIX) {
        let Some(found) = hub_session(app, &session) else { return fail(request, CompanionError::UnknownSession) };
        let path = found.transcript_path;
        blocking(move || {
            if path.is_empty() {
                return None;
            }
            let messages = nook_core::agents::transcript::recent(&path, nook_core::agents::transcript::FULL_LIMIT);
            messages.into_iter().find(|m| m.id == item).map(|m| m.text)
        })
        .await
        .flatten()
    } else {
        let Some(id) = Uuid::parse_str(&session).ok().filter(|id| manager.run(*id).is_some()) else {
            return fail(request, CompanionError::UnknownSession);
        };
        blocking(move || manager.timeline(id).into_iter().find(|e| rd::same_id(e, &item)).map(|e| e.text)).await.flatten()
    };
    let Some(text) = text else { return fail(request, CompanionError::UnknownItem) };
    CompanionResponse { entry_text: Some(rd::clip(&text, TimelineEntry::FULL_LIMIT)), ..CompanionResponse::success(&request.id) }
}

// MARK: Older sessions

/// Older sessions than the live list holds, a page at a time, or every session that matches the words of `text`.
async fn history(request: &CompanionRequest, manager: Arc<Manager>) -> CompanionResponse {
    let query = rd::clean_query(request.text.as_deref());
    let cursor = request.item.clone();
    let page = blocking(move || {
        let mut runs: Vec<WorkspaceRun> = manager.runs().into_iter().filter(|r| !r.archived).collect();
        runs.sort_by_key(|r| std::cmp::Reverse(r.updated_at));
        let candidates: Vec<WorkspaceRun> = if query.is_empty() {
            runs.into_iter().skip(rd::LIVE_COUNT).collect()
        } else {
            runs.into_iter()
                .filter(|r| {
                    let folder = sessions::folder(&r.working_directory);
                    rd::matches_query(&query, &[&r.title, &folder, r.branch.as_deref().unwrap_or_default(), r.provider.display_name()])
                })
                .collect()
        };
        let (page, next) = rd::history_page(
            &candidates,
            |r| r.updated_at.timestamp_millis() as f64 / 1000.0,
            |r| r.id.to_string(),
            cursor.as_deref(),
            rd::PAGE_SIZE,
        );
        // Only the runs of one page become digests, so a long history costs nothing extra.
        let list = page
            .iter()
            .map(|run| sessions::run_session(run, &manager.permissions(run.id), &manager.questions(run.id), &manager.last_answer(run.id)))
            .collect();
        (server::digests(list), next)
    })
    .await;
    let Some((list, next)) = page else { return fail(request, CompanionError::Failed) };
    CompanionResponse { sessions: Some(list), cursor: next, ..CompanionResponse::success(&request.id) }
}

// MARK: Managing a session

/// What the phone may do to a session, as the Agents list offers it: rename it and archive it once it rests; end an
/// agent in a terminal (it saves its conversation).
async fn manage(app: &AppHandle, request: &CompanionRequest, manager: Arc<Manager>) -> CompanionResponse {
    let (Some(session), Some(action)) = (request.session.as_deref(), request.item.as_deref()) else {
        return fail(request, CompanionError::BadRequest);
    };
    if session.starts_with(HUB_PREFIX) {
        if action != "end" {
            return fail(request, CompanionError::NotAllowedFromPhone);
        }
        let Some(found) = hub_session(app, session) else { return fail(request, CompanionError::UnknownSession) };
        {
            let Some(agents) = app.try_state::<AgentsState>() else { return fail(request, CompanionError::Failed) };
            let Some(pid) = agents.hub.process_id(&found.id) else { return fail(request, CompanionError::NotAllowedFromPhone) };
            if !nook_core::agents::scanner::terminate(pid) {
                return fail(request, CompanionError::Failed);
            }
            agents.hub.forget(&found.id);
        }
        audit(app, "end", session);
        return CompanionResponse { sessions: Some(listed(app).await), ..CompanionResponse::success(&request.id) };
    }
    let Some(run) = run_of(&manager, session) else { return fail(request, CompanionError::UnknownSession) };
    if !rd::run_actions(&run).iter().any(|a| a == action) {
        return fail(request, CompanionError::NotAllowedFromPhone);
    }
    match action {
        "rename" => {
            let Some(title) = CompanionPolicy::clean_message(request.text.as_deref().unwrap_or_default()) else {
                return fail(request, CompanionError::BadRequest);
            };
            manager.rename(run.id, &title.replace(['\n', '\t'], " "));
        }
        "archive" => manager.set_archived(run.id, true),
        _ => return fail(request, CompanionError::NotAllowedFromPhone),
    }
    audit(app, action, &run.title);
    CompanionResponse { sessions: Some(listed(app).await), ..CompanionResponse::success(&request.id) }
}

// MARK: A message that steers, or comes with pictures

/// A message with `steer` or pictures (a plain one the server sends itself). While the session works: into the running
/// turn when the phone asks to steer and the agent can take it, else in line for after the turn. The server audits it.
async fn send(app: &AppHandle, request: &CompanionRequest, manager: Arc<Manager>) -> CompanionResponse {
    let Some(session) = request.session.as_deref() else { return fail(request, CompanionError::UnknownSession) };
    if let Some(key) = session.strip_prefix(HUB_PREFIX) {
        let Some(found) = hub_session(app, session) else { return fail(request, CompanionError::UnknownSession) };
        if !sessions::can_continue_in_nook(&found) {
            return fail(request, CompanionError::NotAllowedFromPhone);
        }
        // Continued in Nook with the pictures, as the Mac does (`CompanionAgents.send`); steering a terminal is not.
        let asked = request.clone();
        let Some(text) = blocking(move || rd::message(&asked, &images_folder())).await.flatten() else {
            return fail(request, CompanionError::BadRequest);
        };
        return match crate::commands::workspace::continue_live(app, key, Some(text), false).await {
            Ok(_) => CompanionResponse {
                sessions: Some(listed(app).await),
                message: Some("sent".into()),
                ..CompanionResponse::success(&request.id)
            },
            Err(message) => fail_with(request, CompanionError::NotAllowedFromPhone, message),
        };
    }
    let Some(run) = run_of(&manager, session) else { return fail(request, CompanionError::UnknownSession) };
    let asked = request.clone();
    let steer = request.steer == Some(true);
    let outcome = blocking(move || -> Result<&'static str, Option<String>> {
        let text = rd::message(&asked, &images_folder()).ok_or(None)?;
        if steer && manager.steer(run.id, &text) {
            return Ok("steered");
        }
        let busy = run.status.is_active() || manager.is_running(run.id);
        manager.send(run.id, &text).map_err(Some)?;
        Ok(if busy { "queued" } else { "sent" })
    })
    .await
    .unwrap_or(Err(Some(String::new())));
    match outcome {
        Ok(outcome) => CompanionResponse {
            sessions: Some(listed(app).await),
            message: Some(outcome.into()),
            ..CompanionResponse::success(&request.id)
        },
        Err(None) => fail(request, CompanionError::BadRequest),
        Err(Some(message)) => fail_with(request, CompanionError::Failed, message),
    }
}

// MARK: What a session changed

/// Every file a session changed in its folder, the most changed first, with its patch while they fit in one answer.
async fn diff(app: &AppHandle, request: &CompanionRequest, manager: Arc<Manager>) -> CompanionResponse {
    let Some(folder) = request.session.as_deref().and_then(|s| session_folder(app, &manager, s)) else {
        return fail(request, CompanionError::UnknownSession);
    };
    let files = blocking(move || {
        let Some(git) = manager.git().filter(|_| !folder.is_empty()) else { return vec![] };
        let Ok(status) = git.status(&folder) else { return vec![] };
        rd::diff_digests(status.files, |file| git.diff(&folder, file).ok())
    })
    .await
    .unwrap_or_default();
    CompanionResponse { diff: json(&files), ..CompanionResponse::success(&request.id) }
}

// MARK: A session's terminals and folder

/// The terminals of a session's folder on this computer, with their last lines.
fn terminals(app: &AppHandle, request: &CompanionRequest, manager: &Manager) -> CompanionResponse {
    let Some(folder) = request.session.as_deref().and_then(|s| session_folder(app, manager, s)).filter(|f| !f.is_empty()) else {
        return fail(request, CompanionError::UnknownSession);
    };
    let Some(ws) = app.try_state::<WorkspaceState>() else { return fail(request, CompanionError::Failed) };
    let list: Vec<TerminalDigest> = ws
        .terminals
        .in_folder(&folder)
        .into_iter()
        .map(|t| TerminalDigest {
            output: ws.terminals.output(&t.id, rd::MAX_TERMINAL_LINES).unwrap_or_default(),
            id: t.short_id,
            title: t.title,
            running: t.running,
        })
        .collect();
    CompanionResponse { terminals: json(&rd::fitting(list)), ..CompanionResponse::success(&request.id) }
}

fn resolve(relative: &str, folder: &str) -> Option<std::path::PathBuf> {
    rd::resolve_in(relative, folder, |p| std::fs::canonicalize(p).ok())
}

/// One folder or file of a session's folder on this computer.
async fn files(app: &AppHandle, request: &CompanionRequest, manager: &Manager) -> CompanionResponse {
    let Some(folder) = request.session.as_deref().and_then(|s| session_folder(app, manager, s)).filter(|f| !f.is_empty()) else {
        return fail(request, CompanionError::UnknownSession);
    };
    let relative = request.item.clone().unwrap_or_default();
    let digest = blocking(move || {
        let path = resolve(&relative, &folder)?;
        let meta = std::fs::metadata(&path).ok()?;
        if meta.is_dir() {
            let mut names: Vec<String> =
                std::fs::read_dir(&path).ok()?.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned()).collect();
            names.sort();
            // A folder of a million files must not cost a million lookups.
            let entries = names
                .into_iter()
                .take(rd::MAX_ENTRIES * 2)
                .map(|name| {
                    let meta = std::fs::metadata(path.join(&name)).ok();
                    let is_folder = meta.as_ref().is_some_and(|m| m.is_dir());
                    FolderEntry { size: if is_folder { None } else { meta.map(|m| m.len()) }, is_folder, name }
                })
                .collect();
            return Some(rd::listing(&relative, entries));
        }
        // Opening a named pipe or a device would wait forever.
        if !meta.is_file() {
            return None;
        }
        use std::io::Read;
        let mut data = Vec::new();
        std::fs::File::open(&path).ok()?.take(rd::MAX_TEXT_BYTES as u64 + 1).read_to_end(&mut data).ok()?;
        Some(rd::file_digest(&relative, &data))
    })
    .await
    .flatten();
    let Some(digest) = digest else { return fail(request, CompanionError::NotAllowedFromPhone) };
    CompanionResponse { folder: json(&digest), ..CompanionResponse::success(&request.id) }
}

/// A piece of one file of a session's folder, for the phone to preview it: the same rules as `files`, and no file over
/// `FileChunk::MAX_FILE_BYTES`.
async fn file_data(app: &AppHandle, request: &CompanionRequest, manager: &Manager) -> CompanionResponse {
    let Some(folder) = request.session.as_deref().and_then(|s| session_folder(app, manager, s)).filter(|f| !f.is_empty()) else {
        return fail(request, CompanionError::UnknownSession);
    };
    let relative = request.item.clone().unwrap_or_default();
    let offset: i64 = request.text.as_deref().unwrap_or("0").trim().parse().unwrap_or(-1);
    let asked = relative.clone();
    let read = blocking(move || -> Result<FileChunk, CompanionError> {
        if asked.is_empty() {
            return Err(CompanionError::NotAllowedFromPhone);
        }
        let path = resolve(&asked, &folder).ok_or(CompanionError::NotAllowedFromPhone)?;
        let meta = std::fs::metadata(&path).map_err(|_| CompanionError::NotAllowedFromPhone)?;
        // Opening a named pipe or a device would wait forever.
        if !meta.is_file() {
            return Err(CompanionError::NotAllowedFromPhone);
        }
        let total = meta.len();
        let range = FileChunk::range(offset, total).ok_or(CompanionError::BadRequest)?;
        use std::io::{Read, Seek, SeekFrom};
        let mut file = std::fs::File::open(&path).map_err(|_| CompanionError::NotAllowedFromPhone)?;
        file.seek(SeekFrom::Start(range.start)).map_err(|_| CompanionError::Failed)?;
        let mut data = Vec::new();
        file.take(range.end - range.start).read_to_end(&mut data).map_err(|_| CompanionError::Failed)?;
        Ok(FileChunk { path: asked, offset: range.start, total, data: base64::engine::general_purpose::STANDARD.encode(data) })
    })
    .await
    .unwrap_or(Err(CompanionError::Failed));
    match read {
        Ok(chunk) => {
            if chunk.offset == 0 {
                audit(app, "file_preview", &relative);
            }
            CompanionResponse { file_chunk: json(&chunk), ..CompanionResponse::success(&request.id) }
        }
        // A file over the limit says so, so the phone can tell it from one it may not see.
        Err(CompanionError::BadRequest) => fail_with(request, CompanionError::BadRequest, "tooLarge"),
        Err(error) => fail(request, error),
    }
}
