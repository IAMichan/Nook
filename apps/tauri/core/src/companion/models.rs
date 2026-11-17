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
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PairingLink {
    pub host: String,
    pub port: u16,
    pub key: Vec<u8>,
    pub mac_name: String,
    /// Other addresses to try (`&a=`, at most `MAX_ALTERNATES`).
    pub alternates: Vec<String>,
    /// The relay the computer keeps a connection to (`&r=`), to reach it from anywhere.
    pub relay: Option<String>,
}

/// Most alternate addresses a code carries, so the QR code stays easy to scan.
pub const MAX_ALTERNATES: usize = 6;

impl PairingLink {
    pub fn url(&self) -> String {
        let mut url = format!(
            "{LINK_SCHEME}://{LINK_HOST}?h={}&p={}&k={}&n={}",
            percent_encode(&self.host),
            self.port,
            base64url_encode(&self.key),
            percent_encode(&self.mac_name)
        );
        for a in self.alternates.iter().take(MAX_ALTERNATES) {
            url.push_str(&format!("&a={}", percent_encode(a)));
        }
        if let Some(r) = &self.relay {
            url.push_str(&format!("&r={}", percent_encode(r)));
        }
        url
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
        // Every `a`, not only the first: the other addresses, each once and never the main one again.
        let mut seen = vec![host.to_lowercase()];
        let mut alternates = Vec::new();
        for part in query.split('&').filter(|p| p.starts_with("a=")) {
            let Some(a) = percent_decode(&part[2..]) else { continue };
            if valid_host(&a) && !seen.contains(&a.to_lowercase()) && alternates.len() < MAX_ALTERNATES {
                seen.push(a.to_lowercase());
                alternates.push(a);
            }
        }
        let relay = get("r").and_then(|r| super::transport::normalize_relay(&r));
        Some(PairingLink { host, port, key, mac_name: if name.is_empty() { "Mac".into() } else { name }, alternates, relay })
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
    /// Keeps the connection open: answered like `list`, then the Mac sends what changed as answers with this request's id
    /// and a growing `seq` (`feature::STREAM`).
    Subscribe,
    /// A sign of life on the open connection, with whether the app is in front (`foreground`).
    Ping,
    /// The session the phone has open (`session`; none when it closed it): its conversation follows over the open
    /// connection as changes after `timelineAfter` (`feature::LIVE_TIMELINE`).
    Watch,
    /// The chat the phone has open in the Chats tab (`item`; none when it closed it): its messages follow by themselves
    /// (`feature::LIVE_CHATS`). Answered like `inboxChat`.
    WatchChat,
    /// The Nook conversation the phone has open (`conversation`; none when it closed it; `item`: its last finished
    /// message, to resume after): answered like `chat`, then Nook's new words follow by themselves
    /// (`feature::LIVE_CONVERSATION`, `messagesConversation`, `messagesAfter`, `messageAppend`).
    WatchConversation,
    /// What a session changed in its folder (`session`; `diff` in the answer, `feature::DIFF`).
    Diff,
    /// Pull requests (`feature::PULL_REQUESTS`): the list (a session's linked ones with `session`), one in full by its
    /// address (`item`), an action on it (`item`, `pullAction`) and a new session that works on it (`pullWork`).
    Pulls,
    Pull,
    PullAct,
    PullWork,
    /// A session's terminals (`terminals` in the answer) and one folder or file of its folder (`item`; `folder`), with
    /// `feature::WORKSPACE`; a piece of a file to preview (`item`, `text`: the offset; `fileChunk`, `feature::FILE_PREVIEW`).
    Terminals,
    Files,
    FileData,
    /// Older sessions a page at a time, and a search through all of them (`text`, `item`: the cursor; `feature::HISTORY`).
    History,
    /// One entry of a conversation in full (`session`, `item`; `entryText`, `feature::FULL_TRANSCRIPT`).
    Entry,
    /// Opens Nook's update panel on the Mac (`feature::REQUEST_UPDATE`); never installs anything.
    RequestUpdate,
    /// The pictures of chats (`items`; `avatars` in the answer, `feature::AVATARS`).
    Avatars,
    /// The phone's own device key (`device_key`, `feature::DEVICE_KEY`): `text` is its public half (X9.63, base64). The
    /// computer keeps the first one it gets for a pairing; `message` in the answer is "bound", or "other" when it already
    /// holds a different one (the phone has to pair again).
    BindKey,
    /// The Chats tab as on the Mac (`feature::CHAT_ACTIONS`, `CompanionChats.swift`): an action in a chat (`item`,
    /// `chatAction`; answered like `inboxChat`, with `inbox`), older messages of a chat (`item`, `text` the oldest message
    /// the phone has; `inboxLines` with `inboxBefore`), the photos of messages (`item`, `items` the messages, at most
    /// `InboxMedia::BATCH`; `inboxMedia`), a chat's info (`item`; `inboxInfo`) and the chats that hold words (`text`;
    /// `inboxFound`).
    InboxAct,
    InboxOlder,
    InboxMedia,
    InboxInfo,
    InboxSearch,
    /// Nook's conversations as on the Mac's Nook tab (`feature::NOOK_CHATS`, `CompanionNookChats.swift`): an action on
    /// one (`conversation`, `nookAction`; answered with `conversations`), and the conversations that hold words (`text`;
    /// `allow` true searches the archive; `conversationsFound`).
    ChatAct,
    ChatSearch,
    /// The computer's notification settings for its phones (`feature::NOTIFY_SETTINGS`, `CompanionNotifySettings`): read
    /// them (`notify` in the answer), and change them for every paired phone (`notify` in the request).
    NotifySettings,
    NotifySet,
}

impl CompanionOp {
    /// The ops the phone side may send through `CompanionClient::call`: everything but pairing and push registration,
    /// which the client does itself.
    pub fn callable(self) -> bool {
        !matches!(self, CompanionOp::Hello | CompanionOp::Register | CompanionOp::Unregister | CompanionOp::Subscribe | CompanionOp::Ping)
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
    pub const STREAM: &str = "stream";
    pub const LIVE_TIMELINE: &str = "liveTimeline";
    pub const LIVE_CHATS: &str = "liveChats";
    pub const LIVE_CONVERSATION: &str = "liveConversation";
    pub const FOREGROUND: &str = "foreground";
    pub const DIFF: &str = "diff";
    pub const PULL_REQUESTS: &str = "pullRequests";
    pub const IMAGES: &str = "images";
    pub const WORKSPACE: &str = "workspace";
    pub const FILE_PREVIEW: &str = "filePreview";
    pub const HISTORY: &str = "history";
    pub const FULL_TRANSCRIPT: &str = "fullTranscript";
    pub const REQUEST_UPDATE: &str = "requestUpdate";
    pub const AVATARS: &str = "avatars";
    pub const APP_ICONS: &str = "appIcons";
    pub const RETRY: &str = "retry";
    pub const ROUTES: &str = "routes";
    pub const RELAY: &str = "relay";
    pub const COMPRESSION: &str = "compression";
    /// The computer takes `bindKey` and from then on wants the phone's requests signed (`device_key`).
    pub const DEVICE_KEY: &str = "deviceKey";
    /// The computer takes files with `send` and `start` (`CompanionRequest::attachments`).
    pub const ATTACHMENTS: &str = "attachments";
    /// The Chats tab does what the Mac's does (`CompanionChats.swift`): `inboxAct`, `inboxOlder`, `inboxMedia`,
    /// `inboxInfo`, `inboxSearch`, pictures and files with `inboxSend`, every list (chats, status, channels) and what each
    /// chat takes (`abilities` on its digest).
    pub const CHAT_ACTIONS: &str = "chatActions";
    /// The Nook tab does what the Mac's does (`CompanionNookChats.swift`): `chatAct`, `chatSearch`, the list's flags on a
    /// conversation's digest, `conversationsArchived`, a question to a busy conversation that waits in line, and
    /// pictures with `ask`.
    pub const NOOK_CHATS: &str = "nookChats";
    /// The Agents tab does what the Mac's does (`CompanionSessions.swift`): more `SessionAction`s, the list's shelves
    /// (`pinned`, `settled`, `snoozedUntil` on a digest), "Always allow" (`decision`), several questions and multi-select
    /// (`questions` on an item, `answers`), the composer's choices (`controls`), the queue (`queued`), and effort, access,
    /// base branch and files for a new session.
    pub const AGENTS_TAB: &str = "agentsTab";
    /// The Pull requests page does what the Mac's does (`CompanionPullRequests.swift`): labels, opened time, comments
    /// and checks on a row, the Summary's side info, the conversation and threads, and the menu's actions (`actions` on
    /// the detail, the new `CompanionPullAction` kinds).
    pub const PULL_ACTIONS: &str = "pullActions";
    /// The computer answers `notifySettings` and takes `notifySet`.
    pub const NOTIFY_SETTINGS: &str = "notifySettings";
    pub const CLOCK: &str = "clock";
    pub const REVOKE: &str = "revoke";
    pub const RESUME: &str = "resume";
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
    /// The reasoning effort ("" the agent's default), the access and the base branch of a new worktree
    /// (`feature::AGENTS_TAB`); none keeps the Mac's choice.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_branch: Option<String>,
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
    /// With `subscribe` and `ping`: the app is in front, so the Mac leaves out pushes the open connection shows.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub foreground: Option<bool>,
    /// Pictures with `send` or `start` (`CompanionImage`: `{ "jpeg": base64 }`, `feature::IMAGES`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub images: Option<Vec<CompanionImage>>,
    /// What `pullAct` does (`CompanionPullAction`), passed through as the interface wrote it; the Mac checks it.
    #[serde(default, rename = "pullAction", skip_serializing_if = "Option::is_none")]
    pub pull_action: Option<serde_json::Value>,
    /// The new session of `pullWork` (`PullWorkRequest`), passed through likewise.
    #[serde(default, rename = "pullWork", skip_serializing_if = "Option::is_none")]
    pub pull_work: Option<serde_json::Value>,
    /// The notification settings `notifySet` changes to (`CompanionNotifySettings`), passed through; the computer checks them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notify: Option<serde_json::Value>,
    /// The chats of `avatars`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub items: Option<Vec<String>>,
    /// This phone opens compressed answers (`CompanionWire`); a Mac without `compression` ignores it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compression: Option<bool>,
    /// Files with `send`, `start` or `inboxSend` (`CompanionFile`, `feature::ATTACHMENTS`, `feature::CHAT_ACTIONS`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attachments: Option<Vec<CompanionFile>>,
    /// What `inboxAct` does in the chat `item`.
    #[serde(default, rename = "chatAction", skip_serializing_if = "Option::is_none")]
    pub chat_action: Option<InboxAction>,
    /// What `chatAct` does to the Nook conversation `conversation` (`NookChatAction`), passed through as the interface
    /// wrote it; the computer checks it.
    #[serde(default, rename = "nookAction", skip_serializing_if = "Option::is_none")]
    pub nook_action: Option<serde_json::Value>,
    /// With `decide` (`feature::AGENTS_TAB`): "always" allows it and what is like it from now on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub decision: Option<String>,
    /// With `answer` (`feature::AGENTS_TAB`): every question's answer by question id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub answers: Option<std::collections::BTreeMap<String, Vec<String>>>,
}

/// Where the computer can be reached (`CompanionEndpoint`), as it says with `hello`, `list` and `subscribe`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CompanionEndpoint {
    pub host: String,
    pub port: u16,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tailnet: Option<bool>,
}

/// A picture that goes with a message (`CompanionImage`): a JPEG of at most `MAX_BYTES`, at most `MAX_COUNT` per message.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CompanionImage {
    pub jpeg: String,
}

