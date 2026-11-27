//! Live relay connections and held messages for shared sessions (`GuestShares.swift` on the Mac, AG-81).
//! Each shared session keeps one outgoing WebSocket to the relay in its own derived room (`guest_link::room`).
//! Views are pushed to connected guests at most twice per second and only when the timeline or run state changed.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use futures_util::{SinkExt, StreamExt};
use rand::TryRng;
use serde::Serialize;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use uuid::Uuid;

use crate::companion::relay::{host_socket, mux_decode, mux_encode, retry_delay, MuxKind};

use super::guest_link::{self, GuestHold, GuestMessage, GuestShare, GuestSlices, HeldMessage, Outgoing, Refusal, SliceOutcome};
use super::manager::Manager;

/// Keychain account name where live `Vec<GuestShare>` JSON is stored across launches.
pub const SHARES_SECRET_ACCOUNT: &str = "guest.shares";

const KEEP_ALIVE: Duration = Duration::from_secs(30);
const SILENCE_LIMIT: Duration = Duration::from_secs(75);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const PUSH_DEBOUNCE: Duration = Duration::from_millis(500);

pub type RelayUrlFn = Box<dyn Fn() -> Option<String> + Send + Sync>;
pub type ReadSecretFn = Box<dyn Fn(&str) -> Option<String> + Send + Sync>;
pub type WriteSecretFn = Box<dyn Fn(&str, &str) + Send + Sync>;
pub type RemoveSecretFn = Box<dyn Fn(&str) + Send + Sync>;
pub type ChangeNotifyFn = Box<dyn Fn() + Send + Sync>;

/// Host callbacks decoupling `GuestShares` in `nook-core` from Tauri / keychain / event emitter details.
pub struct GuestSharesCallbacks {
    pub relay_url: RelayUrlFn,
    pub read_secret: ReadSecretFn,
    pub write_secret: WriteSecretFn,
    pub remove_secret: RemoveSecretFn,
    pub on_change: ChangeNotifyFn,
}

/// Snapshot of one active guest share, sent to the UI.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GuestShareInfo {
    pub until: DateTime<Utc>,
    pub link: String,
    pub watching: usize,
    pub held: Vec<HeldMessage>,
}

/// Snapshot of all active guest shares plus whether a relay is configured.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GuestSharesSnapshot {
    pub can_share: bool,
    pub shares: HashMap<Uuid, GuestShareInfo>,
}

struct LinkInner {
    peers: HashSet<u32>,
    slices: GuestSlices,
    hold: GuestHold,
    last_sent: Vec<u8>,
    outbound: Option<mpsc::UnboundedSender<Message>>,
    socket_task: Option<tokio::task::AbortHandle>,
    expiry_task: Option<tokio::task::AbortHandle>,
}

struct LinkState {
    share: GuestShare,
    inner: Mutex<LinkInner>,
    push_scheduled: AtomicBool,
}

impl LinkState {
    fn new(share: GuestShare) -> Self {
        Self {
            share,
            inner: Mutex::new(LinkInner {
                peers: HashSet::new(),
                slices: GuestSlices::default(),
                hold: GuestHold::default(),
                last_sent: Vec::new(),
                outbound: None,
                socket_task: None,
                expiry_task: None,
            }),
            push_scheduled: AtomicBool::new(false),
        }
    }
}

pub struct GuestShares {
    manager: Arc<Manager>,
    runtime: tokio::runtime::Handle,
    files_dir: PathBuf,
    callbacks: GuestSharesCallbacks,
    links: Mutex<HashMap<Uuid, Arc<LinkState>>>,
}

impl GuestShares {
    pub fn new(manager: Arc<Manager>, runtime: tokio::runtime::Handle, files_dir: PathBuf, callbacks: GuestSharesCallbacks) -> Arc<Self> {
        Arc::new(Self { manager, runtime, files_dir, callbacks, links: Mutex::new(HashMap::new()) })
    }

