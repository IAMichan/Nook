//! Pi (`pi.dev`) coding agent over its RPC mode (`PiRPC.swift`, `PiExtension.swift`, `WorkspaceManager+Pi.swift` and
//! `PiRPCTurnDriver.swift` on the Mac): `pi --mode rpc` reads commands and writes events as LF-delimited JSON lines.
//!
//! Nook runs one `pi --mode rpc` process per turn, resumes the conversation from Pi's session file (`--session`), loads
//! Nook's extension (`nook-pi-extension.ts`) for tool approvals and the workspace bridge, and handles blocking `confirm`,
//! `select`, `input`, and `editor` dialogs over stdin/stdout.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use serde_json::{json, Value};

use super::command::{CommandInput, LaunchSpec};
use super::driver::{self, Driver, DriverEvent, Step};
use super::models::{PermissionPolicy, TurnUsage};
use super::parsers::{number, ClaudeEvent, ClaudeTurnResult, TokenCounts};
use crate::i18n::tr;

/// What Nook writes to Pi's stdin (`PiRPC` on macOS).
pub mod rpc {
    use serde_json::{json, Map, Value};

    /// Request id of the initial `get_state` command sent to learn the session file and model context window.
    pub const STATE_REQUEST_ID: &str = "nook-state";
    /// Request id for `get_available_models`.
    pub const MODELS_REQUEST_ID: &str = "nook-models";

    /// Pi's thinking levels, lowest first (`--thinking` / `set_thinking_level`).
    pub const THINKING_LEVELS: &[&str] = &["off", "minimal", "low", "medium", "high", "xhigh"];

    pub fn line(object: Value) -> String {
        let mut s = serde_json::to_string(&object).unwrap_or_else(|_| "{}".into());
        s.push('\n');
        s
    }

    pub fn get_state() -> String {
        line(json!({ "type": "get_state", "id": STATE_REQUEST_ID }))
    }

    pub fn get_available_models(id: &str) -> String {
        line(json!({ "type": "get_available_models", "id": id }))
    }

    /// A prompt message. While Pi is working on a turn `steer: true` steers the running turn (`streamingBehavior: "steer"`).
    pub fn prompt(message: &str, steer: bool) -> String {
        let mut obj = Map::new();
        obj.insert("type".into(), json!("prompt"));
        obj.insert("message".into(), json!(message));
        if steer {
            obj.insert("streamingBehavior".into(), json!("steer"));
        }
        line(Value::Object(obj))
    }

    pub fn abort() -> String {
        line(json!({ "type": "abort" }))
    }

    /// Answer to an extension `select`, `input`, or `editor` dialog: the value, or `cancelled: true` when none.
    pub fn dialog_response(request_id: &str, value: Option<&str>) -> String {
        match value {
            Some(v) => line(json!({ "type": "extension_ui_response", "id": request_id, "value": v })),
            None => line(json!({ "type": "extension_ui_response", "id": request_id, "cancelled": true })),
        }
    }

    /// Answer to an extension `confirm` dialog.
    pub fn confirm_response(request_id: &str, confirmed: bool) -> String {
        line(json!({ "type": "extension_ui_response", "id": request_id, "confirmed": confirmed }))
    }

    pub fn set_model(provider: &str, model_id: &str) -> String {
        line(json!({ "type": "set_model", "provider": provider, "modelId": model_id }))
    }

    pub fn set_thinking_level(level: &str) -> String {
        line(json!({ "type": "set_thinking_level", "level": level }))
    }

    /// Compacts the conversation; non-empty `instructions` says what the summary should preserve.
    pub fn compact(instructions: &str) -> String {
        let clean = instructions.trim();
        if clean.is_empty() {
            line(json!({ "type": "compact" }))
        } else {
            line(json!({ "type": "compact", "customInstructions": clean }))
        }
    }

    /// Initial stdin lines for a turn: Nook's `/compact` maps to Pi's `compact` command, everything else to `prompt`.
    /// `get_state` always goes first so the session file and context window are known before the turn ends.
    pub fn turn_input(message: &str) -> Vec<String> {
        let trimmed = message.trim();
        if trimmed == "/compact" {
            return vec![get_state(), compact("")];
        }
        if let Some(rest) = trimmed.strip_prefix("/compact ") {
            return vec![get_state(), compact(rest)];
        }
        vec![get_state(), prompt(message, false)]
    }

    /// Splits a Pi model slug `"provider/model"` at the first slash (the model id itself may contain slashes).
    pub fn split_model(slug: &str) -> Option<(&str, &str)> {
        let (provider, model_id) = slug.split_once('/')?;
        if provider.is_empty() || model_id.is_empty() {
            return None;
        }
        Some((provider, model_id))
    }
}

/// One model Pi can use (`get_available_models`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PiModel {
    pub provider: String,
    pub id: String,
    pub name: String,
    pub context_window: Option<u64>,
    pub supports_thinking: bool,
}

impl PiModel {
    /// What Nook displays and sends as the model slug: `"provider/id"`.
    pub fn slug(&self) -> String {
        format!("{}/{}", self.provider, self.id)
    }

    /// Extracts models when `line` is Pi's reply to Nook's `get_available_models`; `None` for any other line.
    pub fn reply_in(line: &str) -> Option<Vec<Self>> {
        let object: Value = serde_json::from_str(line).ok()?;
        if object.get("type").and_then(Value::as_str) != Some("response")
            || object.get("id").and_then(Value::as_str) != Some(rpc::MODELS_REQUEST_ID)
        {
            return None;
        }
        if object.get("success").and_then(Value::as_bool) == Some(true) {
            Some(Self::parse(object.get("data")))
        } else {
            Some(Vec::new())
        }
    }

    /// Parses the `models` array inside a `get_available_models` `data` object, deduplicating by `provider/id`.
    pub fn parse(data: Option<&Value>) -> Vec<Self> {
        let Some(models) = data.and_then(|d| d.get("models")).and_then(Value::as_array) else {
            return Vec::new();
        };
        let mut seen = HashSet::new();
        let mut result = Vec::new();
        for model in models {
            let Some(provider) = model.get("provider").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()) else {
                continue;
            };
            let Some(id) = model.get("id").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()) else {
                continue;
            };
            let slug = format!("{provider}/{id}");
            if !seen.insert(slug) {
                continue;
            }
            let name = model.get("name").and_then(Value::as_str).unwrap_or(id).to_string();
            let context_window = number(model.get("contextWindow")).filter(|v| *v > 0.0).map(|v| v as u64);
            let supports_thinking = model.get("reasoning").and_then(Value::as_bool).unwrap_or(false);
            result.push(Self { provider: provider.to_string(), id: id.to_string(), name, context_window, supports_thinking });
        }
        result
    }
}

