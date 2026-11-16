//! The phone side (`CompanionClient.swift` of the iPhone app), for Android. One short connection per request, and one
//! kept connection while the app is in front (`stream`). A phone can be paired with up to eight computers
//! (`CompanionPairings`): one is active, the others are asked for their sessions now and then. Each pairing knows every
//! way to its computer (`transport::Route`) and keeps what waits to be sent while the computer is away (its outbox,
//! with a computer that lists `retry`). Pairings live in the app's secret store.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use super::device_key;
use super::models::*;
use super::seal::{self, Direction};
use super::transport::{self, Conn, Route};
use crate::secrets::SecretStore;

const EXCHANGE_TIMEOUT: Duration = Duration::from_secs(8);
/// Where pairings were kept before a phone could pair with several computers; read once and moved.
const PAIRING_ACCOUNT: &str = "companion.pairing";
const PAIRINGS_ACCOUNT: &str = "companion.pairings";
/// How many computers one phone pairs with.
pub const MAX_MACS: usize = 8;
/// How many requests wait in one computer's outbox, and for how long.
pub const OUTBOX_LIMIT: usize = 20;
pub const OUTBOX_MAX_AGE: f64 = 24.0 * 3600.0;

/// How long one request may wait, as the iPhone's `CompanionOutbox.maxAge(for:)`: a message to a session a day; a new
/// session, a question to Nook or a chat message an hour, since started or sent much later it would surprise more than
/// help.
pub fn outbox_max_age(op: CompanionOp) -> f64 {
    match op {
        CompanionOp::Send => OUTBOX_MAX_AGE,
        _ => 3600.0,
    }
}
/// How often the phone says it is still there on a kept connection (`CompanionTiming.pingEvery`).
pub const PING_EVERY: Duration = Duration::from_secs(5);
/// A kept connection that brings nothing for this long is gone (the Mac closes one after 45 seconds of silence).
pub const STREAM_IDLE: Duration = Duration::from_secs(45);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClientError {
    Refused,
    Storage,
    BadResponse,
    Timeout,
    Closed,
    Unreachable(String),
}

impl ClientError {
    /// The computer could not be reached at all (as opposed to an answer that said no).
    pub fn is_unreachable(&self) -> bool {
        matches!(self, ClientError::Timeout | ClientError::Closed | ClientError::Unreachable(_))
    }
}

impl std::fmt::Display for ClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let text = match self {
            ClientError::Refused => "De computer weigerde de code.".to_string(),
            ClientError::Storage => "De sleutel kon niet worden bewaard.".to_string(),
            ClientError::BadResponse => "Onbegrijpelijk antwoord van de computer.".to_string(),
            ClientError::Timeout => "De computer antwoordt niet. Staat de companion aan en zit je op hetzelfde wifi?".to_string(),
            ClientError::Closed => "De verbinding werd verbroken.".to_string(),
            ClientError::Unreachable(why) => format!("De computer is niet bereikbaar ({why})."),
        };
        f.write_str(&text)
    }
}

/// Finds the addresses of a host name. DNS by default; the app looks up `….local` over mDNS.
#[async_trait]
pub trait HostResolver: Send + Sync {
    async fn resolve(&self, host: &str, port: u16) -> Vec<SocketAddr>;
}

pub struct DnsResolver;

#[async_trait]
impl HostResolver for DnsResolver {
    async fn resolve(&self, host: &str, port: u16) -> Vec<SocketAddr> {
        tokio::net::lookup_host((host, port)).await.map(|a| a.collect()).unwrap_or_default()
    }
}

/// A request, sealed and framed; signed with `signer` (the private device key) for a computer that holds its public half.
fn sealed_frame(link: &PairingLink, req: &CompanionRequest, signer: Option<&[u8]>) -> Result<Vec<u8>, ClientError> {
    let device_id = PairedDevice::identifier(&link.key);
    let plain = serde_json::to_vec(req).map_err(|_| ClientError::BadResponse)?;
    let mut sealed = seal::seal(&plain, &link.key, &device_id, Direction::Request);
    if let Some(private) = signer {
        // Unsigned it would only be refused: better to say the key is gone.
        sealed = device_key::sign(&sealed, private).ok_or(ClientError::Storage)?;
    }
    FrameReader::frame(&sealed).ok_or(ClientError::BadResponse)
}

fn open_frame(link: &PairingLink, frame: &[u8]) -> Result<CompanionResponse, ClientError> {
    let opened = seal::open(frame, &link.key, Direction::Response).map_err(|_| ClientError::BadResponse)?;
    let json = transport::unpack(&opened)?;
    serde_json::from_slice(&json).map_err(|_| ClientError::BadResponse)
}

/// One request over one open connection: the frame out, the first whole frame back.
async fn exchange_on(
    conn: &mut Conn,
    link: &PairingLink,
    req: &CompanionRequest,
    signer: Option<&[u8]>,
) -> Result<CompanionResponse, ClientError> {
    let attempt = async {
        conn.send(&sealed_frame(link, req, signer)?).await?;
        let mut reader = FrameReader::default();
        loop {
            let bytes = conn.recv().await?;
            for frame in reader.feed(&bytes) {
                let response = open_frame(link, &frame)?;
                if response.id == req.id {
                    return Ok(response);
                }
            }
            if reader.overflowed() {
                return Err(ClientError::BadResponse);
            }
        }
    };
    tokio::time::timeout(EXCHANGE_TIMEOUT, attempt).await.map_err(|_| ClientError::Timeout)?
}

