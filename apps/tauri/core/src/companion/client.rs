//! De telefoonkant (`CompanionClient.swift` van de iPhone-app), voor Android: één korte verbinding per aanvraag
//! (verbinden, verzegelde aanvraag sturen, verzegeld antwoord lezen, sluiten). De koppeling (adres en sleutel) staat in
//! de kluis van de app.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use super::models::*;
use super::seal::{self, Direction};
use crate::secrets::SecretStore;

const EXCHANGE_TIMEOUT: Duration = Duration::from_secs(8);
const PAIRING_ACCOUNT: &str = "companion.pairing";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClientError {
    Refused,
    Storage,
    BadResponse,
    Timeout,
    Closed,
    Unreachable(String),
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

/// Zoekt de adressen bij een hostnaam. Standaard via DNS; de app kan `….local` via mDNS opzoeken.
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

/// Eén verbinding: het frame sturen, lezen tot er één heel frame terug is, met een tijdslimiet.
pub async fn exchange(addresses: &[SocketAddr], payload: &[u8]) -> Result<Vec<u8>, ClientError> {
    let attempt = async {
        let mut last = ClientError::Unreachable("geen adres".into());
        let mut stream = None;
        for addr in addresses {
            match TcpStream::connect(addr).await {
                Ok(s) => {
                    stream = Some(s);
                    break;
                }
                Err(e) => last = ClientError::Unreachable(e.to_string()),
            }
        }
        let mut stream = stream.ok_or(last)?;
        stream.write_all(payload).await.map_err(|_| ClientError::Closed)?;
        let mut reader = FrameReader::default();
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            let n = stream.read(&mut buf).await.map_err(|_| ClientError::Closed)?;
            if n == 0 {
                return Err(ClientError::Closed);
            }
            if let Some(first) = reader.feed(&buf[..n]).into_iter().next() {
                return Ok(first);
            }
            if reader.overflowed() {
                return Err(ClientError::BadResponse);
            }
        }
    };
    tokio::time::timeout(EXCHANGE_TIMEOUT, attempt).await.map_err(|_| ClientError::Timeout)?
}

/// Een aanvraag versturen met deze koppeling en het geopende antwoord teruggeven.
pub async fn request(link: &PairingLink, req: &CompanionRequest, resolver: &dyn HostResolver) -> Result<CompanionResponse, ClientError> {
    let device_id = PairedDevice::identifier(&link.key);
    let plain = serde_json::to_vec(req).map_err(|_| ClientError::BadResponse)?;
    let sealed = seal::seal(&plain, &link.key, &device_id, Direction::Request);
    let framed = FrameReader::frame(&sealed).ok_or(ClientError::BadResponse)?;
    let addresses = resolver.resolve(&link.host, link.port).await;
    if addresses.is_empty() {
        let hint = if link.host.to_ascii_lowercase().ends_with(".local") {
            "; lukt het niet, vervang dan in de link h=… door het IP-adres van je computer"
        } else {
            ""
        };
        return Err(ClientError::Unreachable(format!("{} niet gevonden{hint}", link.host)));
    }
    let reply = exchange(&addresses, &framed).await?;
    let opened = seal::open(&reply, &link.key, Direction::Response).map_err(|_| ClientError::BadResponse)?;
    let response: CompanionResponse = serde_json::from_slice(&opened).map_err(|_| ClientError::BadResponse)?;
    if response.id != req.id {
        return Err(ClientError::BadResponse);
    }
    Ok(response)
}

/// How often the phone says it is still there on a kept connection (`CompanionTiming.pingEvery`).
pub const PING_EVERY: Duration = Duration::from_secs(5);
/// A kept connection that brings nothing for this long is gone (the Mac closes one after 45 seconds of silence).
pub const STREAM_IDLE: Duration = Duration::from_secs(45);