impl CompanionImage {
    pub const MAX_BYTES: usize = 90 * 1024;
    pub const MAX_COUNT: usize = 2;

    /// Whether this is a JPEG within the limit, as the Mac checks it.
    pub fn is_valid(&self) -> bool {
        base64::engine::general_purpose::STANDARD
            .decode(&self.jpeg)
            .is_ok_and(|d| d.len() > 3 && d.len() <= Self::MAX_BYTES && d[..3] == [0xFF, 0xD8, 0xFF])
    }
}

/// A file that goes with a message (`CompanionFile`): its name and its bytes in base64, at most `MAX_BYTES`, at most
/// `MAX_COUNT` per message, and with the pictures at most `MAX_TOGETHER`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CompanionFile {
    pub name: String,
    pub data: String,
}

impl CompanionFile {
    pub const MAX_BYTES: usize = 150 * 1024;
    pub const MAX_COUNT: usize = 1;
    pub const MAX_TOGETHER: usize = 180 * 1024;

    /// How many bytes it holds, when it decodes and is within the limit.
    pub fn size(&self) -> Option<usize> {
        let bytes = base64::engine::general_purpose::STANDARD.decode(&self.data).ok()?;
        (!bytes.is_empty() && bytes.len() <= Self::MAX_BYTES && !self.name.trim().is_empty()).then_some(bytes.len())
    }
}

