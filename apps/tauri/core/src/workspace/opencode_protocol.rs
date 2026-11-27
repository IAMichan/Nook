//! OpenCode 2's own server (`opencode serve`): the HTTP API and event stream its TUI uses (`OpenCodeServerProtocol` on
//! the Mac). Nook starts one per account on `127.0.0.1` with a port the system picks and a password of its own
//! (`opencode_server`), and drives every OpenCode session of that account through it. It says more than OpenCode's ACP
//! server: questions as forms, a reason with a denial, the model's variants (Nook's effort), per-step tokens and cost,
//! and an interrupt that answers whether anything was running.
//!
//! This module only builds requests and decodes responses and SSE events, with zero I/O, so tests run it directly
//! against recorded `opencode serve` streams without OpenCode installed.

use std::collections::{BTreeMap, HashMap, HashSet};

use base64::Engine;
use rand::Rng;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use uuid::Uuid;

use super::driver::SlashCommand;
use super::models::{ExecutionMode, PermissionPolicy};
use crate::agents::models::{QuestionItem, QuestionOption};

/// The first OpenCode 2 whose server API Nook speaks. OpenCode 1.x also has `serve`, with an older API: those run over ACP.
pub const MINIMUM_VERSION: (u64, u64, u64) = (2, 0, 18);

/// Loopback only, and a port the system picks; the URL is read from what the server prints.
pub const ARGUMENTS: &[&str] = &["serve", "--hostname", "127.0.0.1", "--port", "0"];

/// OpenCode 2 requires a password and prints a generated one otherwise: Nook gives its own through the environment
/// (never on the command line). `OPENCODE_SERVER_PASSWORD` is 1.x's name for it and is dropped.
pub const PASSWORD_ENV: &str = "OPENCODE_PASSWORD";
pub const REMOVED_ENV: &[&str] = &["OPENCODE_SERVER_PASSWORD"];

/// HTTP Basic user name.
pub const USER: &str = "opencode";

/// Words OpenCode tells the model with a denial that has no reason of its own: a rejection without a message ends
/// the whole execution, as Stop would.
pub const DECLINED_MESSAGE: &str = "The user declined this request.";

/// Parses the first `major.minor.patch` (or `major.minor`) version triple out of CLI output like `"2.2.7"` or
/// `"opencode v2.3.0-beta.1"`.
pub fn parse_version(raw: &str) -> Option<(u64, u64, u64)> {
    let bytes = raw.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i].is_ascii_digit() {
            let start = i;
            while i < bytes.len() && (bytes[i].is_ascii_digit() || bytes[i] == b'.') {
                i += 1;
            }
            let token = &raw[start..i];
            let mut parts = token.split('.').filter(|p| !p.is_empty());
            if let (Some(maj), Some(min)) = (parts.next(), parts.next()) {
                if let (Ok(major), Ok(minor)) = (maj.parse::<u64>(), min.parse::<u64>()) {
                    let patch = parts.next().and_then(|p| p.parse::<u64>().ok()).unwrap_or(0);
                    return Some((major, minor, patch));
                }
            }
        } else {
            i += 1;
        }
    }
    None
}

/// True when `version` is OpenCode 2.0.18 or newer.
pub fn supports_version(version: Option<&str>) -> bool {
    version.and_then(parse_version).is_some_and(|v| v >= MINIMUM_VERSION)
}

/// A fresh random password: 32 bytes from the system's secure generator, base64url without padding.
pub fn make_password() -> String {
    let mut bytes = [0u8; 32];
    rand::rng().fill_bytes(&mut bytes);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

/// The `Authorization` header (HTTP Basic, UTF-8 credentials).
pub fn authorization(password: &str) -> String {
    format!("Basic {}", base64::engine::general_purpose::STANDARD.encode(format!("{USER}:{password}")))
}

/// The server's address from its stdout line: `"Server listening on http://127.0.0.1:60163"`. Only loopback counts.
pub fn listening_url(line: &str) -> Option<String> {
    const PREFIX: &str = "http://127.0.0.1:";
    let at = line.find(PREFIX)?;
    let rest = &line[at + PREFIX.len()..];
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    let port: u16 = digits.parse().ok()?;
    if port == 0 {
        return None;
    }
    Some(format!("{PREFIX}{port}"))
}

/// `location[directory]=...`: which folder (OpenCode's "location") a request is about.
pub fn location_query(directory: &str) -> Vec<(String, String)> {
    vec![("location[directory]".into(), directory.into())]
}

// MARK: - Requests

/// A model as OpenCode names it, from Nook's `"provider/model"` (the id its ACP server uses too), with the session's
/// effort as the model's variant. `None` for the agent's default.
pub fn model_ref(model: &str, effort: Option<&str>) -> Option<Value> {
    let trimmed = model.trim();
    let slash = trimmed.find('/')?;
    if slash == 0 {
        return None;
    }
    let provider = &trimmed[..slash];
    let id = &trimmed[slash + 1..];
    if id.is_empty() {
        return None;
    }
    let mut obj = Map::new();
    obj.insert("providerID".into(), Value::String(provider.into()));
    obj.insert("id".into(), Value::String(id.into()));
    if let Some(v) = effort.filter(|v| !v.is_empty()) {
        obj.insert("variant".into(), Value::String(v.into()));
    }
    Some(Value::Object(obj))
}

/// `"provider/model"` of a model reference, and its variant (`"default"` means `None`).
pub fn parse_model_ref(value: Option<&Value>) -> Option<(String, Option<String>)> {
    let obj = value?.as_object()?;
    let provider = obj.get("providerID")?.as_str()?;
    let id = obj.get("id")?.as_str()?;
    if provider.is_empty() || id.is_empty() {
        return None;
    }
    let variant = obj.get("variant").and_then(Value::as_str).filter(|v| !v.is_empty() && *v != "default").map(str::to_string);
    Some((format!("{provider}/{id}"), variant))
}

/// The agent for the session's mode: OpenCode's own `plan` agent reads and plans, `build` works.
pub fn agent_for_mode(mode: ExecutionMode) -> &'static str {
    match mode {
        ExecutionMode::Agent => "build",
        ExecutionMode::Plan => "plan",
    }
}

/// The name of Nook's bridge in OpenCode for one session: OpenCode hides tools of names over 64 characters.
pub fn bridge_server(run_id: Uuid) -> String {
    let hex = run_id.simple().to_string();
    format!("nook-{}", &hex[..16])
}

/// A permission rule (`Permission.Rule`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Rule {
    pub action: String,
    pub resource: String,
    pub effect: String,
}

impl Rule {
    pub fn new(action: impl Into<String>, resource: impl Into<String>, effect: impl Into<String>) -> Self {
        Self { action: action.into(), resource: resource.into(), effect: effect.into() }
    }

    pub fn json(&self) -> Value {
        json!({
            "action": self.action,
            "resource": self.resource,
            "effect": self.effect,
        })
    }
}

