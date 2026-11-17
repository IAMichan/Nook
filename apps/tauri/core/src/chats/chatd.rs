//! Nook's own chat helper, nook-chatd (`apps/chatd`), as chats for the shared inbox: its local `/v1` API and its
//! `/v1/ws` live line (`ChatServiceData`, `ChatServiceBridge` and `ChatLiveStream` on the Mac). Telegram, Signal,
//! Messenger, Instagram, X, LinkedIn and Slack reach the inbox this way. The app (`src-tauri/src/chats/helper.rs`)
//! starts the helper; this module only talks to it and translates.

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
use std::time::Duration;

use async_trait::async_trait;
use chrono::{DateTime, TimeZone, Utc};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};

use super::{BridgedChat, ChatBridge, ChatKind, ChatMedia, InboxMessage, Receipt};

/// The port the helper listens on, on 127.0.0.1 only (the same as on the Mac).
pub const PORT: u16 = 29373;
/// Chats one read lists, and messages it reads per chat that moved.
pub const CHAT_COUNT: usize = 40;
pub const HISTORY: usize = 30;
/// Nook's id of a message from the helper: `nook-<chat>-<message>`.
pub const ID_PREFIX: &str = "nook-";

/// The apps the helper links.
pub const APPS: [&str; 8] = ["whatsapp", "telegram", "signal", "messenger", "instagram", "x", "linkedin", "slack"];
/// The apps whose terms forbid other clients and that do restrict accounts for it: linking them says so first.
pub const RISKY_APPS: [&str; 4] = ["messenger", "instagram", "x", "linkedin"];

/// One chat as `/v1/chats` lists it.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ServiceChat {
    pub id: String,
    /// The app in Nook for its network.
    pub app: String,
    pub title: String,
    pub is_group: bool,
    pub unread: usize,
    pub last: Option<DateTime<Utc>>,
    /// A group's other people by name.
    pub members: Vec<String>,
    /// Your own id in it.
    pub me: Option<String>,
    /// Everyone's name by their id in it.
    pub people: HashMap<String, String>,
    pub is_muted: bool,
    pub account: Option<String>,
}

/// The networks by the words in their name or account id, most specific first.
const NETWORKS: [(&str, &str); 14] = [
    ("whatsapp", "whatsapp"),
    ("instagram", "instagram"),
    ("messenger", "messenger"),
    ("facebook", "messenger"),
    ("telegram", "telegram"),
    ("signal", "signal"),
    ("discord", "discord"),
    ("linkedin", "linkedin"),
    ("twitter", "x"),
    ("slack", "slack"),
    ("teams", "teams"),
    ("imessage", "messages"),
    ("googlechat", "googlechat"),
    ("google chat", "googlechat"),
];

/// The app for a chat's network; `None` for a network Nook has no source for (it is left out).
pub fn app(network: &str, account: &str) -> Option<&'static str> {
    let words = format!("{network} {account}").to_lowercase();
    NETWORKS.iter().find(|(word, _)| words.contains(word)).map(|(_, app)| *app)
}

pub fn message_id(id: &str, chat: &str) -> String {
    format!("{ID_PREFIX}{chat}-{id}")
}

/// The helper's own id of a message Nook knows as [`message_id`].
pub fn network_id(id: &str, chat: &str) -> Option<String> {
    id.strip_prefix(&format!("{ID_PREFIX}{chat}-")).map(str::to_string)
}

/// A time as the helper writes it: RFC 3339, or milliseconds since 1970.
pub fn date(value: &Value) -> Option<DateTime<Utc>> {
    match value {
        Value::String(text) => DateTime::parse_from_rfc3339(text).ok().map(|d| d.with_timezone(&Utc)),
        Value::Number(n) => n.as_i64().and_then(|ms| Utc.timestamp_millis_opt(ms).single()),
        _ => None,
    }
}

fn text(value: &Value) -> Option<String> {
    value.as_str().map(str::trim).filter(|t| !t.is_empty()).map(str::to_string)
}

fn items(json: &Value) -> &[Value] {
    json.get("items").and_then(Value::as_array).map_or(&[], Vec::as_slice)
}