/// What can be done in one chat besides reading it (`InboxAbility`), as the computer lists it per chat in the digest's
/// `abilities`. A name this side does not know (from a newer Mac) is ignored.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum InboxAbility {
    Reply,
    React,
    Edit,
    Delete,
    DeleteForMe,
    MarkReadInApp,
    MarkUnreadInApp,
    PinInApp,
    MuteInApp,
    Archive,
    DeleteChat,
    Vote,
    Photo,
    File,
}

impl InboxAbility {
    /// The abilities in `names`, the unknown ones left out.
    pub fn parse(names: &[String]) -> Vec<InboxAbility> {
        names.iter().filter_map(|n| serde_json::from_value(serde_json::Value::String(n.clone())).ok()).collect()
    }
}

/// What `inboxAct` does (`InboxAction.Kind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum InboxActionKind {
    React,
    Edit,
    Delete,
    DeleteForMe,
    Vote,
    Forward,
    Pin,
    PinInApp,
    MuteInApp,
    Archive,
    DeleteChat,
    Remove,
    MarkReadInNook,
    MarkReadInApp,
    MarkUnread,
}

/// One thing the phone does in a chat of the Chats tab (`InboxAction`), after your own tap.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InboxAction {
    pub kind: InboxActionKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub emoji: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub choices: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub targets: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<bool>,
}