/// The session's rules for what it may do without asking. The last rule that matches wins, so the session's rights
/// come first, then what you allowed "for this session", then Plan mode's ban on edits, and last Nook's bridge: only
/// this session's own (one server serves every session of the folder).
pub fn rules(permission: PermissionPolicy, mode: ExecutionMode, grants: &[Rule], bridge_server: Option<&str>) -> Vec<Rule> {
    let mut out = match permission {
        PermissionPolicy::Bypass => vec![Rule::new("*", "*", "allow")],
        PermissionPolicy::AcceptEdits => {
            vec![Rule::new("shell", "*", "ask"), Rule::new("edit", "*", "allow"), Rule::new("external_directory", "*", "ask")]
        }
        PermissionPolicy::Ask => {
            vec![Rule::new("shell", "*", "ask"), Rule::new("edit", "*", "ask"), Rule::new("external_directory", "*", "ask")]
        }
    };
    out.extend(grants.iter().cloned());
    if mode == ExecutionMode::Plan {
        out.push(Rule::new("edit", "*", "deny"));
    }
    if let Some(bridge) = bridge_server {
        out.push(Rule::new("nook-*", "*", "deny"));
        out.push(Rule::new(format!("{bridge}_*"), "*", "allow"));
    }
    out
}

/// What "Always" allows for the rest of the session: the patterns OpenCode offers to save (`"ls *"`). Kept in the
/// session's rules rather than OpenCode's `"always"`, which it saves for the whole project.
pub fn grants(action: &str, save: &[String]) -> Vec<Rule> {
    if save.is_empty() {
        vec![Rule::new(action, "*", "allow")]
    } else {
        save.iter().map(|pattern| Rule::new(action, pattern, "allow")).collect()
    }
}

/// The answer to a permission request. A denial always carries a message, so the turn goes on without the action.
pub fn permission_reply(allow: bool, reason: &str) -> Value {
    if allow {
        return json!({ "decision": "once" });
    }
    let text = reason.trim();
    json!({
        "decision": "reject",
        "message": if text.is_empty() { DECLINED_MESSAGE } else { text },
    })
}

/// Percent-encodes a local file path into a `file://` URI.
pub fn file_uri(path: &str) -> String {
    // Use `url::Url::from_file_path` when possible for exact RFC 8089 encoding; fall back cleanly on relative/exotic paths.
    if let Ok(u) = url::Url::from_file_path(path) {
        return u.to_string();
    }
    let normalized = path.replace('\\', "/");
    let rooted = if normalized.starts_with('/') { normalized } else { format!("/{normalized}") };
    format!("file://{}", rooted.replace(' ', "%20"))
}

/// A prompt: your words and the files that go with them (pictures as `file:` links OpenCode reads itself).
pub fn prompt_body(text: &str, files: &[String]) -> Value {
    let mut body = Map::new();
    body.insert("text".into(), Value::String(text.into()));
    if !files.is_empty() {
        let attachments: Vec<Value> = files
            .iter()
            .map(|path| {
                let name = path.rsplit(['/', '\\']).next().unwrap_or(path);
                json!({
                    "uri": file_uri(path),
                    "name": name,
                })
            })
            .collect();
        body.insert("files".into(), Value::Array(attachments));
    }
    Value::Object(body)
}

/// A new session in `directory`.
pub fn new_session_body(directory: &str, model: Option<Value>, agent: &str, session_rules: &[Rule]) -> Value {
    let mut body = Map::new();
    body.insert("location".into(), json!({ "directory": directory }));
    body.insert("agent".into(), Value::String(agent.into()));
    body.insert("permissions".into(), Value::Array(session_rules.iter().map(Rule::json).collect()));
    if let Some(m) = model {
        body.insert("model".into(), m);
    }
    Value::Object(body)
}

/// Nook's bridge as a local MCP server of OpenCode's.
pub fn bridge_config(command: &str, arguments: &[String], environment: &BTreeMap<String, String>) -> Value {
    let mut cmd = Vec::with_capacity(1 + arguments.len());
    cmd.push(command.to_string());
    cmd.extend(arguments.iter().cloned());
    json!({
        "config": {
            "type": "local",
            "command": cmd,
            "environment": environment,
        }
    })
}

/// The answer to a form: per field the chosen labels, one text for a single choice.
pub fn form_answer(form: &OpenCodeForm, answers: &HashMap<String, Vec<String>>) -> Value {
    let mut answer = Map::new();
    for field in &form.fields {
        let values: Vec<String> =
            answers.get(&field.key).into_iter().flatten().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect();
        if values.is_empty() {
            continue;
        }
        // A label shown for an option goes back as that option's value.
        let mapped: Vec<String> =
            values.into_iter().map(|v| field.options.iter().find(|opt| opt.label == v).map(|opt| opt.value.clone()).unwrap_or(v)).collect();
        if field.multi_select {
            answer.insert(field.key.clone(), Value::Array(mapped.into_iter().map(Value::String).collect()));
        } else {
            answer.insert(field.key.clone(), Value::String(mapped.join(", ")));
        }
    }
    json!({ "answer": Value::Object(answer) })
}

/// A `/` command of OpenCode's in a prompt: `/compact` alone, or a command it listed with what follows it.
pub fn parse_slash_command(prompt: &str, known: &[SlashCommand]) -> Option<(String, String)> {
    let trimmed = prompt.trim();
    let body = trimmed.strip_prefix('/')?;
    let name: String = body.chars().take_while(|c| !c.is_whitespace()).collect();
    if name.is_empty() {
        return None;
    }
    let rest = body[name.len()..].trim().to_string();
    if name == "compact" {
        return Some((name, rest));
    }
    known.iter().any(|c| c.name == name).then_some((name, rest))
}

// MARK: - Responses

/// A model OpenCode offers: Nook's id for it, its name, its variants (the effort levels) and context window.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenCodeModel {
    pub id: String,
    pub name: String,
    pub variants: Vec<String>,
    pub context_window: Option<u64>,
}

/// `GET /api/model` (and `/api/model/default`'s `data`): the enabled chat models.
pub fn parse_models(response: &Value) -> Vec<OpenCodeModel> {
    let Some(data) = response.get("data") else { return vec![] };
    let items: Vec<&Value> = match data {
        Value::Array(arr) => arr.iter().collect(),
        Value::Object(_) => vec![data],
        _ => return vec![],
    };
    items
        .into_iter()
        .filter_map(|item| {
            let obj = item.as_object()?;
            if obj.get("enabled").and_then(Value::as_bool) == Some(false) {
                return None;
            }
            if obj.get("type").and_then(Value::as_str).unwrap_or("chat") != "chat" {
                return None;
            }
            if obj.get("status").and_then(Value::as_str).unwrap_or("active") == "deprecated" {
                return None;
            }
            let provider = obj.get("providerID")?.as_str()?;
            let id = obj.get("id")?.as_str()?;
            let full = format!("{provider}/{id}");
            let name = obj.get("name").and_then(Value::as_str).map(|n| format!("{provider}/{n}")).unwrap_or_else(|| full.clone());
            let variants: Vec<String> = obj
                .get("variants")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|v| v.get("id").and_then(Value::as_str))
                .filter(|v| !v.is_empty())
                .map(str::to_string)
                .collect();
            let context_window = obj.get("limit").and_then(|l| l.get("context")).and_then(Value::as_u64);
            Some(OpenCodeModel { id: full, name, variants, context_window })
        })
        .collect()
}

