//! One `opencode serve` process per `(executable, profile_id)` (`OpenCodeServerHost` on the Mac), shared by every
//! OpenCode session of that account: bound to `127.0.0.1` on an ephemeral port, with a per-host random password kept
//! only in memory. Its SSE stream (`GET /api/event`) stays open while the host runs and reconnects automatically after
//! transient drops.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use futures_util::StreamExt;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::sync::oneshot;

use super::command;
use super::driver::SlashCommand;
use super::models::TurnUsage;
use super::opencode_protocol::{self, OpenCodeEvent, OpenCodeModel, Rule, SseParser};

/// An answer from the OpenCode HTTP server: its status and parsed JSON, or why there was none.
#[derive(Debug, Clone)]
pub struct OpenCodeReply {
    pub status: u16,
    pub json: Option<Value>,
    pub error: Option<String>,
}

impl OpenCodeReply {
    pub fn ok(&self) -> bool {
        (200..300).contains(&self.status) && self.error.is_none()
    }

    pub fn not_found(&self) -> bool {
        self.status == 404
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpenCodeServerError {
    /// This OpenCode has no server Nook speaks (1.x, or a version that would not tell): the session uses ACP.
    Unsupported(Option<String>),
    Launch(String),
    Timeout,
    Exited(String),
}

impl std::fmt::Display for OpenCodeServerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unsupported(v) => write!(f, "OpenCode {} has no server Nook can use", v.as_deref().unwrap_or("?")),
            Self::Launch(msg) => write!(f, "{msg}"),
            Self::Timeout => write!(f, "The OpenCode server did not start in time."),
            Self::Exited(stderr) => {
                if stderr.is_empty() {
                    write!(f, "The OpenCode server stopped.")
                } else {
                    write!(f, "{stderr}")
                }
            }
        }
    }
}

/// One Nook session's place on an OpenCode server (`OpenCodeLink` on the Mac).
#[derive(Debug, Clone)]
pub struct OpenCodeLink {
    /// The server's key in `opencode_hosts` (`executable|profile_id`).
    pub host: String,
    pub directory: String,
    pub session_id: Option<String>,
    /// The server is starting or the session is being read or created; a prompt waits in `opencode_warm_prompts`.
    pub opening: bool,
    /// The session was just created: the next prompt carries the session instructions.
    pub fresh: bool,
    /// What Nook set on the session, so only changes are sent before the next prompt.
    pub applied_model: Option<String>,
    pub applied_agent: Option<String>,
    pub applied_rules: Option<Vec<Rule>>,
    /// The model the session currently runs, as OpenCode reports it (`"provider/model"`).
    pub current_model: Option<String>,
    /// What you allowed "for this session" (`opencode_protocol::grants`).
    pub grants: Vec<Rule>,
    /// Nook's bridge as this session's MCP server in OpenCode, once registered.
    pub bridge_server: Option<String>,
    pub prepared: bool,
    pub models: Vec<OpenCodeModel>,
    pub commands: Vec<SlashCommand>,
    /// The running turn's tool calls by id, with OpenCode's original tool name and raw input.
    pub tools: HashMap<String, OpenCodeToolState>,
    /// Subagent sessions of this one, whose permission requests and questions belong to this session.
    pub children: HashSet<String>,
    /// The turn's prompt went out: from now on the end of an execution is this turn's end.
    pub prompt_sent: bool,
    /// Tokens and cost accumulated during the running turn.
    pub usage: TurnUsage,
    /// Context window of the active model when known.
    pub context_window: Option<u64>,
    /// True if any assistant text arrived in this turn.
    pub replied: bool,
    /// True when woken by an external execution without a Nook prompt.
    pub unprompted: bool,
    /// Active streamed text item id (`assistantMessageID:ordinal`) mapped to timeline event id.
    pub text_items: HashMap<String, uuid::Uuid>,
    /// Active streamed reasoning item id (`assistantMessageID:ordinal`) mapped to timeline event id.
    pub thinking_items: HashMap<String, uuid::Uuid>,
}

#[derive(Debug, Clone)]
pub struct OpenCodeToolState {
    pub name: String,
    pub input: Value,
}