/// The chats of `/v1/chats`, without archived ones, merged ones and those of networks Nook does not know.
pub fn chats(json: &Value) -> Vec<ServiceChat> {
    items(json)
        .iter()
        .filter_map(|chat| {
            let id = chat.get("id")?.as_str()?.to_string();
            if chat.get("isArchived").and_then(Value::as_bool) == Some(true)
                || chat.get("merge").is_some_and(|m| !m.is_null())
                || chat.get("mergedIntoChatID").and_then(Value::as_str).is_some_and(|m| !m.is_empty())
            {
                return None;
            }
            let network = chat.get("network").and_then(Value::as_str).unwrap_or_default();
            let account_id = chat.get("accountID").and_then(Value::as_str).unwrap_or_default();
            let source = app(network, account_id)?;
            let title = text(chat.get("title").unwrap_or(&Value::Null))?;
            let is_group = chat.get("type").and_then(Value::as_str) == Some("group");
            let people = chat.pointer("/participants/items").and_then(Value::as_array).cloned().unwrap_or_default();
            let me = people
                .iter()
                .find(|p| p.get("isSelf").and_then(Value::as_bool) == Some(true))
                .and_then(|p| p.get("id")?.as_str().map(str::to_string));
            let mut names = HashMap::new();
            let mut members = vec![];
            for person in &people {
                let name = text(person.get("fullName").unwrap_or(&Value::Null))
                    .or_else(|| text(person.get("username").unwrap_or(&Value::Null)));
                if let (Some(pid), Some(name)) = (person.get("id").and_then(Value::as_str), &name) {
                    names.insert(pid.to_string(), name.clone());
                }
                if is_group && person.get("isSelf").and_then(Value::as_bool) != Some(true) {
                    members.extend(name);
                }
            }
            let account = text(chat.get("account").unwrap_or(&Value::Null))
                .or_else(|| text(chat.pointer("/user/username").unwrap_or(&Value::Null)));
            Some(ServiceChat {
                id,
                app: source.to_string(),
                title,
                is_group,
                unread: chat.get("unreadCount").and_then(Value::as_u64).unwrap_or(0) as usize,
                last: chat.get("lastActivity").and_then(date),
                members,
                me,
                people: names,
                is_muted: chat.get("isMuted").and_then(Value::as_bool) == Some(true),
                account,
            })
        })
        .collect()
}

/// Whether a message was seen: `true`, a time, or (in a group) by anyone.
fn seen(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Bool(flag)) => *flag,
        Some(Value::String(time)) => !time.is_empty(),
        Some(Value::Object(people)) => people.values().any(|v| seen(Some(v))),
        _ => false,
    }
}

/// How far your message got: its send status, then whether it was delivered or seen.
pub fn receipt(message: &Value) -> Receipt {
    match message.pointer("/sendStatus/status").and_then(Value::as_str) {
        Some("PENDING") => return Receipt::Pending,
        Some("FAIL_RETRIABLE" | "FAIL_PERMANENT") => return Receipt::Failed,
        _ => {}
    }
    if seen(message.get("seen")) {
        return Receipt::Read;
    }
    let delivered = message.pointer("/sendStatus/deliveredToUsers").and_then(Value::as_array).is_some_and(|d| !d.is_empty());
    if delivered {
        Receipt::Delivered
    } else {
        Receipt::Sent
    }
}

/// What an attachment is, by what the helper says of it.
pub fn media(attachment: &Value) -> ChatMedia {
    let name = text(attachment.get("fileName").unwrap_or(&Value::Null));
    let mime = attachment.get("mimeType").and_then(Value::as_str).unwrap_or_default();
    let flag = |key: &str| attachment.get(key).and_then(Value::as_bool) == Some(true);
    if flag("isSticker") {
        return ChatMedia::Sticker;
    }
    if flag("isVoiceNote") {
        return ChatMedia::Voice;
    }
    match (mime.split('/').next().unwrap_or_default(), attachment.get("type").and_then(Value::as_str)) {
        ("image", _) | (_, Some("img")) => ChatMedia::Image,
        ("video", _) | (_, Some("video")) => ChatMedia::Video,
        ("audio", _) | (_, Some("audio")) => ChatMedia::Audio,
        _ => ChatMedia::Document { name },
    }
}

/// What a message without text holds, in words the views show (their own label goes over it where they have one).
fn label(message: &Value) -> String {
    let attachment = message.get("attachments").and_then(Value::as_array).and_then(|a| a.first());
    if let Some(name) = attachment.and_then(|a| text(a.get("fileName").unwrap_or(&Value::Null))) {
        return name;
    }
    match message.get("type").and_then(Value::as_str) {
        Some("STICKER") => "🙂".into(),
        Some("LOCATION") => "📍".into(),
        _ => String::new(),
    }
}