    /// At launch: cleans any stale guest-files folder and reopens persisted shares that are still live.
    pub fn start(self: &Arc<Self>) {
        let _ = std::fs::remove_dir_all(&self.files_dir);
        let saved: Vec<GuestShare> =
            (self.callbacks.read_secret)(SHARES_SECRET_ACCOUNT).and_then(|raw| serde_json::from_str(&raw).ok()).unwrap_or_default();
        let live = GuestShare::live(&saved, Utc::now());
        if live != saved {
            self.persist_shares(&live);
        }
        for share in live {
            if self.manager.run(share.run_id).is_some_and(|r| !r.archived) {
                self.open(share);
            }
        }
    }

    pub fn can_share(&self) -> bool {
        (self.callbacks.relay_url)().is_some()
    }

    pub fn link(&self, run_id: Uuid) -> Option<String> {
        let relay = (self.callbacks.relay_url)()?;
        let links = self.links.lock().unwrap_or_else(|e| e.into_inner());
        let link = links.get(&run_id)?;
        guest_link::url(&relay, &link.share.key)
    }

    /// Starts sharing `run_id` (or returns the existing live link).
    pub fn share(self: &Arc<Self>, run_id: Uuid) -> Result<String, String> {
        if let Some(existing) = self.link(run_id) {
            return Ok(existing);
        }
        let Some(relay) = (self.callbacks.relay_url)() else {
            return Err("No relay is configured for guest links.".into());
        };
        let Some(run) = self.manager.run(run_id) else {
            return Err("This session no longer exists.".into());
        };
        if run.archived {
            return Err("Archived sessions cannot be shared.".into());
        }
        let share = GuestShare::new(run_id, guest_link::new_key().to_vec(), Utc::now());
        let url = guest_link::url(&relay, &share.key).ok_or_else(|| "Invalid relay address.".to_string())?;
        self.open(share);
        self.persist();
        (self.callbacks.on_change)();
        Ok(url)
    }

    /// Stops sharing `run_id`: notifies connected guests, removes held messages and their files, and updates keychain.
    pub fn stop(self: &Arc<Self>, run_id: Uuid) {
        let removed = {
            let mut links = self.links.lock().unwrap_or_else(|e| e.into_inner());
            links.remove(&run_id)
        };
        let Some(link) = removed else { return };
        let (peers, outbound, held, socket_task, expiry_task) = {
            let mut inner = link.inner.lock().unwrap_or_else(|e| e.into_inner());
            let peers: Vec<u32> = inner.peers.drain().collect();
            let outbound = inner.outbound.take();
            let held = inner.hold.take_all();
            let socket_task = inner.socket_task.take();
            let expiry_task = inner.expiry_task.take();
            (peers, outbound, held, socket_task, expiry_task)
        };
        if let Some(tx) = outbound {
            Self::send_outgoing(&Outgoing::ended(), &link.share.key, &tx, &peers);
        }
        if let Some(expiry) = expiry_task {
            expiry.abort();
        }
        if let Some(socket) = socket_task {
            // Brief grace window so the `ended` frame flushes before the socket closes.
            self.runtime.spawn(async move {
                tokio::time::sleep(Duration::from_millis(500)).await;
                socket.abort();
            });
        }
        for message in held {
            remove_files(&message);
        }
        self.persist();
        (self.callbacks.on_change)();
    }

    /// On shutdown: aborts sockets and timers while leaving persisted shares intact for next launch.
    pub fn suspend(&self) {
        let links = self.links.lock().unwrap_or_else(|e| e.into_inner());
        for link in links.values() {
            let mut inner = link.inner.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(t) = inner.socket_task.take() {
                t.abort();
            }
            if let Some(t) = inner.expiry_task.take() {
                t.abort();
            }
            inner.outbound = None;
            inner.peers.clear();
        }
    }

    /// Sends a held guest message to the session as your next prompt (with its saved files attached).
    pub fn send_held(self: &Arc<Self>, run_id: Uuid, message_id: &str) -> Result<(), String> {
        let link = {
            let links = self.links.lock().unwrap_or_else(|e| e.into_inner());
            links.get(&run_id).cloned()
        };
        let Some(link) = link else { return Err("Sharing has stopped for this session.".into()) };
        let taken = {
            let mut inner = link.inner.lock().unwrap_or_else(|e| e.into_inner());
            inner.hold.take(message_id)
        };
        let Some(taken) = taken else { return Ok(()) };
        let framed = guest_link::framed(&taken.text, &taken.files);
        self.manager.send(run_id, &framed)?;
        self.schedule_push(run_id);
        (self.callbacks.on_change)();
        Ok(())
    }

