//! Agents over ACP, the Agent Client Protocol (`AcpAgent.swift` and `WorkspaceManager+Acp.swift` on the Mac): Gemini
//! CLI, OpenCode, Cursor, Grok and Antigravity. JSON-RPC 2.0 over stdin/stdout, ACP v1 shapes. Per turn Nook starts the
//! agent, `initialize`s, opens the session (`session/new`, or `session/resume` / `session/load` to go on with an
//! earlier one), sets the model and mode, sends `session/prompt`, shows `session/update` live, and answers
//! `session/request_permission` from Nook's approval card. Stop sends `session/cancel`.

use std::collections::HashMap;

use serde_json::{json, Value};

use super::antigravity;
use super::bridge::SERVER_NAME;
use super::command::{CommandInput, LaunchSpec};
use super::driver::{self, Driver, DriverEvent, Message, RpcId, Step, Wire};
use super::models::{ExecutionMode, PermissionPolicy, RunProvider, TurnUsage};
use super::parsers::{number, ClaudeEvent, ClaudeTurnResult, TokenCounts};
use crate::i18n::tr;

const WIRE: Wire = Wire { jsonrpc: true };
pub const PROTOCOL_VERSION: i64 = 1;

/// How to start an agent's ACP server (the arguments the ACP registry lists for it).
pub fn arguments(provider: RunProvider, permission: PermissionPolicy) -> Vec<String> {
    let list: &[&str] = match provider {
        RunProvider::Gemini => &["--acp"],
        RunProvider::Opencode | RunProvider::Cursor => &["acp"],
        // Grok decides on approvals itself with --always-approve; otherwise it asks Nook.
        RunProvider::Grok if permission == PermissionPolicy::Bypass => &["agent", "--always-approve", "stdio"],
        RunProvider::Grok => &["agent", "stdio"],
        // Antigravity's server takes no arguments; its account and harness come from the environment.
        RunProvider::Antigravity | RunProvider::Claude | RunProvider::Codex => &[],
    };
    list.iter().map(|s| s.to_string()).collect()
}

/// The process and its driver for one turn.
pub fn launch(input: &CommandInput) -> Result<(LaunchSpec, AcpDriver), String> {
    let mut environment = input.account_environment.clone();
    environment.insert("NOOK_RUN_ID".into(), input.run_id.clone());
    let mut executable = input.executable.clone();
    if input.provider == RunProvider::Antigravity {
        let server = antigravity::server(&input.executable).ok_or_else(antigravity::not_installed)?;
        let prepared = antigravity::prepare(&input.profile_id, &server, &input.account_environment)?;
        environment.extend(prepared);
        executable = server;
    }
    let mut driver = AcpDriver::new(input);
    let first = driver.initialize();
    let spec = LaunchSpec {
        executable,
        arguments: arguments(input.provider, input.permission),
        extra_environment: environment,
        working_directory: input.working_directory.clone(),
        initial_input: vec![first],
        keeps_input_open: true,
    };
    Ok((spec, driver))
}

/// Whether a request may be allowed without asking, under the session's rights.
pub fn auto_allows(kind: &str, permission: PermissionPolicy, mode: ExecutionMode) -> bool {
    if kind == "elicitation" {
        return false;
    }
    if mode == ExecutionMode::Plan {
        return ["read", "search", "think", "fetch"].contains(&kind);
    }
    match permission {
        PermissionPolicy::Bypass => true,
        PermissionPolicy::AcceptEdits => ["read", "search", "think", "fetch", "edit", "move"].contains(&kind),
        PermissionPolicy::Ask => ["read", "search", "think"].contains(&kind),
    }
}

/// The option to answer a permission request with: the kind you chose, or the closest one the agent offers.
pub fn permission_outcome(options: &[(String, String)], allow: bool, always: bool) -> Value {
    let wanted: &[&str] = match (allow, always) {
        (true, true) => &["allow_always", "allow_once"],
        (true, false) => &["allow_once", "allow_always"],
        (false, _) => &["reject_once", "reject_always"],
    };
    for kind in wanted {
        if let Some((id, _)) = options.iter().find(|(_, k)| k == kind) {
            return json!({"outcome": {"outcome": "selected", "optionId": id}});
        }
    }
    cancelled()
}

fn cancelled() -> Value {
    json!({"outcome": {"outcome": "cancelled"}})
}

/// A tool call as the timeline shows it: the name Nook groups by and an input its summaries read.
#[derive(Debug, Clone, PartialEq)]
pub struct ToolCall {
    pub id: String,
    pub title: String,
    /// read, edit, delete, move, search, execute, think, fetch, switch_mode, other.
    pub kind: String,
    pub status: Option<String>,
    pub input: Value,
    pub output: String,
    pub paths: Vec<String>,
    pub diffs: Vec<(String, Option<String>, String)>,
}