fn sealed_frame(link: &PairingLink, req: &CompanionRequest) -> Result<Vec<u8>, ClientError> {
    let device_id = PairedDevice::identifier(&link.key);
    let plain = serde_json::to_vec(req).map_err(|_| ClientError::BadResponse)?;
    FrameReader::frame(&seal::seal(&plain, &link.key, &device_id, Direction::Request)).ok_or(ClientError::BadResponse)
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoredPairing {
    host: String,
    port: u16,
    key: String,
    mac_name: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    Unpaired,
    Pairing,
    Connected,
    Offline,
}

/// Wat de interface laat zien.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientSnapshot {
    pub phase: Phase,
    /// Waarom de computer niet bereikbaar is (bij `offline`); leeg = nog aan het zoeken.
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
    link: Option<PairingLink>,
    phase: Phase,
    reason: String,
    mac_name: String,
    sessions: Vec<SessionDigest>,
    notice: Option<String>,
    features: Vec<String>,
    scopes: Option<Vec<String>>,
    mac_version: Option<i64>,
    oldest_phone: Option<i64>,
}

pub struct CompanionClient {
    secrets: Arc<dyn SecretStore>,
    resolver: Arc<dyn HostResolver>,
    inner: Mutex<Inner>,
    app_version: String,
}

impl CompanionClient {
    pub fn new(secrets: Arc<dyn SecretStore>, resolver: Arc<dyn HostResolver>) -> Self {
        let link = secrets.read(PAIRING_ACCOUNT).and_then(|text| {
            let stored: StoredPairing = serde_json::from_str(&text).ok()?;
            let key = base64url_decode(&stored.key).filter(|k| k.len() == KEY_LENGTH)?;
            Some(PairingLink { host: stored.host, port: stored.port, key, mac_name: stored.mac_name })
        });
        let inner = Inner {
            phase: if link.is_some() { Phase::Offline } else { Phase::Unpaired },
            mac_name: link.as_ref().map(|l| l.mac_name.clone()).unwrap_or_default(),
            link,
            reason: String::new(),
            sessions: Vec::new(),
            notice: None,
            features: Vec::new(),
            scopes: None,
            mac_version: None,
            oldest_phone: None,
        };
        Self { secrets, resolver, inner: Mutex::new(inner), app_version: env!("CARGO_PKG_VERSION").into() }
    }