/// Sends a request with this pairing over the first route that answers; the route that did comes back with the answer.
/// `signer` is the private device key once the computer holds its public half (`device_key`).
pub async fn request(
    link: &PairingLink,
    routes: &[Route],
    req: &CompanionRequest,
    signer: Option<&[u8]>,
    resolver: &dyn HostResolver,
) -> Result<(CompanionResponse, Route), ClientError> {
    let mut last = ClientError::Unreachable(format!("{} niet gevonden", link.host));
    for route in routes {
        let mut conn = match transport::connect(route, resolver).await {
            Ok(c) => c,
            Err(e) => {
                last = e;
                continue;
            }
        };
        match exchange_on(&mut conn, link, req, signer).await {
            Ok(r) => return Ok((r, route.clone())),
            Err(e) if e.is_unreachable() => last = e,
            Err(e) => return Err(e),
        }
    }
    if let ClientError::Unreachable(_) = last {
        if link.host.to_ascii_lowercase().ends_with(".local") {
            last = ClientError::Unreachable(format!(
                "{} niet gevonden; lukt het niet, vervang dan in de link h=… door het IP-adres van je computer",
                link.host
            ));
        }
    }
    Err(last)
}

/// A request that waits for the computer (`CompanionOutbox`): sent again with the same id once it is back, so the
/// computer answers a repeat with its first answer and nothing goes twice.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Queued {
    pub request: CompanionRequest,
    pub queued_at: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoredPairing {
    host: String,
    port: u16,
    key: String,
    mac_name: String,
    #[serde(default)]
    alternates: Vec<String>,
    #[serde(default)]
    relay: Option<String>,
    #[serde(default)]
    endpoints: Vec<CompanionEndpoint>,
    #[serde(default)]
    last_route: Option<Route>,
    #[serde(default)]
    outbox: Vec<Queued>,
    #[serde(default)]
    features: Vec<String>,
    #[serde(default)]
    push_token: Option<String>,
    #[serde(default)]
    device_key: Option<String>,
    #[serde(default)]
    key_bound: bool,
    #[serde(default)]
    key_refused: bool,
}

/// A push key for the phone's notification service (`RelayPush.pushKey`): derived from a pairing key, so the service
/// that opens notifications never holds the pairing key itself, and a push can never pass as a reply.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PushKey {
    /// The pairing's device id: what a sealed push names as `d`.
    pub mac: String,
    pub name: String,
    /// Base64.
    pub key: String,
}

pub fn push_key(pairing_key: &[u8]) -> Vec<u8> {
    use hmac::{Hmac, KeyInit, Mac};
    let mut mac = <Hmac<sha2::Sha256> as KeyInit>::new_from_slice(pairing_key).expect("any key length");
    mac.update(b"nook-companion-push-v1");
    mac.finalize().into_bytes().to_vec()
}

/// One computer this phone is paired with.
#[derive(Debug, Clone)]
struct Pairing {
    link: PairingLink,
    endpoints: Vec<CompanionEndpoint>,
    last_route: Option<Route>,
    outbox: Vec<Queued>,
    /// What it listed last, so a computer away still says whether it keeps an outbox.
    features: Vec<String>,
    /// The push token this computer has from the phone (FCM), so it is registered again only when it changes.
    push_token: Option<String>,
    /// This phone's private device key for this computer (`device_key`, base64), made when the computer lists
    /// `feature::DEVICE_KEY`; it lives in the secret store with the rest of the pairing and goes with it.
    device_key: Option<String>,
    /// The computer holds the key's public half: every request to it is signed.
    key_bound: bool,
    /// The computer holds another key for this pairing ("other"): only pairing again helps, so it is not asked again.
    key_refused: bool,
}

impl Pairing {
    fn id(&self) -> String {
        PairedDevice::identifier(&self.link.key)
    }

    /// The private device key to sign with, once the computer holds its public half.
    fn signer(&self) -> Option<Vec<u8>> {
        use base64::Engine;
        if !self.key_bound {
            return None;
        }
        // A bound key that cannot be read signs nothing; `sealed_frame` then refuses rather than send unsigned.
        Some(self.device_key.as_deref().and_then(|k| base64::engine::general_purpose::STANDARD.decode(k).ok()).unwrap_or_default())
    }

    /// Every way to the computer, the last one that worked first and the relay last (`CompanionRoutes.rank`).
    fn routes(&self) -> Vec<Route> {
        let mut out: Vec<Route> = Vec::new();
        let mut push = |r: Route| {
            if !out.contains(&r) {
                out.push(r);
            }
        };
        if let Some(r) = &self.last_route {
            push(r.clone());
        }
        push(Route::Direct { host: self.link.host.clone(), port: self.link.port });
        for a in &self.link.alternates {
            push(Route::Direct { host: a.clone(), port: self.link.port });
        }
        for e in &self.endpoints {
            push(Route::Direct { host: e.host.clone(), port: e.port });
        }
        if let Some(relay) = &self.link.relay {
            push(Route::Relay { relay: relay.clone(), room: transport::relay_room(&self.link.key) });
        }
        out
    }

