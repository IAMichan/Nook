//! The companion's `inbox` area on Windows and Linux: the phone's Chats tab, as the Mac's `CompanionServer+Chats.swift`
//! answers it, from the chats this app has. That is WhatsApp through the linked gateway (`Connectors::whatsapp`), the
//! one chat app this area reads; the chats Windows' notifications bring to the computer's own Chats tab
//! (`crate::chats::system_notices`) do not reach the phone yet (docs/INTEGRATIONS.md). The shapes are
//! `nook_core::companion::inbox_digest`.
//!
//! `inbox` and `inboxChat` are asked again and again by the live connection, so they only read what Nook holds (one
//! chat's history is fetched once, the first time it opens). Sending is the phone's own tap, as the Chats tab's send
//! button is on the Mac: the same checks (a chat the list shows that can be written to, no "@nook …", WhatsApp's own
//! length and rate limits) and the action log (`companion_chat_send` and `whatsapp_send`).

use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};

use nook_core::companion::inbox_digest::{self, ChatAvatar, InboxTypist};
use nook_core::companion::{feature, CompanionError, CompanionOp, CompanionPolicy, CompanionRequest, CompanionResponse};
use nook_core::connectors::whatsapp::{jid, Conversation, WhatsAppLink};
use serde::Serialize;
use tauri::{AppHandle, Manager as _};

use crate::connectors::Connectors;
use crate::state::AppState;

/// The `feature` names this area can answer: the inbox whenever the connections are there (an unlinked WhatsApp lists
/// no chats and says why), and the chats' pictures.
pub fn features(app: &AppHandle) -> Vec<&'static str> {
    if app.try_state::<Connectors>().is_none() {
        return Vec::new();
    }
    vec![feature::INBOX, feature::AVATARS]
}

/// The answer to one of this area's ops; `None` when it cannot.
pub async fn handle(app: &AppHandle, request: &CompanionRequest, _device: &str) -> Option<CompanionResponse> {
    let link = app.try_state::<Connectors>()?.whatsapp.clone();
    Some(match request.op {
        CompanionOp::Inbox => inbox(app, &link, request),
        CompanionOp::InboxChat => inbox_chat(&link, request).await,
        CompanionOp::InboxSend => inbox_send(app, &link, request).await,
        CompanionOp::InboxMark => inbox_mark(app, &link, request),
        CompanionOp::Avatars => avatars(&link, request).await,
        _ => return None,
    })
}

fn json<T: Serialize>(value: &T) -> Option<serde_json::Value> {
    serde_json::to_value(value).ok()
}

fn audit(app: &AppHandle, tool: &str, args: &str, result: &str) {
    if let Some(state) = app.try_state::<AppState>() {
        state.store.audit(tool, args, result);
    }
}

/// Every chat the Chats tab lists (hidden ones and status updates left out), newest first.
fn chats(link: &WhatsAppLink) -> Vec<Conversation> {
    if !link.is_connected() {
        return Vec::new();
    }
    link.chat_list()
}

/// A chat the list shows, by its id; a hidden one cannot be reached.
fn entry(link: &WhatsAppLink, id: Option<&str>) -> Option<Conversation> {
    let id = jid::normalized(id.filter(|i| !i.is_empty())?);
    chats(link).into_iter().find(|c| c.id == id)
}

/// Nobody is typing as far as this computer knows: the gateway does not say.
fn typing() -> Option<serde_json::Value> {
    json(&Vec::<InboxTypist>::new())
}

fn inbox(app: &AppHandle, link: &WhatsAppLink, request: &CompanionRequest) -> CompanionResponse {
    let connected = link.is_connected();
    let list = chats(link);
    warm_avatars(app, &list);
    let digests = inbox_digest::digests(&list, connected, |id| link.with_avatar(id, inbox_digest::avatar_version));
    CompanionResponse {
        message: (!connected).then(|| inbox_digest::CHATS_OFF.to_string()),
        inbox: json(&digests),
        ..CompanionResponse::success(&request.id)
    }
}

/// One chat's newest messages. The first time a chat opens its older messages come from the linked phone (once per
/// chat while linked), as opening it on the computer does; after that this reads only what Nook holds.
async fn inbox_chat(link: &WhatsAppLink, request: &CompanionRequest) -> CompanionResponse {
    let Some(chat) = entry(link, request.item.as_deref()) else {
        return CompanionResponse::failure(&request.id, CompanionError::UnknownItem);
    };
    link.load_history(&chat.id).await;
    let lines = link.conversation(&chat.id).map(|c| inbox_digest::lines(&c)).unwrap_or_default();
    CompanionResponse { inbox_lines: json(&lines), inbox_typing: typing(), ..CompanionResponse::success(&request.id) }
}

/// Your own words to a chat, sent as the Chats tab sends them. WhatsApp's gateway takes no quote, so `replyTo` goes
/// unused, as on the Mac for an app that cannot answer a message.
async fn inbox_send(app: &AppHandle, link: &WhatsAppLink, request: &CompanionRequest) -> CompanionResponse {
    let fail = |error| CompanionResponse::failure(&request.id, error);
    let Some(chat) = entry(link, request.item.as_deref()) else { return fail(CompanionError::UnknownItem) };
    if !inbox_digest::can_send(chat.kind, link.is_connected()) {
        return fail(CompanionError::NotAllowedFromPhone);
    }
    // "@nook …" asks Nook to write the message, which is never sent as it is; that stays on the computer.
    let Some(text) = CompanionPolicy::clean_message(request.text.as_deref().unwrap_or_default()).filter(|t| !inbox_digest::asks_nook(t))
    else {
        return fail(CompanionError::BadRequest);
    };
    let args = serde_json::json!({"to": chat.name, "chat": chat.id, "from": "companion"}).to_string();
    if let Err(e) = link.send(&text, &chat.id).await {
        audit(app, "whatsapp_send", &args, &format!("error: {}", e.message));
        return CompanionResponse { message: Some(e.message), ..fail(CompanionError::Failed) };
    }
    audit(app, "whatsapp_send", &args, "ok");
    audit(app, "companion_chat_send", &chat.name, "ok");
    let lines = link.conversation(&chat.id).map(|c| inbox_digest::lines(&c)).unwrap_or_default();
    CompanionResponse { inbox_lines: json(&lines), inbox_typing: typing(), ..CompanionResponse::success(&request.id) }
}

