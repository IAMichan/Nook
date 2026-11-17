//! Commando's voor de companion: de server op de computer (Instellingen › Companion) en de telefoonkant op Android.

use chrono::{DateTime, Utc};
use nook_core::companion::client::ClientSnapshot;
use nook_core::companion::push::PushSettings;
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
    /// What the phone said it runs; `None` until it said so.
    app_version: Option<String>,
    /// This computer no longer works with the phone's app (`CompanionCompatibility.phoneSupported`).
    outdated: bool,
    /// It works, but cannot use what this Nook added since (`CompanionCompatibility.phoneBehind`).
    behind: bool,
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
    push: Option<PushView>,
    /// Reaching this computer away from home, and keeping it reachable (Settings › Companion › Always reachable).
    away: Option<AwayView>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AwayView {
    relay: nook_core::companion::store::RelaySettings,
    /// Nook's own relay in this build; without one, only your own relay can be used.
    nook_relay: Option<String>,
    relay_status: nook_core::companion::relay::RelayStatus,
    keep_awake: nook_core::companion::keep_awake::KeepAwakeMode,
    /// What is held now and why (none while nothing is).
    keep_awake_decision: Option<nook_core::companion::keep_awake::Decision>,
    /// Nook keeps running: started at sign-in, and again when it stops (Task Scheduler, systemd).
    background_supported: bool,
    background: bool,
    /// Whether this computer has a Tailscale address phones were told about.
    tailscale: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PushView {
    settings: PushSettings,
    key_id: String,
    team_id: String,
    has_key: bool,
    can_push: bool,
    last_result: Option<String>,
    /// How pushes reach the phones: sealed through the relay, or with your own APNs key.
    route: nook_core::companion::relay_push::PushRoute,
    /// A relay is in use, so pushes can go through it (Android phones always do).
    relay_reachable: bool,
    /// Pushes go through the relay now.
    relay_active: bool,
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
    hosts.extend(companion::reach::interface_addresses().into_iter().map(|(_, ip)| ip.to_string()));
    let chosen = c.pairing_host.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let pairing = match (store.active_pending(now), store.pending_until(now), &c.server.state()) {
        (Some(key), Some(until), nook_core::companion::server::ServerState::Listening { port }) => {
            let host = chosen.unwrap_or_else(|| hosts[0].clone());
            let url = c.server.link(&host, *port, key).url();
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
            .map(|d| {
                // A phone that never said its version is not called out of date (as on the Mac).
                let known = d.protocol_version.is_some();
                DeviceView {
                    outdated: known && !nook_core::companion::phone_supported(d.protocol_version),
                    behind: known && nook_core::companion::phone_behind(d.protocol_version),
                    id: d.id,
                    name: d.name,
                    paired_at: d.paired_at,
                    last_seen: d.last_seen,
                    push: d.push_token.is_some(),
                    app_version: d.app_version,
                }
            })
            .collect(),
        pairing,
        push: Some(PushView {
            settings: store.push(),
            key_id: store.apns_ids().0,
            team_id: store.apns_ids().1,
            has_key: store.apns_pem().is_some(),
            can_push: store.can_push(),
            last_result: c.server.last_push(),
            route: c.server.push_route(),
            relay_reachable: c.server.relay_push_reachable(),
            relay_active: c.server.relay_push_active(),
        }),
        away: Some(AwayView {
            relay: store.relay(),
            nook_relay: companion::nook_relay(),
            relay_status: c.relay.status(),
            keep_awake: store.keep_awake(),
            keep_awake_decision: c.keep.lock().unwrap_or_else(|e| e.into_inner()).decision.filter(|d| d.reason.is_some()),
            background_supported: companion::background::supported(),
            background: companion::background::installed(),
            tailscale: c.server.reach().hosts.iter().any(|h| h.tailnet),
        }),
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
        push: None,
        away: None,
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
        companion::apply_relay(&companion);
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
        // The pairing window gets its own room, so a phone can even pair away from home.
        companion::apply_relay(&companion);
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
    {
        // A phone connected live hears it first, so it says "pair again" instead of looking for this computer.
        companion.server.revoke(&id);
        companion.server.store().remove(&id);
        companion::apply_relay(&companion);
    }
    #[cfg(not(desktop))]
    let _ = id;
    info(&companion)
}

/// Welke meldingen en wanneer (Instellingen › Companion › Pushmeldingen).
#[tauri::command]
pub fn companion_set_push(companion: State<'_, Companion>, settings: PushSettings) -> Result<CompanionInfo, String> {
    #[cfg(desktop)]
    {
        companion.server.store().set_push_settings(settings);
        Ok(info(&companion))
    }
    #[cfg(not(desktop))]
    {
        let _ = (companion, settings);
        Err(NO_SERVER.into())
    }
}

/// How pushes reach the phones: sealed through the relay, or straight to Apple with your own key.
#[tauri::command]
pub fn companion_set_push_route(
    companion: State<'_, Companion>,
    route: nook_core::companion::relay_push::PushRoute,
) -> Result<CompanionInfo, String> {
    #[cfg(desktop)]
    {
        companion.server.store().set_push_route(route);
        Ok(info(&companion))
    }
    #[cfg(not(desktop))]
    {
        let _ = (companion, route);
        Err(NO_SERVER.into())
    }
}

/// Sleutel-id, team-id en eventueel de inhoud van het .p8-bestand (dat gaat naar de kluis en wordt niet teruggegeven).
#[tauri::command]
pub fn companion_set_apns(
    companion: State<'_, Companion>,
    key_id: String,
    team_id: String,
    pem: Option<String>,
) -> Result<CompanionInfo, String> {
    #[cfg(desktop)]
    {
        let store = companion.server.store();
        store.set_apns_ids(&key_id, &team_id);
        if let Some(pem) = pem.filter(|p| !p.trim().is_empty()) {
            if !store.save_apns_pem(&pem) {
                return Err("Dat is geen geldige .p8-sleutel.".into());
            }
        }
        companion.server.forget_apns_token();
        Ok(info(&companion))
    }
    #[cfg(not(desktop))]
    {
        let _ = (companion, key_id, team_id, pem);
        Err(NO_SERVER.into())
    }
}

#[tauri::command]
pub fn companion_remove_apns_key(companion: State<'_, Companion>) -> CompanionInfo {
    #[cfg(desktop)]
    {
        companion.server.store().remove_apns_pem();
        companion.server.forget_apns_token();
    }
    info(&companion)
}

#[tauri::command]
pub async fn companion_push_test(companion: State<'_, Companion>) -> Result<String, String> {
    #[cfg(desktop)]
    {
        Ok(companion.server.send_test().await)
    }
    #[cfg(not(desktop))]
    {
        let _ = companion;
        Err(NO_SERVER.into())
    }
}

// Always reachable: the relay, keeping the computer awake, keeping Nook running.

/// Turns the relay on or off, and picks Nook's relay or your own (`address`).
#[tauri::command]
pub fn companion_set_relay(companion: State<'_, Companion>, enabled: bool, own: bool, address: String) -> Result<CompanionInfo, String> {
    #[cfg(desktop)]
    {
        let address = address.trim().to_string();
        if own && enabled && !address.is_empty() && nook_core::companion::transport::normalize_relay(&address).is_none() {
            return Err("That is not an https address.".into());
        }
        companion.server.store().set_relay(nook_core::companion::store::RelaySettings { enabled, own, address });
        companion::apply_relay(&companion);
        Ok(info(&companion))
    }
    #[cfg(not(desktop))]
    {
        let _ = (companion, enabled, own, address);
        Err(NO_SERVER.into())
    }
}

/// *Test relay*: a round trip through the relay as a paired phone makes it; the time in milliseconds.
#[tauri::command]
pub async fn companion_test_relay(companion: State<'_, Companion>) -> Result<u64, String> {
    #[cfg(desktop)]
    {
        companion.relay.test().await
    }
    #[cfg(not(desktop))]
    {
        let _ = companion;
        Err(NO_SERVER.into())
    }
}

#[tauri::command]
pub fn companion_set_keep_awake(
    companion: State<'_, Companion>,
    mode: nook_core::companion::keep_awake::KeepAwakeMode,
) -> Result<CompanionInfo, String> {
    #[cfg(desktop)]
    {
        companion.server.store().set_keep_awake(mode);
        Ok(info(&companion))
    }
    #[cfg(not(desktop))]
    {
        let _ = (companion, mode);
        Err(NO_SERVER.into())
    }
}

/// Keeps Nook running (Task Scheduler on Windows, a systemd user service on Linux), or stops doing so.
#[tauri::command]
pub fn companion_set_background(companion: State<'_, Companion>, on: bool) -> Result<CompanionInfo, String> {
    #[cfg(desktop)]
    {
        companion::background::set(on)?;
        Ok(info(&companion))
    }
    #[cfg(not(desktop))]
    {
        let _ = (companion, on);
        Err(NO_SERVER.into())
    }
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

/// Makes another paired computer the active one; the kept connection moves to it.
#[tauri::command]
pub fn companion_client_switch(app: AppHandle, companion: State<'_, Companion>, id: String) -> ClientView {
    let snapshot = companion.client.switch_to(&id);
    companion.poll.restart();
    view(&app, snapshot)
}

/// Takes a waiting request out of the outbox ("Don't send").
#[tauri::command]
pub fn companion_client_discard(app: AppHandle, companion: State<'_, Companion>, id: String) -> ClientView {
    view(&app, companion.client.discard(&id))
}

/// Asks the other paired computers for their sessions now.
#[tauri::command]
pub async fn companion_client_others(app: AppHandle, companion: State<'_, Companion>) -> Result<ClientView, String> {
    Ok(view(&app, companion.client.refresh_others().await))
}

/// The push keys of every paired computer, for the notification service (`NookPush.kt`).
#[tauri::command]
pub fn companion_client_push_keys(companion: State<'_, Companion>) -> Vec<nook_core::companion::client::PushKey> {
    companion.client.push_keys()
}

/// Gives every paired computer this phone's push token (Firebase Cloud Messaging).
#[tauri::command]
pub async fn companion_client_register_push(companion: State<'_, Companion>, token: String) -> Result<usize, String> {
    let count = companion.client.register_push(&token).await;
    companion.poll.pushing.store(count > 0, std::sync::atomic::Ordering::SeqCst);
    Ok(count)
}

/// Denies a request and tells the agent why (`decide` with `text`).
#[tauri::command]
pub async fn companion_client_deny(
    app: AppHandle,
    companion: State<'_, Companion>,
    session: String,
    item: String,
    reason: String,
) -> Result<ClientView, String> {
    Ok(view(&app, companion.client.decide_with_reason(&session, &item, false, Some(&reason)).await))
}

/// The answer of `companion_client_call`: the new state, and what the computer sent back (`None` when it was refused or
/// out of reach; the state says why).
#[derive(Serialize)]
pub struct CallResult {
    view: ClientView,
    response: Option<nook_core::companion::CompanionResponse>,
}

/// Every other request of the phone side (the whole conversation, a new session, Nook's chats, home, limits, the Chats
/// tab, managing a session), as the iPhone app makes them. The computer decides what this phone may do.
#[tauri::command]
pub async fn companion_client_call(
    app: AppHandle,
    companion: State<'_, Companion>,
    call: nook_core::companion::client::ClientCall,
) -> Result<CallResult, String> {
    let (snapshot, response) = companion.client.call(call).await;
    Ok(CallResult { view: view(&app, snapshot), response })
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
