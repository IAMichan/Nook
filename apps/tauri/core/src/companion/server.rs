//! De computerkant van de companion (`CompanionServer.swift`): een TCP-luisteraar die verzegelde aanvragen van
//! gekoppelde telefoons beantwoordt. Zonder koppelsleutel is niets leesbaar, oude, herhaalde of te snelle aanvragen
//! worden geweigerd, en wat een telefoon mag begrenst [`CompanionPolicy`]. Elke actie staat in het auditlogboek.
//! De aankondiging op het netwerk (mDNS/Bonjour) doet de app.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use chrono::Utc;
use serde::Serialize;
use serde_json::Value;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpListener;

use super::backend::{BackendSession, CompanionBackend};
use super::device_key;
use super::live;
use super::models::*;
use super::push;
use super::relay_push;
use super::scopes;
use super::seal::{self, Direction};
use super::store::CompanionStore;
use crate::store::NookStore;

const MAX_CONNECTIONS: usize = 8;

/// A connection a request came on: its number, its writer, and how many frames wait on that writer.
type Connection<'a> = (u64, &'a tokio::sync::mpsc::UnboundedSender<Vec<u8>>, &'a Arc<AtomicUsize>);
const CONNECTION_DEADLINE: Duration = Duration::from_secs(30);
const MAX_SESSIONS: usize = 25;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum ServerState {
    Stopped,
    Listening { port: u16 },
    Failed { message: String },
}

pub struct CompanionServer {
    store: Arc<CompanionStore>,
    backend: Arc<RwLock<Arc<dyn CompanionBackend>>>,
    audit: Option<Arc<NookStore>>,
    /// De naam die de telefoon ziet ("Michaels pc").
    name: String,
    apns: super::apns::ApnsClient,
    /// Posts sealed pushes to the relay (`relay_push`).
    relay_http: reqwest::Client,
    /// This build has a relay of Nook's own, so a new setup starts on the relay route (`PushRoute::default_for`).
    build_relay: std::sync::atomic::AtomicBool,
    ledger: Mutex<push::PushLedger>,
    /// Hoe de laatste melding afliep, per toestel; voor Instellingen.
    last_push: Mutex<Option<String>>,
    guards: Mutex<HashMap<String, RequestGuard>>,
    state: Mutex<ServerState>,
    task: Mutex<Option<tokio::task::AbortHandle>>,
    open: Arc<AtomicUsize>,
    /// Where phones can reach this computer besides the address in their code, and the relay it keeps rooms on: told
    /// with every `hello` and `list` (`endpoints`, `relay`), so a phone follows a new Wi-Fi address or the relay without
    /// pairing again (`CompanionEndpoints` on the Mac).
    reach: Mutex<Reach>,
    /// The phones connected live (`subscribe`), by connection.
    peers: Arc<Mutex<HashMap<u64, live::Peer>>>,
    next_connection: AtomicU64,
    /// The answers to requests that changed something, per phone (`feature::RETRY`).
    receipts: Mutex<HashMap<String, live::Receipts>>,
    /// The task that looks for changes while a phone is connected live; ends when none is.
    ticker: Mutex<Option<tokio::task::AbortHandle>>,
    nudged: Arc<tokio::sync::Notify>,
    /// This app's version and the kind of computer it runs on, told with `hello`, `list` and `subscribe`.
    app_version: Mutex<Option<String>>,
    platform: &'static str,
}

/// What `hello` and `list` say about how to reach this computer.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Reach {
    /// The `.local` name and the addresses of this computer's interfaces (the port is the listener's).
    pub hosts: Vec<ReachHost>,
    /// The relay address phones should use, or "" so they drop the one they knew.
    pub relay: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReachHost {
    pub host: String,
    /// The address is this computer's Tailscale address (not just any address in 100.64/10).
    pub tailnet: bool,
}

impl CompanionServer {
    pub fn new(store: Arc<CompanionStore>, backend: Arc<dyn CompanionBackend>, audit: Option<Arc<NookStore>>, name: String) -> Self {
        Self {
            store,
            backend: Arc::new(RwLock::new(backend)),
            audit,
            name,
            apns: Default::default(),
            relay_http: reqwest::Client::builder().timeout(Duration::from_secs(15)).build().unwrap_or_default(),
            build_relay: Default::default(),
            ledger: Mutex::new(Default::default()),
            last_push: Mutex::new(None),
            guards: Mutex::new(HashMap::new()),
            state: Mutex::new(ServerState::Stopped),
            task: Mutex::new(None),
            open: Arc::new(AtomicUsize::new(0)),
            reach: Mutex::new(Reach::default()),
            peers: Arc::new(Mutex::new(HashMap::new())),
            next_connection: AtomicU64::new(1),
            receipts: Mutex::new(HashMap::new()),
            ticker: Mutex::new(None),
            nudged: Arc::new(tokio::sync::Notify::new()),
            app_version: Mutex::new(None),
            platform: if cfg!(target_os = "windows") {
                "windows"
            } else if cfg!(target_os = "macos") {
                "macos"
            } else if cfg!(target_os = "android") {
                "android"
            } else {
                "linux"
            },
        }
    }

    /// The version of this app, told to phones so they can say when one side is behind (`CompanionCompatibility`).
    /// This build has Nook's own relay (`NOOK_RELAY_URL`).
    pub fn set_build_relay(&self, has: bool) {
        self.build_relay.store(has, Ordering::Relaxed);
    }

    /// How pushes reach the phones now.
    pub fn push_route(&self) -> relay_push::PushRoute {
        self.store.push_route(self.build_relay.load(Ordering::Relaxed))
    }

    /// The relay's push endpoint, when a relay is in use (`RelayPushClient.reachable`): an Android phone needs it,
    /// whatever the route for iPhones is.
    fn relay_push_endpoint(&self) -> Option<String> {
        relay_push::endpoint(&self.reach().relay)
    }

    /// A relay is in use that pushes can go through (`RelayPushClient.reachable`).
    pub fn relay_push_reachable(&self) -> bool {
        self.relay_push_endpoint().is_some()
    }

    /// Notifications go through the relay now (`RelayPushClient.active`).
    pub fn relay_push_active(&self) -> bool {
        self.push_route() == relay_push::PushRoute::Relay && self.relay_push_endpoint().is_some()
    }

    /// Notifications can go out at all: with the user's own APNs key, or sealed through the relay
    /// (`CompanionNotifier.canSendAlerts`).
    pub fn can_send_alerts(&self) -> bool {
        self.store.can_push() || self.relay_push_active()
    }

    pub fn set_app_version(&self, version: &str) {
        *self.app_version.lock().unwrap_or_else(|e| e.into_inner()) = Some(version.to_string());
    }