impl OpenCodeLink {
    pub fn new(host: String, directory: String) -> Self {
        Self {
            host,
            directory,
            session_id: None,
            opening: true,
            fresh: false,
            applied_model: None,
            applied_agent: None,
            applied_rules: None,
            current_model: None,
            grants: Vec::new(),
            bridge_server: None,
            prepared: false,
            models: Vec::new(),
            commands: Vec::new(),
            tools: HashMap::new(),
            children: HashSet::new(),
            prompt_sent: false,
            usage: TurnUsage::default(),
            context_window: None,
            replied: false,
            unprompted: false,
            text_items: HashMap::new(),
            thinking_items: HashMap::new(),
        }
    }
}

/// Host lifecycle state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostState {
    Starting,
    Ready,
    Stopped,
}

/// Callbacks delivered by [`OpenCodeServerHost`] to the workspace manager.
pub struct HostCallbacks {
    pub on_events: Arc<dyn Fn(Vec<OpenCodeEvent>) + Send + Sync>,
    pub on_reconnected: Arc<dyn Fn() + Send + Sync>,
    pub on_gone: Arc<dyn Fn(String) + Send + Sync>,
}

struct HostInner {
    state: HostState,
    base_url: Option<String>,
    version: Option<String>,
    pid: Option<u32>,
    ever_connected: bool,
    stream_failures: usize,
    waiters: Vec<oneshot::Sender<Result<(), OpenCodeServerError>>>,
    kill: Option<oneshot::Sender<()>>,
    stream_task: Option<tokio::task::AbortHandle>,
    timeout_task: Option<tokio::task::AbortHandle>,
}

const START_TIMEOUT: Duration = Duration::from_secs(30);
const STREAM_SILENCE_TIMEOUT: Duration = Duration::from_secs(45);
const RECONNECT_ATTEMPTS: usize = 5;

/// One shared `opencode serve` process for an account.
pub struct OpenCodeServerHost {
    pub key: String,
    pub executable: String,
    password: String,
    client: reqwest::Client,
    runtime: tokio::runtime::Handle,
    callbacks: HostCallbacks,
    inner: Mutex<HostInner>,
}

