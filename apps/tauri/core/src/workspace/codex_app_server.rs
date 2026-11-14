//! Codex through `codex app-server` (`CodexAppServer.swift` on the Mac): newline-delimited JSON-RPC over stdin/stdout.
//! Compared with `codex exec --json` this gives approvals for commands and file changes in Nook's approval card, Codex's
//! questions, steering a running turn, live text and reasoning, and the context window. One process per turn: the
//! conversation goes on with `thread/resume`, so a session continues after a restart of Nook just the same.

use std::collections::HashMap;

use serde_json::{json, Value};

use super::bridge::SERVER_NAME;
use super::command::{CommandInput, LaunchSpec};
use super::driver::{self, Driver, DriverEvent, Message, RpcId, Step, Wire};
use super::models::{ExecutionMode, PermissionPolicy, TurnUsage};
use super::parsers::{number, ClaudeEvent, ClaudeTurnResult, TokenCounts};
use crate::i18n::tr;

const WIRE: Wire = Wire { jsonrpc: false };

/// The process and its driver for one turn.
pub fn launch(input: &CommandInput) -> (LaunchSpec, CodexDriver) {
    let mut environment = input.account_environment.clone();
    environment.insert("NOOK_RUN_ID".into(), input.run_id.clone());
    let mut driver = CodexDriver::new(input);
    let first = driver.initialize();
    let spec = LaunchSpec {
        executable: input.executable.clone(),
        arguments: vec!["app-server".into()],
        extra_environment: environment,
        working_directory: input.working_directory.clone(),
        initial_input: vec![first],
        keeps_input_open: true,
    };
    (spec, driver)
}

