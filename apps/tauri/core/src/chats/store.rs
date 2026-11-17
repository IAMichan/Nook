//! The shared inbox in memory and on disk (`chat-inbox.json`, as on the Mac). What goes to disk is
//! [`ChatInbox::for_disk`]: a chat whose app keeps its messages (WhatsApp through a gateway) is saved without them.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use chrono::Utc;

use super::{ChatBridge, ChatInbox};
use crate::paths;

pub const FILE_NAME: &str = "chat-inbox.json";

/// One [`ChatInbox`] for every chat app, behind one lock. Never call out of Nook while holding it.
pub struct InboxStore {
    inbox: Mutex<ChatInbox>,
    path: Option<PathBuf>,
    dirty: AtomicBool,
}

impl Default for InboxStore {
    fn default() -> Self {
        Self::memory()
    }
}

impl InboxStore {
    /// An inbox that is never saved (tests, and a phone without a data directory).
    pub fn memory() -> Self {
        Self { inbox: Mutex::default(), path: None, dirty: AtomicBool::new(false) }
    }

    /// The inbox in Nook's data directory.
    pub fn open_default() -> Self {
        Self::open(paths::support_directory().join(FILE_NAME))
    }

    /// The inbox saved at `path`; an unreadable or missing file starts empty (the apps bring their chats again).
    pub fn open(path: PathBuf) -> Self {
        let mut inbox: ChatInbox =
            std::fs::read(&path).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        inbox.trim(Utc::now());
        Self { inbox: Mutex::new(inbox), path: Some(path), dirty: AtomicBool::new(false) }
    }

    /// Changes the inbox; it is saved at the next [`Self::save`].
    pub fn with<T>(&self, f: impl FnOnce(&mut ChatInbox) -> T) -> T {
        let mut inbox = self.inbox.lock().unwrap_or_else(|e| e.into_inner());
        let result = f(&mut inbox);
        self.dirty.store(true, Ordering::Relaxed);
        result
    }

    /// Looks at the inbox without changing it.
    pub fn read<T>(&self, f: impl FnOnce(&ChatInbox) -> T) -> T {
        let inbox = self.inbox.lock().unwrap_or_else(|e| e.into_inner());
        f(&inbox)
    }

    /// Writes the inbox when it changed since the last save. True when it wrote.
    pub fn save(&self) -> std::io::Result<bool> {
        let Some(path) = &self.path else { return Ok(false) };
        if !self.dirty.swap(false, Ordering::Relaxed) {
            return Ok(false);
        }
        let data = self.read(|inbox| serde_json::to_vec(&inbox.for_disk()))?;
        if let Err(error) = paths::write_atomic(path, &data) {
            self.dirty.store(true, Ordering::Relaxed);
            return Err(error);
        }
        Ok(true)
    }

    /// One read of a bridge, merged. True when the inbox changed.
    pub async fn read_bridge(&self, bridge: &dyn ChatBridge) -> Result<bool, String> {
        if !bridge.is_ready() {
            return Ok(false);
        }
        let chats = bridge.read().await?;
        if chats.is_empty() {
            return Ok(false);
        }
        Ok(self.with(|inbox| inbox.merge_all(chats, Utc::now())))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chats::{BridgedChat, InboxMessage};
    use async_trait::async_trait;

    struct Fake;

    #[async_trait]
    impl ChatBridge for Fake {
        fn app(&self) -> &str {
            "telegram"
        }
        fn is_ready(&self) -> bool {
            true
        }
        async fn read(&self) -> Result<Vec<BridgedChat>, String> {
            Ok(vec![BridgedChat {
                app: "telegram".into(),
                name: "Ann".into(),
                chat_id: Some("1".into()),
                messages: vec![InboxMessage::new("m", "hello", Utc::now(), false)],
                ..Default::default()
            }])
        }
    }

    #[tokio::test]
    async fn a_bridge_read_lands_in_the_inbox_and_survives_a_restart_without_ephemeral_messages() {
        let dir = std::env::temp_dir().join(format!("nook-chat-inbox-{}", uuid::Uuid::new_v4()));
        let path = dir.join(FILE_NAME);
        let store = InboxStore::open(path.clone());
        assert!(store.read_bridge(&Fake).await.unwrap());
        store.with(|inbox| {
            inbox.merge(
                BridgedChat {
                    app: "whatsapp".into(),
                    name: "Bo".into(),
                    chat_id: Some("2".into()),
                    ephemeral: true,
                    messages: vec![InboxMessage::new("w", "secret", Utc::now(), false)],
                    ..Default::default()
                },
                Utc::now(),
            )
        });
        assert!(store.save().unwrap());
        assert!(!store.save().unwrap(), "nothing changed since");
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("hello"));
        assert!(!text.contains("secret"), "an ephemeral chat's messages never reach the disk");
        let again = InboxStore::open(path);
        assert_eq!(again.read(|i| i.threads.len()), 2);
        let _ = std::fs::remove_dir_all(dir);
    }
}
