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
        return Err(ClientError::Unreachable(format!("{} niet gevonden", link.host)));
    }
    let reply = exchange(&addresses, &framed).await?;
    let opened = seal::open(&reply, &link.key, Direction::Response).map_err(|_| ClientError::BadResponse)?;
    let response: CompanionResponse = serde_json::from_slice(&opened).map_err(|_| ClientError::BadResponse)?;
    if response.id != req.id {
        return Err(ClientError::BadResponse);
    }
    Ok(response)
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
}

struct Inner {
    link: Option<PairingLink>,
    phase: Phase,
    reason: String,
    mac_name: String,
    sessions: Vec<SessionDigest>,
    notice: Option<String>,
}

pub struct CompanionClient {
    secrets: Arc<dyn SecretStore>,
    resolver: Arc<dyn HostResolver>,
    inner: Mutex<Inner>,
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
        };
        Self { secrets, resolver, inner: Mutex::new(inner) }
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
        }
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
        let mut hello = CompanionRequest::new(CompanionOp::Hello);
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
        }
        self.snapshot()
    }

    pub async fn refresh(&self) -> ClientSnapshot {
        self.perform(CompanionRequest::new(CompanionOp::List)).await
    }

    pub async fn decide(&self, session: &str, item: &str, allow: bool) -> ClientSnapshot {
        let mut r = CompanionRequest::new(CompanionOp::Decide);
        r.session = Some(session.into());
        r.item = Some(item.into());
        r.allow = Some(allow);
        self.perform(r).await
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

    async fn perform(&self, req: CompanionRequest) -> ClientSnapshot {
        let Some(link) = self.lock().link.clone() else { return self.snapshot() };
        let result = request(&link, &req, &*self.resolver).await;
        let mut refresh = false;
        {
            let mut i = self.lock();
            match result {
                Ok(response) if response.ok => {
                    if let Some(list) = response.sessions {
                        i.sessions = list;
                    }
                    if let Some(name) = response.mac_name {
                        i.mac_name = name;
                    }
                    i.phase = Phase::Connected;
                    i.reason.clear();
                    if let Some(message) = response.message {
                        i.notice = (message == "queued").then(|| "In de wachtrij: de sessie is nog bezig.".into());
                    }
                }
                Ok(response) => {
                    i.phase = Phase::Connected;
                    i.notice = Some(
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
                        .into(),
                    );
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
        self.snapshot()
    }
}