/// The Pi extension Nook loads via `--extension` (`PiExtension.swift` on macOS): blocks tool calls for Nook's
/// approval prompt and registers Nook's workspace bridge (`nook-mcp`) as Pi tools.
pub mod extension {
    use std::path::{Path, PathBuf};

    use super::PermissionPolicy;

    pub const PERMISSION_VARIABLE: &str = "NOOK_PI_PERMISSION";
    pub const BRIDGE_VARIABLE: &str = "NOOK_PI_BRIDGE";
    pub const READ_ONLY_TOOLS: &[&str] = &["read", "grep", "find", "ls"];
    pub const FILE_CHANGE_TOOLS: &[&str] = &["edit", "write"];
    pub const BRIDGE_TOOL_PREFIX: &str = "mcp__nook__";

    pub fn permission_value(policy: PermissionPolicy) -> &'static str {
        match policy {
            PermissionPolicy::Ask => "ask",
            PermissionPolicy::AcceptEdits => "acceptEdits",
            PermissionPolicy::Bypass => "bypass",
        }
    }

    pub fn file_path() -> PathBuf {
        crate::paths::support_directory().join("nook-pi-extension.ts")
    }

    /// Writes `nook-pi-extension.ts` in Nook's support directory when missing or out of date.
    pub fn install() -> PathBuf {
        let path = file_path();
        let _ = install_at(&path);
        path
    }

    /// Writes the extension to `path` when missing or different from the current source.
    pub fn install_at(path: &Path) -> bool {
        let data = source();
        if let Ok(current) = std::fs::read_to_string(path) {
            if current == data {
                return true;
            }
        }
        if let Some(parent) = path.parent() {
            if std::fs::create_dir_all(parent).is_err() {
                return false;
            }
        }
        crate::paths::write_atomic(path, data.as_bytes()).is_ok()
    }

    pub fn source() -> String {
        let read_only = serde_json::to_string(READ_ONLY_TOOLS).unwrap_or_else(|_| "[]".into());
        let file_changes = serde_json::to_string(FILE_CHANGE_TOOLS).unwrap_or_else(|_| "[]".into());
        format!(
            r#"// Nook's extension for Pi: asks Nook before tools run, and offers Nook's workspace tools. Written by Nook; edits are overwritten.
import {{ spawn }} from "node:child_process";

const READ_ONLY = new Set({read_only});
const FILE_CHANGES = new Set({file_changes});
const BRIDGE_PREFIX = "{BRIDGE_TOOL_PREFIX}";

function summary(input) {{
  try {{ return JSON.stringify(input, null, 2).slice(0, 4000); }} catch {{ return String(input).slice(0, 4000); }}
}}

function startBridge(script) {{
  const isWinBatch = process.platform === "win32" && /\.(cmd|bat)$/i.test(script);
  const child = spawn(script, ["--agent", "pi"], {{ stdio: ["pipe", "pipe", "ignore"], env: process.env, shell: isWinBatch, windowsHide: true }});
  const pending = new Map();
  let buffer = "";
  let next = 1;
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {{
    buffer += chunk;
    let index;
    while ((index = buffer.indexOf("\n")) >= 0) {{
      const line = buffer.slice(0, index).trim();
      buffer = buffer.slice(index + 1);
      if (!line) continue;
      try {{
        const message = JSON.parse(line);
        const waiting = pending.get(message.id);
        if (!waiting) continue;
        pending.delete(message.id);
        if (message.error) waiting.reject(new Error(message.error.message || "bridge error"));
        else waiting.resolve(message.result);
      }} catch {{}}
    }}
  }});
  child.on("exit", () => {{
    for (const waiting of pending.values()) waiting.reject(new Error("The Nook bridge closed."));
    pending.clear();
  }});
  child.on("error", () => {{}});
  const request = (method, params) => new Promise((resolve, reject) => {{
    const id = next++;
    pending.set(id, {{ resolve, reject }});
    child.stdin.write(JSON.stringify({{ jsonrpc: "2.0", id, method, params }}) + "\n");
  }});
  const notify = (method, params) => child.stdin.write(JSON.stringify({{ jsonrpc: "2.0", method, params }}) + "\n");
  return {{ child, request, notify }};
}}

export default async function (pi) {{
  const mode = process.env.{PERMISSION_VARIABLE} || "ask";

  pi.on("tool_call", async (event, ctx) => {{
    if (mode === "bypass") return;
    if (READ_ONLY.has(event.toolName) || event.toolName.startsWith(BRIDGE_PREFIX)) return;
    if (mode === "acceptEdits" && FILE_CHANGES.has(event.toolName)) return;
    const approved = await ctx.ui.confirm(`Allow ${{event.toolName}}?`, summary(event.input), {{ signal: ctx.signal }});
    if (!approved) return {{ block: true, reason: `${{event.toolName}} was declined in Nook.` }};
  }});

  const script = process.env.{BRIDGE_VARIABLE};
  if (!script) return;
  try {{
    const bridge = startBridge(script);
    await bridge.request("initialize", {{ protocolVersion: "2024-11-05", capabilities: {{}}, clientInfo: {{ name: "pi", version: "1" }} }});
    bridge.notify("notifications/initialized", {{}});
    const listed = await bridge.request("tools/list", {{}});
    for (const tool of listed.tools || []) {{
      pi.registerTool({{
        name: BRIDGE_PREFIX + tool.name,
        label: tool.name,
        description: tool.description || tool.name,
        parameters: tool.inputSchema || {{ type: "object", properties: {{}} }},
        async execute(_id, params) {{
          const result = await bridge.request("tools/call", {{ name: tool.name, arguments: params || {{}} }});
          const content = (result.content || []).filter((part) => part.type === "text" || part.type === "image");
          if (result.isError) throw new Error(content.map((part) => part.text || "").join("\n") || "The tool failed.");
          return {{ content: content.length ? content : [{{ type: "text", text: "" }}], details: {{ tool: tool.name }} }};
        }},
      }});
    }}
    pi.on("session_shutdown", () => {{ try {{ bridge.child.kill(); }} catch {{}} }});
  }} catch (error) {{
    // Without the bridge Pi still works; the permission hook above stays.
  }}
}}
"#
        )
    }
}

/// Token and cost counts from one Pi model call.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct PiUsage {
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    pub total: u64,
    pub cost_usd: Option<f64>,
}

/// A parsed `select`, `input`, or `editor` dialog question from a Pi extension.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PiDialogQuestion {
    pub header: String,
    pub question: String,
    pub options: Vec<String>,
}