    /// Everything this computer can do (`CompanionFeature.all` on the Mac): what the server does itself, and what the
    /// backend says it can.
    pub fn features(&self) -> Vec<String> {
        let backend = self.backend().features();
        let mut list: Vec<&str> = vec![
            feature::DEVICE_KEY,
            feature::ROUTES,
            feature::RELAY,
            feature::STREAM,
            feature::FOREGROUND,
            feature::RETRY,
            feature::CLOCK,
            feature::COMPRESSION,
            feature::REVOKE,
        ];
        if backend.contains(&feature::TIMELINE) {
            list.extend([feature::LIVE_TIMELINE, feature::RESUME]);
        }
        if backend.contains(&feature::INBOX) || backend.contains(&feature::CHAT) {
            list.push(feature::LIVE_CHATS);
        }
        if backend.contains(&feature::CHAT) {
            list.push(feature::LIVE_CONVERSATION);
        }
        for f in backend {
            if !list.contains(&f) {
                list.push(f);
            }
        }
        list.into_iter().map(str::to_string).collect()
    }

    /// The answer to `hello`, `list` and `subscribe`: the sessions, what this computer is and can do, and how to reach it.
    async fn hello(&self, id: &str) -> CompanionResponse {
        CompanionResponse {
            mac_name: Some(self.name.clone()),
            platform: Some(self.platform.into()),
            sessions: Some(digests(self.backend().sessions().await)),
            endpoints: self.endpoints(),
            relay: Some(self.reach().relay),
            features: Some(self.features()),
            protocol_version: Some(PROTOCOL_VERSION),
            oldest_phone: Some(OLDEST_PHONE),
            app_version: self.app_version.lock().unwrap_or_else(|e| e.into_inner()).clone(),
            ..CompanionResponse::success(id)
        }
    }

    /// Updates what phones are told about reaching this computer.
    pub fn set_reach(&self, reach: Reach) {
        *self.reach.lock().unwrap_or_else(|e| e.into_inner()) = reach;
    }