impl ToolCall {
    pub fn read(raw: &Value) -> Self {
        let mut output = vec![];
        let mut paths: Vec<String> = vec![];
        let mut diffs = vec![];
        for item in raw.get("content").and_then(Value::as_array).into_iter().flatten() {
            match item.get("type").and_then(Value::as_str) {
                Some("content") => {
                    if let Some(t) = text(item.get("content")) {
                        output.push(t);
                    }
                }
                Some("diff") => {
                    let Some(path) = item.get("path").and_then(Value::as_str).map(file_path) else { continue };
                    if !paths.contains(&path) {
                        paths.push(path.clone());
                    }
                    if let Some(new) = item.get("newText").and_then(Value::as_str) {
                        diffs.push((path, item.get("oldText").and_then(Value::as_str).map(str::to_string), new.to_string()));
                    }
                }
                _ => {}
            }
        }
        let kind = raw.get("kind").and_then(Value::as_str).unwrap_or("").to_string();
        for location in raw.get("locations").and_then(Value::as_array).into_iter().flatten() {
            if let Some(path) = location.get("path").and_then(Value::as_str).map(file_path) {
                if !paths.contains(&path) && (kind == "edit" || kind == "read") {
                    paths.push(path);
                }
            }
        }
        // Some agents (Antigravity) put a failed call's reason only in rawOutput.
        if output.is_empty() {
            if let Some(o) = raw.get("rawOutput").and_then(raw_output) {
                output.push(o);
            }
        }
        Self {
            id: raw.get("toolCallId").and_then(Value::as_str).map(str::to_string).unwrap_or_else(|| uuid::Uuid::new_v4().to_string()),
            title: raw.get("title").and_then(Value::as_str).unwrap_or("").to_string(),
            kind,
            status: raw.get("status").and_then(Value::as_str).map(str::to_string),
            input: raw.get("rawInput").cloned().unwrap_or(Value::Null),
            output: output.join("\n"),
            paths,
            diffs,
        }
    }

    /// The tool name Nook's timeline and approval card read: edits are Edit (so the change is recorded and its diff
    /// shown), commands `shell`, the rest by their ACP kind.
    pub fn name(&self) -> String {
        match self.kind.as_str() {
            "execute" => "shell".into(),
            "edit" | "move" if self.diffs.iter().any(|d| d.1.is_none()) && self.diffs.len() == 1 => "Write".into(),
            "edit" | "move" => "Edit".into(),
            "delete" => "delete".into(),
            "read" => "read".into(),
            "search" => "grep".into(),
            "fetch" => "webfetch".into(),
            "" => "tool".into(),
            other => other.into(),
        }
    }

    /// The input with what the summaries need: the command, the file and the change (old/new text), the title.
    pub fn summary_input(&self) -> Value {
        let mut input = if self.input.is_object() { self.input.clone() } else { json!({}) };
        if self.kind == "execute" && input.get("command").is_none() {
            input["command"] = json!(self.title);
        }
        if let Some(first) = self.paths.first() {
            if super::models::tool_summary::path(&input).is_none() {
                input["file_path"] = json!(first);
            }
        }
        if let [(path, old, new)] = self.diffs.as_slice() {
            input["file_path"] = json!(path);
            input["old_string"] = json!(old.clone().unwrap_or_default());
            input["new_string"] = json!(new);
        }
        if input.as_object().is_some_and(|o| o.is_empty()) && !self.title.is_empty() {
            input["description"] = json!(self.title);
        }
        input
    }
}

/// A file as a path; some agents name it as a `file://` URL.
pub fn file_path(value: &str) -> String {
    match value.strip_prefix("file://") {
        Some(rest) => percent_encoding::percent_decode_str(rest).decode_utf8_lossy().into_owned(),
        None => value.to_string(),
    }
}

fn raw_output(value: &Value) -> Option<String> {
    match value {
        Value::String(s) if !s.is_empty() => Some(s.clone()),
        Value::Object(o) => {
            for key in ["error", "message", "output", "stderr", "result"] {
                if let Some(t) = o.get(key).and_then(Value::as_str).filter(|t| !t.is_empty()) {
                    return Some(t.into());
                }
                if let Some(t) = o.get(key).and_then(|v| v.get("message")).and_then(Value::as_str).filter(|t| !t.is_empty()) {
                    return Some(t.into());
                }
            }
            (!o.is_empty()).then(|| value.to_string())
        }
        Value::Null | Value::String(_) => None,
        other => Some(other.to_string()),
    }
}

fn text(block: Option<&Value>) -> Option<String> {
    let block = block?;
    (block.get("type").and_then(Value::as_str) == Some("text"))
        .then(|| block.get("text").and_then(Value::as_str).unwrap_or("").to_string())
        .filter(|t| !t.is_empty())
}

