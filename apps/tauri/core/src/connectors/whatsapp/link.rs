//! WhatsApp live: Nook praat met de lokale koppeling van de gebruiker (GOWA, die Nook op de desktop kan starten, of
//! OpenWA), krijgt nieuwe berichten op een webhook op 127.0.0.1 (en kijkt zelf als die niet komt), en houdt de
//! gesprekken alleen in het geheugen: niets van een bericht gaat naar schijf of een logboek, en alles is weg als Nook
//! stopt of WhatsApp uitgaat. Versturen kan alleen naar chats op de telefoon, hooguit zes per minuut, en alleen na
//! Uitvoeren of nadat de gebruiker zelf antwoordde.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use base64::Engine;
use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

use super::provider::{ChatInfo, LinkState, Provider, WaError};
use super::{
    files, jid, match_recipient, overview, parse_webhook, verify, ChatKind, ChatMode, Conversation, HttpRequest, Inbox, Message, Outcome,
    Parse, RateLimit, WebhookEvent, WhatsAppSettings, CREDENTIAL_ACCOUNT, KEEP, MAX_LENGTH, SECRET_ACCOUNT, WEBHOOK_PATH,
};
use crate::brain::LoopTool;
use crate::connectors::hub::{Connector, Env, Scope};
use crate::connectors::{CResult, ConnectorError, ConnectorItem, ConnectorState, ConnectorStatus, ErrorKind, Tone};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind", content = "message")]
pub enum Link {
    Off,
    Connecting,
    /// De koppeling draait, WhatsApp is nog niet gekoppeld: de QR staat in de instellingen.
    NeedsQr,
    Connected,
    Unreachable,
    Unauthorized,
    Failed(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind", content = "message")]
pub enum Webhook {
    Off,
    Listening,
    Registered,
    PortBusy,
    Refused(String),
}

/// Een nieuw bericht dat de gebruiker moet zien (geen stille groep, niet van jezelf).
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Arrived {
    pub chat: String,
    pub name: String,
    pub preview: String,
    pub unread: usize,
}

/// One chat in Settings › WhatsApp › Per chat: its kind, its choice, and whether it is hidden.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsChat {
    pub jid: String,
    pub name: String,
    pub kind: ChatKind,
    pub mode: ChatMode,
    pub hidden: bool,
}

/// How many of a chat's newest photos, videos and documents its card fetches to show.
pub const PREVIEW_COUNT: usize = 6;
/// How many fetched files stay at most; the oldest go first, from memory and from disk.
pub const PREVIEW_LIMIT: usize = 48;
/// How long a preview that failed waits before it is tried again.
const PREVIEW_RETRY: Duration = Duration::from_secs(60);

/// Hoe het ervoor staat, voor de instellingen.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LinkView {
    pub link: Link,
    pub webhook: Webhook,
    pub status_line: String,
    pub webhook_line: String,
    /// De QR als data-URL, zolang er een te scannen is.
    pub qr: Option<String>,
    pub me: Option<String>,
    pub unread: usize,
    pub hidden_chats: usize,
    pub gowa_running: bool,
}

#[derive(Default)]
struct Inner {
    provider: Option<Arc<Provider>>,
    inbox: Inbox,
    link: Option<Link>,
    webhook: Option<Webhook>,
    qr: Option<Vec<u8>>,
    qr_expiry: Option<DateTime<Utc>>,
    me: Option<String>,
    known: Vec<ChatInfo>,
    generation: u64,
    backfilled: bool,
    last_webhook: Option<DateTime<Utc>>,
    last_poll: Option<DateTime<Utc>>,
    last_chat_list: Option<DateTime<Utc>>,
    naming: HashSet<String>,
    rate: Option<RateLimit>,
    failures: u32,
    tick: u64,
    refreshing: bool,
    polling: bool,
    /// Chats whose older messages were fetched for the card: once per chat while linked.
    history_loaded: HashSet<String>,
    /// Files the card shows or the user opened, by message id (oldest first in `preview_order`).
    previews: HashMap<String, PathBuf>,
    preview_order: VecDeque<String>,
    previews_loading: HashSet<String>,
    preview_failed: HashMap<String, Instant>,
}

/// Een chat die bij een zoekvraag past: id, naam en de berichten die passen.
type Found = (String, String, Vec<Message>);
type ArrivedFn = Arc<dyn Fn(Arrived) + Send + Sync>;
type ChangedFn = Arc<dyn Fn() + Send + Sync>;
type ReceiptFn = Arc<dyn Fn(String) + Send + Sync>;

pub struct WhatsAppLink {
    env: Arc<Env>,
    inner: Mutex<Inner>,
    tasks: Mutex<Vec<tokio::task::JoinHandle<()>>>,
    gowa: Mutex<Gowa>,
    /// Alleen op de desktop mag Nook GOWA zelf starten.
    desktop: bool,
    on_arrived: Mutex<Option<ArrivedFn>>,
    on_changed: Mutex<Option<ChangedFn>>,
    on_receipt: Mutex<Option<ReceiptFn>>,
    /// Where fetched files wait for the app that shows them: a folder of Nook's own in its data directory, emptied
    /// when Nook starts, when WhatsApp stops and when Nook quits.
    files_dir: Mutex<PathBuf>,
}

#[derive(Default)]
struct Gowa {
    child: Option<std::process::Child>,
    signature: Option<String>,
    last_start: Option<std::time::Instant>,
}

impl WhatsAppLink {
    pub fn new(env: Arc<Env>, desktop: bool) -> Arc<Self> {
        Arc::new(Self {
            env,
            inner: Mutex::default(),
            tasks: Mutex::default(),
            gowa: Mutex::default(),
            desktop,
            on_arrived: Mutex::default(),
            on_changed: Mutex::default(),
            on_receipt: Mutex::default(),
            files_dir: Mutex::new(crate::paths::support_directory().join("WhatsApp files")),
        })
    }

