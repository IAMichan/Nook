//! WhatsApp via een lokale koppeling (GOWA of OpenWA) op deze computer: de berichten, de gesprekken in het geheugen,
//! en wat de koppelingen sturen en antwoorden. Niets hiervan gaat ooit naar schijf of een logboek.
//!
//! Naar open-source code onder de MIT-licentie, Copyright (c) 2026 Louis Raillé (zie THIRD-PARTY-NOTICES.md). De
//! veldnamen komen uit de documentatie van de koppelingen:
//!   GOWA   — github.com/aldinokemal/go-whatsapp-web-multidevice
//!   OpenWA — github.com/rmyndharis/OpenWA

pub mod link;
pub mod provider;

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};

use chrono::{DateTime, Duration, Utc};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::Sha256;

pub use link::WhatsAppLink;

pub const CREDENTIAL_ACCOUNT: &str = "whatsapp-gateway-credential";
pub const SECRET_ACCOUNT: &str = "whatsapp-webhook-secret";
pub const DEFAULT_PORT: u16 = 47823;
pub const WEBHOOK_PATH: &str = "/whatsapp";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum GatewayKind {
    #[default]
    Gowa,
    Openwa,
}

impl GatewayKind {
    pub fn name(self) -> &'static str {
        match self {
            Self::Gowa => "GOWA",
            Self::Openwa => "OpenWA",
        }
    }

    pub fn default_url(self) -> &'static str {
        match self {
            Self::Gowa => "http://127.0.0.1:3000",
            Self::Openwa => "http://127.0.0.1:2785",
        }
    }

    /// De header met de HMAC-SHA256 van de webhook ("sha256=<hex>"), in kleine letters.
    pub fn signature_header(self) -> &'static str {
        match self {
            Self::Gowa => "x-hub-signature-256",
            Self::Openwa => "x-openwa-signature",
        }
    }
}

/// Wat de gebruiker koos bij WhatsApp live. Het wachtwoord en het webhookgeheim staan in de kluis.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WhatsAppSettings {
    pub enabled: bool,
    pub gateway: GatewayKind,
    /// Leeg = het standaardadres van de koppeling.
    pub url: String,
    /// De poort van Nooks eigen webhook (altijd op 127.0.0.1).
    pub port: u16,
    /// Een nieuw bericht verschijnt in de interface met een veld om te antwoorden.
    pub notify: bool,
    /// Leesbevestiging bij antwoorden of "Gelezen"; nooit alleen bij ontvangst.
    pub mark_read_on_reply: bool,
    pub mute_groups: bool,
    /// Status updates (status@broadcast) stay quiet.
    pub mute_status: bool,
    /// Channels (…@newsletter) stay quiet.
    pub mute_channels: bool,
    pub ignored: BTreeSet<String>,
    /// Per chat (normalized JID): louder or quieter than its kind. Absent means automatic.
    pub modes: BTreeMap<String, ChatMode>,
    /// "GOWA automatisch starten" (alleen op de desktop).
    pub auto_start: bool,
    pub gowa_path: String,
}

impl Default for WhatsAppSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            gateway: GatewayKind::Gowa,
            url: String::new(),
            port: DEFAULT_PORT,
            notify: true,
            mark_read_on_reply: true,
            mute_groups: true,
            mute_status: true,
            mute_channels: true,
            ignored: BTreeSet::new(),
            modes: BTreeMap::new(),
            auto_start: false,
            gowa_path: String::new(),
        }
    }
}

impl WhatsAppSettings {
    pub fn address(&self) -> String {
        let stored = self.url.trim();
        if stored.is_empty() {
            self.gateway.default_url().into()
        } else {
            stored.into()
        }
    }

    pub fn webhook_port(&self) -> u16 {
        if self.port >= 1024 {
            self.port
        } else {
            DEFAULT_PORT
        }
    }

    pub fn filters(&self) -> Filters {
        Filters {
            mute_groups: self.mute_groups,
            mute_status: self.mute_status,
            mute_channels: self.mute_channels,
            ignored: self.ignored.iter().cloned().collect(),
            modes: self.modes.iter().map(|(k, v)| (k.clone(), *v)).collect(),
        }
    }

    /// Sets one chat's choice; automatic removes the entry.
    pub fn set_mode(&mut self, chat: &str, mode: ChatMode) {
        let key = jid::normalized(chat);
        if mode == ChatMode::Automatic {
            self.modes.remove(&key);
        } else {
            self.modes.insert(key, mode);
        }
    }
}

/// What one chat does when a message arrives, chosen per chat in Settings › WhatsApp.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum ChatMode {
    /// Follows the rule of its kind (groups, status updates and channels stay quiet; people reach you).
    #[default]
    Automatic,
    /// Always reaches you, even a group without a mention or a channel.
    Loud,
    /// Never reaches you; the chat is kept and can still be read.
    Muted,
}

/// The kinds of chat WhatsApp has, told apart by the JID's server.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ChatKind {
    Person,
    Group,
    Status,
    Channel,
}

/// How far your own message got, as WhatsApp's ticks show it: one grey tick when the server has it, two when it
/// reached the phone, two blue ones once it was read. Ordered, so ticks only move forward.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Receipt {
    Failed,
    Pending,
    Sent,
    Delivered,
    Read,
}

impl Receipt {
    /// A gateway's status word: OpenWA's `pending|sent|delivered|read|played|failed`, GOWA's `delivered|read|played`.
    pub fn from_status(status: &str) -> Option<Self> {
        Some(match status.to_lowercase().as_str() {
            "pending" => Self::Pending,
            "sent" | "server" => Self::Sent,
            "delivered" | "delivery" => Self::Delivered,
            "read" | "played" => Self::Read,
            "failed" | "error" => Self::Failed,
            _ => return None,
        })
    }

    /// Ticks only move forward; a failure always shows.
    pub fn advanced(self, new: Receipt) -> Receipt {
        if new == Receipt::Failed || new > self {
            new
        } else {
            self
        }
    }
}

/// What a message holds besides text: a label is shown, and the file itself is only fetched when the card shows it or
/// the user opens it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Media {
    #[default]
    None,
    Image,
    Video,
    Audio,
    Voice,
    Document {
        name: Option<String>,
    },
    Sticker,
    Location,
    Contact,
    Other,
}

impl Media {
    /// A file Nook can fetch from the gateway and open on this computer.
    pub fn is_openable(&self) -> bool {
        matches!(self, Self::Image | Self::Video | Self::Audio | Self::Voice | Self::Document { .. })
    }