impl OpenCodeServerHost {
    pub fn new(key: String, executable: String, runtime: tokio::runtime::Handle, callbacks: HostCallbacks) -> Arc<Self> {
        let client = reqwest::Client::builder().no_proxy().pool_max_idle_per_host(8).build().unwrap_or_else(|_| reqwest::Client::new());
        Arc::new(Self {
            key,
            executable,
            password: opencode_protocol::make_password(),
            client,
            runtime,
            callbacks,
            inner: Mutex::new(HostInner {
                state: HostState::Starting,
                base_url: None,
                version: None,
                pid: None,
                ever_connected: false,
                stream_failures: 0,
                waiters: Vec::new(),
                kill: None,
                stream_task: None,
                timeout_task: None,
            }),
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HostInner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn is_running(&self) -> bool {
        self.lock().state != HostState::Stopped
    }

    pub fn pid(&self) -> Option<u32> {
        self.lock().pid
    }

    /// Resolves once the server answered `/api/info` and its SSE event stream sent `server.connected`.
    pub async fn wait_ready(self: &Arc<Self>) -> Result<(), OpenCodeServerError> {
        let rx = {
            let mut inner = self.lock();
            match inner.state {
                HostState::Ready => return Ok(()),
                HostState::Stopped => return Err(OpenCodeServerError::Exited(String::new())),
                HostState::Starting => {
                    let (tx, rx) = oneshot::channel();
                    inner.waiters.push(tx);
                    rx
                }
            }
        };
        rx.await.unwrap_or_else(|_| Err(OpenCodeServerError::Exited(String::new())))
    }

    /// Starts the server for an account (`environment`: the account's variables). Checks `--version` first so an
    /// unsupported 1.x binary is never launched as a server.
    pub fn start(self: &Arc<Self>, environment: BTreeMap<String, String>, working_directory: String) {
        let host_timeout = Arc::clone(self);
        let timeout_handle = self.runtime.spawn(async move {
            tokio::time::sleep(START_TIMEOUT).await;
            host_timeout.fail(OpenCodeServerError::Timeout);
        });
        self.lock().timeout_task = Some(timeout_handle.abort_handle());

        let host = Arc::clone(self);
        let exe = self.executable.clone();
        self.runtime.spawn(async move {
            let version = tokio::task::spawn_blocking(move || installed_version(&exe)).await.ok().flatten();
            host.launch(version, environment, working_directory);
        });
    }

    fn launch(self: &Arc<Self>, version: Option<String>, environment: BTreeMap<String, String>, working_directory: String) {
        if self.lock().state != HostState::Starting {
            return;
        }
        if !opencode_protocol::supports_version(version.as_deref()) {
            self.fail(OpenCodeServerError::Unsupported(version));
            return;
        }
        self.lock().version = version;

        let mut base: BTreeMap<String, String> = std::env::vars().collect();
        for key in opencode_protocol::REMOVED_ENV {
            base.remove(*key);
        }
        let mut extra = environment;
        extra.insert(opencode_protocol::PASSWORD_ENV.into(), self.password.clone());
        let env = command::environment(&base, &self.executable, &extra);

        let mut cmd = tokio::process::Command::new(&self.executable);
        cmd.args(opencode_protocol::ARGUMENTS)
            .current_dir(&working_directory)
            .env_clear()
            .envs(&env)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        #[cfg(windows)]
        {
            cmd.creation_flags(0x0800_0000);
        }

        let _guard = self.runtime.enter();
        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                self.fail(OpenCodeServerError::Launch(e.to_string()));
                return;
            }
        };
        let pid = child.id();
        if let Some(p) = pid {
            super::dev_stop::note_agent(p);
        }
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        // Keep stdin alive until stop/exit so the server doesn't see an immediate EOF if it checks stdin.
        let _stdin = child.stdin.take();
        let (kill_tx, kill_rx) = oneshot::channel::<()>();
        {
            let mut inner = self.lock();
            if inner.state != HostState::Starting {
                let _ = child.start_kill();
                return;
            }
            inner.pid = pid;
            inner.kill = Some(kill_tx);
        }

        // Capture stderr tail for diagnostics if the server exits unexpectedly.
        let tail = Arc::new(Mutex::new(String::new()));
        if let Some(mut err) = stderr {
            let tail_c = Arc::clone(&tail);
            self.runtime.spawn(async move {
                let mut buf = [0u8; 4096];
                while let Ok(n) = err.read(&mut buf).await {
                    if n == 0 {
                        break;
                    }
                    let mut t = tail_c.lock().unwrap_or_else(|e| e.into_inner());
                    t.push_str(&String::from_utf8_lossy(&buf[..n]));
                    if t.len() > 8_192 {
                        let cut = t.len() - 8_192;
                        let cut = (cut..t.len()).find(|i| t.is_char_boundary(*i)).unwrap_or(t.len());
                        t.drain(..cut);
                    }
                }
            });
        }

        // Read stdout lines to discover the loopback listening URL.
        if let Some(out) = stdout {
            let host_out = Arc::clone(self);
            self.runtime.spawn(async move {
                let mut lines = BufReader::new(out).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    if let Some(url) = opencode_protocol::listening_url(&line) {
                        host_out.listening_at(url);
                    }
                }
            });
        }

        // Wait for process exit or explicit stop/kill.
        let host_wait = Arc::clone(self);
        self.runtime.spawn(async move {
            let _stdin_hold = _stdin;
            tokio::select! {
                _ = child.wait() => {}
                _ = kill_rx => {
                    drop(_stdin_hold);
                    let _ = child.start_kill();
                    let _ = tokio::time::timeout(Duration::from_secs(2), child.wait()).await;
                }
            }
            let stderr_text = tail.lock().unwrap_or_else(|e| e.into_inner()).trim().to_string();
            host_wait.exited(stderr_text);
        });
    }

