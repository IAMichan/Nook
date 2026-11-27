//! Automation in the app: scheduled tasks (the 30-second tick and the local webhook listener), automatic session
//! titles through the chosen brain, handing a session to another agent, and delegated child sessions. The logic is in
//! `nook_core::workspace::{schedule, scheduler, webhook, titles, handoff, delegation}`; this file only connects it
//! to the manager, the secret store and the brain. Event to the interface: `automation-changed`.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{Local, Utc};
use nook_core::workspace::arrivals::ArrivedMessage;
use nook_core::workspace::delegation::Links;
use nook_core::workspace::handoff::HandoffStore;
use nook_core::workspace::models::RunProvider;
use nook_core::workspace::scheduler::{AutomationSettings, Scheduler, TICK_SECONDS};
use nook_core::workspace::webhook_relay::{RelayState, WebhookRelayClient};
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
    pub relay: WebhookRelayClient,
    listener: Mutex<Listener>,
    coalesce_timer: Mutex<Option<tauri::async_runtime::JoinHandle<()>>>,
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

    /// The live status of the public webhook relay connection.
    pub fn relay_state(&self) -> RelayState {
        self.relay.state()
    }
}

/// Shared handler for both the local loopback webhook listener and the public webhook relay.
fn make_webhook_handler(app: &AppHandle) -> webhook::Handler {
    let handle = app.clone();
    Arc::new(move |request| {
        let Some(auto) = handle.try_state::<AutomationState>() else { return (503, "unavailable".into()) };
        let answer = auto.scheduler.handle_webhook(auto.settings().scheduled_tasks, &request, Utc::now());
        if answer.0 == 202 {
            let app = handle.clone();
            tauri::async_runtime::spawn(async move {
                tick(&app).await;
                schedule_coalesce_flush(&app);
            });
        }
        let _ = handle.emit("automation-changed", ());
        answer
    })
}

/// Schedules a one-shot wake-up for the earliest open coalesce window, so a burst flushes right when its window closes
/// instead of waiting for the 30-second tick.
pub fn schedule_coalesce_flush(app: &AppHandle) {
    let Some(auto) = app.try_state::<AutomationState>() else { return };
    let mut timer = lock(&auto.coalesce_timer);
    if let Some(old) = timer.take() {
        old.abort();
    }
    let Some(deadline) = auto.scheduler.next_coalesce_deadline() else { return };
    let delay = (deadline - Utc::now()).to_std().unwrap_or_default() + Duration::from_millis(50);
    let handle = app.clone();
    *timer = Some(tauri::async_runtime::spawn(async move {
        tokio::time::sleep(delay).await;
        tick(&handle).await;
        schedule_coalesce_flush(&handle);
    }));
}

#[cfg(desktop)]
fn current_relay_url(app: &AppHandle) -> Option<String> {
    app.try_state::<crate::companion::Companion>().and_then(|c| crate::companion::current_relay(c.server.store()))
}

#[cfg(not(desktop))]
fn current_relay_url(_: &AppHandle) -> Option<String> {
    None
}

/// After `workspace::setup`: loads the tasks, resumes any waiting webhook deliveries from before the last quit, and
/// starts the tick, local webhook listener, and public webhook relay when chosen.
pub fn setup(app: &AppHandle) {
    let secrets = app.state::<AppState>().secrets.clone();
    let directory = nook_core::paths::support_directory().join("workspace");
    let scheduler = Arc::new(Scheduler::new(Scheduler::file(), secrets.clone(), Utc::now(), &Local));
    let settings = AutomationSettings::load_from(&AutomationSettings::file());
    let resumed = scheduler.resume_restored_webhooks(settings.scheduled_tasks);
    let change_handle = app.clone();
    let relay = WebhookRelayClient::new(
        secrets,
        make_webhook_handler(app),
        Arc::new(move || {
            let _ = change_handle.emit("automation-changed", ());
        }),
        tauri::async_runtime::handle().inner().clone(),
    );
    app.manage(AutomationState {
        scheduler: scheduler.clone(),
        settings: Mutex::new(settings),
        handoffs: HandoffStore::new(&directory),
        links: Links::new(&directory),
        relay,
        listener: Mutex::new(Listener::default()),
        coalesce_timer: Mutex::new(None),
    });
    apply_listener(app);
    apply_relay(app);
    if resumed {
        let handle = app.clone();
        tauri::async_runtime::spawn(async move { tick(&handle).await });
    }
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
        let host = super::nook_runs::AppHost { manager, app: app2.clone() };
        scheduler.tick(&host, enabled, &profile, Utc::now(), &Local);
        if enabled {
            scheduler.drain_webhooks(&host, &profile, Utc::now(), &Local);
        }
        scheduler.tasks() != before
    })
    .await
    .unwrap_or(false);
    if changed {
        let _ = app.emit("automation-changed", ());
    }
}

