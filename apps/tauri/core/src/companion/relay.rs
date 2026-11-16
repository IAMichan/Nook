//! The computer's side of the relay (`CompanionRelayClient.swift` on the Mac): reaching this computer from anywhere
//! without Tailscale and without a port opened on the router (docs/COMPANION.md, "Away from home"). The computer keeps
//! one outgoing WebSocket per paired phone (and one for an open pairing window), each in that phone's room
//! ([`relay_room`]). A phone that cannot reach the computer directly opens its own WebSocket to the same room, and the
//! relay passes bytes between them. Everything that passes is sealed with the pairing key, so the relay reads and forges
//! nothing; each phone connection that comes through is answered by [`CompanionServer::serve_stream`] like a connection
//! on the local network.
//!
//! On the computer's socket every message is `[kind: 1 byte][connection: 4 bytes, big-endian][payload]` (`RelayMux`,
//! `apps/relay/worker/mux.js`); a phone's own socket carries the payload alone.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use rand::TryRng;
use serde::Serialize;
use tokio::io::{AsyncReadExt, AsyncWriteExt, WriteHalf};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

use super::models::PairedDevice;
use super::server::CompanionServer;
use super::transport::{normalize_relay, relay_room};

/// The keep-alive goes this often; the relay answers "ping" with "pong" without waking the room.
const KEEP_ALIVE: Duration = Duration::from_secs(30);
/// A socket that heard nothing this long is replaced (asleep, or the network changed under it).
const SILENCE_LIMIT: Duration = Duration::from_secs(75);
/// How long connecting to the relay may take.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// A phone connection lasts as long as one on the local network may (`CONNECTION_DEADLINE` in the server).
const PEER_DEADLINE: Duration = Duration::from_secs(30);
/// Phone connections one room keeps open at once.
const MAX_PEERS: usize = 8;
/// What one phone connection may have in flight towards the server before the room waits.
const PEER_BUFFER: usize = 256 * 1024;

/// The kinds of a message on the computer's socket.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MuxKind {
    /// A phone connected (relay to computer).
    Open = 1,
    /// Bytes for or from that connection.
    Data = 2,
    /// The connection ended (either way).
    Close = 3,
}

pub fn mux_encode(kind: MuxKind, connection: u32, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(5 + payload.len());
    out.push(kind as u8);
    out.extend_from_slice(&connection.to_be_bytes());
    out.extend_from_slice(payload);
    out
}

pub fn mux_decode(data: &[u8]) -> Option<(MuxKind, u32, &[u8])> {
    if data.len() < 5 {
        return None;
    }
    let kind = match data[0] {
        1 => MuxKind::Open,
        2 => MuxKind::Data,
        3 => MuxKind::Close,
        _ => return None,
    };
    Some((kind, u32::from_be_bytes([data[1], data[2], data[3], data[4]]), &data[5..]))
}

/// The WebSocket the computer opens: `wss://host/v1/rooms/<room>?role=mac` (the relay calls every computer "mac").
pub fn host_socket(relay: &str, room: &str) -> Option<String> {
    let base = normalize_relay(relay)?;
    let ws = base.replacen("https://", "wss://", 1).replacen("http://", "ws://", 1);
    Some(format!("{ws}/v1/rooms/{room}?role=mac"))
}

/// The wait before trying again after `failures` failures in a row (`RetryBackoff`): up to a minute, with jitter.
pub fn retry_delay(failures: u32, random: f64) -> Duration {
    let ceiling = (1u64 << failures.clamp(1, 10)).min(60) as f64;
    Duration::from_secs_f64(ceiling / 2.0 + ceiling / 2.0 * random.clamp(0.0, 1.0))
}

/// How the relay is doing, for Settings.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum RelayStatus {
    Off,
    /// On, but there is no valid (https) relay address.
    Invalid,
    Connecting,
    Connected,
    Failed {
        message: String,
    },
}

#[derive(Default)]
struct RoomState {
    connected: AtomicBool,
    last_error: Mutex<Option<String>>,
}

struct Room {
    relay: String,
    task: tokio::task::AbortHandle,
    state: Arc<RoomState>,
}

