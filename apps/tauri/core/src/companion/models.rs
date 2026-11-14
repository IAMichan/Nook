//! Berichten, framing en regels van het companion-protocol (`packages/protocol/Sources/CompanionModels.swift`).
//! Het formaat op de lijn is gelijk aan dat van de Mac en de iPhone-app: JSON zoals `JSONEncoder` het maakt, met
//! weggelaten velden waar Swift `nil` heeft.

use std::collections::VecDeque;

use base64::Engine;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub const BONJOUR_TYPE: &str = "_nookcompanion._tcp";
pub const LINK_SCHEME: &str = "nook";
pub const LINK_HOST: &str = "pair";
pub const MAX_FRAME: usize = 256 * 1024;
/// Hoeveel de klok van een aanvraag mag afwijken.
pub const FRESHNESS: f64 = 60.0;
/// Hoe lang een koppelcode geldt (seconden).
pub const PAIRING_WINDOW: i64 = 300;
pub const EXCERPT_LIMIT: usize = 600;
pub const KEY_LENGTH: usize = 32;

/// Wat de computer toont om te koppelen: `nook://pair?h=<host>&p=<poort>&k=<base64url-sleutel>&n=<naam>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingLink {
    pub host: String,
    pub port: u16,
    pub key: Vec<u8>,
    pub mac_name: String,
}

impl PairingLink {
    pub fn url(&self) -> String {
        format!(
            "{LINK_SCHEME}://{LINK_HOST}?h={}&p={}&k={}&n={}",
            percent_encode(&self.host),
            self.port,
            base64url_encode(&self.key),
            percent_encode(&self.mac_name)
        )
    }

    pub fn parse(text: &str) -> Option<PairingLink> {
        let text = text.trim();
        let rest = text.strip_prefix(LINK_SCHEME)?.strip_prefix("://")?;
        let (authority, query) = match rest.split_once('?') {
            Some((a, q)) => (a, q),
            None => (rest, ""),
        };
        let query = query.split('#').next().unwrap_or("");
        // `nook://pair` met eventueel een lege of `/`-pad, zoals URLComponents het leest.
        let host = authority.split('/').next().unwrap_or("");
        if host != LINK_HOST {
            return None;
        }
        let mut q: Vec<(String, String)> = Vec::new();
        for part in query.split('&').filter(|p| !p.is_empty()) {
            let (name, value) = part.split_once('=').unwrap_or((part, ""));
            let (name, value) = (percent_decode(name)?, percent_decode(value)?);
            if !q.iter().any(|(n, _)| *n == name) {
                q.push((name, value));
            }
        }
        let get = |k: &str| q.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone());
        let host = get("h")?;
        if !valid_host(&host) {
            return None;
        }
        let port: u16 = get("p")?.parse().ok()?;
        if port == 0 {
            return None;
        }
        let key = base64url_decode(&get("k")?)?;
        if key.len() != KEY_LENGTH {
            return None;
        }
        let name: String = get("n").unwrap_or_else(|| "Mac".into()).chars().filter(|c| !is_control(*c)).take(60).collect();
        Some(PairingLink { host, port, key, mac_name: if name.is_empty() { "Mac".into() } else { name } })
    }
}

/// Een IPv4/IPv6-adres of een hostnaam; niets met een schema, pad, inloggegevens of spaties.
pub fn valid_host(host: &str) -> bool {
    !host.is_empty() && host.chars().count() <= 253 && host.chars().all(|c| c.is_alphanumeric() || "-._:".contains(c))
}