/// The messages of `/v1/chats/{id}/messages`, oldest first, without reactions and hidden ones; a deleted one shows as
/// deleted, an edited one says so.
pub fn messages(json: &Value, chat: &ServiceChat) -> Vec<InboxMessage> {
    let mut list: Vec<InboxMessage> = items(json)
        .iter()
        .filter_map(|message| {
            let id = message.get("id")?.as_str()?;
            let kind = message.get("type").and_then(Value::as_str);
            if kind == Some("REACTION")
                || matches!(kind, Some("MEMBERSHIP" | "GROUP_CHANGE"))
                || message.get("isHidden").and_then(Value::as_bool) == Some(true)
            {
                return None;
            }
            let sent = date(message.get("timestamp")?)?;
            let mine = message.get("isSender").and_then(Value::as_bool) == Some(true);
            let sender_id = (!mine && chat.is_group)
                .then(|| message.get("senderID").and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string))
                .flatten();
            let sender = if mine || !chat.is_group {
                String::new()
            } else {
                message.get("senderName").and_then(Value::as_str).unwrap_or_default().to_string()
            };
            let mut item = InboxMessage::new(message_id(id, &chat.id), String::new(), sent, mine);
            item.sender = sender;
            item.sender_id = sender_id;
            if message.get("isDeleted").and_then(Value::as_bool) == Some(true) {
                return Some(item.withdrawn());
            }
            let attachment = message.get("attachments").and_then(Value::as_array).and_then(|a| a.first());
            item.media = attachment.map(media).unwrap_or_default();
            let mut words = message.get("text").and_then(Value::as_str).unwrap_or_default().trim().to_string();
            if words.is_empty() && item.media.is_none() {
                words = label(message);
            }
            // The helper writes a file's name as the text of a message with only that file.
            if let ChatMedia::Document { name: Some(name) } = &item.media {
                if &words == name {
                    words.clear();
                }
            }
            if words.is_empty() && item.media.is_none() {
                return None;
            }
            item.text = words;
            if mine {
                item.receipt = Some(receipt(message));
            }
            item.edited = message.get("isEdited").and_then(Value::as_bool) == Some(true);
            if !mine && chat.is_group {
                let mentions: Vec<&str> =
                    message.get("mentions").and_then(Value::as_array).map(|m| m.iter().filter_map(Value::as_str).collect()).unwrap_or_default();
                item.mentions_me = chat.me.as_deref().is_some_and(|me| mentions.contains(&me));
            }
            Some(item)
        })
        .collect();
    list.sort_by_key(|m| m.date);
    list
}

/// The messages of a `/messages` answer that were deleted, by their id in Nook.
pub fn deleted(json: &Value, chat: &ServiceChat) -> Vec<String> {
    items(json)
        .iter()
        .filter(|m| m.get("isDeleted").and_then(Value::as_bool) == Some(true))
        .filter_map(|m| m.get("id")?.as_str().map(|id| message_id(id, &chat.id)))
        .collect()
}

/// The helper's ids of the messages in a `/messages` answer.
pub fn item_ids(json: &Value) -> HashSet<String> {
    items(json).iter().filter_map(|m| m.get("id")?.as_str().map(str::to_string)).collect()
}

/// A `/messages` answer with the items of `more` (messages asked by their id) that it lacks.
pub fn adding(more: &Value, to: &Value) -> Value {
    let have = item_ids(to);
    let mut list = items(to).to_vec();
    list.extend(items(more).iter().filter(|m| m.get("id").and_then(Value::as_str).is_some_and(|id| !have.contains(id))).cloned());
    let mut merged = to.clone();
    merged["items"] = Value::Array(list);
    merged
}

/// Whether a chat's messages stop before its newest activity (by more than a second): that message is on its way.
pub fn is_behind(messages: &[InboxMessage], chat: &ServiceChat) -> bool {
    match (chat.last, messages.last()) {
        (Some(last), Some(newest)) => newest.date < last - chrono::Duration::seconds(1),
        _ => false,
    }
}

/// What one event of `/v1/ws` asks for.
#[derive(Debug, Clone, PartialEq)]
pub enum LiveEvent {
    Ready,
    Subscribed,
    /// A chat (by its id there) has something new; with the message when the change is to one message.
    Changed { chat: String, message: Option<String> },
    /// Someone in a chat is typing for `seconds`; 0 says they stopped.
    Typing { chat: String, person: String, name: String, seconds: f64 },
    Other,
}

pub fn event(json: &Value) -> LiveEvent {
    let field = |key: &str| json.get(key).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string);
    match json.get("type").and_then(Value::as_str) {
        Some("ready") => LiveEvent::Ready,
        Some("subscriptions.updated") => LiveEvent::Subscribed,
        Some("chat.upserted" | "chat.deleted" | "message.upserted" | "message.deleted") => match field("chatID") {
            Some(chat) => LiveEvent::Changed { chat, message: field("messageID") },
            None => LiveEvent::Other,
        },
        Some("typing") => match (field("chatID"), field("userID")) {
            (Some(chat), Some(person)) => LiveEvent::Typing {
                chat,
                person,
                name: field("name").unwrap_or_default(),
                seconds: (json.get("timeoutMs").and_then(Value::as_f64).unwrap_or(0.0) / 1000.0).max(0.0),
            },
            _ => LiveEvent::Other,
        },
        _ => LiveEvent::Other,
    }
}

