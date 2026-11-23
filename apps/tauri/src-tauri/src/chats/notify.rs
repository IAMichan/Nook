//! A new chat message reaching you, for every chat app (`ChatNotices` on the Mac): Settings › Notifications decides how
//! (`notices::decide`, the one rule set: the Chats style, the app's switch, quiet hours, quiet while sharing). As a system
//! notification it carries Reply and Mark as read (`ToastKind::ChatReply`), so you can answer from the Windows toast
//! itself; as a card or strip the bar shows it; "history only" keeps it in the list without anything popping up.

use nook_core::chats::priority::{self, ChatNoticeMode, NoticePriorityLevel, NoticeScore};
use nook_core::chats::{ChatInbox, InboxMessage, InboxThread};
use nook_core::services::notice_rules::{NoticeDecision, NoticeSource, NoticeStyle};
use nook_core::services::toast::{NoticeOptions, NoticeTarget, Toast, ToastLevel};
use tauri::{AppHandle, Emitter, Manager};

use crate::connectors::Connectors;

/// What the bar is told of a new message from an app other than WhatsApp (WhatsApp's own card has `whatsapp-message`).
#[derive(serde::Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct ChatArrived {
    pub key: String,
    pub app: String,
    pub name: String,
    pub preview: String,
    pub unread: usize,
    /// "card" or "strip", as Settings › Notifications says.
    pub style: String,
    /// Scored notice priority (CH-64): raises above burst pacing and powers the card's priority badge.
    pub priority: NoticeScore,
}

/// Evaluates notice priority for a specific incoming message inside `thread` (CH-64).
/// Group chats default to `quiet_by_kind = true` so only direct mentions and replies-to-me raise priority.
pub fn score_message(thread: &InboxThread, message: &InboxMessage) -> NoticeScore {
    let mode = if thread.muted_in_app == Some(true) { ChatNoticeMode::Muted } else { ChatNoticeMode::Automatic };
    priority::evaluate(thread, message, thread.is_group(), mode)
}

/// Evaluates notice priority for the newest incoming message in `thread` (CH-64).
pub fn score_thread(thread: &InboxThread) -> NoticeScore {
    let mode = if thread.muted_in_app == Some(true) { ChatNoticeMode::Muted } else { ChatNoticeMode::Automatic };
    priority::evaluate_latest(thread, thread.is_group(), mode)
}

/// The app's display name for the notice rules' per-app switches.
pub fn app_name(app: &str) -> &str {
    match app {
        "whatsapp" => "WhatsApp",
        "telegram" => "Telegram",
        "signal" => "Signal",
        "messenger" => "Messenger",
        "instagram" => "Instagram",
        "x" => "X",
        "linkedin" => "LinkedIn",
        "slack" => "Slack",
        "teams" => "Teams",
        "discord" => "Discord",
        "googlechat" => "Google Chat",
        other => other,
    }
}

/// How a new message in `app` shows now: `None` when it is kept in the list only.
pub fn style(handle: &AppHandle, app: &str, urgent: bool) -> Option<NoticeStyle> {
    match crate::notices::decide(handle, NoticeSource::Chats, app_name(app), urgent) {
        NoticeDecision::Show(NoticeStyle::Off) | NoticeDecision::HistoryOnly => None,
        NoticeDecision::Show(style) => Some(style),
    }
}

/// A system notification for a chat's newest message, with Reply and Mark as read. Answering sends through the chat's
/// own app (WhatsApp's gateway or the helper), marking reads it there; a click opens the chat in Nook.
pub fn toast(handle: &AppHandle, key: &str, app: &str, name: &str, preview: &str, sends: bool) {
    toast_with_priority(handle, key, app, name, preview, sends, &NoticeScore::default());
}