    /// A file the card fetches by itself to show: a photo, a video or a document (a voice note stays a button).
    pub fn is_previewed(&self) -> bool {
        matches!(self, Self::Image | Self::Video | Self::Document { .. })
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    pub id: String,
    /// Het gesprek: een persoon (…@s.whatsapp.net, …@lid, …@c.us) of een groep (…@g.us).
    pub chat: String,
    pub sender: String,
    pub sender_name: String,
    pub text: String,
    pub media: Media,
    pub date: DateTime<Utc>,
    pub from_me: bool,
    pub mentions_me: bool,
    pub chat_name: Option<String>,
    /// Your own message's ticks; `None` when unknown (someone else's message, or history without a status).
    #[serde(default)]
    pub receipt: Option<Receipt>,
}

impl Message {
    pub fn new(id: &str, chat: &str, sender: &str, sender_name: &str, text: &str, date: DateTime<Utc>, from_me: bool) -> Self {
        Self {
            id: id.into(),
            chat: chat.into(),
            sender: sender.into(),
            sender_name: sender_name.into(),
            text: text.into(),
            media: Media::None,
            date,
            from_me,
            mentions_me: false,
            chat_name: None,
            receipt: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Conversation {
    pub id: String,
    pub name: String,
    pub is_group: bool,
    pub kind: ChatKind,
    /// Nieuwste laatst, alleen de laatste [`KEEP`].
    pub messages: Vec<Message>,
    pub unread: usize,
    pub last_activity: DateTime<Utc>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Filters {
    /// Groepen blijven stil tenzij het bericht jou noemt.
    pub mute_groups: bool,
    pub mute_status: bool,
    pub mute_channels: bool,
    pub ignored: HashSet<String>,
    /// Per chat (normalized JID); absent means automatic.
    pub modes: HashMap<String, ChatMode>,
}

impl Filters {
    pub fn mode(&self, chat: &str) -> ChatMode {
        self.modes.get(&jid::normalized(chat)).copied().unwrap_or_default()
    }

    /// Whether a chat's kind keeps it quiet, before any per-chat choice.
    pub fn kind_is_quiet(&self, kind: ChatKind) -> bool {
        match kind {
            ChatKind::Person => false,
            ChatKind::Group => self.mute_groups,
            ChatKind::Status => self.mute_status,
            ChatKind::Channel => self.mute_channels,
        }
    }

    /// Whether a message in this chat stays silent: the per-chat choice first, then the kind's rule. A mention in an
    /// automatic group still reaches you; a muted chat never does.
    pub fn is_quiet(&self, chat: &str, mentions_me: bool) -> bool {
        match self.mode(chat) {
            ChatMode::Loud => false,
            ChatMode::Muted => true,
            ChatMode::Automatic => {
                let kind = jid::kind(chat);
                self.kind_is_quiet(kind) && !(kind == ChatKind::Group && mentions_me)
            }
        }
    }
}

pub mod jid {
    use super::ChatKind;

    pub fn is_group(jid: &str) -> bool {
        jid.ends_with("@g.us")
    }

    /// The status updates of your contacts arrive as one chat, status@broadcast.
    pub fn is_status(jid: &str) -> bool {
        jid.to_lowercase().starts_with("status@")
    }

    /// A channel: a one-way broadcast you follow.
    pub fn is_channel(jid: &str) -> bool {
        jid.ends_with("@newsletter")
    }

    pub fn kind(jid: &str) -> ChatKind {
        if is_group(jid) {
            ChatKind::Group
        } else if is_status(jid) {
            ChatKind::Status
        } else if is_channel(jid) {
            ChatKind::Channel
        } else {
            ChatKind::Person
        }
    }

    /// A readable name for a chat without one: "Statusupdates", else the number.
    pub fn fallback_name(jid: &str) -> String {
        if is_status(jid) {
            "Statusupdates".into()
        } else {
            display_number(jid)
        }
    }

    /// "33612345678@s.whatsapp.net" → "+33612345678".
    pub fn display_number(jid: &str) -> String {
        let user = jid.split('@').next().unwrap_or(jid);
        let digits = user.split(':').next().unwrap_or(user);
        if !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit()) {
            format!("+{digits}")
        } else {
            digits.to_string()
        }
    }

    /// Dezelfde persoon in zijn verschillende vormen: "336…:12@s.whatsapp.net" en "336…@c.us" zijn één gesprek.
    pub fn normalized(jid: &str) -> String {
        let Some((user, server)) = jid.split_once('@') else { return jid.to_string() };
        let user = user.split(':').next().unwrap_or(user);
        let server = if server == "c.us" { "s.whatsapp.net" } else { server };
        format!("{user}@{server}")
    }

    /// De cijfers van het gebruikersdeel: "33612345678:3@s.whatsapp.net" → "33612345678".
    pub fn digits(jid: &str) -> String {
        let user = jid.split('@').next().unwrap_or(jid);
        user.split(':').next().unwrap_or(user).chars().filter(|c| c.is_ascii_digit()).collect()
    }

    pub fn same_user(a: &str, b: &str) -> bool {
        let (x, y) = (digits(a), digits(b));
        !x.is_empty() && x == y
    }
}

/// "@33612345678" in de tekst, voor het nummer van dit account (zo toont GOWA een vermelding).
pub fn text_mentions(text: &str, me: Option<&str>) -> bool {
    let Some(me) = me else { return false };
    let digits = jid::digits(me);
    digits.len() >= 6 && text.contains(&format!("@{digits}"))
}

/// Messages kept per chat (in memory only): enough for the card to scroll back a while.
pub const KEEP: usize = 50;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Duplicate,
    Ignored,
    Quiet,
    Notify,
}

/// De gesprekken, per chat: één regel per gesprek, nooit één per bericht.
#[derive(Debug, Clone, Default)]
pub struct Inbox {
    pub conversations: HashMap<String, Conversation>,
    seen: HashSet<String>,
    order: VecDeque<String>,
    /// Receipts that came before their message (the webhook can beat the answer to the send itself).
    early_receipts: HashMap<String, Receipt>,
}

impl Inbox {
    /// Nieuwste activiteit eerst.
    pub fn sorted(&self) -> Vec<&Conversation> {
        let mut list: Vec<&Conversation> = self.conversations.values().collect();
        list.sort_by_key(|b| std::cmp::Reverse(b.last_activity));
        list
    }

    pub fn total_unread(&self) -> usize {
        self.conversations.values().map(|c| c.unread).sum()
    }

    /// Voegt een bericht toe aan zijn gesprek. `Notify` als het jou moet bereiken, `Quiet` als het bewaard wordt maar
    /// stil blijft (een stille groep, je eigen bericht). `history`: een ouder bericht dat later geladen werd.
    pub fn add(&mut self, message: Message, filters: &Filters, name: Option<&str>, history: bool) -> Outcome {
        if self.seen.contains(&message.id) {
            return Outcome::Duplicate;
        }
        let chat = jid::normalized(&message.chat);
        if filters.ignored.contains(&chat) {
            return Outcome::Ignored;
        }
        self.seen.insert(message.id.clone());
        self.order.push_back(message.id.clone());
        if self.order.len() > 2_000 {
            for _ in 0..1_000 {
                if let Some(old) = self.order.pop_front() {
                    self.seen.remove(&old);
                }
            }
        }
        let kind = jid::kind(&chat);
        let is_group = kind == ChatKind::Group;
        let number = jid::fallback_name(&chat);
        // In een privégesprek noemt de ander het: nooit je eigen naam op je eigen bericht.
        let person = (kind == ChatKind::Person && !message.from_me && !message.sender_name.is_empty()).then(|| message.sender_name.clone());
        let given = name.map(str::to_string).or_else(|| message.chat_name.clone()).filter(|n| !n.is_empty());
        let conversation = self.conversations.entry(chat.clone()).or_insert_with(|| Conversation {
            id: chat.clone(),
            name: given.clone().or_else(|| person.clone()).unwrap_or_else(|| number.clone()),
            is_group,
            kind,
            messages: vec![],
            unread: 0,
            last_activity: message.date,
        });
        if let Some(name) = given {
            conversation.name = name;
        } else if conversation.name == number {
            if let Some(person) = person {
                conversation.name = person;
            }
        }
        let from_me = message.from_me;
        let mentions = message.mentions_me;
        let date = message.date;
        let mut msg = message;
        msg.chat = chat.clone();
        if msg.from_me {
            // Your own message that just went out has reached WhatsApp's server: one tick.
            if msg.receipt.is_none() && !history {
                msg.receipt = Some(Receipt::Sent);
            }
            if let Some(early) = self.early_receipts.remove(&msg.id) {
                msg.receipt = Some(msg.receipt.unwrap_or(Receipt::Sent).advanced(early));
            }
        }
        conversation.messages.push(msg);
        conversation.messages.sort_by_key(|m| m.date);
        if conversation.messages.len() > KEEP {
            let extra = conversation.messages.len() - KEEP;
            conversation.messages.drain(..extra);
        }
        conversation.last_activity = conversation.last_activity.max(date);
        if history {
            Outcome::Quiet
        } else if from_me {
            // Beantwoord vanaf de telefoon: daar gelezen.
            conversation.unread = 0;
            Outcome::Quiet
        } else {
            conversation.unread += 1;
            if filters.is_quiet(&chat, mentions) {
                Outcome::Quiet
            } else {
                Outcome::Notify
            }
        }
    }

    /// A delivery or read receipt for your own messages: their ticks move forward, never back. Returns the chat whose
    /// ticks changed, `None` when none did (a receipt for an incoming message, or for one Nook doesn't keep).
    pub fn apply_receipt(&mut self, status: Receipt, ids: &[String], chat: &str) -> Option<String> {
        let key = jid::normalized(chat);
        // The gateway can name the chat differently (a person's @lid against their number): then every chat is looked at.
        let keys: Vec<String> =
            if self.conversations.contains_key(&key) { vec![key] } else { self.conversations.keys().cloned().collect() };
        let mut pending: HashSet<&String> = ids.iter().collect();
        let mut changed = None;
        for chat_key in keys {
            let Some(conversation) = self.conversations.get_mut(&chat_key) else { continue };
            let mut touched = false;
            for message in conversation.messages.iter_mut() {
                if !pending.remove(&message.id) {
                    continue;
                }
                if !message.from_me {
                    continue;
                }
                let new = Some(message.receipt.unwrap_or(Receipt::Sent).advanced(status));
                if new != message.receipt {
                    message.receipt = new;
                    touched = true;
                }
            }
            if touched {
                changed = Some(chat_key);
            }
            if pending.is_empty() {
                break;
            }
        }
        // Not here yet: kept a little while for the message itself (only ids never seen; a few hundred at most).
        for id in pending.into_iter().filter(|id| !self.seen.contains(*id)) {
            let kept = self.early_receipts.get(id).copied().unwrap_or(status).advanced(status);
            self.early_receipts.insert(id.clone(), kept);
        }
        if self.early_receipts.len() > 500 {
            self.early_receipts.clear();
        }
        changed
    }

    /// The conversations the interface lists: quiet chats (a muted group, status updates, a channel, a chat you muted)
    /// stay out unless something in them reached you.
    pub fn visible(&self, filters: &Filters) -> Vec<&Conversation> {
        self.sorted()
            .into_iter()
            .filter(|c| {
                !filters.ignored.contains(&c.id)
                    && (!filters.is_quiet(&c.id, false) || c.messages.iter().any(|m| !m.from_me && !filters.is_quiet(&c.id, m.mentions_me)))
            })
            .collect()
    }

    pub fn visible_unread(&self, filters: &Filters) -> usize {
        self.visible(filters).iter().map(|c| c.unread).sum()
    }

    pub fn remove(&mut self, chat: &str) {
        self.conversations.remove(&jid::normalized(chat));
    }

    pub fn mark_read(&mut self, chat: &str) {
        if let Some(c) = self.conversations.get_mut(&jid::normalized(chat)) {
            c.unread = 0;
        }
    }

    pub fn rename(&mut self, chat: &str, name: &str) {
        if name.is_empty() {
            return;
        }
        if let Some(c) = self.conversations.get_mut(&jid::normalized(chat)) {
            c.name = name.into();
        }
    }

    pub fn clear(&mut self) {
        *self = Self::default();
    }
}

pub const MAX_LENGTH: usize = 4096;

/// Een paar berichten per minuut hooguit, wat er ook geklikt wordt: Nook is geen massaverzender.
#[derive(Debug, Clone)]
pub struct RateLimit {
    pub limit: usize,
    pub window: Duration,
    sent: Vec<DateTime<Utc>>,
}

impl RateLimit {
    pub fn new(limit: usize, window_secs: i64) -> Self {
        Self { limit, window: Duration::seconds(window_secs), sent: vec![] }
    }

    pub fn allow(&mut self, now: DateTime<Utc>) -> bool {
        let window = self.window;
        self.sent.retain(|t| now - *t <= window);
        if self.sent.len() >= self.limit {
            return false;
        }
        self.sent.push(now);
        true
    }
}

// Het HTTP-verzoek van de webhook

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpRequest {
    pub method: String,
    pub path: String,
    /// Namen in kleine letters.
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Parse {
    Incomplete,
    Invalid,
    Done(HttpRequest),
}

impl HttpRequest {
    /// Leest wat er tot nu toe binnen is; `Incomplete` tot de hele body er is.
    pub fn parse(data: &[u8], max_body: usize) -> Parse {
        let Some(end) = data.windows(4).position(|w| w == b"\r\n\r\n") else {
            return if data.len() > 16_384 { Parse::Invalid } else { Parse::Incomplete };
        };
        let Ok(head) = std::str::from_utf8(&data[..end]) else { return Parse::Invalid };
        let mut lines = head.split("\r\n");
        let first: Vec<&str> = lines.next().unwrap_or("").split(' ').collect();
        if first.len() < 2 {
            return Parse::Invalid;
        }
        let mut headers = HashMap::new();
        for line in lines {
            if let Some((name, value)) = line.split_once(':') {
                headers.insert(name.trim().to_lowercase(), value.trim().to_string());
            }
        }
        let length: i64 = headers.get("content-length").map(|v| v.parse().unwrap_or(-1)).unwrap_or(0);
        if length < 0 || length as usize > max_body {
            return Parse::Invalid;
        }
        let start = end + 4;
        if data.len() - start < length as usize {
            return Parse::Incomplete;
        }
        Parse::Done(HttpRequest {
            method: first[0].into(),
            path: first[1].into(),
            headers,
            body: data[start..start + length as usize].to_vec(),
        })
    }

    pub fn response(status: u16, reason: &str) -> Vec<u8> {
        format!("HTTP/1.1 {status} {reason}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").into_bytes()
    }
}

// Webhook

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// "sha256=<hex>" van HMAC-SHA256(geheim, body): wat beide koppelingen sturen.
pub fn signature(body: &[u8], secret: &str) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("HMAC accepteert elke sleutel");
    mac.update(body);
    format!("sha256={}", hex(&mac.finalize().into_bytes()))
}

/// Waar als de levering de handtekening draagt die `secret` geeft, over de ruwe bytes.
pub fn verify(kind: GatewayKind, headers: &HashMap<String, String>, body: &[u8], secret: &str) -> bool {
    if secret.is_empty() {
        return false;
    }
    let Some(sent) = headers.get(kind.signature_header()).filter(|s| s.starts_with("sha256=")) else { return false };
    crate::connectors::oauth::constant_time_eq(sent, &signature(body, secret))
}

#[derive(Debug, Clone, PartialEq)]
pub enum WebhookEvent {
    Message(Message),
    /// Your own messages reached the phone or were read: their ticks move.
    Receipt {
        ids: Vec<String>,
        chat: String,
        status: Receipt,
    },
    /// Een geldige levering waar Nook niets mee hoeft (reacties, een test).
    Ignored,
}

fn non_empty(v: &Value) -> Option<String> {
    v.as_str().filter(|s| !s.is_empty()).map(str::to_string)
}

pub fn rfc3339(v: &Value) -> Option<DateTime<Utc>> {
    v.as_str().and_then(|s| DateTime::parse_from_rfc3339(s).ok()).map(|d| d.with_timezone(&Utc))
}

/// Seconden sinds 1970, als getal of als tekst.
pub fn epoch(v: &Value) -> Option<DateTime<Utc>> {
    let n = crate::connectors::float(v).filter(|n| *n > 0.0)?;
    DateTime::from_timestamp_millis((n * 1000.0) as i64)
}

/// Leest één levering; `None` als het geen JSON is. `me` is de JID of het nummer van dit account.
pub fn parse_webhook(kind: GatewayKind, body: &[u8], me: Option<&str>) -> Option<WebhookEvent> {
    let json: Value = serde_json::from_slice(body).ok()?;
    if !json.is_object() {
        return None;
    }
    Some(match kind {
        GatewayKind::Gowa => parse_gowa(&json, me),
        GatewayKind::Openwa => parse_openwa(&json, me),
    })
}

/// `{"event":"message.ack","payload":{ids, chat_id, receipt_type: "delivered"|"read"|"played"|…}}`. A group sends one
/// per member, while WhatsApp's own ticks wait for every member: a group keeps its one tick. The `-self` receipts are
/// your own phone reading incoming messages, which have no ticks.
fn parse_gowa_receipt(json: &Value) -> WebhookEvent {
    let p = &json["payload"];
    let Some(chat) = non_empty(&p["chat_id"]).filter(|c| !jid::is_group(c)) else { return WebhookEvent::Ignored };
    let ids: Vec<String> = crate::connectors::list(&p["ids"]).iter().filter_map(non_empty).collect();
    let Some(kind) = p["receipt_type"].as_str().filter(|t| !t.ends_with("-self")) else { return WebhookEvent::Ignored };
    match Receipt::from_status(kind) {
        Some(status) if status >= Receipt::Delivered && !ids.is_empty() => WebhookEvent::Receipt { ids, chat, status },
        _ => WebhookEvent::Ignored,
    }
}

/// `{"event":"message.ack"|"message.failed","data":{id, messageId, status, chatId?}}`. OpenWA only moves a group
/// message past one tick when WhatsApp itself does.
fn parse_openwa_receipt(json: &Value) -> WebhookEvent {
    let d = &json["data"];
    let (Some(id), Some(status)) =
        (non_empty(&d["messageId"]).or_else(|| non_empty(&d["id"])), d["status"].as_str().and_then(Receipt::from_status))
    else {
        return WebhookEvent::Ignored;
    };
    WebhookEvent::Receipt { ids: vec![id], chat: d["chatId"].as_str().unwrap_or("").to_string(), status }
}

fn parse_gowa(json: &Value, me: Option<&str>) -> WebhookEvent {
    if json["event"] == "message.ack" {
        return parse_gowa_receipt(json);
    }
    let p = &json["payload"];
    let (Some("message"), Some(id), Some(chat)) = (json["event"].as_str(), non_empty(&p["id"]), non_empty(&p["chat_id"])) else {
        return WebhookEvent::Ignored;
    };
    let from = non_empty(&p["from"]).unwrap_or_else(|| chat.clone());
    let text = p["body"].as_str().unwrap_or("").to_string();
    let mine = me.map(str::to_string).or_else(|| non_empty(&json["device_id"]));
    let mut m = Message::new(
        &id,
        &chat,
        &from,
        &non_empty(&p["sender_display_name"]).or_else(|| non_empty(&p["from_name"])).unwrap_or_default(),
        &text,
        rfc3339(&p["timestamp"]).unwrap_or_else(Utc::now),
        p["is_from_me"].as_bool().unwrap_or(false),
    );
    m.media = gowa_media(p);
    m.mentions_me = jid::is_group(&chat) && text_mentions(&text, mine.as_deref());
    WebhookEvent::Message(m)
}

/// GOWA zet elke soort media onder een eigen sleutel; alleen het label telt.
pub fn gowa_media(p: &Value) -> Media {
    let has = |k: &str| !p[k].is_null();
    if has("image") {
        Media::Image
    } else if has("video") || has("video_note") {
        Media::Video
    } else if has("audio") {
        Media::Voice
    } else if has("document") {
        Media::Document { name: non_empty(&p["document"]["filename"]) }
    } else if has("sticker") {
        Media::Sticker
    } else if has("location") || has("live_location") {
        Media::Location
    } else if has("contact") || has("contacts_array") {
        Media::Contact
    } else if has("poll") {
        Media::Other
    } else {
        Media::None
    }
}

fn parse_openwa(json: &Value, me: Option<&str>) -> WebhookEvent {
    let event = json["event"].as_str().unwrap_or("");
    let d = &json["data"];
    if event == "message.ack" || event == "message.failed" {
        return parse_openwa_receipt(json);
    }
    if event != "message.received" && event != "message.sent" {
        return WebhookEvent::Ignored;
    }
    let (Some(id), Some(chat)) = (non_empty(&d["id"]), non_empty(&d["chatId"]).or_else(|| non_empty(&d["from"]))) else {
        return WebhookEvent::Ignored;
    };
    let kind = d["type"].as_str().unwrap_or("text");
    if kind == "revoked" {
        return WebhookEvent::Ignored;
    }
    let from_me = d["fromMe"].as_bool().unwrap_or(event == "message.sent");
    let mut m = Message::new(
        &id,
        &chat,
        &non_empty(&d["author"]).or_else(|| non_empty(&d["from"])).unwrap_or_else(|| chat.clone()),
        &non_empty(&d["contact"]["name"]).or_else(|| non_empty(&d["contact"]["pushName"])).unwrap_or_default(),
        d["body"].as_str().unwrap_or(""),
        epoch(&d["timestamp"]).unwrap_or_else(Utc::now),
        from_me,
    );
    m.media = openwa_media(kind, non_empty(&d["media"]["filename"]));
    let is_group = d["isGroup"].as_bool().unwrap_or_else(|| jid::is_group(&chat));
    if let (true, Some(mine)) = (is_group, me) {
        let ids: Vec<&str> = crate::connectors::list(&d["mentionedIds"]).iter().filter_map(Value::as_str).collect();
        m.mentions_me = ids.iter().any(|i| jid::same_user(i, mine)) || text_mentions(&m.text, Some(mine));
    }
    WebhookEvent::Message(m)
}

/// OpenWA's `type` (text|image|video|audio|voice|document|sticker|location|contact|poll|…).
pub fn openwa_media(kind: &str, filename: Option<String>) -> Media {
    match kind {
        "text" | "" => Media::None,
        "image" => Media::Image,
        "video" => Media::Video,
        "audio" => Media::Audio,
        "voice" => Media::Voice,
        "document" => Media::Document { name: filename },
        "sticker" => Media::Sticker,
        "location" => Media::Location,
        "contact" => Media::Contact,
        _ => Media::Other,
    }
}

/// Files fetched from the gateway: their names on disk, and which kinds Nook will hand to another app.
pub mod files {
    use super::Media;

    /// Larger files are refused: the same cap both gateways use by default.
    pub const MAX_BYTES: usize = 50 * 1024 * 1024;

    /// Extensions Nook opens with the app the system uses for them: documents, pictures, video and sound. Anything
    /// else (a program, a script, a shortcut) is never opened, whatever a message calls itself.
    const OPENABLE: &[&str] = &[
        "pdf", "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "mp4", "m4v", "mov", "webm", "3gp", "mkv", "avi", "ogg", "oga",
        "opus", "mp3", "m4a", "aac", "wav", "amr", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf", "txt", "csv",
        "epub",
    ];

    pub fn extension(name: &str) -> Option<String> {
        let (stem, ext) = name.rsplit_once('.')?;
        (!stem.is_empty() && !ext.is_empty() && ext.len() <= 8).then(|| ext.to_lowercase())
    }

    /// Whether a file of this name may be opened with the system's default app.
    pub fn may_open(name: &str) -> bool {
        extension(name).is_some_and(|e| OPENABLE.contains(&e.as_str()))
    }

    /// The usual extension for a MIME type the gateway names, for the kinds Nook opens.
    pub fn extension_for(mime: &str) -> Option<&'static str> {
        let base = mime.split(';').next().unwrap_or("").trim().to_lowercase();
        Some(match base.as_str() {
            "image/jpeg" | "image/jpg" => "jpg",
            "image/png" => "png",
            "image/gif" => "gif",
            "image/webp" => "webp",
            "image/heic" => "heic",
            "video/mp4" => "mp4",
            "video/quicktime" => "mov",
            "video/webm" => "webm",
            "video/3gpp" => "3gp",
            "audio/ogg" | "audio/ogg; codecs=opus" => "ogg",
            "audio/opus" => "opus",
            "audio/mpeg" => "mp3",
            "audio/mp4" | "audio/m4a" | "audio/x-m4a" => "m4a",
            "audio/aac" => "aac",
            "audio/amr" => "amr",
            "audio/wav" | "audio/x-wav" => "wav",
            "application/pdf" => "pdf",
            "text/plain" => "txt",
            "text/csv" => "csv",
            _ => return None,
        })
    }

    /// A safe file name: the document's own name when there is one, else one after its kind, with an extension the
    /// system recognizes. Never a path: separators, reserved characters and leading dots go.
    pub fn file_name(media: &Media, given: Option<&str>, mime: Option<&str>) -> String {
        let fallback = match media {
            Media::Image => "photo",
            Media::Video => "video",
            Media::Audio | Media::Voice => "voice message",
            Media::Document { .. } => "document",
            _ => "attachment",
        };
        let own = match media {
            Media::Document { name } => name.as_deref().or(given),
            _ => given,
        };
        let cleaned: String = own
            .unwrap_or(fallback)
            .chars()
            .map(|c| if matches!(c, '/' | '\\' | ':' | '<' | '>' | '"' | '|' | '?' | '*') || c.is_control() { '-' } else { c })
            .collect();
        let mut name = cleaned.trim_matches(|c: char| c.is_whitespace() || c == '.').to_string();
        if name.is_empty() {
            name = fallback.into();
        }
        // Windows keeps a few names for devices.
        let stem = name.split('.').next().unwrap_or("").to_uppercase();
        if ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "LPT1", "LPT2", "LPT3"].contains(&stem.as_str()) {
            name = format!("_{name}");
        }
        if extension(&name).is_none() {
            if let Some(ext) = mime.and_then(extension_for) {
                name = format!("{name}.{ext}");
            }
        }
        let count = name.chars().count();
        name.chars().skip(count.saturating_sub(120)).collect()
    }
}

// Tekst voor het brein

/// Een chat op id of nummer, anders op naam: exact, dan een woord ervan, dan een deel. `None` als niets past of twee
/// verschillende chats even goed passen.
pub fn match_recipient(wanted: &str, chats: &[(String, String)]) -> Option<(String, String)> {
    let query = fold(wanted);
    if wanted.contains('@') {
        if let Some(c) = chats.iter().find(|(j, _)| jid::normalized(j) == jid::normalized(wanted)) {
            return Some(c.clone());
        }
    }
    let digits: String = wanted.chars().filter(|c| c.is_ascii_digit()).collect();
    let non_space = wanted.chars().filter(|c| !c.is_whitespace()).count();
    if digits.len() >= 8 && digits.len() * 2 >= non_space {
        let tail = &digits[digits.len().saturating_sub(9)..];
        return chats.iter().find(|(j, _)| jid::digits(j).ends_with(tail)).cloned();
    }
    let unique = |found: Vec<&(String, String)>| -> Option<(String, String)> {
        let ids: HashSet<&String> = found.iter().map(|(j, _)| j).collect();
        (ids.len() == 1).then(|| found[0].clone())
    };
    let exact: Vec<_> = chats.iter().filter(|(_, n)| fold(n) == query).collect();
    if !exact.is_empty() {
        return unique(exact);
    }
    let word: Vec<_> = chats.iter().filter(|(_, n)| fold(n).split(' ').any(|w| w == query)).collect();
    if !word.is_empty() {
        return unique(word);
    }
    if query.chars().count() < 3 {
        return None;
    }
    let partly: Vec<_> = chats.iter().filter(|(_, n)| fold(n).contains(&query)).collect();
    if !partly.is_empty() {
        return unique(partly);
    }
    // Een tikfout: alleen de ene naam die dichtbij ligt, nooit een gok tussen twee.
    let names: Vec<String> = chats.iter().map(|(_, n)| n.clone()).collect();
    let name = fuzzy_best(wanted, &names)?;
    unique(chats.iter().filter(|(_, n)| *n == name).collect())
}

fn fold(text: &str) -> String {
    let lowered: String = text
        .to_lowercase()
        .chars()
        .map(|c| match c {
            'à' | 'á' | 'â' | 'ä' => 'a',
            'è' | 'é' | 'ê' | 'ë' => 'e',
            'ì' | 'í' | 'î' | 'ï' => 'i',
            'ò' | 'ó' | 'ô' | 'ö' => 'o',
            'ù' | 'ú' | 'û' | 'ü' => 'u',
            'ç' => 'c',
            'ñ' => 'n',
            other => other,
        })
        .collect();
    lowered
}

fn fuzzy_best(query: &str, candidates: &[String]) -> Option<String> {
    let norm = |t: &str| fold(t).split(|c: char| !c.is_alphanumeric()).filter(|p| !p.is_empty()).collect::<Vec<_>>().join(" ");
    let wanted = norm(query);
    if wanted.chars().count() < 4 {
        return None;
    }
    let allowed = if wanted.chars().count() >= 7 { 2 } else { 1 };
    let scored: Vec<(String, usize)> =
        candidates.iter().map(|c| (c.clone(), levenshtein(&wanted, &norm(c)))).filter(|(_, d)| *d <= allowed).collect();
    let least = scored.iter().map(|(_, d)| *d).min()?;
    let names: HashSet<String> = scored.into_iter().filter(|(_, d)| *d == least).map(|(n, _)| n).collect();
    (names.len() == 1).then(|| names.into_iter().next().unwrap_or_default())
}

fn levenshtein(a: &str, b: &str) -> usize {
    let (x, y): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    let mut prev: Vec<usize> = (0..=y.len()).collect();
    for i in 1..=x.len() {
        let mut cur = vec![i; y.len() + 1];
        for j in 1..=y.len() {
            cur[j] = (prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + usize::from(x[i - 1] != y[j - 1]));
        }
        prev = cur;
    }
    prev[y.len()]
}

pub fn label(media: &Media) -> Option<String> {
    Some(match media {
        Media::None => return None,
        Media::Image => "[photo]".into(),
        Media::Video => "[video]".into(),
        Media::Audio | Media::Voice => "[voice message]".into(),
        Media::Document { name } => format!("[document{}]", name.as_ref().map(|n| format!(": {n}")).unwrap_or_default()),
        Media::Sticker => "[sticker]".into(),
        Media::Location => "[location]".into(),
        Media::Contact => "[contact]".into(),
        Media::Other => "[attachment]".into(),
    })
}

/// Eén regel per bericht: "2026-10-18 14:02 Lisa: tekst", in de tijdzone `offset`.
pub fn lines_in<Tz: chrono::TimeZone>(messages: &[Message], chat_name: &str, zone: &Tz) -> String
where
    Tz::Offset: std::fmt::Display,
{
    let mut sorted: Vec<&Message> = messages.iter().collect();
    sorted.sort_by_key(|m| m.date);
    sorted
        .iter()
        .map(|m| {
            let who = if m.from_me {
                "Me".to_string()
            } else if m.sender_name.is_empty() {
                chat_name.to_string()
            } else {
                m.sender_name.clone()
            };
            let text = [label(&m.media), (!m.text.is_empty()).then(|| m.text.clone())].into_iter().flatten().collect::<Vec<_>>().join(" ");
            format!("{} {who}: {text}", m.date.with_timezone(zone).format("%Y-%m-%d %H:%M"))
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn lines(messages: &[Message], chat_name: &str) -> String {
    lines_in(messages, chat_name, &chrono::Local)
}

/// De gesprekken met iets nieuws, voor de context en het overzicht.
pub fn overview(conversations: &[&Conversation], limit: usize) -> String {
    conversations
        .iter()
        .take(limit)
        .map(|c| {
            let preview = c
                .messages
                .last()
                .map(|m| {
                    let body = [label(&m.media), (!m.text.is_empty()).then(|| m.text.chars().take(120).collect::<String>())]
                        .into_iter()
                        .flatten()
                        .collect::<Vec<_>>()
                        .join(" ");
                    format!("{}{body}", if m.from_me { "Me: " } else { "" })
                })
                .unwrap_or_default();
            let unread = if c.unread > 0 { format!(" ({} unread)", c.unread) } else { String::new() };
            format!("- {}{}{unread}: {preview}", c.name, if c.is_group { " [group]" } else { "" })
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn msg(id: &str, chat: &str, at: i64, from_me: bool, mention: bool) -> Message {
        let mut m = Message::new(id, chat, chat, "Lisa", "hoi", DateTime::from_timestamp(1_800_000_000 + at, 0).unwrap(), from_me);
        m.mentions_me = mention;
        m
    }

    #[test]
    fn inbox_groups_by_chat_and_counts_unread() {
        let mut inbox = Inbox::default();
        let f = Filters::default();
        assert_eq!(inbox.add(msg("1", "31600000001@s.whatsapp.net", 0, false, false), &f, None, false), Outcome::Notify);
        inbox.add(msg("2", "31600000001@s.whatsapp.net", 5, false, false), &f, None, false);
        inbox.add(msg("3", "31600000002@s.whatsapp.net", 3, false, false), &f, None, false);
        assert_eq!(inbox.conversations.len(), 2);
        assert_eq!(inbox.conversations["31600000001@s.whatsapp.net"].unread, 2);
        assert_eq!(inbox.sorted()[0].id, "31600000001@s.whatsapp.net");
        assert_eq!(inbox.add(msg("2", "31600000001@s.whatsapp.net", 0, false, false), &f, None, false), Outcome::Duplicate);
        assert_eq!(inbox.add(msg("4", "31600000001:7@c.us", 9, false, false), &f, None, false), Outcome::Notify);
        assert_eq!(inbox.conversations.len(), 2);
        assert_eq!(inbox.add(msg("5", "31600000002@s.whatsapp.net", 10, true, false), &f, None, false), Outcome::Quiet);
        assert_eq!(inbox.conversations["31600000002@s.whatsapp.net"].unread, 0);
    }

    #[test]
    fn groups_stay_quiet_unless_they_mention_you() {
        let mut inbox = Inbox::default();
        let group = "120363000000000001@g.us";
        let f = Filters { mute_groups: true, ..Default::default() };
        assert_eq!(inbox.add(msg("g1", group, 0, false, false), &f, None, false), Outcome::Quiet);
        assert!(inbox.visible(&f).is_empty());
        assert_eq!(inbox.add(msg("g2", group, 1, false, true), &f, None, false), Outcome::Notify);
        let mut ignoring = f.clone();
        ignoring.ignored.insert("31600000009@s.whatsapp.net".into());
        assert_eq!(inbox.add(msg("i1", "31600000009@s.whatsapp.net", 0, false, false), &ignoring, None, false), Outcome::Ignored);
    }

    #[test]
    fn history_is_kept_but_never_new() {
        let mut inbox = Inbox::default();
        let f = Filters::default();
        assert_eq!(inbox.add(msg("h1", "1@s.whatsapp.net", 0, false, false), &f, None, true), Outcome::Quiet);
        assert_eq!(inbox.conversations["1@s.whatsapp.net"].unread, 0);
        for i in 0..60 {
            inbox.add(msg(&format!("m{i}"), "1@s.whatsapp.net", i + 1, false, false), &f, None, false);
        }
        assert_eq!(inbox.conversations["1@s.whatsapp.net"].messages.len(), KEEP);
        assert_eq!(inbox.conversations["1@s.whatsapp.net"].messages.last().unwrap().id, "m59");
    }

    #[test]
    fn each_kind_of_chat_has_its_own_rule_and_each_chat_its_own_choice() {
        assert_eq!(jid::kind("31600000001@s.whatsapp.net"), ChatKind::Person);
        assert_eq!(jid::kind("120363000000000001@g.us"), ChatKind::Group);
        assert_eq!(jid::kind("status@broadcast"), ChatKind::Status);
        assert_eq!(jid::kind("120363000000000002@newsletter"), ChatKind::Channel);
        let settings = WhatsAppSettings::default();
        let f = settings.filters();
        assert!(!f.is_quiet("31600000001@s.whatsapp.net", false));
        assert!(f.is_quiet("120363000000000001@g.us", false));
        assert!(!f.is_quiet("120363000000000001@g.us", true), "a mention in a group still reaches you");
        assert!(f.is_quiet("status@broadcast", false));
        assert!(f.is_quiet("1@newsletter", true));

        let mut settings = WhatsAppSettings::default();
        settings.set_mode("120363000000000001@g.us", ChatMode::Loud);
        settings.set_mode("31600000001:4@c.us", ChatMode::Muted);
        let f = settings.filters();
        assert!(!f.is_quiet("120363000000000001@g.us", false));
        assert!(f.is_quiet("31600000001@s.whatsapp.net", false));
        assert_eq!(f.mode("31600000001@s.whatsapp.net"), ChatMode::Muted);
        settings.set_mode("31600000001@s.whatsapp.net", ChatMode::Automatic);
        assert!(!settings.modes.contains_key("31600000001@s.whatsapp.net"));

        let mut inbox = Inbox::default();
        let mut status = msg("s1", "status@broadcast", 0, false, false);
        status.sender_name = "Piet".into();
        assert_eq!(inbox.add(status, &f, None, false), Outcome::Quiet);
        assert_eq!(inbox.conversations["status@broadcast"].name, "Statusupdates");
        assert_eq!(inbox.conversations["status@broadcast"].kind, ChatKind::Status);
        assert!(inbox.visible(&f).is_empty());
        assert_eq!(inbox.add(msg("g1", "120363000000000001@g.us", 1, false, false), &f, None, false), Outcome::Notify);
        assert_eq!(inbox.add(msg("p1", "31600000001@s.whatsapp.net", 2, false, false), &f, None, false), Outcome::Quiet);
        let shown: Vec<&str> = inbox.visible(&f).iter().map(|c| c.id.as_str()).collect();
        assert_eq!(shown, vec!["120363000000000001@g.us"]);
        // Old settings files without the new fields still load.
        let old: WhatsAppSettings = serde_json::from_str(r#"{"enabled":true,"muteGroups":false}"#).unwrap();
        assert!(old.mute_status && old.mute_channels && old.modes.is_empty() && !old.mute_groups);
    }

    #[test]
    fn receipts_move_your_ticks_forward_only() {
        let mut inbox = Inbox::default();
        let f = Filters::default();
        let chat = "31600000001@s.whatsapp.net";
        inbox.add(msg("in", chat, 0, false, false), &f, None, false);
        inbox.add(msg("out", chat, 5, true, false), &f, None, false);
        let ticks = |inbox: &Inbox, id: &str| inbox.conversations[chat].messages.iter().find(|m| m.id == id).and_then(|m| m.receipt);
        assert_eq!(ticks(&inbox, "out"), Some(Receipt::Sent));
        assert_eq!(ticks(&inbox, "in"), None);
        let ids = |id: &str| vec![id.to_string()];
        assert_eq!(inbox.apply_receipt(Receipt::Delivered, &ids("out"), "31600000001@c.us").as_deref(), Some(chat));
        assert_eq!(ticks(&inbox, "out"), Some(Receipt::Delivered));
        assert_eq!(inbox.apply_receipt(Receipt::Read, &ids("out"), chat).as_deref(), Some(chat));
        assert_eq!(inbox.apply_receipt(Receipt::Delivered, &ids("out"), chat), None, "never back");
        assert_eq!(ticks(&inbox, "out"), Some(Receipt::Read));
        assert_eq!(inbox.apply_receipt(Receipt::Read, &ids("in"), chat), None, "their messages have no ticks");
        assert_eq!(ticks(&inbox, "in"), None);
        inbox.add(msg("out2", chat, 6, true, false), &f, None, false);
        assert_eq!(inbox.apply_receipt(Receipt::Delivered, &ids("out2"), "").as_deref(), Some(chat), "found by id");
        // A receipt that beats its own message is kept for it.
        assert_eq!(inbox.apply_receipt(Receipt::Delivered, &ids("early"), chat), None);
        inbox.add(msg("early", chat, 7, true, false), &f, None, false);
        assert_eq!(ticks(&inbox, "early"), Some(Receipt::Delivered));
        // History without a status shows no ticks.
        inbox.add(msg("old", chat, 1, true, false), &f, None, true);
        assert_eq!(ticks(&inbox, "old"), None);
        assert_eq!(Receipt::Read.advanced(Receipt::Failed), Receipt::Failed);
        assert_eq!(Receipt::from_status("retry"), None);
    }

    #[test]
    fn gateway_receipts() {
        let gowa = br#"{"event":"message.ack","device_id":"31699999999@s.whatsapp.net","payload":{"ids":["A1","A2"],"chat_id":"31600000001@s.whatsapp.net","from":"31600000001@s.whatsapp.net","receipt_type":"read"}}"#;
        assert_eq!(
            parse_webhook(GatewayKind::Gowa, gowa, None),
            Some(WebhookEvent::Receipt {
                ids: vec!["A1".into(), "A2".into()],
                chat: "31600000001@s.whatsapp.net".into(),
                status: Receipt::Read
            })
        );
        let own = br#"{"event":"message.ack","payload":{"ids":["A1"],"chat_id":"31600000001@s.whatsapp.net","receipt_type":"read-self"}}"#;
        assert_eq!(parse_webhook(GatewayKind::Gowa, own, None), Some(WebhookEvent::Ignored));
        let group = br#"{"event":"message.ack","payload":{"ids":["A1"],"chat_id":"1203630@g.us","receipt_type":"delivered"}}"#;
        assert_eq!(parse_webhook(GatewayKind::Gowa, group, None), Some(WebhookEvent::Ignored));
        let openwa = br#"{"event":"message.ack","sessionId":"s","data":{"id":"uuid-1","messageId":"B1","status":"delivered","ack":2,"chatId":"31600000001@c.us"}}"#;
        assert_eq!(
            parse_webhook(GatewayKind::Openwa, openwa, None),
            Some(WebhookEvent::Receipt { ids: vec!["B1".into()], chat: "31600000001@c.us".into(), status: Receipt::Delivered })
        );
        let failed = br#"{"event":"message.failed","data":{"messageId":"B2","status":"failed","ack":-1}}"#;
        assert_eq!(
            parse_webhook(GatewayKind::Openwa, failed, None),
            Some(WebhookEvent::Receipt { ids: vec!["B2".into()], chat: String::new(), status: Receipt::Failed })
        );
    }

    #[test]
    fn fetched_files_get_a_safe_name_and_only_safe_kinds_open() {
        let doc = |n: &str| Media::Document { name: Some(n.into()) };
        assert_eq!(files::file_name(&doc("Guard-meting (1).pdf"), None, None), "Guard-meting (1).pdf");
        assert_eq!(files::file_name(&doc("../../evil/x.pdf"), None, None), "-..-evil-x.pdf");
        assert_eq!(files::file_name(&doc("..\\x:y.pdf"), None, None), "-x-y.pdf");
        assert_eq!(files::file_name(&Media::Image, None, Some("image/jpeg")), "photo.jpg");
        assert_eq!(files::file_name(&Media::Voice, None, Some("audio/ogg; codecs=opus")), "voice message.ogg");
        assert_eq!(files::file_name(&doc("con.txt"), None, None), "_con.txt");
        assert_eq!(files::file_name(&doc("   ...  "), None, None), "document");
        assert!(files::file_name(&doc(&format!("{}.pdf", "a".repeat(300))), None, None).chars().count() <= 120);
        assert!(files::may_open("offerte.PDF"));
        assert!(files::may_open("photo.jpg"));
        for bad in ["setup.exe", "run.bat", "x.lnk", "a.desktop", "b.sh", "c.ps1", "pdf", "noext", "x.pdf.exe"] {
            assert!(!files::may_open(bad), "{bad}");
        }
        assert!(Media::Voice.is_openable() && !Media::Voice.is_previewed());
        assert!(!Media::Location.is_openable());
    }

    #[test]
    fn rate_limit() {
        let mut limit = RateLimit::new(2, 60);
        let now = Utc::now();
        assert!(limit.allow(now));
        assert!(limit.allow(now));
        assert!(!limit.allow(now + Duration::seconds(10)));
        assert!(limit.allow(now + Duration::seconds(61)));
    }

    #[test]
    fn only_a_signed_delivery_counts() {
        let body = br#"{"event":"message","device_id":"31611111111@s.whatsapp.net","payload":{"id":"ABC","chat_id":"31622222222@s.whatsapp.net","from":"31622222222@s.whatsapp.net","from_name":"Jan","timestamp":"2026-10-18T12:00:00Z","is_from_me":false,"body":"Kom je vanavond?"}}"#;
        let sig = signature(body, "geheim");
        assert!(sig.starts_with("sha256="));
        let headers = |k: &str| HashMap::from([(k.to_string(), sig.clone())]);
        assert!(verify(GatewayKind::Gowa, &headers("x-hub-signature-256"), body, "geheim"));
        assert!(!verify(GatewayKind::Gowa, &headers("x-hub-signature-256"), body, "anders"));
        assert!(!verify(GatewayKind::Gowa, &HashMap::new(), body, "geheim"));
        assert!(!verify(GatewayKind::Openwa, &headers("x-hub-signature-256"), body, "geheim"));
        let Some(WebhookEvent::Message(parsed)) = parse_webhook(GatewayKind::Gowa, body, None) else { panic!("no message") };
        assert_eq!(
            (parsed.id.as_str(), parsed.sender_name.as_str(), parsed.text.as_str(), parsed.from_me),
            ("ABC", "Jan", "Kom je vanavond?", false)
        );
        assert_eq!(parse_webhook(GatewayKind::Gowa, br#"{"event":"receipt"}"#, None), Some(WebhookEvent::Ignored));
        assert_eq!(parse_webhook(GatewayKind::Gowa, b"geen json", None), None);
    }

    #[test]
    fn hmac_rfc4231() {
        let mut mac = Hmac::<Sha256>::new_from_slice(b"Jefe").unwrap();
        mac.update(b"what do ya want for nothing?");
        assert_eq!(hex(&mac.finalize().into_bytes()), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    }

    #[test]
    fn openwa_delivery() {
        let body = br#"{"event":"message.received","sessionId":"s","data":{"id":"X1","from":"31633333333@c.us","chatId":"31633333333@c.us","body":"","type":"voice","timestamp":1800000000,"fromMe":false,"contact":{"pushName":"Sanne"}}}"#;
        let Some(WebhookEvent::Message(parsed)) = parse_webhook(GatewayKind::Openwa, body, None) else { panic!("no message") };
        assert_eq!(parsed.media, Media::Voice);
        assert_eq!(parsed.sender_name, "Sanne");
    }

    #[test]
    fn the_webhook_request_is_read_whole() {
        let raw = "POST /whatsapp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 4\r\nX-Hub-Signature-256: sha256=ab\r\n\r\n";
        assert_eq!(HttpRequest::parse(format!("{raw}ab").as_bytes(), 1_000_000), Parse::Incomplete);
        let Parse::Done(r) = HttpRequest::parse(format!("{raw}abcd").as_bytes(), 1_000_000) else { panic!("not parsed") };
        assert_eq!(r.path, "/whatsapp");
        assert_eq!(r.headers["x-hub-signature-256"], "sha256=ab");
        assert_eq!(r.body, b"abcd");
        assert_eq!(HttpRequest::parse(b"POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n", 1_000_000), Parse::Invalid);
    }

    #[test]
    fn recipient_by_name_number_or_id() {
        let chats: Vec<(String, String)> = [
            ("31611111111@s.whatsapp.net", "Lisa de Vries"),
            ("31622222222@s.whatsapp.net", "Jan Bakker"),
            ("31633333333@s.whatsapp.net", "Jan Jansen"),
            ("120363000000000001@g.us", "Familie"),
        ]
        .iter()
        .map(|(a, b)| (a.to_string(), b.to_string()))
        .collect();
        let jid = |q: &str| match_recipient(q, &chats).map(|c| c.0);
        assert_eq!(jid("Lisa").as_deref(), Some("31611111111@s.whatsapp.net"));
        assert_eq!(jid("lisa de vries").as_deref(), Some("31611111111@s.whatsapp.net"));
        assert_eq!(jid("familie").as_deref(), Some("120363000000000001@g.us"));
        assert_eq!(jid("06-11111111").as_deref(), Some("31611111111@s.whatsapp.net"));
        assert_eq!(match_recipient("31622222222@c.us", &chats).map(|c| c.1).as_deref(), Some("Jan Bakker"));
        assert_eq!(jid("Jan"), None, "two Jans: ask which one");
        assert_eq!(match_recipient("Bakker", &chats).map(|c| c.1).as_deref(), Some("Jan Bakker"));
        assert_eq!(jid("0698765432"), None, "a number that is not a chat is never sent to");
        assert_eq!(jid("Pieter"), None);
        assert_eq!(jid("Familei").as_deref(), Some("120363000000000001@g.us"), "a typo in one name");
    }

    #[test]
    fn messages_as_text() {
        let mut a = msg("2", "c", 120, true, false);
        a.text = "Top, tot dan".into();
        a.sender_name = String::new();
        let mut b = msg("1", "c", 0, false, false);
        b.text = "Ben om 8 uur bij je".into();
        let text = lines_in(&[a, b], "Lisa", &Utc);
        assert_eq!(text, "2027-01-15 08:00 Lisa: Ben om 8 uur bij je\n2027-01-15 08:02 Me: Top, tot dan");
        let mut voice = msg("3", "c", 0, false, false);
        voice.text = String::new();
        voice.media = Media::Voice;
        assert!(lines_in(&[voice], "Lisa", &Utc).ends_with("Lisa: [voice message]"));
    }
}
