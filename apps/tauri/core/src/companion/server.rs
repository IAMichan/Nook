//! De computerkant van de companion (`CompanionServer.swift`): een TCP-luisteraar die verzegelde aanvragen van
//! gekoppelde telefoons beantwoordt. Zonder koppelsleutel is niets leesbaar, oude, herhaalde of te snelle aanvragen
//! worden geweigerd, en wat een telefoon mag begrenst [`CompanionPolicy`]. Elke actie staat in het auditlogboek.
//! De aankondiging op het netwerk (mDNS/Bonjour) doet de app.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use chrono::Utc;
use serde::Serialize;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use super::backend::{BackendSession, CompanionBackend};
use super::models::*;
use super::push;
use super::seal::{self, Direction};
use super::store::CompanionStore;
use crate::store::NookStore;

const MAX_CONNECTIONS: usize = 8;
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
    backend: RwLock<Arc<dyn CompanionBackend>>,
    audit: Option<Arc<NookStore>>,
    /// De naam die de telefoon ziet ("Michaels pc").
    name: String,
    apns: super::apns::ApnsClient,
    ledger: Mutex<push::PushLedger>,
    /// Hoe de laatste melding afliep, per toestel; voor Instellingen.
    last_push: Mutex<Option<String>>,
    guards: Mutex<HashMap<String, RequestGuard>>,
    state: Mutex<ServerState>,
    task: Mutex<Option<tokio::task::AbortHandle>>,
    open: Arc<AtomicUsize>,
}

impl CompanionServer {
    pub fn new(store: Arc<CompanionStore>, backend: Arc<dyn CompanionBackend>, audit: Option<Arc<NookStore>>, name: String) -> Self {
        Self {
            store,
            backend: RwLock::new(backend),
            audit,
            name,
            apns: Default::default(),
            ledger: Mutex::new(Default::default()),
            last_push: Mutex::new(None),
            guards: Mutex::new(HashMap::new()),
            state: Mutex::new(ServerState::Stopped),
            task: Mutex::new(None),
            open: Arc::new(AtomicUsize::new(0)),
        }
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
                    let _ = tokio::time::timeout(CONNECTION_DEADLINE, conn.serve(stream)).await;
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
        Some(PairingLink { host: host.into(), port, key, mac_name: self.name.clone() })
    }

    async fn serve(&self, mut stream: TcpStream) {
        let mut reader = FrameReader::default();
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            let n = match stream.read(&mut buf).await {
                Ok(0) | Err(_) => return,
                Ok(n) => n,
            };
            let frames = reader.feed(&buf[..n]);
            if reader.overflowed() {
                return;
            }
            for frame in frames {
                match self.respond(&frame).await {
                    Some(reply) => {
                        if stream.write_all(&reply).await.is_err() {
                            return;
                        }
                    }
                    None => return,
                }
            }
        }
    }

    /// Het antwoord op één frame, al verzegeld en ingelijst; `None` = verbinding sluiten.
    pub async fn respond(&self, frame: &[u8]) -> Option<Vec<u8>> {
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
        let request: CompanionRequest = serde_json::from_slice(&plain).ok()?;
        let sealed = |response: CompanionResponse| {
            let json = serde_json::to_vec(&response).ok()?;
            FrameReader::frame(&seal::seal(&json, &key, &claimed, Direction::Response))
        };

        // De bewaker hoort bij het toestel: een herhaald id of een stortvloed wordt vanaf hier geweigerd.
        let refusal = {
            let mut guards = self.guards.lock().unwrap_or_else(|e| e.into_inner());
            guards.entry(claimed.clone()).or_default().admit(&request, now.timestamp_millis() as f64 / 1000.0)
        };
        if let Some(error) = refusal {
            return sealed(CompanionResponse::failure(&request.id, error));
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
        sealed(self.handle(&request, &claimed).await)
    }

    fn audit(&self, action: &str, detail: &str) {
        if let Some(store) = &self.audit {
            store.audit(&format!("companion_{action}"), detail, "ok");
        }
    }

    async fn handle(&self, request: &CompanionRequest, device_id: &str) -> CompanionResponse {
        let backend = self.backend();
        let id = request.id.as_str();
        let fail = |e| CompanionResponse::failure(id, e);
        let with_sessions = |sessions: Vec<SessionDigest>| CompanionResponse { sessions: Some(sessions), ..CompanionResponse::success(id) };
        match request.op {
            CompanionOp::Hello | CompanionOp::List => {
                let sessions = digests(backend.sessions().await);
                CompanionResponse { mac_name: Some(self.name.clone()), ..with_sessions(sessions) }
            }
            CompanionOp::Register => {
                // Het token komt in een URL op Apple's host: alleen hex.
                let Some(token) = request.text.as_deref().filter(|t| push::valid_token(t)) else {
                    return fail(CompanionError::BadRequest);
                };
                self.store.set_push_token(device_id, Some(token.to_lowercase()), Some(request.item.as_deref() != Some("development")));
                self.audit("push_registered", &self.store.device(device_id).map(|d| d.name).unwrap_or_default());
                let ready = self.store.can_push() && self.store.push().enabled;
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
                CompanionResponse {
                    message: Some(if session.active { "queued" } else { "sent" }.into()),
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
        }
    }
}

// Pushmeldingen (`CompanionNotifier.swift`)

impl CompanionServer {
    /// Een gebeurtenis in de werkruimte (toestemming nodig, een vraag, een klare of mislukte beurt) als melding naar de
    /// gekoppelde iPhones, binnen de regels van de gebruiker. `turn` maakt een klare beurt uniek (bv. de tijd van de
    /// laatste wijziging); `away` = de gebruiker is niet bij de computer. Geeft de reden terug als er niets ging.
    pub async fn notify(&self, event: push::PushEvent, turn: i64, away: bool) -> Option<push::PushSkip> {
        let settings = self.store.push();
        if !self.store.enabled() || !self.store.can_push() {
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
        let Some(pem) = self.store.apns_pem() else { return };
        let (key_id, team_id) = self.store.apns_ids();
        let (title, body) = self.words(event, test);
        let badge = digests(self.backend().sessions().await).iter().filter(|s| !s.items.is_empty()).count() as i64;
        let payload = push::apns_payload(event, &title, &body, badge);
        let collapse = push::collapse_id(event, turn);
        let mut summary = Vec::new();
        for device in devices {
            let Some(token) = &device.push_token else { continue };
            let production = device.push_production.unwrap_or(true);
            let result = self.apns.send(&pem, &key_id, &team_id, &payload, token, production, &collapse).await;
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