/// `GET /api/command`: the commands to offer after `/`.
pub fn parse_commands(response: &Value) -> Vec<SlashCommand> {
    let Some(list) = response.get("data").and_then(Value::as_array) else { return vec![] };
    let mut seen = HashSet::new();
    list.iter()
        .filter_map(|item| {
            let name = item.get("name")?.as_str()?;
            if name.is_empty() || name.chars().any(char::is_whitespace) || !seen.insert(name.to_string()) {
                return None;
            }
            Some(SlashCommand {
                name: name.to_string(),
                detail: item.get("description").and_then(Value::as_str).unwrap_or("").to_string(),
                takes_input: true,
            })
        })
        .collect()
}

/// What Nook reads of a session (`GET /api/session/{id}` or `POST /api/session`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenCodeSessionInfo {
    pub id: String,
    /// The session that started this one (a subagent's).
    pub parent_id: Option<String>,
    pub directory: Option<String>,
    pub model: Option<String>,
    pub variant: Option<String>,
    /// Working right now (busy since it was last idle).
    pub busy: bool,
    /// How its last execution ended: succeeded, failed, interrupted.
    pub outcome: Option<String>,
}

/// `GET /api/session/{id}`: the session, `None` when the answer has none.
pub fn parse_session(response: &Value) -> Option<OpenCodeSessionInfo> {
    let data = response.get("data")?.as_object()?;
    let id = data.get("id")?.as_str()?.to_string();
    let time = data.get("time").and_then(Value::as_object);
    let busy_ts = time.and_then(|t| t.get("busy")).and_then(Value::as_f64);
    let idle_ts = time.and_then(|t| t.get("idle")).and_then(Value::as_f64);
    let busy = match (busy_ts, idle_ts) {
        (Some(b), Some(i)) => b > i,
        (Some(_), None) => true,
        (None, _) => false,
    };
    let parsed_model = parse_model_ref(data.get("model"));
    Some(OpenCodeSessionInfo {
        id,
        parent_id: data.get("parentID").and_then(Value::as_str).map(str::to_string),
        directory: data.get("location").and_then(|l| l.get("directory")).and_then(Value::as_str).map(str::to_string),
        model: parsed_model.as_ref().map(|(m, _)| m.clone()),
        variant: parsed_model.and_then(|(_, v)| v),
        busy,
        outcome: data.get("outcome").and_then(Value::as_str).map(str::to_string),
    })
}

/// The answer to `POST .../interrupt`: whether something was running and is stopped now.
pub fn parse_interrupted(response: &Value) -> Option<bool> {
    response.get("interrupted").and_then(Value::as_bool)
}

/// The text of an error answer (`{"_tag":...,"message":...}`).
pub fn error_message(response: &Value) -> Option<String> {
    let obj = response.as_object()?;
    obj.get("message").and_then(Value::as_str).or_else(|| obj.get("_tag").and_then(Value::as_str)).map(str::to_string)
}

// MARK: - SSE Framing

/// One Server-Sent Event frame from `GET /api/event`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SseFrame {
    pub event: Option<String>,
    pub id: Option<String>,
    pub data: String,
}

/// Incremental SSE parser (`SSEParser` on the Mac): accepts arbitrary byte/UTF-8 chunks and yields complete frames on
/// blank lines.
#[derive(Debug, Default)]
pub struct SseParser {
    buffer: String,
    event: Option<String>,
    id: Option<String>,
    data_lines: Vec<String>,
}

impl SseParser {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn feed(&mut self, chunk: &str) -> Vec<SseFrame> {
        self.buffer.push_str(chunk);
        let mut frames = Vec::new();
        while let Some(pos) = self.buffer.find('\n') {
            let mut line = self.buffer[..pos].to_string();
            self.buffer.drain(..=pos);
            if line.ends_with('\r') {
                line.pop();
            }
            if line.is_empty() {
                if !self.data_lines.is_empty() {
                    frames.push(SseFrame { event: self.event.take(), id: self.id.take(), data: self.data_lines.join("\n") });
                    self.data_lines.clear();
                } else {
                    self.event = None;
                    self.id = None;
                }
                continue;
            }
            if line.starts_with(':') {
                continue;
            }
            let (field, value) = match line.find(':') {
                Some(idx) => {
                    let v = &line[idx + 1..];
                    (&line[..idx], v.strip_prefix(' ').unwrap_or(v))
                }
                None => (line.as_str(), ""),
            };
            match field {
                "data" => self.data_lines.push(value.to_string()),
                "event" => self.event = Some(value.to_string()),
                "id" => self.id = Some(value.to_string()),
                _ => {}
            }
        }
        frames
    }
}

// MARK: - Events

/// Tokens of one model call (a "step").
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct OpenCodeTokens {
    pub input: u64,
    pub output: u64,
    pub reasoning: u64,
    pub cache_read: u64,
    pub cache_write: u64,
}

impl OpenCodeTokens {
    pub fn parse(raw: Option<&Value>) -> Option<Self> {
        let obj = raw?.as_object()?;
        let num = |m: &Map<String, Value>, k: &str| m.get(k).and_then(Value::as_u64).unwrap_or(0);
        let cache = obj.get("cache").and_then(Value::as_object);
        Some(Self {
            input: num(obj, "input"),
            output: num(obj, "output"),
            reasoning: num(obj, "reasoning"),
            cache_read: cache.map(|c| num(c, "read")).unwrap_or(0),
            cache_write: cache.map(|c| num(c, "write")).unwrap_or(0),
        })
    }

    /// What was in the context for this call.
    pub fn context(self) -> u64 {
        self.input + self.cache_read + self.cache_write
    }
}

/// A permission request (`permission.asked`): an action (`"shell"`, `"edit"`, `"external_directory"`, an MCP tool),
/// what it is about (`"ls"`, a path), and what "always" would save (`"ls *"`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenCodePermission {
    pub id: String,
    pub session_id: String,
    pub action: String,
    pub resources: Vec<String>,
    pub save: Vec<String>,
    pub call_id: Option<String>,
    pub message: Option<String>,
}

impl OpenCodePermission {
    pub fn parse(raw: &Value) -> Option<Self> {
        let obj = raw.as_object()?;
        let id = obj.get("id")?.as_str()?.to_string();
        let session_id = obj.get("sessionID")?.as_str()?.to_string();
        let action = obj.get("action")?.as_str()?.to_string();
        let strings = |key: &str| -> Vec<String> {
            obj.get(key).and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).map(str::to_string).collect()
        };
        Some(Self {
            id,
            session_id,
            action,
            resources: strings("resources"),
            save: strings("save"),
            call_id: obj.get("source").and_then(|s| s.get("id")).and_then(Value::as_str).map(str::to_string),
            message: obj.get("message").and_then(Value::as_str).map(str::to_string),
        })
    }
}