    fn listening_at(self: &Arc<Self>, url: String) {
        {
            let mut inner = self.lock();
            if inner.state != HostState::Starting || inner.base_url.is_some() {
                return;
            }
            inner.base_url = Some(url);
        }
        let host = Arc::clone(self);
        self.runtime.spawn(async move {
            // The server announces its port before every route is mounted: retry `/api/info` briefly.
            for attempt in 0..10u64 {
                let info = host.send("GET", "/api/info", &[], None, Duration::from_secs(5)).await;
                if host.lock().state != HostState::Starting {
                    return;
                }
                if info.ok() {
                    let reported = info.json.as_ref().and_then(|j| j.get("version")).and_then(Value::as_str).map(str::to_string);
                    let effective = reported.clone().or_else(|| host.lock().version.clone());
                    if !opencode_protocol::supports_version(effective.as_deref()) {
                        host.fail(OpenCodeServerError::Unsupported(reported));
                        return;
                    }
                    if let Some(v) = reported {
                        host.lock().version = Some(v);
                    }
                    host.open_stream();
                    return;
                }
                if info.status == 401 {
                    host.fail(OpenCodeServerError::Launch("The OpenCode server rejected Nook's password.".into()));
                    return;
                }
                if info.not_found() {
                    let ver = host.lock().version.clone();
                    host.fail(OpenCodeServerError::Unsupported(ver));
                    return;
                }
                tokio::time::sleep(Duration::from_millis(200 * (attempt + 1))).await;
            }
            host.fail(OpenCodeServerError::Launch("The OpenCode server did not answer.".into()));
        });
    }

    fn open_stream(self: &Arc<Self>) {
        let base_url = {
            let inner = self.lock();
            if inner.state == HostState::Stopped {
                return;
            }
            let Some(u) = inner.base_url.clone() else { return };
            u
        };
        let url = format!("{base_url}/api/event");
        let auth = opencode_protocol::authorization(&self.password);
        let client = self.client.clone();
        let host = Arc::clone(self);
        let handle = self.runtime.spawn(async move {
            let result = run_sse_stream(&client, &url, &auth, &host).await;
            let err = result.err();
            host.stream_ended(err);
        });
        let mut inner = self.lock();
        if let Some(prev) = inner.stream_task.replace(handle.abort_handle()) {
            prev.abort();
        }
    }

    fn received_events(&self, events: Vec<OpenCodeEvent>) {
        let mut notify_reconnected = false;
        let mut ready_waiters = Vec::new();
        {
            let mut inner = self.lock();
            if inner.state == HostState::Stopped {
                return;
            }
            if events.iter().any(|e| matches!(e, OpenCodeEvent::Connected)) {
                inner.stream_failures = 0;
                if inner.state == HostState::Starting {
                    inner.state = HostState::Ready;
                    inner.ever_connected = true;
                    if let Some(t) = inner.timeout_task.take() {
                        t.abort();
                    }
                    ready_waiters = std::mem::take(&mut inner.waiters);
                } else if inner.ever_connected {
                    notify_reconnected = true;
                }
            }
        }
        for waiter in ready_waiters {
            let _ = waiter.send(Ok(()));
        }
        if notify_reconnected {
            (self.callbacks.on_reconnected)();
        }
        let work: Vec<OpenCodeEvent> = events.into_iter().filter(|e| !matches!(e, OpenCodeEvent::Connected)).collect();
        if !work.is_empty() {
            (self.callbacks.on_events)(work);
        }
    }

    fn stream_ended(self: &Arc<Self>, error: Option<String>) {
        let failures = {
            let mut inner = self.lock();
            if inner.state == HostState::Stopped {
                return;
            }
            inner.stream_failures += 1;
            inner.stream_failures
        };
        if failures > RECONNECT_ATTEMPTS {
            let message = error.unwrap_or_else(|| "The OpenCode server stopped sending events.".into());
            self.stop();
            (self.callbacks.on_gone)(message);
            return;
        }
        let host = Arc::clone(self);
        self.runtime.spawn(async move {
            tokio::time::sleep(Duration::from_secs(failures as u64)).await;
            if host.is_running() {
                host.open_stream();
            }
        });
    }