#[derive(Debug, Clone, PartialEq)]
enum Call {
    Initialize,
    Authenticate,
    Open { method: &'static str, loading: Option<String> },
    Setting,
    Prompt,
    Other,
}

struct Permission {
    rpc: RpcId,
    options: Vec<(String, String)>,
    elicitation: bool,
}

pub struct AcpDriver {
    provider: RunProvider,
    next: i64,
    calls: HashMap<i64, Call>,
    cwd: String,
    model: String,
    mode: ExecutionMode,
    permission: PermissionPolicy,
    effort: Option<String>,
    prompt: String,
    instructions: String,
    resume: Option<String>,
    bridge: Option<Value>,
    /// From `initialize`.
    load: bool,
    resume_method: bool,
    auth_methods: Vec<String>,
    signed_in: bool,
    session: Option<String>,
    fresh: bool,
    /// What the session offers (`configOptions`, `modes`, `models` of its open answer).
    info: Value,
    /// Settings still to send before the prompt.
    pending_settings: Vec<(String, Value)>,
    /// `session/load` replays the conversation: Nook already has it.
    replaying: bool,
    permissions: HashMap<String, Permission>,
    tool_names: HashMap<String, (String, Value)>,
    replied: bool,
    thought: String,
    tool_calls: usize,
    continuations: usize,
    stopping: bool,
    used: Option<u64>,
    size: Option<u64>,
    finished: bool,
    signed_in_note: bool,
}

impl AcpDriver {
    pub fn new(input: &CommandInput) -> Self {
        let bridge = input.bridge.as_ref().map(|b| {
            json!({"name": SERVER_NAME, "command": b.script, "args": ["--agent", input.provider.id()], "env": [{"name": "NOOK_RUN_ID", "value": input.run_id}]})
        });
        Self {
            provider: input.provider,
            next: 1,
            calls: HashMap::new(),
            cwd: input.working_directory.clone(),
            model: input.model.trim().into(),
            mode: input.mode,
            permission: input.permission,
            effort: input.effort.clone().filter(|e| !e.is_empty()),
            prompt: input.prompt.clone(),
            instructions: driver::instructions(input),
            resume: input.resume_session_id.clone().filter(|s| !s.is_empty()),
            bridge,
            load: false,
            resume_method: false,
            auth_methods: vec![],
            signed_in: false,
            session: None,
            fresh: false,
            info: Value::Null,
            pending_settings: vec![],
            replaying: false,
            permissions: HashMap::new(),
            tool_names: HashMap::new(),
            replied: false,
            thought: String::new(),
            tool_calls: 0,
            continuations: 0,
            stopping: false,
            used: None,
            size: None,
            finished: false,
            signed_in_note: false,
        }
    }

    fn request(&mut self, call: Call, method: &str, params: Value) -> String {
        let id = driver::next_id(&mut self.next);
        self.calls.insert(id, call);
        WIRE.request(id, method, params)
    }

    fn initialize(&mut self) -> String {
        // Nook reads no files and runs no terminals for the agent: it does that itself.
        self.request(
            Call::Initialize,
            "initialize",
            json!({
                "protocolVersion": PROTOCOL_VERSION,
                "clientCapabilities": {"fs": {"readTextFile": false, "writeTextFile": false}, "terminal": false, "elicitation": {"form": {}}},
                "clientInfo": {"name": "nook", "title": "Nook", "version": env!("CARGO_PKG_VERSION")}
            }),
        )
    }

    fn open(&mut self, step: &mut Step) {
        let continuing = self.resume.clone().filter(|_| self.load || self.resume_method);
        if self.resume.is_some() && continuing.is_none() {
            step.events.push(DriverEvent::System(driver::no_load_note(self.provider)));
            self.resume = None;
        }
        let method = match &continuing {
            None => "session/new",
            Some(_) if self.resume_method => "session/resume",
            Some(_) => "session/load",
        };
        let mut params = json!({"cwd": self.cwd, "mcpServers": self.bridge.iter().cloned().collect::<Vec<_>>()});
        if let Some(id) = &continuing {
            params["sessionId"] = json!(id);
        }
        self.replaying = method == "session/load";
        let line = self.request(Call::Open { method, loading: continuing }, method, params);
        step.replies.push(line);
    }

    fn fail(&mut self, step: &mut Step, message: String) {
        self.finish(step, true, "error", message, TurnUsage::default());
    }

    fn finish(&mut self, step: &mut Step, failed: bool, reason: &str, message: String, mut usage: TurnUsage) {
        if self.finished {
            return;
        }
        self.finished = true;
        usage.context_window = self.size;
        // The context as the agent last reported it.
        if let Some(used) = self.used {
            step.event(ClaudeEvent::Usage {
                message_id: "acp-context".into(),
                tokens: TokenCounts { input: used, ..Default::default() },
                model: None,
            });
        }
        for (_, p) in self.permissions.drain() {
            step.replies.push(WIRE.response(&p.rpc, cancelled()));
        }
        step.event(ClaudeEvent::Result(ClaudeTurnResult {
            is_error: failed && !self.stopping,
            subtype: reason.into(),
            text: message,
            session_id: self.session.clone(),
            usage,
            ..Default::default()
        }));
    }