/// A form (`form.created`): the questions the agent asks (its `question` tool), or what a plugin asks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenCodeFormOption {
    pub value: String,
    pub label: String,
    pub description: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenCodeFormField {
    pub key: String,
    pub title: String,
    pub description: String,
    pub options: Vec<OpenCodeFormOption>,
    pub multi_select: bool,
    pub custom: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenCodeForm {
    pub id: String,
    pub session_id: String,
    pub title: String,
    pub fields: Vec<OpenCodeFormField>,
    pub call_id: Option<String>,
    /// Something Nook cannot show as a question (a link to open, a number, a field that depends on another): such a form
    /// is cancelled with a note.
    pub unsupported: Option<String>,
}

impl OpenCodeForm {
    pub fn parse(raw: Option<&Value>) -> Option<Self> {
        let obj = raw?.as_object()?;
        let id = obj.get("id")?.as_str()?.to_string();
        let session_id = obj.get("sessionID")?.as_str()?.to_string();
        let mut fields = Vec::new();
        let mut unsupported: Option<String> = None;
        for (index, item) in obj.get("fields").and_then(Value::as_array).into_iter().flatten().enumerate() {
            let Some(f) = item.as_object() else { continue };
            let kind = f.get("type").and_then(Value::as_str).unwrap_or("");
            if f.get("hidden").and_then(Value::as_bool) == Some(true) {
                unsupported.get_or_insert_with(|| "a hidden field".into());
            }
            if f.get("when").and_then(Value::as_array).is_some_and(|w| !w.is_empty()) {
                unsupported.get_or_insert_with(|| "a field that depends on another".into());
            }
            if kind != "string" && kind != "multiselect" {
                unsupported.get_or_insert_with(|| if kind == "external" { "a link to open".into() } else { format!("a {kind} value") });
                continue;
            }
            let options: Vec<OpenCodeFormOption> = f
                .get("options")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|opt| {
                    let o = opt.as_object()?;
                    let value = o.get("value").and_then(Value::as_str).unwrap_or("");
                    let label = o.get("label").and_then(Value::as_str).filter(|s| !s.is_empty()).unwrap_or(value);
                    if label.is_empty() {
                        return None;
                    }
                    let description = o.get("description").and_then(Value::as_str).filter(|s| !s.is_empty()).unwrap_or(label);
                    Some(OpenCodeFormOption {
                        value: if value.is_empty() { label.to_string() } else { value.to_string() },
                        label: label.to_string(),
                        description: description.to_string(),
                    })
                })
                .collect();
            fields.push(OpenCodeFormField {
                key: f.get("key").and_then(Value::as_str).map(str::to_string).unwrap_or_else(|| format!("q{index}")),
                title: f.get("title").and_then(Value::as_str).unwrap_or("").to_string(),
                description: f.get("description").and_then(Value::as_str).unwrap_or("").to_string(),
                options,
                multi_select: kind == "multiselect",
                custom: f.get("custom").and_then(Value::as_bool) == Some(true),
            });
        }
        let call_id = obj.get("metadata").and_then(|m| m.get("tool")).and_then(|t| t.get("id")).and_then(Value::as_str).map(str::to_string);
        if fields.is_empty() {
            unsupported.get_or_insert_with(|| "an empty form".into());
        }
        Some(Self {
            id,
            session_id,
            title: obj.get("title").and_then(Value::as_str).unwrap_or("").to_string(),
            fields,
            call_id,
            unsupported,
        })
    }

    /// The questions in Nook's question panel.
    pub fn question_items(&self) -> Vec<QuestionItem> {
        self.fields
            .iter()
            .map(|field| QuestionItem {
                question: if field.description.is_empty() { field.title.clone() } else { field.description.clone() },
                header: field.title.chars().take(16).collect(),
                options: field
                    .options
                    .iter()
                    .map(|o| QuestionOption { label: o.label.clone(), description: o.description.clone(), preview: String::new() })
                    .collect(),
                multi_select: field.multi_select,
            })
            .collect()
    }
}

/// How an execution (the work one prompt, or a steer, set off) ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpenCodeOutcome {
    Succeeded,
    Failed { kind: String, message: String },
    Interrupted { reason: String },
}

/// One event of the server's stream (`GET /api/event`), as far as Nook uses it.
#[derive(Debug, Clone, PartialEq)]
pub enum OpenCodeEvent {
    /// The stream is open: from now on nothing is missed.
    Connected,
    ExecutionStarted {
        session: String,
    },
    ExecutionEnded {
        session: String,
        outcome: OpenCodeOutcome,
    },
    /// More of an answer (`thinking: false`) or a thought, by the message and the part's place in it.
    TextDelta {
        session: String,
        item: String,
        thinking: bool,
        text: String,
    },
    /// The whole part: replaces what streamed.
    TextDone {
        session: String,
        item: String,
        thinking: bool,
        text: String,
    },
    /// The model starts writing a tool call.
    ToolStarted {
        session: String,
        call: String,
        name: String,
    },
    /// The call is complete and runs (or waits for permission).
    ToolCalled {
        session: String,
        call: String,
        input: Value,
    },
    ToolSucceeded {
        session: String,
        call: String,
        output: String,
        metadata: Value,
    },
    /// `kind`: `"aborted"` for a call Stop ended, `"permission.rejected"` for one you denied.
    ToolFailed {
        session: String,
        call: String,
        kind: String,
        message: String,
    },
    /// A model call ended: its tokens and cost.
    StepEnded {
        session: String,
        tokens: Option<OpenCodeTokens>,
        cost: Option<f64>,
    },
    Permission(OpenCodePermission),
    /// Answered (by Nook, or by another client of the same server).
    PermissionSettled {
        session: String,
        request: String,
    },
    Form(OpenCodeForm),
    FormSettled {
        session: String,
        form: String,
    },
    Retrying {
        session: String,
        message: String,
    },
    CompactionStarted {
        session: String,
    },
    CompactionEnded {
        session: String,
        failed: Option<String>,
    },
    /// The session runs another model now (`session.model.selected`): `"provider/model"`.
    ModelSelected {
        session: String,
        model: String,
        variant: Option<String>,
    },
    /// Anything else, kept only for its type and session.
    Other {
        kind: String,
        session: Option<String>,
    },
}

impl OpenCodeEvent {
    pub fn session_id(&self) -> Option<&str> {
        match self {
            Self::Connected => None,
            Self::ExecutionStarted { session }
            | Self::ExecutionEnded { session, .. }
            | Self::TextDelta { session, .. }
            | Self::TextDone { session, .. }
            | Self::ToolStarted { session, .. }
            | Self::ToolCalled { session, .. }
            | Self::ToolSucceeded { session, .. }
            | Self::ToolFailed { session, .. }
            | Self::StepEnded { session, .. }
            | Self::PermissionSettled { session, .. }
            | Self::FormSettled { session, .. }
            | Self::Retrying { session, .. }
            | Self::CompactionStarted { session }
            | Self::CompactionEnded { session, .. }
            | Self::ModelSelected { session, .. } => Some(session.as_str()),
            Self::Permission(p) => Some(p.session_id.as_str()),
            Self::Form(f) => Some(f.session_id.as_str()),
            Self::Other { session, .. } => session.as_deref(),
        }
    }