    /// Dismisses a held guest message and deletes its saved files.
    pub fn dismiss_held(self: &Arc<Self>, run_id: Uuid, message_id: &str) {
        let link = {
            let links = self.links.lock().unwrap_or_else(|e| e.into_inner());
            links.get(&run_id).cloned()
        };
        let Some(link) = link else { return };
        let taken = {
            let mut inner = link.inner.lock().unwrap_or_else(|e| e.into_inner());
            inner.hold.take(message_id)
        };
        if let Some(taken) = taken {
            remove_files(&taken);
            self.schedule_push(run_id);
            (self.callbacks.on_change)();
        }
    }

    /// Called when `run_id`'s timeline changed.
    pub fn notify_timeline(self: &Arc<Self>, run_id: Uuid) {
        self.schedule_push(run_id);
    }

    /// Called when workspace runs changed (status/title/archive/delete).
    pub fn notify_changed(self: &Arc<Self>) {
        let ids: Vec<Uuid> = self.links.lock().unwrap_or_else(|e| e.into_inner()).keys().copied().collect();
        for id in ids {
            match self.manager.run(id) {
                Some(run) if !run.archived => self.schedule_push(id),
                _ => self.stop(id),
            }
        }
    }

    pub fn snapshot(&self) -> GuestSharesSnapshot {
        let relay = (self.callbacks.relay_url)();
        let can_share = relay.is_some();
        let links = self.links.lock().unwrap_or_else(|e| e.into_inner());
        let mut shares = HashMap::new();
        for (&run_id, link) in links.iter() {
            let inner = link.inner.lock().unwrap_or_else(|e| e.into_inner());
            let url = relay.as_deref().and_then(|r| guest_link::url(r, &link.share.key)).unwrap_or_default();
            shares.insert(
                run_id,
                GuestShareInfo { until: link.share.until, link: url, watching: inner.peers.len(), held: inner.hold.messages().to_vec() },
            );
        }
        GuestSharesSnapshot { can_share, shares }
    }

    // MARK: Internals

    fn open(self: &Arc<Self>, share: GuestShare) {
        let Some(relay) = (self.callbacks.relay_url)() else { return };
        let Some(ws_url) = host_socket(&relay, &share.room()) else { return };
        let run_id = share.run_id;
        let wait_secs = (share.until - Utc::now()).num_seconds().max(0) as u64;
        let link = Arc::new(LinkState::new(share));
        {
            let mut links = self.links.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(prev) = links.insert(run_id, link.clone()) {
                let mut inner = prev.inner.lock().unwrap_or_else(|e| e.into_inner());
                if let Some(t) = inner.socket_task.take() {
                    t.abort();
                }
                if let Some(t) = inner.expiry_task.take() {
                    t.abort();
                }
            }
        }
        let this = Arc::clone(self);
        let link_for_socket = Arc::clone(&link);
        let socket_handle = self.runtime.spawn(async move {
            this.run_socket(run_id, link_for_socket, ws_url).await;
        });
        let this_exp = Arc::clone(self);
        let expiry_handle = self.runtime.spawn(async move {
            tokio::time::sleep(Duration::from_secs(wait_secs)).await;
            this_exp.stop(run_id);
        });
        let mut inner = link.inner.lock().unwrap_or_else(|e| e.into_inner());
        inner.socket_task = Some(socket_handle.abort_handle());
        inner.expiry_task = Some(expiry_handle.abort_handle());
    }