/// What the live line sends once it is ready: every chat's changes.
pub fn subscribe_all() -> Value {
    json!({"type": "subscriptions.set", "chatIDs": ["*"]})
}

/// The helper's local API, behind the token Nook made at its start.
#[derive(Clone)]
pub struct ChatdClient {
    base: String,
    token: String,
    http: reqwest::Client,
}

impl ChatdClient {
    pub fn new(base: impl Into<String>, token: impl Into<String>) -> Self {
        let http = reqwest::Client::builder().timeout(Duration::from_secs(30)).no_proxy().build().unwrap_or_default();
        Self { base: base.into().trim_end_matches('/').to_string(), token: token.into(), http }
    }

    pub fn local(token: impl Into<String>) -> Self {
        Self::new(format!("http://127.0.0.1:{PORT}"), token)
    }

    fn path(chat: &str) -> String {
        format!("/v1/chats/{}", percent_encoding::utf8_percent_encode(chat, percent_encoding::NON_ALPHANUMERIC))
    }

    /// Whether a helper answers at `base`: its info needs no token.
    pub async fn answers(&self) -> bool {
        let url = format!("{}/v1/info", self.base);
        matches!(self.http.get(url).timeout(Duration::from_secs(2)).send().await, Ok(r) if r.status().is_success())
    }

    async fn call(&self, method: reqwest::Method, path: &str, query: &[(&str, String)], body: Option<Value>) -> Result<Value, String> {
        let mut request = self.http.request(method, format!("{}{path}", self.base)).bearer_auth(&self.token).query(query);
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send().await.map_err(|e| e.to_string())?;
        let status = response.status();
        let data = response.bytes().await.map_err(|e| e.to_string())?;
        let json: Value = serde_json::from_slice(&data).unwrap_or(Value::Null);
        if !status.is_success() {
            let reason = ["message", "code"].iter().find_map(|k| text(json.get(*k).unwrap_or(&Value::Null)));
            return Err(reason.unwrap_or_else(|| format!("HTTP {}", status.as_u16())));
        }
        Ok(json)
    }

    pub async fn chats(&self, limit: usize) -> Result<Vec<ServiceChat>, String> {
        Ok(chats(&self.call(reqwest::Method::GET, "/v1/chats", &[("limit", limit.to_string())], None).await?))
    }

    /// A chat's newest messages, or (with `ids`) those messages wherever they are.
    pub async fn messages(&self, chat: &str, limit: usize, ids: &[String]) -> Result<Value, String> {
        let mut query = vec![("limit", limit.to_string())];
        if !ids.is_empty() {
            query = vec![("ids", ids.join(","))];
        }
        self.call(reqwest::Method::GET, &format!("{}/messages", Self::path(chat)), &query, None).await
    }

    /// Sends text; the helper's id of the message on its way.
    pub async fn send(&self, chat: &str, text: &str, reply_to: Option<&str>) -> Result<Option<String>, String> {
        let mut body = json!({"text": text});
        if let Some(reply) = reply_to {
            body["replyToMessageID"] = json!(reply);
        }
        let answer = self.call(reqwest::Method::POST, &format!("{}/messages", Self::path(chat)), &[], Some(body)).await?;
        Ok(answer.get("pendingMessageID").and_then(Value::as_str).map(str::to_string))
    }

    /// Read in the app too.
    pub async fn mark_read(&self, chat: &str) -> Result<(), String> {
        self.call(reqwest::Method::POST, &format!("{}/read", Self::path(chat)), &[], Some(json!({}))).await.map(|_| ())
    }

    /// Unread in the app too.
    pub async fn mark_unread(&self, chat: &str) -> Result<(), String> {
        self.call(reqwest::Method::POST, &format!("{}/unread", Self::path(chat)), &[], Some(json!({}))).await.map(|_| ())
    }

    /// The linked networks and their accounts (`/v1/bridges`).
    pub async fn bridges(&self) -> Result<Value, String> {
        self.call(reqwest::Method::GET, "/v1/bridges", &[], None).await
    }