/// New messages from someone else, from any chat app: every automation whose message trigger they match runs with
/// them (`Scheduler::messages_arrived`). A source kept on this computer never reaches an external brain, also not
/// through an automation, so its messages are dropped here while such a brain is chosen.
pub fn messages_arrived(app: &AppHandle, messages: Vec<ArrivedMessage>) {
    let Some(auto) = app.try_state::<AutomationState>() else { return };
    let private = app.state::<AppState>().settings().private_sources();
    let messages: Vec<ArrivedMessage> = messages.into_iter().filter(|m| !private.contains(&m.app)).collect();
    if messages.is_empty() || !auto.scheduler.tasks().iter().any(|t| t.enabled && t.rule.is_message()) {
        return;
    }
    let (Some(ws), scheduler, enabled) = (app.try_state::<WorkspaceState>(), auto.scheduler.clone(), auto.settings().scheduled_tasks)
    else {
        return;
    };
    let manager = ws.manager.clone();
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let app2 = app.clone();
        let _ = tauri::async_runtime::spawn_blocking(move || {
            let profile = |p: RunProvider| default_profile(&app2, p);
            let host = super::nook_runs::AppHost { manager, app: app2.clone() };
            scheduler.messages_arrived(&host, enabled, &messages, &profile, Utc::now(), &Local);
        })
        .await;
        let _ = app.emit("automation-changed", ());
    });
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
    let handler = make_webhook_handler(app);
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

/// Connects, reconnects, or stops the public webhook relay after a change of settings, tasks, or companion relay.
pub fn apply_relay(app: &AppHandle) {
    let Some(auto) = app.try_state::<AutomationState>() else { return };
    let settings = auto.settings();
    let wanted =
        settings.scheduled_tasks && settings.webhooks_public && auto.scheduler.tasks().iter().any(|t| t.enabled && t.rule.is_webhook());
    let relay = current_relay_url(app);
    auto.relay.apply(wanted, relay.as_deref());
}

/// The address of a task's webhook while the listener is on.
pub fn webhook_url(app: &AppHandle, task: Uuid) -> Option<String> {
    let port = app.try_state::<AutomationState>()?.settings().listening_port()?;
    Some(format!("http://127.0.0.1:{port}/hooks/{task}"))
}

/// The public address of a task's webhook through the relay, while public webhooks are on and a relay is configured.
pub fn public_webhook_url(app: &AppHandle, task: Uuid) -> Option<String> {
    let auto = app.try_state::<AutomationState>()?;
    if !auto.settings().webhooks_public {
        return None;
    }
    let relay = current_relay_url(app)?;
    auto.relay.public_url(&relay, task)
}

/// The title rules `project` sets for itself (Settings › Projects), empty when none.
fn app_rules(app: &AppHandle, project: &str) -> String {
    app.try_state::<WorkspaceState>()
        .map(|w| crate::workspace::lock(&w.settings).defaults_for(project).title_instructions)
        .unwrap_or_default()
}

/// A short title for a new session from its first message, written by the chosen brain (the same path as every other
/// brain answer). The first line stays when automatic titles are off, the brain gives nothing usable, or you renamed
/// the session meanwhile. `typed`: you gave the session a name yourself.
pub fn title_new_session(app: &AppHandle, id: Uuid, typed: bool) {
    let Some(auto) = app.try_state::<AutomationState>() else { return };
    let rules = auto.settings().title_instructions.clone();
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
    let own = app_rules(app, &run.project_path);
    tauri::async_runtime::spawn(async move {
        // A project's own title rules win over the ones for all projects.
        let prompt = titles::prompt(&run.task, if own.trim().is_empty() { &rules } else { &own });
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