    pub fn reach(&self) -> Reach {
        self.reach.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// The endpoints for an answer: every known host on the listener's port; nil while not listening.
    fn endpoints(&self) -> Option<Vec<CompanionEndpoint>> {
        let ServerState::Listening { port } = self.state() else { return None };
        let reach = self.reach();
        Some(
            reach
                .hosts
                .into_iter()
                .filter(|h| valid_host(&h.host))
                .map(|h| CompanionEndpoint { host: h.host, port, tailnet: h.tailnet.then_some(true) })
                .collect(),
        )
    }

    pub fn store(&self) -> &Arc<CompanionStore> {
        &self.store
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    /// De agents-kant kan later een echte backend geven zonder de server te herstarten.
    pub fn set_backend(&self, backend: Arc<dyn CompanionBackend>) {
        *self.backend.write().unwrap_or_else(|e| e.into_inner()) = backend;
    }

    /// Vergeet het ondertekende token, bv. na een nieuwe sleutel.
    pub fn forget_apns_token(&self) {
        self.apns.forget_token();
    }

    pub fn last_push(&self) -> Option<String> {
        self.last_push.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// The sessions as the backend gives them (for keeping the computer awake while agents work).
    pub async fn sessions(&self) -> Vec<BackendSession> {
        self.backend().sessions().await
    }

    fn backend(&self) -> Arc<dyn CompanionBackend> {
        self.backend.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub fn state(&self) -> ServerState {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn set_state(&self, state: ServerState) {
        *self.state.lock().unwrap_or_else(|e| e.into_inner()) = state;
    }

    /// Start of stopt de luisteraar zoals de instelling zegt.
    pub async fn apply(self: &Arc<Self>) -> ServerState {
        if self.store.enabled() {
            self.start().await
        } else {
            self.stop();
            self.state()
        }
    }

    pub async fn start(self: &Arc<Self>) -> ServerState {
        if let ServerState::Listening { .. } = self.state() {
            return self.state();
        }
        let listener = match self.store.port() {
            Some(port) => match TcpListener::bind(("0.0.0.0", port)).await {
                Ok(l) => Ok(l),
                // Bezet: een andere poort, die voortaan vast blijft.
                Err(_) => TcpListener::bind(("0.0.0.0", 0)).await,
            },
            None => TcpListener::bind(("0.0.0.0", 0)).await,
        };
        let listener = match listener.and_then(|l| l.local_addr().map(|a| (l, a.port()))) {
            Ok(pair) => pair,
            Err(e) => {
                self.store.set_port(None);
                self.set_state(ServerState::Failed { message: e.to_string() });
                return self.state();
            }
        };
        let (listener, port) = listener;
        if self.store.port() != Some(port) {
            self.store.set_port(Some(port));
        }
        self.set_state(ServerState::Listening { port });
        let me = self.clone();
        let handle = tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    continue;
                };
                if me.open.load(Ordering::SeqCst) >= MAX_CONNECTIONS {
                    drop(stream);
                    continue;
                }
                me.open.fetch_add(1, Ordering::SeqCst);
                let conn = me.clone();
                tokio::spawn(async move {
                    let _ = tokio::time::timeout(CONNECTION_DEADLINE, conn.serve_stream(stream)).await;
                    conn.open.fetch_sub(1, Ordering::SeqCst);
                });
            }
        });
        *self.task.lock().unwrap_or_else(|e| e.into_inner()) = Some(handle.abort_handle());
        self.state()
    }

    pub fn stop(&self) {
        if let Some(task) = self.task.lock().unwrap_or_else(|e| e.into_inner()).take() {
            task.abort();
        }
        self.set_state(ServerState::Stopped);
    }

    /// Wat de telefoon krijgt om te koppelen: de sleutel van een open koppelvenster en waar deze computer zit.
    pub fn pairing_link(&self, host: &str) -> Option<PairingLink> {
        let ServerState::Listening { port } = self.state() else { return None };
        let now = Utc::now();
        let key = self.store.active_pending(now).unwrap_or_else(|| self.store.begin_pairing(now));
        Some(self.link(host, port, key))
    }

    /// A pairing code for `key`: `host` first, this computer's other addresses as alternates (`&a=`, so a phone that
    /// cannot resolve one still pairs, and knows the Tailscale address from the start), and the relay while it is on
    /// (`&r=`, so a phone can even pair away from home).
    pub fn link(&self, host: &str, port: u16, key: Vec<u8>) -> PairingLink {
        let reach = self.reach();
        let mut alternates: Vec<String> = Vec::new();
        for h in reach.hosts {
            if !h.host.eq_ignore_ascii_case(host) && valid_host(&h.host) && !alternates.contains(&h.host) {
                alternates.push(h.host);
            }
        }
        alternates.truncate(MAX_ALTERNATES);
        PairingLink {
            host: host.into(),
            port,
            key,
            mac_name: self.name.clone(),
            alternates,
            relay: Some(reach.relay).filter(|r| !r.is_empty()),
        }
    }

    /// Answers one connection: a phone on this network, or one that came through the relay (`relay::RelayHost`). A
    /// connection that subscribed stays open while the phone is heard from (`live::STREAM_IDLE`), and gets what changes
    /// by itself; any other closes after `live::REQUEST_IDLE` without a request.
    pub async fn serve_stream<S: AsyncRead + AsyncWrite + Unpin + Send>(&self, stream: S) {
        let (mut reader_half, mut writer_half) = tokio::io::split(stream);
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
        let pending = Arc::new(AtomicUsize::new(0));
        let connection = self.next_connection.fetch_add(1, Ordering::SeqCst);
        let written = pending.clone();
        let writer = async move {
            while let Some(frame) = rx.recv().await {
                // An empty frame is the server's own: close this connection (`close_streams`).
                if frame.is_empty() {
                    return;
                }
                let failed = writer_half.write_all(&frame).await.is_err();
                written.fetch_sub(1, Ordering::SeqCst);
                if failed {
                    return;
                }
            }
        };
        let reader = async {
            let mut reader = FrameReader::default();
            let mut buf = vec![0u8; 64 * 1024];
            loop {
                let idle = if self.is_live(connection) { live::STREAM_IDLE } else { live::REQUEST_IDLE };
                let n = match tokio::time::timeout(idle, reader_half.read(&mut buf)).await {
                    Ok(Ok(0)) | Ok(Err(_)) | Err(_) => return,
                    Ok(Ok(n)) => n,
                };
                let frames = reader.feed(&buf[..n]);
                if reader.overflowed() {
                    return;
                }
                for frame in frames {
                    match self.respond_on(&frame, Some((connection, &tx, &pending))).await {
                        Some(reply) => {
                            pending.fetch_add(1, Ordering::SeqCst);
                            if tx.send(reply).is_err() {
                                return;
                            }
                        }
                        None => return,
                    }
                }
            }
        };
        tokio::select! {
            _ = reader => {}
            _ = writer => {}
        }
        self.peers.lock().unwrap_or_else(|e| e.into_inner()).remove(&connection);
    }

    fn is_live(&self, connection: u64) -> bool {
        self.peers.lock().unwrap_or_else(|e| e.into_inner()).contains_key(&connection)
    }

    /// Het antwoord op één frame, al verzegeld en ingelijst; `None` = verbinding sluiten.
    pub async fn respond(&self, frame: &[u8]) -> Option<Vec<u8>> {
        self.respond_on(frame, None).await
    }

    /// The answer to one frame on `connection` (none: a single request, as in the tests): sealed and framed.
    async fn respond_on(&self, frame: &[u8], connection: Option<Connection<'_>>) -> Option<Vec<u8>> {
        let claimed = seal::claimed_device(frame)?;
        let now = Utc::now();
        // De sleutel van een gekoppeld toestel, of die van het open koppelvenster (die zich bewijst door het bericht te openen).
        let (key, pairing) = match self.store.key(&claimed) {
            Some(key) => (key, false),
            None => {
                let pending = self.store.active_pending(now).filter(|k| PairedDevice::identifier(k) == claimed)?;
                (pending, true)
            }
        };
        let plain = seal::open(frame, &key, Direction::Request).ok()?;
        let plain = super::transport::unpack(&plain).ok()?;
        let request: CompanionRequest = serde_json::from_slice(&plain).ok()?;
        let compress = request.compression == Some(true);
        // Only what this phone may see, and only the features it may use (`scopes::redact`); looked up when sealing, so
        // a phone that pairs with this very request gets its new scopes.
        let sealed = |response: CompanionResponse| {
            let response = scopes::redact(response, &self.store.scopes_of(&claimed));
            Self::seal_response(&response, &key, &claimed, compress)
        };
        let seconds = now.timestamp_millis() as f64 / 1000.0;

        // A phone that bound its device key signs every request with it (`device_key`): without a valid signature the
        // pairing key alone (a copy of it) is not enough.
        if !pairing && device_key::needs_signature(request.op) {
            if let Some(public_key) = self.store.device_key(&claimed) {
                if !device_key::verify(frame, &public_key) {
                    return sealed(CompanionResponse {
                        message: Some("signature".into()),
                        ..CompanionResponse::failure(&request.id, CompanionError::NotAllowedFromPhone)
                    });
                }
            }
        }

        // A request outside what this phone may do (`CompanionScopes.allows`).
        if !pairing && !scopes::allows(request.op, &self.store.scopes_of(&claimed)) {
            return sealed(CompanionResponse {
                message: Some("scope".into()),
                ..CompanionResponse::failure(&request.id, CompanionError::NotAllowedFromPhone)
            });
        }

        // A repeat of a request that changes something (its answer got lost, or it waited in the phone's outbox): the
        // answer it got, without doing it again (`CommandReceipts`, `feature::RETRY`).
        let keeps = !pairing && live::keeps(request.op);
        if keeps {
            let lookup = self.receipts.lock().unwrap_or_else(|e| e.into_inner()).entry(claimed.clone()).or_default().begin(&request.id);
            match lookup {
                live::Lookup::New => {}
                live::Lookup::Answered(earlier) => {
                    let refusal = self
                        .guards
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .entry(claimed.clone())
                        .or_default()
                        .admit_retry(&request, seconds);
                    return sealed(refusal.map(|e| Self::refusal(&request.id, e, seconds)).unwrap_or(*earlier));
                }
                // Still being carried out: the phone asks again later and gets the answer then.
                live::Lookup::Running => return sealed(CompanionResponse::failure(&request.id, CompanionError::Busy)),
            }
        }

        // De bewaker hoort bij het toestel: een herhaald id of een stortvloed wordt vanaf hier geweigerd.
        let refusal = {
            let mut guards = self.guards.lock().unwrap_or_else(|e| e.into_inner());
            guards.entry(claimed.clone()).or_default().admit(&request, seconds)
        };
        if let Some(error) = refusal {
            if keeps {
                self.receipts.lock().unwrap_or_else(|e| e.into_inner()).entry(claimed.clone()).or_default().cancel(&request.id);
            }
            return sealed(Self::refusal(&request.id, error, seconds));
        }

        if pairing {
            let name = request.text.clone().unwrap_or_default();
            if request.op != CompanionOp::Hello || self.store.complete_pairing(&name, now).is_none() {
                return sealed(CompanionResponse::failure(&request.id, CompanionError::BadRequest));
            }
            self.audit("paired", if name.is_empty() { "Telefoon" } else { &name });
        } else {
            self.store.touch(&claimed, now);
        }
        if matches!(request.op, CompanionOp::Hello | CompanionOp::List | CompanionOp::Subscribe) {
            self.store.note_versions(&claimed, request.protocol_version, clean_version(request.app_version.as_deref()));
        }

        if let Some((connection, tx, pending)) = connection {
            let mut peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(peer) = peers.get_mut(&connection) {
                peer.last_heard = std::time::Instant::now();
                if let (Some(foreground), CompanionOp::Ping) = (request.foreground, request.op) {
                    peer.foreground = foreground;
                }
            }
            if request.op == CompanionOp::Subscribe && !pairing {
                // One live connection per phone: a newer one (another network, the app restarted) replaces the older.
                peers.retain(|_, p| p.device != claimed);
                let mut peer = live::Peer::new(claimed.clone(), key.clone(), request.id.clone(), tx.clone(), pending.clone());
                peer.compression = compress;
                peer.scopes = self.store.scopes_of(&claimed);
                peer.foreground = request.foreground.unwrap_or(false);
                peers.insert(connection, peer);
                drop(peers);
                self.ensure_ticker();
            }
        }

        let mut response = self.handle(&request, &claimed, connection.map(|c| c.0)).await;
        response.id = request.id.clone();
        if request.op == CompanionOp::Subscribe {
            if let Some((connection, ..)) = connection {
                if let Some(peer) = self.peers.lock().unwrap_or_else(|e| e.into_inner()).get_mut(&connection) {
                    peer.sent_sessions = response.sessions.clone();
                }
            }
        }
        if keeps {
            let mut receipts = self.receipts.lock().unwrap_or_else(|e| e.into_inner());
            receipts.entry(claimed.clone()).or_default().finish(&request.id, &response);
            if !live::settles(&response) {
                self.guards.lock().unwrap_or_else(|e| e.into_inner()).entry(claimed.clone()).or_default().forget(&request);
            }
        }
        sealed(response)
    }

    /// A refusal; a `stale` one says the computer's time, so the phone can correct for its clock (`feature::CLOCK`).
    fn refusal(id: &str, error: CompanionError, now: f64) -> CompanionResponse {
        CompanionResponse { mac_time: (error == CompanionError::Stale).then_some(now), ..CompanionResponse::failure(id, error) }
    }

    fn seal_response(response: &CompanionResponse, key: &[u8], device: &str, compress: bool) -> Option<Vec<u8>> {
        let json = serde_json::to_vec(response).ok()?;
        let packed = super::transport::pack(&json, compress);
        FrameReader::frame(&seal::seal(&packed, key, device, Direction::Response))
    }

    fn audit(&self, action: &str, detail: &str) {
        if let Some(store) = &self.audit {
            store.audit(&format!("companion_{action}"), detail, "ok");
        }
    }

    async fn handle(&self, request: &CompanionRequest, device_id: &str, connection: Option<u64>) -> CompanionResponse {
        let backend = self.backend();
        let id = request.id.as_str();
        let fail = |e| CompanionResponse::failure(id, e);
        let with_sessions = |sessions: Vec<SessionDigest>| CompanionResponse { sessions: Some(sessions), ..CompanionResponse::success(id) };
        match request.op {
            CompanionOp::Hello | CompanionOp::List | CompanionOp::Subscribe => self.hello(id).await,
            CompanionOp::Watch | CompanionOp::WatchChat | CompanionOp::WatchConversation => {
                self.watch(request, device_id, connection).await
            }
            // The relay test and "Why can't I connect?" on the phone: the sealed round trip is the answer.
            CompanionOp::Ping => CompanionResponse::success(id),
            CompanionOp::BindKey => {
                use base64::Engine;
                let Some(public_key) = request
                    .text
                    .as_deref()
                    .and_then(|t| base64::engine::general_purpose::STANDARD.decode(t.as_bytes()).ok())
                    .filter(|k| device_key::is_valid_public_key(k))
                else {
                    return fail(CompanionError::BadRequest);
                };
                let bound = self.store.bind_key(device_id, &public_key);
                if bound {
                    self.audit("device_key", &self.store.device(device_id).map(|d| d.name).unwrap_or_default());
                }
                CompanionResponse { message: Some(if bound { "bound" } else { "other" }.into()), ..CompanionResponse::success(id) }
            }
            CompanionOp::Register if request.item.as_deref() == Some(relay_push::FCM) => {
                // Nook on Android: a Firebase token, whose pushes go through the relay (`RelayPushRequest.service`).
                let Some(token) = request.text.as_deref().filter(|t| relay_push::valid_fcm_token(t)) else {
                    return fail(CompanionError::BadRequest);
                };
                self.store.set_push(device_id, Some(token.to_string()), Some(true), Some(relay_push::FCM));
                self.audit("push_registered", &self.store.device(device_id).map(|d| d.name).unwrap_or_default());
                let ready = self.relay_push_endpoint().is_some() && self.store.push().enabled;
                CompanionResponse {
                    mac_name: Some(self.name.clone()),
                    message: Some(if ready { "push" } else { "nopush" }.into()),
                    ..CompanionResponse::success(id)
                }
            }
            CompanionOp::Register => {
                // Het token komt in een URL op Apple's host: alleen hex.
                let Some(token) = request.text.as_deref().filter(|t| push::valid_token(t)) else {
                    return fail(CompanionError::BadRequest);
                };
                self.store.set_push_token(device_id, Some(token.to_lowercase()), Some(request.item.as_deref() != Some("development")));
                self.audit("push_registered", &self.store.device(device_id).map(|d| d.name).unwrap_or_default());
                let ready = self.can_send_alerts() && self.store.push().enabled;
                CompanionResponse {
                    mac_name: Some(self.name.clone()),
                    message: Some(if ready { "push" } else { "nopush" }.into()),
                    ..CompanionResponse::success(id)
                }
            }
            CompanionOp::Unregister => {
                self.store.set_push_token(device_id, None, None);
                CompanionResponse::success(id)
            }
            CompanionOp::Decide => {
                let sessions = backend.sessions().await;
                let Some(session) = find(&sessions, request.session.as_deref()) else { return fail(CompanionError::UnknownSession) };
                let Some(item) =
                    session.digest.items.iter().find(|i| i.kind == ItemKind::Approval && Some(i.id.as_str()) == request.item.as_deref())
                else {
                    return fail(CompanionError::UnknownItem);
                };
                let allow = request.allow == Some(true);
                if allow && !item.can_allow {
                    return fail(CompanionError::NotAllowedFromPhone);
                }
                if backend.decide(&session.digest.id, &item.id, allow).await.is_err() {
                    return fail(CompanionError::Failed);
                }
                self.audit(if allow { "allow" } else { "deny" }, &format!("{} · {}", session.digest.title, item.detail));
                with_sessions(digests(backend.sessions().await))
            }
            CompanionOp::Answer => {
                let sessions = backend.sessions().await;
                let Some(session) = find(&sessions, request.session.as_deref()) else { return fail(CompanionError::UnknownSession) };
                let Some(item) =
                    session.digest.items.iter().find(|i| i.kind == ItemKind::Question && Some(i.id.as_str()) == request.item.as_deref())
                else {
                    return fail(CompanionError::UnknownItem);
                };
                // Een vraag met meerdere onderdelen beantwoord je op de computer.
                let Some(text) = CompanionPolicy::clean_message(request.text.as_deref().unwrap_or_default()).filter(|_| item.can_allow)
                else {
                    return fail(CompanionError::NotAllowedFromPhone);
                };
                // Een eigen antwoord alleen waar de agent dat accepteert; anders moet het een van de opties zijn.
                if !session.free_answers.contains(&item.id) && !item.options.contains(&text) {
                    return fail(CompanionError::BadRequest);
                }
                if backend.answer(&session.digest.id, &item.id, &text).await.is_err() {
                    return fail(CompanionError::Failed);
                }
                self.audit("answer", &session.digest.title);
                with_sessions(digests(backend.sessions().await))
            }
            CompanionOp::Send if request.steer == Some(true) || request.images.as_ref().is_some_and(|i| !i.is_empty()) => {
                let response = backend.extra(request, device_id).await.unwrap_or_else(|| fail(CompanionError::BadRequest));
                if response.ok {
                    self.audit(if request.steer == Some(true) { "steer" } else { "send" }, request.session.as_deref().unwrap_or_default());
                    self.nudge();
                }
                response
            }
            CompanionOp::Send => {
                let sessions = backend.sessions().await;
                let Some(session) = find(&sessions, request.session.as_deref()) else { return fail(CompanionError::UnknownSession) };
                let Some(text) = CompanionPolicy::clean_message(request.text.as_deref().unwrap_or_default()) else {
                    return fail(CompanionError::BadRequest);
                };
                if backend.send(&session.digest.id, &text).await.is_err() {
                    return fail(CompanionError::Failed);
                }
                self.audit("send", &session.digest.title);
                // A terminal session continues in Nook at once (`sessions::can_continue_in_nook`); only a run waits its turn.
                let queued = session.active && !session.digest.id.starts_with(super::sessions::HUB_PREFIX);
                CompanionResponse {
                    message: Some(if queued { "queued" } else { "sent" }.into()),
                    ..with_sessions(digests(backend.sessions().await))
                }
            }
            CompanionOp::Stop => {
                let sessions = backend.sessions().await;
                let Some(session) = find(&sessions, request.session.as_deref()) else { return fail(CompanionError::UnknownSession) };
                if backend.stop(&session.digest.id).await.is_err() {
                    return fail(CompanionError::Failed);
                }
                self.audit("stop", &session.digest.title);
                with_sessions(digests(backend.sessions().await))
            }
            // Everything else is the app's (`CompanionBackend::extra`); what it cannot do it does not list, so a phone
            // does not ask, and an answer that says so is better than closing the connection.
            _ => {
                let response = backend.extra(request, device_id).await.unwrap_or_else(|| fail(CompanionError::BadRequest));
                if response.ok && live::keeps(request.op) {
                    // Something changed: the live phones hear it at once.
                    self.nudge();
                }
                response
            }
        }
    }
}

// Live connections (`subscribe`, `watch`, `watchChat`, `watchConversation`)

impl CompanionServer {
    /// Something changed (an action from a phone, or the app says so): the live phones are looked at now.
    pub fn nudge(&self) {
        self.nudged.notify_one();
    }