    /// Opens the live line and hands each event to `on_event` until it drops (an error, a close, or no answer to a
    /// ping within `ping_gap`). Delivery is at most once and nothing is replayed: after a drop, read everything again.
    pub async fn live(&self, ping_gap: Duration, mut on_event: impl FnMut(LiveEvent) + Send) -> Result<(), String> {
        use tokio_tungstenite::tungstenite::{client::IntoClientRequest, Message};
        let url = format!("{}/v1/ws", self.base.replacen("http", "ws", 1));
        let mut request = url.into_client_request().map_err(|e| e.to_string())?;
        let auth = format!("Bearer {}", self.token).parse().map_err(|_| "token".to_string())?;
        request.headers_mut().insert("Authorization", auth);
        let (mut socket, _) = tokio_tungstenite::connect_async(request).await.map_err(|e| e.to_string())?;
        let mut waiting_pong = false;
        loop {
            let next = tokio::time::timeout(ping_gap, socket.next()).await;
            let message = match next {
                Err(_) if waiting_pong => return Err("no answer to ping".into()),
                Err(_) => {
                    socket.send(Message::Ping(Vec::new().into())).await.map_err(|e| e.to_string())?;
                    waiting_pong = true;
                    continue;
                }
                Ok(None) => return Ok(()),
                Ok(Some(Err(e))) => return Err(e.to_string()),
                Ok(Some(Ok(message))) => message,
            };
            waiting_pong = false;
            let data = match message {
                Message::Text(text) => text.as_bytes().to_vec(),
                Message::Binary(data) => data.to_vec(),
                Message::Close(_) => return Ok(()),
                _ => continue,
            };
            let Ok(json) = serde_json::from_slice::<Value>(&data) else { continue };
            let event = event(&json);
            if event == LiveEvent::Ready {
                socket.send(Message::Text(subscribe_all().to_string().into())).await.map_err(|e| e.to_string())?;
            }
            on_event(event);
        }
    }
}

/// What the bridge remembers between reads.
#[derive(Default)]
struct BridgeState {
    /// Each chat's `lastActivity` when it was last read: one that did not move is not read again.
    seen: HashMap<String, Option<DateTime<Utc>>>,
    /// Chats the live line said changed, with the messages it named.
    stale: HashMap<String, HashSet<String>>,
    /// The unread count and mute last reported per chat: a change alone is passed on without reading messages.
    reported_unread: HashMap<String, usize>,
    reported_muted: HashMap<String, bool>,
    /// Chats that moved to a message the answer does not hold yet, and how often they were read again for it.
    behind: HashMap<String, u32>,
    /// What the helper last said of each chat, for a change in a chat past the newest the list brings.
    earlier: HashMap<String, ServiceChat>,
    /// The listed chats by id, for sending and reading by Nook's key.
    chats: HashMap<String, ServiceChat>,
    working: bool,
}

/// The helper as one [`ChatBridge`] for all its apps (`ChatServiceBridge` on the Mac). Its chats are keyed by the
/// helper's own chat id, so two chats of one name never share a row.
pub struct ChatdBridge {
    client: Mutex<Option<ChatdClient>>,
    state: Mutex<BridgeState>,
    /// Apps switched off in Nook: their chats are not read.
    skipped: Mutex<HashSet<String>>,
}

impl Default for ChatdBridge {
    fn default() -> Self {
        Self::new()
    }
}

impl ChatdBridge {
    const BEHIND_RETRIES: u32 = 3;

    pub fn new() -> Self {
        Self { client: Mutex::new(None), state: Mutex::default(), skipped: Mutex::default() }
    }

    fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
        m.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The helper runs (with this client), or stopped (`None`): every chat is read again once it is back.
    pub fn set_client(&self, client: Option<ChatdClient>) {
        *Self::lock(&self.client) = client;
        let mut state = Self::lock(&self.state);
        *state = BridgeState::default();
    }

    pub fn client(&self) -> Option<ChatdClient> {
        Self::lock(&self.client).clone()
    }

    pub fn set_skipped(&self, apps: HashSet<String>) {
        *Self::lock(&self.skipped) = apps;
    }

    /// The live line said a chat changed (with the message, when it named one): it is read at the next turn.
    pub fn changed(&self, chat: &str, message: Option<&str>) {
        let mut state = Self::lock(&self.state);
        let set = state.stale.entry(chat.to_string()).or_default();
        set.extend(message.map(str::to_string));
    }

    /// The live line went down: what changed meanwhile is not told, so every chat is read again.
    pub fn dropped(&self) {
        Self::lock(&self.state).seen.clear();
    }

    /// The helper's chat behind Nook's key for it, for sending and marking read.
    pub fn chat(&self, app: &str, chat_id: &str) -> Option<ServiceChat> {
        Self::lock(&self.state).chats.get(chat_id).filter(|c| c.app == app).cloned()
    }

    /// The listed chats, newest first.
    pub fn chats(&self) -> Vec<ServiceChat> {
        let mut list: Vec<ServiceChat> = Self::lock(&self.state).chats.values().cloned().collect();
        list.sort_by_key(|c| std::cmp::Reverse(c.last));
        list
    }

