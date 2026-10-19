//! Wat Nook uit de uitvoer van een agent haalt (`AgentStreamParsers` op de Mac): Claude Code (`stream-json`),
//! Codex (`exec --json`) en Gemini CLI (`stream-json`), en de berichten die Nook terugstuurt naar Claude Code.

use serde_json::{json, Value};

use super::models::TurnUsage;

/// Tokens van één modelaanroep.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TokenCounts {
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
}

impl TokenCounts {
    /// De tokens in de context bij deze aanroep.
    pub fn context(&self) -> u64 {
        self.input + self.cache_read + self.cache_write
    }
}

/// Een getal uit JSON (geen booleans), ook als het als tekst kwam.
pub fn number(v: Option<&Value>) -> Option<f64> {
    match v? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.parse().ok(),
        _ => None,
    }
}

fn s<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str)
}

// MARK: Claude Code

#[derive(Debug, Clone, PartialEq)]
pub enum ClaudeEvent {
    Initialized {
        session_id: String,
        model: Option<String>,
    },
    /// Een stukje tekst terwijl het antwoord binnenkomt (`--include-partial-messages`).
    TextDelta(String),
    /// Een volledig tekstblok.
    Text(String),
    /// Een volledig denkblok (leeg als het model het voor zich hield).
    Thinking(String),
    /// Denken terwijl het binnenkomt: een nieuw blok begint, of meer tekst voor het huidige.
    ThinkingDelta {
        text: String,
        starts: bool,
    },
    BlockStopped,
    ToolUse {
        id: String,
        name: String,
        input: Value,
        nested: bool,
    },
    ToolResult {
        id: String,
        output: String,
        is_error: bool,
    },
    Usage {
        message_id: String,
        tokens: TokenCounts,
        model: Option<String>,
    },
    /// De agent vraagt toestemming (`--permission-prompt-tool stdio`).
    PermissionRequest {
        request_id: String,
        tool: String,
        input: Value,
        suggestions: Option<Value>,
        tool_use_id: Option<String>,
    },
    Result(ClaudeTurnResult),
    Notice(String),
    /// Een limiet van het abonnement veranderde (`rate_limit_event`).
    RateLimits(Value),
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct ClaudeTurnResult {
    pub is_error: bool,
    pub subtype: String,
    pub text: String,
    pub session_id: Option<String>,
    pub usage: TurnUsage,
    pub permission_denials: usize,
    pub terminal_reason: Option<String>,
    pub api_error_status: Option<i64>,
}

impl ClaudeTurnResult {
    /// Het einde van een stuk beurt dat een bijsturend bericht afkapte: de beurt gaat door.
    pub fn ended_by_steer(&self) -> bool {
        matches!(self.terminal_reason.as_deref(), Some("aborted_streaming") | Some("aborted_tools"))
    }
}

pub fn tokens(usage: &Value) -> TokenCounts {
    let n = |k: &str| number(usage.get(k)).unwrap_or(0.0).max(0.0) as u64;
    TokenCounts {
        input: n("input_tokens"),
        output: n("output_tokens"),
        cache_read: n("cache_read_input_tokens"),
        cache_write: n("cache_creation_input_tokens"),
    }
}

/// Uitvoer van een tool: tekst, of de tekst uit een lijst blokken.
pub fn result_text(content: Option<&Value>) -> String {
    match content {
        Some(Value::String(t)) => t.clone(),
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter_map(|b| {
                if let Some(t) = s(b, "text") {
                    Some(t.to_string())
                } else if s(b, "type") == Some("image") {
                    Some("[afbeelding]".into())
                } else {
                    None
                }
            })
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

pub fn parse_claude(line: &str) -> Vec<ClaudeEvent> {
    let Ok(object) = serde_json::from_str::<Value>(line) else { return vec![] };
    let Some(kind) = s(&object, "type") else { return vec![] };
    let nested = object.get("parent_tool_use_id").is_some_and(|v| !v.is_null());
    match kind {
        "system" => match s(&object, "subtype").unwrap_or("") {
            "init" => s(&object, "session_id")
                .map(|id| vec![ClaudeEvent::Initialized { session_id: id.into(), model: s(&object, "model").map(str::to_string) }])
                .unwrap_or_default(),
            "compact_boundary" => vec![ClaudeEvent::Notice("compact".into())],
            _ => vec![],
        },
        "stream_event" => {
            let Some(event) = object.get("event").filter(|_| !nested) else { return vec![] };
            match s(event, "type") {
                Some("content_block_start") => {
                    let Some(block) = event.get("content_block").filter(|b| s(b, "type") == Some("thinking")) else { return vec![] };
                    vec![ClaudeEvent::ThinkingDelta { text: s(block, "thinking").unwrap_or("").into(), starts: true }]
                }
                Some("content_block_delta") => {
                    let Some(delta) = event.get("delta") else { return vec![] };
                    match s(delta, "type") {
                        Some("text_delta") => {
                            s(delta, "text").filter(|t| !t.is_empty()).map(|t| vec![ClaudeEvent::TextDelta(t.into())]).unwrap_or_default()
                        }
                        Some("thinking_delta") => s(delta, "thinking")
                            .filter(|t| !t.is_empty())
                            .map(|t| vec![ClaudeEvent::ThinkingDelta { text: t.into(), starts: false }])
                            .unwrap_or_default(),
                        _ => vec![],
                    }
                }
                Some("content_block_stop") => vec![ClaudeEvent::BlockStopped],
                _ => vec![],
            }
        }
        "assistant" => {
            let Some(message) = object.get("message") else { return vec![] };
            let mut events = vec![];
            for block in message.get("content").and_then(Value::as_array).into_iter().flatten() {
                match s(block, "type") {
                    Some("text") if !nested => {
                        if let Some(t) = s(block, "text").filter(|t| !t.trim().is_empty()) {
                            events.push(ClaudeEvent::Text(t.into()));
                        }
                    }
                    Some("thinking") if !nested => events.push(ClaudeEvent::Thinking(s(block, "thinking").unwrap_or("").into())),
                    Some("tool_use") => {
                        if let (Some(id), Some(name)) = (s(block, "id"), s(block, "name")) {
                            events.push(ClaudeEvent::ToolUse {
                                id: id.into(),
                                name: name.into(),
                                input: block.get("input").cloned().unwrap_or(json!({})),
                                nested,
                            });
                        }
                    }
                    _ => {}
                }
            }
            if !nested {
                if let (Some(id), Some(usage)) = (s(message, "id"), message.get("usage")) {
                    events.push(ClaudeEvent::Usage {
                        message_id: id.into(),
                        tokens: tokens(usage),
                        model: s(message, "model").map(str::to_string),
                    });
                }
            }
            events
        }
        "user" => object
            .pointer("/message/content")
            .and_then(Value::as_array)
            .map(|content| {
                content
                    .iter()
                    .filter(|b| s(b, "type") == Some("tool_result"))
                    .filter_map(|b| {
                        Some(ClaudeEvent::ToolResult {
                            id: s(b, "tool_use_id")?.into(),
                            output: result_text(b.get("content")),
                            is_error: b.get("is_error").and_then(Value::as_bool).unwrap_or(false),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default(),
        "control_request" => {
            let (Some(request_id), Some(request)) = (s(&object, "request_id"), object.get("request")) else { return vec![] };
            if s(request, "subtype") != Some("can_use_tool") {
                return vec![];
            }
            let Some(tool) = s(request, "tool_name") else { return vec![] };
            vec![ClaudeEvent::PermissionRequest {
                request_id: request_id.into(),
                tool: tool.into(),
                input: request.get("input").cloned().unwrap_or(json!({})),
                suggestions: request.get("permission_suggestions").filter(|v| !v.is_null()).cloned(),
                tool_use_id: s(request, "tool_use_id").map(str::to_string),
            }]
        }
        "rate_limit_event" => vec![ClaudeEvent::RateLimits(object.get("rate_limit_info").cloned().unwrap_or(Value::Null))],
        "result" => {
            let mut usage = TurnUsage::default();
            if let Some(raw) = object.get("usage") {
                let t = tokens(raw);
                usage.input_tokens = Some(t.input);
                usage.output_tokens = Some(t.output);
                usage.cache_read_tokens = Some(t.cache_read);
                usage.cache_write_tokens = Some(t.cache_write);
            }
            usage.reported_cost_usd = number(object.get("total_cost_usd"));
            if let Some(models) = object.get("modelUsage").and_then(Value::as_object) {
                let window = models.values().filter_map(|m| number(m.get("contextWindow"))).fold(0.0, f64::max);
                if window > 0.0 {
                    usage.context_window = Some(window as u64);
                }
            }
            usage.duration_seconds = number(object.get("duration_ms")).map(|ms| ms / 1000.0);
            let subtype = s(&object, "subtype").unwrap_or("").to_string();
            let text = s(&object, "result").map(str::to_string).unwrap_or_else(|| {
                object
                    .get("errors")
                    .and_then(Value::as_array)
                    .map(|e| e.iter().filter_map(Value::as_str).collect::<Vec<_>>().join("\n"))
                    .unwrap_or_default()
            });
            vec![ClaudeEvent::Result(ClaudeTurnResult {
                is_error: object.get("is_error").and_then(Value::as_bool).unwrap_or(subtype != "success"),
                subtype,
                text,
                session_id: s(&object, "session_id").map(str::to_string),
                usage,
                permission_denials: object.get("permission_denials").and_then(Value::as_array).map(Vec::len).unwrap_or(0),
                terminal_reason: s(&object, "terminal_reason").map(str::to_string),
                api_error_status: number(object.get("api_error_status")).map(|n| n as i64),
            })]
        }
        _ => vec![],
    }
}

/// Een bericht van de gebruiker in `--input-format stream-json`. Met `steer` krijgt het `priority: "now"`: Claude Code
/// neemt het meteen mee in de lopende beurt.
pub fn claude_user_message(text: &str, steer: bool) -> String {
    let mut m = json!({"type": "user", "message": {"role": "user", "content": text}, "parent_tool_use_id": null, "session_id": ""});
    if steer {
        m["priority"] = json!("now");
    }
    line(m)
}

/// Antwoord op een toestemmingsvraag. Bij "toestaan" krijgt Claude Code de oorspronkelijke invoer terug.
pub fn claude_permission_response(request_id: &str, allow: bool, input: &Value, rules: Option<&Value>, message: &str) -> String {
    let decision = if allow {
        let mut d = json!({"behavior": "allow", "updatedInput": input});
        if let Some(r) = rules {
            d["updatedPermissions"] = r.clone();
        }
        d
    } else {
        json!({"behavior": "deny", "message": if message.is_empty() { "Denied by user in Nook." } else { message }})
    };
    line(json!({"type": "control_response", "response": {"subtype": "success", "request_id": request_id, "response": decision}}))
}

/// Het antwoord op AskUserQuestion, als toestemming met de antwoorden ingevuld.
pub fn claude_question_answer(request_id: &str, input: &Value, answers: &[(String, Vec<String>)]) -> String {
    let mut updated = input.clone();
    if !updated.is_object() {
        updated = json!({});
    }
    let mut filled = serde_json::Map::new();
    for (question, chosen) in answers {
        filled.insert(question.clone(), json!(chosen.join(", ")));
    }
    updated["answers"] = Value::Object(filled);
    line(
        json!({"type": "control_response", "response": {"subtype": "success", "request_id": request_id, "response": {"behavior": "allow", "updatedInput": updated}}}),
    )
}

/// Vraagt Claude Code de lopende beurt te onderbreken.
pub fn claude_interrupt(id: &str) -> String {
    line(json!({"type": "control_request", "request_id": id, "request": {"subtype": "interrupt"}}))
}

fn line(v: Value) -> String {
    format!("{v}\n")
}

// MARK: Codex

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodexFileChange {
    pub path: String,
    pub kind: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum CodexEvent {
    ThreadStarted(String),
    Message(String),
    Reasoning(String),
    CommandStarted { id: String, command: String },
    CommandFinished { id: String, command: String, output: String, exit_code: Option<i64> },
    FileChanges { id: String, changes: Vec<CodexFileChange> },
    ToolCall { id: String, name: String, detail: String, finished: bool, failed: bool },
    TurnCompleted(TurnUsage),
    Failed(String),
    UsageLimited,
}

pub fn parse_codex(line: &str) -> Vec<CodexEvent> {
    let Ok(object) = serde_json::from_str::<Value>(line) else { return vec![] };
    match s(&object, "type").unwrap_or("") {
        "thread.started" => s(&object, "thread_id").map(|t| vec![CodexEvent::ThreadStarted(t.into())]).unwrap_or_default(),
        "turn.completed" => {
            let mut usage = TurnUsage::default();
            if let Some(raw) = object.get("usage") {
                let cached = number(raw.get("cached_input_tokens")).unwrap_or(0.0) as u64;
                let input = number(raw.get("input_tokens")).unwrap_or(0.0) as u64;
                // Codex telt gecachete tokens mee in input_tokens; apart gehouden zodat ze niet dubbel tellen.
                usage.input_tokens = Some(input.saturating_sub(cached));
                usage.cache_read_tokens = Some(cached);
                usage.output_tokens = Some(number(raw.get("output_tokens")).unwrap_or(0.0) as u64);
                usage.context_tokens = Some(input);
            }
            vec![CodexEvent::TurnCompleted(usage)]
        }
        "turn.failed" => {
            let message = object.pointer("/error/message").and_then(Value::as_str).unwrap_or("Codex stopte met een fout.").to_string();
            let limited = message.to_lowercase().contains("usage limit");
            let mut events = vec![CodexEvent::Failed(message)];
            if limited {
                events.push(CodexEvent::UsageLimited);
            }
            events
        }
        "error" => vec![CodexEvent::Failed(s(&object, "message").unwrap_or("Codex meldde een fout.").into())],
        t @ ("item.started" | "item.updated" | "item.completed") => {
            object.get("item").map(|item| parse_codex_item(item, t == "item.completed")).unwrap_or_default()
        }
        _ => vec![],
    }
}

fn parse_codex_item(item: &Value, finished: bool) -> Vec<CodexEvent> {
    let id = s(item, "id").map(str::to_string).unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    // Oudere versies noemen het veld "item_type".
    let kind = s(item, "type").or_else(|| s(item, "item_type")).unwrap_or("");
    match kind {
        "agent_message" | "assistant_message" => {
            s(item, "text").filter(|t| finished && !t.is_empty()).map(|t| vec![CodexEvent::Message(t.into())]).unwrap_or_default()
        }
        "reasoning" => {
            s(item, "text").filter(|t| finished && !t.is_empty()).map(|t| vec![CodexEvent::Reasoning(t.into())]).unwrap_or_default()
        }
        "command_execution" => {
            let command = s(item, "command").unwrap_or("").to_string();
            if finished {
                vec![CodexEvent::CommandFinished {
                    id,
                    command,
                    output: s(item, "aggregated_output").unwrap_or("").into(),
                    exit_code: number(item.get("exit_code")).map(|n| n as i64),
                }]
            } else {
                vec![CodexEvent::CommandStarted { id, command }]
            }
        }
        "file_change" => {
            if !finished {
                return vec![];
            }
            let changes: Vec<CodexFileChange> = item
                .get("changes")
                .and_then(Value::as_array)
                .map(|list| {
                    list.iter()
                        .filter_map(|c| Some(CodexFileChange { path: s(c, "path")?.into(), kind: s(c, "kind").unwrap_or("update").into() }))
                        .collect()
                })
                .unwrap_or_default();
            if changes.is_empty() {
                vec![]
            } else {
                vec![CodexEvent::FileChanges { id, changes }]
            }
        }
        "mcp_tool_call" | "web_search" => {
            let mut name =
                s(item, "tool")
                    .map(str::to_string)
                    .unwrap_or_else(|| if kind == "web_search" { "web_search".into() } else { "mcp".into() });
            let mut detail = s(item, "query").or_else(|| s(item, "server")).unwrap_or("").to_string();
            // Nooks eigen werkruimte-tools lezen als wat ze doen: "Nook-terminal · npm run dev".
            if s(item, "server") == Some(super::bridge::SERVER_NAME) {
                if let Some(tool) = super::bridge::BridgeTool::named(&name) {
                    name = tool.label().into();
                    detail = item
                        .get("arguments")
                        .and_then(super::bridge::BridgeTool::detail)
                        .map(|d| super::models::tool_summary::one_line(&d, 120))
                        .unwrap_or_default();
                }
            }
            vec![CodexEvent::ToolCall { id, name, detail, finished, failed: s(item, "status") == Some("failed") }]
        }
        "error" => vec![CodexEvent::Failed(s(item, "message").unwrap_or("Codex meldde een fout.").into())],
        _ => vec![],
    }
}

// MARK: Gemini CLI

#[derive(Debug, Clone, PartialEq)]
pub enum GeminiEvent {
    Initialized {
        session_id: String,
        model: Option<String>,
    },
    /// Een stukje antwoord (`delta: true`) of een heel antwoord.
    Text {
        text: String,
        delta: bool,
    },
    ToolUse {
        id: String,
        name: String,
        input: Value,
    },
    ToolResult {
        id: String,
        output: String,
        is_error: bool,
    },
    Warning(String),
    Failed(String),
    Result {
        is_error: bool,
        message: Option<String>,
        usage: TurnUsage,
    },
}

pub fn parse_gemini(line: &str) -> Vec<GeminiEvent> {
    let Ok(object) = serde_json::from_str::<Value>(line) else { return vec![] };
    match s(&object, "type").unwrap_or("") {
        "init" => s(&object, "session_id")
            .filter(|i| !i.is_empty())
            .map(|i| vec![GeminiEvent::Initialized { session_id: i.into(), model: s(&object, "model").map(str::to_string) }])
            .unwrap_or_default(),
        "message" => {
            // De opdracht komt terug als gebruikersbericht; alleen het antwoord telt.
            if s(&object, "role") != Some("assistant") {
                return vec![];
            }
            s(&object, "content")
                .filter(|c| !c.is_empty())
                .map(|c| vec![GeminiEvent::Text { text: c.into(), delta: object.get("delta").and_then(Value::as_bool).unwrap_or(false) }])
                .unwrap_or_default()
        }
        "tool_use" => vec![GeminiEvent::ToolUse {
            id: s(&object, "tool_id").map(str::to_string).unwrap_or_else(|| uuid::Uuid::new_v4().to_string()),
            name: s(&object, "tool_name").unwrap_or("tool").into(),
            input: object.get("parameters").filter(|p| p.is_object()).cloned().unwrap_or(json!({})),
        }],
        "tool_result" => {
            let error = object.pointer("/error/message").and_then(Value::as_str);
            vec![GeminiEvent::ToolResult {
                id: s(&object, "tool_id").unwrap_or("").into(),
                output: s(&object, "output").or(error).unwrap_or("").into(),
                is_error: s(&object, "status") == Some("error"),
            }]
        }
        "error" => {
            let message = s(&object, "message").unwrap_or("Gemini CLI meldde een fout.").to_string();
            if s(&object, "severity") == Some("warning") {
                vec![GeminiEvent::Warning(message)]
            } else {
                vec![GeminiEvent::Failed(message)]
            }
        }
        "result" => {
            let mut usage = TurnUsage::default();
            if let Some(stats) = object.get("stats") {
                let cached = number(stats.get("cached")).map(|n| n as u64);
                let input = number(stats.get("input"))
                    .map(|n| n as u64)
                    .or_else(|| number(stats.get("input_tokens")).map(|n| (n as u64).saturating_sub(cached.unwrap_or(0))));
                usage.input_tokens = input;
                usage.cache_read_tokens = cached;
                usage.output_tokens = number(stats.get("output_tokens")).map(|n| n as u64);
                usage.context_tokens = number(stats.get("input_tokens")).map(|n| n as u64);
                usage.duration_seconds = number(stats.get("duration_ms")).map(|ms| ms / 1000.0);
            }
            vec![GeminiEvent::Result {
                is_error: s(&object, "status") == Some("error"),
                message: object.pointer("/error/message").and_then(Value::as_str).map(str::to_string),
                usage,
            }]
        }
        _ => vec![],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_init_and_deltas() {
        assert_eq!(
            parse_claude(r#"{"type":"system","subtype":"init","session_id":"abc","model":"claude-sonnet-4-5","cwd":"/x","tools":[]}"#),
            vec![ClaudeEvent::Initialized { session_id: "abc".into(), model: Some("claude-sonnet-4-5".into()) }]
        );
        let top = r#"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hal"}}}"#;
        assert_eq!(parse_claude(top), vec![ClaudeEvent::TextDelta("Hal".into())]);
        let nested = r#"{"type":"stream_event","parent_tool_use_id":"toolu_1","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}}}"#;
        assert!(parse_claude(nested).is_empty());
        let thinking = r#"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hm"}}}"#;
        assert_eq!(parse_claude(thinking), vec![ClaudeEvent::ThinkingDelta { text: "hm".into(), starts: false }]);
    }

    #[test]
    fn claude_assistant_with_tool_and_usage() {
        let line = r#"{"type":"assistant","parent_tool_use_id":null,"session_id":"abc","message":{"id":"msg_1","model":"claude-sonnet-4-5","content":[{"type":"text","text":"Ik kijk even."},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":20}}}"#;
        let events = parse_claude(line);
        assert_eq!(events.len(), 3);
        assert_eq!(events[0], ClaudeEvent::Text("Ik kijk even.".into()));
        assert_eq!(
            events[1],
            ClaudeEvent::ToolUse { id: "toolu_1".into(), name: "Bash".into(), input: json!({"command": "ls"}), nested: false }
        );
        let ClaudeEvent::Usage { tokens, .. } = &events[2] else { panic!() };
        assert_eq!(*tokens, TokenCounts { input: 10, output: 5, cache_read: 100, cache_write: 20 });
        assert_eq!(tokens.context(), 130);
        let sub = r#"{"type":"assistant","parent_tool_use_id":"toolu_parent","message":{"id":"m","content":[{"type":"text","text":"sub"},{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/a"}}],"usage":{"input_tokens":1,"output_tokens":1}}}"#;
        assert_eq!(
            parse_claude(sub),
            vec![ClaudeEvent::ToolUse { id: "t2".into(), name: "Read".into(), input: json!({"file_path": "/a"}), nested: true }]
        );
    }

    #[test]
    fn claude_tool_results_and_permission() {
        let string = r#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok","is_error":false}]}}"#;
        assert_eq!(parse_claude(string), vec![ClaudeEvent::ToolResult { id: "t1".into(), output: "ok".into(), is_error: false }]);
        let blocks = r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"a"},{"type":"text","text":"b"}],"is_error":true}]}}"#;
        assert_eq!(parse_claude(blocks), vec![ClaudeEvent::ToolResult { id: "t2".into(), output: "a\nb".into(), is_error: true }]);
        let req = r#"{"type":"control_request","request_id":"req_7","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf build"},"permission_suggestions":[{"type":"addRules"}],"tool_use_id":"toolu_9"}}"#;
        assert_eq!(
            parse_claude(req),
            vec![ClaudeEvent::PermissionRequest {
                request_id: "req_7".into(),
                tool: "Bash".into(),
                input: json!({"command": "rm -rf build"}),
                suggestions: Some(json!([{"type": "addRules"}])),
                tool_use_id: Some("toolu_9".into())
            }]
        );
    }

    #[test]
    fn claude_result() {
        let line = r#"{"type":"result","subtype":"success","is_error":false,"duration_ms":4200,"num_turns":3,"result":"Klaar.","session_id":"abc","total_cost_usd":0.0421,"usage":{"input_tokens":12,"output_tokens":340,"cache_read_input_tokens":9000,"cache_creation_input_tokens":800},"modelUsage":{"claude-sonnet-4-5":{"inputTokens":12,"contextWindow":200000,"costUSD":0.04}},"permission_denials":[{"tool_name":"Bash"}]}"#;
        let ClaudeEvent::Result(r) = &parse_claude(line)[0] else { panic!() };
        assert!(!r.is_error);
        assert_eq!((r.text.as_str(), r.session_id.as_deref()), ("Klaar.", Some("abc")));
        assert_eq!(
            (r.usage.input_tokens, r.usage.output_tokens, r.usage.cache_read_tokens, r.usage.cache_write_tokens),
            (Some(12), Some(340), Some(9000), Some(800))
        );
        assert!((r.usage.reported_cost_usd.unwrap() - 0.0421).abs() < 1e-6);
        assert_eq!(r.usage.context_window, Some(200_000));
        assert!((r.usage.duration_seconds.unwrap() - 4.2).abs() < 1e-6);
        assert_eq!(r.permission_denials, 1);
        let ClaudeEvent::Result(e) =
            &parse_claude(r#"{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"s"}"#)[0]
        else {
            panic!()
        };
        assert!(e.is_error);
        assert_eq!((e.usage.reported_cost_usd, e.usage.input_tokens, e.usage.context_window), (None, None, None));
        assert!(parse_claude("not json").is_empty());
        assert!(parse_claude("{}").is_empty());
        assert!(parse_claude(r#"{"type":"control_response","response":{}}"#).is_empty());
    }

    #[test]
    fn claude_outgoing() {
        let l = claude_user_message("Hallo \"wereld\"\nregel 2", false);
        assert!(l.ends_with('\n'));
        assert_eq!(l.matches('\n').count(), 1);
        let v: Value = serde_json::from_str(&l).unwrap();
        assert_eq!(v["message"]["content"], "Hallo \"wereld\"\nregel 2");
        assert_eq!(v["message"]["role"], "user");
        let allow: Value = serde_json::from_str(&claude_permission_response("r1", true, &json!({"command": "ls"}), None, "")).unwrap();
        assert_eq!(allow["response"]["request_id"], "r1");
        assert_eq!(allow["response"]["response"]["updatedInput"]["command"], "ls");
        assert!(allow["response"]["response"].get("updatedPermissions").is_none());
        let always: Value =
            serde_json::from_str(&claude_permission_response("r2", true, &json!({}), Some(&json!([{"type": "addRules"}])), "")).unwrap();
        assert!(always["response"]["response"].get("updatedPermissions").is_some());
        let deny: Value = serde_json::from_str(&claude_permission_response("r3", false, &json!({}), None, "")).unwrap();
        assert_eq!(deny["response"]["response"]["behavior"], "deny");
        let i: Value = serde_json::from_str(&claude_interrupt("x")).unwrap();
        assert_eq!(i["request"]["subtype"], "interrupt");
    }

    #[test]
    fn codex() {
        assert_eq!(parse_codex(r#"{"type":"thread.started","thread_id":"t-1"}"#), vec![CodexEvent::ThreadStarted("t-1".into())]);
        assert_eq!(
            parse_codex(r#"{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"Klaar"}}"#),
            vec![CodexEvent::Message("Klaar".into())]
        );
        assert_eq!(
            parse_codex(r#"{"type":"item.completed","item":{"id":"i1","type":"reasoning","text":"denk"}}"#),
            vec![CodexEvent::Reasoning("denk".into())]
        );
        assert!(parse_codex(r#"{"type":"item.started","item":{"id":"i0","type":"agent_message","text":""}}"#).is_empty());
        assert_eq!(
            parse_codex(
                r#"{"type":"item.started","item":{"id":"c1","type":"command_execution","command":"bash -lc ls","status":"in_progress"}}"#
            ),
            vec![CodexEvent::CommandStarted { id: "c1".into(), command: "bash -lc ls".into() }]
        );
        assert_eq!(
            parse_codex(
                r#"{"type":"item.completed","item":{"id":"c1","type":"command_execution","command":"ls","aggregated_output":"a\nb","exit_code":2,"status":"failed"}}"#
            ),
            vec![CodexEvent::CommandFinished { id: "c1".into(), command: "ls".into(), output: "a\nb".into(), exit_code: Some(2) }]
        );
        let changes = r#"{"type":"item.completed","item":{"id":"f1","item_type":"file_change","changes":[{"path":"/r/a.swift","kind":"update"},{"path":"/r/b.swift","kind":"add"}],"status":"completed"}}"#;
        assert_eq!(
            parse_codex(changes),
            vec![CodexEvent::FileChanges {
                id: "f1".into(),
                changes: vec![
                    CodexFileChange { path: "/r/a.swift".into(), kind: "update".into() },
                    CodexFileChange { path: "/r/b.swift".into(), kind: "add".into() }
                ]
            }]
        );
        let CodexEvent::TurnCompleted(u) =
            &parse_codex(r#"{"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50}}"#)[0]
        else {
            panic!()
        };
        assert_eq!(
            (u.input_tokens, u.cache_read_tokens, u.output_tokens, u.reported_cost_usd, u.context_window),
            (Some(200), Some(800), Some(50), None, None)
        );
        assert_eq!(
            parse_codex(r#"{"type":"turn.failed","error":{"message":"rate limit"}}"#),
            vec![CodexEvent::Failed("rate limit".into())]
        );
        assert_eq!(parse_codex(r#"{"type":"error","message":"stream error"}"#), vec![CodexEvent::Failed("stream error".into())]);
    }

    #[test]
    fn gemini() {
        assert_eq!(
            parse_gemini(r#"{"type":"init","session_id":"g1","model":"gemini-2.5-pro"}"#),
            vec![GeminiEvent::Initialized { session_id: "g1".into(), model: Some("gemini-2.5-pro".into()) }]
        );
        assert!(parse_gemini(r#"{"type":"message","role":"user","content":"x"}"#).is_empty());
        assert_eq!(
            parse_gemini(r#"{"type":"message","role":"assistant","content":"Hoi","delta":true}"#),
            vec![GeminiEvent::Text { text: "Hoi".into(), delta: true }]
        );
        let GeminiEvent::Result { usage, is_error, .. } = &parse_gemini(
            r#"{"type":"result","status":"success","stats":{"input_tokens":100,"cached":40,"output_tokens":7,"duration_ms":1500}}"#,
        )[0] else {
            panic!()
        };
        assert!(!is_error);
        assert_eq!(
            (usage.input_tokens, usage.cache_read_tokens, usage.output_tokens, usage.context_tokens),
            (Some(60), Some(40), Some(7), Some(100))
        );
    }
}