/// Structured events parsed from one line of Pi's RPC stdout (`PiStreamEvent` on macOS).
#[derive(Debug, Clone, PartialEq)]
pub enum PiStreamEvent {
    Session {
        file: Option<String>,
        model: Option<String>,
        context_window: Option<u64>,
    },
    Started,
    TextDelta(String),
    ThinkingDelta(String),
    Text(String),
    Thinking(String),
    ToolStarted {
        id: String,
        name: String,
        input: Value,
    },
    ToolUpdated {
        id: String,
        output: String,
    },
    ToolFinished {
        id: String,
        name: String,
        output: String,
        is_error: bool,
    },
    Usage(PiUsage),
    Confirm {
        request_id: String,
        title: String,
        message: String,
    },
    Dialog {
        request_id: String,
        question: PiDialogQuestion,
    },
    Notice(String),
    UserMessage(Option<String>),
    CompactionStarted,
    /// `None` on success, `Some("")` when aborted, `Some(msg)` on error.
    CompactionEnded {
        failed: Option<String>,
    },
    Retrying(String),
    Failed(String),
    Settled {
        aborted: bool,
    },
    Ended,
    CommandDone {
        command: String,
        error: Option<String>,
    },
}

/// Parses one JSON line from `pi --mode rpc` stdout (`PiStreamParser.parse` on macOS).
pub fn parse_line(line: &str) -> Vec<PiStreamEvent> {
    let Ok(object) = serde_json::from_str::<Value>(line) else {
        return Vec::new();
    };
    let Some(kind) = object.get("type").and_then(Value::as_str) else {
        return Vec::new();
    };
    match kind {
        "response" => parse_response(&object),
        "agent_start" => vec![PiStreamEvent::Started],
        "message_update" => parse_message_update(&object),
        "message_start" => {
            let Some(message) = object.get("message").and_then(Value::as_object) else {
                return Vec::new();
            };
            if message.get("role").and_then(Value::as_str) != Some("user") {
                return Vec::new();
            }
            let text = content_text(message.get("content"));
            vec![PiStreamEvent::UserMessage((!text.is_empty()).then_some(text))]
        }
        "message_end" => {
            let Some(message) = object.get("message").and_then(Value::as_object) else {
                return Vec::new();
            };
            if message.get("role").and_then(Value::as_str) != Some("assistant") {
                return Vec::new();
            }
            let mut events = Vec::new();
            if let Some(usage) = parse_usage(message.get("usage")) {
                events.push(PiStreamEvent::Usage(usage));
            }
            if message.get("stopReason").and_then(Value::as_str) == Some("error") {
                let err = message.get("errorMessage").and_then(Value::as_str).unwrap_or("Pi reported a model error.").to_string();
                events.push(PiStreamEvent::Failed(err));
            }
            events
        }
        "tool_execution_start" => {
            let Some(id) = object.get("toolCallId").and_then(Value::as_str) else {
                return Vec::new();
            };
            let name = object.get("toolName").and_then(Value::as_str).unwrap_or("tool").to_string();
            let input = object.get("args").cloned().filter(Value::is_object).unwrap_or_else(|| json!({}));
            vec![PiStreamEvent::ToolStarted { id: id.to_string(), name, input }]
        }
        "tool_execution_update" => {
            let Some(id) = object.get("toolCallId").and_then(Value::as_str) else {
                return Vec::new();
            };
            let text = content_text(object.pointer("/partialResult/content"));
            if text.is_empty() {
                Vec::new()
            } else {
                vec![PiStreamEvent::ToolUpdated { id: id.to_string(), output: text }]
            }
        }
        "tool_execution_end" => {
            let Some(id) = object.get("toolCallId").and_then(Value::as_str) else {
                return Vec::new();
            };
            let name = object.get("toolName").and_then(Value::as_str).unwrap_or("tool").to_string();
            let output = content_text(object.pointer("/result/content"));
            let is_error = object.get("isError").and_then(Value::as_bool).unwrap_or(false);
            vec![PiStreamEvent::ToolFinished { id: id.to_string(), name, output, is_error }]
        }
        "compaction_start" => vec![PiStreamEvent::CompactionStarted],
        "compaction_end" => {
            if object.get("aborted").and_then(Value::as_bool) == Some(true) {
                return vec![PiStreamEvent::CompactionEnded { failed: Some(String::new()) }];
            }
            let failure = object.get("errorMessage").and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string);
            vec![PiStreamEvent::CompactionEnded { failed: failure }]
        }
        "auto_retry_start" => {
            let reason = object.get("errorMessage").and_then(Value::as_str).unwrap_or("").to_string();
            vec![PiStreamEvent::Retrying(reason)]
        }
        "extension_ui_request" => parse_dialog(&object),
        "extension_error" => {
            let message = object.get("error").and_then(Value::as_str).unwrap_or("An extension failed.").to_string();
            vec![PiStreamEvent::Notice(message)]
        }
        "agent_settled" => {
            let aborted = object.get("aborted").and_then(Value::as_bool).unwrap_or(false);
            vec![PiStreamEvent::Settled { aborted }]
        }
        "agent_end" => vec![PiStreamEvent::Ended],
        _ => Vec::new(),
    }
}

fn parse_response(object: &Value) -> Vec<PiStreamEvent> {
    let command = object.get("command").and_then(Value::as_str).unwrap_or("");
    let success = object.get("success").and_then(Value::as_bool).unwrap_or(false);
    let error = if success {
        None
    } else {
        Some(
            object
                .get("error")
                .and_then(Value::as_str)
                .map(str::to_string)
                .unwrap_or_else(|| format!("Pi rejected the {command} command.")),
        )
    };
    if command == "get_state" && success && object.get("id").and_then(Value::as_str) == Some(rpc::STATE_REQUEST_ID) {
        let state = object.get("data");
        let model = state.and_then(|s| s.get("model"));
        let slug = model
            .and_then(|m| m.get("provider").and_then(Value::as_str))
            .zip(model.and_then(|m| m.get("id").and_then(Value::as_str)))
            .map(|(p, id)| format!("{p}/{id}"));
        let file = state.and_then(|s| s.get("sessionFile")).and_then(Value::as_str).map(str::to_string);
        let context_window = model.and_then(|m| number(m.get("contextWindow"))).filter(|v| *v > 0.0).map(|v| v as u64);
        return vec![PiStreamEvent::Session { file, model: slug, context_window }];
    }
    if command == "prompt" {
        if let Some(err) = error {
            return vec![PiStreamEvent::Failed(err), PiStreamEvent::Settled { aborted: false }];
        }
        return Vec::new();
    }
    if command == "compact" {
        return vec![PiStreamEvent::CommandDone { command: command.to_string(), error }];
    }
    if let Some(err) = error {
        if command != "get_state" {
            return vec![PiStreamEvent::Notice(err)];
        }
    }
    Vec::new()
}

