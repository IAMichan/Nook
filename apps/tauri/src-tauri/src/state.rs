use std::sync::{Arc, Mutex, RwLock};

use nook_core::nooks::NookChat;
use nook_core::secrets::SecretStore;
use nook_core::settings::Settings;
use nook_core::store::NookStore;

tokio::task_local! {
    /// The settings a screen-work run reads instead of the stored ones: the same, but thinking on the model on this
    /// computer (`brain::screen_brain::routed`, the Mac's `ScreenBrain.routed`). Every step of that run (context, tools,
    /// privacy filter, model) follows it; saving settings never does.
    pub static ROUTED: Settings;
}

/// Terminal opened beside the chat in the main window when `run_command` executes.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatTerminal {
    pub folder: String,
    pub id: String,
}

/// Alles wat de commando's delen. Eén exemplaar, beheerd door Tauri.
pub struct AppState {
    pub settings: RwLock<Settings>,
    pub chat: Mutex<NookChat>,
    /// Keeps chat saves in order now that the file is written after the chat lock is released.
    chat_save: Mutex<()>,
    pub store: Arc<NookStore>,
    pub secrets: Arc<dyn SecretStore>,
    /// Lopende vragen per Nook, zodat Stoppen werkt.
    pub running: Mutex<std::collections::HashMap<String, tokio::task::AbortHandle>>,
    /// Waar het hoofdvenster heen moet zodra de interface geladen is.
    pub pending_route: Mutex<Option<String>>,
    /// Terminal die naast de chat getoond moet worden zodra het hoofdvenster geladen is.
    pub pending_chat_terminal: Mutex<Option<ChatTerminal>>,
}

impl AppState {
    pub fn new(secrets: Arc<dyn SecretStore>) -> Self {
        // A damaged nook.sqlite is set aside and started fresh, and the main window says so (`storage_recovery`, SV-81).
        let store =
            nook_core::storage_recovery::open(&nook_core::paths::database_file(), |p| NookStore::open(p).map_err(|e| e.to_string()))
                .or_else(|| NookStore::in_memory().ok())
                .expect("database");
        Self {
            settings: RwLock::new(Settings::load()),
            chat: Mutex::new(NookChat::load()),
            chat_save: Mutex::new(()),
            store: Arc::new(store),
            secrets,
            running: Mutex::new(Default::default()),
            pending_route: Mutex::new(None),
            pending_chat_terminal: Mutex::new(None),
        }
    }

    pub fn settings(&self) -> Settings {
        if let Ok(routed) = ROUTED.try_with(Clone::clone) {
            return routed;
        }
        self.settings.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub fn update_settings(&self, f: impl FnOnce(&mut Settings)) -> Settings {
        let mut guard = self.settings.write().unwrap_or_else(|e| e.into_inner());
        f(&mut guard);
        let _ = guard.save();
        guard.clone()
    }

    pub fn with_chat<T>(&self, f: impl FnOnce(&mut NookChat) -> T) -> T {
        let mut guard = self.chat.lock().unwrap_or_else(|e| e.into_inner());
        f(&mut guard)
    }

    /// Saves after every change; `write_atomic` never leaves half a file behind. The chat is only serialized under its
    /// lock: the write itself (several MB once images are attached) happens after, so nothing waits on the disk for it.
    pub fn save_chat(&self) {
        let _order = self.chat_save.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((file, Ok(bytes))) = self.with_chat(|c| c.snapshot()) {
            let _ = nook_core::paths::write_atomic(&file, &bytes);
        }
    }

    pub fn key_for(&self, provider: nook_core::provider::AIProvider) -> Option<String> {
        self.secrets.read(&provider.key_account())
    }
}