    fn exited(&self, stderr: String) {
        let (was_ready, waiters) = {
            let mut inner = self.lock();
            if inner.state == HostState::Stopped {
                return;
            }
            let was_ready = inner.state == HostState::Ready;
            inner.state = HostState::Stopped;
            inner.pid = None;
            inner.kill = None;
            if let Some(t) = inner.timeout_task.take() {
                t.abort();
            }
            if let Some(s) = inner.stream_task.take() {
                s.abort();
            }
            (was_ready, std::mem::take(&mut inner.waiters))
        };
        if was_ready {
            (self.callbacks.on_gone)(stderr);
        } else {
            for waiter in waiters {
                let _ = waiter.send(Err(OpenCodeServerError::Exited(stderr.clone())));
            }
        }
    }

    fn fail(&self, error: OpenCodeServerError) {
        let waiters = {
            let mut inner = self.lock();
            if inner.state != HostState::Starting {
                return;
            }
            inner.state = HostState::Stopped;
            inner.pid = None;
            if let Some(t) = inner.timeout_task.take() {
                t.abort();
            }
            if let Some(s) = inner.stream_task.take() {
                s.abort();
            }
            if let Some(k) = inner.kill.take() {
                let _ = k.send(());
            }
            std::mem::take(&mut inner.waiters)
        };
        for waiter in waiters {
            let _ = waiter.send(Err(error.clone()));
        }
    }

    /// Stops the server process and its SSE stream; any pending startup waiters hear it stopped.
    pub fn stop(&self) {
        let waiters = {
            let mut inner = self.lock();
            let was_starting = inner.state == HostState::Starting;
            inner.state = HostState::Stopped;
            inner.pid = None;
            if let Some(t) = inner.timeout_task.take() {
                t.abort();
            }
            if let Some(s) = inner.stream_task.take() {
                s.abort();
            }
            if let Some(k) = inner.kill.take() {
                let _ = k.send(());
            }
            if was_starting {
                std::mem::take(&mut inner.waiters)
            } else {
                Vec::new()
            }
        };
        for waiter in waiters {
            let _ = waiter.send(Err(OpenCodeServerError::Exited(String::new())));
        }
    }

    /// Sends one authenticated JSON HTTP request to the loopback server. Never panics.
    pub async fn send(
        &self,
        method: &str,
        path: &str,
        query: &[(String, String)],
        body: Option<Value>,
        timeout: Duration,
    ) -> OpenCodeReply {
        let Some(base_url) = self.lock().base_url.clone() else {
            return OpenCodeReply { status: 0, json: None, error: Some("The OpenCode server is not running.".into()) };
        };
        let mut url = match url::Url::parse(&format!("{base_url}{path}")) {
            Ok(u) => u,
            Err(_) => return OpenCodeReply { status: 0, json: None, error: Some("Bad request path".into()) },
        };
        if !query.is_empty() {
            {
                let mut pairs = url.query_pairs_mut();
                for (k, v) in query {
                    pairs.append_pair(k, v);
                }
            }
            // Match macOS: `+` in folder paths must stay percent-encoded rather than decoded as a space.
            if let Some(q) = url.query().map(|q| q.replace('+', "%2B")) {
                url.set_query(Some(&q));
            }
        }
        let Ok(http_method) = reqwest::Method::from_bytes(method.as_bytes()) else {
            return OpenCodeReply { status: 0, json: None, error: Some("Bad HTTP method".into()) };
        };
        let mut req = self
            .client
            .request(http_method, url)
            .timeout(timeout)
            .header(reqwest::header::AUTHORIZATION, opencode_protocol::authorization(&self.password))
            .header(reqwest::header::ACCEPT, "application/json");
        if let Some(b) = body {
            req = req.json(&b);
        }
        match req.send().await {
            Ok(resp) => {
                let status = resp.status().as_u16();
                let bytes = resp.bytes().await.unwrap_or_default();
                let json = (!bytes.is_empty()).then(|| serde_json::from_slice::<Value>(&bytes).ok()).flatten();
                let error = if (200..300).contains(&status) {
                    None
                } else {
                    Some(json.as_ref().and_then(opencode_protocol::error_message).unwrap_or_else(|| format!("HTTP {status}")))
                };
                OpenCodeReply { status, json, error }
            }
            Err(e) => OpenCodeReply { status: 0, json: None, error: Some(e.to_string()) },
        }
    }
}

