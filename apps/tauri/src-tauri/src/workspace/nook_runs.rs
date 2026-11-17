//! Runs of automations for Nook Chat itself (`ScheduledTaskStore.runInNook` on the Mac): each run is a conversation of
//! its own, asked as if the user typed the task's prompt, with the run's note for the brain. Nook looks things up and
//! answers there; mail drafts and plans wait in that conversation for the user's click. Nothing is sent or changed by
//! the run itself. The rules (prompt note, quiet, reasons) are in `nook_core::workspace::{nook_schedule, scheduler}`.

use std::sync::Arc;
use std::time::{Duration, Instant};

use chrono::{Local, Utc};
use nook_core::brain::service;
use nook_core::nooks::Conversation;
use nook_core::workspace::manager::Manager;
use nook_core::workspace::models::{NewRunConfig, PermissionPolicy, RunStatus};
use nook_core::workspace::nook_schedule;
use nook_core::workspace::schedule::{reason, ScheduledRunStatus};
use nook_core::workspace::scheduler::{NookRun, SessionHost};
use tauri::{AppHandle, Emitter, Manager as _};
use uuid::Uuid;

use super::automation::AutomationState;
use crate::commands::chat;
use crate::state::AppState;

/// The scheduler's host in the app: sessions go to the workspace manager, runs for Nook to Nook Chat.
pub struct AppHost {
    pub manager: Arc<Manager>,
    pub app: AppHandle,
}

impl SessionHost for AppHost {
    fn start_session(&self, config: NewRunConfig) -> Result<Uuid, String> {
        self.manager.start_session(config)
    }

    fn session(&self, id: Uuid) -> Option<(RunStatus, Option<String>, PermissionPolicy)> {
        self.manager.session(id)
    }

    fn send_to(&self, id: Uuid, text: &str, fresh: bool, note: &str) -> Result<(), String> {
        self.manager.send_to(id, text, fresh, note)
    }

    fn ask_nook(&self, run: NookRun) -> Result<(), String> {
        start(&self.app, run)
    }
}

/// Starts the run in a new conversation in the background, so the chat on screen stays as it is.
fn start(app: &AppHandle, run: NookRun) -> Result<(), String> {
    let state = app.state::<AppState>();
    let settings = state.settings();
    if !service::brain_ready(&settings, state.key_for(settings.provider).is_some_and(|k| !k.is_empty())) {
        return Err(reason::NO_BRAIN.into());
    }
    let nook_id = state.with_chat(|c| {
        let conversation = Conversation::new();
        let id = conversation.id.clone();
        c.conversations.insert(0, conversation);
        id
    });
    let reply = chat::ask_scheduled(app, &nook_id, &run.prompt, run.note.clone())?;
    // The task's name, not the first words of its prompt; the marker ties the conversation to its automation.
    state.with_chat(|c| {
        if let Some(conv) = c.get_mut(&nook_id) {
            conv.title = run.title.clone();
            conv.scheduled_task = Some(run.task.to_string());
        }
    });
    chat::updated(app, &nook_id);
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let (status, error) = watch(&app, &nook_id, reply.as_deref(), run.quiet).await;
        if let Some(auto) = app.try_state::<AutomationState>() {
            auto.scheduler.finish_run(run.task, status, error, Utc::now(), &Local);
        }
        let _ = app.emit("automation-changed", ());
    });
    Ok(())
}

/// Waits for the run's answer (at most `RUN_LIMIT_SECONDS`) and says how the run ended.
async fn watch(app: &AppHandle, nook_id: &str, reply: Option<&str>, quiet: bool) -> (ScheduledRunStatus, Option<String>) {
    let state = app.state::<AppState>();
    let deadline = Instant::now() + Duration::from_secs(nook_schedule::RUN_LIMIT_SECONDS);
    let busy = || state.with_chat(|c| c.get(nook_id).is_some_and(|conv| conv.busy));
    while busy() && Instant::now() < deadline {
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    if busy() {
        chat::stop(app, nook_id);
        return (ScheduledRunStatus::Failed, Some(reason::NOOK_TIMEOUT.into()));
    }
    // A quick answer (no brain needed) has no reply id: the last answer of the conversation is the run's.
    let (answer, asked) = state.with_chat(|c| {
        let Some(conv) = c.get(nook_id) else { return (None, 0) };
        let asked = conv.messages.iter().filter(|m| m.from_user).count();
        let answer = match reply {
            Some(id) => conv.messages.iter().find(|m| m.id == id),
            None => conv.messages.iter().rev().find(|m| !m.from_user),
        };
        (answer.cloned(), asked)
    });
    // The user deleted the conversation meanwhile: the run happened, there is just nothing to show.
    let Some(answer) = answer else { return (ScheduledRunStatus::Succeeded, None) };
    // Nothing new: no conversation stays behind, unless the user went on with it.
    if quiet && nook_schedule::is_nothing_new(&answer.text) {
        if asked <= 1 {
            state.with_chat(|c| c.remove(nook_id));
            chat::updated(app, nook_id);
        }
        return (ScheduledRunStatus::Succeeded, Some(reason::NOTHING_NEW.into()));
    }
    if answer.is_error {
        return (ScheduledRunStatus::Failed, Some(answer.text));
    }
    if answer.text.trim().is_empty() && answer.mails.is_empty() && answer.actions.is_empty() && answer.charts.is_empty() {
        return (ScheduledRunStatus::Failed, Some(reason::NOOK_EMPTY.into()));
    }
    // The answer waits for the user: the conversation shows as unread in the list.
    state.with_chat(|c| {
        if let Some(conv) = c.get_mut(nook_id) {
            conv.unread = true;
        }
    });
    chat::updated(app, nook_id);
    (ScheduledRunStatus::Succeeded, None)
}
