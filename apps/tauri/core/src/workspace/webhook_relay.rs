//! Outgoing WebSocket listener for the public webhook relay (`WebhookRelay.swift` on the Mac, AG-131 / #1677).
//!
//! Connects to `wss://<relay>/v1/hooks/<room>/listen` with `Authorization: Bearer <token>`, forwards each incoming
//! webhook JSON frame to the scheduler's `webhook::Handler`, and replies with `{ id, status, message }`. Keeps the
//! socket alive with `"ping"` every 30 s, replaces a silent socket after 75 s, and reconnects with exponential backoff.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use rand::TryRng;
use serde::Serialize;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::Message;
use uuid::Uuid;

use super::webhook::{self, Handler};
use super::webhook_rules::{self, RELAY_TOKEN_ACCOUNT};
use crate::companion::relay::retry_delay;
use crate::secrets::SecretStore;

const KEEP_ALIVE: Duration = Duration::from_secs(30);
const SILENCE_LIMIT: Duration = Duration::from_secs(75);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// Live status of the public webhook relay connection (`WebhookRelay.State` on the Mac).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RelayState {
    #[default]
    Off,
    Connecting,
    Connected,
    NoRelay,
}

#[derive(Default)]
struct Inner {
    state: RelayState,
    url: Option<String>,
    token: Option<String>,
    task: Option<tokio::task::AbortHandle>,
}

/// Manages one outgoing WebSocket to the public webhook relay.
pub struct WebhookRelayClient {
    secrets: Arc<dyn SecretStore>,
    handler: Handler,
    on_change: Arc<dyn Fn() + Send + Sync>,
    inner: Arc<Mutex<Inner>>,
    runtime: tokio::runtime::Handle,
}

impl WebhookRelayClient {
    pub fn new(
        secrets: Arc<dyn SecretStore>,
        handler: Handler,
        on_change: Arc<dyn Fn() + Send + Sync>,
        runtime: tokio::runtime::Handle,
    ) -> Self {
        Self { secrets, handler, on_change, inner: Arc::new(Mutex::new(Inner::default())), runtime }
    }

    pub fn state(&self) -> RelayState {
        self.inner.lock().unwrap_or_else(|e| e.into_inner()).state
    }

    /// Reads the computer's public webhook relay token from the secret store, creating one when `create` is true.
    pub fn token(&self, create: bool) -> Option<String> {
        if let Some(existing) = self.secrets.read(RELAY_TOKEN_ACCOUNT).filter(|s| !s.is_empty()) {
            return Some(existing);
        }
        if !create {
            return None;
        }
        let fresh = webhook::new_secret();
        if self.secrets.write(RELAY_TOKEN_ACCOUNT, &fresh).is_ok() {
            Some(fresh)
        } else {
            None
        }
    }

    /// Public URL for `task` (`https://<relay>/v1/hooks/<room>/<task>`), creating the relay token when missing.
    pub fn public_url(&self, relay: &str, task: Uuid) -> Option<String> {
        let token = self.token(true)?;
        webhook_rules::relay_public_url(relay, &token, task)
    }

    /// Connects, reconnects, or stops the relay listener so it matches `(wanted, relay)`.
    ///
    /// - `wanted`: true when scheduled tasks are on, public webhooks are on, and at least one enabled webhook task exists.
    /// - `relay`: the configured relay base URL (`None` puts the client in [`RelayState::NoRelay`] when `wanted`).
    pub fn apply(&self, wanted: bool, relay: Option<&str>) {
        if !wanted {
            self.stop(RelayState::Off);
            return;
        }
        let Some(token) = self.token(true) else {
            self.stop(RelayState::Off);
            return;
        };
        let Some(url) = relay.and_then(|r| webhook_rules::relay_listen_url(r, &token)) else {
            self.stop(RelayState::NoRelay);
            return;
        };
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let same = inner.url.as_deref() == Some(url.as_str())
            && inner.token.as_deref() == Some(token.as_str())
            && inner.task.as_ref().is_some_and(|t| !t.is_finished());
        if same {
            return;
        }
        if let Some(old) = inner.task.take() {
            old.abort();
        }
        inner.url = Some(url.clone());
        inner.token = Some(token.clone());
        let changed = inner.state != RelayState::Connecting;
        inner.state = RelayState::Connecting;
        let state = self.inner.clone();
        let handler = self.handler.clone();
        let on_change = self.on_change.clone();
        inner.task = Some(self.runtime.spawn(run_loop(url, token, state, handler, on_change)).abort_handle());
        drop(inner);
        if changed {
            (self.on_change)();
        }
    }

