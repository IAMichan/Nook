//! The chat apps Nook only hears of through Windows' notifications (Discord first) in the shared inbox: every few
//! seconds the new toasts are read ([`nook_core::chats::system_notices`]) and merged, and the interface hears of it
//! through `chats-changed`. An app with a link of its own here (WhatsApp's gateway, the chat helper's networks) is left
//! to that link.

use std::sync::Arc;

use nook_core::chats::system_notices::{default_database, SystemNoticeBridge};
use nook_core::chats::{ChatBridge, InboxStore};
use tauri::{AppHandle, Emitter, Manager};

use crate::connectors::Connectors;

/// Starts reading the notifications into the inbox. Called from `connectors::setup`, after `Connectors` is managed.
pub fn setup(app: &AppHandle, chats: Arc<InboxStore>) {
    if !cfg!(windows) {
        return;
    }
    let Some(path) = default_database() else { return };
    let handle = app.clone();
    let linked = Arc::new(move |chat_app: &str| handle.try_state::<Connectors>().is_some_and(|c| super::inbox::sends(&c, chat_app)));
    let bridge = SystemNoticeBridge::new(path, linked);
    let handle = app.clone();
    tauri::async_runtime::spawn(async move {
        loop {
            let before = chats.read(|inbox| inbox.clone());
            match chats.read_bridge(&bridge).await {
                Ok(true) => {
                    let _ = handle.emit("chats-changed", ());
                    // On a copy: nothing may wait for the inbox while the notices go out.
                    let now = chats.read(Clone::clone);
                    super::notify::arrived(&handle, &before, &now);
                }
                Ok(false) => {}
                Err(error) => log::info!("Chats: reading Windows notifications failed: {error}"),
            }
            tokio::time::sleep(bridge.interval()).await;
        }
    });
}
