//! Agents that speak JSON-RPC over stdin/stdout (`TurnDriver` on the Mac): Codex through `codex app-server` and the
//! ACP agents (Gemini CLI, OpenCode, Cursor, Grok, Antigravity). Like every session Nook runs, one process per turn:
//! the driver opens (or resumes) the agent's conversation, sends the prompt, turns what the agent says into the same
//! events Claude Code's stream gives ([`ClaudeEvent`]), and answers the agent's requests (approvals, questions) once you
//! decide. The manager only feeds it lines and writes what it returns.
//!
//! Which transport an agent uses is [`RunProvider::transport`]; [`plan`] picks the driver from it, and falls back to the
//! agent's one-shot mode (`codex exec`, Gemini CLI's headless mode) when this version of the agent has no server.

use std::collections::{BTreeMap, HashMap};
use std::path::Path;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};

use serde_json::{json, Value};

use super::command::{self, CommandInput, LaunchSpec};
use super::models::{RunProvider, Transport};
use super::parsers::ClaudeEvent;
use crate::i18n::{tr, trf};

/// What a driver hands the manager for one line of the agent's output.
#[derive(Debug, Clone, PartialEq)]
pub enum DriverEvent {
    /// The same events as Claude Code's stream: text, thinking, tools, approvals, questions, the end of the turn.
    Claude(ClaudeEvent),
    /// A file the agent changed ("modified", "written", "deleted").
    FileChange { path: String, kind: String },
    /// A note in the timeline.
    System(String),
}

/// One step: events for the timeline and lines to write to the agent.
#[derive(Debug, Default)]
pub struct Step {
    pub events: Vec<DriverEvent>,
    pub replies: Vec<String>,
}

impl Step {
    pub fn event(&mut self, e: ClaudeEvent) {
        self.events.push(DriverEvent::Claude(e));
    }
}

/// A conversation with one agent process. Everything happens under the manager's lock: nothing here blocks.
pub trait Driver: Send {
    /// A line from the agent's stdout.
    fn receive(&mut self, line: &str) -> Step;
    /// Your answer to an approval (`request_id` as the driver named it). Lines to write; empty for an unknown request.
    fn decide(&mut self, request_id: &str, allow: bool, always: bool) -> Vec<String>;
    /// Your answers to a question, per question text. `None`: not a question of this driver.
    fn answer(&mut self, _request_id: &str, _answers: &[(String, Vec<String>)]) -> Option<Vec<String>> {
        None
    }
    /// A message for the running turn. `None`: this agent cannot be steered now (it goes in the queue instead).
    fn steer(&mut self, _text: &str) -> Option<Vec<String>> {
        None
    }
    /// Lines that ask the agent to end the turn.
    fn interrupt(&mut self) -> Vec<String>;
    /// Variables of your own environment the agent must not get (an account or project of someone else's).
    fn removed_environment(&self) -> &'static [&'static str] {
        &[]
    }
}

/// How a turn starts: the process, its driver (none for a one-shot agent), and a note for the timeline.
pub struct Planned {
    pub spec: LaunchSpec,
    pub driver: Option<Box<dyn Driver>>,
    /// Shown once per session (the manager skips it when the timeline already has it).
    pub note: Option<String>,
}

/// Picks how this turn runs, from the agent's transport. Probes are cached: call [`warm`] first, outside any lock.
pub fn plan(input: &CommandInput) -> Result<Planned, String> {
    match input.provider.transport() {
        Transport::ClaudeStream => Ok(Planned { spec: command::spec(input), driver: None, note: None }),
        Transport::CodexAppServer => {
            if probe(input.provider, &input.executable) != Some(false) {
                let (spec, driver) = super::codex_app_server::launch(input);
                Ok(Planned { spec, driver: Some(Box::new(driver)), note: None })
            } else {
                Ok(Planned {
                    spec: command::spec(input),
                    driver: None,
                    note: Some(tr("Deze Codex heeft geen bruikbare app-server; Nook gebruikt codex exec.", "This Codex has no usable app-server; Nook uses codex exec.").into()),
                })
            }
        }
        Transport::Acp => {
            // Gemini CLI before ACP: its headless mode, as before.
            if input.provider == RunProvider::Gemini && probe(input.provider, &input.executable) == Some(false) {
                return Ok(Planned { spec: command::spec(input), driver: None, note: None });
            }
            let (spec, driver) = super::acp::launch(input)?;
            Ok(Planned { spec, driver: Some(Box::new(driver)), note: None })
        }
    }
}

/// The program a session of `provider` runs, from the one Nook found for the agent: Antigravity runs its ACP server
/// (found next to `agy`, in Nook's tools folder or on `PATH`), every other agent the program itself.
pub fn session_executable(provider: RunProvider, found: Option<String>) -> Option<String> {
    match provider {
        RunProvider::Antigravity => super::antigravity::server(found.as_deref().unwrap_or("")),
        RunProvider::Claude | RunProvider::Codex | RunProvider::Gemini | RunProvider::Opencode | RunProvider::Cursor | RunProvider::Grok => {
            found
        }
    }
}