/// System notification with priority awareness (CH-64): urgent priority may pass burst pacing after user rules
/// (`style(..., false)`) have already allowed the notice.
pub fn toast_with_priority(handle: &AppHandle, key: &str, app: &str, name: &str, preview: &str, sends: bool, priority: &NoticeScore) {
    let level =
        if priority.raises && priority.level == NoticePriorityLevel::Urgent { ToastLevel::TimeSensitive } else { ToastLevel::Active };
    let toast = Toast::notice(
        &format!("chat-{key}"),
        name,
        app_name(app),
        preview,
        NoticeTarget::Chat(key.to_string()),
        level,
        NoticeOptions { reply: sends, read: true, app: None },
    );
    let (reply_app, read_app, show_app) = (handle.clone(), handle.clone(), handle.clone());
    let (reply_key, read_key, show_key) = (key.to_string(), key.to_string(), key.to_string());
    let handlers = crate::notices::Handlers {
        reply: sends.then(|| {
            Box::new(move |text: String| {
                let (app, key) = (reply_app.clone(), reply_key.clone());
                tauri::async_runtime::spawn(async move {
                    if let Some(c) = app.try_state::<Connectors>() {
                        if let Err(e) = super::inbox::chat_inbox_send(app.clone(), c, key, text, None).await {
                            log::info!("A reply from a chat notification did not go: {e}");
                        }
                    }
                });
            }) as Box<dyn Fn(String) + Send + Sync>
        }),
        read: Some(Box::new(move || {
            let (app, key) = (read_app.clone(), read_key.clone());
            tauri::async_runtime::spawn(async move {
                if let Some(c) = app.try_state::<Connectors>() {
                    let _ = super::inbox::chat_inbox_mark_read(app.clone(), c, key, true).await;
                }
            });
        })),
        show: Some(Box::new(move || open(&show_app, &show_key))),
        ..Default::default()
    };
    let fallback = (handle.clone(), name.to_string(), preview.to_string());
    crate::notices::post(handle, toast, handlers, move || crate::platform::plain_notification(&fallback.0, &fallback.1, &fallback.2));
}

/// Opens the chat in the main window's Chats tab: the window comes up on Chats, then the chat opens there (`open-chat`,
/// a moment later, so a Chats tab that is only now shown hears it).
pub fn open(handle: &AppHandle, key: &str) {
    crate::platform::desktop_or_main(handle, "chats");
    let (app, key) = (handle.clone(), key.to_string());
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(600)).await;
        let _ = app.emit("open-chat", key);
    });
}

/// The chats of the helper's apps that got something new from someone else since `before`: each is scored by
/// `ChatNoticePriority` (CH-64), told as Settings says, and handed to the automations that start on a message (BR-16).
pub fn arrived(handle: &AppHandle, before: &ChatInbox, now: &ChatInbox) {
    let since = chrono::Utc::now() - chrono::Duration::minutes(10);
    let mut messages = vec![];
    let mut ranked: Vec<(String, &InboxThread, &InboxMessage, NoticeScore)> = vec![];
    for key in now.fresh(before, since) {
        let Some(thread) = now.threads.get(&key) else { continue };
        // WhatsApp tells its own arrivals (`whatsapp-message`); its chats are in the inbox too.
        if thread.app == "whatsapp" || thread.muted_in_app == Some(true) || thread.archived {
            continue;
        }
        let Some(newest) = thread.messages.iter().rev().find(|m| m.is_incoming() && !m.deleted) else { continue };
        let priority = score_message(thread, newest);
        ranked.push((key, thread, newest, priority));
    }
    // Lower-priority notices go first so the highest-priority arrival is emitted last and surfaces on top.
    ranked.sort_by_key(|(_, _, newest, p)| (p.raises, p.score, newest.date));

    for (key, thread, newest, priority) in ranked {
        let preview = preview(thread, newest);
        crate::notice_history::record(
            handle,
            &format!("chat:{key}"),
            nook_core::services::notice_log::NoticeKind::Info,
            &thread.name,
            &preview,
            &thread.app,
            &format!("chat:{key}"),
        );
        messages.push(nook_core::workspace::arrivals::ArrivedMessage {
            chat_id: key.clone(),
            app: thread.app.clone(),
            chat: thread.name.clone(),
            sender: if newest.sender.is_empty() { thread.name.clone() } else { newest.sender.clone() },
            text: newest.text.clone(),
            date: newest.date,
            is_group: thread.is_group(),
            id: newest.id.clone(),
        });
        // A question or a mention never counts as urgent here (`ChatNoticePriority`: priority only passes a pacer, it
        // never bypasses a user rule like quiet hours, quiet mode, or an app switched off).
        match style(handle, &thread.app, false) {
            Some(NoticeStyle::System) => toast_with_priority(handle, &key, &thread.app, &thread.name, &preview, true, &priority),
            Some(style) => {
                let style = if style == NoticeStyle::Strip { "strip" } else { "card" };
                let _ = handle.emit(
                    "chat-arrived",
                    ChatArrived {
                        key: key.clone(),
                        app: thread.app.clone(),
                        name: thread.name.clone(),
                        preview,
                        unread: thread.unread,
                        style: style.into(),
                        priority,
                    },
                );
            }
            None => {}
        }
    }
    if !messages.is_empty() {
        crate::workspace::automation::messages_arrived(handle, messages);
    }
}

fn preview(thread: &InboxThread, m: &nook_core::chats::InboxMessage) -> String {
    let words = if m.text.is_empty() { "📎".to_string() } else { m.text.chars().take(160).collect() };
    if thread.is_group() && !m.sender.is_empty() {
        format!("{}: {words}", m.sender)
    } else {
        words
    }
}