    /// Your own messages in a chat got new ticks (delivered, read).
    pub fn on_receipt(&self, f: impl Fn(String) + Send + Sync + 'static) {
        *self.on_receipt.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::new(f));
    }

    /// Another folder for fetched files (tests).
    pub fn set_files_dir(&self, dir: PathBuf) {
        *self.files_dir.lock().unwrap_or_else(|e| e.into_inner()) = dir;
    }

    pub fn files_dir(&self) -> PathBuf {
        self.files_dir.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Removes every fetched file.
    pub fn clear_files(&self) {
        let _ = std::fs::remove_dir_all(self.files_dir());
    }

    pub fn on_arrived(&self, f: impl Fn(Arrived) + Send + Sync + 'static) {
        *self.on_arrived.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::new(f));
    }

    pub fn on_changed(&self, f: impl Fn() + Send + Sync + 'static) {
        *self.on_changed.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::new(f));
    }

    fn changed(&self) {
        let f = self.on_changed.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if let Some(f) = f {
            f();
        }
    }

    fn with<T>(&self, f: impl FnOnce(&mut Inner) -> T) -> T {
        f(&mut self.inner.lock().unwrap_or_else(|e| e.into_inner()))
    }

    pub fn settings(&self) -> WhatsAppSettings {
        self.env.store.read(|c| c.whatsapp.clone())
    }

    pub fn update_settings(self: &Arc<Self>, f: impl FnOnce(&mut WhatsAppSettings)) {
        self.env.store.update(|c| f(&mut c.whatsapp));
        self.settings_changed();
    }

    /// GOWA: `user:pass` voor basic auth. OpenWA: de API-sleutel.
    pub fn set_credential(self: &Arc<Self>, value: &str) -> CResult<()> {
        self.env.secrets.write(CREDENTIAL_ACCOUNT, value).map_err(ConnectorError::new)?;
        self.settings_changed();
        Ok(())
    }

    pub fn has_credential(&self) -> bool {
        self.env.secret(CREDENTIAL_ACCOUNT).is_some()
    }

    /// Het geheim van de webhook, één keer gemaakt (willekeurig, 64 hex-tekens).
    fn webhook_secret(&self) -> String {
        if let Some(s) = self.env.secret(SECRET_ACCOUNT).filter(|s| s.len() >= 16) {
            return s;
        }
        let mut bytes = [0u8; 32];
        rand::Rng::fill(&mut rand::rngs::OsRng, &mut bytes[..]);
        let secret = super::hex(&bytes);
        let _ = self.env.secrets.write(SECRET_ACCOUNT, &secret);
        secret
    }

    fn make_provider(&self) -> Option<Provider> {
        let s = self.settings();
        Provider::new(s.gateway, &s.address(), self.env.secret(CREDENTIAL_ACCOUNT).as_deref())
    }

    pub fn is_connected(&self) -> bool {
        self.with(|i| i.link == Some(Link::Connected))
    }

    fn link(&self) -> Link {
        self.with(|i| i.link.clone().unwrap_or(Link::Off))
    }

    /// Eén keer bij de start.
    pub fn start(self: &Arc<Self>) {
        self.clear_files();
        self.update();
    }

    /// Instellingen veranderd (aan/uit, koppeling, adres, wachtwoord, poort): opnieuw beginnen.
    pub fn settings_changed(self: &Arc<Self>) {
        let enabled = self.settings().enabled;
        self.stop(!enabled);
        self.update();
        self.changed();
    }

    fn update(self: &Arc<Self>) {
        let enabled = self.settings().enabled;
        let running = self.with(|i| i.provider.is_some());
        if enabled && !running {
            self.begin();
        } else if !enabled && running {
            self.stop(true);
        }
    }

    fn begin(self: &Arc<Self>) {
        let Some(provider) = self.make_provider() else {
            self.with(|i| i.link = Some(Link::Failed("Het adres van de WhatsApp-koppeling klopt niet. Kijk bij Geavanceerd.".into())));
            return;
        };
        let kind = provider.kind;
        self.with(|i| {
            i.provider = Some(Arc::new(provider));
            i.generation += 1;
            i.link = Some(Link::Connecting);
            i.rate = Some(RateLimit::new(6, 60));
        });
        self.start_listener(kind);
        self.sync_gowa();
        let me = Arc::downgrade(self);
        let timer = tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(5)).await;
                let Some(link) = me.upgrade() else { break };
                link.on_tick();
            }
        });
        self.tasks.lock().unwrap_or_else(|e| e.into_inner()).push(timer);
        self.refresh();
    }

    fn stop(&self, forget: bool) {
        for task in self.tasks.lock().unwrap_or_else(|e| e.into_inner()).drain(..) {
            task.abort();
        }
        self.with(|i| {
            i.generation += 1;
            i.refreshing = false;
            i.polling = false;
            i.provider = None;
            i.link = None;
            i.webhook = None;
            i.qr = None;
            i.me = None;
            i.backfilled = false;
            i.last_webhook = None;
            i.naming.clear();
            i.failures = 0;
            i.history_loaded.clear();
            i.previews.clear();
            i.preview_order.clear();
            i.previews_loading.clear();
            i.preview_failed.clear();
            if forget {
                i.inbox.clear();
                i.known.clear();
            }
        });
        self.clear_files();
        if !self.settings().enabled {
            self.stop_gowa();
        }
    }

    fn on_tick(self: &Arc<Self>) {
        let (tick, connected, failures) = self.with(|i| {
            i.tick += 1;
            (i.tick, i.link == Some(Link::Connected), i.failures)
        });
        if !connected {
            // Elke 5 s tijdens het koppelen; elke 30 s als de koppeling al een minuut weg is.
            if failures > 12 && tick % 6 != 0 {
                return;
            }
            self.refresh();
        } else {
            if tick % 12 == 0 {
                self.refresh();
            }
            if tick % 4 == 0 {
                self.poll();
            }
        }
    }

    // Status en QR

    pub fn refresh(self: &Arc<Self>) {
        let Some((provider, gen)) = self.with(|i| {
            if i.refreshing {
                return None;
            }
            i.refreshing = true;
            i.provider.clone().map(|p| (p, i.generation))
        }) else {
            return;
        };
        let me = self.clone();
        tokio::spawn(async move {
            me.refresh_with(provider, gen).await;
            me.with(|i| {
                if i.generation == gen {
                    i.refreshing = false;
                }
            });
            me.changed();
        });
    }

    async fn refresh_with(self: &Arc<Self>, provider: Arc<Provider>, gen: u64) {
        let current = |me: &Self| me.with(|i| i.generation == gen);
        match provider.status().await {
            Ok(status) => {
                if !current(self) {
                    return;
                }
                self.with(|i| {
                    i.failures = 0;
                    i.me = status.me.clone();
                });
                match status.link {
                    LinkState::Connected => {
                        let (listening, backfilled, stale_chats) = self.with(|i| {
                            if i.link != Some(Link::Connected) {
                                i.qr = None;
                            }
                            i.link = Some(Link::Connected);
                            (
                                i.webhook == Some(Webhook::Listening),
                                i.backfilled,
                                i.last_chat_list.map(|t| (Utc::now() - t).num_seconds() > 300).unwrap_or(true),
                            )
                        });
                        if listening {
                            self.register(&provider, gen).await;
                        }
                        if !backfilled && current(self) {
                            self.backfill(&provider, gen).await;
                        }
                        if stale_chats {
                            self.load_chats(&provider, gen).await;
                        }
                    }
                    LinkState::NeedsQr => {
                        let ask = self.with(|i| {
                            i.link = Some(Link::NeedsQr);
                            let due = i.qr.is_none() || i.qr_expiry.map(|e| Utc::now() > e).unwrap_or(true);
                            if due {
                                // 15 s niet opnieuw vragen, ook als er niets kwam: elke GOWA-login herstart het koppelen.
                                i.qr_expiry = Some(Utc::now() + chrono::Duration::seconds(15));
                            }
                            due
                        });
                        if ask {
                            if let Ok(Some((png, seconds))) = provider.qr_code().await {
                                self.with(|i| {
                                    if i.generation == gen {
                                        i.qr = Some(png);
                                        i.qr_expiry = Some(Utc::now() + chrono::Duration::seconds(seconds as i64));
                                    }
                                });
                            }
                        }
                    }
                    LinkState::Connecting => self.with(|i| i.link = Some(Link::Connecting)),
                }
            }
            Err(e) => {
                if current(self) {
                    self.apply(e);
                }
            }
        }
    }

    fn apply(self: &Arc<Self>, error: WaError) {
        let not_logged_in = error == WaError::NotLoggedIn;
        let unreachable = error == WaError::Unreachable;
        self.with(|i| {
            i.link = Some(match error {
                WaError::Unreachable => Link::Unreachable,
                WaError::Unauthorized => Link::Unauthorized,
                WaError::NotLoggedIn => Link::NeedsQr,
                WaError::Refused(why) => Link::Failed(why),
            });
            if !not_logged_in {
                i.failures += 1;
            }
        });
        // GOWA die Nook startte en weg is (gecrasht, gestopt): opnieuw gestart, hooguit één keer per minuut.
        if unreachable {
            self.sync_gowa();
        }
    }

    /// De koppeling in één zin, voor de instellingen en voor het brein als WhatsApp niet bereikbaar is.
    pub fn status_line(&self) -> String {
        status_text(&self.link(), self.with(|i| i.me.clone()).as_deref())
    }

    pub fn view(&self) -> LinkView {
        let settings = self.settings();
        let port = settings.webhook_port();
        let filters = settings.filters();
        self.with(|i| {
            let webhook = i.webhook.clone().unwrap_or(Webhook::Off);
            LinkView {
                link: i.link.clone().unwrap_or(Link::Off),
                status_line: status_text(i.link.as_ref().unwrap_or(&Link::Off), i.me.as_deref()),
                webhook_line: match &webhook {
                    Webhook::Off => String::new(),
                    Webhook::Listening => format!("Wacht op berichten op 127.0.0.1:{port}…"),
                    Webhook::Registered => "Nieuwe berichten komen direct binnen.".into(),
                    Webhook::PortBusy => format!("Poort {port} is bezet: Nook kijkt elke 20 seconden zelf."),
                    Webhook::Refused(why) => format!("De koppeling weigerde de webhook ({why}): Nook kijkt elke 20 seconden zelf."),
                },
                webhook,
                qr: i.qr.as_ref().map(|png| format!("data:image/png;base64,{}", base64::engine::general_purpose::STANDARD.encode(png))),
                me: i.me.clone(),
                unread: i.inbox.visible_unread(&filters),
                hidden_chats: settings.ignored.len(),
                gowa_running: false,
            }
        })
    }

    /// De gesprekken die de interface toont, nieuwste eerst.
    pub fn visible(&self) -> Vec<super::Conversation> {
        let filters = self.settings().filters();
        self.with(|i| i.inbox.visible(&filters).into_iter().cloned().collect())
    }

    pub fn gowa_running(&self) -> bool {
        let mut g = self.gowa.lock().unwrap_or_else(|e| e.into_inner());
        match g.child.as_mut() {
            Some(c) => matches!(c.try_wait(), Ok(None)),
            None => false,
        }
    }

    // Webhook

    fn start_listener(self: &Arc<Self>, kind: super::GatewayKind) {
        let secret = self.webhook_secret();
        let port = self.settings().webhook_port();
        let me = self.clone();
        let task = tokio::spawn(async move {
            let listener = match TcpListener::bind(("127.0.0.1", port)).await {
                Ok(l) => l,
                Err(_) => {
                    me.with(|i| i.webhook = Some(Webhook::PortBusy));
                    me.changed();
                    return;
                }
            };
            me.with(|i| {
                if i.webhook.is_none() || i.webhook == Some(Webhook::PortBusy) {
                    i.webhook = Some(Webhook::Listening);
                }
            });
            me.refresh();
            loop {
                let Ok((mut socket, peer)) = listener.accept().await else { continue };
                // Alleen de loopback: de luisteraar zit er al aan vast, dit is een tweede slot.
                if !peer.ip().is_loopback() {
                    continue;
                }
                let me = me.clone();
                let secret = secret.clone();
                tokio::spawn(async move {
                    let mut buffer = vec![];
                    let mut chunk = [0u8; 16_384];
                    let read = async {
                        loop {
                            let n = socket.read(&mut chunk).await.unwrap_or(0);
                            if n > 0 {
                                buffer.extend_from_slice(&chunk[..n]);
                            }
                            match HttpRequest::parse(&buffer, 1_000_000) {
                                Parse::Incomplete if n > 0 => continue,
                                other => return other,
                            }
                        }
                    };
                    // Een verzoek dat nooit af komt, wordt na 10 seconden verbroken.
                    let parsed = tokio::time::timeout(Duration::from_secs(10), read).await.unwrap_or(Parse::Invalid);
                    let response = match parsed {
                        Parse::Done(request) => {
                            let status = if request.method != "POST" || !request.path.starts_with(WEBHOOK_PATH) {
                                404
                            } else if !verify(kind, &request.headers, &request.body, &secret) {
                                401
                            } else {
                                me.received(&request.body, kind);
                                200
                            };
                            let reason = match status {
                                200 => "OK",
                                401 => "Unauthorized",
                                _ => "Not Found",
                            };
                            HttpRequest::response(status, reason)
                        }
                        _ => HttpRequest::response(400, "Bad Request"),
                    };
                    let _ = socket.write_all(&response).await;
                    let _ = socket.shutdown().await;
                });
            }
        });
        self.tasks.lock().unwrap_or_else(|e| e.into_inner()).push(task);
    }

    async fn register(&self, provider: &Provider, gen: u64) {
        let url = format!("http://127.0.0.1:{}{WEBHOOK_PATH}", self.settings().webhook_port());
        match provider.register_webhook(&url, &self.webhook_secret()).await {
            Ok(()) => self.with(|i| {
                if i.generation == gen {
                    i.webhook = Some(Webhook::Registered);
                }
            }),
            Err(WaError::Refused(why)) => self.with(|i| {
                if i.generation == gen {
                    i.webhook = Some(Webhook::Refused(why));
                }
            }),
            // De volgende controle probeert het opnieuw.
            Err(_) => {}
        }
    }

    fn received(self: &Arc<Self>, body: &[u8], kind: super::GatewayKind) {
        let me = self.with(|i| {
            i.last_webhook = Some(Utc::now());
            if i.webhook != Some(Webhook::Registered) {
                i.webhook = Some(Webhook::Registered);
            }
            i.me.clone()
        });
        match parse_webhook(kind, body, me.as_deref()) {
            Some(WebhookEvent::Message(message)) => self.ingest(vec![message], true),
            Some(WebhookEvent::Receipt { ids, chat, status }) => {
                if let Some(changed) = self.with(|i| i.inbox.apply_receipt(status, &ids, &chat)) {
                    let f = self.on_receipt.lock().unwrap_or_else(|e| e.into_inner()).clone();
                    if let Some(f) = f {
                        f(changed);
                    }
                }
            }
            _ => {}
        }
        self.changed();
    }

    fn webhook_alive(&self) -> bool {
        self.with(|i| i.last_webhook.map(|t| (Utc::now() - t).num_seconds() < 300).unwrap_or(false))
    }

    // Berichten

    /// De laatste uren geschiedenis na het koppelen: bewaard, maar niets telt als nieuw.
    async fn backfill(self: &Arc<Self>, provider: &Provider, gen: u64) {
        let me_id = self.with(|i| {
            i.backfilled = true;
            i.me.clone()
        });
        let since = Utc::now() - chrono::Duration::hours(12);
        let Ok(messages) = provider.recent_messages(since, me_id.as_deref()).await else { return };
        let filters = self.settings().filters();
        let chats: Vec<String> = self.with(|i| {
            if i.generation != gen {
                return vec![];
            }
            let mut chats = vec![];
            for m in messages {
                chats.push(jid::normalized(&m.chat));
                i.inbox.add(m, &filters, None, true);
            }
            i.last_poll = Some(Utc::now());
            chats
        });
        for chat in chats {
            self.name_group(&chat);
        }
    }

    async fn load_chats(&self, provider: &Provider, gen: u64) {
        self.with(|i| i.last_chat_list = Some(Utc::now()));
        let Ok(chats) = provider.chats(200).await else { return };
        self.with(|i| {
            if i.generation == gen {
                i.known = chats.into_iter().map(|c| ChatInfo { jid: jid::normalized(&c.jid), ..c }).collect();
            }
        });
    }

    fn poll(self: &Arc<Self>) {
        if self.webhook_alive() {
            return;
        }
        let Some((provider, gen, since, me_id)) = self.with(|i| {
            if i.polling || !i.backfilled {
                return None;
            }
            i.polling = true;
            // Een beetje overlap; dubbele berichten vallen weg.
            let since = i.last_poll.unwrap_or_else(Utc::now) - chrono::Duration::seconds(30);
            i.provider.clone().map(|p| (p, i.generation, since, i.me.clone()))
        }) else {
            return;
        };
        let me = self.clone();
        tokio::spawn(async move {
            let started = Utc::now();
            if let Ok(messages) = provider.recent_messages(since, me_id.as_deref()).await {
                if me.with(|i| i.generation == gen) {
                    me.with(|i| i.last_poll = Some(started));
                    me.ingest(messages, true);
                    me.changed();
                }
            }
            me.with(|i| {
                if i.generation == gen {
                    i.polling = false;
                }
            });
        });
    }

    fn ingest(self: &Arc<Self>, messages: Vec<Message>, announce: bool) {
        let filters = self.settings().filters();
        let mut fresh = None;
        let mut chats = vec![];
        self.with(|i| {
            for m in messages {
                let key = jid::normalized(&m.chat);
                let from_me = m.from_me;
                let outcome = i.inbox.add(m, &filters, None, false);
                chats.push(key.clone());
                if outcome == Outcome::Notify && !from_me {
                    fresh = Some(key);
                }
            }
        });
        for chat in chats {
            self.name_group(&chat);
        }
        if let (true, Some(chat), true) = (announce, fresh, self.settings().notify) {
            let arrived = self.with(|i| {
                i.inbox.conversations.get(&chat).map(|c| Arrived {
                    chat: c.id.clone(),
                    name: c.name.clone(),
                    preview: c.messages.last().map(|m| super::label(&m.media).unwrap_or_default() + &m.text).unwrap_or_default(),
                    unread: c.unread,
                })
            });
            let f = self.on_arrived.lock().unwrap_or_else(|e| e.into_inner()).clone();
            if let (Some(a), Some(f)) = (arrived, f) {
                f(a);
            }
        }
    }

    /// Groepen komen binnen onder hun id (de webhook van GOWA noemt de naam niet): één keer gevraagd.
    fn name_group(self: &Arc<Self>, chat: &str) {
        let Some((provider, gen)) = self.with(|i| {
            let conversation = i.inbox.conversations.get(chat)?;
            if !jid::is_group(chat) || conversation.name != jid::display_number(chat) || !i.naming.insert(chat.to_string()) {
                return None;
            }
            i.provider.clone().map(|p| (p, i.generation))
        }) else {
            return;
        };
        let me = self.clone();
        let chat = chat.to_string();
        tokio::spawn(async move {
            if let Some(name) = provider.group_name(&chat).await {
                me.with(|i| {
                    if i.generation == gen {
                        i.inbox.rename(&chat, &name);
                    }
                });
            }
        });
    }

    /// De nieuwste berichten van één chat, van de koppeling (of wat Nook bewaarde).
    pub async fn messages_of(&self, chat: &str, limit: usize) -> CResult<Vec<Message>> {
        let (provider, me) = self.with(|i| (i.provider.clone(), i.me.clone()));
        let Some(provider) = provider.filter(|_| self.is_connected()) else { return Err(ConnectorError::new(self.status_line())) };
        let key = jid::normalized(chat);
        if let Ok(fetched) = provider.messages(&key, limit, me.as_deref()).await {
            if !fetched.is_empty() {
                let filters = self.settings().filters();
                self.with(|i| {
                    for m in &fetched {
                        i.inbox.add(m.clone(), &filters, None, true);
                    }
                });
                return Ok(fetched);
            }
        }
        Ok(self.with(|i| i.inbox.conversations.get(&key).map(|c| c.messages.clone()).unwrap_or_default()))
    }

    /// Markeert de chat hier en op WhatsApp als gelezen (tot het nieuwste ontvangen bericht).
    pub fn mark_read(&self, chat: &str) {
        let key = jid::normalized(chat);
        let mark = self.settings().mark_read_on_reply;
        let Some((provider, last)) = self.with(|i| {
            let conversation = i.inbox.conversations.get(&key)?;
            let had = conversation.unread > 0;
            let last = conversation.messages.iter().rev().find(|m| !m.from_me).map(|m| m.id.clone());
            i.inbox.mark_read(&key);
            (had && mark).then(|| i.provider.clone()).flatten().map(|p| (p, last))
        }) else {
            return;
        };
        tokio::spawn(async move {
            let _ = provider.mark_read(&key, last.as_deref()).await;
        });
    }

    /// Wie een naam, nummer of chat-id bedoelt: een chat op de telefoon of een die jou schreef. Nooit een nieuw
    /// nummer: Nook is geen massaverzender en een verkeerde gok mag nooit bij een vreemde aankomen.
    pub fn resolve(&self, recipient: &str) -> Option<(String, String)> {
        let wanted = recipient.trim();
        if wanted.is_empty() {
            return None;
        }
        let chats = self.with(|i| {
            let mut chats: Vec<(String, String)> = i.inbox.sorted().iter().map(|c| (c.id.clone(), c.name.clone())).collect();
            for k in &i.known {
                if !chats.iter().any(|(j, _)| *j == k.jid) {
                    chats.push((k.jid.clone(), if k.name.is_empty() { jid::display_number(&k.jid) } else { k.name.clone() }));
                }
            }
            chats
        });
        match_recipient(wanted, &chats)
    }

    fn chat_names(&self, limit: usize) -> Vec<String> {
        self.with(|i| {
            let mut names: Vec<String> = vec![];
            for n in i.inbox.sorted().iter().map(|c| c.name.clone()).chain(i.known.iter().take(12).map(|k| k.name.clone())) {
                if !n.is_empty() && !names.contains(&n) {
                    names.push(n);
                }
            }
            names.truncate(limit);
            names
        })
    }

    /// Stuurt tekst naar een chat. Fouten zijn een zin waar de gebruiker iets mee kan.
    pub async fn send(&self, text: &str, recipient: &str) -> CResult<String> {
        let provider =
            self.with(|i| i.provider.clone()).filter(|_| self.is_connected()).ok_or_else(|| ConnectorError::new(self.status_line()))?;
        let body = text.trim();
        if body.is_empty() {
            return Err(ConnectorError::new("Het bericht is leeg."));
        }
        if body.chars().count() > MAX_LENGTH {
            return Err(ConnectorError::new("Het bericht is te lang voor WhatsApp (maximaal 4096 tekens)."));
        }
        let Some((target, name)) = self.resolve(recipient) else {
            return Err(ConnectorError::new(format!(
                "Ik vind geen WhatsApp-chat met {recipient}. Chats op je telefoon: {}.",
                self.chat_names(12).join(", ")
            )));
        };
        if !self.with(|i| i.rate.get_or_insert_with(|| RateLimit::new(6, 60)).allow(Utc::now())) {
            return Err(ConnectorError::new("Even rustig: Nook stuurt hoogstens 6 WhatsApp-berichten per minuut."));
        }
        let gen = self.with(|i| i.generation);
        let id = provider.send(body, &target).await.map_err(|e| ConnectorError::new(wa_text(&e)))?;
        if self.with(|i| i.generation) != gen {
            return Ok(name);
        }
        let filters = self.settings().filters();
        let me = self.with(|i| i.me.clone()).unwrap_or_default();
        let mut mine =
            Message::new(&id.unwrap_or_else(|| format!("nook-{}", uuid::Uuid::new_v4())), &target, &me, "", body, Utc::now(), true);
        mine.chat_name = Some(name.clone());
        self.with(|i| i.inbox.add(mine, &filters, Some(&name), false));
        // Antwoorden leest het gesprek.
        if self.settings().mark_read_on_reply {
            let last = self.with(|i| {
                i.inbox.conversations.get(&target).and_then(|c| c.messages.iter().rev().find(|m| !m.from_me).map(|m| m.id.clone()))
            });
            let _ = provider.mark_read(&target, last.as_deref()).await;
        }
        self.changed();
        Ok(name)
    }

    /// One conversation as the card shows it (also a quiet or hidden one: the card asked for it by id).
    pub fn conversation(&self, chat: &str) -> Option<Conversation> {
        self.with(|i| i.inbox.conversations.get(&jid::normalized(chat)).cloned())
    }

    /// The older messages of a chat, fetched once so its card can scroll back. True when the conversation changed.
    pub async fn load_history(&self, chat: &str) -> bool {
        let key = jid::normalized(chat);
        if !self.is_connected() || !self.with(|i| i.history_loaded.insert(key.clone())) {
            return false;
        }
        let count = |me: &Self| me.with(|i| i.inbox.conversations.get(&key).map(|c| c.messages.len()).unwrap_or(0));
        let before = count(self);
        let _ = self.messages_of(&key, KEEP).await;
        count(self) != before
    }

    /// A file already fetched for the card.
    pub fn preview(&self, id: &str) -> Option<PathBuf> {
        self.with(|i| i.previews.get(id).cloned()).filter(|p| p.is_file())
    }

    /// The message ids of a chat's newest photos, videos and documents (a fixed few, so a redraw never reaches
    /// further back).
    pub fn preview_ids(&self, chat: &str) -> Vec<String> {
        self.with(|i| {
            let Some(c) = i.inbox.conversations.get(&jid::normalized(chat)) else { return vec![] };
            let all: Vec<String> = c.messages.iter().filter(|m| m.media.is_previewed()).map(|m| m.id.clone()).collect();
            all[all.len().saturating_sub(PREVIEW_COUNT)..].to_vec()
        })
    }

    /// Fetches the card's newest files that are not here yet. One that failed is tried again after a minute. True when
    /// at least one came in while the link stayed the same.
    pub async fn load_previews(&self, chat: &str) -> bool {
        let gen = self.with(|i| i.generation);
        let mut loaded = false;
        for id in self.preview_ids(chat) {
            let wanted = self.with(|i| {
                let failed_recently = i.preview_failed.get(&id).is_some_and(|t| t.elapsed() < PREVIEW_RETRY);
                let wanted = !i.previews.contains_key(&id) && !i.previews_loading.contains(&id) && !failed_recently;
                if wanted {
                    i.previews_loading.insert(id.clone());
                }
                wanted
            });
            if !wanted {
                continue;
            }
            let fetched = self.fetch_file(&id, chat).await;
            let current = self.with(|i| {
                i.previews_loading.remove(&id);
                i.generation == gen
            });
            if !current {
                if let Ok(path) = fetched {
                    remove_saved(&path);
                }
                return false;
            }
            match fetched {
                Ok(path) => {
                    self.keep_preview(&id, path);
                    loaded = true;
                }
                Err(_) => self.with(|i| {
                    i.preview_failed.insert(id.clone(), Instant::now());
                }),
            }
        }
        loaded
    }

    fn keep_preview(&self, id: &str, path: PathBuf) {
        let dropped = self.with(|i| {
            i.preview_failed.remove(id);
            if i.previews.insert(id.to_string(), path).is_none() {
                i.preview_order.push_back(id.to_string());
            }
            let mut dropped = vec![];
            while i.preview_order.len() > PREVIEW_LIMIT {
                if let Some(old) = i.preview_order.pop_front().and_then(|old| i.previews.remove(&old)) {
                    dropped.push(old);
                }
            }
            dropped
        });
        for path in dropped {
            remove_saved(&path);
        }
    }

    /// A message's file on this computer, fetched from the gateway only when the card shows it or the user opens it.
    pub async fn download(&self, id: &str, chat: &str) -> CResult<PathBuf> {
        if let Some(saved) = self.preview(id) {
            return Ok(saved);
        }
        let gen = self.with(|i| i.generation);
        let path = self.fetch_file(id, chat).await?;
        if self.with(|i| i.generation) != gen {
            remove_saved(&path);
            return Err(ConnectorError::new(self.status_line()));
        }
        self.keep_preview(id, path.clone());
        log::info!("WhatsApp: opened a file");
        Ok(path)
    }

    /// Fetches one message's file and saves it under its own folder in [`Self::files_dir`].
    async fn fetch_file(&self, id: &str, chat: &str) -> CResult<PathBuf> {
        let provider =
            self.with(|i| i.provider.clone()).filter(|_| self.is_connected()).ok_or_else(|| ConnectorError::new(self.status_line()))?;
        let key = jid::normalized(chat);
        let media = self
            .with(|i| i.inbox.conversations.get(&key)?.messages.iter().find(|m| m.id == id).map(|m| m.media.clone()))
            .filter(|m| m.is_openable())
            .ok_or_else(|| ConnectorError::new("Dit bericht is niet meer in Nook; open het op je telefoon."))?;
        let file = provider.media(&key, id).await.map_err(|e| match e {
            WaError::Refused(why) if why == "too large" => ConnectorError::new("Dit bestand is groter dan 50 MB; open het op je telefoon."),
            WaError::Refused(_) => ConnectorError::new(FETCH_FAILED),
            other => ConnectorError::new(wa_text(&other)),
        })?;
        if file.data.is_empty() {
            return Err(ConnectorError::new(FETCH_FAILED));
        }
        let name = files::file_name(&media, file.name.as_deref(), file.mime.as_deref());
        let root = self.files_dir();
        let folder = root.join(uuid::Uuid::new_v4().to_string());
        std::fs::create_dir_all(&folder).map_err(|e| ConnectorError::new(e.to_string()))?;
        crate::paths::restrict(&root, 0o700);
        let path = folder.join(name);
        std::fs::write(&path, &file.data).map_err(|e| ConnectorError::new(e.to_string()))?;
        Ok(path)
    }

    /// Whether `path` is a file Nook itself fetched into its own folder (and nothing outside it, through a link or
    /// `..`): the only kind it hands to another app.
    pub fn owns_file(&self, path: &Path) -> bool {
        let (Ok(root), Ok(file)) = (self.files_dir().canonicalize(), path.canonicalize()) else { return false };
        file.starts_with(&root) && file != root && file.is_file()
    }

    /// Keeps the chat but stops it from reaching you (the card's Dempen).
    pub fn mute(self: &Arc<Self>, chat: &str) {
        self.set_mode(chat, ChatMode::Muted);
    }

    pub fn set_mode(self: &Arc<Self>, chat: &str, mode: ChatMode) {
        self.env.store.update(|c| c.whatsapp.set_mode(chat, mode));
        self.changed();
    }

    /// A hidden chat comes back (one at a time).
    pub fn unhide(self: &Arc<Self>, chat: &str) {
        let key = jid::normalized(chat);
        self.env.store.update(|c| {
            c.whatsapp.ignored.remove(&key);
        });
        self.changed();
    }

    /// Every chat Settings › WhatsApp can name: the ones with messages, then the gateway's list, newest first; hidden
    /// chats last.
    pub fn chats_for_settings(&self) -> Vec<SettingsChat> {
        let settings = self.settings();
        let filters = settings.filters();
        let mut seen = HashSet::new();
        let mut out = vec![];
        self.with(|i| {
            for c in i.inbox.sorted() {
                if seen.insert(c.id.clone()) {
                    out.push((c.id.clone(), c.name.clone()));
                }
            }
            for k in &i.known {
                if seen.insert(k.jid.clone()) {
                    out.push((k.jid.clone(), if k.name.is_empty() { jid::fallback_name(&k.jid) } else { k.name.clone() }));
                }
            }
        });
        for hidden in &settings.ignored {
            if seen.insert(hidden.clone()) {
                out.push((hidden.clone(), jid::fallback_name(hidden)));
            }
        }
        out.into_iter()
            .map(|(jid, name)| SettingsChat {
                kind: jid::kind(&jid),
                mode: filters.mode(&jid),
                hidden: settings.ignored.contains(&jid),
                jid,
                name,
            })
            .collect()
    }

    pub fn ignore(self: &Arc<Self>, chat: &str) {
        let key = jid::normalized(chat);
        self.env.store.update(|c| {
            c.whatsapp.ignored.insert(key.clone());
        });
        self.with(|i| i.inbox.remove(&key));
        self.changed();
    }

    /// Eén controle vanuit "Test" in de instellingen.
    pub async fn test_connection(&self) -> String {
        let provider = match self.with(|i| i.provider.clone()) {
            Some(p) => p,
            None => match self.make_provider() {
                Some(p) => Arc::new(p),
                None => return "Het adres van de WhatsApp-koppeling klopt niet. Kijk bij Geavanceerd.".into(),
            },
        };
        let mut attempt = 0;
        loop {
            match provider.status().await {
                Ok(status) => {
                    return status_text(
                        &match status.link {
                            LinkState::Connected => Link::Connected,
                            LinkState::NeedsQr => Link::NeedsQr,
                            LinkState::Connecting => Link::Connecting,
                        },
                        status.me.as_deref(),
                    )
                }
                // GOWA net gestart door Nook: een paar seconden om op te komen.
                Err(WaError::Unreachable) if self.gowa_running() && attempt < 8 => {
                    attempt += 1;
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
                Err(e) => return wa_text(&e),
            }
        }
    }

    // GOWA starten

    /// Brengt GOWA in lijn met de instellingen: gestart als "GOWA automatisch starten" aan staat (en de koppeling GOWA
    /// op deze computer is), alleen herstart als binary, adres of wachtwoord veranderde, gestopt als het uit staat.
    pub fn sync_gowa(&self) -> bool {
        let s = self.settings();
        if !self.desktop || !s.auto_start || s.gateway != super::GatewayKind::Gowa {
            self.stop_gowa();
            return false;
        }
        let path = expand_home(&s.gowa_path);
        let Ok(url) = url::Url::parse(&s.address()) else {
            self.stop_gowa();
            return false;
        };
        // Alleen op deze computer: een adres elders is de koppeling van een ander.
        if path.is_empty()
            || !std::path::Path::new(&path).is_file()
            || !["127.0.0.1", "localhost", "[::1]"].contains(&url.host_str().unwrap_or(""))
        {
            self.stop_gowa();
            return false;
        }
        let credential = self.env.secret(CREDENTIAL_ACCOUNT).unwrap_or_default();
        let signature = format!("{path}\u{1f}{url}\u{1f}{credential}");
        let running = self.gowa_running();
        {
            let g = self.gowa.lock().unwrap_or_else(|e| e.into_inner());
            if running && g.signature.as_deref() == Some(signature.as_str()) {
                return true;
            }
            if !running
                && g.signature.as_deref() == Some(signature.as_str())
                && g.last_start.map(|t| t.elapsed().as_secs() < 60).unwrap_or(false)
            {
                return true;
            }
        }
        self.stop_gowa();
        let dir = crate::paths::support_directory().join("GOWA");
        let _ = std::fs::create_dir_all(&dir);
        let mut cmd = std::process::Command::new(&path);
        cmd.args(super::provider::gowa::launch_arguments(&url)).current_dir(&dir);
        // Het wachtwoord gaat via de omgeving, niet via de opdrachtregel (die ziet iedereen).
        if credential.contains(':') {
            cmd.env("APP_BASIC_AUTH", &credential);
        }
        cmd.env("APP_UI_ENABLED", "false")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        #[cfg(target_os = "windows")]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(0x0800_0000);
        }
        match cmd.spawn() {
            Ok(child) => {
                let mut g = self.gowa.lock().unwrap_or_else(|e| e.into_inner());
                g.child = Some(child);
                g.signature = Some(signature);
                g.last_start = Some(std::time::Instant::now());
                true
            }
            Err(e) => {
                log::info!("WhatsApp: GOWA kon niet starten: {e}");
                false
            }
        }
    }

    /// Stopt GOWA als Nook hem startte (bij afsluiten, of voor een herstart zodat er nooit twee dezelfde database delen).
    pub fn stop_gowa(&self) {
        let mut g = self.gowa.lock().unwrap_or_else(|e| e.into_inner());
        g.signature = None;
        if let Some(mut child) = g.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    fn live_tools(self: &Arc<Self>) -> Vec<LoopTool> {
        let (a, b, c, d) = (self.clone(), self.clone(), self.clone(), self.clone());
        vec![
            LoopTool::read(
                "whatsapp_live",
                "WhatsApp through the user's linked phone (live, includes what arrived a minute ago). Without chat: the recent conversations with unread counts and the newest message. With chat (a name, number or chat id): the newest messages of that chat.",
                json!({"type": "object", "properties": {
                    "chat": {"type": "string", "description": "Name, phone number or chat id. Leave empty for the overview."},
                    "limit": {"type": "integer", "description": "How many messages of the chat (default 20, at most 50)."}
                }}),
                move |input| {
                    let link = a.clone();
                    async move { link.live(&input).await.map_err(Into::into) }
                },
            ),
            LoopTool::read(
                "read_whatsapp",
                "Reads one WhatsApp chat from the linked phone: its newest messages in time order. Give the chat id from search_whatsapp or whatsapp_live, or a name.",
                json!({"type": "object", "properties": {
                    "chat": {"type": "string", "description": "The chat id from search_whatsapp, or a name."},
                    "limit": {"type": "integer", "description": "How many messages (default 20, at most 50)."}
                }, "required": ["chat"]}),
                move |input| {
                    let link = b.clone();
                    async move { link.live(&input).await.map_err(Into::into) }
                },
            ),
            LoopTool::read(
                "search_whatsapp",
                "Searches the WhatsApp chats of the linked phone (the last hours kept by Nook, plus chats whose name matches) by keywords in the text and by chat or contact name. Returns matching chats with their matching messages and a chat id; read a whole chat with read_whatsapp.",
                json!({"type": "object", "properties": {"query": {"type": "string", "description": "One or more keywords or a name, separated by spaces."}}, "required": ["query"]}),
                move |input| {
                    let link = c.clone();
                    async move { link.search(crate::connectors::text(&input, "query")).await.map_err(Into::into) }
                },
            ),
            LoopTool::read(
                "whatsapp_open_chats",
                "Lists the WhatsApp chats that are still open on the linked phone: unread ones, and one-on-one chats where the other person wrote last (waiting for the user's reply), with the newest message and a chat id.",
                json!({"type": "object", "properties": {}}),
                move |_| {
                    let link = d.clone();
                    async move { Ok(link.open_chats()) }
                },
            ),
            LoopTool::action(
                "whatsapp_send",
                "Sends a WhatsApp message from the user's own account to an existing chat (a contact or group on their phone), through the linked phone. Use when the user asks to app, WhatsApp or message someone on WhatsApp. Write the message as the user would, in their language and tone, without a signature. The user sees the exact text and recipient and approves before anything is sent.",
                json!({"type": "object", "properties": {
                    "to": {"type": "string", "description": "The chat: a contact or group name as on the phone, a phone number, or a chat id from whatsapp_live."},
                    "message": {"type": "string", "description": "The full text to send."}
                }, "required": ["to", "message"]}),
            ),
        ]
    }

    async fn live(&self, input: &Value) -> CResult<String> {
        let chat = crate::connectors::text(input, "chat").trim().to_string();
        if chat.is_empty() {
            let filters = self.settings().filters();
            return Ok(self.with(|i| {
                let list = i.inbox.visible(&filters);
                if list.is_empty() {
                    let names: Vec<String> = i.known.iter().take(15).map(|k| k.name.clone()).filter(|n| !n.is_empty()).collect();
                    if names.is_empty() {
                        "No recent WhatsApp messages in the last 12 hours.".to_string()
                    } else {
                        format!("No new WhatsApp messages in the last 12 hours. Recent chats: {}.", names.join(", "))
                    }
                } else {
                    format!("Recent WhatsApp conversations (newest first):\n{}", overview(&list, 12))
                }
            }));
        }
        let Some((target, name)) = self.resolve(&chat) else {
            return Err(ConnectorError::new(format!(
                "Ik vind geen WhatsApp-chat met {chat}. Chats op je telefoon: {}.",
                self.chat_names(12).join(", ")
            )));
        };
        let limit = crate::connectors::int(&input["limit"]).unwrap_or(20).clamp(1, 50) as usize;
        let messages = self.messages_of(&target, limit).await?;
        if messages.is_empty() {
            return Ok(format!("No messages found in the WhatsApp chat with {name}."));
        }
        Ok(format!("WhatsApp chat with {name} (chat id {target}):\n{}", super::lines(&messages, &name)))
    }

    async fn search(&self, query: &str) -> CResult<String> {
        let words: Vec<String> = query.split_whitespace().map(|w| w.to_lowercase()).filter(|w| w.chars().count() >= 2).collect();
        if words.is_empty() {
            return Err(ConnectorError::new("Zoekterm ontbreekt."));
        }
        let hit = |text: &str| {
            let lower = text.to_lowercase();
            words.iter().any(|w| lower.contains(w))
        };
        let (mut found, extra): (Vec<Found>, Vec<ChatInfo>) = self.with(|i| {
            let found = i
                .inbox
                .sorted()
                .iter()
                .filter_map(|c| {
                    let matching: Vec<Message> = c.messages.iter().filter(|m| hit(&m.text)).cloned().collect();
                    if !matching.is_empty() || hit(&c.name) {
                        Some((
                            c.id.clone(),
                            c.name.clone(),
                            if matching.is_empty() { c.messages.iter().rev().take(5).cloned().collect() } else { matching },
                        ))
                    } else {
                        None
                    }
                })
                .collect();
            let extra = i.known.iter().filter(|k| hit(&k.name) && !i.inbox.conversations.contains_key(&k.jid)).take(3).cloned().collect();
            (found, extra)
        });
        for chat in extra {
            if let Ok(messages) = self.messages_of(&chat.jid, 10).await {
                found.push((chat.jid.clone(), chat.name.clone(), messages));
            }
        }
        if found.is_empty() {
            return Ok(format!(
                "Geen WhatsApp-berichten gevonden voor \"{query}\" (Nook kent alleen de laatste uren en de chats op je telefoon)."
            ));
        }
        let mut out = vec![format!("WhatsApp chats matching \"{query}\":")];
        for (id, name, messages) in found.iter().take(8) {
            out.push(format!("\n{name} (chat id {id}):"));
            out.push(super::lines(&messages.iter().rev().take(8).cloned().collect::<Vec<_>>(), name));
        }
        Ok(out.join("\n"))
    }

    fn open_chats(&self) -> String {
        let filters = self.settings().filters();
        self.with(|i| {
            let list: Vec<_> = i
                .inbox
                .visible(&filters)
                .into_iter()
                .filter(|c| c.unread > 0 || (!c.is_group && c.messages.last().map(|m| !m.from_me).unwrap_or(false)))
                .collect();
            if list.is_empty() {
                return "No open WhatsApp chats: nothing unread and nobody waiting for a reply.".into();
            }
            let lines: Vec<String> = list
                .iter()
                .map(|c| {
                    let state = if c.unread > 0 { format!("{} unread", c.unread) } else { "waiting for your reply".into() };
                    let last = c.messages.last().map(|m| m.text.chars().take(120).collect::<String>()).unwrap_or_default();
                    format!("- {} ({state}, chat id {}): {last}", c.name, c.id)
                })
                .collect();
            format!("Open WhatsApp chats:\n{}", lines.join("\n"))
        })
    }
}

