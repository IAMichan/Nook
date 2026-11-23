//! Agents in de app: de hub die hooks ontvangt (via de lokale verbinding uit `nook_core::agents::ipc`), koppelen,
//! accounts, eerdere sessies en de terminal waarin een agent draait. Events naar de interface:
//! `agents-changed`, `agent-approval`, `agent-approval-gone`, `agent-question`, `agent-question-gone`,
//! `agent-attention` en `agent-usage`.

pub mod terminal;
pub mod updates;
pub mod usage;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use nook_core::agents::history::{HistoryResult, HistoryScanner, ProfileHome};
use nook_core::agents::hub::{AgentHub, HubEvent};
use nook_core::agents::installer::{self, Change};
use nook_core::agents::profiles::ProfileStore;
use nook_core::agents::sessions::SessionMarks;
use nook_core::agents::{ipc, scanner, AgentKind};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};

use crate::state::AppState;

/// Alles van de agents, naast `AppState`.
pub struct AgentsState {
    pub hub: Arc<AgentHub>,
    pub profiles: Mutex<ProfileStore>,
    pub marks: Mutex<SessionMarks>,
    pub history: Mutex<HistoryScanner>,
    pub last_history: Mutex<HistoryResult>,
    /// Voorgestelde wijzigingen van Koppelen, tot je op OK klikt.
    pub changes: Mutex<HashMap<String, Change>>,
    /// Wanneer de proceslijst voor het laatst gescand is.
    pub scanned: Mutex<Option<std::time::Instant>>,
}

pub fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Gone {
    id: String,
    message: Option<String>,
}

pub fn setup(app: &AppHandle) {
    let support = nook_core::paths::support_directory();
    let handle = app.clone();
    let hub = Arc::new(AgentHub::new(Some(support.clone()), move |event| on_hub_event(&handle, event)));
    if let Some(services) = app.try_state::<crate::services::Services>() {
        hub.recap.set(services.recap.clone());
    }
    app.manage(AgentsState {
        hub: hub.clone(),
        profiles: Mutex::new(ProfileStore::load(Some(support.join("agent-profiles.json")))),
        marks: Mutex::new(SessionMarks::load(Some(support.join("agent-marks.json")))),
        history: Mutex::new(HistoryScanner::default()),
        last_history: Mutex::new(HistoryResult::default()),
        changes: Mutex::new(HashMap::new()),
        scanned: Mutex::new(None),
    });
    usage::manage(app);
    if !crate::platform::capabilities().local_agents {
        return;
    }
    usage::start(app);
    install_helpers();
    let h = hub.clone();
    tauri::async_runtime::spawn(async move {
        let on_connection: Arc<dyn Fn(ipc::BoxStream) + Send + Sync> = Arc::new(move |stream| {
            tauri::async_runtime::spawn(ipc::serve_hook(h.clone(), stream));
        });
        if let Err(e) = ipc::listen(ipc::address("hub"), on_connection).await {
            log::error!("Agent-hub kon niet luisteren: {e}");
        }
    });
    // Onderhoud: wegschrijven (elke seconde als er iets veranderde), opruimen (elke minuut), processen (elke 10 s).
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let mut tick = 0u64;
        loop {
            tokio::time::sleep(Duration::from_secs(1)).await;
            tick += 1;
            hub.flush();
            if tick.is_multiple_of(60) {
                hub.prune();
            }
            if tick % 10 == 1 {
                scan(&app).await;
            }
        }
    });
}

/// Scant de proceslijst en geeft de uitkomst aan de hub.
pub async fn scan(app: &AppHandle) {
    let found = tauri::async_runtime::spawn_blocking(scanner::scan).await.unwrap_or_default();
    let state = app.state::<AgentsState>();
    *lock(&state.scanned) = Some(std::time::Instant::now());
    // Accounts die als proces draaien maar nog niet in Nook staan, komen erbij.
    let running: Vec<(AgentKind, String)> = found
        .iter()
        .filter_map(|a| AgentKind::from_agent_name(&a.name).map(|k| (k, a.home.clone())))
        .filter(|(_, h)| !h.is_empty())
        .collect();
    if !running.is_empty() && lock(&state.profiles).adopt_existing(&running) {
        let _ = app.emit("agents-changed", ());
    }
    state.hub.apply_scan(found, |agent, home| {
        let Some(target) = installer::Target::for_agent(agent) else { return false };
        let home = (!home.is_empty()).then(|| PathBuf::from(home));
        installer::state(target, home.as_deref()) == installer::State::Installed
    });
}