fn percent_encode(text: &str) -> String {
    let mut out = String::new();
    for b in text.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = text.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

pub fn base64url_encode(data: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(data)
}

pub fn base64url_decode(text: &str) -> Option<Vec<u8>> {
    // Zoals `Base64URL.decode` op de Mac: aanvullen met `=` en dan gewoon base64.
    let mut s = text.replace('-', "+").replace('_', "/");
    while !s.len().is_multiple_of(4) {
        s.push('=');
    }
    base64::engine::general_purpose::STANDARD.decode(s).ok()
}

/// `CharacterSet.controlCharacters` op de Mac: de Unicode-categorieën Cc en Cf.
pub fn is_control(c: char) -> bool {
    if c.is_control() {
        return true;
    }
    matches!(c as u32,
        0x00AD | 0x0600..=0x0605 | 0x061C | 0x06DD | 0x070F | 0x0890..=0x0891 | 0x08E2 | 0x180E | 0x200B..=0x200F
        | 0x202A..=0x202E | 0x2060..=0x2064 | 0x2066..=0x206F | 0xFEFF | 0xFFF9..=0xFFFB | 0x110BD | 0x110CD
        | 0x13430..=0x1343F | 0x1BCA0..=0x1BCA3 | 0x1D173..=0x1D17A | 0xE0001 | 0xE0020..=0xE007F)
}

// Berichten

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CompanionOp {
    Hello,
    List,
    Decide,
    Answer,
    Send,
    Stop,
    /// Het APNs-token van de telefoon (`text`, hex) en de omgeving (`item`: "production" of "development").
    Register,
    Unregister,
    /// What a new session can start with (`launch` in the answer); `start` starts one (`launch` in the request).
    Options,
    Start,
    /// The recent conversation of one session (`session`; `timeline` in the answer).
    Timeline,
    /// Nook's own chats: the list, one conversation, a question (a new conversation when `conversation` is empty) and
    /// stopping the answer that is being written.
    Chats,
    Chat,
    Ask,
    ChatStop,
    /// Nook's home: what waits, the agenda, what plays, the limits (`home` in the answer).
    Home,
    /// Plan limits and what the sessions used (`item`: "today", "week" or "month"; `usage` in the answer).
    Usage,
    /// Play/pause, next or previous track (`text`); answered with `home`.
    Music,
    /// The Chats tab: the inbox, one chat's messages, your own words to a chat, and read or unread by hand.
    Inbox,
    InboxChat,
    InboxSend,
    InboxMark,
    /// Manages a session (`item`: a `SessionAction`, `text`: the new name of `rename` or the moment of `snoozeUntil`).
    Manage,
}

impl CompanionOp {
    /// The ops the phone side may send through `CompanionClient::call`: everything but pairing and push registration,
    /// which the client does itself.
    pub fn callable(self) -> bool {
        !matches!(self, CompanionOp::Hello | CompanionOp::Register | CompanionOp::Unregister)
    }
}

/// The protocol this side speaks (`CompanionProtocol.version`): 3 added pull requests, files with a message, snoozing
/// to a moment and `limitResetsAt`. Unknown fields are ignored, so a newer Mac's answers still read.
pub const PROTOCOL_VERSION: i64 = 3;

/// What a Mac can do beyond the first version of the protocol (`CompanionFeature`). The phone only offers what the Mac
/// lists in `CompanionResponse::features`.
pub mod feature {
    pub const START: &str = "start";
    pub const TIMELINE: &str = "timeline";
    pub const CHAT: &str = "chat";
    pub const HOME: &str = "home";
    pub const USAGE: &str = "usage";
    pub const MUSIC: &str = "music";
    pub const INBOX: &str = "inbox";
    pub const MANAGE: &str = "manage";
    pub const STEER: &str = "steer";
}

/// A new session as the phone asks for it (`LaunchRequest`). The Mac decides the rest from its own defaults.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchRequest {
    pub agent: String,
    pub project: String,
    pub task: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub plan: bool,
    pub worktree: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub main_thread: Option<bool>,
}

/// Eén aanvraag van de telefoon. `id` is uniek per aanvraag; `sent` is de klok van de telefoon (seconden sinds 1970).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CompanionRequest {
    pub id: String,
    pub sent: f64,
    pub op: CompanionOp,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub allow: Option<bool>,
    /// A Nook chat, for `chat`, `ask` and `chatStop`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub launch: Option<LaunchRequest>,
    /// The message of a chat that `inboxSend` answers.
    #[serde(default, rename = "replyTo", skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<String>,
    /// This side's protocol and app version, with `hello` and `list`.
    #[serde(default, rename = "protocolVersion", skip_serializing_if = "Option::is_none")]
    pub protocol_version: Option<i64>,
    #[serde(default, rename = "appVersion", skip_serializing_if = "Option::is_none")]
    pub app_version: Option<String>,
    /// With `send` to a working session: true steers the running turn, false or nil waits for it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub steer: Option<bool>,
    /// With `stop` and a steering `send`: the turn the phone saw (`SessionDigest::turn`), so only that turn is reached.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn: Option<String>,
}

