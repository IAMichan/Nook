//! De werkruimte in de app: sessies die Nook zelf draait, git, terminals, de browser en de brug voor agents.
//! Events naar de interface: `workspace-changed`, `workspace-timeline` (run-id), en via de agents-events
//! `agent-approval`, `agent-approval-gone`, `agent-question`, `agent-question-gone` en `agent-attention`.

pub mod automation;
#[cfg(desktop)]
pub mod bridge;
pub mod bridge_cli;
#[cfg(desktop)]
pub mod browser;
pub mod clones;
pub mod nook_runs;
#[cfg(desktop)]
pub mod snapshot;
#[cfg(desktop)]
pub mod terminals;

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use nook_core::agents::models::{AgentApproval, AgentSession, AgentStatus, ApprovalDecision, QuestionRequest};
use nook_core::agents::profiles::AgentProfile;
use nook_core::workspace::bridge::BridgeLaunch;
use nook_core::workspace::guest_shares::{GuestShares, GuestSharesCallbacks};
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
    pub guest_shares: Arc<GuestShares>,
    pub governor: Arc<nook_core::workspace::governor::AgentGovernor>,
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
            let found = nook_core::agents::find_executable(provider.kind()).map(|p| p.to_string_lossy().into_owned());
            nook_core::workspace::driver::session_executable(provider, found)
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
    let auto_pull_app = app.clone();
    let auto_pull_settings = settings.clone();
    let support_dir = nook_core::paths::support_directory();
    let directory = support_dir.join("workspace");
    let governor_record = directory.join("paused-groups.json");
    let manager = Manager::new(directory, hooks, runtime.clone(), move |event| on_event(&handle, event));
    let hot_app = app.clone();
    let emit_app = app.clone();
    let governor = nook_core::workspace::governor::AgentGovernor::new(
        manager.clone(),
        runtime.clone(),
        governor_record,
        Box::new(move || {
            hot_app.try_state::<crate::services::Services>().is_some_and(|_| crate::services::energy::view(&hot_app).signals.hot)
        }),
        Box::new(move |throttles| {
            let _ = emit_app.emit("agent-governor-changed", &throttles);
        }),
    );
    let release_gov = governor.clone();
    manager.set_before_stop(move |pid| release_gov.release_agent(pid));
    if desktop {
        governor.start();
    }
    let exe_app = app.clone();
    manager.set_account_executable(move |profile_id| {
        let agents = exe_app.try_state::<AgentsState>()?;
        let path = lock(&agents.profiles).profile(profile_id)?.executable_override();
        path
    });
    let args_app = app.clone();
    manager.set_account_arguments(move |profile_id| {
        let Some(agents) = args_app.try_state::<AgentsState>() else { return Vec::new() };
        let args = lock(&agents.profiles).profile(profile_id).map(|p| p.launch_arguments()).unwrap_or_default();
        args
    });
    let oc_settings = settings.clone();
    manager.set_open_code_server(move || lock(&oc_settings).open_code_server);
    if let Some(services) = app.try_state::<crate::services::Services>() {
        manager.recap.set(services.recap.clone());
    }
    let guest_relay_app = app.clone();
    let guest_read_app = app.clone();
    let guest_write_app = app.clone();
    let guest_remove_app = app.clone();
    let guest_emit_app = app.clone();
    let guest_shares = GuestShares::new(
        manager.clone(),
        runtime,
        support_dir.join("guest-files"),
        GuestSharesCallbacks {
            relay_url: Box::new(move || {
                #[cfg(desktop)]
                {
                    guest_relay_app
                        .try_state::<crate::companion::Companion>()
                        .and_then(|c| crate::companion::current_relay(c.server.store()))
                }
                #[cfg(not(desktop))]
                {
                    let _ = &guest_relay_app;
                    None
                }
            }),
            read_secret: Box::new(move |account| guest_read_app.try_state::<AppState>().and_then(|s| s.secrets.read(account))),
            write_secret: Box::new(move |account, value| {
                if let Some(s) = guest_write_app.try_state::<AppState>() {
                    let _ = s.secrets.write(account, value);
                }
            }),
            remove_secret: Box::new(move |account| {
                if let Some(s) = guest_remove_app.try_state::<AppState>() {
                    let _ = s.secrets.remove(account);
                }
            }),
            on_change: Box::new(move || {
                let _ = guest_emit_app.emit("guest-shares-changed", ());
            }),
        },
    );
    app.manage(WorkspaceState {
        manager: manager.clone(),
        guest_shares: guest_shares.clone(),
        governor,
        settings,
        #[cfg(desktop)]
        terminals: Default::default(),
        #[cfg(desktop)]
        browser: Default::default(),
        #[cfg(desktop)]
        bridge: Default::default(),
    });
    guest_shares.start();
    #[cfg(desktop)]
    if desktop {
        let script_app = app.clone();
        manager.set_script_runner(move |folder, command, title| {
            let state = script_app.try_state::<WorkspaceState>()?;
            let info = state.terminals.open(&script_app, folder, Some(command), Some(title), None).ok()?;
            let id = info.id;
            let poll_app = script_app.clone();
            Some(Box::new(move || poll_app.try_state::<WorkspaceState>().and_then(|ws| ws.terminals.find(&id)).is_some_and(|t| t.running)))
        });
        bridge::listen(app);
    }
    automation::setup(app);
    // Wegschrijven als er iets veranderde, en de worktrees af en toe opnieuw lezen.
    tauri::async_runtime::spawn(async move {
        let mut tick = 0u64;
        let mut last_auto_pull: std::collections::HashMap<String, std::time::Instant> = std::collections::HashMap::new();
        loop {
            tokio::time::sleep(Duration::from_secs(1)).await;
            tick += 1;
            // Serializing and writing a busy run's timeline is disk work; it does not belong on a runtime worker.
            let m = manager.clone();
            let _ = tauri::async_runtime::spawn_blocking(move || m.flush()).await;
            if tick % 60 == 5 {
                let m = manager.clone();
                let _ = tauri::async_runtime::spawn_blocking(move || m.refresh_worktrees()).await;
            }
            if tick % 30 == 10 {
                manager.check_idle_compactions();
            }
            // Auto-pull default branches roughly every 15 minutes per repo, when enabled globally or per project.
            if tick % 30 == 15 {
                let global_auto_pull =
                    auto_pull_app.try_state::<AppState>().map(|s| s.settings().worktrees.auto_pull_default_branch).unwrap_or(false);
                let due: Vec<String> = {
                    let ws = lock(&auto_pull_settings);
                    if !nook_core::workspace::source_control_rules::AutoPull::enabled_anywhere(global_auto_pull, &ws.project_overrides) {
                        Vec::new()
                    } else {
                        let now = std::time::Instant::now();
                        let interval = Duration::from_secs(nook_core::workspace::source_control_rules::AUTO_PULL_INTERVAL_SECS);
                        let mut seen = std::collections::HashSet::new();
                        let mut candidates = Vec::new();
                        for run in manager.runs() {
                            if let Some(p) = run.repo_root.as_deref().or(Some(run.project_path.as_str())) {
                                candidates.push(p.to_string());
                            }
                        }
                        candidates.extend(ws.favorite_projects.iter().cloned());
                        candidates.extend(ws.recent_projects.iter().take(12).cloned());
                        candidates
                            .into_iter()
                            .filter_map(|raw| {
                                let clean = nook_core::workspace::paths::normalize(&raw);
                                if clean.is_empty()
                                    || nook_core::workspace::scratch::is_scratch(&clean)
                                    || !seen.insert(clean.clone())
                                    || ws.is_archived_project(&clean)
                                    || !ws.auto_pull_enabled(&clean, global_auto_pull)
                                {
                                    return None;
                                }
                                let ready = last_auto_pull.get(&clean).is_none_or(|at| now.duration_since(*at) >= interval);
                                if ready {
                                    last_auto_pull.insert(clean.clone(), now);
                                    Some(clean)
                                } else {
                                    None
                                }
                            })
                            .collect()
                    }
                };
                if !due.is_empty() {
                    let working: std::collections::HashSet<String> = manager
                        .runs()
                        .into_iter()
                        .filter(|r| r.status.is_active() && r.isolation == nook_core::workspace::models::IsolationMode::Folder)
                        .map(|r| nook_core::workspace::paths::normalize(&r.working_directory))
                        .collect();
                    let m = manager.clone();
                    let _ = tauri::async_runtime::spawn_blocking(move || {
                        let Some(git) = m.git() else { return };
                        let mut done = std::collections::HashSet::new();
                        for path in due {
                            let Some(checkout) = git.main_checkout(&path) else { continue };
                            let key = nook_core::workspace::paths::normalize(&checkout);
                            if !done.insert(key.clone()) {
                                continue;
                            }
                            let busy = working
                                .iter()
                                .any(|w| *w == key || w.starts_with(&format!("{key}/")) || w.starts_with(&format!("{key}\\")));
                            let _ = git.auto_pull(&checkout, busy);
                        }
                    })
                    .await;
                }
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
        state.guest_shares.suspend();
        state.governor.release_all();
        state.manager.shutdown();
        #[cfg(desktop)]
        state.terminals.close_all();
    }
}

/// De omgeving van een account: eigen omgevingsvariabelen (ook uit de kluis), daarna `CLAUDE_CONFIG_DIR`/`CODEX_HOME`/…,
/// en bij een Claude-account met API-sleutel die sleutel uit de kluis. Rechtstreeks naar het proces; nooit gelogd of bewaard.
fn account_environment(app: &AppHandle, profile_id: &str) -> BTreeMap<String, String> {
    let Some(agents) = app.try_state::<AgentsState>() else { return BTreeMap::new() };
    let profile: Option<AgentProfile> = lock(&agents.profiles).profile(profile_id);
    let Some(profile) = profile else { return BTreeMap::new() };
    let secrets = app.state::<AppState>().secrets.clone();
    profile.launch_environment(|key| secrets.read(key))
}

fn on_event(app: &AppHandle, event: ManagerEvent) {
    #[cfg(desktop)]
    crate::companion::backend::on_workspace_event(app, &event);
    match event {
        ManagerEvent::Changed => {
            if let Some(ws) = app.try_state::<WorkspaceState>() {
                ws.guest_shares.notify_changed();
            }
            let _ = app.emit("workspace-changed", ());
            let _ = app.emit("agents-changed", ());
        }
        ManagerEvent::Timeline(id) => {
            if let Some(ws) = app.try_state::<WorkspaceState>() {
                ws.guest_shares.notify_timeline(id);
            }
            let _ = app.emit("workspace-timeline", id.to_string());
        }
        ManagerEvent::Approval(approval) => {
            let _ = app.emit("agent-approval", &approval);
            crate::agents::present_approval(app, &approval);
        }
        ManagerEvent::ApprovalGone(id) => {
            crate::agents::approval_gone(app, &id);
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
            #[cfg(desktop)]
            bridge::tasks::turn_finished(app, &run);
            if run.status == RunStatus::Stopped {
                return;
            }
            let card = attention_card(&run, &last);
            crate::agents::present_attention(app, &card);
            let _ = app.emit("agent-attention", card);
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
        launched_by: None,
    }
}

/// De GitHub-tokens voor een repository ("eigenaar/naam") uit de kluis, nooit uit een bestand: alle accounts van de
/// koppeling GitHub, het account van de eigenaar eerst (het eerste met toegang wint). Leeg als GitHub uit staat.
pub fn github_tokens(app: &AppHandle, repo: &str) -> Vec<String> {
    use nook_core::connectors::accounts;
    let Some(c) = app.try_state::<crate::connectors::Connectors>() else { return vec![] };
    if !c.env.store.is_on("github") {
        return vec![];
    }
    let owner = repo.split('/').next().unwrap_or_default();
    accounts::ordered_for_owner(accounts::accounts(&c.env.store, "github"), owner)
        .iter()
        .filter_map(|a| c.env.secret(&a.key("token")))
        .collect()
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
/// A Deny's reason reaches the agent (a bridge request has no agent to tell).
pub fn decide_approval_with_reason(app: &AppHandle, id: &str, decision: ApprovalDecision, reason: Option<&str>) -> Result<(), String> {
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
    manager.decide_with_reason(run, request, decision, reason)
}

/// `runq:<run>:<verzoek>`: het antwoord op een vraag van een sessie die Nook draait.
pub fn answer_question(app: &AppHandle, id: &str, selections: &[Vec<String>]) -> Result<(), String> {
    let gone = || "Deze vraag bestaat niet meer.".to_string();
    let rest = id.strip_prefix("runq:").ok_or_else(gone)?;
    let (run, request) = rest.split_once(':').ok_or_else(gone)?;
    let run = Uuid::parse_str(run).map_err(|_| gone())?;
    manager(app).ok_or_else(gone)?.answer_question(run, request, selections)
}