    /// The app version this phone says it runs (`appVersion` on `hello` and `list`).
    pub fn with_app_version(mut self, version: &str) -> Self {
        self.app_version = version.into();
        self
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn snapshot(&self) -> ClientSnapshot {
        let i = self.lock();
        ClientSnapshot {
            phase: i.phase,
            reason: i.reason.clone(),
            mac_name: i.mac_name.clone(),
            host: i.link.as_ref().map(|l| l.host.clone()).unwrap_or_default(),
            sessions: i.sessions.clone(),
            notice: i.notice.clone(),
            features: i.features.clone(),
            scopes: i.scopes.clone(),
            mac_version: i.mac_version,
            oldest_phone: i.oldest_phone,
        }
    }

    /// Whether the paired computer lists this feature.
    pub fn has(&self, feature: &str) -> bool {
        self.lock().features.iter().any(|f| f == feature)
    }

    pub fn is_paired(&self) -> bool {
        self.lock().link.is_some()
    }

    pub fn clear_notice(&self) {
        self.lock().notice = None;
    }

    /// Koppelt met de code die de computer toont. De eerste aanvraag, `hello`, bewijst dat de telefoon de sleutel
    /// heeft; de computer bewaart het toestel dan.
    pub async fn pair(&self, text: &str, device_name: &str) -> ClientSnapshot {
        let Some(parsed) = PairingLink::parse(text) else {
            self.lock().notice = Some("Dat is geen geldige koppelcode.".into());
            return self.snapshot();
        };
        {
            let mut i = self.lock();
            i.phase = Phase::Pairing;
            i.notice = None;
        }
        let mut hello = CompanionRequest::versioned(CompanionOp::Hello, &self.app_version);
        hello.text = Some(device_name.into());
        let result = match request(&parsed, &hello, &*self.resolver).await {
            Ok(r) if r.ok => self.save(&parsed).map(|_| r),
            Ok(_) => Err(ClientError::Refused),
            Err(e) => Err(e),
        };
        let mut i = self.lock();
        match result {
            Ok(response) => {
                i.mac_name = response.mac_name.unwrap_or_else(|| parsed.mac_name.clone());
                i.link = Some(parsed);
                i.features = response.features.unwrap_or_default();
                i.scopes = response.scopes;
                i.mac_version = response.protocol_version;
                i.oldest_phone = response.oldest_phone;
                i.sessions = response.sessions.unwrap_or_default();
                i.phase = Phase::Connected;
                i.reason.clear();
            }
            Err(e) => {
                i.phase = if i.link.is_some() { Phase::Offline } else { Phase::Unpaired };
                i.notice = Some(format!("Koppelen mislukt: {e} De code werkt vijf minuten en één keer; maak op je computer een nieuwe."));
            }
        }
        drop(i);
        self.snapshot()
    }

    fn save(&self, link: &PairingLink) -> Result<(), ClientError> {
        let stored =
            StoredPairing { host: link.host.clone(), port: link.port, key: base64url_encode(&link.key), mac_name: link.mac_name.clone() };
        let json = serde_json::to_string(&stored).map_err(|_| ClientError::Storage)?;
        self.secrets.write(PAIRING_ACCOUNT, &json).map_err(|_| ClientError::Storage)
    }

    pub fn unpair(&self) -> ClientSnapshot {
        let _ = self.secrets.remove(PAIRING_ACCOUNT);
        {
            let mut i = self.lock();
            i.link = None;
            i.sessions.clear();
            i.phase = Phase::Unpaired;
            i.mac_name.clear();
            i.reason.clear();
            i.features.clear();
            i.scopes = None;
        }
        self.snapshot()
    }

    pub async fn refresh(&self) -> ClientSnapshot {
        self.perform(CompanionRequest::versioned(CompanionOp::List, &self.app_version)).await
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

    /// Any other request the interface makes (the whole conversation, a new session, Nook's chats, home, limits, the
    /// Chats tab, managing a session). The answer comes back as it came, beside the new state; `None` when the computer
    /// could not be reached or refused it (the state's notice or reason says why).
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
        self.exchange(r).await
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

    /// Keeps one connection open to the computer, as the iPhone app does while it is in front (`subscribe`): the
    /// computer sends the sessions, the open session's conversation, the chats and Nook's conversations as they change,
    /// and the phone pings every few seconds with `foreground()`. `on_update` gets every update with the new state.
    /// Returns when the connection ends; the caller decides when to connect again. Only for a computer that lists
    /// `feature::STREAM`.
    pub async fn stream(
        &self,
        foreground: impl Fn() -> bool,
        mut on_update: impl FnMut(ClientSnapshot, CompanionResponse),
    ) -> Result<(), ClientError> {
        let Some(link) = self.lock().link.clone() else { return Err(ClientError::Closed) };
        let addresses = self.resolver.resolve(&link.host, link.port).await;
        let mut stream = None;
        let mut last = ClientError::Unreachable(format!("{} niet gevonden", link.host));
        for addr in &addresses {
            match tokio::time::timeout(EXCHANGE_TIMEOUT, TcpStream::connect(addr)).await {
                Ok(Ok(s)) => {
                    stream = Some(s);
                    break;
                }
                Ok(Err(e)) => last = ClientError::Unreachable(e.to_string()),
                Err(_) => last = ClientError::Timeout,
            }
        }
        let (mut reader, mut writer) = stream.ok_or(last)?.into_split();
        let mut subscribe = CompanionRequest::versioned(CompanionOp::Subscribe, &self.app_version);
        subscribe.foreground = Some(foreground());
        let id = subscribe.id.clone();
        writer.write_all(&sealed_frame(&link, &subscribe)?).await.map_err(|_| ClientError::Closed)?;

        let mut frames = FrameReader::default();
        let mut buf = vec![0u8; 64 * 1024];
        let mut ping = tokio::time::interval(PING_EVERY);
        ping.tick().await;
        let mut last_seq = -1i64;
        loop {
            tokio::select! {
                read = tokio::time::timeout(STREAM_IDLE, reader.read(&mut buf)) => {
                    let n = match read {
                        Err(_) => return Err(ClientError::Timeout),
                        Ok(Err(_)) | Ok(Ok(0)) => return Err(ClientError::Closed),
                        Ok(Ok(n)) => n,
                    };
                    for frame in frames.feed(&buf[..n]) {
                        let opened = seal::open(&frame, &link.key, Direction::Response).map_err(|_| ClientError::BadResponse)?;
                        let Ok(response) = serde_json::from_slice::<CompanionResponse>(&opened) else { continue };
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
                            if let Some(list) = &response.sessions {
                                i.sessions = list.clone();
                            }
                            if let Some(name) = &response.mac_name {
                                i.mac_name = name.clone();
                            }
                            if response.features.is_some() {
                                i.features = response.features.clone().unwrap_or_default();
                                i.scopes = response.scopes.clone();
                                i.mac_version = response.protocol_version;
                                i.oldest_phone = response.oldest_phone;
                            }
                            i.phase = Phase::Connected;
                            i.reason.clear();
                        }
                        on_update(self.snapshot(), response);
                    }
                    if frames.overflowed() {
                        return Err(ClientError::BadResponse);
                    }
                }
                _ = ping.tick() => {
                    let mut p = CompanionRequest::new(CompanionOp::Ping);
                    p.foreground = Some(foreground());
                    writer.write_all(&sealed_frame(&link, &p)?).await.map_err(|_| ClientError::Closed)?;
                }
            }
        }
    }

    async fn perform(&self, req: CompanionRequest) -> ClientSnapshot {
        self.exchange(req).await.0
    }

    async fn exchange(&self, req: CompanionRequest) -> (ClientSnapshot, Option<CompanionResponse>) {
        let Some(link) = self.lock().link.clone() else { return (self.snapshot(), None) };
        let op = req.op;
        let result = request(&link, &req, &*self.resolver).await;
        let mut refresh = false;
        let mut answer = None;
        {
            let mut i = self.lock();
            match result {
                Ok(response) if response.ok => {
                    if let Some(list) = &response.sessions {
                        i.sessions = list.clone();
                    }
                    if let Some(name) = &response.mac_name {
                        i.mac_name = name.clone();
                    }
                    if matches!(op, CompanionOp::Hello | CompanionOp::List) {
                        // A Mac lists its features with every `list`; one that lists none can do only the first version.
                        i.features = response.features.clone().unwrap_or_default();
                        i.scopes = response.scopes.clone();
                        i.mac_version = response.protocol_version;
                        i.oldest_phone = response.oldest_phone;
                    }
                    i.phase = Phase::Connected;
                    i.reason.clear();
                    if op == CompanionOp::Send {
                        if let Some(message) = &response.message {
                            i.notice = (message == "queued").then(|| "In de wachtrij: de sessie is nog bezig.".into());
                        }
                    }
                    answer = Some(response);
                }
                Ok(response) => {
                    i.phase = Phase::Connected;
                    // A refusal that says why in words (a chat app that could not send) shows those words.
                    let said = response.message.clone().filter(|m| response.error == Some(CompanionError::Failed) && !m.trim().is_empty());
                    i.notice = Some(said.unwrap_or_else(|| {
                        match response.error {
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
                Err(e) => {
                    i.phase = Phase::Offline;
                    i.reason = e.to_string();
                }
            }
        }
        if refresh {
            let notice = self.lock().notice.clone();
            Box::pin(self.refresh()).await;
            self.lock().notice = notice;
        }
        (self.snapshot(), answer)
    }
}
