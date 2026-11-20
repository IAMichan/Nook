//! Follow-ups in the app (`AppModel+FollowUps` on the Mac): the chats you owe a reply for Today, your waits, snoozes and
//! scheduled messages, and the tick that settles them with the inbox once a minute, reminds you of a wait whose time is
//! up and sends a scheduled message when it is due (one that comes too late waits for your OK).

use std::collections::HashSet;
use std::sync::Arc;

use chrono::{DateTime, Duration, Utc};
use nook_core::chats::follow_up::{self, FollowUpStore, ScheduledSend, Turn};
use tauri::{AppHandle, Emitter, Manager, State};

use crate::connectors::Connectors;

pub struct FollowUpState(pub Arc<FollowUpStore>);

/// Called once from `connectors::setup`: the store, and the tick.
pub fn setup(app: &AppHandle) {
    let store = Arc::new(FollowUpStore::open_default());
    app.manage(FollowUpState(store.clone()));
    let handle = app.clone();
    tauri::async_runtime::spawn(async move {
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(60)).await;
            tick(&handle, &store).await;
        }
    });
}

async fn tick(app: &AppHandle, store: &FollowUpStore) {
    let Some(c) = app.try_state::<Connectors>() else { return };
    let now = Utc::now();
    let turns = c.env.chats.read(|inbox| follow_up::turns(inbox, now));
    store.change(|f| f.settle(&turns, now));
    let chats: HashSet<String> = turns.iter().map(|t| t.chat.clone()).collect();
    let plan = store.read(|f| f.plan(&chats, now));
    for chat in &plan.reminders {
        if let Some(turn) = turns.iter().find(|t| &t.chat == chat) {
            if super::notify::style(app, &turn.app, false).is_some() {
                // "Lisa has not answered yet", with the last message (the Mac's `chats.followUp.reminder`).
                let title = nook_core::i18n::trf("{name} heeft nog niet geantwoord", "{name} has not answered yet", &[("name", &turn.name)]);
                crate::notices::notice(
                    app,
                    &format!("wait-{chat}"),
                    &title,
                    &turn.last_text,
                    nook_core::services::toast::NoticeTarget::Chat(chat.clone()),
                );
            }
        }
        store.change(|f| f.acknowledge(chat, now));
    }
    for send in plan.sends {
        store.change(|f| f.cancel_scheduled(&send.id));
        if let Some(c) = app.try_state::<Connectors>() {
            if let Err(e) = super::inbox::chat_inbox_send(app.clone(), c, send.chat.clone(), send.text.clone(), None).await {
                log::info!("A scheduled message did not go: {e}");
                let _ = app.emit("chat-scheduled-confirm", &send);
            }
        }
    }
    for send in plan.confirm {
        store.change(|f| f.cancel_scheduled(&send.id));
        // Its chat comes up with the text ready, for you to send or drop.
        let _ = app.emit("chat-scheduled-confirm", &send);
    }
}

/// The chats you owe a reply, every app at once, without snoozed ones and scam: questions first. For Today.
#[tauri::command]
pub fn chat_owed(c: State<'_, Connectors>, f: State<'_, FollowUpState>, limit: Option<usize>) -> Vec<Turn> {
    let now = Utc::now();
    // A chat you muted in its app is not one you owe an answer (the Mac leaves out muted and hidden chats).
    let turns = c.env.chats.read(|inbox| {
        let mut turns = follow_up::turns(inbox, now);
        turns.retain(|t| inbox.threads.get(&t.chat).and_then(|t| t.muted_in_app) != Some(true));
        turns
    });
    let mut owed = f.0.read(|f| f.owed(&turns, now));
    owed.truncate(limit.unwrap_or(3));
    owed
}

/// "Waiting for reply" on a chat, with a reminder after `hours` (a day by default); `false` clears it.
#[tauri::command]
pub fn chat_follow_up_wait(f: State<'_, FollowUpState>, key: String, waiting: bool, hours: Option<i64>) {
    f.0.change(|f| {
        if waiting {
            f.mark_waiting(&key, Utc::now(), hours.map(Duration::hours).unwrap_or_else(follow_up::FollowUps::default_wait));
        } else {
            f.clear_waiting(&key);
        }
    });
}

/// Snoozes a chat out of what you owe until `until` (milliseconds since 1970), or (`None`) brings it back.
#[tauri::command]
pub fn chat_snooze(f: State<'_, FollowUpState>, key: String, until: Option<i64>) {
    f.0.change(|f| match until.and_then(DateTime::from_timestamp_millis) {
        Some(until) => f.snooze(&key, until),
        None => f.unsnooze(&key),
    });
}

/// Schedules a message to go at `at` (milliseconds since 1970); its id, to cancel it.
#[tauri::command]
pub fn chat_schedule(f: State<'_, FollowUpState>, key: String, text: String, at: i64) -> Result<String, String> {
    let send_at = DateTime::from_timestamp_millis(at).ok_or("No time given.")?;
    if text.trim().is_empty() || send_at <= Utc::now() {
        return Err("A scheduled message needs words and a time still to come.".into());
    }
    let id = uuid::Uuid::new_v4().to_string();
    f.0.change(|f| f.schedule(ScheduledSend { id: id.clone(), chat: key, text, send_at }));
    Ok(id)
}

/// The messages scheduled for a chat, soonest first.
#[tauri::command]
pub fn chat_scheduled(f: State<'_, FollowUpState>, key: String) -> Vec<ScheduledSend> {
    f.0.read(|f| f.scheduled.iter().filter(|s| s.chat == key).cloned().collect())
}

#[tauri::command]
pub fn chat_schedule_cancel(f: State<'_, FollowUpState>, id: String) {
    f.0.change(|f| f.cancel_scheduled(&id));
}