    async fn run_socket(self: Arc<Self>, run_id: Uuid, link: Arc<LinkState>, ws_url: String) {
        let mut failures = 0u32;
        while link.share.is_live(Utc::now()) {
            let since = Instant::now();
            if let Ok(Ok((ws, _))) = tokio::time::timeout(CONNECT_TIMEOUT, tokio_tungstenite::connect_async(ws_url.as_str())).await {
                self.serve_socket(run_id, &link, ws).await;
            }
            {
                let mut inner = link.inner.lock().unwrap_or_else(|e| e.into_inner());
                inner.outbound = None;
                let had_peers = !inner.peers.is_empty();
                inner.peers.clear();
                if had_peers {
                    drop(inner);
                    (self.callbacks.on_change)();
                }
            }
            if !link.share.is_live(Utc::now()) {
                break;
            }
            failures = if since.elapsed() >= Duration::from_secs(30) { 1 } else { failures + 1 };
            let mut byte = [0u8; 1];
            let random = rand::rngs::SysRng.try_fill_bytes(&mut byte).map(|_| f64::from(byte[0]) / 255.0).unwrap_or(0.5);
            tokio::time::sleep(retry_delay(failures, random)).await;
        }
    }

    async fn serve_socket(
        &self,
        run_id: Uuid,
        link: &Arc<LinkState>,
        ws: tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    ) {
        let (mut sink, mut stream) = ws.split();
        let (out_tx, mut out_rx) = mpsc::unbounded_channel::<Message>();
        let writer = tokio::spawn(async move {
            while let Some(msg) = out_rx.recv().await {
                if sink.send(msg).await.is_err() {
                    return;
                }
            }
        });
        {
            let mut inner = link.inner.lock().unwrap_or_else(|e| e.into_inner());
            inner.outbound = Some(out_tx.clone());
            inner.peers.clear();
        }
        let _ = out_tx.send(Message::Text("ping".into()));
        let mut ping_interval = tokio::time::interval(KEEP_ALIVE);
        ping_interval.tick().await;
        let mut last_heard = Instant::now();

        loop {
            tokio::select! {
                _ = ping_interval.tick() => {
                    if last_heard.elapsed() >= SILENCE_LIMIT {
                        break;
                    }
                    if out_tx.send(Message::Text("ping".into())).is_err() {
                        break;
                    }
                }
                next = stream.next() => {
                    match next {
                        Some(Ok(Message::Binary(bytes))) => {
                            last_heard = Instant::now();
                            if let Some((kind, conn, payload)) = mux_decode(&bytes) {
                                self.handle_frame(run_id, link, kind, conn, payload, &out_tx);
                            }
                        }
                        Some(Ok(Message::Text(_))) | Some(Ok(Message::Pong(_))) => {
                            last_heard = Instant::now();
                        }
                        Some(Ok(Message::Ping(p))) => {
                            last_heard = Instant::now();
                            let _ = out_tx.send(Message::Pong(p));
                        }
                        Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                        Some(Ok(Message::Frame(_))) => {}
                    }
                }
            }
        }
        writer.abort();
    }

    fn handle_frame(
        &self,
        run_id: Uuid,
        link: &Arc<LinkState>,
        kind: MuxKind,
        conn: u32,
        payload: &[u8],
        tx: &mpsc::UnboundedSender<Message>,
    ) {
        match kind {
            MuxKind::Open => {
                {
                    let mut inner = link.inner.lock().unwrap_or_else(|e| e.into_inner());
                    inner.peers.insert(conn);
                    inner.last_sent.clear();
                }
                (self.callbacks.on_change)();
                self.push_to(run_id, link, &[conn], false);
            }
            MuxKind::Close => {
                let changed = {
                    let mut inner = link.inner.lock().unwrap_or_else(|e| e.into_inner());
                    inner.peers.remove(&conn)
                };
                if changed {
                    (self.callbacks.on_change)();
                }
            }
            MuxKind::Data => {
                if !link.share.is_live(Utc::now()) {
                    return;
                }
                let Some(plain) = guest_link::open(payload, &link.share.key) else { return };
                let outcome = {
                    let mut inner = link.inner.lock().unwrap_or_else(|e| e.into_inner());
                    inner.slices.add(&plain, Utc::now())
                };
                match outcome {
                    SliceOutcome::Waiting => {}
                    SliceOutcome::Refused { id: Some(msg_id), refusal } => {
                        Self::send_outgoing(&Outgoing::ack(msg_id, Some(refusal)), &link.share.key, tx, &[conn]);
                    }
                    SliceOutcome::Refused { id: None, .. } => {}
                    SliceOutcome::Complete { id: msg_id, json } => {
                        self.take_message(run_id, link, &msg_id, &json, conn, tx);
                    }
                }
            }
        }
    }