    /// The settings the run asks for that the session does not have yet: the model, the effort, then the mode.
    fn settings(&self) -> Vec<(String, Value)> {
        let session = self.session.clone().unwrap_or_default();
        let options: Vec<Value> = self.info.get("configOptions").and_then(Value::as_array).cloned().unwrap_or_default();
        let option = |category: &str| options.iter().find(|o| o.get("category").and_then(Value::as_str) == Some(category)).cloned();
        let values = |o: &Value| -> Vec<String> {
            o.get("options")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .flat_map(|x| x.get("options").and_then(Value::as_array).cloned().unwrap_or_else(|| vec![x.clone()]))
                .filter_map(|x| x.get("value").and_then(Value::as_str).map(str::to_string))
                .collect()
        };
        let current = |o: &Value| o.get("currentValue").and_then(Value::as_str).map(str::to_string);
        let mut steps = vec![];
        if !self.model.is_empty() {
            match option("model") {
                Some(o) if current(&o).as_deref() != Some(self.model.as_str()) => steps.push((
                    "session/set_config_option".to_string(),
                    json!({"sessionId": session, "configId": o.get("id"), "value": self.model}),
                )),
                Some(_) => {}
                None if self.info.pointer("/models/currentModelId").and_then(Value::as_str) != Some(self.model.as_str()) => {
                    steps.push(("session/set_model".into(), json!({"sessionId": session, "modelId": self.model})))
                }
                None => {}
            }
        }
        if let (Some(effort), Some(o)) = (&self.effort, option("thought_level")) {
            if values(&o).contains(effort) && current(&o).as_ref() != Some(effort) {
                steps.push(("session/set_config_option".into(), json!({"sessionId": session, "configId": o.get("id"), "value": effort})));
            }
        }
        let mode_ids: Vec<String> = self
            .info
            .pointer("/modes/availableModes")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|m| m.get("id").and_then(Value::as_str).map(str::to_string))
            .collect();
        let mode_option = option("mode");
        let offered: Vec<String> = mode_option.as_ref().map(&values).unwrap_or_default().into_iter().chain(mode_ids.clone()).collect();
        let wanted = match self.provider {
            RunProvider::Antigravity => Some(antigravity::mode(self.mode, self.permission).to_string()),
            _ if self.mode == ExecutionMode::Plan => offered.iter().find(|m| m.to_lowercase().contains("plan")).cloned(),
            _ => None,
        };
        let applied = mode_option.as_ref().and_then(current).or_else(|| self.info.pointer("/modes/currentModeId").and_then(Value::as_str).map(str::to_string));
        if let Some(mode) = wanted.filter(|m| Some(m) != applied.as_ref() && offered.contains(m)) {
            match &mode_option {
                Some(o) => steps.push(("session/set_config_option".into(), json!({"sessionId": session, "configId": o.get("id"), "value": mode}))),
                None => steps.push(("session/set_mode".into(), json!({"sessionId": session, "modeId": mode}))),
            }
        }
        steps
    }

    /// The next setting, or the prompt once they are all answered.
    fn proceed(&mut self, step: &mut Step) {
        if self.stopping {
            return self.finish(step, false, "cancelled", String::new(), TurnUsage::default());
        }
        if !self.pending_settings.is_empty() {
            let (method, params) = self.pending_settings.remove(0);
            let line = self.request(Call::Setting, &method, params);
            step.replies.push(line);
            return;
        }
        let mut text = self.prompt.clone();
        if self.fresh && !self.instructions.is_empty() {
            text = format!("{}\n\n{text}", self.instructions);
        }
        self.fresh = false;
        if self.mode == ExecutionMode::Plan {
            text = format!("{}\n\n{text}", driver::PLAN_ONLY);
        }
        self.send_prompt(step, text);
    }