fn status_text(link: &Link, me: Option<&str>) -> String {
    match link {
        Link::Off => "Uit".into(),
        Link::Connecting => "Verbinden met de koppeling…".into(),
        Link::NeedsQr => "Nog niet gekoppeld: scan de QR-code met WhatsApp op je telefoon.".into(),
        Link::Connected => format!("Gekoppeld {}", me.map(jid::display_number).unwrap_or_default()).trim().to_string(),
        Link::Unreachable => "De WhatsApp-koppeling op deze computer antwoordt niet. Draait hij?".into(),
        Link::Unauthorized => "De koppeling weigert het wachtwoord of de sleutel. Kijk bij Geavanceerd.".into(),
        Link::Failed(why) => why.clone(),
    }
}

fn wa_text(error: &WaError) -> String {
    match error {
        WaError::Unreachable => status_text(&Link::Unreachable, None),
        WaError::Unauthorized => status_text(&Link::Unauthorized, None),
        WaError::NotLoggedIn => status_text(&Link::NeedsQr, None),
        WaError::Refused(why) => why.clone(),
    }
}

const FETCH_FAILED: &str =
    "De WhatsApp-koppeling kon dit bestand niet ophalen. Het is misschien te oud of nog niet gedownload op je telefoon.";

/// Removes a fetched file together with the folder of its own it was saved in.
fn remove_saved(path: &Path) {
    match path.parent() {
        Some(folder) => {
            let _ = std::fs::remove_dir_all(folder);
        }
        None => {
            let _ = std::fs::remove_file(path);
        }
    }
}

