//! De werkruimte in de app: sessies die Nook zelf draait, git, terminals, de browser en de brug voor agents.
//! Events naar de interface: `workspace-changed`, `workspace-timeline` (run-id), en via de agents-events
//! `agent-approval`, `agent-approval-gone`, `agent-question`, `agent-question-gone` en `agent-attention`.

#[cfg(desktop)]
pub mod bridge;
pub mod bridge_cli;
#[cfg(desktop)]
pub mod browser;
#[cfg(desktop)]
pub mod terminals;

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use nook_core::agents::models::{AgentApproval, AgentSession, AgentStatus, ApprovalDecision, QuestionRequest};
use nook_core::agents::profiles::AgentProfile;
use nook_core::workspace::bridge::BridgeLaunch;
use nook_core::workspace::manager::{Hooks, Manager, ManagerEvent};
use nook_core::workspace::models::{RunStatus, WorkspaceRun};
use nook_core::workspace::settings::WorkspaceSettings;
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager as _};
use uuid::Uuid;

use crate::agents::{lock, AgentsState};
use crate::state::AppState;

pub struct WorkspaceState {
    pub manager: Arc<Manager>,
    pub settings: Arc<Mutex<WorkspaceSettings>>,
    #[cfg(desktop)]
    pub terminals: terminals::Terminals,
    #[cfg(desktop)]
    pub browser: browser::Browser,
    #[cfg(desktop)]
    pub bridge: bridge::Bridge,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Gone {
    id: String,
    message: Option<String>,
}

pub fn setup(app: &AppHandle) {
    let settings = Arc::new(Mutex::new(WorkspaceSettings::load_from(&WorkspaceSettings::file())));
    let runtime = tauri::async_runtime::block_on(async { tokio::runtime::Handle::current() });
    let desktop = crate::platform::capabilities().local_agents;
    let env_app = app.clone();
    let bridge_settings = settings.clone();
    let root_settings = settings.clone();
    let resume_settings = settings.clone();
    let hooks = Hooks {
        executable: Box::new(move |provider| {
            if !desktop {
                return None;
            }
            nook_core::agents::find_executable(provider.kind()).map(|p| p.to_string_lossy().into_owned())
        }),
        account_environment: Box::new(move |profile_id| account_environment(&env_app, profile_id)),
        bridge: Box::new(move || {
            if !desktop || !lock(&bridge_settings).agent_tools {
                return None;
            }
            Some(BridgeLaunch { script: bridge_script().to_string_lossy().into_owned() })
        }),
        worktree_root: Box::new(move || lock(&root_settings).worktree_root()),
        auto_resume_limited: Box::new(move || lock(&resume_settings).auto_resume_limited),
    };
    let handle = app.clone();
    let archive_settings = settings.clone();
    let directory = nook_core::paths::support_directory().join("workspace");
    let manager = Manager::new(directory, hooks, runtime, move |event| on_event(&handle, event));
    app.manage(WorkspaceState {
        manager: manager.clone(),
        settings,
        #[cfg(desktop)]
        terminals: Default::default(),
        #[cfg(desktop)]
        browser: Default::default(),
        #[cfg(desktop)]
        bridge: Default::default(),
    });
    #[cfg(desktop)]
    if desktop {
        bridge::listen(app);
    }
    // Wegschrijven als er iets veranderde, en de worktrees af en toe opnieuw lezen.
    tauri::async_runtime::spawn(async move {
        let mut tick = 0u64;
        loop {
            tokio::time::sleep(Duration::from_secs(1)).await;
            tick += 1;
            manager.flush();
            if tick % 60 == 5 {
                let m = manager.clone();
                let _ = tauri::async_runtime::spawn_blocking(move || m.refresh_worktrees()).await;
            }
            // Sessies die zo lang niet gebruikt zijn, gaan vanzelf naar het archief (als je dat instelde).
            if tick % 600 == 30 {
                let days = lock(&archive_settings).auto_archive_days;
                if days > 0 {
                    let limit = chrono::Utc::now() - chrono::Duration::days(days.into());
                    for run in manager.runs() {
                        if !run.archived && !run.status.is_active() && run.updated_at < limit {
                            manager.set_archived(run.id, true);
                        }
                    }
                }
            }
        }
    });
}

/// Pad van `~/.nook/nook-mcp`: Nook zelf in de stand van MCP-server (zie `cli`).
pub fn bridge_script() -> std::path::PathBuf {
    nook_core::paths::dot_nook().join(if cfg!(windows) { "nook-mcp.exe" } else { "nook-mcp" })
}

/// Bij afsluiten: alles wegschrijven en lopende agents netjes stoppen.
pub fn shutdown(app: &AppHandle) {
    if let Some(state) = app.try_state::<WorkspaceState>() {
        state.manager.shutdown();
        #[cfg(desktop)]
        state.terminals.close_all();
    }
}

/// De omgeving van een account: `CLAUDE_CONFIG_DIR`/`CODEX_HOME`/…, en bij een Claude-account met API-sleutel die
/// sleutel uit de kluis. Rechtstreeks naar het proces; nooit gelogd of bewaard.
fn account_environment(app: &AppHandle, profile_id: &str) -> BTreeMap<String, String> {
    let Some(agents) = app.try_state::<AgentsState>() else { return BTreeMap::new() };
    let profile: Option<AgentProfile> = lock(&agents.profiles).profile(profile_id);
    let Some(profile) = profile else { return BTreeMap::new() };
    let mut env = profile.environment();
    if profile.kind == nook_core::agents::AgentKind::Claude && profile.uses_api_key() {
        if let Some(key) = app.state::<AppState>().secrets.read(&profile.secret_account()).filter(|k| !k.trim().is_empty()) {
            env.insert("ANTHROPIC_API_KEY".into(), key.trim().to_string());
        }
    }
    env
}

fn on_event(app: &AppHandle, event: ManagerEvent) {
    match event {
        ManagerEvent::Changed => {
            let _ = app.emit("workspace-changed", ());
            let _ = app.emit("agents-changed", ());
        }
        ManagerEvent::Timeline(id) => {
            let _ = app.emit("workspace-timeline", id.to_string());
        }
        ManagerEvent::Approval(approval) => {
            let _ = app.emit("agent-approval", approval);
            crate::agents::open_bar(app);
        }
        ManagerEvent::ApprovalGone(id) => {
            let _ = app.emit("agent-approval-gone", Gone { id, message: None });
        }
        ManagerEvent::Question(question) => {
            let _ = app.emit("agent-question", question);
            crate::agents::open_bar(app);
        }
        ManagerEvent::QuestionGone(id) => {
            let _ = app.emit("agent-question-gone", Gone { id, message: None });
        }
        ManagerEvent::TurnFinished(run, last) => {
            if run.status == RunStatus::Stopped {
                return;
            }
            let _ = app.emit("agent-attention", attention_card(&run, &last));
        }
    }
}

/// Het kaartje "klaar" of "mislukt" in de balk voor een sessie die Nook draait.
pub fn attention_card(run: &WorkspaceRun, last: &str) -> AgentSession {
    let status = match run.status {
        RunStatus::Failed => AgentStatus::Failed,
        RunStatus::WaitingApproval => AgentStatus::Waiting,
        RunStatus::Preparing | RunStatus::Running => AgentStatus::Running,
        _ => AgentStatus::Done,
    };
    let summary = if run.status == RunStatus::Failed {
        run.status_detail.clone().unwrap_or_else(|| "De beurt is mislukt.".into())
    } else {
        nook_core::workspace::manager::attention_summary(last)
    };
    AgentSession {
        id: format!("run:{}", run.id),
        name: run.provider.display_name().into(),
        project: run.title.clone(),
        status,
        file: String::new(),
        placeholder: String::new(),
        steps: vec![],
        diff: vec![],
        cwd: run.working_directory.clone(),
        host: String::new(),
        home: String::new(),
        approval_id: None,
        question_id: None,
        lines_added: 0,
        lines_removed: 0,
        summary,
        is_linked: false,
        session_id: run.provider_session_id.clone().unwrap_or_default(),
        transcript_path: String::new(),
        last_prompt: String::new(),
        last_reply: last.to_string(),
        started: Some(run.created_at),
        updated: Some(run.updated_at),
        pid: None,
    }
}

fn manager(app: &AppHandle) -> Option<Arc<Manager>> {
    app.try_state::<WorkspaceState>().map(|s| s.manager.clone())
}

/// Toestemmingsvragen van sessies die Nook draait en van de werkruimte-brug.
pub fn pending_approvals(app: &AppHandle) -> Vec<AgentApproval> {
    let mut list = manager(app).map(|m| m.pending_approvals()).unwrap_or_default();
    #[cfg(desktop)]
    if let Some(ws) = app.try_state::<WorkspaceState>() {
        list.extend(ws.bridge.pending().iter().map(bridge::Bridge::approval));
    }
    list
}

pub fn pending_questions(app: &AppHandle) -> Vec<QuestionRequest> {
    manager(app).map(|m| m.pending_questions()).unwrap_or_default()
}

/// `run-<verzoek>`: een vraag van een sessie die Nook draait; `bridge-<verzoek>`: een verzoek via de werkruimte-brug.
pub fn decide_approval(app: &AppHandle, id: &str, decision: ApprovalDecision) -> Result<(), String> {
    let gone = || "Deze vraag bestaat niet meer.".to_string();
    #[cfg(desktop)]
    if let Some(request) = id.strip_prefix("bridge-") {
        let ws = app.try_state::<WorkspaceState>().ok_or_else(gone)?;
        let allow = matches!(decision, ApprovalDecision::Allow | ApprovalDecision::Always);
        return if ws.bridge.decide(app, request, allow) { Ok(()) } else { Err(gone()) };
    }
    let request = id.strip_prefix("run-").ok_or_else(gone)?;
    let manager = manager(app).ok_or_else(gone)?;
    let run = manager
        .pending_approvals()
        .into_iter()
        .find(|a| a.id == id)
        .and_then(|a| a.session_key.strip_prefix("run:").and_then(|r| Uuid::parse_str(r).ok()))
        .ok_or_else(gone)?;
    manager.decide(run, request, decision)
}

/// `runq:<run>:<verzoek>`: het antwoord op een vraag van een sessie die Nook draait.
pub fn answer_question(app: &AppHandle, id: &str, selections: &[Vec<String>]) -> Result<(), String> {
    let gone = || "Deze vraag bestaat niet meer.".to_string();
    let rest = id.strip_prefix("runq:").ok_or_else(gone)?;
    let (run, request) = rest.split_once(':').ok_or_else(gone)?;
    let run = Uuid::parse_str(run).map_err(|_| gone())?;
    manager(app).ok_or_else(gone)?.answer_question(run, request, selections)
}
