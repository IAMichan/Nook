//! What every chat app's bridge does (`ChatBridge` in `apps/macos/Services/Messages/ChatBridges.swift`): it reads its
//! app and hands the shared inbox [`BridgedChat`]s. A bridge only translates; the rules live in [`super::ChatInbox`].

use std::time::Duration;

use async_trait::async_trait;

use super::BridgedChat;

#[async_trait]
pub trait ChatBridge: Send + Sync {
    /// The app's source id (`whatsapp`, `telegram`, `slack`…): the `app` of every chat it brings.
    fn app(&self) -> &str;

    /// What turns, reads and failures are kept under: the app's id, unless two bridges read one app.
    fn bridge_id(&self) -> &str {
        self.app()
    }

    /// Whether it can read right now: the app is linked, or a token is set.
    fn is_ready(&self) -> bool;

    /// Its last read worked.
    fn is_working(&self) -> bool {
        self.is_ready()
    }

    /// How long to wait between two reads.
    fn interval(&self) -> Duration {
        Duration::from_secs(60)
    }

    /// The chats that changed since the last read (everything on the first), with their newest messages. A bridge that
    /// is pushed to (a webhook, a live line) merges as messages arrive and may return nothing here.
    async fn read(&self) -> Result<Vec<BridgedChat>, String>;

    /// You are looking at this chat: the files it still waits for go first.
    fn hurry_files(&self, _chat: &str) {}

    /// Its app leaves a message deleted for everyone out of the history it gives, instead of saying so.
    fn history_omits_deleted(&self) -> bool {
        false
    }

    /// Its app's older messages can change (an edit, a deletion).
    fn history_changes(&self) -> bool {
        true
    }
}