fn expand_home(path: &str) -> String {
    let p = path.trim();
    match (p.strip_prefix("~/"), dirs::home_dir()) {
        (Some(rest), Some(home)) => home.join(rest).display().to_string(),
        _ => p.to_string(),
    }
}

#[async_trait]
impl Connector for WhatsAppLink {
    fn id(&self) -> String {
        "whatsapp".into()
    }

    fn title(&self) -> String {
        "WhatsApp".into()
    }

    fn configured(&self) -> bool {
        self.settings().enabled
    }

    fn active(&self) -> bool {
        self.is_connected() && self.env.store.is_on("whatsapp")
    }

    fn status(&self) -> ConnectorStatus {
        let line = self.status_line();
        match self.link() {
            Link::Off => ConnectorStatus::default(),
            Link::Connected => {
                let filters = self.settings().filters();
                let (unread, items) = self.with(|i| {
                    let list = i.inbox.visible(&filters);
                    let items = list
                        .iter()
                        .take(5)
                        .map(|c| {
                            ConnectorItem::new(
                                &c.id,
                                &c.name,
                                c.messages.last().map(|m| m.text.clone()).unwrap_or_default(),
                                if c.unread > 0 { Tone::Attention } else { Tone::Neutral },
                                None,
                            )
                        })
                        .collect();
                    (i.inbox.visible_unread(&filters), items)
                });
                let detail = if unread > 0 { format!("{unread} ongelezen") } else { "Alles gelezen".into() };
                ConnectorStatus::ok(line, detail, items, unread > 0)
            }
            Link::Connecting | Link::NeedsQr => ConnectorStatus { state: ConnectorState::Loading, headline: line, ..Default::default() },
            Link::Unauthorized => ConnectorStatus::failed(&ConnectorError::kind(line, ErrorKind::Auth)),
            Link::Unreachable => ConnectorStatus::failed(&ConnectorError::kind(line, ErrorKind::Network)),
            Link::Failed(_) => ConnectorStatus::failed(&ConnectorError::new(line)),
        }
    }