    fn bridged(chat: &ServiceChat, messages: Vec<InboxMessage>, deleted: Vec<String>, current: bool) -> BridgedChat {
        BridgedChat {
            app: chat.app.clone(),
            name: chat.title.clone(),
            messages,
            unread: current.then_some(chat.unread),
            members: (!chat.members.is_empty()).then(|| chat.members.clone()),
            deleted,
            chat_id: Some(chat.id.clone()),
            account: chat.account.clone(),
            kind: Some(if chat.is_group { ChatKind::Group } else { ChatKind::Person }),
            activity: chat.last,
            muted_in_app: current.then_some(chat.is_muted),
            listed: current,
            ..Default::default()
        }
    }
}

#[async_trait]
impl ChatBridge for ChatdBridge {
    fn app(&self) -> &str {
        "service"
    }

    fn is_ready(&self) -> bool {
        self.client().is_some()
    }

    fn is_working(&self) -> bool {
        Self::lock(&self.state).working
    }

    fn interval(&self) -> Duration {
        Duration::from_secs(10)
    }

    async fn read(&self) -> Result<Vec<BridgedChat>, String> {
        let Some(client) = self.client() else { return Ok(vec![]) };
        let skipped = Self::lock(&self.skipped).clone();
        let listed: Vec<ServiceChat> = match client.chats(CHAT_COUNT).await {
            Ok(list) => list.into_iter().filter(|c| !skipped.contains(&c.app)).collect(),
            Err(error) => {
                Self::lock(&self.state).working = false;
                return Err(error);
            }
        };
        let listed_ids: HashSet<String> = listed.iter().map(|c| c.id.clone()).collect();
        let mut result = vec![];
        // Which chats to read, and what is passed on without reading (a count or mute changed elsewhere).
        let (due, taken) = {
            let mut state = Self::lock(&self.state);
            state.chats = listed.iter().map(|c| (c.id.clone(), c.clone())).collect();
            let moved = |state: &BridgeState, chat: &ServiceChat| {
                state.stale.contains_key(&chat.id) || state.seen.get(&chat.id) != Some(&chat.last)
            };
            for chat in &listed {
                if moved(&state, chat) {
                    continue;
                }
                let reread = state.reported_unread.get(&chat.id).is_some_and(|u| *u != chat.unread);
                let remuted = state.reported_muted.get(&chat.id).is_some_and(|m| *m != chat.is_muted);
                if reread || remuted {
                    state.reported_unread.insert(chat.id.clone(), chat.unread);
                    state.reported_muted.insert(chat.id.clone(), chat.is_muted);
                    let mut bridged = Self::bridged(chat, vec![], vec![], true);
                    if !reread {
                        bridged.unread = None;
                    }
                    result.push(bridged);
                }
            }
            for chat in &listed {
                state.earlier.insert(chat.id.clone(), chat.clone());
            }
            // The chats told to have changed first, then older ones the live line named, then the others that moved.
            let older: Vec<ServiceChat> = state
                .stale
                .keys()
                .filter(|id| !listed_ids.contains(*id))
                .filter_map(|id| state.earlier.get(id).cloned())
                .filter(|c| !skipped.contains(&c.app))
                .collect();
            let mut due: Vec<ServiceChat> = listed.iter().filter(|c| state.stale.contains_key(&c.id)).cloned().collect();
            due.extend(older);
            due.extend(listed.iter().filter(|c| !state.stale.contains_key(&c.id) && moved(&state, c)).cloned());
            let taken: HashMap<String, HashSet<String>> =
                due.iter().filter_map(|c| state.stale.remove(&c.id).map(|m| (c.id.clone(), m))).collect();
            (due, taken)
        };
        let reads = futures_util::future::join_all(due.iter().map(|chat| {
            let client = client.clone();
            let named: Vec<String> = taken.get(&chat.id).map(|m| m.iter().cloned().collect()).unwrap_or_default();
            async move {
                let mut answer = client.messages(&chat.id, HISTORY, &[]).await?;
                let have = item_ids(&answer);
                let missing: Vec<String> = named.into_iter().filter(|m| !have.contains(m)).collect();
                if !missing.is_empty() {
                    if let Ok(again) = client.messages(&chat.id, HISTORY, &missing).await {
                        answer = adding(&again, &answer);
                    }
                }
                Ok::<Value, String>(answer)
            }
        }))
        .await;
        let mut failure = None;
        let mut state = Self::lock(&self.state);
        for (chat, answer) in due.iter().zip(reads) {
            let answer = match answer {
                Ok(answer) => answer,
                Err(error) => {
                    state.stale.entry(chat.id.clone()).or_default();
                    failure = Some(error);
                    continue;
                }
            };
            let messages = messages(&answer, chat);
            let deleted = deleted(&answer, chat);
            // The chat moved to a message the answer does not hold yet: read again at the next turns, a few times.
            if is_behind(&messages, chat) && state.behind.get(&chat.id).copied().unwrap_or(0) < Self::BEHIND_RETRIES {
                *state.behind.entry(chat.id.clone()).or_default() += 1;
                state.stale.entry(chat.id.clone()).or_default();
            } else {
                state.behind.remove(&chat.id);
            }
            state.seen.insert(chat.id.clone(), chat.last);
            let current = listed_ids.contains(&chat.id);
            if current {
                state.reported_unread.insert(chat.id.clone(), chat.unread);
                state.reported_muted.insert(chat.id.clone(), chat.is_muted);
            }
            if messages.is_empty() && deleted.is_empty() && !current {
                continue;
            }
            result.push(Self::bridged(chat, messages, deleted, current));
        }
        if let Some(error) = failure {
            if result.is_empty() {
                state.working = false;
                return Err(error);
            }
        }
        state.working = true;
        Ok(result)
    }

