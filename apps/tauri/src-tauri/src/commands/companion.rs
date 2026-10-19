//! Commando's voor de companion: de server op de computer (Instellingen › Companion) en de telefoonkant op Android.

use chrono::{DateTime, Utc};
use nook_core::companion::client::ClientSnapshot;
use serde::Serialize;
use tauri::{AppHandle, Emitter, State};

use crate::companion::{self, Companion};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceView {
    id: String,
    name: String,
    paired_at: DateTime<Utc>,
    last_seen: Option<DateTime<Utc>>,
    push: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingView {
    url: String,
    qr_svg: String,
    host: String,
    until: DateTime<Utc>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CompanionInfo {
    /// Deze app kan server zijn (Windows, Linux).
    server: bool,
    /// Deze app laat de telefoonkant zien (Android).
    client: bool,
    enabled: bool,
    state: Option<nook_core::companion::server::ServerState>,
    computer_name: String,
    /// Waar een telefoon deze computer kan vinden: `naam.local` en de adressen in het lokale netwerk.
    hosts: Vec<String>,
    devices: Vec<DeviceView>,
    pairing: Option<PairingView>,
}

#[cfg(desktop)]
fn qr_svg(text: &str) -> String {
    match qrcode::QrCode::with_error_correction_level(text, qrcode::EcLevel::M) {
        Ok(code) => code
            .render::<qrcode::render::svg::Color>()
            .min_dimensions(200, 200)
            .quiet_zone(true)
            .dark_color(qrcode::render::svg::Color("#000000"))
            .light_color(qrcode::render::svg::Color("#ffffff"))
            .build(),
        Err(_) => String::new(),
    }
}

#[cfg(desktop)]
fn info(c: &Companion) -> CompanionInfo {
    let store = c.server.store();
    let now = Utc::now();
    let mut hosts = vec![companion::local_host_name()];
    hosts.extend(companion::mdns::local_addresses());
    let chosen = c.pairing_host.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let pairing = match (store.active_pending(now), store.pending_until(now), &c.server.state()) {
        (Some(key), Some(until), nook_core::companion::server::ServerState::Listening { port }) => {
            let host = chosen.unwrap_or_else(|| hosts[0].clone());
            let link = nook_core::companion::PairingLink { host: host.clone(), port: *port, key, mac_name: c.server.name().into() };
            let url = link.url();
            Some(PairingView { qr_svg: qr_svg(&url), url, host, until })
        }
        _ => None,
    };
    CompanionInfo {
        server: true,
        client: companion::client_enabled(),
        enabled: store.enabled(),
        state: Some(c.server.state()),
        computer_name: c.server.name().into(),
        hosts,
        devices: store
            .devices()
            .into_iter()
            .map(|d| DeviceView { id: d.id, name: d.name, paired_at: d.paired_at, last_seen: d.last_seen, push: d.push_token.is_some() })
            .collect(),
        pairing,
    }
}

#[cfg(not(desktop))]
fn info(_: &Companion) -> CompanionInfo {
    CompanionInfo {
        server: false,
        client: true,
        enabled: false,
        state: None,
        computer_name: companion::device_name(),
        hosts: Vec::new(),
        devices: Vec::new(),
        pairing: None,
    }
}

#[tauri::command]
pub fn companion_info(companion: State<'_, Companion>) -> CompanionInfo {
    info(&companion)
}

#[cfg(not(desktop))]
const NO_SERVER: &str = "Een telefoon is geen companion-server; koppel hem met een Mac of pc.";

#[tauri::command]
pub async fn companion_set_enabled(companion: State<'_, Companion>, enabled: bool) -> Result<CompanionInfo, String> {
    #[cfg(desktop)]
    {
        companion.server.store().set_enabled(enabled);
        if !enabled {
            companion.server.store().cancel_pairing();
        }
        let state = companion.server.apply().await;
        companion.announcer.apply(&state, companion.server.name());
        Ok(info(&companion))
    }
    #[cfg(not(desktop))]
    {
        let _ = (companion, enabled);
        Err(NO_SERVER.into())
    }
}

/// Opent een koppelvenster (vijf minuten, één keer) met `host` als adres in de code.
#[tauri::command]
pub fn companion_begin_pairing(companion: State<'_, Companion>, host: Option<String>) -> Result<CompanionInfo, String> {
    #[cfg(desktop)]
    {
        let host = host.filter(|h| nook_core::companion::valid_host(h)).unwrap_or_else(companion::local_host_name);
        companion.server.pairing_link(&host).ok_or("De companion luistert niet.")?;
        *companion.pairing_host.lock().unwrap_or_else(|e| e.into_inner()) = Some(host);
        Ok(info(&companion))
    }
    #[cfg(not(desktop))]
    {
        let _ = (companion, host);
        Err(NO_SERVER.into())
    }
}

#[tauri::command]
pub fn companion_cancel_pairing(companion: State<'_, Companion>) -> CompanionInfo {
    #[cfg(desktop)]
    companion.server.store().cancel_pairing();
    info(&companion)
}

#[tauri::command]
pub fn companion_remove_device(companion: State<'_, Companion>, id: String) -> CompanionInfo {
    #[cfg(desktop)]
    companion.server.store().remove(&id);
    #[cfg(not(desktop))]
    let _ = id;
    info(&companion)
}

// De telefoonkant

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientView {
    #[serde(flatten)]
    snapshot: ClientSnapshot,
    device_name: String,
}

fn view(app: &AppHandle, snapshot: ClientSnapshot) -> ClientView {
    let _ = app.emit("companion-client", &snapshot);
    ClientView { snapshot, device_name: companion::device_name() }
}

#[tauri::command]
pub fn companion_client(app: AppHandle, companion: State<'_, Companion>) -> ClientView {
    view(&app, companion.client.snapshot())
}

#[tauri::command]
pub async fn companion_client_pair(
    app: AppHandle,
    companion: State<'_, Companion>,
    link: String,
    name: String,
) -> Result<ClientView, String> {
    let name = if name.trim().is_empty() { companion::device_name() } else { name };
    let snapshot = companion.client.pair(&link, &name).await;
    #[cfg(mobile)]
    if snapshot.phase == nook_core::companion::client::Phase::Connected {
        use tauri_plugin_notification::NotificationExt;
        let _ = app.notification().request_permission();
    }
    companion.poll.wake();
    Ok(view(&app, snapshot))
}

#[tauri::command]
pub fn companion_client_unpair(app: AppHandle, companion: State<'_, Companion>) -> ClientView {
    view(&app, companion.client.unpair())
}

#[tauri::command]
pub async fn companion_client_refresh(app: AppHandle, companion: State<'_, Companion>) -> Result<ClientView, String> {
    Ok(view(&app, companion.client.refresh().await))
}

#[tauri::command]
pub async fn companion_client_decide(
    app: AppHandle,
    companion: State<'_, Companion>,
    session: String,
    item: String,
    allow: bool,
) -> Result<ClientView, String> {
    Ok(view(&app, companion.client.decide(&session, &item, allow).await))
}

#[tauri::command]
pub async fn companion_client_answer(
    app: AppHandle,
    companion: State<'_, Companion>,
    session: String,
    item: String,
    text: String,
) -> Result<ClientView, String> {
    Ok(view(&app, companion.client.answer(&session, &item, &text).await))
}

#[tauri::command]
pub async fn companion_client_send(
    app: AppHandle,
    companion: State<'_, Companion>,
    session: String,
    text: String,
) -> Result<ClientView, String> {
    Ok(view(&app, companion.client.send(&session, &text).await))
}

#[tauri::command]
pub async fn companion_client_stop(app: AppHandle, companion: State<'_, Companion>, session: String) -> Result<ClientView, String> {
    Ok(view(&app, companion.client.stop(&session).await))
}

#[tauri::command]
pub fn companion_client_clear_notice(companion: State<'_, Companion>) {
    companion.client.clear_notice();
}

/// De interface staat voor (of niet): bepaalt hoe vaak de lijst wordt opgehaald en of er meldingen komen.
#[tauri::command]
pub fn companion_client_visible(companion: State<'_, Companion>, visible: bool) {
    companion.poll.set_visible(visible);
}