    /// One frame's `data`. `None` for what is not an event (a broken frame); an event of a type Nook does not read is
    /// `Other`, so a newer server's events never break the stream.
    pub fn decode(data: &str) -> Option<Self> {
        let object: Value = serde_json::from_str(data).ok()?;
        let kind = object.get("type")?.as_str()?;
        let body = object.get("data").and_then(Value::as_object);
        let session = body.and_then(|b| b.get("sessionID")).and_then(Value::as_str).map(str::to_string);
        let string = |key: &str| -> String { body.and_then(|b| b.get(key)).and_then(Value::as_str).unwrap_or("").to_string() };
        let item = || -> String {
            let msg = string("assistantMessageID");
            let ord = body
                .and_then(|b| b.get("ordinal"))
                .map(|v| match v {
                    Value::Number(n) => n.to_string(),
                    Value::String(s) => s.clone(),
                    _ => "0".into(),
                })
                .unwrap_or_else(|| "0".into());
            format!("{msg}:{ord}")
        };

        let Some(session) = session else {
            return Some(match kind {
                "server.connected" => Self::Connected,
                "form.created" => OpenCodeForm::parse(body.and_then(|b| b.get("form")))
                    .map(Self::Form)
                    .unwrap_or_else(|| Self::Other { kind: kind.into(), session: None }),
                _ => Self::Other { kind: kind.into(), session: None },
            });
        };

        Some(match kind {
            "session.execution.started" => Self::ExecutionStarted { session },
            "session.execution.succeeded" => Self::ExecutionEnded { session, outcome: OpenCodeOutcome::Succeeded },
            "session.execution.interrupted" => {
                Self::ExecutionEnded { session, outcome: OpenCodeOutcome::Interrupted { reason: string("reason") } }
            }
            "session.execution.failed" => {
                let err = body.and_then(|b| b.get("error"));
                Self::ExecutionEnded {
                    session,
                    outcome: OpenCodeOutcome::Failed {
                        kind: err.and_then(|e| e.get("type")).and_then(Value::as_str).unwrap_or("").into(),
                        message: error_text(err),
                    },
                }
            }
            "session.text.delta" | "session.reasoning.delta" => {
                Self::TextDelta { session, item: item(), thinking: kind.starts_with("session.reasoning"), text: string("delta") }
            }
            "session.text.ended" | "session.reasoning.ended" => {
                Self::TextDone { session, item: item(), thinking: kind.starts_with("session.reasoning"), text: string("text") }
            }
            "session.tool.input.started" => Self::ToolStarted { session, call: string("id"), name: string("name") },
            "session.tool.called" => Self::ToolCalled {
                session,
                call: string("id"),
                input: body.and_then(|b| b.get("input")).filter(|v| v.is_object()).cloned().unwrap_or_else(|| json!({})),
            },
            "session.tool.success" => Self::ToolSucceeded {
                session,
                call: string("id"),
                output: content_text(body.and_then(|b| b.get("content"))),
                metadata: body.and_then(|b| b.get("metadata")).filter(|v| v.is_object()).cloned().unwrap_or_else(|| json!({})),
            },
            "session.tool.failed" => {
                let err = body.and_then(|b| b.get("error"));
                Self::ToolFailed {
                    session,
                    call: string("id"),
                    kind: err.and_then(|e| e.get("type")).and_then(Value::as_str).unwrap_or("").into(),
                    message: error_text(err),
                }
            }
            "session.step.ended" | "session.step.failed" => Self::StepEnded {
                session,
                tokens: OpenCodeTokens::parse(body.and_then(|b| b.get("tokens"))),
                cost: body.and_then(|b| b.get("cost")).and_then(Value::as_f64),
            },
            "permission.asked" => body
                .map(|b| Value::Object(b.clone()))
                .and_then(|v| OpenCodePermission::parse(&v))
                .map(Self::Permission)
                .unwrap_or_else(|| Self::Other { kind: kind.into(), session: Some(session) }),
            "permission.replied" => Self::PermissionSettled { session, request: string("requestID") },
            "form.replied" | "form.cancelled" => Self::FormSettled { session, form: string("id") },
            "session.retry.scheduled" => Self::Retrying { session, message: error_text(body.and_then(|b| b.get("error"))) },
            "session.compaction.started" => Self::CompactionStarted { session },
            "session.compaction.ended" => Self::CompactionEnded { session, failed: None },
            "session.compaction.failed" => Self::CompactionEnded { session, failed: Some(error_text(body.and_then(|b| b.get("error")))) },
            "session.model.selected" => match parse_model_ref(body.and_then(|b| b.get("model"))) {
                Some((model, variant)) => Self::ModelSelected { session, model, variant },
                None => Self::Other { kind: kind.into(), session: Some(session) },
            },
            _ => Self::Other { kind: kind.into(), session: Some(session) },
        })
    }
}

fn error_text(error: Option<&Value>) -> String {
    let Some(obj) = error.and_then(Value::as_object) else { return String::new() };
    obj.get("message").and_then(Value::as_str).or_else(|| obj.get("type").and_then(Value::as_str)).unwrap_or("").to_string()
}

fn content_text(content: Option<&Value>) -> String {
    content
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|part| {
            (part.get("type").and_then(Value::as_str) == Some("text")).then(|| part.get("text").and_then(Value::as_str)).flatten()
        })
        .collect::<Vec<_>>()
        .join("\n")
}

// MARK: - Tool Mapping (`OpenCodeTools`)

/// Maps OpenCode tool inputs and names into the canonical shape Nook's timeline reads (`file_path`, `old_string`,
/// `new_string`, canonical tool names).
pub mod tools {
    use std::path::Path;

    use serde_json::Value;

    /// Normalizes a tool's input keys to Claude Code's conventions so diffs, file changes and summaries work identically.
    pub fn map_input(tool: &str, input: &Value, directory: &str) -> Value {
        let mut mapped = input.as_object().cloned().unwrap_or_default();
        if let Some(path) = mapped.get("path").and_then(Value::as_str).filter(|p| !p.is_empty()).map(str::to_string) {
            mapped.insert("file_path".into(), Value::String(absolute_path(&path, directory)));
        }
        if tool == "edit" {
            if let Some(old) = mapped.get("oldString").cloned() {
                mapped.insert("old_string".into(), old);
            }
            if let Some(new) = mapped.get("newString").cloned() {
                mapped.insert("new_string".into(), new);
            }
        }
        Value::Object(mapped)
    }

