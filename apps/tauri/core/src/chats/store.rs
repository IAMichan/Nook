//! The shared inbox in memory and on disk: in the chat archive (`chats.sqlite`, [`super::archive::ChatStore`]), which
//! keeps every message and is written with only what changed, else in `chat-inbox.json` when the archive cannot be
//! opened (as on the Mac). What goes to disk is [`ChatInbox::for_disk`]: a chat whose app keeps its messages (WhatsApp
//! through a gateway) is saved without them.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use chrono::{DateTime, Utc};

use super::archive::{ChatStore, Found};
use super::{ChatBridge, ChatInbox, InboxMessage};
use crate::paths;

pub const FILE_NAME: &str = "chat-inbox.json";

/// One [`ChatInbox`] for every chat app, behind one lock. Never call out of Nook while holding it.
pub struct InboxStore {
    inbox: Mutex<ChatInbox>,
    path: Option<PathBuf>,
    dirty: AtomicBool,
    /// The archive, and what was last written to it (`None`: everything is written at the next save).
    archive: Option<Mutex<(ChatStore, Option<ChatInbox>)>>,
}

impl Default for InboxStore {
    fn default() -> Self {
        Self::memory()
    }
}

impl InboxStore {
    /// An inbox that is never saved (tests, and a phone without a data directory).
    pub fn memory() -> Self {
        Self { inbox: Mutex::default(), path: None, dirty: AtomicBool::new(false), archive: None }
    }

    /// The inbox in Nook's data directory: from the archive, else from `chat-inbox.json` (also the first time the
    /// archive is made, so nothing an earlier version kept is lost).
    pub fn open_default() -> Self {
        let dir = paths::support_directory();
        Self::open_with_archive(dir.join(FILE_NAME), dir.join(super::archive::FILE_NAME))
    }

    /// The inbox kept in the archive at `archive`, with `json` as the fallback and the first start's source.
    pub fn open_with_archive(json: PathBuf, archive: PathBuf) -> Self {
        let Some(store) = ChatStore::open(&archive) else { return Self::open(json) };
        let loaded = store.load_inbox(ChatInbox::KEEP);
        let written = loaded.clone();
        let mut inbox = loaded
            .or_else(|| std::fs::read(&json).ok().and_then(|data| serde_json::from_slice(&data).ok()))
            .unwrap_or_default();
        inbox.trim(Utc::now());
        let dirty = written.is_none();
        Self {
            inbox: Mutex::new(inbox),
            path: Some(json),
            dirty: AtomicBool::new(dirty),
            archive: Some(Mutex::new((store, written))),
        }
    }

    /// The inbox saved at `path`; an unreadable or missing file starts empty (the apps bring their chats again).
    pub fn open(path: PathBuf) -> Self {
        let mut inbox: ChatInbox =
            std::fs::read(&path).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        inbox.trim(Utc::now());
        Self { inbox: Mutex::new(inbox), path: Some(path), dirty: AtomicBool::new(false), archive: None }
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
        if let Some(archive) = &self.archive {
            let current = self.read(ChatInbox::for_disk);
            let mut guard = archive.lock().unwrap_or_else(|e| e.into_inner());
            let (store, written) = &mut *guard;
            if store.apply(written.as_ref(), &current) {
                *written = Some(current);
                return Ok(true);
            }
            // Written again from nothing at the next save.
            *written = None;
            self.dirty.store(true, Ordering::Relaxed);
            return Err(std::io::Error::other("chat archive not written"));
        }
        let data = self.read(|inbox| serde_json::to_vec(&inbox.for_disk()))?;
        if let Err(error) = paths::write_atomic(path, &data) {
            self.dirty.store(true, Ordering::Relaxed);
            return Err(error);
        }
        Ok(true)
    }

    /// The archive, when there is one: for scrolling back past what the inbox holds and for searching every message.
    pub fn archive<T>(&self, f: impl FnOnce(&ChatStore) -> T) -> Option<T> {
        let archive = self.archive.as_ref()?;
        let guard = archive.lock().unwrap_or_else(|e| e.into_inner());
        Some(f(&guard.0))
    }

    /// The `limit` messages of a chat before `before` from the archive, oldest first (scrolling back).
    pub fn older(&self, key: &str, before: DateTime<Utc>, excluding: &HashSet<String>, limit: usize) -> Vec<InboxMessage> {
        self.archive(|a| a.older(key, before, excluding, limit)).unwrap_or_default()
    }

    /// Every message that holds any of these words, grouped by chat.
    pub fn search(&self, words: &[String], limit: usize) -> Vec<Found> {
        self.archive(|a| a.search(words, limit)).unwrap_or_default()
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

    #[tokio::test]
    async fn the_archive_takes_over_from_the_json_file_and_keeps_every_message() {
        let dir = std::env::temp_dir().join(format!("nook-chat-archive-{}", uuid::Uuid::new_v4()));
        let json = dir.join(FILE_NAME);
        let first = InboxStore::open(json.clone());
        assert!(first.read_bridge(&Fake).await.unwrap());
        first.save().unwrap();
        // A version with the archive: what the JSON file held comes along on its first start.
        let archive = dir.join(crate::chats::archive::FILE_NAME);
        let store = InboxStore::open_with_archive(json.clone(), archive.clone());
        assert_eq!(store.read(|i| i.threads.len()), 1);
        assert!(store.save().unwrap());
        assert_eq!(store.search(&["hello".into()], 5).len(), 1);
        assert_eq!(store.archive(|a| a.message_count(None)), Some(1));
        // And from the archive after that.
        let again = InboxStore::open_with_archive(json, archive);
        assert_eq!(again.read(|i| i.threads.len()), 1);
        assert!(!again.save().unwrap(), "nothing changed since");
        let _ = std::fs::remove_dir_all(dir);
    }
}
