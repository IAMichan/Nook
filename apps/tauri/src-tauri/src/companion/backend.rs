//! De sessies voor de companion-server: wat Nook zelf draait (de werkruimte) en wat via hooks binnenkomt (de hub),
//! zoals `CompanionServer.digests` en `CompanionNotifier` op de Mac. Een actie van de telefoon gaat langs dezelfde
//! weg als de knoppen in de balk.

use async_trait::async_trait;
use nook_core::agents::hub::HubEvent;
use nook_core::agents::models::{ApprovalDecision, ApprovalOrigin};
use nook_core::companion::push::{PushEvent, PushKind};
use nook_core::companion::sessions::{self, HUB_PREFIX};
use nook_core::companion::{BackendSession, CompanionBackend};
use nook_core::workspace::manager::ManagerEvent;
use nook_core::workspace::models::{RunStatus, WorkspaceRun};
use tauri::{AppHandle, Manager as _};
use uuid::Uuid;

use super::Companion;
use crate::agents::AgentsState;
use crate::workspace::WorkspaceState;

/// Zoveel sessies stuurt de server hooguit; meer tijdlijnen hoeven we dus niet te lezen.
const MAX_RUNS: usize = 25;

pub struct AppBackend {
    app: AppHandle,
}

impl AppBackend {
    pub fn new(app: AppHandle) -> Self {
        Self { app }
    }

    fn run_id(session: &str) -> Result<Uuid, String> {
        Uuid::parse_str(session).map_err(|_| "Deze sessie bestaat niet meer.".to_string())
    }

    fn workspace(&self) -> Result<tauri::State<'_, WorkspaceState>, String> {
        self.app.try_state::<WorkspaceState>().ok_or_else(|| "De werkruimte is er nog niet.".into())
    }

    fn hub(&self) -> Result<tauri::State<'_, AgentsState>, String> {
        self.app.try_state::<AgentsState>().ok_or_else(|| "De agents zijn er nog niet.".into())
    }
}

/// Alle sessies die niet gearchiveerd zijn, op de achtergrond gelezen (een tijdlijn kan van schijf komen).
fn collect(app: &AppHandle) -> Vec<BackendSession> {
    let mut list = Vec::new();
    if let Some(ws) = app.try_state::<WorkspaceState>() {
        let manager = &ws.manager;
        let mut runs: Vec<WorkspaceRun> = manager.runs().into_iter().filter(|r| !r.archived).collect();
        runs.sort_by_key(|r| std::cmp::Reverse(r.updated_at));
        for run in runs.into_iter().take(MAX_RUNS) {
            let answer = manager.last_answer(run.id);
            list.push(sessions::run_session(&run, &manager.permissions(run.id), &manager.questions(run.id), &answer));
        }
    }
    if let Some(agents) = app.try_state::<AgentsState>() {
        let (approvals, questions) = (agents.hub.approvals(), agents.hub.questions());
        list.extend(agents.hub.sessions().iter().map(|s| sessions::hub_session(s, &approvals, &questions)));
    }
    list
}

#[async_trait]
impl CompanionBackend for AppBackend {
    async fn sessions(&self) -> Vec<BackendSession> {
        let app = self.app.clone();
        tauri::async_runtime::spawn_blocking(move || collect(&app)).await.unwrap_or_default()
    }

    async fn decide(&self, session: &str, item: &str, allow: bool) -> Result<(), String> {
        let decision = if allow { ApprovalDecision::Allow } else { ApprovalDecision::Deny };
        if session.starts_with(HUB_PREFIX) {
            self.hub()?.hub.decide(item, decision);
            return Ok(());
        }
        Self::run_id(session)?;
        crate::workspace::decide_approval(&self.app, &format!("run-{item}"), decision)
    }

    async fn answer(&self, session: &str, item: &str, text: &str) -> Result<(), String> {
        let selections = vec![vec![text.to_string()]];
        if session.starts_with(HUB_PREFIX) {
            self.hub()?.hub.answer_question(item, &selections);
            return Ok(());
        }
        let run = Self::run_id(session)?;
        crate::workspace::answer_question(&self.app, &format!("runq:{run}:{item}"), &selections)
    }

    async fn send(&self, session: &str, text: &str) -> Result<(), String> {
        if session.starts_with(HUB_PREFIX) {
            return Err("Deze sessie draait in een terminal; typ je bericht daar.".into());
        }
        let run = Self::run_id(session)?;
        // Bezig? Dan in de wachtrij, zoals in de werkruimte.
        self.workspace()?.manager.send(run, text)
    }

    async fn stop(&self, session: &str) -> Result<(), String> {
        if session.starts_with(HUB_PREFIX) {
            return Err("Deze sessie draait in een terminal; stop hem daar.".into());
        }
        let run = Self::run_id(session)?;
        let ws = self.workspace()?;
        if ws.manager.run(run).is_none() {
            return Err("Deze sessie bestaat niet meer.".into());
        }
        ws.manager.stop(run);
        Ok(())
    }
}

// MARK: Pushmeldingen