impl InboxAction {
    /// The most chats one message is forwarded to at once, as on the Mac.
    pub const MAX_TARGETS: usize = 10;

    /// Whether the action carries what it needs (`InboxAction.isComplete`); the computer checks again what the app takes.
    pub fn is_complete(&self) -> bool {
        let message = self.message.as_deref().is_some_and(|m| !m.is_empty());
        match self.kind {
            InboxActionKind::React => message && self.emoji.as_deref().is_some_and(|e| !e.is_empty() && e.chars().count() <= 8),
            InboxActionKind::Edit => message && CompanionPolicy::clean_message(self.text.as_deref().unwrap_or("")).is_some(),
            InboxActionKind::Delete | InboxActionKind::DeleteForMe => message,
            InboxActionKind::Vote => message && self.choices.as_ref().is_some_and(|c| c.len() <= 32),
            InboxActionKind::Forward => message && self.targets.as_ref().is_some_and(|t| !t.is_empty() && t.len() <= Self::MAX_TARGETS),
            InboxActionKind::Pin | InboxActionKind::PinInApp | InboxActionKind::MuteInApp => self.value.is_some(),
            InboxActionKind::Archive
            | InboxActionKind::DeleteChat
            | InboxActionKind::Remove
            | InboxActionKind::MarkReadInNook
            | InboxActionKind::MarkReadInApp
            | InboxActionKind::MarkUnread => true,
        }
    }

    /// What the chat's app has to take for this action; none for what Nook does by itself.
    pub fn needs(&self) -> Option<InboxAbility> {
        match self.kind {
            InboxActionKind::React => Some(InboxAbility::React),
            InboxActionKind::Edit => Some(InboxAbility::Edit),
            InboxActionKind::Delete => Some(InboxAbility::Delete),
            InboxActionKind::Vote => Some(InboxAbility::Vote),
            InboxActionKind::PinInApp => Some(InboxAbility::PinInApp),
            InboxActionKind::MuteInApp => Some(InboxAbility::MuteInApp),
            InboxActionKind::Archive => Some(InboxAbility::Archive),
            InboxActionKind::DeleteChat => Some(InboxAbility::DeleteChat),
            InboxActionKind::MarkReadInApp
            | InboxActionKind::DeleteForMe
            | InboxActionKind::Forward
            | InboxActionKind::Pin
            | InboxActionKind::Remove
            | InboxActionKind::MarkReadInNook
            | InboxActionKind::MarkUnread => None,
        }
    }
}

/// A poll in a chat (`InboxPoll`): its question, its options with their votes and whether you chose them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InboxPoll {
    pub question: String,
    pub options: Vec<InboxPollOption>,
    /// More than one option may be chosen.
    pub multiple: bool,
    /// The counts are known.
    pub counted: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InboxPollOption {
    pub text: String,
    pub votes: i64,
    pub chosen: bool,
}

/// One line of a chat's details (`InboxChatInfo.Detail`): `key` says what it is, `value` is as the app says it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InboxChatDetail {
    pub key: String,
    pub value: String,
}

/// What a chat's app says about the chat itself (`InboxChatInfo`, the answer to `inboxInfo`).
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InboxChatInfo {
    pub chat: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub about: Option<String>,
    pub members: Vec<String>,
    pub admins: Vec<String>,
    pub admins_only: bool,
    pub details: Vec<InboxChatDetail>,
    pub blocked: bool,
    pub bot: bool,
    pub verified: bool,
}

/// A photo of a chat message (`InboxMedia`, the answer to `inboxMedia`): `jpeg` in base64, `version` as the line's
/// `thumb` was when it was made.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InboxMedia {
    pub line: String,
    pub version: String,
    pub jpeg: String,
}