/// Keeps a room open on the relay for every paired phone and the open pairing window.
pub struct RelayHost {
    server: Arc<CompanionServer>,
    rooms: Mutex<HashMap<String, Room>>,
    /// The relay in use; `None` while off.
    relay: Mutex<Option<String>>,
    on: AtomicBool,
    /// Rooms run here: `apply` is also called from outside the runtime (a Settings command on the main thread).
    runtime: tokio::runtime::Handle,
}

impl RelayHost {
    pub fn new(server: Arc<CompanionServer>, runtime: tokio::runtime::Handle) -> Self {
        Self { server, rooms: Mutex::new(HashMap::new()), relay: Mutex::new(None), on: AtomicBool::new(false), runtime }
    }

    /// Opens a room for every paired phone (and the open pairing window) on `relay`, and closes the rest. `on` false or
    /// a companion that is off closes them all. Cheap to call often: rooms that are wanted and open stay as they are.
    pub fn apply(&self, on: bool, relay: Option<&str>) {
        let relay = relay.and_then(normalize_relay);
        let store = self.server.store();
        let on = on && store.enabled();
        self.on.store(on, Ordering::SeqCst);
        *self.relay.lock().unwrap_or_else(|e| e.into_inner()) = relay.clone();
        let mut rooms = self.rooms.lock().unwrap_or_else(|e| e.into_inner());
        let Some(relay) = relay.filter(|_| on) else {
            for (_, room) in rooms.drain() {
                room.task.abort();
            }
            return;
        };
        let mut wanted: HashMap<String, Vec<u8>> = HashMap::new();
        for device in store.devices() {
            if let Some(key) = store.key(&device.id) {
                wanted.insert(device.id, key);
            }
        }
        if let Some(pending) = store.active_pending(chrono::Utc::now()) {
            wanted.insert(PairedDevice::identifier(&pending), pending);
        }
        rooms.retain(|id, room| {
            let keep = wanted.contains_key(id) && room.relay == relay && !room.task.is_finished();
            if !keep {
                room.task.abort();
            }
            keep
        });
        for (id, key) in wanted {
            if rooms.contains_key(&id) {
                continue;
            }
            let Some(url) = host_socket(&relay, &relay_room(&key)) else { continue };
            let state = Arc::new(RoomState::default());
            let task = self.runtime.spawn(run_room(self.server.clone(), url, state.clone())).abort_handle();
            rooms.insert(id, Room { relay: relay.clone(), task, state });
        }
    }

    /// Opens every room again now (after sleep, on another network) instead of waiting for the keep-alive to notice.
    pub fn reconnect(&self) {
        let mut rooms = self.rooms.lock().unwrap_or_else(|e| e.into_inner());
        for (_, room) in rooms.drain() {
            room.task.abort();
        }
        drop(rooms);
        let relay = self.relay.lock().unwrap_or_else(|e| e.into_inner()).clone();
        self.apply(self.on.load(Ordering::SeqCst), relay.as_deref());
    }

    pub fn status(&self) -> RelayStatus {
        if !self.on.load(Ordering::SeqCst) {
            return RelayStatus::Off;
        }
        if self.relay.lock().unwrap_or_else(|e| e.into_inner()).is_none() {
            return RelayStatus::Invalid;
        }
        let rooms = self.rooms.lock().unwrap_or_else(|e| e.into_inner());
        if rooms.values().any(|r| r.state.connected.load(Ordering::SeqCst)) {
            return RelayStatus::Connected;
        }
        if let Some(message) = rooms.values().find_map(|r| r.state.last_error.lock().unwrap_or_else(|e| e.into_inner()).clone()) {
            return RelayStatus::Failed { message };
        }
        if rooms.is_empty() {
            RelayStatus::Off
        } else {
            RelayStatus::Connecting
        }
    }