/// Read or unread by hand: read is passed on to WhatsApp as the computer's own "Mark as read" does (when Settings ›
/// WhatsApp lets Nook), unread is Nook's alone.
fn inbox_mark(app: &AppHandle, link: &WhatsAppLink, request: &CompanionRequest) -> CompanionResponse {
    let Some(chat) = entry(link, request.item.as_deref()) else {
        return CompanionResponse::failure(&request.id, CompanionError::UnknownItem);
    };
    let read = request.allow == Some(true);
    if read {
        link.mark_read(&chat.id);
    } else {
        link.mark_unread(&chat.id);
    }
    audit(app, if read { "companion_chat_read" } else { "companion_chat_unread" }, &chat.name, "ok");
    inbox(app, link, request)
}

/// The chats' pictures the phone asks for: only of chats the list shows, as small square JPEGs. App icons
/// (`appIcons`) are not offered here.
async fn avatars(link: &WhatsAppLink, request: &CompanionRequest) -> CompanionResponse {
    let wanted = inbox_digest::wanted_avatars(request.items.as_deref().unwrap_or_default());
    if wanted.is_empty() {
        return CompanionResponse::failure(&request.id, CompanionError::BadRequest);
    }
    let listed: Vec<String> = {
        let all = chats(link);
        wanted.into_iter().map(|w| jid::normalized(&w)).filter(|w| all.iter().any(|c| &c.id == w)).collect()
    };
    let found = link.avatars(&listed).await;
    let pictures: Vec<(String, Vec<u8>)> = listed.into_iter().filter_map(|id| found.get(&id).map(|b| (id, b.clone()))).collect();
    let made = tauri::async_runtime::spawn_blocking(move || {
        let mut total = 0;
        let mut made = Vec::new();
        for (chat, bytes) in pictures {
            let Some(jpeg) = square_jpeg(&bytes) else { continue };
            if jpeg.len() > inbox_digest::AVATAR_MAX_BYTES
                || total + jpeg.len() > inbox_digest::AVATAR_BATCH * inbox_digest::AVATAR_MAX_BYTES
            {
                continue;
            }
            total += jpeg.len();
            use base64::Engine;
            made.push(ChatAvatar {
                version: inbox_digest::avatar_version(&bytes),
                chat,
                jpeg: base64::engine::general_purpose::STANDARD.encode(jpeg),
            });
        }
        made
    })
    .await
    .unwrap_or_default();
    CompanionResponse { avatars: json(&made), ..CompanionResponse::success(&request.id) }
}

/// A picture cropped to a square in its middle, `AVATAR_SIDE` pixels across, as a JPEG.
fn square_jpeg(bytes: &[u8]) -> Option<Vec<u8>> {
    let image = image::ImageReader::new(std::io::Cursor::new(bytes)).with_guessed_format().ok()?.decode().ok()?;
    let side = image.width().min(image.height());
    if side == 0 {
        return None;
    }
    let square = image.crop_imm((image.width() - side) / 2, (image.height() - side) / 2, side, side);
    let small = image::DynamicImage::from(square.thumbnail(inbox_digest::AVATAR_SIDE, inbox_digest::AVATAR_SIDE).to_rgb8());
    let mut out = std::io::Cursor::new(Vec::new());
    small.write_to(&mut out, image::ImageFormat::Jpeg).ok()?;
    Some(out.into_inner())
}

/// The list says which chats have a picture only once Nook fetched it, so listing the inbox fetches the pictures of the
/// listed chats in the background: at most one fetch at a time and one a minute (each chat is asked at most every six
/// hours by the link itself). The next look at the inbox then names them, and a live phone hears it.
fn warm_avatars(app: &AppHandle, list: &[Conversation]) {
    static BUSY: AtomicBool = AtomicBool::new(false);
    static LAST: AtomicI64 = AtomicI64::new(0);
    let now = chrono::Utc::now().timestamp();
    if list.is_empty() || now - LAST.load(Ordering::Relaxed) < 60 || BUSY.swap(true, Ordering::AcqRel) {
        return;
    }
    LAST.store(now, Ordering::Relaxed);
    let ids: Vec<String> = list.iter().take(inbox_digest::INBOX_LIMIT).map(|c| c.id.clone()).collect();
    let Some(link) = app.try_state::<Connectors>().map(|c| c.whatsapp.clone()) else {
        BUSY.store(false, Ordering::Release);
        return;
    };
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let before = ids.iter().filter(|id| link.with_avatar(id, |_| ()).is_some()).count();
        let found = link.avatars(&ids).await;
        BUSY.store(false, Ordering::Release);
        if found.len() > before {
            if let Some(companion) = app.try_state::<super::Companion>() {
                companion.server.nudge();
            }
        }
    });
}
