use std::sync::{Arc, Mutex, RwLock};

use nook_core::nooks::NookChat;
use nook_core::secrets::SecretStore;
use nook_core::settings::Settings;
use nook_core::store::NookStore;

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
}

impl AppState {
    pub fn new(secrets: Arc<dyn SecretStore>) -> Self {
        let store = NookStore::open_default().or_else(|_| NookStore::in_memory()).expect("database");
        Self {
            settings: RwLock::new(Settings::load()),
            chat: Mutex::new(NookChat::load()),
            chat_save: Mutex::new(()),
            store: Arc::new(store),
            secrets,
            running: Mutex::new(Default::default()),
            pending_route: Mutex::new(None),
        }
    }

    pub fn settings(&self) -> Settings {
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