impl CompanionRequest {
    /// Een nieuwe aanvraag met een uniek id (hoofdletters, zoals `UUID().uuidString`) en de klok van nu.
    pub fn new(op: CompanionOp) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            sent: chrono::Utc::now().timestamp_millis() as f64 / 1000.0,
            op,
            session: None,
            item: None,
            text: None,
            allow: None,
            conversation: None,
            launch: None,
            reply_to: None,
            protocol_version: None,
            app_version: None,
            steer: None,
            turn: None,
        }
    }

    /// A request that says which versions this side speaks: `hello` and `list` carry them.
    pub fn versioned(op: CompanionOp, app_version: &str) -> Self {
        Self { protocol_version: Some(PROTOCOL_VERSION), app_version: Some(app_version.into()), ..Self::new(op) }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CompanionError {
    Stale,
    Replay,
    RateLimited,
    UnknownSession,
    UnknownItem,
    NotAllowedFromPhone,
    BadRequest,
    Busy,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompanionResponse {
    pub id: String,
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<CompanionError>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mac_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sessions: Option<Vec<SessionDigest>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    /// What the Mac can do beyond the first version (`feature`), with `hello` and `list`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub features: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub protocol_version: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub oldest_phone: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app_version: Option<String>,
    /// What this phone may do on the Mac (`CompanionScope` names); nil from a Mac without scopes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scopes: Option<Vec<String>>,
    /// The id of the session `start` started, or of the conversation `ask` began.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created: Option<String>,
    // The phone side passes these through to the interface as they came (`CompanionModels.swift` has their shapes):
    // `LaunchOptions`, `[TimelineEntry]`, `[ChatDigest]`, `[ChatLine]`, `HomeDigest`, `UsageDigest`, `[InboxChatDigest]`,
    // `[InboxLine]` and `[InboxTypist]`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub launch: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeline: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeline_session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversations: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub messages: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub home: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inbox: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inbox_lines: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inbox_typing: Option<serde_json::Value>,
}

impl CompanionResponse {
    pub fn failure(id: &str, error: CompanionError) -> Self {
        Self { id: id.into(), ok: false, error: Some(error), ..Default::default() }
    }

    pub fn success(id: &str) -> Self {
        Self { id: id.into(), ok: true, ..Default::default() }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ItemKind {
    #[default]
    Approval,
    Question,
}

/// Wat in een sessie op jou wacht.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DigestItem {
    pub id: String,
    pub kind: ItemKind,
    pub title: String,
    pub detail: String,
    /// De telefoon mag dit toestaan. Zo niet, dan kan ze het alleen weigeren of aan de computer laten.
    pub can_allow: bool,
    pub options: Vec<String>,
    /// A question's option previews (a mock-up or code per option, empty for one without); nil when none has one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub option_previews: Option<Vec<String>>,
}

/// Wat de telefoon over een sessie hoort. Titels en uittreksels zijn ingekort: de telefoon is geen logboek.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionDigest {
    pub id: String,
    pub title: String,
    pub agent: String,
    /// `AgentAttention`: approval, input, failed, limited, working, ready, idle, finished.
    pub attention: String,
    pub folder: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    pub updated: f64,
    pub excerpt: String,
    pub items: Vec<DigestItem>,
    /// The phone can send this session a message or stop it; false for an agent in a terminal. Nil means yes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub can_send: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// `SessionAction` names the phone may take on this session (`manage`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actions: Option<Vec<String>>,
    /// The running turn can take a message right now (`steer`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub can_steer: Option<bool>,
    /// When the usage limit that stopped this session resets (seconds since 1970).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit_resets_at: Option<f64>,
    /// The turn that runs now, sent back with a Stop or a steer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn: Option<String>,
}

/// Sessies die op jou wachten (een goedkeuring of een vraag), voor het getal op het icoon.
pub fn needing_you(sessions: &[SessionDigest]) -> usize {
    sessions.iter().filter(|s| !s.items.is_empty()).count()
}

// Framing

/// Berichten reizen als 4 bytes lengte (big-endian) en dan zoveel bytes. Een te groot frame sluit de verbinding.
#[derive(Debug, Default)]
pub struct FrameReader {
    buffer: Vec<u8>,
    overflowed: bool,
}

impl FrameReader {
    pub fn overflowed(&self) -> bool {
        self.overflowed
    }

    pub fn feed(&mut self, data: &[u8]) -> Vec<Vec<u8>> {
        if self.overflowed {
            return Vec::new();
        }
        self.buffer.extend_from_slice(data);
        let mut frames = Vec::new();
        while self.buffer.len() >= 4 {
            let length = u32::from_be_bytes([self.buffer[0], self.buffer[1], self.buffer[2], self.buffer[3]]) as usize;
            if length > MAX_FRAME {
                self.overflowed = true;
                self.buffer.clear();
                return frames;
            }
            if self.buffer.len() < 4 + length {
                break;
            }
            frames.push(self.buffer[4..4 + length].to_vec());
            self.buffer.drain(..4 + length);
        }
        frames
    }

    pub fn frame(payload: &[u8]) -> Option<Vec<u8>> {
        if payload.len() > MAX_FRAME {
            return None;
        }
        let mut out = (payload.len() as u32).to_be_bytes().to_vec();
        out.extend_from_slice(payload);
        Some(out)
    }
}

// Regels

/// Recent geziene ids, zodat een herhaalde aanvraag geweigerd wordt (`DeliveryLog`).
#[derive(Debug)]
pub struct DeliveryLog {
    ids: VecDeque<String>,
    capacity: usize,
}

impl DeliveryLog {
    pub fn new(capacity: usize) -> Self {
        Self { ids: VecDeque::new(), capacity: capacity.max(1) }
    }

    /// Waar als `id` nieuw is; onwaar bij een herhaling. Het oudste id valt weg als het logboek vol is.
    pub fn record(&mut self, id: &str) -> bool {
        if self.ids.iter().any(|i| i == id) {
            return false;
        }
        self.ids.push_back(id.into());
        while self.ids.len() > self.capacity {
            self.ids.pop_front();
        }
        true
    }
}

/// Hoogstens `limit` aanvragen per `window` seconden (`RateWindow`). De klok wordt meegegeven.
#[derive(Debug)]
pub struct RateWindow {
    limit: usize,
    window: f64,
    accepted: Vec<f64>,
}

impl RateWindow {
    pub fn new(limit: usize, window: f64) -> Self {
        Self { limit: limit.max(1), window, accepted: Vec::new() }
    }

    pub fn admit(&mut self, now: f64) -> bool {
        self.accepted.retain(|t| now - t < self.window);
        if self.accepted.len() < self.limit {
            self.accepted.push(now);
            true
        } else {
            false
        }
    }
}

/// Wat de computer controleert voordat hij kijkt wat een aanvraag vraagt.
#[derive(Debug)]
pub struct RequestGuard {
    seen: DeliveryLog,
    rate: RateWindow,
}

impl Default for RequestGuard {
    fn default() -> Self {
        Self { seen: DeliveryLog::new(200), rate: RateWindow::new(120, 60.0) }
    }
}

impl RequestGuard {
    /// `None` als de aanvraag door mag. `now` in seconden sinds 1970.
    pub fn admit(&mut self, request: &CompanionRequest, now: f64) -> Option<CompanionError> {
        if (now - request.sent).abs() > FRESHNESS {
            return Some(CompanionError::Stale);
        }
        if !self.rate.admit(now) {
            return Some(CompanionError::RateLimited);
        }
        if !self.seen.record(&request.id) {
            return Some(CompanionError::Replay);
        }
        None
    }
}

pub struct CompanionPolicy;

impl CompanionPolicy {
    /// Of een goedkeuring vanaf de telefoon toegestaan mag worden. Een commando alleen als het veilig is beoordeeld;
    /// bestanden lezen en bewerken wel; al het andere (gevaarlijke of onbeoordeelbare commando's, web, MCP, onbekend) niet.
    pub fn can_allow(tool: &str, command_is_safe: Option<bool>) -> bool {
        match tool {
            "Bash" | "bash" | "shell" | "command" | "Shell" => command_is_safe == Some(true),
            "Read" | "Glob" | "Grep" | "LS" | "Edit" | "MultiEdit" | "Write" | "NotebookEdit" | "fileChange" => true,
            _ => false,
        }
    }

    pub fn excerpt(text: &str) -> String {
        let flat = text.replace('\r', "");
        let flat = flat.trim();
        if flat.chars().count() <= EXCERPT_LIMIT {
            return flat.into();
        }
        let mut cut: String = flat.chars().take(EXCERPT_LIMIT).collect();
        cut.push('…');
        cut
    }

    /// Een bericht van de telefoon is begrensd als een concept; stuurtekens behalve regeleinde en tab gaan eruit.
    pub fn clean_message(text: &str) -> Option<String> {
        let kept: String = text.chars().filter(|c| *c == '\n' || *c == '\t' || !is_control(*c)).collect();
        let clean = kept.trim();
        (!clean.is_empty() && clean.chars().count() <= 8_000).then(|| clean.to_string())
    }
}

/// Een gekoppeld toestel zoals de computer het bewaart (zonder de sleutel, die in de kluis staat).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairedDevice {
    /// Openbaar kenmerk van de sleutel (eerste 8 bytes van SHA-256, hex); de telefoon stuurt het mee.
    pub id: String,
    pub name: String,
    pub paired_at: chrono::DateTime<chrono::Utc>,
    #[serde(default)]
    pub last_seen: Option<chrono::DateTime<chrono::Utc>>,
    /// Waar pushmeldingen heen gaan; leeg tot de telefoon meldingen toestaat.
    #[serde(default)]
    pub push_token: Option<String>,
    #[serde(default)]
    pub push_production: Option<bool>,
}

impl PairedDevice {
    pub fn identifier(key: &[u8]) -> String {
        Sha256::digest(key)[..8].iter().map(|b| format!("{b:02x}")).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> Vec<u8> {
        (0u8..32).collect()
    }

    #[test]
    fn pairing_link_round_trip() {
        let link = PairingLink { host: "192.168.1.20".into(), port: 49321, key: key(), mac_name: "Michael’s Mac".into() };
        assert_eq!(PairingLink::parse(&link.url()), Some(link));
    }

    #[test]
    fn pairing_link_reads_what_the_mac_writes() {
        // Zo maakt URLComponents de link op de Mac.
        let k = base64url_encode(&key());
        let text = format!("nook://pair?h=Michaels-MacBook.local&p=49321&k={k}&n=Michael%E2%80%99s%20MacBook");
        let link = PairingLink::parse(&text).unwrap();
        assert_eq!(link.host, "Michaels-MacBook.local");
        assert_eq!(link.mac_name, "Michael’s MacBook");
        assert_eq!(link.key, key());
    }

    #[test]
    fn pairing_link_refuses_bad_input() {
        let k = base64url_encode(&key());
        assert!(PairingLink::parse("https://pair?h=a&p=1&k=x").is_none());
        assert!(PairingLink::parse(&format!("nook://pair?h=a&p=0&k={k}")).is_none());
        assert!(PairingLink::parse(&format!("nook://pair?h=a%2Fb&p=1&k={k}")).is_none(), "geen pad in een host");
        assert!(PairingLink::parse(&format!("nook://pair?h=a&p=1&k={}", base64url_encode(&[1; 16]))).is_none(), "korte sleutel");
        assert!(PairingLink::parse(&format!("nook://pair?h=a&p=70000&k={k}")).is_none());
        assert!(PairingLink::parse(&format!("nook://other?h=a&p=1&k={k}")).is_none());
        let link = PairingLink::parse(&format!("nook://pair?h=a&p=1&k={k}&n=%07")).unwrap();
        assert_eq!(link.mac_name, "Mac");
    }

    #[test]
    fn base64url_round_trip() {
        for length in 0..12usize {
            let data: Vec<u8> = (0..length).map(|i| (i * 37 + 250) as u8).collect();
            assert_eq!(base64url_decode(&base64url_encode(&data)), Some(data));
        }
        assert!(!base64url_encode(&[0xfb, 0xff]).contains('+'));
    }

    #[test]
    fn framing_splits_and_joins() {
        let mut reader = FrameReader::default();
        let mut all = FrameReader::frame(b"hello").unwrap();
        all.extend(FrameReader::frame(b"x").unwrap());
        assert!(reader.feed(&all[..3]).is_empty());
        let frames = reader.feed(&all[3..]);
        assert_eq!(frames, vec![b"hello".to_vec(), b"x".to_vec()]);
    }

    #[test]
    fn oversized_frame_closes_the_reader() {
        let mut reader = FrameReader::default();
        let n = (MAX_FRAME + 1) as u32;
        assert!(reader.feed(&n.to_be_bytes()).is_empty());
        assert!(reader.overflowed());
        assert!(reader.feed(b"more").is_empty());
        assert!(FrameReader::frame(&vec![0; MAX_FRAME + 1]).is_none());
    }

    fn request(id: &str, sent: f64) -> CompanionRequest {
        CompanionRequest { id: id.into(), sent, ..CompanionRequest::new(CompanionOp::List) }
    }

    #[test]
    fn guard_refuses_stale_and_replayed_requests() {
        let mut guard = RequestGuard::default();
        let now = 1_000_000.0;
        assert_eq!(guard.admit(&request("a", now), now), None);
        assert_eq!(guard.admit(&request("a", now), now), Some(CompanionError::Replay));
        assert_eq!(guard.admit(&request("b", now - 120.0), now), Some(CompanionError::Stale));
        assert_eq!(guard.admit(&request("c", now + 120.0), now), Some(CompanionError::Stale));
    }

    #[test]
    fn guard_rate_limits() {
        let mut guard = RequestGuard::default();
        let now = 1_000_000.0;
        let limited = (0..200).any(|i| guard.admit(&request(&format!("r{i}"), now), now) == Some(CompanionError::RateLimited));
        assert!(limited);
    }

    #[test]
    fn policy_only_allows_low_risk_from_the_phone() {
        assert!(CompanionPolicy::can_allow("Edit", None));
        assert!(CompanionPolicy::can_allow("Bash", Some(true)));
        assert!(!CompanionPolicy::can_allow("Bash", Some(false)));
        assert!(!CompanionPolicy::can_allow("Bash", None));
        assert!(!CompanionPolicy::can_allow("WebFetch", None));
        assert!(!CompanionPolicy::can_allow("mcp__x__y", None));
    }

    #[test]
    fn message_cleaning() {
        assert_eq!(CompanionPolicy::clean_message("  hi\u{0007}\nthere  ").as_deref(), Some("hi\nthere"));
        assert_eq!(CompanionPolicy::clean_message("a\u{200B}b").as_deref(), Some("ab"));
        assert_eq!(CompanionPolicy::clean_message("  \n "), None);
        assert_eq!(CompanionPolicy::clean_message(&"a".repeat(8_001)), None);
        assert_eq!(CompanionPolicy::excerpt(&"a".repeat(700)).chars().count(), EXCERPT_LIMIT + 1);
    }

    #[test]
    fn device_identifier_is_stable_and_short() {
        assert_eq!(PairedDevice::identifier(&key()), PairedDevice::identifier(&key()));
        assert_eq!(PairedDevice::identifier(&key()).len(), 16);
        assert_ne!(PairedDevice::identifier(&key()), PairedDevice::identifier(&[9; 32]));
        // SHA-256 van 0…31 begint met 630dcd29 66c4336691125448 (zelfde als PureSHA256 op de Mac).
        assert_eq!(PairedDevice::identifier(&key()), "630dcd2966c43366");
    }

    #[test]
    fn paired_device_decodes_without_push_fields() {
        let old = r#"{"id":"a","name":"iPhone","pairedAt":"2026-01-01T00:00:00Z"}"#;
        let device: PairedDevice = serde_json::from_str(old).unwrap();
        assert_eq!(device.push_token, None);
        assert_eq!(device.push_production, None);
    }

    #[test]
    fn badge_counts_sessions_with_items() {
        let item = DigestItem {
            id: "i".into(),
            kind: ItemKind::Approval,
            title: "t".into(),
            detail: String::new(),
            can_allow: false,
            options: vec![],
            ..Default::default()
        };
        let digest = |id: &str, items: Vec<DigestItem>| SessionDigest {
            id: id.into(),
            title: String::new(),
            agent: String::new(),
            attention: "idle".into(),
            folder: String::new(),
            branch: None,
            updated: 0.0,
            excerpt: String::new(),
            items,
            ..Default::default()
        };
        assert_eq!(needing_you(&[digest("1", vec![item.clone(), item]), digest("2", vec![])]), 1);
    }

    #[test]
    fn phone_requests_write_what_the_mac_reads() {
        let mut r = CompanionRequest::versioned(CompanionOp::List, "1.2.0");
        r.reply_to = Some("m1".into());
        r.steer = Some(true);
        r.turn = Some("t1".into());
        r.launch = Some(LaunchRequest {
            agent: "claude".into(),
            project: "/p".into(),
            task: "Fix it".into(),
            title: None,
            plan: true,
            worktree: false,
            model: None,
            main_thread: Some(true),
        });
        let json = serde_json::to_value(&r).unwrap();
        assert_eq!(json["protocolVersion"], PROTOCOL_VERSION);
        assert_eq!(json["appVersion"], "1.2.0");
        assert_eq!(json["replyTo"], "m1");
        assert_eq!(json["launch"]["mainThread"], true);
        assert!(json["launch"].get("model").is_none());
        for (op, name) in [(CompanionOp::ChatStop, "chatStop"), (CompanionOp::InboxChat, "inboxChat"), (CompanionOp::Options, "options")] {
            assert_eq!(serde_json::to_value(op).unwrap(), name);
        }
        assert!(!CompanionOp::Hello.callable() && !CompanionOp::Register.callable() && CompanionOp::Timeline.callable());
        // A digest from a current Mac keeps what the phone shows.
        let digest: SessionDigest = serde_json::from_value(serde_json::json!({
            "id": "S", "title": "t", "agent": "Claude Code", "attention": "working", "folder": "f", "updated": 1.0,
            "excerpt": "", "items": [], "canSend": false, "canSteer": true, "actions": ["rename"], "turn": "T"
        }))
        .unwrap();
        assert_eq!((digest.can_send, digest.can_steer, digest.turn.as_deref()), (Some(false), Some(true), Some("T")));
    }

    #[test]
    fn request_and_response_codable_like_swift() {
        let mut request = CompanionRequest::new(CompanionOp::Decide);
        request.session = Some("s".into());
        request.item = Some("i".into());
        request.allow = Some(true);
        let json = serde_json::to_string(&request).unwrap();
        assert!(!json.contains("text"), "nil-velden laat Swift weg");
        assert_eq!(serde_json::from_str::<CompanionRequest>(&json).unwrap(), request);
        let response = CompanionResponse::failure("x", CompanionError::NotAllowedFromPhone);
        let json = serde_json::to_string(&response).unwrap();
        assert_eq!(json, r#"{"id":"x","ok":false,"error":"notAllowedFromPhone"}"#);
        assert_eq!(serde_json::from_str::<CompanionResponse>(&json).unwrap(), response);
        // Zoals JSONEncoder op de iPhone het schrijft (met `\/`).
        let swift = r#"{"id":"A","sent":1700000000.5,"op":"hello","text":"Michael\/iPhone"}"#;
        let parsed: CompanionRequest = serde_json::from_str(swift).unwrap();
        assert_eq!(parsed.op, CompanionOp::Hello);
        assert_eq!(parsed.text.as_deref(), Some("Michael/iPhone"));
        assert!(serde_json::from_str::<CompanionRequest>(r#"{"id":"A","sent":1,"op":"explode"}"#).is_err());
    }
}
