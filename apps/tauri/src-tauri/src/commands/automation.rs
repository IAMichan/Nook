//! Commands for automation: scheduled tasks and their webhooks, the automation switches (Settings › Agents ›
//! Automation), handing a session to another agent, and the result of a delegated task. See `workspace::automation`.

use chrono::{Local, Utc};
use nook_core::workspace::models::RunProvider;
use nook_core::workspace::schedule::ScheduledTask;
use nook_core::workspace::scheduler::{AutomationSettings, RunNow};
use nook_core::workspace::webhook_relay::RelayState;
use nook_core::workspace::webhook_rules::WebhookDeliveryRecord;
use nook_core::workspace::{delegation, handoff};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};
use uuid::Uuid;

use crate::workspace::automation::{self, AutomationState};
use crate::workspace::WorkspaceState;

type Res<T> = Result<T, String>;

fn id(text: &str) -> Res<Uuid> {
    Uuid::parse_str(text).map_err(|_| nook_core::i18n::tr("Ongeldig id.", "Invalid id.").to_string())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskView {
    #[serde(flatten)]
    task: ScheduledTask,
    running: bool,
    /// `http://127.0.0.1:<port>/hooks/<id>` for a webhook task while the listener is on.
    webhook_url: Option<String>,
    /// `https://<relay>/v1/hooks/<room>/<id>` for a webhook task while public webhooks are on.
    public_webhook_url: Option<String>,
    /// Recent verified deliveries for a webhook task (newest first, up to 50).
    deliveries: Vec<WebhookDeliveryRecord>,
    /// The title of the session the latest run went to, while it exists.
    session_title: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AutomationOverview {
    settings: AutomationSettings,
    tasks: Vec<TaskView>,
    /// The port the webhook listener listens on now.
    listening: Option<u16>,
    listener_error: Option<String>,
    /// Live state of the public webhook relay connection.
    relay_state: RelayState,
}

#[tauri::command]
pub fn automation_overview(app: AppHandle, state: State<'_, AutomationState>) -> AutomationOverview {
    let manager = app.try_state::<WorkspaceState>().map(|w| w.manager.clone());
    let tasks = state
        .scheduler
        .tasks()
        .into_iter()
        .map(|task| {
            let is_hook = task.rule.is_webhook();
            TaskView {
                running: state.scheduler.is_running(task.id),
                webhook_url: is_hook.then(|| automation::webhook_url(&app, task.id)).flatten(),
                public_webhook_url: is_hook.then(|| automation::public_webhook_url(&app, task.id)).flatten(),
                deliveries: if is_hook { state.scheduler.deliveries(task.id) } else { Vec::new() },
                session_title: task.last_session.and_then(|s| manager.as_ref()?.run(s)).map(|r| r.title),
                task,
            }
        })
        .collect();
    let (listening, listener_error) = state.listener();
    AutomationOverview { settings: state.settings(), tasks, listening, listener_error, relay_state: state.relay_state() }
}

#[tauri::command]
pub fn automation_save_settings(app: AppHandle, state: State<'_, AutomationState>, settings: AutomationSettings) {
    *crate::agents::lock(&state.settings) = settings.clone();
    settings.save_to(&AutomationSettings::file());
    automation::apply_listener(&app);
    automation::apply_relay(&app);
    let _ = app.emit("automation-changed", ());
}

#[tauri::command]
pub fn automation_save_task(app: AppHandle, state: State<'_, AutomationState>, task: ScheduledTask) -> Res<ScheduledTask> {
    if task.prompt.trim().is_empty() {
        return Err(nook_core::i18n::tr("Schrijf een prompt.", "Write a prompt.").into());
    }
    let saved = state.scheduler.save_task(task, Utc::now(), &Local);
    automation::apply_relay(&app);
    let _ = app.emit("automation-changed", ());
    Ok(saved)
}

#[tauri::command]
pub fn automation_delete_task(app: AppHandle, state: State<'_, AutomationState>, task: String) -> Res<()> {
    state.scheduler.delete(id(&task)?);
    automation::apply_relay(&app);
    let _ = app.emit("automation-changed", ());
    Ok(())
}

#[tauri::command]
pub fn automation_set_task_enabled(app: AppHandle, state: State<'_, AutomationState>, task: String, enabled: bool) -> Res<()> {
    state.scheduler.set_enabled(id(&task)?, enabled, Utc::now(), &Local);
    automation::apply_relay(&app);
    let _ = app.emit("automation-changed", ());
    Ok(())
}

/// "Run now": the task's own prompt, once, if it is free.
#[tauri::command]
pub async fn automation_run_task(app: AppHandle, task: String) -> Res<RunNow> {
    let task = id(&task)?;
    let auto = app.state::<AutomationState>();
    let scheduler = auto.scheduler.clone();
    let enabled = auto.settings().scheduled_tasks;
    let manager = app.state::<WorkspaceState>().manager.clone();
    let app2 = app.clone();
    let result = tauri::async_runtime::spawn_blocking(move || {
        let profile = |p: RunProvider| automation::default_profile(&app2, p);
        let host = crate::workspace::nook_runs::AppHost { manager, app: app2.clone() };
        scheduler.run_now(&host, enabled, task, &profile, Utc::now(), &Local)
    })
    .await
    .map_err(|e| e.to_string())?;
    let _ = app.emit("automation-changed", ());
    Ok(result)
}

/// The signing secret of a webhook task, from the secret store, to copy into the sender.
#[tauri::command]
pub fn automation_webhook_secret(state: State<'_, AutomationState>, task: String, rotate: bool) -> Res<String> {
    let task = id(&task)?;
    let secret = if rotate { state.scheduler.rotate_secret(task) } else { state.scheduler.webhook_secret(task, true) };
    secret.ok_or_else(|| {
        nook_core::i18n::tr("Het geheim kon niet in de kluis worden bewaard.", "The secret could not be kept in the secret store.").into()
    })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HandedOff {
    included: usize,
    omitted: usize,
    /// The new agent goes on with its own earlier conversation.
    resumed: bool,
}

/// Hands a session to another agent (or account) between turns, with its context.
#[tauri::command]
pub async fn workspace_hand_off(app: AppHandle, run: String, provider: RunProvider, profile_id: String, model: String) -> Res<HandedOff> {
    let run = id(&run)?;
    let installed = crate::platform::capabilities().local_agents && nook_core::agents::find_executable(provider.kind()).is_some();
    let manager = app.state::<WorkspaceState>().manager.clone();
    let app2 = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let auto = app2.state::<AutomationState>();
        handoff::switch(&manager, &auto.handoffs, run, provider, &profile_id, &model, installed).map(|s| HandedOff {
            included: s.included,
            omitted: s.omitted,
            resumed: s.resumed,
        })
    })
    .await
    .map_err(|e| e.to_string())?
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DelegatedView {
    parent: String,
    parent_title: Option<String>,
    depth: usize,
}

/// Where a delegated session came from, for its header ("Delegated by …").
#[tauri::command]
pub fn workspace_delegation(app: AppHandle, state: State<'_, AutomationState>, run: String) -> Res<Option<DelegatedView>> {
    let Some(link) = state.links.link(id(&run)?) else { return Ok(None) };
    let title = app.state::<WorkspaceState>().manager.run(link.parent).map(|r| r.title);
    Ok(Some(DelegatedView { parent: link.parent.to_string(), parent_title: title, depth: link.depth }))
}

/// Delegates a task from a session to a child session (for the bridge's `delegate_task`).
pub fn delegate(app: &AppHandle, parent: Uuid, request: delegation::Request) -> Res<Uuid> {
    let manager = app.state::<WorkspaceState>().manager.clone();
    let auto = app.state::<AutomationState>();
    let profile = |p: RunProvider| automation::default_profile(app, p);
    let typed = !request.title.trim().is_empty();
    let child = delegation::delegate(&manager, &auto.links, parent, request, &profile)?;
    automation::title_new_session(app, child, typed);
    Ok(child)
}