impl InboxMedia {
    /// How many photos one `inboxMedia` request asks for.
    pub const BATCH: usize = 3;
}

/// Paging back through a chat on the phone (`InboxPaging`): the computer sends the newest messages that fit, and older
/// pages on request (`inboxOlder`). Lines are the `InboxLine`s as they came (JSON with an `id`).
pub mod inbox_paging {
    use serde_json::Value;

    fn id(line: &Value) -> Option<&str> {
        line.get("id").and_then(Value::as_str)
    }

    /// The phone's messages after the computer sent the newest ones again (`latest`): the older messages the phone paged
    /// back to stay before them, so a new message does not throw away what you scrolled back to read.
    pub fn merge(latest: &[Value], kept: &[Value]) -> Vec<Value> {
        let Some(first) = latest.first().and_then(id) else { return latest.to_vec() };
        match kept.iter().position(|l| id(l) == Some(first)) {
            Some(index) if index > 0 => kept[..index].iter().chain(latest).cloned().collect(),
            _ => latest.to_vec(),
        }
    }

    /// An older page (`page`, the messages before `before`) put before the phone's messages.
    pub fn prepend(page: &[Value], before: &str, kept: &[Value]) -> Vec<Value> {
        let Some(index) = kept.iter().position(|l| id(l) == Some(before)) else { return kept.to_vec() };
        let known: std::collections::HashSet<&str> = kept.iter().filter_map(id).collect();
        page.iter().filter(|l| id(l).is_none_or(|i| !known.contains(i))).chain(&kept[index..]).cloned().collect()
    }
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
            foreground: None,
            images: None,
            pull_action: None,
            pull_work: None,
            notify: None,
            items: None,
            compression: None,
            attachments: None,
            chat_action: None,
            nook_action: None,
            decision: None,
            answers: None,
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
    /// What kind of computer answers (`CompanionPlatform`: "macos", "windows" or "linux"), with `hello`, `list` and
    /// `subscribe`; none from an older Mac. The phone names it and shows its icon by it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
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
    /// The open session's conversation follows after this entry (`TimelineDelta`); none: the conversation whole.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeline_after: Option<String>,
    /// The chat whose messages `inboxLines` holds, on a live update.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inbox_chat: Option<String>,
    /// The Nook conversation `messages` or `messageAppend` belong to, on a live update (`ConversationDelta`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub messages_conversation: Option<String>,
    /// `messages` go after this message; none: they are the conversation whole.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub messages_after: Option<String>,
    /// `ChatAppend`: Nook's new words at the end of its last message, passed through to the interface.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message_append: Option<serde_json::Value>,
    /// The computer's clock with a `stale` refusal, so the phone can correct for its own (`feature::CLOCK`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mac_time: Option<f64>,
    /// The order of the updates on a kept connection.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seq: Option<i64>,
    /// The Mac removed this phone: pair again.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revoked: Option<bool>,
    /// `[DiffFileDigest]`, `[PullDigest]` and `PullDetailDigest`, passed through to the interface.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diff: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pulls: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pull: Option<serde_json::Value>,
    /// The notification settings of `notifySettings` and `notifySet` (`CompanionNotifySettings`), passed through.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notify: Option<serde_json::Value>,
    /// `[TerminalDigest]`, `FolderDigest`, `FileChunk` and `[ChatAvatar]`, passed through to the interface.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminals: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_chunk: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatars: Option<serde_json::Value>,
    /// The next page of `history`, while there are more.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
    /// The page before the oldest entry the phone has (`timeline` with `item`), empty at the start.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeline_before: Option<String>,
    /// One entry in full (`entry`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entry_text: Option<String>,
    /// Where the computer can be reached, and the relay it uses (`feature::ROUTES`, `feature::RELAY`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub endpoints: Option<Vec<CompanionEndpoint>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relay: Option<String>,
    /// With `inboxOlder`: `inboxLines` is the page before this message, not the newest messages.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inbox_before: Option<String>,
    /// The photos of `inboxMedia`; a message without one (any more) is left out.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inbox_media: Option<Vec<InboxMedia>>,
    /// The chat's info of `inboxInfo`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inbox_info: Option<InboxChatInfo>,
    /// The chats `inboxSearch` found, the best first (`[InboxChatDigest]`, passed through to the interface).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inbox_found: Option<serde_json::Value>,
    /// With `inboxChat`, `inboxOlder` and a watched chat: the chat's app may have older messages than these.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inbox_more: Option<bool>,
    /// The Nook conversations `chatSearch` found (`[ChatDigest]`, passed through), and how many wait in the archive.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversations_found: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversations_archived: Option<i64>,
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
    /// "Always allow" is offered (`feature::AGENTS_TAB`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub can_always: Option<bool>,
    /// Every question of a question item (`SessionQuestion`), passed through to the interface.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub questions: Option<serde_json::Value>,
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
    /// Where it sits in the Mac's Agents list (`feature::AGENTS_TAB`): pinned, settled, snoozed until then.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub settled: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub snoozed_until: Option<f64>,
    /// The folder it works in, in full, for "Copy path".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    /// The composer's effort, mode and model (`SessionControls`) and the messages in line (`[QueuedDigest]`), passed
    /// through to the interface.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub controls: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub queued: Option<serde_json::Value>,
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