    /// Whether a phone is connected live and in front, so a push about what its screen already shows can be left out
    /// (`ForegroundPolicy`).
    pub fn phone_in_front(&self, device: &str) -> bool {
        self.peers
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .any(|p| p.device == device && p.foreground && p.last_heard.elapsed() < std::time::Duration::from_secs(10))
    }

    /// How many phones are connected live (for keeping the computer awake).
    pub fn live_phones(&self) -> usize {
        self.peers.lock().unwrap_or_else(|e| e.into_inner()).len()
    }

    /// Tells a phone's live connections that it was removed (`revoked`), so it says "pair again" instead of looking
    /// for this computer forever. Must run before its key is forgotten.
    pub fn revoke(&self, device: &str) -> bool {
        let mut peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
        let mut told = false;
        for peer in peers.values_mut().filter(|p| p.device == device) {
            let mut update = peer.update();
            update.ok = false;
            update.error = Some(CompanionError::NotAllowedFromPhone);
            update.revoked = Some(true);
            told |= send_update(peer, &update);
        }
        peers.retain(|_, p| p.device != device);
        told
    }

    /// Changes what a paired phone may do and ends its live connections, so it connects again and learns what it may
    /// do now (`CompanionStore.setScopes`, `dropStreams`).
    pub fn set_scopes(&self, device: &str, granted: &scopes::Scopes) {
        self.store.set_scopes(device, granted);
        self.close_streams(device);
    }