    fn send_prompt(&mut self, step: &mut Step, text: String) {
        let session = self.session.clone().unwrap_or_default();
        let line = self.request(Call::Prompt, "session/prompt", json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}));
        step.replies.push(line);
    }

    fn response(&mut self, step: &mut Step, call: Call, result: Value, error: Option<String>) {
        match call {
            Call::Initialize => {
                if let Some(e) = error {
                    return self.fail(step, e);
                }
                // A v2 answer has `info` and its capabilities under `capabilities.session`.
                let agent = result.get("agentCapabilities").cloned().unwrap_or_else(|| {
                    let session = result.pointer("/capabilities/session").cloned().unwrap_or(Value::Null);
                    json!({"loadSession": !session.is_null(), "sessionCapabilities": if session.is_null() { json!({}) } else { json!({"resume": {}}) }})
                });
                self.load = agent.get("loadSession").and_then(Value::as_bool).unwrap_or(false);
                self.resume_method = agent.pointer("/sessionCapabilities/resume").is_some_and(Value::is_object);
                self.auth_methods = result
                    .get("authMethods")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter(|m| m.get("type").and_then(Value::as_str).unwrap_or("agent") == "agent")
                    .filter_map(|m| m.get("id").and_then(Value::as_str).map(str::to_string))
                    .collect();
                if self.provider == RunProvider::Antigravity && self.auth_methods.iter().any(|m| m == antigravity::AUTH_METHOD) {
                    // Antigravity signs in first; with a saved token this returns at once.
                    self.signed_in = true;
                    let line = self.request(Call::Authenticate, "authenticate", json!({"methodId": antigravity::AUTH_METHOD}));
                    step.replies.push(line);
                    return;
                }
                self.open(step);
            }
            Call::Authenticate => match error {
                Some(e) => self.fail(step, e),
                None => self.open(step),
            },
            Call::Open { method, loading } => {
                self.replaying = false;
                if let Some(e) = error {
                    if loading.is_some() && driver::session_gone(&e) {
                        step.events.push(DriverEvent::System(driver::no_load_note(self.provider)));
                        self.resume = None;
                        return self.open(step);
                    }
                    if !self.signed_in && driver::needs_sign_in(&e) && !self.auth_methods.is_empty() {
                        self.signed_in = true;
                        let method = self.auth_methods[0].clone();
                        let line = self.request(Call::Authenticate, "authenticate", json!({"methodId": method}));
                        step.replies.push(line);
                        return;
                    }
                    return self.fail(step, e);
                }
                let _ = method;
                let session = result.get("sessionId").and_then(Value::as_str).map(str::to_string).or(loading.clone());
                let Some(session) = session else { return self.fail(step, tr("De agent opende geen sessie.", "The agent opened no session.").into()) };
                self.fresh = loading.is_none();
                self.session = Some(session.clone());
                self.info = result;
                let model = self.info.pointer("/models/currentModelId").and_then(Value::as_str).map(str::to_string);
                step.event(ClaudeEvent::Initialized { session_id: session, model });
                self.pending_settings = self.settings();
                self.proceed(step);
            }
            // A setting the agent refused does not hold up the prompt.
            Call::Setting => self.proceed(step),
            Call::Prompt => {
                if let Some(e) = error {
                    return if self.stopping { self.finish(step, false, "cancelled", String::new(), TurnUsage::default()) } else { self.fail(step, e) };
                }
                let reason = result.get("stopReason").and_then(Value::as_str).unwrap_or("end_turn").to_string();
                let usage = prompt_usage(&result);
                if self.provider == RunProvider::Antigravity && !self.stopping {
                    // Antigravity sometimes writes its whole answer as thinking: that thought becomes the reply.
                    if !self.replied && self.tool_calls == 0 && !self.thought.trim().is_empty() {
                        step.event(ClaudeEvent::Text(self.thought.trim().to_string()));
                        self.replied = true;
                    }
                    if antigravity::should_continue(&reason, self.replied, self.stopping, self.continuations) {
                        self.continuations += 1;
                        step.events.push(DriverEvent::System(
                            tr("Antigravity stopte zonder antwoord; Nook vraagt hem verder te gaan.", "Antigravity stopped without replying; Nook asks it to carry on.").into(),
                        ));
                        let text = antigravity::continuation(self.tool_calls);
                        return self.send_prompt(step, text);
                    }
                }
                let failed = reason == "refusal";
                let message = if failed { tr("De agent weigerde deze opdracht.", "The agent refused this request.").to_string() } else { String::new() };
                self.finish(step, failed, &reason, message, usage);
            }
            Call::Other => {}
        }
    }

    fn update(&mut self, step: &mut Step, update: &Value) {
        if self.replaying {
            return;
        }
        match update.get("sessionUpdate").and_then(Value::as_str) {
            Some("agent_message_chunk") => {
                if let Some(t) = text(update.get("content")) {
                    if !t.trim().is_empty() {
                        self.replied = true;
                    }
                    step.event(ClaudeEvent::TextDelta(t));
                }
            }
            Some("agent_thought_chunk") => {
                if let Some(t) = text(update.get("content")) {
                    let starts = self.thought.is_empty();
                    self.thought.push_str(&t);
                    step.event(ClaudeEvent::ThinkingDelta { text: t, starts });
                }
            }
            Some("tool_call") => {
                // Text that came before the call is done.
                step.event(ClaudeEvent::BlockStopped);
                let call = ToolCall::read(update);
                self.tool_calls += 1;
                self.thought.clear();
                let (name, input) = (call.name(), call.summary_input());
                self.tool_names.insert(call.id.clone(), (name.clone(), input.clone()));
                step.event(ClaudeEvent::ToolUse { id: call.id.clone(), name, input, nested: false });
                self.settle(step, &call);
            }
            Some("tool_call_update") => {
                let call = ToolCall::read(update);
                if !self.tool_names.contains_key(&call.id) {
                    let (name, input) = (call.name(), call.summary_input());
                    self.tool_names.insert(call.id.clone(), (name.clone(), input.clone()));
                    step.event(ClaudeEvent::ToolUse { id: call.id.clone(), name, input, nested: false });
                }
                self.settle(step, &call);
            }
            Some("usage_update") => {
                self.used = number(update.get("used")).map(|n| n as u64);
                self.size = number(update.get("size")).map(|n| n as u64).filter(|n| *n > 0);
            }
            _ => {}
        }
    }

    /// A call that finished: its output, and the files an edit wrote that the name alone does not record.
    fn settle(&mut self, step: &mut Step, call: &ToolCall) {
        let failed = call.status.as_deref() == Some("failed");
        if !failed && call.status.as_deref() != Some("completed") {
            return;
        }
        step.event(ClaudeEvent::ToolResult { id: call.id.clone(), output: call.output.clone(), is_error: failed });
        if failed {
            return;
        }
        let (name, input) = self.tool_names.get(&call.id).cloned().unwrap_or_default();
        let recorded: Vec<String> = super::models::tool_summary::file_changes(&name, &input).into_iter().map(|(p, _)| p).collect();
        if matches!(call.kind.as_str(), "edit" | "move" | "delete") {
            let kind = if call.kind == "delete" { "deleted" } else { "modified" };
            for path in call.paths.iter().filter(|p| !recorded.contains(p)) {
                step.events.push(DriverEvent::FileChange { path: path.clone(), kind: kind.into() });
            }
        }
    }

    fn server_request(&mut self, step: &mut Step, id: RpcId, method: &str, params: &Value) {
        let key = format!("acp-{}", id.text());
        match method {
            "session/request_permission" => {
                let call = ToolCall::read(params.get("toolCall").unwrap_or(&Value::Null));
                let options: Vec<(String, String)> = params
                    .get("options")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|o| Some((o.get("optionId")?.as_str()?.to_string(), o.get("kind").and_then(Value::as_str).unwrap_or("").to_string())))
                    .collect();
                // The session's rights already allow it: answered at once, as the agent would not have asked.
                let kind = if call.kind.is_empty() { self.tool_names.get(&call.id).map(|_| "other").unwrap_or("other").to_string() } else { call.kind.clone() };
                if auto_allows(&kind, self.permission, self.mode) {
                    step.replies.push(WIRE.response(&id, permission_outcome(&options, true, false)));
                    return;
                }
                let (name, input) = match self.tool_names.get(&call.id) {
                    Some((n, i)) if call.kind.is_empty() => (n.clone(), i.clone()),
                    _ => (call.name(), call.summary_input()),
                };
                let always = options.iter().any(|(_, k)| k == "allow_always");
                self.permissions.insert(key.clone(), Permission { rpc: id, options, elicitation: false });
                step.event(ClaudeEvent::PermissionRequest {
                    request_id: key,
                    tool: name,
                    input,
                    suggestions: always.then(|| json!([{"type": "allow_always"}])),
                    tool_use_id: Some(call.id),
                });
            }
            "elicitation/create" | "session/elicitation" => {
                let fields = params.pointer("/requestedSchema/properties").and_then(Value::as_object).is_some_and(|f| !f.is_empty());
                let form = params.get("mode").and_then(Value::as_str).unwrap_or("form") == "form";
                if fields || !form {
                    step.replies.push(WIRE.response(&id, json!({"action": "decline"})));
                    return;
                }
                let server = params.pointer("/_meta/serverName").and_then(Value::as_str).unwrap_or("mcp");
                let message: String = params.get("message").and_then(Value::as_str).unwrap_or("").chars().take(600).collect();
                self.permissions.insert(key.clone(), Permission { rpc: id, options: vec![], elicitation: true });
                step.event(ClaudeEvent::PermissionRequest {
                    request_id: key,
                    tool: format!("mcp__{server}__confirm"),
                    input: json!({"description": message}),
                    suggestions: None,
                    tool_use_id: None,
                });
            }
            // Nook offers no files or terminals (`initialize`): anything else is answered with an error.
            _ => step.replies.push(WIRE.error(&id, -32601, "Nook does not handle this request.")),
        }
    }
}