// MARK: Can this version of the agent run as a server?

type ProbeKey = (String, Option<SystemTime>);

fn probes() -> &'static Mutex<HashMap<ProbeKey, bool>> {
    static PROBES: OnceLock<Mutex<HashMap<ProbeKey, bool>>> = OnceLock::new();
    PROBES.get_or_init(Default::default)
}

fn probe_key(executable: &str) -> ProbeKey {
    let modified = std::fs::metadata(executable).and_then(|m| m.modified()).ok();
    (executable.to_string(), modified)
}

/// The cached answer: `Some(true)` the server is there, `Some(false)` it is not, `None` not asked (or nothing to ask).
pub fn probe(provider: RunProvider, executable: &str) -> Option<bool> {
    probe_arguments(provider)?;
    probes().lock().unwrap_or_else(|e| e.into_inner()).get(&probe_key(executable)).copied()
}

/// What to run to find out, and how to read the answer: Codex has `app-server` when its help for it works; Gemini CLI
/// speaks ACP when its help lists `--acp`.
fn probe_arguments(provider: RunProvider) -> Option<(&'static [&'static str], Option<&'static str>)> {
    match provider.transport() {
        Transport::CodexAppServer => Some((&["app-server", "--help"], None)),
        Transport::Acp if provider == RunProvider::Gemini => Some((&["--help"], Some("--acp"))),
        Transport::Acp | Transport::ClaudeStream => None,
    }
}

/// Asks the agent once per program (and again after it changed on disk). Blocks for at most a few seconds: call it
/// before taking a lock. An agent that does not answer in time counts as having the server; the turn says otherwise.
pub fn warm(provider: RunProvider, executable: &str) {
    let Some((arguments, needle)) = probe_arguments(provider) else { return };
    let key = probe_key(executable);
    if probes().lock().unwrap_or_else(|e| e.into_inner()).contains_key(&key) {
        return;
    }
    let base: BTreeMap<String, String> = std::env::vars().collect();
    let env = command::environment(&base, executable, &BTreeMap::new());
    let mut cmd = std::process::Command::new(executable);
    cmd.args(arguments)
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
    let Ok(mut child) = cmd.spawn() else { return };
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if started.elapsed() < Duration::from_secs(8) => std::thread::sleep(Duration::from_millis(25)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
        }
    };
    let Some(status) = status else { return };
    let mut text = String::new();
    if let Some(mut out) = child.stdout.take() {
        let _ = std::io::Read::read_to_string(&mut out, &mut text);
    }
    if let Some(mut err) = child.stderr.take() {
        let _ = std::io::Read::read_to_string(&mut err, &mut text);
    }
    let available = match needle {
        Some(n) => text.contains(n),
        None => status.success(),
    };
    probes().lock().unwrap_or_else(|e| e.into_inner()).insert(key, available);
}

// MARK: JSON-RPC

/// A request id as the agent sent it: a number or a string.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum RpcId {
    Int(i64),
    Text(String),
}

impl RpcId {
    pub fn read(v: Option<&Value>) -> Option<Self> {
        match v? {
            Value::Number(n) => n.as_i64().map(Self::Int),
            Value::String(s) => Some(Self::Text(s.clone())),
            _ => None,
        }
    }

    pub fn json(&self) -> Value {
        match self {
            Self::Int(n) => json!(n),
            Self::Text(s) => json!(s),
        }
    }

    pub fn text(&self) -> String {
        match self {
            Self::Int(n) => n.to_string(),
            Self::Text(s) => s.clone(),
        }
    }
}

/// One line from the agent.
#[derive(Debug, Clone, PartialEq)]
pub enum Message {
    Response { id: i64, result: Value, error: Option<String> },
    Notification { method: String, params: Value },
    Request { id: RpcId, method: String, params: Value },
}

pub fn parse(line: &str) -> Option<Message> {
    let object: Value = serde_json::from_str(line).ok()?;
    if let Some(method) = object.get("method").and_then(Value::as_str) {
        let params = object.get("params").cloned().unwrap_or_else(|| json!({}));
        return Some(match RpcId::read(object.get("id")) {
            Some(id) => Message::Request { id, method: method.into(), params },
            None => Message::Notification { method: method.into(), params },
        });
    }
    let id = object.get("id")?.as_i64()?;
    if let Some(error) = object.get("error").filter(|e| !e.is_null()) {
        let message = error.get("message").and_then(Value::as_str).unwrap_or("The agent returned an error.");
        return Some(Message::Response { id, result: Value::Null, error: Some(message.into()) });
    }
    Some(Message::Response { id, result: object.get("result").cloned().unwrap_or(Value::Null), error: None })
}