    /// Canonical tool name for timeline rows (matching `CanonicalTool.of` on the Mac).
    pub fn canonical_name(raw: &str) -> String {
        if raw.is_empty() {
            return "Tool".into();
        }
        if raw == "Bash" {
            return "Bash".into();
        }
        match raw.to_lowercase().as_str() {
            "bash" | "shell" | "shell_command" | "exec_command" | "container.exec" | "local_shell" | "local_shell_call"
            | "run_shell_command" | "powershell" | "run_command" | "run_in_terminal" | "run_terminal_cmd" | "terminal"
            | "nook terminal" => "Shell".into(),
            "edit"
            | "replace"
            | "str_replace"
            | "str_replace_editor"
            | "str_replace_based_edit_tool"
            | "strreplace"
            | "search_replace"
            | "edit_file"
            | "insert"
            | "apply_patch"
            | "patch" => "Edit".into(),
            "multiedit" => "MultiEdit".into(),
            "notebookedit" => "NotebookEdit".into(),
            "write" | "write_file" | "create" | "create_file" => "Write".into(),
            "delete" | "delete_file" => "Delete".into(),
            "read" | "read_file" | "read_many_files" | "view_file" | "view" => "Read".into(),
            "notebookread" => "NotebookRead".into(),
            "ls" | "list_directory" | "list" | "list_dir" => "LS".into(),
            "grep" | "search_file_content" | "grep_search" | "codebase_search" | "codesearch" | "search" => "Grep".into(),
            "glob" | "find_by_name" | "file_search" => "Glob".into(),
            "websearch" | "web_search" | "google_web_search" => "WebSearch".into(),
            "webfetch" | "web_fetch" | "fetch" | "fetch_url" | "url" | "read_url_content" => "WebFetch".into(),
            "task" => "Task".into(),
            "agent" => "Agent".into(),
            "todowrite" | "todo_write" | "write_todos" => "TodoWrite".into(),
            "update_plan" | "plan" => "Plan".into(),
            "exitplanmode" => "ExitPlanMode".into(),
            "skill" => "Skill".into(),
            _ => raw.to_string(),
        }
    }

    /// Files a successful call changed: the edited and written paths, plus anything `metadata.files` lists.
    pub fn changed_paths(tool: &str, input: &Value, metadata: &Value, directory: &str) -> Vec<String> {
        let mut paths = Vec::new();
        if matches!(tool, "edit" | "write") {
            if let Some(p) = input.get("path").and_then(Value::as_str).filter(|p| !p.is_empty()) {
                paths.push(absolute_path(p, directory));
            }
        }
        if let Some(files) = metadata.get("files").and_then(Value::as_array) {
            for file in files {
                if let Some(p) = file.get("file").and_then(Value::as_str).filter(|p| !p.is_empty()) {
                    let full = absolute_path(p, directory);
                    if !paths.contains(&full) {
                        paths.push(full);
                    }
                }
            }
        }
        paths
    }