/// The tokens of a prompt answer, when the agent reports them.
pub fn prompt_usage(result: &Value) -> TurnUsage {
    let Some(raw) = result.get("usage") else { return TurnUsage::default() };
    let n = |k: &str| number(raw.get(k)).map(|v| v.max(0.0) as u64);
    TurnUsage {
        input_tokens: n("inputTokens"),
        output_tokens: n("outputTokens").map(|o| o + n("thoughtTokens").unwrap_or(0)),
        cache_read_tokens: n("cachedReadTokens"),
        cache_write_tokens: n("cachedWriteTokens"),
        ..Default::default()
    }
}

impl Driver for AcpDriver {
    fn receive(&mut self, line: &str) -> Step {
        let mut step = Step::default();
        match driver::parse(line) {
            Some(Message::Response { id, result, error }) => {
                let call = self.calls.remove(&id).unwrap_or(Call::Other);
                self.response(&mut step, call, result, error);
            }
            Some(Message::Notification { method, params }) => {
                if method == "session/update" {
                    if let Some(update) = params.get("update") {
                        self.update(&mut step, update);
                    }
                }
            }
            Some(Message::Request { id, method, params }) => self.server_request(&mut step, id, &method, &params),
            // Text between the frames: Antigravity's sign-in link, or a log line.
            None => {
                if self.provider == RunProvider::Antigravity && !self.signed_in_note {
                    if let Some(url) = antigravity::sign_in_url(line) {
                        self.signed_in_note = true;
                        antigravity::open_sign_in(&url);
                        step.events.push(DriverEvent::System(
                            tr(
                                "Antigravity vraagt je in te loggen: de inlogpagina van Google is geopend in je browser.",
                                "Antigravity asks you to sign in: Google's sign-in page opened in your browser.",
                            )
                            .into(),
                        ));
                    }
                }
            }
        }
        step
    }

    fn decide(&mut self, request_id: &str, allow: bool, always: bool) -> Vec<String> {
        let Some(p) = self.permissions.remove(request_id) else { return vec![] };
        let answer = if p.elicitation {
            if allow {
                json!({"action": "accept", "content": {}})
            } else {
                json!({"action": "decline"})
            }
        } else {
            permission_outcome(&p.options, allow, always)
        };
        vec![WIRE.response(&p.rpc, answer)]
    }

    fn interrupt(&mut self) -> Vec<String> {
        self.stopping = true;
        let mut lines: Vec<String> = self
            .permissions
            .drain()
            .map(|(_, p)| WIRE.response(&p.rpc, if p.elicitation { json!({"action": "cancel"}) } else { cancelled() }))
            .collect();
        if let Some(session) = &self.session {
            lines.push(WIRE.notification("session/cancel", json!({"sessionId": session})));
        }
        lines
    }