/// Builds lines. `jsonrpc`: ACP wants `"jsonrpc": "2.0"` in every message; Codex leaves it out.
#[derive(Debug, Clone, Copy)]
pub struct Wire {
    pub jsonrpc: bool,
}

impl Wire {
    fn line(&self, mut v: Value) -> String {
        if self.jsonrpc {
            v["jsonrpc"] = json!("2.0");
        }
        format!("{v}\n")
    }

    pub fn request(&self, id: i64, method: &str, params: Value) -> String {
        self.line(json!({"id": id, "method": method, "params": params}))
    }

    pub fn notification(&self, method: &str, params: Value) -> String {
        self.line(json!({"method": method, "params": params}))
    }

    pub fn response(&self, id: &RpcId, result: Value) -> String {
        self.line(json!({"id": id.json(), "result": result}))
    }

    pub fn error(&self, id: &RpcId, code: i64, message: &str) -> String {
        self.line(json!({"id": id.json(), "error": {"code": code, "message": message}}))
    }
}

/// The next id for Nook's own requests, kept inside a signed 32-bit integer (some JSON-RPC libraries reject more).
pub fn next_id(id: &mut i64) -> i64 {
    let current = *id;
    *id = if current < 1 || current >= i32::MAX as i64 { 1 } else { current + 1 };
    current
}

/// The agent wants you to sign in first (ACP's "Authentication required").
pub fn needs_sign_in(message: &str) -> bool {
    let text = message.to_lowercase();
    [
        "authentication required",
        "auth required",
        "auth_required",
        "unauthenticated",
        "not authenticated",
        "please authenticate",
        "requires authentication",
        "not logged in",
        "login required",
    ]
    .iter()
    .any(|t| text.contains(t))
}

/// The conversation to continue is gone (cleared, made elsewhere, or by an older version of the agent).
pub fn session_gone(message: &str) -> bool {
    let text = message.to_lowercase();
    if !["session", "thread", "conversation", "rollout"].iter().any(|t| text.contains(t)) {
        return false;
    }
    ["not found", "no such", "does not exist", "doesn't exist", "unknown", "no rollout", "invalid", "missing", "no conversation found"]
        .iter()
        .any(|t| text.contains(t))
}

/// Instructions for the first prompt of a new conversation, with Nook's bridge note when the bridge is on.
pub fn instructions(input: &CommandInput) -> String {
    let own = input.instructions.trim().to_string();
    if input.bridge.is_some() {
        [own, super::bridge::INSTRUCTIONS.to_string()].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join("\n\n")
    } else {
        own
    }
}

/// The line that keeps Plan mode to a plan.
pub const PLAN_ONLY: &str = "Create a plan only; do not make any changes.";

/// The `{agent} cannot load an earlier conversation` note.
pub fn no_load_note(provider: RunProvider) -> String {
    trf(
        "{agent} kan een eerder gesprek niet laden; dit wordt een nieuw gesprek.",
        "{agent} cannot load an earlier conversation; this becomes a new one.",
        &[("agent", &provider.display_name())],
    )
}

/// Is `path` a program that can run?
pub fn is_program(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

#[cfg(all(test, unix))]
#[path = "driver_tests.rs"]
mod end_to_end;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn messages() {
        assert_eq!(
            parse(r#"{"id":3,"result":{"ok":true}}"#),
            Some(Message::Response { id: 3, result: json!({"ok": true}), error: None })
        );
        assert_eq!(
            parse(r#"{"jsonrpc":"2.0","id":4,"error":{"code":-32000,"message":"Authentication required"}}"#),
            Some(Message::Response { id: 4, result: Value::Null, error: Some("Authentication required".into()) })
        );
        assert_eq!(
            parse(r#"{"id":"a","method":"session/request_permission","params":{}}"#),
            Some(Message::Request { id: RpcId::Text("a".into()), method: "session/request_permission".into(), params: json!({}) })
        );
        assert!(matches!(parse(r#"{"method":"turn/started"}"#), Some(Message::Notification { .. })));
        assert_eq!(parse("Open the following link"), None);
        let acp = Wire { jsonrpc: true };
        assert!(acp.request(1, "initialize", json!({})).contains(r#""jsonrpc":"2.0""#));
        assert!(!Wire { jsonrpc: false }.request(1, "initialize", json!({})).contains("jsonrpc"));
        let mut id = i32::MAX as i64;
        assert_eq!(next_id(&mut id), i32::MAX as i64);
        assert_eq!(id, 1);
    }

    #[test]
    fn error_texts() {
        assert!(needs_sign_in("Authentication required"));
        assert!(!needs_sign_in("rate limited"));
        assert!(session_gone("Session not found: abc"));
        assert!(session_gone("no rollout found for thread id x"));
        assert!(!session_gone("Not found"));
    }
}
