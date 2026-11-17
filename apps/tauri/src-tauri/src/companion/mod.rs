//! De companion in de app. Op Windows en Linux is de computer de server (zoals de Mac): de iPhone-app of de
//! Android-app koppelt en keurt goed, antwoordt, stuurt en stopt. Op Android is de app de telefoon (client) die met een
//! Mac of pc koppelt. Het protocol zelf zit in `nook_core::companion`.

#[cfg(desktop)]
pub mod backend;
#[cfg(desktop)]
pub mod background;
#[cfg(desktop)]
pub mod home;
#[cfg(desktop)]
pub mod inbox;
#[cfg(desktop)]
pub mod keep_awake;
pub mod mdns;
#[cfg(desktop)]
pub mod nook_chat;
mod poll;
#[cfg(desktop)]
pub mod pulls;
#[cfg(desktop)]
pub mod reach;
#[cfg(desktop)]
pub mod remote;

use std::sync::Arc;

use nook_core::companion::client::{CompanionClient, HostResolver};
use tauri::{AppHandle, Manager};

#[cfg(desktop)]
use nook_core::companion::keep_awake::{self as policy, Decision};
#[cfg(desktop)]
use nook_core::companion::relay::RelayHost;
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
    /// The rooms on the relay, so the phone reaches this computer away from home.
    #[cfg(desktop)]
    pub relay: Arc<RelayHost>,
    /// Keeping this computer awake for the phone: the block held now, and why.
    #[cfg(desktop)]
    pub keep: std::sync::Mutex<KeepAwake>,
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

/// Nook's own relay (the build setting `NOOK_RELAY_URL`, as on the Mac); `None` in a build without one.
#[cfg(desktop)]
pub fn nook_relay() -> Option<String> {
    option_env!("NOOK_RELAY_URL").and_then(nook_core::companion::transport::normalize_relay)
}

/// The relay in use: the user's own when chosen (or when this build has none of its own), else Nook's.
#[cfg(desktop)]
pub fn current_relay(store: &CompanionStore) -> Option<String> {
    let settings = store.relay();
    match nook_relay() {
        Some(nook) if !settings.own => Some(nook),
        _ => nook_core::companion::transport::normalize_relay(&settings.address),
    }
}

#[cfg(desktop)]
#[derive(Default)]
pub struct KeepAwake {
    pub holder: keep_awake::Holder,
    pub decision: Option<Decision>,
    /// When a session last worked or waited on you (seconds since 1970).
    last_busy: Option<i64>,
}

/// How often the companion looks at the network, the relay rooms and the sleep block.
#[cfg(desktop)]
const TICK: std::time::Duration = std::time::Duration::from_secs(15);

/// Applies the relay settings now (after a change in Settings, a pairing, or an unpaired phone).
#[cfg(desktop)]
pub fn apply_relay(companion: &Companion) {
    let store = companion.server.store();
    companion.relay.apply(store.relay().enabled, current_relay(store).as_deref());
    let mut reach = companion.server.reach();
    reach.relay = companion.relay.advertised();
    companion.server.set_reach(reach);
}

/// One look: where this computer can be reached (a new network opens the relay rooms again), the relay rooms, and
/// whether to keep the computer awake.
#[cfg(desktop)]
async fn tick(companion: &Companion, slept: bool) {
    let server = &companion.server;
    let hosts = reach::hosts(&local_host_name());
    let moved = server.reach().hosts != hosts;
    server.set_reach(nook_core::companion::server::Reach { hosts, relay: server.reach().relay });
    apply_relay(companion);
    // After sleep or on another network the relay sockets are dead without knowing it: connect again at once.
    if (moved || slept) && !server.reach().relay.is_empty() {
        companion.relay.reconnect();
    }

    let store = server.store();
    let now = chrono::Utc::now();
    let busy_now =
        store.enabled() && server.sessions().await.iter().any(|s| policy::is_busy(&s.digest.attention, !s.digest.items.is_empty()));
    let phone = store.devices().iter().any(|d| d.last_seen.is_some_and(|seen| (now - seen).num_seconds() < policy::PHONE_RECENT_SECONDS));
    let (on_power, battery) = keep_awake::power();
    let mut keep = companion.keep.lock().unwrap_or_else(|e| e.into_inner());
    if busy_now {
        keep.last_busy = Some(now.timestamp());
    }
    let busy = keep.last_busy.is_some_and(|t| now.timestamp() - t < policy::GRACE_SECONDS);
    let decision = if store.enabled() { policy::decide(store.keep_awake(), busy, phone, on_power, battery) } else { Decision::NONE };
    keep.holder.set(decision.hold);
    keep.decision = Some(decision);
}

pub fn setup(app: &AppHandle) {
    let state = app.state::<AppState>();
    let resolver: Arc<dyn HostResolver> = Arc::new(mdns::LocalResolver);
    let version = app.package_info().version.to_string();
    let client = Arc::new(CompanionClient::new(state.secrets.clone(), resolver).with_app_version(&version));
    #[cfg(desktop)]
    let server = {
        let store = Arc::new(CompanionStore::load_default(state.secrets.clone()));
        let server = Arc::new(CompanionServer::new(
            store,
            Arc::new(backend::AppBackend::new(app.clone())),
            Some(state.store.clone()),
            device_name(),
        ));
        server.set_app_version(&version);
        server.set_build_relay(nook_relay().is_some());
        server
    };
    #[cfg(desktop)]
    let relay = Arc::new(RelayHost::new(server.clone(), tauri::async_runtime::handle().inner().clone()));
    app.manage(Companion {
        #[cfg(desktop)]
        server: server.clone(),
        #[cfg(desktop)]
        announcer: mdns::Announcer::default(),
        #[cfg(desktop)]
        pairing_host: Default::default(),
        #[cfg(desktop)]
        relay,
        #[cfg(desktop)]
        keep: Default::default(),
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
            // A tick that comes much later than asked means the computer slept in between. The wall clock, since the
            // monotonic one stands still during suspend on Linux.
            let mut last = std::time::SystemTime::now();
            loop {
                let slept = last.elapsed().is_ok_and(|gap| gap > TICK * 4);
                last = std::time::SystemTime::now();
                tick(&companion, slept).await;
                tokio::time::sleep(TICK).await;
            }
        });
    }
    if client_enabled() {
        poll::start(app);
    }
}