    /// Ends a phone's live connections.
    fn close_streams(&self, device: &str) {
        let mut peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
        for peer in peers.values().filter(|p| p.device == device) {
            let _ = peer.tx.send(Vec::new());
        }
        peers.retain(|_, p| p.device != device);
    }

    /// Starts the task that sends the live phones what changed, unless it runs.
    fn ensure_ticker(&self) {
        let mut ticker = self.ticker.lock().unwrap_or_else(|e| e.into_inner());
        if ticker.as_ref().is_some_and(|t| !t.is_finished()) {
            return;
        }
        let (peers, backend, nudged) = (self.peers.clone(), self.backend.clone(), self.nudged.clone());
        let Ok(runtime) = tokio::runtime::Handle::try_current() else { return };
        *ticker = Some(runtime.spawn(tick(peers, backend, nudged)).abort_handle());
    }

    /// The phone opened a session, a chat or a Nook conversation (or closed it: none): from now on it follows over the
    /// live connection. Answered with what it shows now, which every later update builds on.
    async fn watch(&self, request: &CompanionRequest, device: &str, connection: Option<u64>) -> CompanionResponse {
        let id = request.id.as_str();
        let backend = self.backend();
        let set = |apply: &dyn Fn(&mut live::Peer)| {
            let mut peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
            let found =
                connection.filter(|c| peers.contains_key(c)).or_else(|| peers.iter().find(|(_, p)| p.device == device).map(|(k, _)| *k));
            if let Some(peer) = found.and_then(|k| peers.get_mut(&k)) {
                apply(peer);
            }
        };
        match request.op {
            CompanionOp::Watch => {
                let Some(session) = request.session.clone() else {
                    set(&|p| {
                        p.watch = None;
                        p.sent_timeline.clear();
                    });
                    return CompanionResponse::success(id);
                };
                let asked = CompanionRequest { op: CompanionOp::Timeline, item: None, ..request.clone() };
                let Some(answer) = backend.extra(&asked, device).await.filter(|r| r.ok) else {
                    return CompanionResponse::failure(id, CompanionError::UnknownSession);
                };
                let entries = array(&answer.timeline);
                set(&|p| {
                    p.watch = Some(session.clone());
                    p.sent_timeline = entries.clone();
                });
                if let Some((after, rest)) = live::resume_timeline(&entries, request.item.as_deref()) {
                    return CompanionResponse {
                        timeline: Some(Value::Array(rest)),
                        timeline_session: Some(session),
                        timeline_after: Some(after),
                        ..CompanionResponse::success(id)
                    };
                }
                CompanionResponse { timeline_session: Some(session), ..answer }
            }
            CompanionOp::WatchChat => {
                let Some(chat) = request.item.clone() else {
                    set(&|p| {
                        p.watch_chat = None;
                        p.sent_chat = None;
                    });
                    return CompanionResponse::success(id);
                };
                let asked = CompanionRequest { op: CompanionOp::InboxChat, ..request.clone() };
                let Some(answer) = backend.extra(&asked, device).await else {
                    return CompanionResponse::failure(id, CompanionError::BadRequest);
                };
                if answer.ok {
                    let lines = (answer.inbox_lines.clone().unwrap_or(Value::Null), answer.inbox_typing.clone().unwrap_or(Value::Null));
                    set(&|p| {
                        p.watch_chat = Some(chat.clone());
                        p.sent_chat = Some(lines.clone());
                    });
                }
                answer
            }
            _ => {
                let Some(conversation) = request.conversation.clone() else {
                    set(&|p| {
                        p.watch_conversation = None;
                        p.sent_messages = None;
                    });
                    return CompanionResponse::success(id);
                };
                let asked = CompanionRequest { op: CompanionOp::Chat, item: None, ..request.clone() };
                let Some(answer) = backend.extra(&asked, device).await else {
                    return CompanionResponse::failure(id, CompanionError::BadRequest);
                };
                if !answer.ok {
                    return answer;
                }
                let lines = array(&answer.messages);
                set(&|p| {
                    p.watch_conversation = Some(conversation.clone());
                    p.sent_messages = Some(lines.clone());
                });
                if let Some((after, rest)) = live::resume_conversation(&lines, request.item.as_deref()) {
                    return CompanionResponse {
                        messages: Some(Value::Array(rest)),
                        messages_conversation: Some(conversation),
                        messages_after: Some(after),
                        ..CompanionResponse::success(id)
                    };
                }
                CompanionResponse { messages_conversation: Some(conversation), ..answer }
            }
        }
    }
}

fn array(value: &Option<Value>) -> Vec<Value> {
    value.as_ref().and_then(Value::as_array).cloned().unwrap_or_default()
}

/// Seals `update` for `peer` and hands it to its writer; false when the connection is gone.
fn send_update(peer: &live::Peer, update: &CompanionResponse) -> bool {
    let update = scopes::redact(update.clone(), &peer.scopes);
    let Some(frame) = CompanionServer::seal_response(&update, &peer.key, &peer.device, peer.compression) else { return false };
    peer.pending.fetch_add(1, Ordering::SeqCst);
    peer.tx.send(frame).is_ok()
}

/// Looks for changes while a phone is connected live: at once when nudged or when the backend's generation moves, and
/// in full every `live::FULL_LOOK` (agents in a terminal and chats do not always say so). Ends when no phone is left.
async fn tick(
    peers: Arc<Mutex<HashMap<u64, live::Peer>>>,
    backend: Arc<RwLock<Arc<dyn CompanionBackend>>>,
    nudged: Arc<tokio::sync::Notify>,
) {
    let mut generation = u64::MAX;
    let mut last_full = std::time::Instant::now() - live::FULL_LOOK;
    loop {
        let woken = tokio::select! {
            _ = nudged.notified() => true,
            _ = tokio::time::sleep(live::TICK) => false,
        };
        let backend = backend.read().unwrap_or_else(|e| e.into_inner()).clone();
        let now_generation = backend.generation();
        let full = last_full.elapsed() >= live::FULL_LOOK;
        if !woken && !full && now_generation == generation {
            if peers.lock().unwrap_or_else(|e| e.into_inner()).is_empty() {
                return;
            }
            continue;
        }
        generation = now_generation;
        if full {
            last_full = std::time::Instant::now();
        }
        if !push_pass(&peers, &backend, full).await {
            return;
        }
        // At most a few passes a second while an agent streams: changes in between go in the next one.
        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
    }
}

/// One look: what changed for each live phone goes to it (`pushChanges`, `pushTimelines`, `pushChats`,
/// `pushConversations` on the Mac). False when no phone is connected live any more.
async fn push_pass(peers: &Mutex<HashMap<u64, live::Peer>>, backend: &Arc<dyn CompanionBackend>, full: bool) -> bool {
    struct Wants {
        device: String,
        watches: Vec<String>,
        chats: Vec<String>,
        conversations: Vec<String>,
    }
    let wants = {
        let mut peers = peers.lock().unwrap_or_else(|e| e.into_inner());
        // A phone that went quiet, or one that does not take what it is sent, is let go: it connects again and starts
        // from a fresh snapshot.
        peers.retain(|_, p| p.last_heard.elapsed() < live::STREAM_IDLE && p.backlog() < live::BACKLOG_DROP && !p.tx.is_closed());
        let Some(device) = peers.values().next().map(|p| p.device.clone()) else { return false };
        let mut w = Wants { device, watches: Vec::new(), chats: Vec::new(), conversations: Vec::new() };
        for p in peers.values() {
            if let Some(s) = &p.watch {
                if !w.watches.contains(s) {
                    w.watches.push(s.clone());
                }
            }
            if let Some(c) = &p.watch_chat {
                if !w.chats.contains(c) {
                    w.chats.push(c.clone());
                }
            }
            if let Some(c) = &p.watch_conversation {
                if !w.conversations.contains(c) {
                    w.conversations.push(c.clone());
                }
            }
        }
        w
    };
    let features = backend.features();
    let ask = |op: CompanionOp| CompanionRequest::new(op);
    let sessions = digests(backend.sessions().await);
    let mut timelines: HashMap<String, Vec<Value>> = HashMap::new();
    for session in &wants.watches {
        let request = CompanionRequest { session: Some(session.clone()), ..ask(CompanionOp::Timeline) };
        if let Some(answer) = backend.extra(&request, &wants.device).await.filter(|r| r.ok) {
            timelines.insert(session.clone(), array(&answer.timeline));
        }
    }
    let mut conversations: HashMap<String, Vec<Value>> = HashMap::new();
    for conversation in &wants.conversations {
        let request = CompanionRequest { conversation: Some(conversation.clone()), ..ask(CompanionOp::Chat) };
        if let Some(answer) = backend.extra(&request, &wants.device).await.filter(|r| r.ok) {
            conversations.insert(conversation.clone(), array(&answer.messages));
        }
    }
    let mut chat_lines: HashMap<String, (Value, Value)> = HashMap::new();
    let mut inbox: Option<(Value, Option<String>)> = None;
    let mut conversation_list: Option<Value> = None;
    if full && features.contains(&feature::INBOX) {
        for chat in &wants.chats {
            let request = CompanionRequest { item: Some(chat.clone()), ..ask(CompanionOp::InboxChat) };
            if let Some(answer) = backend.extra(&request, &wants.device).await.filter(|r| r.ok) {
                chat_lines.insert(chat.clone(), (answer.inbox_lines.unwrap_or(Value::Null), answer.inbox_typing.unwrap_or(Value::Null)));
            }
        }
        if let Some(answer) = backend.extra(&ask(CompanionOp::Inbox), &wants.device).await.filter(|r| r.ok) {
            inbox = answer.inbox.map(|list| (list, answer.message));
        }
    }
    if full && features.contains(&feature::CHAT) {
        if let Some(answer) = backend.extra(&ask(CompanionOp::Chats), &wants.device).await.filter(|r| r.ok) {
            conversation_list = answer.conversations;
        }
    }

    let mut peers = peers.lock().unwrap_or_else(|e| e.into_inner());
    for peer in peers.values_mut() {
        // Behind: nothing new until its connection took what waits; what it was not sent stays unsent, so the next
        // pass sends all that changed as one update (`StreamBackpressure`).
        if peer.backlog() > live::BACKLOG_WAIT {
            continue;
        }
        if peer.sent_sessions.as_ref() != Some(&sessions) {
            peer.sent_sessions = Some(sessions.clone());
            let update = CompanionResponse { sessions: Some(sessions.clone()), ..peer.update() };
            send_update(peer, &update);
        }
        if let Some(session) = peer.watch.clone() {
            if let Some(entries) = timelines.get(&session).filter(|e| **e != peer.sent_timeline) {
                let (after, rest) = live::delta(&peer.sent_timeline, entries);
                peer.sent_timeline = entries.clone();
                let update = CompanionResponse {
                    timeline: Some(Value::Array(if after.is_some() { rest } else { entries.clone() })),
                    timeline_session: Some(session),
                    timeline_after: after,
                    ..peer.update()
                };
                send_update(peer, &update);
            }
        }
        if let Some(conversation) = peer.watch_conversation.clone() {
            if let Some(lines) = conversations.get(&conversation).filter(|l| Some(*l) != peer.sent_messages.as_ref()) {
                let (after, rest) = live::delta(peer.sent_messages.as_deref().unwrap_or_default(), lines);
                peer.sent_messages = Some(lines.clone());
                let update = CompanionResponse {
                    messages: Some(Value::Array(if after.is_some() { rest } else { lines.clone() })),
                    messages_conversation: Some(conversation),
                    messages_after: after,
                    ..peer.update()
                };
                send_update(peer, &update);
            }
        }
        let mut update = CompanionResponse::success(&peer.stream_id);
        let mut changed = false;
        if let Some((list, message)) = &inbox {
            if peer.sent_inbox.as_ref() != Some(list) {
                // The first look after subscribing only takes note: the phone asks for the inbox itself then.
                if peer.sent_inbox.is_some() {
                    update.inbox = Some(list.clone());
                    update.message = message.clone();
                    changed = true;
                }
                peer.sent_inbox = Some(list.clone());
            }
        }
        if let Some(chat) = peer.watch_chat.clone() {
            if let Some(lines) = chat_lines.get(&chat).filter(|l| Some(*l) != peer.sent_chat.as_ref()) {
                update.inbox_lines = Some(lines.0.clone());
                update.inbox_typing = Some(lines.1.clone());
                update.inbox_chat = Some(chat);
                peer.sent_chat = Some(lines.clone());
                changed = true;
            }
        }
        if let Some(list) = &conversation_list {
            if peer.sent_conversations.as_ref() != Some(list) {
                if peer.sent_conversations.is_some() {
                    update.conversations = Some(list.clone());
                    changed = true;
                }
                peer.sent_conversations = Some(list.clone());
            }
        }
        if changed {
            let numbered = peer.update();
            update.seq = numbered.seq;
            send_update(peer, &update);
        }
    }
    !peers.is_empty()
}

// Pushmeldingen (`CompanionNotifier.swift`)

impl CompanionServer {
    /// Een gebeurtenis in de werkruimte (toestemming nodig, een vraag, een klare of mislukte beurt) als melding naar de
    /// gekoppelde iPhones, binnen de regels van de gebruiker. `turn` maakt een klare beurt uniek (bv. de tijd van de
    /// laatste wijziging); `away` = de gebruiker is niet bij de computer. Geeft de reden terug als er niets ging.
    pub async fn notify(&self, event: push::PushEvent, turn: i64, away: bool) -> Option<push::PushSkip> {
        let settings = self.store.push();
        if !self.store.enabled() || !self.can_send_alerts() {
            return Some(push::PushSkip::Disabled);
        }
        let targets: Vec<PairedDevice> = self.store.devices().into_iter().filter(|d| d.push_token.is_some()).collect();
        if targets.is_empty() {
            return Some(push::PushSkip::NoDevices);
        }
        if let Some(skip) = push::skip_reason(&event, &settings, away, push::local_hour()) {
            return Some(skip);
        }
        if !self.ledger.lock().unwrap_or_else(|e| e.into_inner()).admit(&event, turn) {
            return Some(push::PushSkip::Duplicate);
        }
        self.deliver(&event, turn, &targets, false).await;
        None
    }

