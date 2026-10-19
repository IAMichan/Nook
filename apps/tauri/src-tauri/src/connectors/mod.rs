//! De koppelingen in de app: één hub met alle bronnen (GitHub, Stripe, agenda's, MCP-servers, WhatsApp, …), op de
//! achtergrond ververst. De interface hoort het via het event `connectors-changed`; een nieuw WhatsApp-bericht komt
//! als `whatsapp-message`.

use std::sync::{Arc, OnceLock};

use nook_core::connectors::cloud::{Calcom, N8n, Notion, Resend, Stripe, Vercel};
use nook_core::connectors::custom::CustomSources;
use nook_core::connectors::feeds::CalendarFeeds;
use nook_core::connectors::github::GitHub;
use nook_core::connectors::hub::Env;
use nook_core::connectors::{mcp, whatsapp, ConnectorHub, ConnectorStore};
use tauri::{AppHandle, Emitter, Manager};

use crate::state::AppState;

/// Alles wat de commando's en tools van de koppelingen delen.
pub struct Connectors {
    pub env: Arc<Env>,
    pub hub: Arc<ConnectorHub>,
    pub github: Arc<GitHub>,
    pub whatsapp: Arc<whatsapp::WhatsAppLink>,
}

impl Connectors {
    /// Brengt de MCP-koppelingen in lijn met de servers in de instellingen.
    pub fn sync_mcp(&self) {
        mcp::connector::sync(&self.hub, &self.env);
        self.hub.changed();
    }
}

static HANDLE: OnceLock<AppHandle> = OnceLock::new();

/// De app, voor plekken zonder `ToolCtx` (de samenvatting op een plankaart).
pub fn handle() -> Option<AppHandle> {
    HANDLE.get().cloned()
}

/// Maakt de hub met alle bronnen en start het verversen. Wordt vanuit `setup` in `lib.rs` aangeroepen.
pub fn setup(app: &AppHandle) {
    let _ = HANDLE.set(app.clone());
    let secrets = app.state::<AppState>().secrets.clone();
    let env = Env::new(secrets, Arc::new(ConnectorStore::open_default()));
    let hub = ConnectorHub::new(env.store.clone());
    let github = GitHub::new(env.clone());
    let whatsapp = whatsapp::WhatsAppLink::new(env.clone(), cfg!(desktop));
    hub.register(github.clone());
    hub.register(Vercel::new(env.clone()));
    hub.register(Stripe::new(env.clone()));
    hub.register(Notion::new(env.clone()));
    hub.register(Calcom::new(env.clone()));
    hub.register(N8n::new(env.clone()));
    hub.register(Resend::new(env.clone()));
    hub.register(CalendarFeeds::new(env.clone()));
    hub.register(CustomSources::new(env.clone()));
    hub.register(whatsapp.clone());

    let handle = app.clone();
    hub.on_change(move || {
        let _ = handle.emit("connectors-changed", ());
    });
    let handle = app.clone();
    whatsapp.on_changed(move || {
        let _ = handle.emit("connectors-changed", ());
    });
    let handle = app.clone();
    whatsapp.on_arrived(move |arrived| {
        let _ = handle.emit("whatsapp-message", &arrived);
    });

    app.manage(Connectors { env: env.clone(), hub: hub.clone(), github, whatsapp: whatsapp.clone() });
    // Verversen en luisteren draaien op de runtime van Tauri.
    tauri::async_runtime::spawn(async move {
        mcp::connector::sync(&hub, &env);
        hub.start();
        whatsapp.start();
    });
}

/// Bij afsluiten: de GOWA die Nook startte gaat mee uit.
pub fn shutdown(app: &AppHandle) {
    if let Some(c) = app.try_state::<Connectors>() {
        c.whatsapp.stop_gowa();
    }
}
