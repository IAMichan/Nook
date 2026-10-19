//! De companion in de app. Op Windows en Linux is de computer de server (zoals de Mac): de iPhone-app of de
//! Android-app koppelt en keurt goed, antwoordt, stuurt en stopt. Op Android is de app de telefoon (client) die met een
//! Mac of pc koppelt. Het protocol zelf zit in `nook_core::companion`.

#[cfg(desktop)]
pub mod backend;
pub mod mdns;
mod poll;

use std::sync::Arc;

use nook_core::companion::client::{CompanionClient, HostResolver};
use tauri::{AppHandle, Manager};

#[cfg(desktop)]
use nook_core::companion::server::CompanionServer;
#[cfg(desktop)]
use nook_core::companion::store::CompanionStore;

use crate::state::AppState;

pub struct Companion {
    #[cfg(desktop)]
    pub server: Arc<CompanionServer>,
    #[cfg(desktop)]
    pub announcer: mdns::Announcer,
    /// Het adres in de koppelcode dat de gebruiker koos (`naam.local` of een IP-adres).
    #[cfg(desktop)]
    pub pairing_host: std::sync::Mutex<Option<String>>,
    pub client: Arc<CompanionClient>,
    pub poll: poll::Poller,
}

/// De naam die de andere kant ziet: de computernaam, of het model van de telefoon.
pub fn device_name() -> String {
    #[cfg(target_os = "android")]
    {
        let model = std::process::Command::new("getprop")
            .arg("ro.product.model")
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .filter(|m| !m.is_empty());
        model.unwrap_or_else(|| "Android".into())
    }
    #[cfg(not(target_os = "android"))]
    {
        let name = gethostname::gethostname().to_string_lossy().trim().to_string();
        if name.is_empty() {
            "Nook".into()
        } else {
            name
        }
    }
}

/// De hostnaam zoals de telefoon hem via mDNS vindt: `naam.local`.
#[cfg(desktop)]
pub fn local_host_name() -> String {
    let name: String = device_name().chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' }).collect();
    let name = name.trim_matches('-');
    let name = if name.is_empty() { "nook" } else { name };
    if name.contains('.') {
        name.to_string()
    } else {
        format!("{name}.local")
    }
}

/// Of deze app de telefoonkant laat zien: op Android altijd; op de computer alleen om te testen (`NOOK_COMPANION_CLIENT=1`).
pub fn client_enabled() -> bool {
    cfg!(target_os = "android") || std::env::var("NOOK_COMPANION_CLIENT").is_ok_and(|v| v == "1")
}

pub fn setup(app: &AppHandle) {
    let state = app.state::<AppState>();
    let resolver: Arc<dyn HostResolver> = Arc::new(mdns::LocalResolver);
    let client = Arc::new(CompanionClient::new(state.secrets.clone(), resolver));
    #[cfg(desktop)]
    let server = {
        let store = Arc::new(CompanionStore::load_default(state.secrets.clone()));
        Arc::new(CompanionServer::new(store, Arc::new(backend::AppBackend::new(app.clone())), Some(state.store.clone()), device_name()))
    };
    app.manage(Companion {
        #[cfg(desktop)]
        server: server.clone(),
        #[cfg(desktop)]
        announcer: mdns::Announcer::default(),
        #[cfg(desktop)]
        pairing_host: Default::default(),
        client,
        poll: poll::Poller::default(),
    });
    #[cfg(desktop)]
    {
        let app = app.clone();
        tauri::async_runtime::spawn(async move {
            let companion = app.state::<Companion>();
            let state = companion.server.apply().await;
            companion.announcer.apply(&state, companion.server.name());
        });
    }
    if client_enabled() {
        poll::start(app);
    }
}
