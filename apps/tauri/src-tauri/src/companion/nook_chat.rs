//! The companion's `nook_chat` area on Windows and Linux: Nook's own conversations on the phone, as the Mac's
//! `CompanionServer` answers `chats`, `chat`, `ask` and `chatStop` (`CompanionServer+Remote.swift`).
//!
//! A question from the phone goes the same way as one typed in the main window (`commands::chat::ask`, the one brain
//! pipeline): plans and drafts in the answer wait for approval on this computer like any other, and the main window is
//! left as it is (a new conversation does not become the open one). The answer being written lives only in the app's
//! `nook-stream` events until it is done, so this area keeps the text so far per message and shows it in `chat`; a
//! live phone hears about every change because both events nudge the companion server.

use std::collections::HashMap;
use std::sync::{Mutex, Once, OnceLock};
use std::time::{Duration, Instant};

use nook_core::brain::{service, PromptImage};
use nook_core::companion::chat_digest::{self, ChatLine};
use nook_core::companion::{feature, CompanionError, CompanionOp, CompanionPolicy, CompanionRequest, CompanionResponse};
use nook_core::nooks::Conversation;
use serde::Deserialize;
use tauri::{AppHandle, Listener, Manager};

use super::Companion;
use crate::commands::chat;
use crate::state::AppState;

/// An answer that stopped streaming without a final update (the app quit the task) is forgotten after this long.
const PARTIAL_TTL: Duration = Duration::from_secs(30 * 60);

/// The text so far of answers being written: message id → (conversation id, text, when it last grew).
type Partials = HashMap<String, (String, String, Instant)>;

fn partials() -> &'static Mutex<Partials> {
    static PARTIALS: OnceLock<Mutex<Partials>> = OnceLock::new();
    PARTIALS.get_or_init(Default::default)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Stream {
    nook_id: String,
    message_id: String,
    text: String,
}

fn nudge(app: &AppHandle) {
    if let Some(companion) = app.try_state::<Companion>() {
        companion.server.nudge();
    }
}

/// Follows the main window's events once: the streamed text of an answer, and every change to a conversation, so a
/// live phone sees them at once. The listeners only touch this area's own map, never the chat's lock.
fn listen(app: &AppHandle) {
    static LISTENING: Once = Once::new();
    LISTENING.call_once(|| {
        let stream_app = app.clone();
        app.listen_any("nook-stream", move |event| {
            let Ok(stream) = serde_json::from_str::<Stream>(event.payload()) else { return };
            {
                let mut map = partials().lock().unwrap_or_else(|e| e.into_inner());
                map.retain(|_, (_, _, at)| at.elapsed() < PARTIAL_TTL);
                map.insert(stream.message_id, (stream.nook_id, stream.text, Instant::now()));
            }
            nudge(&stream_app);
        });
        let updated_app = app.clone();
        app.listen_any("nook-updated", move |_| nudge(&updated_app));
    });
}

/// The feature names this area can answer: Nook's chats, wherever this app has the main window's chat.
pub fn features(app: &AppHandle) -> Vec<&'static str> {
    if app.try_state::<AppState>().is_none() {
        return Vec::new();
    }
    listen(app);
    vec![feature::CHAT]
}

/// The answer to one of this area's ops; `None` when it cannot. The work (the chat's lock, the brain check, saving)
/// runs off the async threads.
pub async fn handle(app: &AppHandle, request: &CompanionRequest, _device: &str) -> Option<CompanionResponse> {
    app.try_state::<AppState>()?;
    listen(app);
    let (app, request) = (app.clone(), request.clone());
    tauri::async_runtime::spawn_blocking(move || match request.op {
        CompanionOp::Chats => Some(chats(&app, &request)),
        CompanionOp::Chat => Some(read(&app, &request)),
        CompanionOp::Ask => Some(ask(&app, &request)),
        CompanionOp::ChatStop => Some(stop(&app, &request)),
        _ => None,
    })
    .await
    .ok()
    .flatten()
}

fn brain_ready(app: &AppHandle) -> bool {
    let state = app.state::<AppState>();
    let settings = state.settings();
    service::brain_ready(&settings, state.key_for(settings.provider).is_some_and(|k| !k.is_empty()))
}

fn audit(app: &AppHandle, action: &str, detail: &str) {
    app.state::<AppState>().store.audit(&format!("companion_{action}"), detail, "ok");
}

/// The text so far of the answers being written in `conversation`; what belongs to finished answers is dropped.
fn partials_of(conversation: &Conversation) -> HashMap<String, String> {
    let mut map = partials().lock().unwrap_or_else(|e| e.into_inner());
    let streaming = |id: &str| conversation.messages.iter().any(|m| m.id == id && m.streaming);
    map.retain(|id, (nook, _, _)| nook != &conversation.id || streaming(id));
    map.iter().filter(|(_, (nook, _, _))| nook == &conversation.id).map(|(id, (_, text, _))| (id.clone(), text.clone())).collect()
}