    fn removed_environment(&self) -> &'static [&'static str] {
        if self.provider == RunProvider::Antigravity {
            antigravity::REMOVED_ENVIRONMENT
        } else {
            &[]
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    pub(crate) fn input(provider: RunProvider, permission: PermissionPolicy, resume: Option<&str>) -> CommandInput {
        CommandInput {
            provider,
            executable: format!("/usr/bin/{}", provider.kind().command()),
            prompt: "Fix it".into(),
            model: String::new(),
            mode: ExecutionMode::Agent,
            permission,
            instructions: "Be brief".into(),
            working_directory: "/w".into(),
            resume_session_id: resume.map(str::to_string),
            fork_session: false,
            account_environment: BTreeMap::new(),
            run_id: "run-1".into(),
            profile_id: "default".into(),
            bridge: None,
            effort: None,
        }
    }

    fn sent(line: &str) -> Value {
        serde_json::from_str(line.trim()).unwrap()
    }

    fn claude(step: &Step) -> Vec<ClaudeEvent> {
        step.events.iter().filter_map(|e| if let DriverEvent::Claude(c) = e { Some(c.clone()) } else { None }).collect()
    }

    #[test]
    fn launch_arguments() {
        assert_eq!(arguments(RunProvider::Gemini, PermissionPolicy::Ask), vec!["--acp"]);
        assert_eq!(arguments(RunProvider::Cursor, PermissionPolicy::Ask), vec!["acp"]);
        assert_eq!(arguments(RunProvider::Opencode, PermissionPolicy::Ask), vec!["acp"]);
        assert_eq!(arguments(RunProvider::Grok, PermissionPolicy::Bypass), vec!["agent", "--always-approve", "stdio"]);
        assert_eq!(arguments(RunProvider::Grok, PermissionPolicy::Ask), vec!["agent", "stdio"]);
        let (spec, _) = launch(&input(RunProvider::Opencode, PermissionPolicy::Ask, None)).unwrap();
        assert_eq!(sent(&spec.initial_input[0])["method"], "initialize");
        assert_eq!(sent(&spec.initial_input[0])["jsonrpc"], "2.0");
    }

    #[test]
    fn new_session_prompt_permission_and_end() {
        let mut d = AcpDriver::new(&input(RunProvider::Grok, PermissionPolicy::Ask, None));
        d.initialize();
        let s = d.receive(r#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true}}}"#);
        let open = sent(&s.replies[0]);
        assert_eq!(open["method"], "session/new");
        assert_eq!(open["params"]["cwd"], "/w");
        let s = d.receive(r#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s-1","modes":{"currentModeId":"agent","availableModes":[{"id":"agent"},{"id":"plan"}]}}}"#);
        assert_eq!(claude(&s)[0], ClaudeEvent::Initialized { session_id: "s-1".into(), model: None });
        let prompt = sent(&s.replies[0]);
        assert_eq!(prompt["method"], "session/prompt");
        assert!(prompt["params"]["prompt"][0]["text"].as_str().unwrap().starts_with("Be brief\n\nFix it"));
        let s = d.receive(r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hi"}}}}"#);
        assert_eq!(claude(&s)[0], ClaudeEvent::TextDelta("Hi".into()));
        d.receive(r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-1","update":{"sessionUpdate":"tool_call","toolCallId":"c1","title":"rm -rf build","kind":"execute","status":"pending","rawInput":{"command":"rm -rf build"}}}}"#);
        let s = d.receive(r#"{"jsonrpc":"2.0","id":7,"method":"session/request_permission","params":{"sessionId":"s-1","toolCall":{"toolCallId":"c1","kind":"execute","title":"rm -rf build","rawInput":{"command":"rm -rf build"}},"options":[{"optionId":"yes","kind":"allow_once","name":"Yes"},{"optionId":"always","kind":"allow_always","name":"Always"},{"optionId":"no","kind":"reject_once","name":"No"}]}}"#);
        match &claude(&s)[0] {
            ClaudeEvent::PermissionRequest { request_id, tool, input, suggestions, .. } => {
                assert_eq!((request_id.as_str(), tool.as_str()), ("acp-7", "shell"));
                assert_eq!(input["command"], "rm -rf build");
                assert!(suggestions.is_some());
            }
            other => panic!("{other:?}"),
        }
        let answer = sent(&d.decide("acp-7", false, false)[0]);
        assert_eq!(answer["result"]["outcome"]["optionId"], "no");
        let s = d.receive(r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-1","update":{"sessionUpdate":"tool_call_update","toolCallId":"c2","kind":"edit","status":"completed","content":[{"type":"diff","path":"/w/a.txt","oldText":"a","newText":"b"}]}}}"#);
        assert!(claude(&s).iter().any(|e| matches!(e, ClaudeEvent::ToolUse { name, input, .. } if name == "Edit" && input["old_string"] == "a")));
        d.receive(r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-1","update":{"sessionUpdate":"usage_update","used":5000,"size":200000}}}"#);
        let s = d.receive(r#"{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn","usage":{"inputTokens":10,"outputTokens":3,"thoughtTokens":2}}}"#);
        match claude(&s).last().unwrap() {
            ClaudeEvent::Result(r) => {
                assert!(!r.is_error);
                assert_eq!(r.session_id.as_deref(), Some("s-1"));
                assert_eq!(r.usage.output_tokens, Some(5));
                assert_eq!(r.usage.context_window, Some(200_000));
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn rights_answer_without_asking() {
        let mut d = AcpDriver::new(&input(RunProvider::Cursor, PermissionPolicy::AcceptEdits, None));
        let s = d.receive(r#"{"jsonrpc":"2.0","id":9,"method":"session/request_permission","params":{"toolCall":{"toolCallId":"c1","kind":"edit"},"options":[{"optionId":"ok","kind":"allow_once"}]}}"#);
        assert!(s.events.is_empty());
        assert_eq!(sent(&s.replies[0])["result"]["outcome"]["optionId"], "ok");
        assert!(auto_allows("read", PermissionPolicy::Ask, ExecutionMode::Plan));
        assert!(!auto_allows("edit", PermissionPolicy::Bypass, ExecutionMode::Plan));
        assert!(!auto_allows("execute", PermissionPolicy::AcceptEdits, ExecutionMode::Agent));
        assert!(auto_allows("execute", PermissionPolicy::Bypass, ExecutionMode::Agent));
        let s = d.receive(r#"{"jsonrpc":"2.0","id":10,"method":"fs/read_text_file","params":{}}"#);
        assert_eq!(sent(&s.replies[0])["error"]["code"], -32601);
    }

    #[test]
    fn resume_load_replay_and_sign_in() {
        let mut d = AcpDriver::new(&input(RunProvider::Gemini, PermissionPolicy::Ask, Some("old")));
        d.initialize();
        let s = d.receive(r#"{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{"loadSession":true},"authMethods":[{"id":"oauth","name":"Google"}]}}"#);
        let open = sent(&s.replies[0]);
        assert_eq!((open["method"].as_str(), open["params"]["sessionId"].as_str()), (Some("session/load"), Some("old")));
        // The replay is the conversation Nook already shows.
        let s = d.receive(r#"{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"old answer"}}}}"#);
        assert!(s.events.is_empty());
        let s = d.receive(r#"{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Authentication required"}}"#);
        assert_eq!(sent(&s.replies[0])["method"], "authenticate");
        let s = d.receive(r#"{"jsonrpc":"2.0","id":3,"result":{}}"#);
        assert_eq!(sent(&s.replies[0])["method"], "session/load");
        let s = d.receive(r#"{"jsonrpc":"2.0","id":4,"error":{"code":-32002,"message":"Session not found"}}"#);
        assert!(matches!(&s.events[0], DriverEvent::System(_)));
        assert_eq!(sent(&s.replies[0])["method"], "session/new");
        // Without load or resume the conversation starts anew, said once.
        let mut d = AcpDriver::new(&input(RunProvider::Opencode, PermissionPolicy::Ask, Some("old")));
        d.initialize();
        let s = d.receive(r#"{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{}}}"#);
        assert!(matches!(&s.events[0], DriverEvent::System(_)));
        assert_eq!(sent(&s.replies[0])["method"], "session/new");
    }

    #[test]
    fn plan_mode_model_and_cancel() {
        let mut i = input(RunProvider::Opencode, PermissionPolicy::Ask, None);
        i.mode = ExecutionMode::Plan;
        i.model = "anthropic/sonnet".into();
        let mut d = AcpDriver::new(&i);
        d.initialize();
        d.receive(r#"{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{}}}"#);
        let s = d.receive(r#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s","configOptions":[{"id":"m","category":"model","currentValue":"x","options":[]},{"id":"mode","category":"mode","currentValue":"build","options":[{"value":"build"},{"value":"plan"}]}]}}"#);
        let first = sent(&s.replies[0]);
        assert_eq!((first["method"].as_str(), first["params"]["value"].as_str()), (Some("session/set_config_option"), Some("anthropic/sonnet")));
        let s = d.receive(r#"{"jsonrpc":"2.0","id":3,"result":{}}"#);
        assert_eq!(sent(&s.replies[0])["params"]["value"], "plan");
        let s = d.receive(r#"{"jsonrpc":"2.0","id":4,"error":{"code":1,"message":"nope"}}"#);
        let prompt = sent(&s.replies[0]);
        assert!(prompt["params"]["prompt"][0]["text"].as_str().unwrap().starts_with(driver::PLAN_ONLY));
        d.receive(r#"{"jsonrpc":"2.0","id":11,"method":"session/request_permission","params":{"toolCall":{"toolCallId":"c","kind":"execute"},"options":[]}}"#);
        let lines = d.interrupt();
        assert_eq!(sent(&lines[0])["result"]["outcome"]["outcome"], "cancelled");
        assert_eq!(sent(&lines[1])["method"], "session/cancel");
        let s = d.receive(r#"{"jsonrpc":"2.0","id":5,"result":{"stopReason":"cancelled"}}"#);
        assert!(matches!(claude(&s).last(), Some(ClaudeEvent::Result(r)) if !r.is_error && r.subtype == "cancelled"));
    }
}