    pub fn absolute_path(path: &str, directory: &str) -> String {
        let is_abs = path.starts_with('/') || path.starts_with("\\\\") || path.get(1..3).is_some_and(|d| d == ":\\" || d == ":/");
        if is_abs || directory.is_empty() {
            path.to_string()
        } else {
            Path::new(directory).join(path).to_string_lossy().into_owned()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace::models::tool_summary;
    use std::path::PathBuf;

    fn fixture(name: &str) -> String {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../macos/Tests/Fixtures/OpenCodeServer").join(name);
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("fixture {}: {e}", path.display()))
    }

    fn events(name: &str, chunk: usize) -> Vec<OpenCodeEvent> {
        let text = fixture(name);
        let mut parser = SseParser::new();
        let mut frames = Vec::new();
        let chars: Vec<char> = text.chars().collect();
        let mut i = 0;
        while i < chars.len() {
            let end = (i + chunk).min(chars.len());
            let piece: String = chars[i..end].iter().collect();
            frames.extend(parser.feed(&piece));
            i = end;
        }
        frames.into_iter().filter_map(|f| OpenCodeEvent::decode(&f.data)).collect()
    }

    #[test]
    fn server_address_comes_from_first_line() {
        assert_eq!(listening_url("Server listening on http://127.0.0.1:60163").as_deref(), Some("http://127.0.0.1:60163"));
        assert_eq!(listening_url("Server listening on http://0.0.0.0:4096"), None);
        assert_eq!(listening_url("Server listening on http://127.0.0.1:0"), None);
        assert_eq!(ARGUMENTS, &["serve", "--hostname", "127.0.0.1", "--port", "0"]);
    }

    #[test]
    fn only_opencode_two_uses_server() {
        assert!(supports_version(Some("2.2.7")));
        assert!(supports_version(Some("2.0.18")));
        assert!(supports_version(Some("opencode v2.3.0")));
        assert!(!supports_version(Some("2.0.17")));
        assert!(!supports_version(Some("1.14.19")));
        assert!(!supports_version(None));
    }

    #[test]
    fn password_is_random_and_basic_auth() {
        let first = make_password();
        let second = make_password();
        assert_ne!(first, second);
        assert!(first.len() >= 40);
        assert!(!first.contains('+') && !first.contains('/') && !first.contains('='));
        assert_eq!(authorization("pw"), format!("Basic {}", base64::engine::general_purpose::STANDARD.encode("opencode:pw")));
        assert_eq!(REMOVED_ENV, &["OPENCODE_SERVER_PASSWORD"]);
    }

    #[test]
    fn fixture_shell_permission_allowed() {
        let evs = events("shell_permission_allowed.sse", 97);
        assert_eq!(evs.first(), Some(&OpenCodeEvent::Connected));
        let session = "ses_fixture0400000000000000000";
        assert!(evs.contains(&OpenCodeEvent::ExecutionStarted { session: session.into() }));
        let perm = evs
            .iter()
            .find_map(|e| match e {
                OpenCodeEvent::Permission(p) => Some(p),
                _ => None,
            })
            .expect("permission event");
        assert_eq!(perm.session_id, session);
        assert_eq!(perm.action, "shell");
        assert_eq!(perm.resources, vec!["ls"]);
        assert_eq!(perm.save, vec!["ls *"]);
        assert_eq!(perm.call_id.as_deref(), Some("call_9badc53833e34908a6971726"));
        assert!(evs.contains(&OpenCodeEvent::ToolStarted {
            session: session.into(),
            call: "call_9badc53833e34908a6971726".into(),
            name: "shell".into(),
        }));
        assert!(evs.contains(&OpenCodeEvent::ToolCalled {
            session: session.into(),
            call: "call_9badc53833e34908a6971726".into(),
            input: json!({ "command": "ls" }),
        }));
        assert!(evs.contains(&OpenCodeEvent::PermissionSettled { session: session.into(), request: perm.id.clone() }));
        let outputs: Vec<&str> = evs
            .iter()
            .filter_map(|e| match e {
                OpenCodeEvent::ToolSucceeded { call, output, .. } if call == "call_9badc53833e34908a6971726" => Some(output.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(outputs, vec!["readme.txt\n"]);
        let steps: Vec<OpenCodeTokens> = evs
            .iter()
            .filter_map(|e| match e {
                OpenCodeEvent::StepEnded { tokens: Some(t), .. } => Some(*t),
                _ => None,
            })
            .collect();
        assert_eq!(
            steps.first().copied(),
            Some(OpenCodeTokens { input: 15160, output: 38, reasoning: 81, cache_read: 1664, cache_write: 0 })
        );
        assert_eq!(steps.len(), 2);
        let answers: Vec<&str> = evs
            .iter()
            .filter_map(|e| match e {
                OpenCodeEvent::TextDone { thinking: false, text, .. } => Some(text.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(answers.len(), 1);
        assert!(answers[0].contains("readme.txt"));
        assert!(evs.iter().any(|e| matches!(e, OpenCodeEvent::TextDelta { thinking: true, .. })));
        assert!(evs.contains(&OpenCodeEvent::ExecutionEnded { session: session.into(), outcome: OpenCodeOutcome::Succeeded }));
        assert!(evs.contains(&OpenCodeEvent::Other { kind: "session.inbox.delivered".into(), session: Some(session.into()) }));
        assert!(evs.contains(&OpenCodeEvent::Other { kind: "project.updated".into(), session: None }));
    }

    #[test]
    fn fixture_question_then_denied_with_reason() {
        let evs = events("question_then_denied_with_reason.sse", 13);
        let session = "ses_fixture0300000000000000000";
        let form = evs
            .iter()
            .find_map(|e| match e {
                OpenCodeEvent::Form(f) => Some(f),
                _ => None,
            })
            .expect("form event");
        assert_eq!(form.session_id, session);
        assert!(form.unsupported.is_none());
        assert_eq!(form.call_id.as_deref(), Some("chatcmpl-tool-b7570e70ad160e4c"));
        let items = form.question_items();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].header, "Color preference");
        assert_eq!(items[0].question, "Which color do you prefer?");
        assert_eq!(items[0].options.len(), 2);
        assert_eq!(items[0].options[0].label, "Red");
        assert_eq!(items[0].options[1].label, "Blue");
        assert!(!items[0].multi_select);

        let mut ans = HashMap::new();
        ans.insert("q0".into(), vec!["Blue".into()]);
        assert_eq!(form_answer(form, &ans), json!({ "answer": { "q0": "Blue" } }));
        assert!(evs.contains(&OpenCodeEvent::FormSettled { session: session.into(), form: form.id.clone() }));
        assert!(evs.contains(&OpenCodeEvent::ToolStarted {
            session: session.into(),
            call: "chatcmpl-tool-b7570e70ad160e4c".into(),
            name: "question".into(),
        }));
        assert!(evs.contains(&OpenCodeEvent::ToolFailed {
            session: session.into(),
            call: "chatcmpl-tool-8b78e3782d253c79".into(),
            kind: "permission.rejected".into(),
            message: "Do not run shell commands; just tell me the color.".into(),
        }));
        let answers: Vec<&str> = evs
            .iter()
            .filter_map(|e| match e {
                OpenCodeEvent::TextDone { thinking: false, text, .. } => Some(text.as_str()),
                _ => None,
            })
            .collect();
        assert!(answers.last().is_some_and(|a| a.contains("blue")));
        assert!(evs.contains(&OpenCodeEvent::ExecutionEnded { session: session.into(), outcome: OpenCodeOutcome::Succeeded }));
    }

    #[test]
    fn fixture_edits_then_stop() {
        let evs = events("edits_then_interrupt.sse", 251);
        let session = "ses_fixture0100000000000000000";
        let edit = evs
            .iter()
            .find_map(|e| match e {
                OpenCodeEvent::ToolCalled { call, input, .. } if call == "chatcmpl-tool-a7365d4d324ecc4f" => Some(input),
                _ => None,
            })
            .expect("edit input");
        let mapped = tools::map_input("edit", edit, "/Users/me/project");
        assert_eq!(mapped["file_path"], "/Users/me/project/notes.txt");
        assert_eq!(mapped["old_string"], "alpha");
        assert_eq!(mapped["new_string"], "beta");
        assert_eq!(tool_summary::describe("edit", &mapped), "edit · notes.txt");
        let metadata = evs
            .iter()
            .find_map(|e| match e {
                OpenCodeEvent::ToolSucceeded { call, metadata, .. } if call == "chatcmpl-tool-a7365d4d324ecc4f" => Some(metadata),
                _ => None,
            })
            .expect("edit metadata");
        assert_eq!(tools::changed_paths("edit", edit, metadata, "/Users/me/project"), vec!["/Users/me/project/notes.txt"]);
        assert_eq!(tools::canonical_name("edit"), "Edit");
        assert_eq!(tools::canonical_name("write"), "Write");
        assert_eq!(tools::canonical_name("shell"), "Shell");
        assert!(evs.contains(&OpenCodeEvent::ToolFailed {
            session: session.into(),
            call: "chatcmpl-tool-8caacf7af79bb0a3".into(),
            kind: "aborted".into(),
            message: "Tool execution interrupted".into(),
        }));
        assert!(evs.contains(&OpenCodeEvent::ExecutionEnded {
            session: session.into(),
            outcome: OpenCodeOutcome::Interrupted { reason: "user".into() },
        }));
        assert_eq!(parse_interrupted(&json!({ "interrupted": true })), Some(true));
        assert_eq!(parse_interrupted(&json!({ "interrupted": false })), Some(false));
    }

    #[test]
    fn fixture_execution_failed() {
        let evs = events("execution_failed.sse", 97);
        assert!(evs.contains(&OpenCodeEvent::ExecutionEnded {
            session: "ses_fixture0200000000000000000".into(),
            outcome: OpenCodeOutcome::Failed {
                kind: "provider.no-route".into(),
                message: "Model unavailable: opencode/no-such-model".into(),
            },
        }));
    }

    #[test]
    fn broken_frame_is_no_event() {
        assert_eq!(OpenCodeEvent::decode("not json"), None);
        assert_eq!(OpenCodeEvent::decode(r#"{"data":{}}"#), None);
        assert_eq!(
            OpenCodeEvent::decode(r#"{"type":"session.brand.new","data":{"sessionID":"s"}}"#),
            Some(OpenCodeEvent::Other { kind: "session.brand.new".into(), session: Some("s".into()) })
        );
        assert_eq!(
            OpenCodeEvent::decode(r#"{"type":"permission.asked","data":{"sessionID":"s"}}"#),
            Some(OpenCodeEvent::Other { kind: "permission.asked".into(), session: Some("s".into()) })
        );
    }

    #[test]
    fn rights_become_rules_with_last_match_winning() {
        let ask = rules(PermissionPolicy::Ask, ExecutionMode::Agent, &[], None);
        assert_eq!(ask.iter().map(|r| r.effect.as_str()).collect::<Vec<_>>(), vec!["ask", "ask", "ask"]);
        assert_eq!(ask.iter().map(|r| r.action.as_str()).collect::<Vec<_>>(), vec!["shell", "edit", "external_directory"]);

        let edits = rules(PermissionPolicy::AcceptEdits, ExecutionMode::Agent, &[], None);
        assert_eq!(edits.iter().find(|r| r.action == "edit").map(|r| r.effect.as_str()), Some("allow"));
        assert_eq!(edits.iter().find(|r| r.action == "shell").map(|r| r.effect.as_str()), Some("ask"));

        assert_eq!(rules(PermissionPolicy::Bypass, ExecutionMode::Agent, &[], None), vec![Rule::new("*", "*", "allow")]);

        let grant = grants("shell", &["ls *".into()]);
        assert_eq!(grant, vec![Rule::new("shell", "ls *", "allow")]);
        let plan = rules(PermissionPolicy::Bypass, ExecutionMode::Plan, &grant, Some("nook-abc"));
        assert_eq!(
            plan.iter().map(Rule::json).collect::<Vec<_>>(),
            vec![
                json!({"action": "*", "resource": "*", "effect": "allow"}),
                json!({"action": "shell", "resource": "ls *", "effect": "allow"}),
                json!({"action": "edit", "resource": "*", "effect": "deny"}),
                json!({"action": "nook-*", "resource": "*", "effect": "deny"}),
                json!({"action": "nook-abc_*", "resource": "*", "effect": "allow"}),
            ]
        );
        assert_eq!(grants("edit", &[]), vec![Rule::new("edit", "*", "allow")]);
        assert_eq!(agent_for_mode(ExecutionMode::Plan), "plan");
        assert_eq!(agent_for_mode(ExecutionMode::Agent), "build");
        let server = bridge_server(Uuid::parse_str("6F9619FF-8B86-D011-B42D-00C04FC964FF").unwrap());
        assert_eq!(server, "nook-6f9619ff8b86d011");
        assert!(server.len() <= 64);
    }

    #[test]
    fn denial_always_carries_words() {
        assert_eq!(permission_reply(true, "ignored"), json!({ "decision": "once" }));
        assert_eq!(permission_reply(false, " use rg instead "), json!({ "decision": "reject", "message": "use rg instead" }));
        assert_eq!(permission_reply(false, ""), json!({ "decision": "reject", "message": DECLINED_MESSAGE }));
    }

    #[test]
    fn models_and_variants_from_fixture() {
        let response: Value = serde_json::from_str(&fixture("models.json")).unwrap();
        let models = parse_models(&response);
        assert_eq!(models.len(), 12);
        let flash = models.iter().find(|m| m.id == "opencode/deepseek-v4.1-flash-free").unwrap();
        assert_eq!(flash.name, "opencode/DeepSeek V4.1 Flash Free");
        assert_eq!(flash.variants, vec!["low", "high", "max"]);
        assert_eq!(flash.context_window, Some(200_000));
        assert!(models.iter().find(|m| m.id == "opencode/big-pickle").unwrap().variants.is_empty());

        assert_eq!(
            parse_models(&json!({"data": {"id": "big-pickle", "providerID": "opencode", "name": "Big Pickle"}}))
                .into_iter()
                .map(|m| m.id)
                .collect::<Vec<_>>(),
            vec!["opencode/big-pickle"]
        );

        assert_eq!(
            model_ref("opencode/deepseek-v4.1-flash-free", Some("high")),
            Some(json!({"providerID": "opencode", "id": "deepseek-v4.1-flash-free", "variant": "high"}))
        );
        assert_eq!(
            model_ref("anthropic/claude-sonnet-5/thinking", None),
            Some(json!({"providerID": "anthropic", "id": "claude-sonnet-5/thinking"}))
        );
        assert_eq!(model_ref("", Some("high")), None);
        assert_eq!(model_ref("no-provider", None), None);

        let parsed = parse_model_ref(Some(&json!({"providerID": "opencode", "id": "big-pickle", "variant": "default"})));
        assert_eq!(parsed, Some(("opencode/big-pickle".into(), None)));
    }

    #[test]
    fn sessions_and_commands() {
        let info = parse_session(&json!({
            "data": {
                "id": "ses_1",
                "parentID": "ses_0",
                "location": { "directory": "/p" },
                "model": { "providerID": "opencode", "id": "m", "variant": "high" },
                "time": { "busy": 10, "idle": 12 },
                "outcome": "interrupted"
            }
        }));
        assert_eq!(
            info,
            Some(OpenCodeSessionInfo {
                id: "ses_1".into(),
                parent_id: Some("ses_0".into()),
                directory: Some("/p".into()),
                model: Some("opencode/m".into()),
                variant: Some("high".into()),
                busy: false,
                outcome: Some("interrupted".into()),
            })
        );
        assert_eq!(parse_session(&json!({"data": {"id": "ses_2", "time": {"busy": 20, "idle": 12}}})).map(|s| s.busy), Some(true));
        assert_eq!(parse_session(&json!({"_tag": "SessionNotFoundError", "message": "gone"})), None);
        assert_eq!(error_message(&json!({"_tag": "SessionNotFoundError", "message": "gone"})).as_deref(), Some("gone"));

        let commands = parse_commands(&json!({
            "data": [
                {"name": "review", "description": "review changes"},
                {"name": "goal"},
                {"name": "two words"},
                {"name": "review"}
            ]
        }));
        assert_eq!(commands.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), vec!["review", "goal"]);
        assert_eq!(parse_slash_command("/compact", &[]).map(|(n, _)| n).as_deref(), Some("compact"));
        assert_eq!(parse_slash_command(" /goal ship the release ", &commands), Some(("goal".into(), "ship the release".into())));
        assert_eq!(parse_slash_command("/unknown do it", &commands), None);
        assert_eq!(parse_slash_command("please /goal", &commands), None);
    }

    #[test]
    fn prompts_and_new_sessions() {
        assert_eq!(
            prompt_body("look", &["/tmp/a b.png".into()]),
            json!({ "text": "look", "files": [{ "uri": "file:///tmp/a%20b.png", "name": "a b.png" }] })
        );
        assert_eq!(prompt_body("hi", &[]), json!({ "text": "hi" }));
        let body = new_session_body("/p", None, "build", &[Rule::new("*", "*", "allow")]);
        assert_eq!(
            body,
            json!({
                "location": { "directory": "/p" },
                "agent": "build",
                "permissions": [{ "action": "*", "resource": "*", "effect": "allow" }]
            })
        );
        assert_eq!(location_query("/a+b"), vec![("location[directory]".into(), "/a+b".into())]);
    }

    #[test]
    fn unsupported_and_multiselect_forms() {
        let external = OpenCodeForm::parse(Some(&json!({
            "id": "frm_1",
            "sessionID": "s",
            "fields": [{ "key": "k", "type": "external", "url": "https://x" }]
        })))
        .unwrap();
        assert!(external.unsupported.is_some());

        let empty = OpenCodeForm::parse(Some(&json!({ "id": "frm_2", "sessionID": "s", "fields": [] }))).unwrap();
        assert!(empty.unsupported.is_some());

        let multi = OpenCodeForm::parse(Some(&json!({
            "id": "frm_3",
            "sessionID": "s",
            "fields": [{
                "key": "pick",
                "type": "multiselect",
                "title": "Which",
                "options": [
                    { "value": "a", "label": "Apple" },
                    { "value": "b", "label": "Banana" }
                ]
            }]
        })))
        .unwrap();
        assert!(multi.unsupported.is_none());
        assert!(multi.question_items()[0].multi_select);
        let mut ans = HashMap::new();
        ans.insert("pick".into(), vec!["Apple".into(), "Banana".into()]);
        assert_eq!(form_answer(&multi, &ans), json!({ "answer": { "pick": ["a", "b"] } }));
    }
}