    fn stop(&self, next: RelayState) {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(old) = inner.task.take() {
            old.abort();
        }
        inner.url = None;
        inner.token = None;
        let changed = inner.state != next;
        inner.state = next;
        drop(inner);
        if changed {
            (self.on_change)();
        }
    }
}

impl Drop for WebhookRelayClient {
    fn drop(&mut self) {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(task) = inner.task.take() {
            task.abort();
        }
    }
}

fn set_state(inner: &Mutex<Inner>, on_change: &(dyn Fn() + Send + Sync), next: RelayState) {
    let changed = {
        let mut guard = inner.lock().unwrap_or_else(|e| e.into_inner());
        let changed = guard.state != next;
        guard.state = next;
        changed
    };
    if changed {
        on_change();
    }
}

async fn run_loop(url: String, token: String, inner: Arc<Mutex<Inner>>, handler: Handler, on_change: Arc<dyn Fn() + Send + Sync>) {
    let mut failures = 0u32;
    loop {
        set_state(&inner, on_change.as_ref(), RelayState::Connecting);
        let since = Instant::now();
        let request = url.as_str().into_client_request().ok().and_then(|mut req| {
            let auth = HeaderValue::from_str(&format!("Bearer {token}")).ok()?;
            req.headers_mut().insert("Authorization", auth);
            Some(req)
        });
        if let Some(req) = request {
            if let Ok(Ok((ws, _))) = tokio::time::timeout(CONNECT_TIMEOUT, tokio_tungstenite::connect_async(req)).await {
                serve_socket(ws, &inner, &handler, on_change.as_ref()).await;
            }
        }
        set_state(&inner, on_change.as_ref(), RelayState::Connecting);
        failures = if since.elapsed() >= Duration::from_secs(30) { 1 } else { failures + 1 };
        let mut byte = [0u8; 1];
        let random = rand::rngs::SysRng.try_fill_bytes(&mut byte).map(|_| f64::from(byte[0]) / 255.0).unwrap_or(0.5);
        tokio::time::sleep(retry_delay(failures, random)).await;
    }
}

type Socket = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn serve_socket(ws: Socket, inner: &Mutex<Inner>, handler: &Handler, on_change: &(dyn Fn() + Send + Sync)) {
    let (mut sink, mut stream) = ws.split();
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<Message>();
    let writer = tokio::spawn(async move {
        while let Some(msg) = out_rx.recv().await {
            if sink.send(msg).await.is_err() {
                return;
            }
        }
    });
    set_state(inner, on_change, RelayState::Connected);
    let _ = out_tx.send(Message::Text("ping".into()));
    let mut last_heard = Instant::now();
    let mut keep_alive = tokio::time::interval(KEEP_ALIVE);
    keep_alive.tick().await;

    loop {
        tokio::select! {
            message = stream.next() => {
                let message = match message {
                    Some(Ok(m)) => m,
                    Some(Err(_)) | None => break,
                };
                last_heard = Instant::now();
                match message {
                    Message::Text(text) => {
                        if text.as_str() == "pong" {
                            continue;
                        }
                        let Some(incoming) = webhook_rules::parse_relay_incoming(text.as_str()) else { continue };
                        let (status, msg) = handler(incoming.request);
                        let reply = webhook_rules::format_relay_answer(&incoming.id, status, &msg);
                        if out_tx.send(Message::Text(reply.into())).is_err() {
                            break;
                        }
                    }
                    Message::Ping(payload) => {
                        let _ = out_tx.send(Message::Pong(payload));
                    }
                    Message::Close(_) => break,
                    _ => {}
                }
            }
            _ = keep_alive.tick() => {
                if last_heard.elapsed() >= SILENCE_LIMIT {
                    break;
                }
                if out_tx.send(Message::Text("ping".into())).is_err() {
                    break;
                }
            }
        }
    }

    drop(out_tx);
    writer.abort();
}