    fn take_message(&self, run_id: Uuid, link: &Arc<LinkState>, msg_id: &str, json: &[u8], conn: u32, tx: &mpsc::UnboundedSender<Message>) {
        let parsed = match guest_link::parse_message(msg_id, json) {
            Ok(m) => m,
            Err(refusal) => {
                Self::send_outgoing(&Outgoing::ack(msg_id, Some(refusal)), &link.share.key, tx, &[conn]);
                return;
            }
        };
        {
            let inner = link.inner.lock().unwrap_or_else(|e| e.into_inner());
            if inner.hold.has_seen(msg_id) {
                Self::send_outgoing(&Outgoing::ack(msg_id, None), &link.share.key, tx, &[conn]);
                return;
            }
            if let Some(refusal) = inner.hold.refusal_for_bytes(parsed.bytes()) {
                Self::send_outgoing(&Outgoing::ack(msg_id, Some(refusal)), &link.share.key, tx, &[conn]);
                return;
            }
        }
        let Some(saved_files) = save_files(&self.files_dir, &parsed, run_id) else {
            Self::send_outgoing(&Outgoing::ack(msg_id, Some(Refusal::Malformed)), &link.share.key, tx, &[conn]);
            return;
        };
        {
            let bytes = parsed.bytes();
            let mut inner = link.inner.lock().unwrap_or_else(|e| e.into_inner());
            inner.hold.add(
                HeldMessage { id: Uuid::new_v4().to_string(), text: parsed.text, files: saved_files, bytes, received: Utc::now() },
                Some(msg_id),
            );
        }
        Self::send_outgoing(&Outgoing::ack(msg_id, None), &link.share.key, tx, &[conn]);
        (self.callbacks.on_change)();
        let peers: Vec<u32> = link.inner.lock().unwrap_or_else(|e| e.into_inner()).peers.iter().copied().collect();
        self.push_to(run_id, link, &peers, true);
    }

    fn schedule_push(self: &Arc<Self>, run_id: Uuid) {
        let link = {
            let links = self.links.lock().unwrap_or_else(|e| e.into_inner());
            links.get(&run_id).cloned()
        };
        let Some(link) = link else { return };
        if link.inner.lock().unwrap_or_else(|e| e.into_inner()).peers.is_empty() {
            return;
        }
        if link.push_scheduled.swap(true, Ordering::SeqCst) {
            return;
        }
        let this = Arc::clone(self);
        self.runtime.spawn(async move {
            tokio::time::sleep(PUSH_DEBOUNCE).await;
            link.push_scheduled.store(false, Ordering::SeqCst);
            let peers: Vec<u32> = link.inner.lock().unwrap_or_else(|e| e.into_inner()).peers.iter().copied().collect();
            if !peers.is_empty() {
                this.push_to(run_id, &link, &peers, true);
            }
        });
    }

    fn push_to(&self, run_id: Uuid, link: &Arc<LinkState>, peers: &[u32], dedupe: bool) {
        if peers.is_empty() {
            return;
        }
        let Some(run) = self.manager.run(run_id) else { return };
        if run.archived {
            return;
        }
        let timeline = self.manager.timeline(run_id);
        let (held_notes, outbound) = {
            let inner = link.inner.lock().unwrap_or_else(|e| e.into_inner());
            (inner.hold.notes(), inner.outbound.clone())
        };
        let Some(tx) = outbound else { return };
        let view = Outgoing::view(run.title, run.status.is_active(), guest_link::entries(&timeline), held_notes, link.share.until);
        let Ok(plain) = serde_json::to_vec(&view) else { return };
        if dedupe {
            let mut inner = link.inner.lock().unwrap_or_else(|e| e.into_inner());
            if inner.last_sent == plain {
                return;
            }
            inner.last_sent = plain.clone();
        }
        Self::send_plain(&plain, &link.share.key, &tx, peers);
    }