    fn stored(&self) -> StoredPairing {
        StoredPairing {
            host: self.link.host.clone(),
            port: self.link.port,
            key: base64url_encode(&self.link.key),
            mac_name: self.link.mac_name.clone(),
            alternates: self.link.alternates.clone(),
            relay: self.link.relay.clone(),
            endpoints: self.endpoints.clone(),
            last_route: self.last_route.clone(),
            outbox: self.outbox.clone(),
            features: self.features.clone(),
            push_token: self.push_token.clone(),
            device_key: self.device_key.clone(),
            key_bound: self.key_bound,
            key_refused: self.key_refused,
        }
    }

    fn from_stored(s: StoredPairing) -> Option<Pairing> {
        let key = base64url_decode(&s.key).filter(|k| k.len() == KEY_LENGTH)?;
        Some(Pairing {
            link: PairingLink { host: s.host, port: s.port, key, mac_name: s.mac_name, alternates: s.alternates, relay: s.relay },
            endpoints: s.endpoints,
            last_route: s.last_route,
            outbox: s.outbox,
            features: s.features,
            push_token: s.push_token,
            device_key: s.device_key,
            key_bound: s.key_bound,
            key_refused: s.key_refused,
        })
    }

    /// Takes in where the computer says it can be reached.
    fn learn(&mut self, response: &CompanionResponse) {
        if let Some(endpoints) = &response.endpoints {
            self.endpoints = endpoints.iter().filter(|e| valid_host(&e.host) && e.port > 0).take(8).cloned().collect();
        }
        if let Some(relay) = response.relay.as_deref().and_then(transport::normalize_relay) {
            self.link.relay = Some(relay);
        }
        if let Some(features) = &response.features {
            self.features = features.clone();
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    Unpaired,
    Pairing,
    Connected,
    Offline,
}

/// A paired computer in the menu.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MacSummary {
    pub id: String,
    pub name: String,
    pub active: bool,
}

/// What another paired computer had when it was last asked (its sessions, under "On <Mac>" in the Agents list).
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OtherMac {
    pub id: String,
    pub name: String,
    pub reachable: bool,
    pub sessions: Vec<SessionDigest>,
}

/// A request in the outbox, as the interface shows it ("Waiting for your Mac").
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QueuedView {
    pub id: String,
    pub op: CompanionOp,
    pub session: Option<String>,
    pub conversation: Option<String>,
    /// The chat a message to a chat of the Chats tab goes to (`inboxSend`).
    pub item: Option<String>,
    pub text: String,
    pub queued_at: f64,
}

/// What the interface shows.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientSnapshot {
    pub phase: Phase,
    /// Why the computer cannot be reached (with `offline`); empty while it is still looked for.
    pub reason: String,
    pub mac_name: String,
    pub host: String,
    pub sessions: Vec<SessionDigest>,
    pub notice: Option<String>,
    /// What the computer can do beyond approving, answering, sending and stopping (`feature`); empty for a computer
    /// that lists none (an older Mac, or Nook on Windows and Linux).
    pub features: Vec<String>,
    /// What this phone may do there (`CompanionScope` names); `None` from a computer without scopes: everything.
    pub scopes: Option<Vec<String>>,
    /// The computer's protocol version and the oldest phone it still supports (`CompanionCompatibility`); none from a
    /// computer that predates versions.
    pub mac_version: Option<i64>,
    pub oldest_phone: Option<i64>,
    /// How the phone reached the active computer last: "lan", "tailnet", "internet" or "relay"; empty before it did.
    pub route: String,
    pub macs: Vec<MacSummary>,
    pub others: Vec<OtherMac>,
    pub outbox: Vec<QueuedView>,
}

/// One request from the interface, as `CompanionRequest` without its id and clock: `CompanionClient::call` adds them.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientCall {
    pub op: Option<CompanionOp>,
    pub session: Option<String>,
    pub item: Option<String>,
    pub text: Option<String>,
    pub allow: Option<bool>,
    pub conversation: Option<String>,
    pub launch: Option<LaunchRequest>,
    pub reply_to: Option<String>,
    pub steer: Option<bool>,
    pub turn: Option<String>,
    pub images: Option<Vec<CompanionImage>>,
    pub pull_action: Option<serde_json::Value>,
    pub pull_work: Option<serde_json::Value>,
    pub items: Option<Vec<String>>,
}

struct Inner {
    pairings: Vec<Pairing>,
    active: usize,
    phase: Phase,
    reason: String,
    mac_name: String,
    sessions: Vec<SessionDigest>,
    notice: Option<String>,
    features: Vec<String>,
    scopes: Option<Vec<String>>,
    mac_version: Option<i64>,
    oldest_phone: Option<i64>,
    route: String,
    others: Vec<OtherMac>,
}

impl Inner {
    fn current(&self) -> Option<&Pairing> {
        self.pairings.get(self.active)
    }

    fn current_mut(&mut self) -> Option<&mut Pairing> {
        self.pairings.get_mut(self.active)
    }

    /// Forgets what came from the computer that was active, before another becomes active.
    fn clear_computer(&mut self) {
        self.sessions.clear();
        self.features.clear();
        self.scopes = None;
        self.mac_version = None;
        self.oldest_phone = None;
        self.route.clear();
        self.reason.clear();
        self.mac_name = self.current().map(|p| p.link.mac_name.clone()).unwrap_or_default();
        self.phase = if self.pairings.is_empty() { Phase::Unpaired } else { Phase::Offline };
    }
}

pub struct CompanionClient {
    secrets: Arc<dyn SecretStore>,
    resolver: Arc<dyn HostResolver>,
    inner: Mutex<Inner>,
    app_version: String,
    /// A `bindKey` request is on its way (`bind_device_key`): no second one meanwhile.
    binding: AtomicBool,
}