    /// Forgets `id`, so the same request may come again (it failed in passing).
    pub fn forget(&mut self, id: &str) {
        self.ids.retain(|i| i != id);
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

    /// For a request whose id already has an answer (`CommandReceipts`): it must still be fresh and within the rate,
    /// but being a repeat is the point.
    pub fn admit_retry(&mut self, request: &CompanionRequest, now: f64) -> Option<CompanionError> {
        if (now - request.sent).abs() > FRESHNESS {
            return Some(CompanionError::Stale);
        }
        if !self.rate.admit(now) {
            return Some(CompanionError::RateLimited);
        }
        None
    }

    /// A request that failed in passing may come again with the same id.
    pub fn forget(&mut self, request: &CompanionRequest) {
        self.seen.forget(&request.id);
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
    /// The public half of the phone's device key (X9.63, base64; `device_key`): once set, only requests signed with it
    /// are taken. `None` until the phone bound one (an older app never does).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_key: Option<String>,
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
        let link =
            PairingLink { host: "192.168.1.20".into(), port: 49321, key: key(), mac_name: "Michael’s Mac".into(), ..Default::default() };
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
            effort: None,
            permission: None,
            base_branch: None,
        });
        let json = serde_json::to_value(&r).unwrap();
        assert_eq!(json["protocolVersion"], PROTOCOL_VERSION);
        assert_eq!(json["appVersion"], "1.2.0");
        assert_eq!(json["replyTo"], "m1");
        assert_eq!(json["launch"]["mainThread"], true);
        assert!(json["launch"].get("model").is_none());
        for (op, name) in [
            (CompanionOp::ChatStop, "chatStop"),
            (CompanionOp::InboxChat, "inboxChat"),
            (CompanionOp::Options, "options"),
            (CompanionOp::WatchConversation, "watchConversation"),
        ] {
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
    fn notification_settings_travel_as_the_mac_reads_them() {
        let mut r = CompanionRequest::new(CompanionOp::NotifySet);
        r.notify = Some(serde_json::json!({"enabled": true, "kinds": ["approval"], "onlyWhenAway": true, "includeTitle": false,
                                           "quietAllowsUrgent": true}));
        let json = serde_json::to_value(&r).unwrap();
        assert_eq!(json["op"], "notifySet");
        assert_eq!(json["notify"]["kinds"][0], "approval");
        let read = serde_json::to_value(CompanionRequest::new(CompanionOp::NotifySettings)).unwrap();
        assert_eq!(read["op"], "notifySettings");
        assert!(read.get("notify").is_none());
        let answer: CompanionResponse = serde_json::from_str(r#"{"id":"1","ok":true,"notify":{"enabled":false,"kinds":[]}}"#).unwrap();
        assert_eq!(answer.notify.unwrap()["enabled"], false);
    }

    #[test]
    fn pictures_and_pull_requests_travel_as_the_mac_reads_them() {
        use base64::Engine;
        let jpeg = |n: usize| {
            let mut d = vec![0xFF, 0xD8, 0xFF];
            d.resize(n, 0);
            CompanionImage { jpeg: base64::engine::general_purpose::STANDARD.encode(d) }
        };
        assert!(jpeg(1000).is_valid());
        assert!(!jpeg(CompanionImage::MAX_BYTES + 1).is_valid());
        assert!(!CompanionImage { jpeg: base64::engine::general_purpose::STANDARD.encode(b"PNG....") }.is_valid());
        let mut r = CompanionRequest::new(CompanionOp::PullAct);
        r.item = Some("https://github.com/o/r/pull/1".into());
        r.pull_action = Some(serde_json::json!({"kind": "approve", "head": "abc"}));
        let json = serde_json::to_value(&r).unwrap();
        assert_eq!(json["op"], "pullAct");
        assert_eq!(json["pullAction"]["kind"], "approve");
        assert!(json.get("images").is_none());
    }

    #[test]
    fn nook_chat_actions_travel_as_the_mac_reads_them() {
        assert_eq!(serde_json::to_value(CompanionOp::ChatAct).unwrap(), "chatAct");
        assert_eq!(serde_json::to_value(CompanionOp::ChatSearch).unwrap(), "chatSearch");
        assert!(CompanionOp::ChatAct.callable() && CompanionOp::ChatSearch.callable());
        let mut r = CompanionRequest::new(CompanionOp::ChatAct);
        r.conversation = Some("C1".into());
        r.nook_action = Some(serde_json::json!({"kind": "pin", "value": true}));
        let json = serde_json::to_value(&r).unwrap();
        assert_eq!(json["nookAction"]["kind"], "pin");
        let answer: CompanionResponse =
            serde_json::from_value(serde_json::json!({"id": "A", "ok": true, "conversationsFound": [], "conversationsArchived": 3})).unwrap();
        assert_eq!(answer.conversations_archived, Some(3));
        assert!(answer.conversations_found.is_some());
    }

    #[test]
    fn chat_actions_travel_as_the_mac_reads_them() {
        assert_eq!(serde_json::to_value(CompanionOp::InboxAct).unwrap(), "inboxAct");
        assert_eq!(serde_json::to_value(CompanionOp::InboxSearch).unwrap(), "inboxSearch");
        assert!(CompanionOp::InboxOlder.callable() && CompanionOp::InboxMedia.callable() && CompanionOp::InboxInfo.callable());
        let mut r = CompanionRequest::new(CompanionOp::InboxAct);
        r.item = Some("wa:1".into());
        r.chat_action = Some(InboxAction {
            kind: InboxActionKind::DeleteForMe,
            message: Some("m1".into()),
            emoji: None,
            text: None,
            choices: None,
            targets: None,
            value: None,
        });
        r.attachments = Some(vec![CompanionFile { name: "a.pdf".into(), data: "AAEC".into() }]);
        let json = serde_json::to_value(&r).unwrap();
        assert_eq!(json["chatAction"], serde_json::json!({"kind": "deleteForMe", "message": "m1"}));
        assert_eq!(json["attachments"][0]["name"], "a.pdf");
        assert_eq!(serde_json::from_value::<CompanionRequest>(json).unwrap(), r);
        // Every kind has the Mac's name.
        for (kind, name) in [
            (InboxActionKind::MarkReadInNook, "markReadInNook"),
            (InboxActionKind::PinInApp, "pinInApp"),
            (InboxActionKind::MuteInApp, "muteInApp"),
            (InboxActionKind::DeleteChat, "deleteChat"),
            (InboxActionKind::MarkUnread, "markUnread"),
        ] {
            assert_eq!(serde_json::to_value(kind).unwrap(), name);
        }
        assert_eq!(
            InboxAbility::parse(&["react".into(), "deleteForMe".into(), "teleport".into(), "markUnreadInApp".into()]),
            vec![InboxAbility::React, InboxAbility::DeleteForMe, InboxAbility::MarkUnreadInApp]
        );
    }

    #[test]
    fn chat_actions_say_whether_they_are_complete() {
        let action = |kind, message: Option<&str>| InboxAction {
            kind,
            message: message.map(Into::into),
            emoji: None,
            text: None,
            choices: None,
            targets: None,
            value: None,
        };
        let mut react = action(InboxActionKind::React, Some("m"));
        assert!(!react.is_complete());
        react.emoji = Some("👍".into());
        assert!(react.is_complete() && react.needs() == Some(InboxAbility::React));
        let mut edit = action(InboxActionKind::Edit, Some("m"));
        edit.text = Some("  ".into());
        assert!(!edit.is_complete());
        edit.text = Some("fixed".into());
        assert!(edit.is_complete());
        let mut forward = action(InboxActionKind::Forward, Some("m"));
        forward.targets = Some((0..11).map(|i| i.to_string()).collect());
        assert!(!forward.is_complete());
        forward.targets = Some(vec!["a".into()]);
        assert!(forward.is_complete() && forward.needs().is_none());
        let mut vote = action(InboxActionKind::Vote, Some("m"));
        assert!(!vote.is_complete());
        vote.choices = Some(vec![]);
        assert!(vote.is_complete(), "an empty choice takes the vote back");
        assert!(!action(InboxActionKind::Pin, None).is_complete());
        assert!(action(InboxActionKind::Archive, None).is_complete());
        assert!(!action(InboxActionKind::Delete, None).is_complete());
    }

    #[test]
    fn chat_answers_read_like_swift_writes_them() {
        let json = r#"{"id":"A","ok":true,"inboxBefore":"m5","inboxMore":true,
            "inboxMedia":[{"line":"m1","version":"v2","jpeg":"\/9j\/"}],
            "inboxInfo":{"chat":"wa:1","members":["Ann","Bob"],"admins":["Ann"],"adminsOnly":false,
                "details":[{"key":"phone","value":"+31"}],"blocked":false,"bot":false,"verified":true},
            "inboxFound":[{"id":"wa:1","app":"whatsapp","appName":"WhatsApp","name":"Ann","preview":"hi","last":1,
                "unread":0,"canSend":true,"waitsInApp":false,"abilities":["react"],"kind":"chats","pinned":true}],
            "inboxLines":[{"id":"m1","text":"","date":1,"sender":"Ann","fromMe":false,"reactions":[],"media":"photo",
                "thumb":"v2","poll":{"question":"Q","options":[{"text":"a","votes":2,"chosen":true}],"multiple":false,"counted":true}}]}"#;
        let r: CompanionResponse = serde_json::from_str(json).unwrap();
        assert_eq!(r.inbox_before.as_deref(), Some("m5"));
        assert_eq!(r.inbox_more, Some(true));
        assert_eq!(r.inbox_media.as_ref().unwrap()[0], InboxMedia { line: "m1".into(), version: "v2".into(), jpeg: "/9j/".into() });
        let info = r.inbox_info.clone().unwrap();
        assert!(info.about.is_none() && info.verified && info.details[0].key == "phone");
        assert_eq!(r.inbox_found.as_ref().unwrap()[0]["abilities"][0], "react");
        let poll: InboxPoll = serde_json::from_value(r.inbox_lines.as_ref().unwrap()[0]["poll"].clone()).unwrap();
        assert_eq!(poll.options[0], InboxPollOption { text: "a".into(), votes: 2, chosen: true });
        // What is nil stays out, as Swift leaves it out.
        let back = serde_json::to_value(&info).unwrap();
        assert!(back.get("about").is_none());
        assert_eq!(back["adminsOnly"], false);
        let plain = serde_json::to_value(CompanionResponse::success("x")).unwrap();
        for key in ["inboxBefore", "inboxMedia", "inboxInfo", "inboxFound", "inboxMore"] {
            assert!(plain.get(key).is_none(), "{key}");
        }
    }

    #[test]
    fn files_stay_within_what_the_mac_takes() {
        use base64::Engine;
        let file = |n: usize| CompanionFile { name: "a.txt".into(), data: base64::engine::general_purpose::STANDARD.encode(vec![1u8; n]) };
        assert_eq!(file(10).size(), Some(10));
        assert_eq!(file(CompanionFile::MAX_BYTES + 1).size(), None);
        assert_eq!(file(0).size(), None);
        assert_eq!(CompanionFile { name: " ".into(), data: "AA==".into() }.size(), None);
        assert_eq!(CompanionFile { name: "a".into(), data: "not base64!".into() }.size(), None);
    }

    #[test]
    fn paging_keeps_what_you_scrolled_back_to() {
        use serde_json::json;
        let lines = |ids: &[&str]| ids.iter().map(|i| json!({ "id": i })).collect::<Vec<_>>();
        let ids = |v: Vec<serde_json::Value>| v.iter().map(|l| l["id"].as_str().unwrap().to_string()).collect::<Vec<_>>();
        // Paged back to 1..6; the newest come again from 4 with a new 7: 1..3 stay before them.
        let kept = lines(&["1", "2", "3", "4", "5", "6"]);
        assert_eq!(ids(inbox_paging::merge(&lines(&["4", "5", "6", "7"]), &kept)), ["1", "2", "3", "4", "5", "6", "7"]);
        // No overlap, or the same start: the newest only.
        assert_eq!(ids(inbox_paging::merge(&lines(&["8", "9"]), &kept)), ["8", "9"]);
        assert_eq!(ids(inbox_paging::merge(&lines(&["1", "2"]), &kept)), ["1", "2"]);
        assert!(inbox_paging::merge(&[], &kept).is_empty());
        // An older page goes before the message it was asked before, without doubles.
        let kept = lines(&["4", "5"]);
        assert_eq!(ids(inbox_paging::prepend(&lines(&["1", "2", "4"]), "4", &kept)), ["1", "2", "4", "5"]);
        assert_eq!(ids(inbox_paging::prepend(&lines(&["1"]), "9", &kept)), ["4", "5"]);
        // A page asked before a later message drops what came before it.
        assert_eq!(ids(inbox_paging::prepend(&lines(&["3"]), "5", &kept)), ["3", "5"]);
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