fn parse_message_update(object: &Value) -> Vec<PiStreamEvent> {
    let Some(delta) = object.get("assistantMessageEvent") else {
        return Vec::new();
    };
    let Some(kind) = delta.get("type").and_then(Value::as_str) else {
        return Vec::new();
    };
    match kind {
        "text_delta" => delta.get("delta").and_then(Value::as_str).map(|s| vec![PiStreamEvent::TextDelta(s.into())]).unwrap_or_default(),
        "thinking_delta" => {
            delta.get("delta").and_then(Value::as_str).map(|s| vec![PiStreamEvent::ThinkingDelta(s.into())]).unwrap_or_default()
        }
        "text_end" => delta.get("content").and_then(Value::as_str).map(|s| vec![PiStreamEvent::Text(s.into())]).unwrap_or_default(),
        "thinking_end" => delta
            .get("content")
            .or_else(|| delta.get("thinking"))
            .and_then(Value::as_str)
            .map(|s| vec![PiStreamEvent::Thinking(s.into())])
            .unwrap_or_default(),
        _ => Vec::new(),
    }
}

fn parse_dialog(object: &Value) -> Vec<PiStreamEvent> {
    let Some(method) = object.get("method").and_then(Value::as_str) else {
        return Vec::new();
    };
    match method {
        "confirm" => {
            let Some(id) = object.get("id").and_then(Value::as_str) else {
                return Vec::new();
            };
            let title = object.get("title").and_then(Value::as_str).unwrap_or("").to_string();
            let message = object.get("message").and_then(Value::as_str).unwrap_or("").to_string();
            vec![PiStreamEvent::Confirm { request_id: id.to_string(), title, message }]
        }
        "select" | "input" | "editor" => {
            let Some(id) = object.get("id").and_then(Value::as_str) else {
                return Vec::new();
            };
            vec![PiStreamEvent::Dialog { request_id: id.to_string(), question: parse_dialog_question(method, object) }]
        }
        "notify" => {
            let message = object.get("message").and_then(Value::as_str).unwrap_or("");
            if message.is_empty() {
                Vec::new()
            } else {
                vec![PiStreamEvent::Notice(message.to_string())]
            }
        }
        _ => Vec::new(),
    }
}

pub fn parse_dialog_question(method: &str, object: &Value) -> PiDialogQuestion {
    let title = object.get("title").and_then(Value::as_str).unwrap_or("").trim().to_string();
    let detail = ["message", "placeholder"]
        .into_iter()
        .filter_map(|key| object.get(key).and_then(Value::as_str))
        .map(str::trim)
        .find(|s| !s.is_empty())
        .map(str::to_string);
    let options = if method == "select" {
        object
            .get("options")
            .and_then(Value::as_array)
            .map(|arr| arr.iter().filter_map(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string).collect())
            .unwrap_or_default()
    } else {
        Vec::new()
    };
    let (header, question) = match detail {
        Some(d) => (title, d),
        None => (String::new(), title),
    };
    let question = if question.is_empty() {
        tr("Een extensie vraagt om een antwoord.", "An extension asks for an answer.").to_string()
    } else {
        question
    };
    PiDialogQuestion { header, question, options }
}

fn parse_usage(value: Option<&Value>) -> Option<PiUsage> {
    let usage = value?.as_object()?;
    let count = |key: &str| number(usage.get(key)).unwrap_or(0.0).max(0.0) as u64;
    let input = count("input");
    let output = count("output");
    let cache_read = count("cacheRead");
    let cache_write = count("cacheWrite");
    let mut total = count("totalTokens");
    if total == 0 {
        total = input + output + cache_read + cache_write;
    }
    let cost_usd = usage.get("cost").and_then(|c| number(c.get("total")));
    Some(PiUsage { input, output, cache_read, cache_write, total, cost_usd })
}

fn content_text(content: Option<&Value>) -> String {
    let Some(content) = content else {
        return String::new();
    };
    if let Some(s) = content.as_str() {
        return s.to_string();
    }
    let Some(blocks) = content.as_array() else {
        return String::new();
    };
    blocks
        .iter()
        .filter_map(|b| (b.get("type").and_then(Value::as_str) == Some("text")).then(|| b.get("text").and_then(Value::as_str)).flatten())
        .collect::<Vec<_>>()
        .join("\n")
}

/// Builds the `LaunchSpec` and [`PiDriver`] for one Pi turn, installing `nook-pi-extension.ts` first.
pub fn launch(input: &CommandInput) -> (LaunchSpec, PiDriver) {
    let ext_path = extension::install();
    launch_with_extension(input, &ext_path)
}

/// Same as [`launch`], with an explicit extension path (used by tests to avoid writing into the real support dir).
pub fn launch_with_extension(input: &CommandInput, extension_path: &Path) -> (LaunchSpec, PiDriver) {
    let mut environment = input.account_environment.clone();
    environment.insert("NOOK_RUN_ID".into(), input.run_id.clone());
    environment.insert(extension::PERMISSION_VARIABLE.into(), extension::permission_value(input.permission).into());
    if let Some(bridge) = &input.bridge {
        environment.insert(extension::BRIDGE_VARIABLE.into(), bridge.script.clone());
    }

    let mut arguments: Vec<String> = vec!["--mode".into(), "rpc".into()];
    if let Some(resume) = input.resume_session_id.as_deref().filter(|s| !s.is_empty()) {
        arguments.extend(["--session".into(), resume.into()]);
    }
    let model = input.model.trim();
    if !model.is_empty() {
        if let Some((provider, model_id)) = rpc::split_model(model) {
            arguments.extend(["--provider".into(), provider.into(), "--model".into(), model_id.into()]);
        } else {
            arguments.extend(["--model".into(), model.into()]);
        }
    }
    if let Some(effort) = input.effort.as_deref().filter(|e| rpc::THINKING_LEVELS.contains(e)) {
        arguments.extend(["--thinking".into(), effort.into()]);
    }
    let instructions = driver::instructions(input);
    if !instructions.is_empty() {
        arguments.extend(["--append-system-prompt".into(), instructions]);
    }
    arguments.extend(["--extension".into(), extension_path.to_string_lossy().into_owned()]);

    let spec = LaunchSpec {
        executable: input.executable.clone(),
        arguments,
        extra_environment: environment,
        working_directory: input.working_directory.clone(),
        initial_input: rpc::turn_input(&input.prompt),
        keeps_input_open: true,
    };
    (spec, PiDriver::new(input))
}

/// One turn over `pi --mode rpc`.
pub struct PiDriver {
    initial_prompt: String,
    saw_initial_user: bool,
    session_file: Option<String>,
    model: Option<String>,
    context_window: Option<u64>,
    usage: TurnUsage,
    usage_seq: u64,
    in_thinking: bool,
    confirmations: HashSet<String>,
    /// Question request id (`pidialog-<id>`) -> Pi's extension UI request id.
    dialogs: HashMap<String, String>,
    last_error: Option<String>,
    stopping: bool,
    pending_end: bool,
    finished: bool,
}