    /// Een testmelding naar elke gekoppelde telefoon, zonder de regels, om sleutel en instellingen te controleren.
    pub async fn send_test(&self) -> String {
        let event = push::PushEvent {
            kind: push::PushKind::Finished,
            session: "test".into(),
            item: None,
            agent: "Nook".into(),
            title: String::new(),
            can_allow: false,
        };
        let targets: Vec<PairedDevice> = self.store.devices().into_iter().filter(|d| d.push_token.is_some()).collect();
        if targets.is_empty() {
            return "Nog geen telefoon die meldingen toestaat.".into();
        }
        self.deliver(&event, Utc::now().timestamp(), &targets, true).await;
        self.last_push().unwrap_or_default()
    }

    fn words(&self, event: &push::PushEvent, test: bool) -> (String, String) {
        if test {
            return ("Nook".into(), "Testmelding: de pushmeldingen werken.".into());
        }
        let title = if self.store.push().include_title && !event.title.is_empty() {
            format!("{} · {}", event.agent, event.title)
        } else {
            event.agent.clone()
        };
        let body = match event.kind {
            push::PushKind::Approval => "Wacht op jouw toestemming.",
            push::PushKind::Question => "Heeft een vraag voor je.",
            push::PushKind::Failed => "Is mislukt.",
            push::PushKind::Limited => "Heeft de limiet bereikt.",
            push::PushKind::Finished => "Is klaar.",
        };
        (title, body.into())
    }

