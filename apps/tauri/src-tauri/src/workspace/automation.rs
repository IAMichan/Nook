//! Automation in the app: scheduled tasks (the 30-second tick and the local webhook listener), automatic session
//! titles through the chosen brain, handing a session to another agent, and delegated child sessions. The logic is in
//! `nook_core::workspace::{schedule, scheduler, webhook, titles, handoff, delegation}`; this file only connects it
//! to the manager, the secret store and the brain. Event to the interface: `automation-changed`.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{Local, Utc};
use nook_core::workspace::delegation::Links;
use nook_core::workspace::handoff::HandoffStore;
use nook_core::workspace::models::RunProvider;
use nook_core::workspace::scheduler::{AutomationSettings, Scheduler, TICK_SECONDS};
use nook_core::workspace::{titles, webhook};
use tauri::{AppHandle, Emitter, Manager as _};
use uuid::Uuid;

use super::WorkspaceState;
use crate::agents::lock;
use crate::state::AppState;

#[derive(Default)]
struct Listener {
    port: u16,
    task: Option<tokio::task::JoinHandle<()>>,
    error: Option<String>,
}

pub struct AutomationState {
    pub scheduler: Arc<Scheduler>,
    pub settings: Mutex<AutomationSettings>,
    pub handoffs: HandoffStore,
    pub links: Links,
    listener: Mutex<Listener>,
}

impl AutomationState {
    pub fn settings(&self) -> AutomationSettings {
        lock(&self.settings).clone()
    }

    /// The port the webhook listener listens on now, or why it could not start.
    pub fn listener(&self) -> (Option<u16>, Option<String>) {
        let l = lock(&self.listener);
        (l.task.is_some().then_some(l.port), l.error.clone())
    }
}

/// After `workspace::setup`: loads the tasks, starts the tick and, when chosen, the webhook listener.
pub fn setup(app: &AppHandle) {
    let secrets = app.state::<AppState>().secrets.clone();
    let directory = nook_core::paths::support_directory().join("workspace");
    let scheduler = Arc::new(Scheduler::new(Scheduler::file(), secrets, Utc::now(), &Local));
    app.manage(AutomationState {
        scheduler: scheduler.clone(),
        settings: Mutex::new(AutomationSettings::load_from(&AutomationSettings::file())),
        handoffs: HandoffStore::new(&directory),
        links: Links::new(&directory),
        listener: Mutex::new(Listener::default()),
    });
    apply_listener(app);
    let handle = app.clone();
    tauri::async_runtime::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(TICK_SECONDS)).await;
            // Nothing to do without tasks: the tick then costs one look at an empty list.
            if scheduler.tasks().is_empty() {
                continue;
            }
            tick(&handle).await;
        }
    });
}

/// The user's account for an agent: the one last chosen for it, else its preferred account.
pub fn default_profile(app: &AppHandle, provider: RunProvider) -> String {
    if let Some(ws) = app.try_state::<WorkspaceState>() {
        if let Some(id) = lock(&ws.settings).default_profiles.get(provider.id()).filter(|p| !p.is_empty()) {
            return id.clone();
        }
    }
    match app.try_state::<crate::agents::AgentsState>() {
        Some(agents) => lock(&agents.profiles).preferred(provider.kind()).id,
        None => provider.id().into(),
    }
}

/// One round: end what finished, start what is due, then the webhook deliveries that wait.
pub async fn tick(app: &AppHandle) {
    let (Some(ws), Some(auto)) = (app.try_state::<WorkspaceState>(), app.try_state::<AutomationState>()) else { return };
    let manager = ws.manager.clone();
    let scheduler = auto.scheduler.clone();
    let enabled = auto.settings().scheduled_tasks;
    let app2 = app.clone();
    let before = scheduler.tasks();
    let changed = tauri::async_runtime::spawn_blocking(move || {
        let profile = |p: RunProvider| default_profile(&app2, p);
        scheduler.tick(&manager, enabled, &profile, Utc::now(), &Local);
        if enabled {
            scheduler.drain_webhooks(&manager, &profile, Utc::now(), &Local);
        }
        scheduler.tasks() != before
    })
    .await
    .unwrap_or(false);
    if changed {
        let _ = app.emit("automation-changed", ());
    }
}

/// Starts, moves or stops the webhook listener after a change of the settings. Loopback only (127.0.0.1).
pub fn apply_listener(app: &AppHandle) {
    let Some(auto) = app.try_state::<AutomationState>() else { return };
    let wanted = auto.settings().listening_port();
    {
        let mut l = lock(&auto.listener);
        if wanted == Some(l.port) && l.task.is_some() {
            return;
        }
        if let Some(task) = l.task.take() {
            task.abort();
        }
        l.port = 0;
        l.error = None;
    }
    let Some(port) = wanted else {
        let _ = app.emit("automation-changed", ());
        return;
    };
    let handle = app.clone();
    let handler: webhook::Handler = Arc::new(move |request| {
        let Some(auto) = handle.try_state::<AutomationState>() else { return (503, "unavailable".into()) };
        let answer = auto.scheduler.handle_webhook(auto.settings().scheduled_tasks, &request, Utc::now());
        if answer.0 == 202 {
            let app = handle.clone();
            tauri::async_runtime::spawn(async move { tick(&app).await });
        }
        answer
    });
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let result = webhook::listen(port, handler).await;
        let Some(auto) = app.try_state::<AutomationState>() else { return };
        {
            let mut l = lock(&auto.listener);
            match result {
                Ok((_, task)) => {
                    l.port = port;
                    l.task = Some(task);
                }
                Err(e) => l.error = Some(e.to_string()),
            }
        }
        let _ = app.emit("automation-changed", ());
    });
}

/// The address of a task's webhook while the listener is on.
pub fn webhook_url(app: &AppHandle, task: Uuid) -> Option<String> {
    let port = app.try_state::<AutomationState>()?.settings().listening_port()?;
    Some(format!("http://127.0.0.1:{port}/hooks/{task}"))
}

/// A short title for a new session from its first message, written by the chosen brain (the same path as every other
/// brain answer). The first line stays when automatic titles are off, the brain gives nothing usable, or you renamed
/// the session meanwhile. `typed`: you gave the session a name yourself.
pub fn title_new_session(app: &AppHandle, id: Uuid, typed: bool) {
    let Some(auto) = app.try_state::<AutomationState>() else { return };
    if typed || !auto.settings().auto_titles {
        return;
    }
    let Some(manager) = app.try_state::<WorkspaceState>().map(|w| w.manager.clone()) else { return };
    let Some(run) = manager.run(id) else { return };
    let state = app.state::<AppState>();
    let settings = state.settings();
    let env = nook_core::brain::service::BrainEnv {
        key: state.key_for(settings.provider),
        memory_gb: crate::brain::memory_gb(),
        country: crate::brain::country(),
        timezone: crate::brain::timezone(),
    };
    tauri::async_runtime::spawn(async move {
        // The Mac's per-project title rules have no settings page here yet.
        let prompt = titles::prompt(&run.task, "");
        let answer =
            tokio::time::timeout(Duration::from_secs(90), nook_core::brain::service::complete(&settings, &env, titles::SYSTEM, &prompt))
                .await
                .ok()
                .and_then(Result::ok);
        let Some(current) = manager.run(id) else { return };
        if let Some(title) = titles::choose(&run.title, &current.title, answer.as_deref()) {
            manager.rename(id, &title);
        }
    });
}