    fn history_changes(&self) -> bool {
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chats::ChatInbox;

    fn list() -> Value {
        json!({"items": [
            {"id": "!a:nook", "network": "Telegram", "accountID": "telegram_1", "title": "Ann", "type": "single",
             "unreadCount": 2, "lastActivity": "2026-11-17T12:05:00Z", "isMuted": true,
             "participants": {"items": [{"id": "@me", "isSelf": true, "fullName": "Me"}, {"id": "@ann", "fullName": "Ann"}]}},
            {"id": "!g:nook", "network": "signal", "accountID": "signal_1", "title": "Team", "type": "group",
             "unreadCount": 0, "lastActivity": 1_794_916_000_000_i64,
             "participants": {"items": [{"id": "@me", "isSelf": true}, {"id": "@bo", "fullName": "Bo"}, {"id": "@cy", "username": "cy"}]}},
            {"id": "!x", "network": "unknownnet", "title": "Nope"},
            {"id": "!arch", "network": "telegram", "title": "Old", "isArchived": true},
            {"id": "!blank", "network": "telegram", "title": "  "}
        ]})
    }

    #[test]
    fn lists_chats_of_known_networks_only() {
        let chats = chats(&list());
        assert_eq!(chats.len(), 2);
        assert_eq!(chats[0].app, "telegram");
        assert_eq!(chats[0].unread, 2);
        assert!(chats[0].is_muted);
        assert_eq!(chats[0].me.as_deref(), Some("@me"));
        assert_eq!(chats[1].app, "signal");
        assert!(chats[1].is_group);
        assert_eq!(chats[1].members, vec!["Bo", "cy"]);
        assert!(chats[1].last.is_some());
        assert_eq!(app("Facebook/Messenger", ""), Some("messenger"));
        assert_eq!(app("", "twitter_1"), Some("x"));
    }

    #[test]
    fn messages_become_inbox_messages() {
        let chat = &chats(&list())[1];
        let answer = json!({"items": [
            {"id": "3", "timestamp": "2026-11-17T12:03:00Z", "text": "later", "isSender": true,
             "sendStatus": {"deliveredToUsers": ["@bo"]}},
            {"id": "1", "timestamp": "2026-11-17T12:01:00Z", "text": "hi @me", "senderID": "@bo", "senderName": "Bo",
             "mentions": ["@me"], "isEdited": true},
            {"id": "2", "timestamp": "2026-11-17T12:02:00Z", "isDeleted": true, "senderID": "@cy", "senderName": "cy"},
            {"id": "r", "timestamp": "2026-11-17T12:02:30Z", "type": "REACTION", "text": "👍"},
            {"id": "f", "timestamp": "2026-11-17T12:04:00Z", "text": "plan.pdf",
             "attachments": [{"fileName": "plan.pdf", "mimeType": "application/pdf"}]},
            {"id": "v", "timestamp": "2026-11-17T12:04:30Z", "attachments": [{"isVoiceNote": true, "mimeType": "audio/ogg"}]}
        ]});
        let list = messages(&answer, chat);
        let ids: Vec<&str> = list.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(ids, vec!["nook-!g:nook-1", "nook-!g:nook-2", "nook-!g:nook-3", "nook-!g:nook-f", "nook-!g:nook-v"]);
        assert_eq!(list[0].sender, "Bo");
        assert_eq!(list[0].sender_id.as_deref(), Some("@bo"));
        assert!(list[0].mentions_me && list[0].edited);
        assert!(list[1].deleted && list[1].text.is_empty());
        assert_eq!(list[2].receipt, Some(Receipt::Delivered));
        assert!(list[2].from_me);
        assert_eq!(list[3].media, ChatMedia::Document { name: Some("plan.pdf".into()) });
        assert!(list[3].text.is_empty(), "a file's name as its text is no text");
        assert_eq!(list[4].media, ChatMedia::Voice);
        assert_eq!(deleted(&answer, chat), vec!["nook-!g:nook-2"]);
        assert_eq!(network_id("nook-!g:nook-1", "!g:nook").as_deref(), Some("1"));
    }

    #[test]
    fn receipts_from_send_status_and_seen() {
        assert_eq!(receipt(&json!({"sendStatus": {"status": "PENDING"}})), Receipt::Pending);
        assert_eq!(receipt(&json!({"sendStatus": {"status": "FAIL_PERMANENT"}})), Receipt::Failed);
        assert_eq!(receipt(&json!({"seen": "2026-11-17T12:00:00Z"})), Receipt::Read);
        assert_eq!(receipt(&json!({"seen": {"@bo": false, "@cy": true}})), Receipt::Read);
        assert_eq!(receipt(&json!({})), Receipt::Sent);
    }

    #[test]
    fn live_events() {
        assert_eq!(event(&json!({"type": "ready"})), LiveEvent::Ready);
        assert_eq!(
            event(&json!({"type": "message.upserted", "chatID": "!a", "messageID": "m1"})),
            LiveEvent::Changed { chat: "!a".into(), message: Some("m1".into()) }
        );
        assert_eq!(event(&json!({"type": "chat.upserted", "chatID": "!a"})), LiveEvent::Changed { chat: "!a".into(), message: None });
        assert_eq!(event(&json!({"type": "chat.upserted"})), LiveEvent::Other);
        assert_eq!(
            event(&json!({"type": "typing", "chatID": "!a", "userID": "@bo", "name": "Bo", "timeoutMs": 5000})),
            LiveEvent::Typing { chat: "!a".into(), person: "@bo".into(), name: "Bo".into(), seconds: 5.0 }
        );
    }

    #[test]
    fn adding_keeps_known_items_once() {
        let a = json!({"items": [{"id": "1"}, {"id": "2"}]});
        let b = json!({"items": [{"id": "2"}, {"id": "0"}]});
        assert_eq!(item_ids(&adding(&b, &a)).len(), 3);
    }

    /// A fake helper on a local port: `/v1/info`, `/v1/chats` and `/v1/chats/{id}/messages`, with the token checked.
    async fn fake_helper(chats: Value, messages: Value) -> String {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else { return };
                let (chats, messages) = (chats.clone(), messages.clone());
                tokio::spawn(async move {
                    let mut buffer = vec![0; 8192];
                    let n = socket.read(&mut buffer).await.unwrap_or(0);
                    let request = String::from_utf8_lossy(&buffer[..n]).to_string();
                    let line = request.lines().next().unwrap_or_default().to_string();
                    let authed = request.to_lowercase().contains("authorization: bearer secret");
                    let (status, body) = if line.contains("/v1/info") {
                        ("200 OK", json!({"app": "nook-chatd"}))
                    } else if !authed {
                        ("401 Unauthorized", json!({"message": "unauthorized"}))
                    } else if line.contains("/messages") {
                        ("200 OK", messages)
                    } else if line.contains("/v1/chats") {
                        ("200 OK", chats)
                    } else {
                        ("404 Not Found", json!({"message": "no"}))
                    };
                    let body = body.to_string();
                    let reply = format!(
                        "HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = socket.write_all(reply.as_bytes()).await;
                });
            }
        });
        base
    }

    #[tokio::test]
    async fn the_bridge_reads_the_helper_into_the_shared_inbox() {
        let answer = json!({"items": [
            {"id": "1", "timestamp": "2026-11-17T12:05:00Z", "text": "hello"}
        ]});
        let base = fake_helper(list(), answer).await;
        assert!(ChatdClient::new(&base, "wrong").answers().await);
        assert_eq!(ChatdClient::new(&base, "wrong").chats(5).await.unwrap_err(), "unauthorized");
        let bridge = ChatdBridge::new();
        assert!(bridge.read().await.unwrap().is_empty(), "without a running helper nothing is read");
        bridge.set_client(Some(ChatdClient::new(&base, "secret")));
        let chats = bridge.read().await.unwrap();
        assert_eq!(chats.len(), 2);
        let mut inbox = ChatInbox::default();
        assert!(inbox.merge_all(chats, Utc::now()));
        let ann = &inbox.threads[&ChatInbox::key("telegram", "!a:nook")];
        assert_eq!(ann.unread, 2, "the app's own count");
        assert_eq!(ann.muted_in_app, Some(true));
        assert_eq!(ann.messages[0].text, "hello");
        // Nothing moved: the next read brings nothing.
        assert!(bridge.read().await.unwrap().is_empty());
        // The live line names a chat: it is read again.
        bridge.changed("!a:nook", Some("1"));
        assert_eq!(bridge.read().await.unwrap().len(), 1);
        assert_eq!(bridge.chat("telegram", "!a:nook").map(|c| c.title), Some("Ann".into()));
    }
}