    async fn deliver(&self, event: &push::PushEvent, turn: i64, devices: &[PairedDevice], test: bool) {
        let pem = self.store.apns_pem();
        let (key_id, team_id) = self.store.apns_ids();
        let (title, body) = self.words(event, test);
        let badge = digests(self.backend().sessions().await).iter().filter(|s| !s.items.is_empty()).count() as i64;
        let collapse = push::collapse_id(event, turn);
        // Through the relay the text is sealed for each phone; Apple, Google and the relay see only "Nook needs you".
        let endpoint = self.relay_push_endpoint();
        let through_relay = self.relay_push_active();
        let mut summary = Vec::new();
        for device in devices {
            let Some(token) = &device.push_token else { continue };
            let production = device.push_production.unwrap_or(true);
            // An Android phone (Firebase) is reached only through the relay, whatever the route for iPhones is.
            let android = device.push_service.as_deref() == Some(relay_push::FCM);
            let result = match (&endpoint, android || through_relay) {
                (None, true) if android => {
                    summary.push(format!(
                        "{}: {}",
                        device.name,
                        crate::i18n::tr(
                            "Android heeft een relay nodig (Instellingen › Companion › Altijd bereikbaar)",
                            "Android needs a relay (Settings › Companion › Always reachable)"
                        )
                    ));
                    continue;
                }
                (Some(url), true) => self.send_through_relay(url, event, &title, &body, badge, device, token, production, &collapse).await,
                _ => match &pem {
                    Some(pem) => {
                        // Each phone is told which of its pairings this is (`mac`), so its buttons reach this computer.
                        let mut payload = push::apns_payload(event, &title, &body, badge);
                        payload["nook"]["mac"] = serde_json::json!(device.id);
                        self.apns.send(pem, &key_id, &team_id, &payload, token, production, &collapse).await
                    }
                    None => super::apns::ApnsResult {
                        outcome: push::Outcome::Configuration,
                        status: 0,
                        reason: Some(crate::i18n::tr("niet ingesteld", "not set up").into()),
                    },
                },
            };
            summary.push(match result.outcome {
                push::Outcome::Delivered => format!("{}: ok", device.name),
                push::Outcome::DropToken => {
                    self.store.set_push_token(&device.id, None, None);
                    format!("{}: toestel meldt zich af; open de app om opnieuw te registreren", device.name)
                }
                push::Outcome::RetryLater => format!("{}: Apple is bezet, later opnieuw", device.name),
                push::Outcome::Configuration => {
                    format!("{}: {}", device.name, result.reason.unwrap_or_else(|| result.status.to_string()))
                }
            });
        }
        let summary = summary.join(" · ");
        if let Some(store) = &self.audit {
            let tool = if test { "companion_push_test" } else { "companion_push" };
            store.audit(tool, &format!("{} · {}", event.kind.raw(), devices.len()), &summary);
        }
        *self.last_push.lock().unwrap_or_else(|e| e.into_inner()) = Some(summary);
    }

