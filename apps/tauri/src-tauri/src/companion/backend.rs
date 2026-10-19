//! De sessies voor de companion-server. De agents en de werkruimte komen nog; tot dan geeft deze backend een lege
//! lijst. Wie de agents bouwt, vult hier `sessions` en de acties in (zie `nook_core::companion::backend`).

use async_trait::async_trait;
use nook_core::companion::{BackendSession, CompanionBackend};
use tauri::AppHandle;

pub struct AppBackend {
    #[allow(dead_code)]
    app: AppHandle,
}

impl AppBackend {
    pub fn new(app: AppHandle) -> Self {
        Self { app }
    }
}

#[async_trait]
impl CompanionBackend for AppBackend {
    async fn sessions(&self) -> Vec<BackendSession> {
        Vec::new()
    }

    async fn decide(&self, _session: &str, _item: &str, _allow: bool) -> Result<(), String> {
        Err("Er lopen hier nog geen agents.".into())
    }

    async fn answer(&self, _session: &str, _item: &str, _text: &str) -> Result<(), String> {
        Err("Er lopen hier nog geen agents.".into())
    }

    async fn send(&self, _session: &str, _text: &str) -> Result<(), String> {
        Err("Er lopen hier nog geen agents.".into())
    }

    async fn stop(&self, _session: &str) -> Result<(), String> {
        Err("Er lopen hier nog geen agents.".into())
    }
}