fn on_hub_event(app: &AppHandle, event: HubEvent) {
    #[cfg(desktop)]
    crate::companion::backend::on_hub_event(app, &event);
    match event {
        HubEvent::Changed => {
            let _ = app.emit("agents-changed", ());
        }
        HubEvent::Approval(request) => {
            let approval = nook_core::agents::models::AgentApproval::from_hook(&request);
            let _ = app.emit("agent-approval", &approval);
            present_approval(app, &approval);
        }
        HubEvent::ApprovalGone(id, message) => {
            approval_gone(app, &format!("hook-{id}"));
            let _ = app.emit("agent-approval-gone", Gone { id: format!("hook-{id}"), message });
        }
        HubEvent::Question(request) => {
            let _ = app.emit("agent-question", request);
            open_bar(app);
        }
        HubEvent::QuestionGone(id, message) => {
            let _ = app.emit("agent-question-gone", Gone { id, message });
        }
        HubEvent::Attention(session) => {
            present_attention(app, &session);
            let _ = app.emit("agent-attention", session);
        }
        HubEvent::PlanUsage => {
            let _ = app.emit("agent-usage", ());
        }
    }
}

/// Decides a permission request, wherever it came from: a hook (`hook-`), a session Nook runs (`run-`) or the MCP
/// bridge (`bridge-`).
pub fn decide(app: &AppHandle, id: &str, decision: nook_core::agents::models::ApprovalDecision) -> Result<(), String> {
    decide_with_reason(app, id, decision, None)
}

/// As `decide`; a Deny with a reason tells the agent why ("Deny with reason", as in the companion).
pub fn decide_with_reason(
    app: &AppHandle,
    id: &str,
    decision: nook_core::agents::models::ApprovalDecision,
    reason: Option<&str>,
) -> Result<(), String> {
    if let Some(request) = id.strip_prefix("hook-") {
        app.state::<AgentsState>().hub.decide_with_reason(request, decision, reason);
        return Ok(());
    }
    crate::workspace::decide_approval_with_reason(app, id, decision, reason)
}

/// A permission request reaches you (`presentApprovalCard` on the Mac): in the bar, or as a system notification with
/// Allow and Deny when you chose that for agents (Settings › Voice & sound › Notices). Show, a click, or a computer that
/// cannot show it brings up the bar, so the request is never lost.
pub fn present_approval(app: &AppHandle, approval: &nook_core::agents::models::AgentApproval) {
    use nook_core::agents::models::ApprovalOrigin;
    use nook_core::services::toast::{NoticeTarget, Toast};
    if !system_notices_for(app, &approval.agent_name, true) {
        return open_bar(app);
    }
    let target = match &approval.origin {
        ApprovalOrigin::Hook { .. } if !approval.session_key.is_empty() => NoticeTarget::Agent(approval.session_key.clone()),
        ApprovalOrigin::Run { run_id, .. } => uuid::Uuid::parse_str(run_id).map(NoticeTarget::Run).unwrap_or(NoticeTarget::Agents),
        _ => NoticeTarget::Agents,
    };
    let context =
        [approval.agent_name.as_str(), approval.project.as_str()].iter().filter(|t| !t.is_empty()).copied().collect::<Vec<_>>().join(" · ");
    let toast = Toast::approval(approval, &context, target);
    let (decide_app, show_app, fallback_app, id) = (app.clone(), app.clone(), app.clone(), approval.id.clone());
    let handlers = crate::notices::Handlers {
        decide: Some(Box::new(move |decision| {
            if let Err(e) = decide(&decide_app, &id, decision) {
                log::info!("A toast's decision did not land: {e}");
            }
        })),
        show: Some(Box::new(move || open_bar(&show_app))),
        ..Default::default()
    };
    crate::notices::post(app, toast, handlers, move || open_bar(&fallback_app));
}

/// Whether an agent's notice goes out as a system notification (Settings › Notifications › Agents), by the one rule
/// set in `notices::decide`; `urgent`: an approval or question, which always reaches you.
fn system_notices_for(app: &AppHandle, agent: &str, urgent: bool) -> bool {
    use nook_core::services::notice_rules::{NoticeDecision, NoticeSource, NoticeStyle};
    app.try_state::<crate::state::AppState>().is_some()
        && crate::notices::decide(app, NoticeSource::Agents, agent, urgent) == NoticeDecision::Show(NoticeStyle::System)
}