    fn send_outgoing(msg: &Outgoing, key: &[u8], tx: &mpsc::UnboundedSender<Message>, peers: &[u32]) {
        if let Ok(plain) = serde_json::to_vec(msg) {
            Self::send_plain(&plain, key, tx, peers);
        }
    }

    fn send_plain(plain: &[u8], key: &[u8], tx: &mpsc::UnboundedSender<Message>, peers: &[u32]) {
        let Some(sealed) = guest_link::seal(plain, key) else { return };
        for &peer in peers {
            let _ = tx.send(Message::Binary(mux_encode(MuxKind::Data, peer, &sealed).into()));
        }
    }

    fn persist(&self) {
        let shares: Vec<GuestShare> = self.links.lock().unwrap_or_else(|e| e.into_inner()).values().map(|l| l.share.clone()).collect();
        self.persist_shares(&shares);
    }

    fn persist_shares(&self, shares: &[GuestShare]) {
        if shares.is_empty() {
            (self.callbacks.remove_secret)(SHARES_SECRET_ACCOUNT);
        } else if let Ok(json) = serde_json::to_string(shares) {
            (self.callbacks.write_secret)(SHARES_SECRET_ACCOUNT, &json);
        }
    }
}

fn save_files(base_dir: &Path, message: &GuestMessage, run_id: Uuid) -> Option<Vec<String>> {
    if message.files.is_empty() {
        return Some(Vec::new());
    }
    let run_prefix: String = run_id.to_string().chars().take(8).collect();
    let msg_prefix: String = Uuid::new_v4().to_string().chars().take(8).collect();
    let folder = base_dir.join(run_prefix).join(msg_prefix);
    if std::fs::create_dir_all(&folder).is_err() {
        return None;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(0o700));
    }
    let mut paths = Vec::with_capacity(message.files.len());
    let mut used = HashSet::new();
    for file in &message.files {
        let mut name = file.name.clone();
        if !used.insert(name.clone()) {
            name = format!("{}-{name}", paths.len() + 1);
        }
        let target = folder.join(&name);
        if crate::paths::write_atomic(&target, &file.data).is_err() {
            let _ = std::fs::remove_dir_all(&folder);
            return None;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o600));
        }
        paths.push(target.to_string_lossy().into_owned());
    }
    Some(paths)
}

fn remove_files(message: &HeldMessage) {
    if let Some(first) = message.files.first() {
        if let Some(parent) = Path::new(first).parent() {
            let _ = std::fs::remove_dir_all(parent);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace::manager::Hooks;

    #[tokio::test]
    async fn snapshot_requires_relay_and_persists_nothing_when_empty() {
        let dir = std::env::temp_dir().join(format!("nook-guest-test-{}", Uuid::new_v4()));
        let hooks = Hooks {
            executable: Box::new(|_| None),
            account_environment: Box::new(|_| std::collections::BTreeMap::new()),
            bridge: Box::new(|| None),
            worktree_root: Box::new(String::new),
            auto_resume_limited: Box::new(|| false),
        };
        let manager = Manager::new(dir.join("ws"), hooks, tokio::runtime::Handle::current(), |_| {});
        let secret = Arc::new(Mutex::new(Option::<String>::None));
        let s_read = secret.clone();
        let s_write = secret.clone();
        let s_remove = secret.clone();
        let shares = GuestShares::new(
            manager,
            tokio::runtime::Handle::current(),
            dir.join("guest-files"),
            GuestSharesCallbacks {
                relay_url: Box::new(|| None),
                read_secret: Box::new(move |_| s_read.lock().unwrap().clone()),
                write_secret: Box::new(move |_, v| *s_write.lock().unwrap() = Some(v.to_string())),
                remove_secret: Box::new(move |_| *s_remove.lock().unwrap() = None),
                on_change: Box::new(|| {}),
            },
        );
        shares.start();
        let snap = shares.snapshot();
        assert!(!snap.can_share);
        assert!(snap.shares.is_empty());
        assert!(shares.share(Uuid::new_v4()).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