fn seconds(date: chrono::DateTime<chrono::Utc>) -> i64 {
    date.timestamp()
}

/// Twee minuten niets gedaan, of het scherm is vergrendeld.
fn away(app: &AppHandle) -> bool {
    let idle = app.try_state::<crate::services::Services>().map(|s| s.platform.screen.idle_seconds()).unwrap_or_default();
    idle >= 120.0 || screen_locked()
}

/// Op Linux zegt logind of de sessie vergrendeld is; elders telt alleen de tijd sinds de laatste invoer.
fn screen_locked() -> bool {
    #[cfg(target_os = "linux")]
    {
        let Some(session) = std::env::var("XDG_SESSION_ID").ok().filter(|s| !s.is_empty()) else { return false };
        std::process::Command::new("loginctl")
            .args(["show-session", &session, "-p", "LockedHint", "--value"])
            .output()
            .is_ok_and(|o| String::from_utf8_lossy(&o.stdout).trim() == "yes")
    }
    #[cfg(not(target_os = "linux"))]
    false
}

fn send(app: &AppHandle, event: PushEvent, turn: i64) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let away = tauri::async_runtime::spawn_blocking({
            let app = app.clone();
            move || away(&app)
        })
        .await
        .unwrap_or(false);
        let Some(companion) = app.try_state::<Companion>() else { return };
        if let Some(skip) = companion.server.notify(event, turn, away).await {
            log::debug!("Companion: geen melding ({skip:?})");
        }
    });
}

/// Een nieuwe goedkeuring of vraag, of een klare beurt in een sessie die Nook draait.
pub fn on_workspace_event(app: &AppHandle, event: &ManagerEvent) {
    match event {
        ManagerEvent::Approval(approval) => {
            let ApprovalOrigin::Run { run_id, request_id } = &approval.origin else { return };
            let app2 = app.clone();
            let (run_id, request_id) = (run_id.clone(), request_id.clone());
            let agent = approval.agent_name.clone();
            let title = approval.project.clone();
            // De invoer van de tool staat in de manager; die is hier misschien nog bezet.
            tauri::async_runtime::spawn(async move {
                let Ok(run) = Uuid::parse_str(&run_id) else { return };
                let can_allow = app2
                    .try_state::<WorkspaceState>()
                    .and_then(|ws| ws.manager.permissions(run).into_iter().find(|p| p.id == request_id))
                    .is_some_and(|p| sessions::can_allow_input(&p.tool, &p.input));
                let event = PushEvent { kind: PushKind::Approval, session: run_id, item: Some(request_id), agent, title, can_allow };
                send(&app2, event, 0);
            });
        }
        ManagerEvent::Question(question) => {
            let Some((run, item)) = question.id.strip_prefix("runq:").and_then(|r| r.split_once(':')) else { return };
            let event = PushEvent {
                kind: PushKind::Question,
                session: run.into(),
                item: Some(item.into()),
                agent: question.agent_name.clone(),
                title: question.project.clone(),
                can_allow: question.items.len() == 1,
            };
            send(app, event, 0);
        }
        ManagerEvent::TurnFinished(run, _) => {
            let kind = match run.status {
                RunStatus::Stopped => return,
                RunStatus::Failed if run.limited_at.is_some() => PushKind::Limited,
                RunStatus::Failed => PushKind::Failed,
                _ => PushKind::Finished,
            };
            let event = PushEvent {
                kind,
                session: run.id.to_string(),
                item: None,
                agent: run.provider.display_name().into(),
                title: run.title.clone(),
                can_allow: false,
            };
            send(app, event, seconds(run.updated_at));
        }
        _ => {}
    }
}

/// Hetzelfde voor sessies in een terminal of editor (via hooks).
pub fn on_hub_event(app: &AppHandle, event: &HubEvent) {
    let event = match event {
        HubEvent::Approval(r) => {
            let event = PushEvent {
                kind: PushKind::Approval,
                session: format!("{HUB_PREFIX}{}", r.session_key),
                item: Some(r.id.clone()),
                agent: r.agent_name.clone(),
                title: r.project.clone(),
                can_allow: sessions::hub_can_allow(r),
            };
            (event, 0)
        }
        HubEvent::Question(q) => {
            let event = PushEvent {
                kind: PushKind::Question,
                session: format!("{HUB_PREFIX}{}", q.session_key),
                item: Some(q.id.clone()),
                agent: q.agent_name.clone(),
                title: q.project.clone(),
                can_allow: q.items.len() == 1,
            };
            (event, 0)
        }
        HubEvent::Attention(s) => {
            let kind = match s.status {
                nook_core::agents::models::AgentStatus::Done => PushKind::Finished,
                nook_core::agents::models::AgentStatus::Failed => PushKind::Failed,
                _ => return,
            };
            let event = PushEvent {
                kind,
                session: format!("{HUB_PREFIX}{}", s.id),
                item: None,
                agent: s.name.clone(),
                title: s.project.clone(),
                can_allow: false,
            };
            (event, s.updated.map(seconds).unwrap_or_default())
        }
        _ => return,
    };
    send(app, event.0, event.1);
}