impl PiDriver {
    pub fn new(input: &CommandInput) -> Self {
        Self {
            initial_prompt: input.prompt.clone(),
            saw_initial_user: false,
            session_file: input.resume_session_id.clone().filter(|s| !s.is_empty()),
            model: (!input.model.trim().is_empty()).then(|| input.model.trim().to_string()),
            context_window: None,
            usage: TurnUsage::default(),
            usage_seq: 0,
            in_thinking: false,
            confirmations: HashSet::new(),
            dialogs: HashMap::new(),
            last_error: None,
            stopping: false,
            pending_end: false,
            finished: false,
        }
    }

    fn finish(&mut self, step: &mut Step) {
        if self.finished {
            return;
        }
        self.finished = true;
        self.pending_end = false;
        if self.in_thinking {
            self.in_thinking = false;
            step.event(ClaudeEvent::BlockStopped);
        }
        let failed = self.last_error.is_some() && !self.stopping;
        let text = if failed { self.last_error.clone().unwrap_or_default() } else { String::new() };
        let subtype = if failed { "error" } else { "success" };
        let mut usage = self.usage.clone();
        usage.context_window = self.context_window;
        step.event(ClaudeEvent::Result(ClaudeTurnResult {
            is_error: failed,
            subtype: subtype.into(),
            text,
            session_id: self.session_file.clone(),
            usage,
            ..Default::default()
        }));
    }

    fn apply(&mut self, step: &mut Step, event: PiStreamEvent) {
        if !matches!(event, PiStreamEvent::Ended) {
            self.pending_end = false;
        }
        match event {
            PiStreamEvent::Session { file, model, context_window } => {
                if let Some(f) = file.filter(|f| !f.is_empty()) {
                    self.session_file = Some(f);
                }
                if let Some(m) = model.filter(|m| !m.is_empty()) {
                    self.model = Some(m);
                }
                if let Some(w) = context_window {
                    self.context_window = Some(w);
                    self.usage.context_window = Some(w);
                }
                if let Some(session_id) = self.session_file.clone() {
                    step.event(ClaudeEvent::Initialized { session_id, model: self.model.clone() });
                }
            }
            PiStreamEvent::Started => {}
            PiStreamEvent::UserMessage(text) => {
                // Skip the echo of the turn's initial prompt so it can never be mistaken for a steer receipt.
                if !self.saw_initial_user && text.as_deref().map(str::trim) == Some(self.initial_prompt.trim()) {
                    self.saw_initial_user = true;
                    return;
                }
                self.saw_initial_user = true;
                step.events.push(DriverEvent::UserMessageRead(text.unwrap_or_default()));
            }
            PiStreamEvent::ThinkingDelta(delta) => {
                if delta.is_empty() {
                    return;
                }
                let starts = !self.in_thinking;
                self.in_thinking = true;
                step.event(ClaudeEvent::ThinkingDelta { text: delta, starts });
            }
            PiStreamEvent::Thinking(full) => {
                self.in_thinking = false;
                step.event(ClaudeEvent::Thinking(full));
            }
            PiStreamEvent::TextDelta(delta) => {
                if self.in_thinking {
                    self.in_thinking = false;
                    step.event(ClaudeEvent::BlockStopped);
                }
                if !delta.is_empty() {
                    step.event(ClaudeEvent::TextDelta(delta));
                }
            }
            PiStreamEvent::Text(full) => {
                if self.in_thinking {
                    self.in_thinking = false;
                    step.event(ClaudeEvent::BlockStopped);
                }
                step.event(ClaudeEvent::Text(full));
            }
            PiStreamEvent::ToolStarted { id, name, input } => {
                if self.in_thinking {
                    self.in_thinking = false;
                    step.event(ClaudeEvent::BlockStopped);
                }
                step.event(ClaudeEvent::ToolUse { id, name, input, nested: false });
            }
            PiStreamEvent::ToolUpdated { id, output } => {
                step.events.push(DriverEvent::ToolOutput { id, output });
            }
            PiStreamEvent::ToolFinished { id, output, is_error, .. } => {
                step.event(ClaudeEvent::ToolResult { id, output, is_error });
            }
            PiStreamEvent::Usage(call) => {
                self.usage.input_tokens = Some(self.usage.input_tokens.unwrap_or(0) + call.input);
                self.usage.output_tokens = Some(self.usage.output_tokens.unwrap_or(0) + call.output);
                self.usage.cache_read_tokens = Some(self.usage.cache_read_tokens.unwrap_or(0) + call.cache_read);
                self.usage.cache_write_tokens = Some(self.usage.cache_write_tokens.unwrap_or(0) + call.cache_write);
                if let Some(cost) = call.cost_usd {
                    self.usage.reported_cost_usd = Some(self.usage.reported_cost_usd.unwrap_or(0.0) + cost);
                }
                self.usage.context_tokens = Some(call.total);
                self.usage.context_window = self.context_window;
                self.usage_seq += 1;
                step.event(ClaudeEvent::Usage {
                    message_id: format!("pi-{}", self.usage_seq),
                    tokens: TokenCounts {
                        input: call.input,
                        output: call.output,
                        cache_read: call.cache_read,
                        cache_write: call.cache_write,
                        cache_ttl: None,
                    },
                    model: self.model.clone(),
                });
            }
            PiStreamEvent::Confirm { request_id, title, message } => {
                if self.in_thinking {
                    self.in_thinking = false;
                    step.event(ClaudeEvent::BlockStopped);
                }
                let tool = title.strip_prefix("Allow ").map(|s| s.strip_suffix('?').unwrap_or(s)).unwrap_or(&title).to_string();
                let tool = if tool.is_empty() { "confirm".to_string() } else { tool };
                let input = serde_json::from_str::<Value>(&message)
                    .ok()
                    .filter(Value::is_object)
                    .unwrap_or_else(|| json!({ "description": if message.is_empty() { &title } else { &message } }));
                self.confirmations.insert(request_id.clone());
                step.event(ClaudeEvent::PermissionRequest { request_id, tool, input, suggestions: None, tool_use_id: None });
            }
            PiStreamEvent::Dialog { request_id, question } => {
                if self.in_thinking {
                    self.in_thinking = false;
                    step.event(ClaudeEvent::BlockStopped);
                }
                let key = format!("pidialog-{request_id}");
                if self.dialogs.contains_key(&key) {
                    return;
                }
                self.dialogs.insert(key.clone(), request_id);
                let options: Vec<Value> = question.options.iter().map(|label| json!({ "label": label, "description": "" })).collect();
                step.event(ClaudeEvent::PermissionRequest {
                    request_id: key,
                    tool: "AskUserQuestion".into(),
                    input: json!({
                        "questions": [{
                            "question": question.question,
                            "header": question.header,
                            "options": options,
                            "multiSelect": false,
                        }]
                    }),
                    suggestions: None,
                    tool_use_id: None,
                });
            }
            PiStreamEvent::Notice(message) => {
                step.events.push(DriverEvent::System(message));
            }
            PiStreamEvent::CompactionStarted => {
                step.event(ClaudeEvent::CompactionStarted);
            }
            PiStreamEvent::CompactionEnded { failed } => match failed {
                None => step.event(ClaudeEvent::Notice("compact".into())),
                Some(msg) => step.event(ClaudeEvent::CompactionFailed((!msg.is_empty()).then_some(msg))),
            },
            PiStreamEvent::Retrying(reason) => {
                let text = if reason.is_empty() {
                    tr("Opnieuw proberen na een fout…", "Retrying after an error…").to_string()
                } else {
                    reason
                };
                step.events.push(DriverEvent::System(text));
            }
            PiStreamEvent::Failed(message) => {
                if self.stopping {
                    return;
                }
                self.last_error = Some(message);
            }
            PiStreamEvent::CommandDone { error, .. } => {
                if let Some(err) = error {
                    if !self.stopping {
                        self.last_error = Some(err);
                    }
                }
                self.finish(step);
            }
            PiStreamEvent::Settled { .. } => {
                self.finish(step);
            }
            PiStreamEvent::Ended => {
                if !self.finished {
                    self.pending_end = true;
                    step.events.push(DriverEvent::ScheduleSettle);
                }
            }
        }
    }
}