    /// Seals the notification for `device` and posts it to the relay (`RelayPushClient.send`).
    #[allow(clippy::too_many_arguments)]
    async fn send_through_relay(
        &self,
        url: &str,
        event: &push::PushEvent,
        title: &str,
        body: &str,
        badge: i64,
        device: &PairedDevice,
        token: &str,
        production: bool,
        collapse: &str,
    ) -> super::apns::ApnsResult {
        let failed =
            |reason: &str| super::apns::ApnsResult { outcome: push::Outcome::Configuration, status: 0, reason: Some(reason.into()) };
        let Some(key) = self.store.key(&device.id) else { return failed("no key") };
        let content = relay_push::RelayPushContent::new(
            title,
            body,
            push::push_category(event),
            &event.session,
            &event.session,
            event.item.as_deref(),
            badge,
            Some(&device.id),
        );
        let envelope = relay_push::seal(&content, &key, &device.id);
        let hidden = relay_push::collapse_id(collapse, &relay_push::push_key(&key));
        let room = super::transport::relay_room(&key);
        let Some(request) = relay_push::request(
            &envelope,
            &room,
            token,
            production,
            Some(hidden),
            push::is_urgent(event.kind),
            device.push_service.as_deref(),
        ) else {
            return failed("could not seal");
        };
        let (outcome, status, reason) = relay_push::post(&self.relay_http, url, &request).await;
        super::apns::ApnsResult { outcome, status, reason }
    }
}

fn find<'a>(sessions: &'a [BackendSession], id: Option<&str>) -> Option<&'a BackendSession> {
    let id = id?;
    sessions.iter().find(|s| s.digest.id == id)
}

/// Nieuwste eerst, hoogstens 25, teksten ingekort.
pub fn digests(sessions: Vec<BackendSession>) -> Vec<SessionDigest> {
    let mut list: Vec<SessionDigest> = sessions.into_iter().map(|s| s.digest).collect();
    list.sort_by(|a, b| b.updated.partial_cmp(&a.updated).unwrap_or(std::cmp::Ordering::Equal));
    list.truncate(MAX_SESSIONS);
    for s in &mut list {
        s.title = CompanionPolicy::excerpt(&s.title);
        s.excerpt = CompanionPolicy::excerpt(&s.excerpt);
        for item in &mut s.items {
            item.title = CompanionPolicy::excerpt(&item.title);
            item.detail = CompanionPolicy::excerpt(&item.detail);
        }
    }
    list
}