/// The conversation's lines as the phone sees them, or nil when it is gone.
fn lines(app: &AppHandle, id: &str) -> Option<Vec<ChatLine>> {
    app.state::<AppState>().with_chat(|c| c.get(id).map(|conv| chat_digest::lines(conv, &partials_of(conv))))
}

fn messages(lines: Option<Vec<ChatLine>>) -> Option<serde_json::Value> {
    lines.and_then(|l| serde_json::to_value(l).ok())
}

/// The id the phone sent, or `None` for a new conversation.
fn conversation_id(request: &CompanionRequest) -> Option<&str> {
    request.conversation.as_deref().map(str::trim).filter(|c| !c.is_empty())
}

/// The conversations of the main window's list (not the archive), with "nobrain" when no brain is set up yet.
fn chats(app: &AppHandle, request: &CompanionRequest) -> CompanionResponse {
    let list = app.state::<AppState>().with_chat(|c| c.list(false));
    CompanionResponse {
        message: (!brain_ready(app)).then(|| "nobrain".to_string()),
        conversations: serde_json::to_value(chat_digest::digests(&list)).ok(),
        ..CompanionResponse::success(&request.id)
    }
}

/// One conversation. Read on the phone is read: the main window no longer marks it as new.
fn read(app: &AppHandle, request: &CompanionRequest) -> CompanionResponse {
    let Some(id) = conversation_id(request) else { return CompanionResponse::failure(&request.id, CompanionError::UnknownSession) };
    let state = app.state::<AppState>();
    let found = state.with_chat(|c| {
        let conv = c.get_mut(id)?;
        let seen = conv.unread && !conv.busy;
        if seen {
            conv.unread = false;
        }
        Some((chat_digest::lines(conv, &partials_of(conv)), seen))
    });
    let Some((lines, seen)) = found else { return CompanionResponse::failure(&request.id, CompanionError::UnknownSession) };
    if seen {
        state.save_chat();
        chat::updated(app, id);
    }
    CompanionResponse { messages: messages(Some(lines)), ..CompanionResponse::success(&request.id) }
}

/// The pictures the phone sent, as the brain takes them; invalid ones (not a JPEG, too large) are refused whole.
fn images(request: &CompanionRequest) -> Option<Vec<PromptImage>> {
    let images = request.images.clone().unwrap_or_default();
    if images.len() > nook_core::companion::CompanionImage::MAX_COUNT || !images.iter().all(|i| i.is_valid()) {
        return None;
    }
    Some(images.into_iter().map(|i| PromptImage { media_type: "image/jpeg".into(), base64: i.jpeg }).collect())
}

/// A question to Nook, answered by the same brain pipeline as in the main window. A new conversation when the phone
/// names none; it does not become the main window's open one.
fn ask(app: &AppHandle, request: &CompanionRequest) -> CompanionResponse {
    let fail = |error, message: Option<String>| CompanionResponse { message, ..CompanionResponse::failure(&request.id, error) };
    if !brain_ready(app) {
        return fail(CompanionError::Failed, Some("nobrain".into()));
    }
    let Some(pictures) = images(request) else { return fail(CompanionError::BadRequest, None) };
    let text = CompanionPolicy::clean_message(request.text.as_deref().unwrap_or_default());
    if text.is_none() && pictures.is_empty() {
        return fail(CompanionError::BadRequest, None);
    }
    let state = app.state::<AppState>();
    let id = match conversation_id(request) {
        Some(asked) => match state.with_chat(|c| c.get(asked).map(|conv| conv.busy)) {
            None => return fail(CompanionError::UnknownSession, None),
            // An answer is still being written: the main window waits for it too.
            Some(true) => return fail(CompanionError::Busy, None),
            Some(false) => asked.to_string(),
        },
        None => state.with_chat(|c| {
            let conversation = Conversation::new();
            let id = conversation.id.clone();
            c.conversations.insert(0, conversation);
            id
        }),
    };
    if let Err(error) = chat::ask_from_phone(app, &id, text.as_deref().unwrap_or_default(), pictures) {
        if conversation_id(request).is_none() {
            state.with_chat(|c| c.remove(&id));
        }
        return fail(CompanionError::Failed, Some(error));
    }
    let title = state.with_chat(|c| c.get(&id).map(|conv| conv.title.clone())).unwrap_or_default();
    audit(app, "ask", &title);
    CompanionResponse { messages: messages(lines(app, &id)), created: Some(id), ..CompanionResponse::success(&request.id) }
}

/// Stops the answer being written in a conversation, as Stop in the main window.
fn stop(app: &AppHandle, request: &CompanionRequest) -> CompanionResponse {
    let state = app.state::<AppState>();
    let title = conversation_id(request).and_then(|id| state.with_chat(|c| c.get(id).map(|conv| conv.title.clone())));
    let (Some(id), Some(title)) = (conversation_id(request), title) else {
        return CompanionResponse::failure(&request.id, CompanionError::UnknownSession);
    };
    chat::stop(app, id);
    audit(app, "chat_stop", &title);
    CompanionResponse { messages: messages(lines(app, id)), ..CompanionResponse::success(&request.id) }
}