impl Driver for PiDriver {
    fn receive(&mut self, line: &str) -> Step {
        let mut step = Step::default();
        for event in parse_line(line) {
            self.apply(&mut step, event);
        }
        step
    }

    fn settle(&mut self) -> Step {
        let mut step = Step::default();
        if self.pending_end && !self.finished {
            self.finish(&mut step);
        }
        step
    }

    fn decide(&mut self, request_id: &str, allow: bool, _always: bool) -> Vec<String> {
        if self.confirmations.remove(request_id) {
            vec![rpc::confirm_response(request_id, allow)]
        } else {
            Vec::new()
        }
    }

    fn answer(&mut self, request_id: &str, answers: &[(String, Vec<String>)]) -> Option<Vec<String>> {
        let orig_id = self.dialogs.remove(request_id)?;
        let value = answers.first().and_then(|(_, sel)| sel.first()).map(String::as_str).filter(|s| !s.is_empty());
        Some(vec![rpc::dialog_response(&orig_id, value)])
    }

    fn steer(&mut self, text: &str) -> Option<Vec<String>> {
        if self.finished {
            return None;
        }
        Some(vec![rpc::prompt(text, true)])
    }

    fn interrupt(&mut self) -> Vec<String> {
        self.stopping = true;
        vec![rpc::abort()]
    }
}