    /// *Test relay*: sends a `ping` through the relay as a paired phone would (into its room, sealed with its key) and
    /// waits for this computer's own answer to come back the same way, the whole path a phone takes from away. The
    /// round trip in milliseconds, or what failed.
    pub async fn test(&self) -> Result<u64, String> {
        let relay = self.relay.lock().unwrap_or_else(|e| e.into_inner()).clone().filter(|_| self.on.load(Ordering::SeqCst));
        let Some(relay) = relay else { return Err("The relay is off.".into()) };
        let store = self.server.store();
        let Some(key) = store.devices().iter().find_map(|d| store.key(&d.id)) else { return Err("Pair a phone first.".into()) };
        let link = super::models::PairingLink { host: "relay".into(), port: 0, key: key.clone(), ..Default::default() };
        let route = super::transport::Route::Relay { relay, room: relay_room(&key) };
        let started = Instant::now();
        let ping = super::models::CompanionRequest::new(super::models::CompanionOp::Ping);
        match super::client::request(&link, &[route], &ping, None, &super::client::DnsResolver).await {
            Ok((response, _)) if response.ok => Ok(started.elapsed().as_millis() as u64),
            Ok(_) => Err("This computer answered, but refused the test.".into()),
            Err(super::client::ClientError::Closed) => Err("The relay closed the connection: this computer is not in the room yet.".into()),
            Err(super::client::ClientError::Timeout) => Err("No answer in time.".into()),
            Err(e) => Err(format!("The relay cannot be reached ({e:?}).")),
        }
    }

    /// The relay phones are told about: its address while on, "" while off, so they drop it.
    pub fn advertised(&self) -> String {
        if self.on.load(Ordering::SeqCst) {
            self.relay.lock().unwrap_or_else(|e| e.into_inner()).clone().unwrap_or_default()
        } else {
            String::new()
        }
    }
}

impl Drop for RelayHost {
    fn drop(&mut self) {
        for (_, room) in self.rooms.lock().unwrap_or_else(|e| e.into_inner()).drain() {
            room.task.abort();
        }
    }
}

/// One room: connect, serve, and connect again with backoff, until aborted.
async fn run_room(server: Arc<CompanionServer>, url: String, state: Arc<RoomState>) {
    let mut failures = 0u32;
    loop {
        let since = Instant::now();
        let error = match tokio::time::timeout(CONNECT_TIMEOUT, tokio_tungstenite::connect_async(url.as_str())).await {
            Ok(Ok((ws, _))) => serve_room(&server, ws, &state).await,
            Ok(Err(e)) => e.to_string(),
            Err(_) => "the relay did not answer in time".into(),
        };
        state.connected.store(false, Ordering::SeqCst);
        *state.last_error.lock().unwrap_or_else(|e| e.into_inner()) = Some(error);
        failures = if since.elapsed() >= Duration::from_secs(30) { 1 } else { failures + 1 };
        let mut byte = [0u8; 1];
        let random = rand::rngs::SysRng.try_fill_bytes(&mut byte).map(|_| f64::from(byte[0]) / 255.0).unwrap_or(0.5);
        tokio::time::sleep(retry_delay(failures, random)).await;
    }
}