impl CompanionClient {
    pub fn new(secrets: Arc<dyn SecretStore>, resolver: Arc<dyn HostResolver>) -> Self {
        let mut pairings: Vec<Pairing> = secrets
            .read(PAIRINGS_ACCOUNT)
            .and_then(|text| serde_json::from_str::<Vec<StoredPairing>>(&text).ok())
            .unwrap_or_default()
            .into_iter()
            .filter_map(Pairing::from_stored)
            .collect();
        // A phone paired before it could pair with several computers: its one pairing becomes the list.
        if pairings.is_empty() {
            if let Some(p) =
                secrets.read(PAIRING_ACCOUNT).and_then(|t| serde_json::from_str::<StoredPairing>(&t).ok()).and_then(Pairing::from_stored)
            {
                pairings.push(p);
            }
        }
        let mut inner = Inner {
            pairings,
            active: 0,
            phase: Phase::Unpaired,
            reason: String::new(),
            mac_name: String::new(),
            sessions: Vec::new(),
            notice: None,
            features: Vec::new(),
            scopes: None,
            mac_version: None,
            oldest_phone: None,
            route: String::new(),
            others: Vec::new(),
        };
        inner.clear_computer();
        let client = Self {
            secrets,
            resolver,
            inner: Mutex::new(inner),
            app_version: env!("CARGO_PKG_VERSION").into(),
            binding: AtomicBool::new(false),
        };
        let _ = client.save();
        let _ = client.secrets.remove(PAIRING_ACCOUNT);
        client
    }