/// Path to `nook-pi-extension.ts` on disk (exposed for diagnostics and tests).
pub fn extension_file_path() -> PathBuf {
    extension::file_path()
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;
    use crate::workspace::bridge::BridgeLaunch;
    use crate::workspace::models::{ExecutionMode, RunProvider};

    fn sample_input(prompt: &str) -> CommandInput {
        CommandInput {
            provider: RunProvider::Pi,
            executable: "/usr/local/bin/pi".into(),
            prompt: prompt.into(),
            model: "anthropic/claude-sonnet-4-5".into(),
            mode: ExecutionMode::Agent,
            permission: PermissionPolicy::Ask,
            instructions: "Stay concise.".into(),
            working_directory: "/tmp/project".into(),
            resume_session_id: None,
            fork_session: false,
            resume_at: None,
            pending_rollback: None,
            account_environment: BTreeMap::new(),
            run_id: "run-123".into(),
            profile_id: "pi".into(),
            bridge: None,
            effort: Some("high".into()),
            tool_search: None,
            tuning: Default::default(),
            omit_agent_credits: false,
        }
    }

    #[test]
    fn rpc_builders_emit_valid_lf_json() {
        let state: Value = serde_json::from_str(rpc::get_state().trim()).unwrap();
        assert_eq!(state, json!({ "type": "get_state", "id": "nook-state" }));
        assert!(rpc::get_state().ends_with('\n'));

        let models: Value = serde_json::from_str(rpc::get_available_models("nook-models").trim()).unwrap();
        assert_eq!(models, json!({ "type": "get_available_models", "id": "nook-models" }));

        let p: Value = serde_json::from_str(rpc::prompt("hello", false).trim()).unwrap();
        assert_eq!(p, json!({ "type": "prompt", "message": "hello" }));

        let s: Value = serde_json::from_str(rpc::prompt("switch", true).trim()).unwrap();
        assert_eq!(s, json!({ "type": "prompt", "message": "switch", "streamingBehavior": "steer" }));

        let ab: Value = serde_json::from_str(rpc::abort().trim()).unwrap();
        assert_eq!(ab, json!({ "type": "abort" }));

        let ok: Value = serde_json::from_str(rpc::confirm_response("r1", true).trim()).unwrap();
        assert_eq!(ok, json!({ "type": "extension_ui_response", "id": "r1", "confirmed": true }));

        let val: Value = serde_json::from_str(rpc::dialog_response("d1", Some("prod")).trim()).unwrap();
        assert_eq!(val, json!({ "type": "extension_ui_response", "id": "d1", "value": "prod" }));

        let cancel: Value = serde_json::from_str(rpc::dialog_response("d1", None).trim()).unwrap();
        assert_eq!(cancel, json!({ "type": "extension_ui_response", "id": "d1", "cancelled": true }));

        let c1: Value = serde_json::from_str(rpc::compact("  ").trim()).unwrap();
        assert_eq!(c1, json!({ "type": "compact" }));

        let c2: Value = serde_json::from_str(rpc::compact(" keep tests ").trim()).unwrap();
        assert_eq!(c2, json!({ "type": "compact", "customInstructions": "keep tests" }));
    }

    #[test]
    fn turn_input_maps_compact_and_regular_prompts() {
        let regular = rpc::turn_input("Fix the bug");
        assert_eq!(regular.len(), 2);
        assert_eq!(serde_json::from_str::<Value>(regular[0].trim()).unwrap()["type"], "get_state");
        assert_eq!(serde_json::from_str::<Value>(regular[1].trim()).unwrap(), json!({ "type": "prompt", "message": "Fix the bug" }));

        let compact = rpc::turn_input("  /compact  ");
        assert_eq!(serde_json::from_str::<Value>(compact[1].trim()).unwrap(), json!({ "type": "compact" }));

        let guided = rpc::turn_input("/compact keep migration notes");
        assert_eq!(
            serde_json::from_str::<Value>(guided[1].trim()).unwrap(),
            json!({ "type": "compact", "customInstructions": "keep migration notes" })
        );
    }

    #[test]
    fn split_model_splits_on_first_slash_only() {
        assert_eq!(rpc::split_model("anthropic/claude-sonnet-4-5"), Some(("anthropic", "claude-sonnet-4-5")));
        assert_eq!(rpc::split_model("openrouter/deepseek/deepseek-v4-flash"), Some(("openrouter", "deepseek/deepseek-v4-flash")));
        assert_eq!(rpc::split_model("bare-model"), None);
        assert_eq!(rpc::split_model("/leading"), None);
        assert_eq!(rpc::split_model("trailing/"), None);
    }

    #[test]
    fn pi_model_reply_parses_and_deduplicates() {
        let line = json!({
            "type": "response",
            "id": "nook-models",
            "command": "get_available_models",
            "success": true,
            "data": {
                "models": [
                    { "provider": "openrouter", "id": "deepseek/v4", "name": "DeepSeek V4", "contextWindow": 1048576, "reasoning": true },
                    { "provider": "openrouter", "id": "deepseek/v4", "name": "Duplicate" },
                    { "provider": "", "id": "ignored" },
                    { "provider": "anthropic", "id": "claude-sonnet-4-5" }
                ]
            }
        })
        .to_string();
        let parsed = PiModel::reply_in(&line).unwrap();
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].slug(), "openrouter/deepseek/v4");
        assert_eq!(parsed[0].context_window, Some(1_048_576));
        assert!(parsed[0].supports_thinking);
        assert_eq!(parsed[1].slug(), "anthropic/claude-sonnet-4-5");
        assert_eq!(parsed[1].name, "claude-sonnet-4-5");
        assert!(PiModel::reply_in(r#"{"type":"agent_start"}"#).is_none());
    }

    #[test]
    fn extension_install_writes_once_and_updates_when_stale() {
        let dir = std::env::temp_dir().join(format!("nook-pi-ext-{}", uuid::Uuid::new_v4()));
        let file = dir.join("nook-pi-extension.ts");
        assert!(extension::install_at(&file));
        let first = std::fs::read_to_string(&file).unwrap();
        assert!(first.contains("NOOK_PI_PERMISSION"));
        assert!(first.contains("NOOK_PI_BRIDGE"));
        assert!(first.contains("mcp__nook__"));
        assert!(extension::install_at(&file));
        std::fs::write(&file, "stale").unwrap();
        assert!(extension::install_at(&file));
        assert_eq!(std::fs::read_to_string(&file).unwrap(), first);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn launch_spec_wires_flags_and_extension_env() {
        let mut input = sample_input("hello");
        input.resume_session_id = Some("/tmp/s.jsonl".into());
        input.permission = PermissionPolicy::AcceptEdits;
        input.bridge = Some(BridgeLaunch { script: "/h/.nook/nook-mcp".into() });
        let (spec, _) = launch_with_extension(&input, Path::new("/sup/nook-pi-extension.ts"));
        assert_eq!(spec.executable, "/usr/local/bin/pi");
        assert!(spec.arguments.windows(2).any(|w| w == ["--mode", "rpc"]));
        assert!(spec.arguments.windows(2).any(|w| w == ["--session", "/tmp/s.jsonl"]));
        assert!(spec.arguments.windows(2).any(|w| w == ["--provider", "anthropic"]));
        assert!(spec.arguments.windows(2).any(|w| w == ["--model", "claude-sonnet-4-5"]));
        assert!(spec.arguments.windows(2).any(|w| w == ["--thinking", "high"]));
        assert!(spec.arguments.windows(2).any(|w| w == ["--extension", "/sup/nook-pi-extension.ts"]));
        assert!(spec.arguments.iter().any(|a| a == "--append-system-prompt"));
        assert_eq!(spec.extra_environment.get("NOOK_PI_PERMISSION").map(String::as_str), Some("acceptEdits"));
        assert_eq!(spec.extra_environment.get("NOOK_PI_BRIDGE").map(String::as_str), Some("/h/.nook/nook-mcp"));
        assert_eq!(spec.extra_environment.get("NOOK_RUN_ID").map(String::as_str), Some("run-123"));
        assert!(spec.keeps_input_open);
        assert_eq!(spec.initial_input.len(), 2);
    }

    #[test]
    fn driver_handles_approvals_dialogs_compaction_and_settle() {
        let mut driver = PiDriver::new(&sample_input("Run checks"));

        // Confirm dialog with JSON input from Nook's extension.
        let confirm = json!({
            "type": "extension_ui_request",
            "id": "c-1",
            "method": "confirm",
            "title": "Allow bash?",
            "message": "{\"command\":\"cargo test\"}"
        })
        .to_string();
        let step = driver.receive(&confirm);
        assert_eq!(
            step.events,
            vec![DriverEvent::Claude(ClaudeEvent::PermissionRequest {
                request_id: "c-1".into(),
                tool: "bash".into(),
                input: json!({ "command": "cargo test" }),
                suggestions: None,
                tool_use_id: None,
            })]
        );
        let reply = driver.decide("c-1", true, true);
        assert_eq!(
            serde_json::from_str::<Value>(reply[0].trim()).unwrap(),
            json!({ "type": "extension_ui_response", "id": "c-1", "confirmed": true })
        );
        assert!(driver.decide("c-1", false, false).is_empty());

        // Select dialog -> AskUserQuestion -> value answer.
        let select = json!({
            "type": "extension_ui_request",
            "id": "d-1",
            "method": "select",
            "title": "Environment",
            "message": "Pick a target",
            "options": ["staging", "prod"]
        })
        .to_string();
        let step = driver.receive(&select);
        match &step.events[0] {
            DriverEvent::Claude(ClaudeEvent::PermissionRequest { request_id, tool, input, .. }) => {
                assert_eq!(request_id, "pidialog-d-1");
                assert_eq!(tool, "AskUserQuestion");
                assert_eq!(input["questions"][0]["header"], "Environment");
                assert_eq!(input["questions"][0]["question"], "Pick a target");
                assert_eq!(input["questions"][0]["options"][0]["label"], "staging");
            }
            other => panic!("unexpected: {other:?}"),
        }
        let ans = driver.answer("pidialog-d-1", &[("Pick a target".into(), vec!["prod".into()])]).unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(ans[0].trim()).unwrap(),
            json!({ "type": "extension_ui_response", "id": "d-1", "value": "prod" })
        );

        // Input dialog with empty answer -> cancelled.
        let input_dlg = json!({
            "type": "extension_ui_request",
            "id": "d-2",
            "method": "input",
            "title": "Tag name"
        })
        .to_string();
        let _ = driver.receive(&input_dlg);
        let cancel = driver.answer("pidialog-d-2", &[("Tag name".into(), vec![])]).unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(cancel[0].trim()).unwrap(),
            json!({ "type": "extension_ui_response", "id": "d-2", "cancelled": true })
        );

        // Compaction events.
        assert_eq!(driver.receive(r#"{"type":"compaction_start"}"#).events, vec![DriverEvent::Claude(ClaudeEvent::CompactionStarted)]);
        assert_eq!(driver.receive(r#"{"type":"compaction_end"}"#).events, vec![DriverEvent::Claude(ClaudeEvent::Notice("compact".into()))]);
        assert_eq!(
            driver.receive(r#"{"type":"compaction_end","errorMessage":"context limit"}"#).events,
            vec![DriverEvent::Claude(ClaudeEvent::CompactionFailed(Some("context limit".into())))]
        );
        assert_eq!(
            driver.receive(r#"{"type":"compaction_end","aborted":true}"#).events,
            vec![DriverEvent::Claude(ClaudeEvent::CompactionFailed(None))]
        );

        // Older Pi without agent_settled: agent_end schedules settle, settle() finishes.
        let ended = driver.receive(r#"{"type":"agent_end"}"#);
        assert_eq!(ended.events, vec![DriverEvent::ScheduleSettle]);
        let settled = driver.settle();
        assert!(matches!(settled.events.as_slice(), [DriverEvent::Claude(ClaudeEvent::Result(r))] if !r.is_error));
        assert!(driver.steer("too late").is_none());
    }

    fn replay_fixture(name: &str) -> (Vec<DriverEvent>, PiDriver) {
        let path =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../apps/macos/Tests/Fixtures/ProviderReplay").join(format!("{name}.ndjson"));
        let raw = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("failed to read {}: {e}", path.display()));
        let mut prompt = String::new();
        let mut frames = Vec::new();
        let mut aborted = false;
        for line in raw.lines().filter(|l| !l.trim().is_empty()) {
            let entry: Value = serde_json::from_str(line).unwrap();
            match entry["type"].as_str().unwrap_or("") {
                "expect_outbound" => {
                    let frame = &entry["frame"];
                    if frame["type"] == "prompt" && frame.get("streamingBehavior").is_none() {
                        prompt = frame["message"].as_str().unwrap_or("").to_string();
                    }
                    if frame["type"] == "abort" {
                        aborted = true;
                        frames.push(None); // marker to trigger driver.interrupt()
                    }
                }
                "emit_inbound" => {
                    frames.push(Some(entry["frame"].to_string()));
                }
                _ => {}
            }
        }
        let mut driver = PiDriver::new(&sample_input(&prompt));
        let mut events = Vec::new();
        for frame in frames {
            match frame {
                Some(line) => events.extend(driver.receive(&line).events),
                None => {
                    let lines = driver.interrupt();
                    assert_eq!(lines, vec![rpc::abort()]);
                }
            }
        }
        if aborted {
            assert!(driver.stopping);
        }
        (events, driver)
    }

    #[test]
    fn replays_all_five_pi_provider_fixtures() {
        // 1. Simple turn: session, thinking, text, usage+cost, settled.
        let (events, _) = replay_fixture("pi_simple");
        assert!(events.iter().any(|e| matches!(
            e,
            DriverEvent::Claude(ClaudeEvent::Initialized { session_id, model })
                if session_id.ends_with("2026-11-12_lanterns.jsonl")
                && model.as_deref() == Some("openrouter/deepseek/deepseek-v4-flash")
        )));
        assert!(events.iter().any(|e| matches!(e, DriverEvent::Claude(ClaudeEvent::Text(t)) if t == "lanterns are lit")));
        let result = events.iter().find_map(|e| match e {
            DriverEvent::Claude(ClaudeEvent::Result(r)) => Some(r),
            _ => None,
        });
        let result = result.expect("pi_simple should finish");
        assert!(!result.is_error);
        assert_eq!(result.usage.input_tokens, Some(1650));
        assert_eq!(result.usage.output_tokens, Some(24));
        assert_eq!(result.usage.context_tokens, Some(1674));
        assert_eq!(result.usage.context_window, Some(1_048_576));
        assert!(result.usage.reported_cost_usd.unwrap() > 0.0);

        // 2. Message steering: steer receipt emitted for steered message, NOT for initial prompt, usage summed.
        let (events, _) = replay_fixture("pi_message_steering");
        let reads: Vec<&str> = events
            .iter()
            .filter_map(|e| match e {
                DriverEvent::UserMessageRead(t) => Some(t.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(reads, vec!["Change of plan, say only: plan B it is"]);
        let result = events
            .iter()
            .find_map(|e| match e {
                DriverEvent::Claude(ClaudeEvent::Result(r)) => Some(r),
                _ => None,
            })
            .unwrap();
        assert_eq!(result.usage.input_tokens, Some(1655 + 28));
        assert_eq!(result.usage.cache_read_tokens, Some(1680));
        assert_eq!(result.usage.context_tokens, Some(1727));

        // 3 & 4. Multi-turn 1 and 2 preserve the same session file.
        let (events1, _) = replay_fixture("pi_multi_turn_1");
        let (events2, _) = replay_fixture("pi_multi_turn_2");
        let s1 = events1.iter().find_map(|e| match e {
            DriverEvent::Claude(ClaudeEvent::Result(r)) => r.session_id.clone(),
            _ => None,
        });
        let s2 = events2.iter().find_map(|e| match e {
            DriverEvent::Claude(ClaudeEvent::Result(r)) => r.session_id.clone(),
            _ => None,
        });
        assert_eq!(s1, s2);
        assert!(s1.unwrap().ends_with("2026-11-12_kettle.jsonl"));

        // 5. Turn interrupt: tool ran + failed, abort suppressed Pi's "This operation was aborted" error.
        let (events, _) = replay_fixture("pi_turn_interrupt");
        assert!(events.iter().any(|e| matches!(e, DriverEvent::Claude(ClaudeEvent::ToolUse { name, .. }) if name == "bash")));
        assert!(events.iter().any(|e| matches!(e, DriverEvent::Claude(ClaudeEvent::ToolResult { is_error: true, .. }))));
        let result = events
            .iter()
            .find_map(|e| match e {
                DriverEvent::Claude(ClaudeEvent::Result(r)) => Some(r),
                _ => None,
            })
            .unwrap();
        assert!(!result.is_error, "abort error should be suppressed while stopping");
    }
}