/// The approval policy and sandbox for a turn.
pub fn policy(mode: ExecutionMode, permission: PermissionPolicy) -> (&'static str, Value) {
    if mode == ExecutionMode::Plan {
        return ("untrusted", json!({"type": "readOnly"}));
    }
    match permission {
        PermissionPolicy::Ask => ("untrusted", json!({"type": "readOnly"})),
        PermissionPolicy::AcceptEdits => ("on-request", json!({"type": "workspaceWrite"})),
        PermissionPolicy::Bypass => ("never", json!({"type": "dangerFullAccess"})),
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Call {
    Initialize,
    Thread { resuming: bool },
    Turn,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum ApprovalKind {
    Command,
    FileChange,
    LegacyCommand,
    LegacyPatch,
    McpTool,
}

struct Question {
    rpc: RpcId,
    /// Question text → Codex's id for it.
    ids: Vec<(String, String)>,
}

pub struct CodexDriver {
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
    mcp_servers: Option<Value>,
    thread: Option<String>,
    turn: Option<String>,
    approvals: HashMap<String, (RpcId, ApprovalKind)>,
    questions: HashMap<String, Question>,
    /// Reasoning items that already streamed (the first delta starts a new block).
    reasoning: Vec<String>,
    usage_seen: u64,
    context_window: Option<u64>,
    last_error: Option<String>,
    finished: bool,
}

impl CodexDriver {
    pub fn new(input: &CommandInput) -> Self {
        let mcp_servers = input.bridge.as_ref().map(|b| {
            json!({SERVER_NAME: {"command": b.script, "args": ["--agent", "codex"], "env": {"NOOK_RUN_ID": input.run_id}, "tool_timeout_sec": 900}})
        });
        Self {
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
            mcp_servers,
            thread: None,
            turn: None,
            approvals: HashMap::new(),
            questions: HashMap::new(),
            reasoning: vec![],
            usage_seen: 0,
            context_window: None,
            last_error: None,
            finished: false,
        }
    }

    fn request(&mut self, call: Call, method: &str, params: Value) -> String {
        let id = driver::next_id(&mut self.next);
        self.calls.insert(id, call);
        WIRE.request(id, method, params)
    }

    fn initialize(&mut self) -> String {
        self.request(
            Call::Initialize,
            "initialize",
            json!({
                "clientInfo": {"name": "nook", "title": "Nook", "version": env!("CARGO_PKG_VERSION")},
                // Nook reads changes from git, not from the per-turn diff stream.
                "capabilities": {"experimentalApi": true, "optOutNotificationMethods": ["turn/diff/updated"]}
            }),
        )
    }

    fn open_thread(&mut self, resume: Option<String>) -> String {
        let mut config = json!({"tools.update_plan.enabled": true, "mcp_optional_startup_grace_ms": 10_000});
        if let Some(servers) = &self.mcp_servers {
            config["mcp_servers"] = servers.clone();
        }
        let mut params = json!({"cwd": self.cwd, "config": config});
        if !self.model.is_empty() {
            params["model"] = json!(self.model);
        }
        if !self.instructions.is_empty() {
            params["developerInstructions"] = json!(self.instructions);
        }
        let resuming = resume.is_some();
        let method = if let Some(thread) = resume {
            params["threadId"] = json!(thread);
            params["excludeTurns"] = json!(true);
            "thread/resume"
        } else {
            "thread/start"
        };
        self.request(Call::Thread { resuming }, method, params)
    }

    fn start_turn(&mut self) -> String {
        let (approval, sandbox) = policy(self.mode, self.permission);
        let text = if self.mode == ExecutionMode::Plan { format!("{}\n\n{}", driver::PLAN_ONLY, self.prompt) } else { self.prompt.clone() };
        let mut params = json!({
            "threadId": self.thread.clone().unwrap_or_default(),
            "input": [{"type": "text", "text": text}],
            "cwd": self.cwd,
            // Some model catalogues default summaries to none; ask every turn so the timeline shows the reasoning.
            "summary": "detailed",
            "approvalPolicy": approval,
            "sandboxPolicy": sandbox,
        });
        if !self.model.is_empty() {
            params["model"] = json!(self.model);
        }
        if let Some(effort) = &self.effort {
            params["effort"] = json!(effort);
        }
        self.request(Call::Turn, "turn/start", params)
    }

    fn finish(&mut self, step: &mut Step, failed: bool, subtype: &str, text: String, duration: Option<f64>) {
        if self.finished {
            return;
        }
        self.finished = true;
        let usage = TurnUsage { context_window: self.context_window, duration_seconds: duration, ..Default::default() };
        step.event(ClaudeEvent::Result(ClaudeTurnResult {
            is_error: failed,
            subtype: subtype.into(),
            text,
            session_id: self.thread.clone(),
            usage,
            ..Default::default()
        }));
    }

    fn response(&mut self, step: &mut Step, call: Call, result: Value, error: Option<String>) {
        match (call, error) {
            (Call::Initialize, None) => {
                step.replies.push(WIRE.notification("initialized", json!({})));
                let resume = self.resume.clone();
                let line = self.open_thread(resume);
                step.replies.push(line);
            }
            (Call::Thread { resuming: true }, Some(e)) if driver::session_gone(&e) => {
                step.events.push(DriverEvent::System(driver::no_load_note(super::models::RunProvider::Codex)));
                let line = self.open_thread(None);
                step.replies.push(line);
            }
            (Call::Thread { .. }, None) => {
                let thread = result.pointer("/thread/id").and_then(Value::as_str).map(str::to_string);
                let Some(thread) = thread.or_else(|| self.resume.clone()) else {
                    return self.finish(step, true, "error", tr("Codex startte geen gesprek.", "Codex started no thread.").into(), None);
                };
                self.thread = Some(thread.clone());
                let model = result.get("model").and_then(Value::as_str).map(str::to_string);
                step.event(ClaudeEvent::Initialized { session_id: thread, model });
                let line = self.start_turn();
                step.replies.push(line);
            }
            (Call::Turn, None) => {
                if let Some(turn) = result.pointer("/turn/id").and_then(Value::as_str) {
                    self.turn = Some(turn.into());
                }
            }
            (Call::Initialize | Call::Thread { .. } | Call::Turn, Some(e)) => self.finish(step, true, "error", e, None),
            (Call::Other, _) => {}
        }
    }

    fn notification(&mut self, step: &mut Step, method: &str, p: &Value) {
        let text = |k: &str| p.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        match method {
            "thread/started" => {
                if let Some(id) = p.pointer("/thread/id").and_then(Value::as_str) {
                    self.thread = Some(id.into());
                }
            }
            "turn/started" => {
                if let Some(id) = p.pointer("/turn/id").and_then(Value::as_str) {
                    self.turn = Some(id.into());
                }
            }
            "item/agentMessage/delta" => {
                let delta = text("delta");
                if !delta.is_empty() {
                    step.event(ClaudeEvent::TextDelta(delta));
                }
            }
            "item/reasoning/summaryTextDelta" | "item/reasoning/textDelta" => {
                let delta = text("delta");
                if delta.is_empty() {
                    return;
                }
                let item = text("itemId");
                let starts = !self.reasoning.contains(&item);
                if starts {
                    self.reasoning.push(item);
                }
                step.event(ClaudeEvent::ThinkingDelta { text: delta, starts });
            }
            "item/started" => self.item(step, p.get("item").unwrap_or(&Value::Null), false),
            "item/completed" => self.item(step, p.get("item").unwrap_or(&Value::Null), true),
            "thread/tokenUsage/updated" => {
                let Some(usage) = p.get("tokenUsage") else { return };
                if let Some(w) = number(usage.get("modelContextWindow")) {
                    self.context_window = Some(w as u64);
                }
                self.usage_seen += 1;
                step.event(ClaudeEvent::Usage { message_id: format!("codex-{}", self.usage_seen), tokens: counts(usage.get("last")), model: None });
            }
            "turn/completed" => {
                let turn = p.get("turn").cloned().unwrap_or(Value::Null);
                let status = turn.get("status").and_then(Value::as_str).unwrap_or("completed").to_string();
                let error = turn.pointer("/error/message").and_then(Value::as_str).map(str::to_string);
                let failed = status == "failed";
                let duration = number(turn.get("durationMs")).map(|ms| ms / 1000.0);
                let message = error.or_else(|| self.last_error.clone()).filter(|_| failed).unwrap_or_default();
                self.turn = None;
                self.finish(step, failed, &status, message, duration);
            }
            "error" => {
                let message = p.pointer("/error/message").and_then(Value::as_str).unwrap_or("Codex reported an error.").to_string();
                if p.get("willRetry").and_then(Value::as_bool) != Some(true) {
                    self.last_error = Some(message);
                }
            }
            "thread/compacted" => step.event(ClaudeEvent::Notice("compact".into())),
            _ => {}
        }
    }

    fn item(&mut self, step: &mut Step, item: &Value, finished: bool) {
        let (Some(id), Some(kind)) = (item.get("id").and_then(Value::as_str), item.get("type").and_then(Value::as_str)) else { return };
        let id = id.to_string();
        let status = item.get("status").and_then(Value::as_str).unwrap_or(if finished { "completed" } else { "inProgress" });
        let failed = matches!(status, "failed" | "declined");
        match kind {
            "agentMessage" if finished => {
                if let Some(t) = item.get("text").and_then(Value::as_str).filter(|t| !t.is_empty()) {
                    step.event(ClaudeEvent::Text(t.into()));
                }
            }
            "reasoning" if finished => {
                let parts = |k: &str| -> Vec<String> {
                    item.get(k).and_then(Value::as_array).map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect()).unwrap_or_default()
                };
                let summary = parts("summary");
                let text = if summary.is_empty() { parts("content") } else { summary }.join("\n\n").trim().to_string();
                step.event(ClaudeEvent::Thinking(text));
            }
            "commandExecution" => {
                let command = item.get("command").and_then(Value::as_str).unwrap_or("").to_string();
                if !finished {
                    step.event(ClaudeEvent::ToolUse { id, name: "shell".into(), input: json!({"command": command}), nested: false });
                } else {
                    let exit = number(item.get("exitCode")).unwrap_or(if failed { 1.0 } else { 0.0 });
                    let output = item.get("aggregatedOutput").and_then(Value::as_str).unwrap_or("").to_string();
                    step.event(ClaudeEvent::ToolResult { id, output, is_error: exit != 0.0 || failed });
                }
            }
            "fileChange" => {
                let changes: Vec<(String, String)> = item
                    .get("changes")
                    .and_then(Value::as_array)
                    .map(|a| {
                        a.iter()
                            .filter_map(|c| {
                                let path = c.get("path")?.as_str()?.to_string();
                                let kind = match c.pointer("/kind/type").and_then(Value::as_str).unwrap_or("update") {
                                    "add" => "written",
                                    "delete" => "deleted",
                                    _ => "modified",
                                };
                                Some((path, kind.to_string()))
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                let names: Vec<&str> = changes.iter().map(|(p, _)| p.rsplit(['/', '\\']).next().unwrap_or(p)).collect();
                if !finished {
                    step.event(ClaudeEvent::ToolUse { id, name: "apply_patch".into(), input: json!({"description": names.join(", ")}), nested: false });
                } else {
                    step.event(ClaudeEvent::ToolResult { id, output: String::new(), is_error: failed });
                    if !failed {
                        for (path, kind) in changes {
                            step.events.push(DriverEvent::FileChange { path, kind });
                        }
                    }
                }
            }
            "mcpToolCall" | "dynamicToolCall" => {
                let tool = item.get("tool").and_then(Value::as_str).unwrap_or("tool");
                let name = match item.get("server").and_then(Value::as_str) {
                    Some(server) => format!("mcp__{server}__{tool}"),
                    None => tool.to_string(),
                };
                if !finished {
                    let input = item.get("arguments").cloned().filter(Value::is_object).unwrap_or_else(|| json!({}));
                    step.event(ClaudeEvent::ToolUse { id, name, input, nested: false });
                } else if status != "inProgress" {
                    let failed = failed || item.get("success").and_then(Value::as_bool) == Some(false);
                    let output = item
                        .pointer("/error/message")
                        .and_then(Value::as_str)
                        .map(str::to_string)
                        .unwrap_or_else(|| super::parsers::result_text(item.pointer("/result/content")));
                    step.event(ClaudeEvent::ToolResult { id, output, is_error: failed });
                }
            }
            "webSearch" => {
                if !finished {
                    let query = item.get("query").and_then(Value::as_str).unwrap_or("");
                    step.event(ClaudeEvent::ToolUse { id, name: "web_search".into(), input: json!({"query": query}), nested: false });
                } else {
                    step.event(ClaudeEvent::ToolResult { id, output: String::new(), is_error: false });
                }
            }
            "contextCompaction" if finished => step.event(ClaudeEvent::Notice("compact".into())),
            _ => {}
        }
    }

    fn server_request(&mut self, step: &mut Step, id: RpcId, method: &str, p: &Value) {
        let text = |k: &str| p.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        let key = format!("codex-{}", id.text());
        let (kind, tool, input) = match method {
            "item/commandExecution/requestApproval" => {
                (ApprovalKind::Command, "shell".to_string(), json!({"command": text("command"), "cwd": text("cwd"), "reason": text("reason")}))
            }
            "execCommandApproval" => {
                let command = super::models::tool_summary::command(&json!({"command": p.get("command")})).unwrap_or_default();
                (ApprovalKind::LegacyCommand, "shell".to_string(), json!({"command": command, "cwd": text("cwd"), "reason": text("reason")}))
            }
            "item/fileChange/requestApproval" | "applyPatchApproval" => {
                let kind = if method == "applyPatchApproval" { ApprovalKind::LegacyPatch } else { ApprovalKind::FileChange };
                let reason = text("reason");
                let description = if reason.is_empty() { tr("Bestandswijzigingen toepassen", "Apply file changes").to_string() } else { reason };
                (kind, "apply_patch".to_string(), json!({"description": description, "path": text("grantRoot")}))
            }
            "mcpServer/elicitation/request" => {
                let fields = p.pointer("/requestedSchema/properties").and_then(Value::as_object).is_some_and(|f| !f.is_empty());
                let form = p.get("mode").and_then(Value::as_str).is_some_and(|m| ["form", "openai/form", "openaiForm"].contains(&m));
                if fields || !form {
                    // A form to fill in (or a page to open) is not something Allow or Deny answers: declined, so nothing waits.
                    step.replies.push(WIRE.response(&id, json!({"action": "decline"})));
                    return;
                }
                let server = text("serverName");
                let tool = p.pointer("/_meta/tool_name").and_then(Value::as_str).unwrap_or("confirm");
                (ApprovalKind::McpTool, format!("mcp__{server}__{tool}"), json!({"description": text("message")}))
            }
            "item/tool/requestUserInput" => {
                let mut ids = vec![];
                let questions: Vec<Value> = p
                    .get("questions")
                    .and_then(Value::as_array)
                    .map(|a| {
                        a.iter()
                            .filter_map(|q| {
                                let qid = q.get("id")?.as_str()?;
                                let question = q.get("question")?.as_str()?;
                                ids.push((question.to_string(), qid.to_string()));
                                Some(json!({
                                    "question": question,
                                    "header": q.get("header").and_then(Value::as_str).unwrap_or(""),
                                    "options": q.get("options").cloned().unwrap_or_else(|| json!([])),
                                    "multiSelect": false,
                                }))
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                if questions.is_empty() {
                    step.replies.push(WIRE.error(&id, -32602, "No questions."));
                    return;
                }
                self.questions.insert(key.clone(), Question { rpc: id, ids });
                step.event(ClaudeEvent::PermissionRequest {
                    request_id: key,
                    tool: "AskUserQuestion".into(),
                    input: json!({"questions": questions}),
                    suggestions: None,
                    tool_use_id: None,
                });
                return;
            }
            _ => {
                step.replies.push(WIRE.error(&id, -32601, "Nook does not handle this request."));
                return;
            }
        };
        self.approvals.insert(key.clone(), (id, kind));
        // Codex remembers an approval for the rest of the session: that is the "Always" Nook offers.
        let always = kind != ApprovalKind::McpTool || p.pointer("/_meta/persist").is_some();
        step.event(ClaudeEvent::PermissionRequest {
            request_id: key,
            tool,
            input,
            suggestions: always.then(|| json!([{"type": "session"}])),
            tool_use_id: None,
        });
    }
}

/// Codex counts cached input inside `inputTokens`; Nook keeps them apart, as for the other agents.
pub fn counts(raw: Option<&Value>) -> TokenCounts {
    let raw = raw.cloned().unwrap_or(Value::Null);
    let n = |k: &str| number(raw.get(k)).unwrap_or(0.0).max(0.0) as u64;
    let cached = n("cachedInputTokens");
    TokenCounts { input: n("inputTokens").saturating_sub(cached), output: n("outputTokens"), cache_read: cached, cache_write: n("cacheWriteInputTokens") }
}

impl Driver for CodexDriver {
    fn receive(&mut self, line: &str) -> Step {
        let mut step = Step::default();
        match driver::parse(line) {
            Some(Message::Response { id, result, error }) => {
                let call = self.calls.remove(&id).unwrap_or(Call::Other);
                self.response(&mut step, call, result, error);
            }
            Some(Message::Notification { method, params }) => self.notification(&mut step, &method, &params),
            Some(Message::Request { id, method, params }) => self.server_request(&mut step, id, &method, &params),
            None => {}
        }
        step
    }

    fn decide(&mut self, request_id: &str, allow: bool, always: bool) -> Vec<String> {
        let Some((id, kind)) = self.approvals.remove(request_id) else { return vec![] };
        let answer = match kind {
            ApprovalKind::Command | ApprovalKind::FileChange => {
                json!({"decision": if !allow { "decline" } else if always { "acceptForSession" } else { "accept" }})
            }
            ApprovalKind::LegacyCommand | ApprovalKind::LegacyPatch => {
                json!({"decision": if !allow { "denied" } else if always { "approved_for_session" } else { "approved" }})
            }
            ApprovalKind::McpTool if !allow => json!({"action": "decline"}),
            ApprovalKind::McpTool => {
                let mut a = json!({"action": "accept", "content": {}});
                if always {
                    a["_meta"] = json!({"persist": "session"});
                }
                a
            }
        };
        vec![WIRE.response(&id, answer)]
    }

    fn answer(&mut self, request_id: &str, answers: &[(String, Vec<String>)]) -> Option<Vec<String>> {
        let q = self.questions.remove(request_id)?;
        let mut filled = serde_json::Map::new();
        for (question, chosen) in answers {
            if let Some((_, qid)) = q.ids.iter().find(|(text, _)| text == question) {
                filled.insert(qid.clone(), json!({"answers": chosen}));
            }
        }
        Some(vec![WIRE.response(&q.rpc, json!({"answers": filled}))])
    }

    fn steer(&mut self, text: &str) -> Option<Vec<String>> {
        let (thread, turn) = (self.thread.clone()?, self.turn.clone()?);
        if self.finished {
            return None;
        }
        Some(vec![self.request(
            Call::Other,
            "turn/steer",
            json!({"threadId": thread, "expectedTurnId": turn, "input": [{"type": "text", "text": text}]}),
        )])
    }

    fn interrupt(&mut self) -> Vec<String> {
        let mut lines: Vec<String> = self.approvals.drain().map(|(_, (id, kind))| {
            let answer = match kind {
                ApprovalKind::McpTool => json!({"action": "cancel"}),
                ApprovalKind::LegacyCommand | ApprovalKind::LegacyPatch => json!({"decision": "abort"}),
                ApprovalKind::Command | ApprovalKind::FileChange => json!({"decision": "cancel"}),
            };
            WIRE.response(&id, answer)
        }).collect();
        if let (Some(thread), Some(turn)) = (self.thread.clone(), self.turn.clone()) {
            lines.push(self.request(Call::Other, "turn/interrupt", json!({"threadId": thread, "turnId": turn})));
        }
        lines
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace::models::RunProvider;
    use std::collections::BTreeMap;

    fn input(resume: Option<&str>) -> CommandInput {
        CommandInput {
            provider: RunProvider::Codex,
            executable: "/usr/bin/codex".into(),
            prompt: "Fix the test".into(),
            model: "gpt-5-codex".into(),
            mode: ExecutionMode::Agent,
            permission: PermissionPolicy::AcceptEdits,
            instructions: "Use tabs".into(),
            working_directory: "/w".into(),
            resume_session_id: resume.map(str::to_string),
            fork_session: false,
            account_environment: BTreeMap::new(),
            run_id: "run-1".into(),
            profile_id: "default".into(),
            bridge: None,
            effort: Some("high".into()),
        }
    }

    fn sent(line: &str) -> Value {
        serde_json::from_str(line.trim()).unwrap()
    }

    fn claude(step: &Step) -> Vec<ClaudeEvent> {
        step.events.iter().filter_map(|e| if let DriverEvent::Claude(c) = e { Some(c.clone()) } else { None }).collect()
    }

    #[test]
    fn handshake_turn_and_approvals() {
        let (spec, mut d) = launch(&input(Some("th-1")));
        assert_eq!(spec.arguments, vec!["app-server"]);
        assert!(spec.keeps_input_open);
        assert_eq!(sent(&spec.initial_input[0])["method"], "initialize");
        let s = d.receive(r#"{"id":1,"result":{}}"#);
        assert_eq!(sent(&s.replies[0])["method"], "initialized");
        let resume = sent(&s.replies[1]);
        assert_eq!(resume["method"], "thread/resume");
        assert_eq!(resume["params"]["threadId"], "th-1");
        assert_eq!(resume["params"]["developerInstructions"], "Use tabs");
        let s = d.receive(r#"{"id":2,"result":{"thread":{"id":"th-1"},"model":"gpt-5-codex"}}"#);
        assert_eq!(claude(&s)[0], ClaudeEvent::Initialized { session_id: "th-1".into(), model: Some("gpt-5-codex".into()) });
        let turn = sent(&s.replies[0]);
        assert_eq!(turn["method"], "turn/start");
        assert_eq!(turn["params"]["approvalPolicy"], "on-request");
        assert_eq!(turn["params"]["sandboxPolicy"]["type"], "workspaceWrite");
        assert_eq!(turn["params"]["effort"], "high");
        d.receive(r#"{"method":"turn/started","params":{"turn":{"id":"t-1"}}}"#);
        let steer = d.steer("also docs").unwrap();
        assert_eq!(sent(&steer[0])["params"]["expectedTurnId"], "t-1");
        let s = d.receive(r#"{"id":"r9","method":"item/commandExecution/requestApproval","params":{"itemId":"c1","command":"rm -rf build","cwd":"/w"}}"#);
        match &claude(&s)[0] {
            ClaudeEvent::PermissionRequest { request_id, tool, input, suggestions, .. } => {
                assert_eq!((request_id.as_str(), tool.as_str()), ("codex-r9", "shell"));
                assert_eq!(input["command"], "rm -rf build");
                assert!(suggestions.is_some());
            }
            other => panic!("{other:?}"),
        }
        let answer = sent(&d.decide("codex-r9", true, true)[0]);
        assert_eq!((answer["id"].clone(), answer["result"]["decision"].clone()), (json!("r9"), json!("acceptForSession")));
        assert!(d.decide("codex-r9", true, false).is_empty(), "answered once");
        let s = d.receive(r#"{"method":"item/completed","params":{"item":{"id":"f1","type":"fileChange","status":"completed","changes":[{"path":"/w/a.rs","kind":{"type":"update"}},{"path":"/w/b.rs","kind":{"type":"add"}}]}}}"#);
        assert!(s.events.contains(&DriverEvent::FileChange { path: "/w/b.rs".into(), kind: "written".into() }));
        d.receive(r#"{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"last":{"inputTokens":100,"cachedInputTokens":40,"outputTokens":7},"modelContextWindow":272000}}}"#);
        let s = d.receive(r#"{"method":"turn/completed","params":{"turn":{"id":"t-1","status":"completed","durationMs":1500}}}"#);
        match &claude(&s)[0] {
            ClaudeEvent::Result(r) => {
                assert!(!r.is_error);
                assert_eq!(r.session_id.as_deref(), Some("th-1"));
                assert_eq!(r.usage.context_window, Some(272_000));
                assert_eq!(r.usage.duration_seconds, Some(1.5));
            }
            other => panic!("{other:?}"),
        }
        assert_eq!(counts(Some(&json!({"inputTokens": 100, "cachedInputTokens": 40}))).input, 60);
    }

    #[test]
    fn gone_thread_starts_anew_and_questions() {
        let (_, mut d) = launch(&input(Some("old")));
        d.receive(r#"{"id":1,"result":{}}"#);
        let s = d.receive(r#"{"id":2,"error":{"code":-32600,"message":"no rollout found for thread id old"}}"#);
        assert!(matches!(&s.events[0], DriverEvent::System(_)));
        assert_eq!(sent(&s.replies[0])["method"], "thread/start");
        let s = d.receive(r#"{"id":5,"method":"item/tool/requestUserInput","params":{"questions":[{"id":"q1","question":"Which?","options":[{"label":"A","description":""}]}]}}"#);
        assert!(matches!(&claude(&s)[0], ClaudeEvent::PermissionRequest { tool, .. } if tool == "AskUserQuestion"));
        let reply = sent(&d.answer("codex-5", &[("Which?".into(), vec!["A".into()])]).unwrap()[0]);
        assert_eq!(reply["result"]["answers"]["q1"]["answers"][0], "A");
        let (approval, sandbox) = policy(ExecutionMode::Plan, PermissionPolicy::Bypass);
        assert_eq!((approval, sandbox["type"].as_str()), ("untrusted", Some("readOnly")));
        assert_eq!(policy(ExecutionMode::Agent, PermissionPolicy::Bypass).0, "never");
    }
}