    /// The app version this phone says it runs (`appVersion` on `hello` and `list`).
    pub fn with_app_version(mut self, version: &str) -> Self {
        self.app_version = version.into();
        self
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn save(&self) -> Result<(), ClientError> {
        let stored: Vec<StoredPairing> = self.lock().pairings.iter().map(Pairing::stored).collect();
        let json = serde_json::to_string(&stored).map_err(|_| ClientError::Storage)?;
        self.secrets.write(PAIRINGS_ACCOUNT, &json).map_err(|_| ClientError::Storage)
    }

    pub fn snapshot(&self) -> ClientSnapshot {
        let i = self.lock();
        let current = i.current();
        ClientSnapshot {
            phase: i.phase,
            reason: i.reason.clone(),
            mac_name: i.mac_name.clone(),
            host: current.map(|p| p.link.host.clone()).unwrap_or_default(),
            sessions: i.sessions.clone(),
            notice: i.notice.clone(),
            features: i.features.clone(),
            scopes: i.scopes.clone(),
            mac_version: i.mac_version,
            oldest_phone: i.oldest_phone,
            route: i.route.clone(),
            macs: i
                .pairings
                .iter()
                .enumerate()
                .map(|(n, p)| MacSummary { id: p.id(), name: p.link.mac_name.clone(), active: n == i.active })
                .collect(),
            others: i.others.clone(),
            outbox: current
                .map(|p| {
                    p.outbox
                        .iter()
                        .map(|q| QueuedView {
                            id: q.request.id.clone(),
                            op: q.request.op,
                            session: q.request.session.clone(),
                            conversation: q.request.conversation.clone(),
                            item: q.request.item.clone(),
                            text: q.request.text.clone().or_else(|| q.request.launch.as_ref().map(|l| l.task.clone())).unwrap_or_default(),
                            queued_at: q.queued_at,
                        })
                        .collect()
                })
                .unwrap_or_default(),
        }
    }

    /// Whether the active computer lists this feature.
    pub fn has(&self, feature: &str) -> bool {
        self.lock().features.iter().any(|f| f == feature)
    }

    pub fn is_paired(&self) -> bool {
        !self.lock().pairings.is_empty()
    }

    pub fn clear_notice(&self) {
        self.lock().notice = None;
    }

    /// Pairs with the code a computer shows; the first request, `hello`, proves the phone has the key and the computer
    /// keeps the device. A code of a computer this phone already knows replaces that pairing; another becomes the
    /// active one, beside the others (at most `MAX_MACS`).
    pub async fn pair(&self, text: &str, device_name: &str) -> ClientSnapshot {
        let Some(parsed) = PairingLink::parse(text) else {
            self.lock().notice = Some("Dat is geen geldige koppelcode.".into());
            return self.snapshot();
        };
        let id = PairedDevice::identifier(&parsed.key);
        let full = {
            let mut i = self.lock();
            let full = i.pairings.len() >= MAX_MACS && !i.pairings.iter().any(|p| p.id() == id);
            if full {
                i.notice = Some("Deze telefoon is al met acht computers gekoppeld. Ontkoppel er eerst een.".into());
            } else {
                i.phase = Phase::Pairing;
                i.notice = None;
            }
            full
        };
        if full {
            return self.snapshot();
        }
        let candidate = Pairing {
            link: parsed.clone(),
            endpoints: vec![],
            last_route: None,
            outbox: vec![],
            features: vec![],
            push_token: None,
            device_key: None,
            key_bound: false,
            key_refused: false,
        };
        let mut hello = CompanionRequest::versioned(CompanionOp::Hello, &self.app_version);
        hello.text = Some(device_name.into());
        hello.compression = Some(true);
        let result = request(&parsed, &candidate.routes(), &hello, None, &*self.resolver).await;
        {
            let mut i = self.lock();
            match result {
                Ok((response, route)) if response.ok => {
                    let mut pairing = candidate;
                    pairing.learn(&response);
                    pairing.last_route = Some(route.clone());
                    if let Some(n) = i.pairings.iter().position(|p| p.id() == id) {
                        i.pairings[n] = pairing;
                        i.active = n;
                    } else {
                        i.pairings.push(pairing);
                        i.active = i.pairings.len() - 1;
                    }
                    i.clear_computer();
                    i.mac_name = response.mac_name.clone().unwrap_or_else(|| parsed.mac_name.clone());
                    i.route = route.kind().into();
                    take_list(&mut i, &response);
                    i.phase = Phase::Connected;
                }
                Ok(_) | Err(_) => {
                    let e = match result {
                        Err(e) => e,
                        _ => ClientError::Refused,
                    };
                    i.phase = if i.pairings.is_empty() { Phase::Unpaired } else { Phase::Offline };
                    i.notice =
                        Some(format!("Koppelen mislukt: {e} De code werkt vijf minuten en één keer; maak op je computer een nieuwe."));
                }
            }
        }
        let _ = self.save();
        self.bind_device_key().await;
        self.snapshot()
    }

    /// Unpairs from the active computer; another paired one becomes active.
    pub fn unpair(&self) -> ClientSnapshot {
        {
            let mut i = self.lock();
            if !i.pairings.is_empty() {
                let n = i.active;
                i.pairings.remove(n);
            }
            i.active = 0;
            // The computer that becomes active is no longer one of the others.
            let next = i.current().map(Pairing::id);
            i.others.retain(|o| Some(&o.id) != next.as_ref());
            i.clear_computer();
        }
        let _ = self.save();
        self.snapshot()
    }

    /// Makes another paired computer the active one.
    pub fn switch_to(&self, id: &str) -> ClientSnapshot {
        {
            let mut i = self.lock();
            if let Some(n) = i.pairings.iter().position(|p| p.id() == id) {
                if n != i.active {
                    i.active = n;
                    i.others.retain(|o| o.id != id);
                    i.clear_computer();
                }
            }
        }
        self.snapshot()
    }

    /// Takes a request out of the outbox ("Don't send").
    pub fn discard(&self, id: &str) -> ClientSnapshot {
        if let Some(p) = self.lock().current_mut() {
            p.outbox.retain(|q| q.request.id != id);
        }
        let _ = self.save();
        self.snapshot()
    }

    /// The push keys of every paired computer, for the phone's notification service.
    pub fn push_keys(&self) -> Vec<PushKey> {
        use base64::Engine;
        self.lock()
            .pairings
            .iter()
            .map(|p| PushKey {
                mac: p.id(),
                name: p.link.mac_name.clone(),
                key: base64::engine::general_purpose::STANDARD.encode(push_key(&p.link.key)),
            })
            .collect()
    }

    /// Gives every paired computer this phone's FCM token (`register` with `item` "fcm"), each once per token; a
    /// computer away gets it the next time. Returns how many have it now.
    pub async fn register_push(&self, token: &str) -> usize {
        let token = token.trim();
        if token.len() < 100 || token.len() > 4096 || !token.chars().all(|c| c.is_ascii_alphanumeric() || ":_-".contains(c)) {
            return 0;
        }
        let pairings: Vec<Pairing> = self.lock().pairings.clone();
        let mut done = 0;
        for p in pairings {
            if p.push_token.as_deref() == Some(token) {
                done += 1;
                continue;
            }
            let mut r = CompanionRequest::new(CompanionOp::Register);
            r.item = Some("fcm".into());
            r.text = Some(token.into());
            if let Ok((response, _)) = request(&p.link, &p.routes(), &r, p.signer().as_deref(), &*self.resolver).await {
                if response.ok {
                    done += 1;
                    if let Some(stored) = self.lock().pairings.iter_mut().find(|x| x.id() == p.id()) {
                        stored.push_token = Some(token.into());
                    }
                }
            }
        }
        let _ = self.save();
        done
    }

    pub async fn refresh(&self) -> ClientSnapshot {
        self.perform(CompanionRequest::versioned(CompanionOp::List, &self.app_version)).await
    }

    /// Asks every other paired computer for its sessions (one short `list` each), for "On <Mac>" in the Agents list.
    pub async fn refresh_others(&self) -> ClientSnapshot {
        let others: Vec<Pairing> = {
            let i = self.lock();
            i.pairings.iter().enumerate().filter(|(n, _)| *n != i.active).map(|(_, p)| p.clone()).collect()
        };
        let mut found = Vec::new();
        for p in others {
            let mut list = CompanionRequest::versioned(CompanionOp::List, &self.app_version);
            list.compression = Some(true);
            let result = request(&p.link, &p.routes(), &list, p.signer().as_deref(), &*self.resolver).await;
            let (reachable, sessions) = match &result {
                Ok((r, _)) if r.ok => (true, r.sessions.clone().unwrap_or_default()),
                _ => (false, Vec::new()),
            };
            if let Ok((r, route)) = &result {
                let mut i = self.lock();
                if let Some(stored) = i.pairings.iter_mut().find(|x| x.id() == p.id()) {
                    stored.learn(r);
                    stored.last_route = Some(route.clone());
                }
            }
            found.push(OtherMac { id: p.id(), name: p.link.mac_name.clone(), reachable, sessions });
        }
        self.lock().others = found;
        let _ = self.save();
        self.snapshot()
    }

    /// Allows or denies a request. `reason` goes with a denial: the computer tells the agent why (an older one ignores it).
    pub async fn decide(&self, session: &str, item: &str, allow: bool) -> ClientSnapshot {
        self.decide_with_reason(session, item, allow, None).await
    }

    pub async fn decide_with_reason(&self, session: &str, item: &str, allow: bool, reason: Option<&str>) -> ClientSnapshot {
        let mut r = CompanionRequest::new(CompanionOp::Decide);
        r.session = Some(session.into());
        r.item = Some(item.into());
        r.allow = Some(allow);
        r.text = reason.map(str::trim).filter(|t| !allow && !t.is_empty()).map(Into::into);
        self.perform(r).await
    }

    /// Any other request the interface makes. The answer comes back as it came, beside the new state; `None` when the
    /// computer refused it or could not be reached (the state's notice or reason says why). A message, a new session or
    /// a question to Nook for a computer that keeps an outbox waits for it instead (the answer then says `outbox`).
    pub async fn call(&self, call: ClientCall) -> (ClientSnapshot, Option<CompanionResponse>) {
        let Some(op) = call.op.filter(|op| op.callable()) else {
            self.lock().notice = Some("De computer weigerde dit.".into());
            return (self.snapshot(), None);
        };
        let mut r = if op == CompanionOp::List { CompanionRequest::versioned(op, &self.app_version) } else { CompanionRequest::new(op) };
        r.session = call.session;
        r.item = call.item;
        r.text = call.text;
        r.allow = call.allow;
        r.conversation = call.conversation;
        r.launch = call.launch;
        r.reply_to = call.reply_to;
        r.steer = call.steer;
        r.turn = call.turn;
        // Pictures go only as the Mac takes them: JPEGs within the limit, at most two.
        if let Some(images) = call.images {
            if images.len() > CompanionImage::MAX_COUNT || !images.iter().all(CompanionImage::is_valid) {
                self.lock().notice = Some("Die foto is te groot of geen JPEG.".into());
                return (self.snapshot(), None);
            }
            r.images = Some(images).filter(|i| !i.is_empty());
        }
        r.pull_action = call.pull_action;
        r.pull_work = call.pull_work;
        r.items = call.items;
        // What you write waits, as on the iPhone (`CompanionOutbox`): a message to a session or to a chat, a new session,
        // a question to Nook. Approvals, answers and stops mean something only now and never wait.
        let queueable = matches!(op, CompanionOp::Send | CompanionOp::Start | CompanionOp::Ask | CompanionOp::InboxSend);
        let (snapshot, answer, error) = self.exchange_full(r.clone()).await;
        if queueable && error.as_ref().is_some_and(ClientError::is_unreachable) && self.keeps_outbox() {
            return self.enqueue(r);
        }
        (snapshot, answer)
    }

    fn keeps_outbox(&self) -> bool {
        self.lock().current().is_some_and(|p| p.features.iter().any(|f| f == feature::RETRY))
    }

    fn enqueue(&self, request: CompanionRequest) -> (ClientSnapshot, Option<CompanionResponse>) {
        let id = request.id.clone();
        {
            let mut i = self.lock();
            let now = chrono::Utc::now().timestamp_millis() as f64 / 1000.0;
            let Some(p) = i.current_mut() else { return (self.snapshot(), None) };
            p.outbox.retain(|q| now - q.queued_at < outbox_max_age(q.request.op));
            if p.outbox.len() >= OUTBOX_LIMIT {
                i.notice = Some("Er wachten al te veel berichten op je computer.".into());
                drop(i);
                return (self.snapshot(), None);
            }
            p.outbox.push(Queued { request, queued_at: now });
        }
        let _ = self.save();
        (self.snapshot(), Some(CompanionResponse { message: Some("outbox".into()), ..CompanionResponse::success(&id) }))
    }

    /// Sends what waits in the active computer's outbox, oldest first, each with its own id again (the computer answers
    /// a repeat with its first answer). Stops at the first that cannot get through; a refusal is taken out and said.
    async fn drain(&self) {
        loop {
            let (link, routes, next, signer) = {
                let mut i = self.lock();
                let now = chrono::Utc::now().timestamp_millis() as f64 / 1000.0;
                let Some(p) = i.current_mut() else { return };
                // What waited too long goes unsent, and the phone says so.
                let before = p.outbox.len();
                p.outbox.retain(|q| now - q.queued_at < outbox_max_age(q.request.op));
                let expired = p.outbox.len() < before;
                let Some(q) = p.outbox.first() else {
                    if expired {
                        i.notice = Some("Wat te lang op je computer wachtte, is niet verstuurd.".into());
                        drop(i);
                        let _ = self.save();
                    }
                    return;
                };
                let next = (p.link.clone(), p.routes(), q.request.clone(), p.signer());
                if expired {
                    i.notice = Some("Wat te lang op je computer wachtte, is niet verstuurd.".into());
                }
                next
            };
            let mut again = next.clone();
            again.sent = chrono::Utc::now().timestamp_millis() as f64 / 1000.0;
            again.compression = Some(true);
            match request(&link, &routes, &again, signer.as_deref(), &*self.resolver).await {
                Ok((response, _)) => {
                    let mut i = self.lock();
                    if let Some(p) = i.current_mut() {
                        p.outbox.retain(|q| q.request.id != next.id);
                    }
                    if let Some(list) = &response.sessions {
                        i.sessions = list.clone();
                    }
                    if !response.ok {
                        i.notice = Some("Niet verstuurd: je computer weigerde een bericht dat wachtte.".into());
                    }
                }
                Err(_) => return,
            }
            let _ = self.save();
        }
    }

    pub async fn answer(&self, session: &str, item: &str, text: &str) -> ClientSnapshot {
        let mut r = CompanionRequest::new(CompanionOp::Answer);
        r.session = Some(session.into());
        r.item = Some(item.into());
        r.text = Some(text.into());
        self.perform(r).await
    }

    pub async fn send(&self, session: &str, text: &str) -> ClientSnapshot {
        let mut r = CompanionRequest::new(CompanionOp::Send);
        r.session = Some(session.into());
        r.text = Some(text.into());
        self.perform(r).await
    }

    pub async fn stop(&self, session: &str) -> ClientSnapshot {
        let mut r = CompanionRequest::new(CompanionOp::Stop);
        r.session = Some(session.into());
        self.perform(r).await
    }

    /// Keeps one connection open to the active computer, as the iPhone app does while it is in front (`subscribe`): the
    /// computer sends the sessions, the open session's conversation, the chats and Nook's conversations as they change,
    /// and the phone pings every few seconds with `foreground()`. `on_update` gets every update with the new state.
    /// Returns when the connection ends; the caller decides when to connect again. Only for a computer that lists
    /// `feature::STREAM`.
    pub async fn stream(
        &self,
        foreground: impl Fn() -> bool,
        mut on_update: impl FnMut(ClientSnapshot, CompanionResponse),
    ) -> Result<(), ClientError> {
        let (link, routes, id_of, signer) = {
            let i = self.lock();
            let Some(p) = i.current() else { return Err(ClientError::Closed) };
            (p.link.clone(), p.routes(), p.id(), p.signer())
        };
        let mut conn = None;
        let mut last = ClientError::Unreachable(format!("{} niet gevonden", link.host));
        for route in &routes {
            match transport::connect(route, &*self.resolver).await {
                Ok(c) => {
                    conn = Some((c, route.clone()));
                    break;
                }
                Err(e) => last = e,
            }
        }
        let (mut conn, route) = conn.ok_or(last)?;
        let mut subscribe = CompanionRequest::versioned(CompanionOp::Subscribe, &self.app_version);
        subscribe.foreground = Some(foreground());
        subscribe.compression = Some(true);
        let id = subscribe.id.clone();
        conn.send(&sealed_frame(&link, &subscribe, signer.as_deref())?).await?;

        let mut frames = FrameReader::default();
        let mut ping = tokio::time::interval(PING_EVERY);
        ping.tick().await;
        let mut last_seq = -1i64;
        let mut first = true;
        loop {
            let bytes = tokio::select! {
                read = tokio::time::timeout(STREAM_IDLE, conn.recv()) => Some(read.map_err(|_| ClientError::Timeout)??),
                _ = ping.tick() => None,
            };
            let Some(bytes) = bytes else {
                let mut p = CompanionRequest::new(CompanionOp::Ping);
                p.foreground = Some(foreground());
                conn.send(&sealed_frame(&link, &p, signer.as_deref())?).await?;
                continue;
            };
            for frame in frames.feed(&bytes) {
                let Ok(response) = open_frame(&link, &frame) else { return Err(ClientError::BadResponse) };
                // Answers to pings say nothing new; updates come with the subscription's id, in order.
                if response.id != id {
                    continue;
                }
                if let Some(seq) = response.seq {
                    if seq <= last_seq {
                        continue;
                    }
                    last_seq = seq;
                }
                if response.revoked == Some(true) {
                    // The computer removed this phone: forget that pairing, say so, and pair again from its code.
                    self.unpair();
                    self.lock().notice = Some("Je computer heeft deze telefoon ontkoppeld. Koppel opnieuw.".into());
                    on_update(self.snapshot(), response);
                    return Err(ClientError::Refused);
                }
                if !response.ok {
                    return Err(ClientError::Refused);
                }
                {
                    let mut i = self.lock();
                    if i.current().map(Pairing::id).as_deref() != Some(id_of.as_str()) {
                        // Another computer became active meanwhile: this connection ends.
                        return Ok(());
                    }
                    if let Some(p) = i.current_mut() {
                        p.learn(&response);
                        p.last_route = Some(route.clone());
                    }
                    if let Some(list) = &response.sessions {
                        i.sessions = list.clone();
                    }
                    if let Some(name) = &response.mac_name {
                        i.mac_name = name.clone();
                    }
                    if response.features.is_some() {
                        take_list(&mut i, &response);
                    }
                    i.phase = Phase::Connected;
                    i.reason.clear();
                    i.route = route.kind().into();
                }
                on_update(self.snapshot(), response);
                if first {
                    first = false;
                    let _ = self.save();
                    self.drain().await;
                    // Bound now, this connection still signs nothing: the next one does.
                    self.bind_device_key().await;
                }
            }
            if frames.overflowed() {
                return Err(ClientError::BadResponse);
            }
        }
    }

    async fn perform(&self, req: CompanionRequest) -> ClientSnapshot {
        self.exchange_full(req).await.0
    }

    async fn exchange_full(&self, mut req: CompanionRequest) -> (ClientSnapshot, Option<CompanionResponse>, Option<ClientError>) {
        let Some((link, routes, signer)) = self.lock().current().map(|p| (p.link.clone(), p.routes(), p.signer())) else {
            return (self.snapshot(), None, None);
        };
        req.compression = Some(true);
        let op = req.op;
        let result = request(&link, &routes, &req, signer.as_deref(), &*self.resolver).await;
        let mut refresh = false;
        let mut answer = None;
        let mut error = None;
        let mut reached = false;
        {
            let mut i = self.lock();
            match result {
                Ok((response, route)) => {
                    reached = true;
                    if let Some(p) = i.current_mut() {
                        p.learn(&response);
                        p.last_route = Some(route.clone());
                    }
                    i.route = route.kind().into();
                    i.phase = Phase::Connected;
                    i.reason.clear();
                    if response.ok {
                        if let Some(list) = &response.sessions {
                            i.sessions = list.clone();
                        }
                        if let Some(name) = &response.mac_name {
                            i.mac_name = name.clone();
                        }
                        if matches!(op, CompanionOp::Hello | CompanionOp::List) {
                            // A Mac lists its features with every `list`; one that lists none can do only the first version.
                            take_list(&mut i, &response);
                        }
                        if op == CompanionOp::Send {
                            if let Some(message) = &response.message {
                                i.notice = (message == "queued").then(|| "In de wachtrij: de sessie is nog bezig.".into());
                            }
                        }
                        answer = Some(response);
                    } else {
                        // A refusal that says why in words (a chat app that could not send) shows those words.
                        let said =
                            response.message.clone().filter(|m| response.error == Some(CompanionError::Failed) && !m.trim().is_empty());
                        i.notice = Some(said.unwrap_or_else(|| {
                            match response.error {
                                Some(CompanionError::NotAllowedFromPhone) if response.message.as_deref() == Some("signature") => {
                                    KEY_REFUSED
                                }
                                Some(CompanionError::NotAllowedFromPhone) => "Dat kan niet vanaf de telefoon: open het op je computer.",
                                Some(CompanionError::UnknownItem | CompanionError::UnknownSession) => {
                                    refresh = true;
                                    "Dat is al afgehandeld."
                                }
                                Some(CompanionError::Stale) => "De klok van je telefoon en je computer loopt te ver uit elkaar.",
                                Some(CompanionError::RateLimited) => "Even rustig aan.",
                                _ => "De computer weigerde dit.",
                            }
                            .into()
                        }));
                    }
                }
                Err(e) => {
                    i.phase = Phase::Offline;
                    i.reason = e.to_string();
                    error = Some(e);
                }
            }
        }
        if reached {
            let _ = self.save();
            if !matches!(op, CompanionOp::Send | CompanionOp::Start | CompanionOp::Ask) {
                self.drain().await;
            }
            self.bind_device_key().await;
        }
        if refresh {
            let notice = self.lock().notice.clone();
            Box::pin(self.refresh()).await;
            self.lock().notice = notice;
        }
        (self.snapshot(), answer, error)
    }
}

const KEY_REFUSED: &str = "Je computer kent een andere sleutel voor deze telefoon. Koppel opnieuw met de code op je computer.";

impl CompanionClient {
    /// Tells the active computer this phone's device key (`CompanionOp::BindKey`) once it lists `feature::DEVICE_KEY`;
    /// from its "bound" on, every request to it is signed. "other" means it already holds a different key for this
    /// pairing: only pairing again helps.
    async fn bind_device_key(&self) {
        use base64::Engine;
        const B64: base64::engine::GeneralPurpose = base64::engine::general_purpose::STANDARD;
        let (link, routes, id, private) = {
            let mut i = self.lock();
            let Some(p) = i.current_mut() else { return };
            if p.key_bound || p.key_refused || !p.features.iter().any(|f| f == feature::DEVICE_KEY) {
                return;
            }
            if p.device_key.is_none() {
                p.device_key = device_key::generate().map(|k| B64.encode(k));
            }
            let Some(private) = p.device_key.as_deref().and_then(|k| B64.decode(k).ok()) else { return };
            (p.link.clone(), p.routes(), p.id(), private)
        };
        let Some(public) = device_key::public_key(&private) else { return };
        if self.binding.swap(true, Ordering::SeqCst) {
            return;
        }
        // The key is kept before the computer hears it, so the one it binds is never lost.
        let _ = self.save();
        let mut bind = CompanionRequest::new(CompanionOp::BindKey);
        bind.text = Some(B64.encode(public));
        let result = request(&link, &routes, &bind, None, &*self.resolver).await;
        self.binding.store(false, Ordering::SeqCst);
        let Ok((response, _)) = result else { return };
        {
            let mut i = self.lock();
            let active = i.current().map(Pairing::id).as_deref() == Some(id.as_str());
            let Some(p) = i.pairings.iter_mut().find(|p| p.id() == id) else { return };
            match response.message.as_deref() {
                Some("bound") if response.ok => p.key_bound = true,
                Some("other") if response.ok => {
                    p.key_refused = true;
                    if active {
                        i.notice = Some(KEY_REFUSED.into());
                    }
                }
                _ => return,
            }
        }
        let _ = self.save();
    }
}

/// What a `hello`, `list` or `subscribe` answer says about the computer.
fn take_list(i: &mut Inner, response: &CompanionResponse) {
    i.features = response.features.clone().unwrap_or_default();
    i.scopes = response.scopes.clone();
    i.mac_version = response.protocol_version;
    i.oldest_phone = response.oldest_phone;
    if let Some(list) = &response.sessions {
        i.sessions = list.clone();
    }
}