    fn refresh_interval(&self) -> u64 {
        3600
    }

    async fn refresh(&self) {}

    fn context_lines(&self) -> Vec<String> {
        if !self.is_connected() {
            return vec![];
        }
        let mut lines = vec!["WhatsApp is linked live (the user's phone through a local gateway): read chats with whatsapp_live, send with whatsapp_send (the user approves first).".to_string()];
        let filters = self.settings().filters();
        let unread = self.with(|i| {
            let list: Vec<_> = i.inbox.visible(&filters).into_iter().filter(|c| c.unread > 0).collect();
            (!list.is_empty()).then(|| overview(&list, 6))
        });
        if let Some(text) = unread {
            lines.push(format!("Unread WhatsApp chats:\n{text}"));
        }
        lines
    }

    fn tools(self: Arc<Self>, _scope: &Scope) -> Vec<LoopTool> {
        if !self.is_connected() {
            return vec![];
        }
        self.live_tools()
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        (tool == "whatsapp_send")
            .then(|| format!("WhatsApp → {}: {}", crate::connectors::text(input, "to").trim(), crate::connectors::text(input, "message")))
    }

    async fn execute(&self, tool: &str, input: &Value) -> Option<CResult<String>> {
        if tool != "whatsapp_send" {
            return None;
        }
        let to = crate::connectors::text(input, "to").to_string();
        let message = crate::connectors::text(input, "message").to_string();
        Some(self.send(&message, &to).await.map(|name| format!("WhatsApp-bericht verstuurd naar {name}.")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connectors::testserver::TestServer;
    use crate::connectors::ConnectorStore;
    use crate::secrets::MemorySecrets;

    #[tokio::test]
    async fn links_to_a_gateway_reads_and_sends() {
        let server = TestServer::start(vec![
            ("GET /devices", 200, r#"{"results":[{"id":"nook","state":"logged_in","jid":"31611111111@s.whatsapp.net"}]}"#.into()),
            ("PATCH /devices/nook/webhook", 200, "{}".into()),
            ("GET /chats", 200, r#"{"results":{"data":[{"jid":"31622222222@s.whatsapp.net","name":"Jan Bakker","last_message_time":"2026-10-18T12:00:00Z"}]}}"#.into()),
            ("GET /chat/*", 200, r#"{"results":{"data":[{"id":"m1","chat_jid":"31622222222@s.whatsapp.net","sender_jid":"31622222222@s.whatsapp.net","sender_display_name":"Jan","content":"Kom je vanavond?","timestamp":"2026-10-18T12:00:00Z","is_from_me":false},{"id":"d1","chat_jid":"31622222222@s.whatsapp.net","sender_jid":"31622222222@s.whatsapp.net","content":"","timestamp":"2026-10-18T12:01:00Z","is_from_me":false,"media_type":"document","filename":"../plan.exe"},{"id":"d2","chat_jid":"31622222222@s.whatsapp.net","sender_jid":"31622222222@s.whatsapp.net","content":"","timestamp":"2026-10-18T12:02:00Z","is_from_me":false,"media_type":"document","filename":"plan.pdf"}]}}"#.into()),
            ("POST /send/message", 200, r#"{"results":{"message_id":"M9"}}"#.into()),
            ("GET /message/*", 200, r#"{"results":{"file_path":"statics/media/x"}}"#.into()),
            ("GET /statics/*", 200, "%PDF-1.4".into()),
        ])
        .await;
        let env = Env::new(Arc::new(MemorySecrets::default()), Arc::new(ConnectorStore::in_memory()));
        env.store.update(|c| {
            c.whatsapp.enabled = true;
            c.whatsapp.url = server.url("");
            c.whatsapp.port = 0;
        });
        let link = WhatsAppLink::new(env, false);
        let files_dir = std::env::temp_dir().join(format!("nook-wa-test-{}", uuid::Uuid::new_v4()));
        link.set_files_dir(files_dir.clone());
        let receipts = Arc::new(Mutex::new(vec![]));
        let seen = receipts.clone();
        link.on_receipt(move |chat| seen.lock().unwrap().push(chat));
        let arrived = Arc::new(Mutex::new(vec![]));
        let log = arrived.clone();
        link.on_arrived(move |a| log.lock().unwrap().push(a));
        link.start();
        for _ in 0..50 {
            if link.is_connected() && link.with(|i| !i.known.is_empty()) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert!(link.is_connected());
        assert_eq!(link.status_line(), "Gekoppeld +31611111111");
        let read = link.live(&json!({"chat": "Jan"})).await.unwrap();
        assert!(read.contains("Jan: Kom je vanavond?"), "{read}");
        assert_eq!(link.send("Ja, tot zo!", "Jan").await.unwrap(), "Jan");
        assert!(link.send("Hoi", "Pieter").await.unwrap_err().message.starts_with("Ik vind geen WhatsApp-chat met Pieter"));
        let tool_names: Vec<String> = link.clone().tools(&Scope::default()).iter().map(|t| t.name.clone()).collect();
        assert!(tool_names.contains(&"whatsapp_send".to_string()));
        // Een webhook-levering van een nieuw bericht wordt gemeld.
        let body = br#"{"event":"message","payload":{"id":"N1","chat_id":"31622222222@s.whatsapp.net","from":"31622222222@s.whatsapp.net","from_name":"Jan","timestamp":"2026-10-18T13:00:00Z","body":"Top!"}}"#;
        link.received(body, super::super::GatewayKind::Gowa);
        assert_eq!(arrived.lock().unwrap().last().map(|a| a.name.clone()).as_deref(), Some("Jan"));

        // Your sent message gets its ticks from the gateway's receipts.
        let ack = br#"{"event":"message.ack","payload":{"ids":["M9"],"chat_id":"31622222222@s.whatsapp.net","receipt_type":"read"}}"#;
        link.received(ack, super::super::GatewayKind::Gowa);
        assert_eq!(receipts.lock().unwrap().as_slice(), ["31622222222@s.whatsapp.net"]);
        let card = link.conversation("31622222222@s.whatsapp.net").unwrap();
        assert_eq!(card.messages.iter().find(|m| m.id == "M9").and_then(|m| m.receipt), Some(super::super::Receipt::Read));

        // Files are fetched into Nook's own folder, under a safe name; nothing else counts as Nook's.
        assert_eq!(link.preview_ids("31622222222@s.whatsapp.net"), ["d1", "d2"]);
        assert!(link.load_previews("31622222222@s.whatsapp.net").await);
        let saved = link.download("d2", "31622222222@s.whatsapp.net").await.unwrap();
        assert!(saved.starts_with(&files_dir) && saved.ends_with("plan.pdf"), "{saved:?}");
        assert!(link.owns_file(&saved));
        assert_eq!(std::fs::read(&saved).unwrap(), b"%PDF-1.4");
        let odd = link.preview("d1").unwrap();
        assert_eq!(odd.file_name().unwrap(), "-plan.exe");
        assert!(!super::super::files::may_open("-plan.exe"));
        assert!(!link.owns_file(std::path::Path::new("/etc/hosts")));
        assert!(link.download("m1", "31622222222@s.whatsapp.net").await.is_err(), "a text message has no file");

        // Per chat: muted chats stay, hidden ones come back one at a time.
        link.mute("31622222222@s.whatsapp.net");
        assert_eq!(link.settings().filters().mode("31622222222@s.whatsapp.net"), super::super::ChatMode::Muted);
        assert!(link.visible().is_empty());
        link.ignore("31622222222@s.whatsapp.net");
        let listed = link.chats_for_settings();
        assert!(listed.iter().any(|c| c.jid == "31622222222@s.whatsapp.net" && c.hidden));
        link.unhide("31622222222@s.whatsapp.net");
        assert!(link.settings().ignored.is_empty());

        link.stop(true);
        assert!(!files_dir.exists(), "fetched files go when WhatsApp stops");
    }
}