type Socket = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// Serves one open socket until it ends; returns why.
async fn serve_room(server: &Arc<CompanionServer>, ws: Socket, state: &RoomState) -> String {
    let (mut sink, mut stream) = ws.split();
    // Everything that goes out (answers of every phone connection, keep-alives) goes through one queue.
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<Message>();
    let writer = tokio::spawn(async move {
        while let Some(message) = out_rx.recv().await {
            if sink.send(message).await.is_err() {
                return;
            }
        }
    });
    // A phone connection that ended on the server's side says so here, so the room forgets it.
    let (ended_tx, mut ended_rx) = mpsc::unbounded_channel::<u32>();
    let mut peers: HashMap<u32, (WriteHalf<tokio::io::DuplexStream>, tokio::task::AbortHandle)> = HashMap::new();
    let _ = out_tx.send(Message::Text("ping".into()));
    let mut last_heard = Instant::now();
    let mut keep_alive = tokio::time::interval(KEEP_ALIVE);
    keep_alive.tick().await;

    let reason = loop {
        tokio::select! {
            message = stream.next() => {
                let message = match message {
                    Some(Ok(m)) => m,
                    Some(Err(e)) => break e.to_string(),
                    None => break "the relay closed the connection".into(),
                };
                last_heard = Instant::now();
                if !state.connected.swap(true, Ordering::SeqCst) {
                    *state.last_error.lock().unwrap_or_else(|e| e.into_inner()) = None;
                }
                let data = match message {
                    Message::Binary(b) => b,
                    Message::Close(frame) => break frame.map(|f| format!("closed ({})", u16::from(f.code))).unwrap_or_else(|| "closed".into()),
                    _ => continue,
                };
                let Some((kind, connection, payload)) = mux_decode(&data) else { continue };
                match kind {
                    MuxKind::Open => {
                        if peers.len() >= MAX_PEERS {
                            let _ = out_tx.send(Message::Binary(mux_encode(MuxKind::Close, connection, &[]).into()));
                            continue;
                        }
                        let (ours, theirs) = tokio::io::duplex(PEER_BUFFER);
                        let (mut reader, writer) = tokio::io::split(ours);
                        let (server, out, ended) = (server.clone(), out_tx.clone(), ended_tx.clone());
                        let task = tokio::spawn(async move {
                            let serve = async {
                                let _ = tokio::time::timeout(PEER_DEADLINE, server.serve_stream(theirs)).await;
                            };
                            let pump = async {
                                let mut buf = vec![0u8; 64 * 1024];
                                loop {
                                    match reader.read(&mut buf).await {
                                        Ok(0) | Err(_) => return,
                                        Ok(n) => {
                                            let frame = mux_encode(MuxKind::Data, connection, &buf[..n]);
                                            if out.send(Message::Binary(frame.into())).is_err() {
                                                return;
                                            }
                                        }
                                    }
                                }
                            };
                            // The server ends the connection (or its deadline does): what it wrote is pumped out first.
                            tokio::join!(serve, pump);
                            let _ = out.send(Message::Binary(mux_encode(MuxKind::Close, connection, &[]).into()));
                            let _ = ended.send(connection);
                        });
                        if let Some((_, old)) = peers.insert(connection, (writer, task.abort_handle())) {
                            old.abort();
                        }
                    }
                    MuxKind::Data => {
                        let delivered = match peers.get_mut(&connection) {
                            Some((writer, _)) => writer.write_all(payload).await.is_ok(),
                            None => false,
                        };
                        if !delivered {
                            if let Some((_, task)) = peers.remove(&connection) {
                                task.abort();
                            }
                            let _ = out_tx.send(Message::Binary(mux_encode(MuxKind::Close, connection, &[]).into()));
                        }
                    }
                    MuxKind::Close => {
                        // Dropping the writer ends what the server reads; its task finishes by itself.
                        if let Some((mut writer, _)) = peers.remove(&connection) {
                            let _ = writer.shutdown().await;
                        }
                    }
                }
            }
            Some(connection) = ended_rx.recv() => {
                peers.remove(&connection);
            }
            _ = keep_alive.tick() => {
                if last_heard.elapsed() > SILENCE_LIMIT {
                    break "the relay went quiet".into();
                }
                let _ = out_tx.send(Message::Text("ping".into()));
            }
        }
    };
    for (_, (_, task)) in peers.drain() {
        task.abort();
    }
    writer.abort();
    reason
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mux_round_trips_like_the_mac() {
        let framed = mux_encode(MuxKind::Data, 0x0102_0304, b"hi");
        assert_eq!(framed, vec![2, 1, 2, 3, 4, b'h', b'i']);
        assert_eq!(mux_decode(&framed), Some((MuxKind::Data, 0x0102_0304, &b"hi"[..])));
        assert_eq!(mux_decode(&[1, 0, 0, 0, 7]), Some((MuxKind::Open, 7, &b""[..])));
        assert_eq!(mux_decode(&[9, 0, 0, 0, 7]), None);
        assert_eq!(mux_decode(&[2, 0, 0]), None);
    }

    #[test]
    fn host_socket_is_the_mac_role() {
        assert_eq!(host_socket("relay.example.com", "ab"), Some("wss://relay.example.com/v1/rooms/ab?role=mac".into()));
        assert_eq!(host_socket("http://localhost:8787", "ab"), Some("ws://localhost:8787/v1/rooms/ab?role=mac".into()));
        assert_eq!(host_socket("http://relay.example.com", "ab"), None, "plain http only on this machine");
    }

    #[test]
    fn backoff_grows_to_a_minute() {
        assert_eq!(retry_delay(1, 1.0), Duration::from_secs(2));
        assert_eq!(retry_delay(1, 0.0), Duration::from_secs(1));
        assert_eq!(retry_delay(3, 1.0), Duration::from_secs(8));
        assert_eq!(retry_delay(20, 1.0), Duration::from_secs(60));
        assert_eq!(retry_delay(20, 0.0), Duration::from_secs(30));
    }
}