async fn run_sse_stream(client: &reqwest::Client, url: &str, authorization: &str, host: &Arc<OpenCodeServerHost>) -> Result<(), String> {
    let resp = client
        .get(url)
        .header(reqwest::header::AUTHORIZATION, authorization)
        .header(reqwest::header::ACCEPT, "text/event-stream")
        .header(reqwest::header::CACHE_CONTROL, "no-cache")
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = resp.status();
    if !status.is_success() {
        return Err(format!("HTTP {}", status.as_u16()));
    }
    let mut stream = resp.bytes_stream();
    let mut parser = SseParser::new();
    let mut pending = Vec::<u8>::new();
    loop {
        let next = tokio::time::timeout(STREAM_SILENCE_TIMEOUT, stream.next()).await;
        match next {
            Err(_) => return Err("The OpenCode event stream timed out.".into()),
            Ok(None) => return Ok(()),
            Ok(Some(Err(e))) => return Err(e.to_string()),
            Ok(Some(Ok(chunk))) => {
                pending.extend_from_slice(&chunk);
                let text = take_valid_utf8(&mut pending);
                if text.is_empty() {
                    continue;
                }
                let events: Vec<OpenCodeEvent> = parser.feed(&text).into_iter().filter_map(|f| OpenCodeEvent::decode(&f.data)).collect();
                if !events.is_empty() {
                    host.received_events(events);
                }
            }
        }
    }
}

/// Extracts the longest valid UTF-8 prefix from `buf`, keeping any incomplete trailing multi-byte sequence for the next
/// chunk.
fn take_valid_utf8(buf: &mut Vec<u8>) -> String {
    match std::str::from_utf8(buf) {
        Ok(s) => {
            let out = s.to_string();
            buf.clear();
            out
        }
        Err(e) => {
            let valid = e.valid_up_to();
            let mut out = String::from_utf8_lossy(&buf[..valid]).into_owned();
            if let Some(len) = e.error_len() {
                // Truly invalid byte sequence: replace and advance past it so the stream never stalls.
                out.push('\u{FFFD}');
                buf.drain(..valid + len);
            } else {
                // Incomplete trailing UTF-8 character: wait for the remaining bytes.
                buf.drain(..valid);
            }
            out
        }
    }
}

/// Reads `opencode --version` with a 10-second timeout; `None` if it fails or prints no recognizable version.
fn installed_version(executable: &str) -> Option<String> {
    let base: BTreeMap<String, String> = std::env::vars().collect();
    let env = command::environment(&base, executable, &BTreeMap::new());
    let mut cmd = std::process::Command::new(executable);
    cmd.arg("--version")
        .env_clear()
        .envs(&env)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000);
    }
    let mut child = cmd.spawn().ok()?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if started.elapsed() < Duration::from_secs(10) => {
                std::thread::sleep(Duration::from_millis(25));
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    let mut buf = Vec::new();
    if let Some(mut out) = child.stdout.take() {
        let mut limited = std::io::Read::take(&mut out, 4096);
        let _ = std::io::Read::read_to_end(&mut limited, &mut buf);
    }
    let text = String::from_utf8_lossy(&buf);
    for line in text.lines() {
        if let Some((maj, min, patch)) = opencode_protocol::parse_version(line) {
            return Some(format!("{maj}.{min}.{patch}"));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utf8_chunk_boundary_preserves_multibyte_chars() {
        let full = "Hallo € wereld 🚀!";
        let bytes = full.as_bytes();
        let mut buf = Vec::new();
        let mut reconstructed = String::new();
        for &b in bytes {
            buf.push(b);
            reconstructed.push_str(&take_valid_utf8(&mut buf));
        }
        assert!(buf.is_empty());
        assert_eq!(reconstructed, full);
    }
}