/// An agent that is done, failed or waits on you: as a system notification when you chose that for agents; otherwise
/// the bar shows its card (`agent-attention`). A click opens the session.
pub fn present_attention(app: &AppHandle, session: &nook_core::agents::models::AgentSession) {
    {
        use nook_core::agents::models::AgentStatus;
        use nook_core::services::notice_log::NoticeKind;
        let kind = match session.status {
            AgentStatus::Done => NoticeKind::Done,
            AgentStatus::Failed => NoticeKind::Failed,
            AgentStatus::Waiting => NoticeKind::Waiting,
            _ => NoticeKind::Info,
        };
        let context = [session.host.as_str(), session.project.as_str()].iter().filter(|t| !t.is_empty()).copied().collect::<Vec<_>>().join(" · ");
        crate::notice_history::record(app, &format!("agent:{}", session.id), kind, &session.name, &session.summary, &context, &format!("agent:{}", session.id));
    }
    if !system_notices_for(app, &session.name, false) {
        return;
    }
    if let Some(toast) = nook_core::services::toast::Toast::agent_status(session) {
        // A reply from the toast goes to the session as your next message, or into its queue while it works.
        let reply = match toast.target {
            nook_core::services::toast::NoticeTarget::Run(run) => {
                let reply_app = app.clone();
                Some(Box::new(move |text: String| {
                    let Some(ws) = reply_app.try_state::<crate::workspace::WorkspaceState>() else { return };
                    if ws.manager.send(run, &text).is_err() {
                        ws.manager.enqueue(run, &text);
                    }
                }) as Box<dyn Fn(String) + Send + Sync>)
            }
            _ => None,
        };
        crate::notices::post(app, toast, crate::notices::Handlers { reply, ..Default::default() }, || {});
    }
}

/// The request was decided elsewhere or the agent moved on: its notification goes away.
pub fn approval_gone(app: &AppHandle, id: &str) {
    crate::notices::withdraw(app, id);
}

/// Een wachtende agent opent de balk op de tab Agents; an open panel stays on its tab and asks in its compact bar.
pub fn open_bar(app: &AppHandle) {
    #[cfg(desktop)]
    crate::platform::desktop::open_bar(app, "agents-request");
    #[cfg(not(desktop))]
    let _ = app;
}

/// Zet `~/.nook/nook-hook` en `~/.nook/nook-mcp` neer: paden zonder spaties naar Nook zelf, dat in die naam als
/// hook-commando of MCP-server start. Op Linux een symbolische koppeling; op Windows een harde koppeling (of een
/// kopie op een andere schijf), omdat symbolische koppelingen daar beheerdersrechten vragen.
pub fn install_helpers() {
    let Ok(exe) = std::env::current_exe() else { return };
    let dir = nook_core::paths::dot_nook();
    for name in ["nook-hook", "nook-mcp"] {
        let link = dir.join(if cfg!(windows) { format!("{name}.exe") } else { name.to_string() });
        #[cfg(unix)]
        {
            if std::fs::read_link(&link).ok().as_deref() == Some(exe.as_path()) {
                continue;
            }
            let _ = std::fs::remove_file(&link);
            if let Err(e) = std::os::unix::fs::symlink(&exe, &link) {
                log::warn!("Kon {} niet maken: {e}", link.display());
            }
        }
        #[cfg(windows)]
        {
            let same = |a: &std::path::Path, b: &std::path::Path| {
                let (Ok(x), Ok(y)) = (std::fs::metadata(a), std::fs::metadata(b)) else { return false };
                x.len() == y.len() && x.modified().ok() == y.modified().ok()
            };
            if same(&exe, &link) {
                continue;
            }
            let _ = std::fs::remove_file(&link);
            if std::fs::hard_link(&exe, &link).is_err() {
                if let Err(e) = std::fs::copy(&exe, &link) {
                    log::warn!("Kon {} niet maken: {e}", link.display());
                }
            }
        }
        #[cfg(not(any(unix, windows)))]
        let _ = (&exe, link);
    }
}

/// De accounts als invoer voor de scan van eerdere sessies.
pub fn profile_homes(app: &AppHandle) -> Vec<ProfileHome> {
    let state = app.state::<AgentsState>();
    let secrets = app.state::<AppState>().secrets.clone();
    let profiles = lock(&state.profiles).all();
    profiles.iter().map(|p| ProfileHome::from_profile(p, p.uses_api_key() && secrets.read(&p.secret_account()).is_some())).collect()
}

/// Leest eerdere sessies, accounts en gebruik opnieuw (op de achtergrond).
pub async fn refresh_history(app: &AppHandle) -> HistoryResult {
    let homes = profile_homes(app);
    let own = nook_core::paths::brain_scratch_directory().to_string_lossy().into_owned();
    let app2 = app.clone();
    let result = tauri::async_runtime::spawn_blocking(move || {
        let state = app2.state::<AgentsState>();
        let mut scanner = lock(&state.history);
        scanner.scan(&homes, &own)
    })
    .await
    .unwrap_or_default();
    *lock(&app.state::<AgentsState>().last_history) = result.clone();
    result
}
