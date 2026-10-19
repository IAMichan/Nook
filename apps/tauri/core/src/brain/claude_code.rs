//! Denken via Claude Code op deze computer (`claude -p`): je Claude-abonnement (Pro/Max) als brein, zonder API-sleutel.
//! Claude Code draait dichtgetimmerd: geen bestanden, geen shell, geen willekeurige adressen ophalen (zo zou onbetrouwbare
//! tekst gegevens kunnen lekken), en zoeken op het web alleen als de bron Web voor deze vraag mag. Het draait in een
//! lege werkmap van zichzelf, nooit in Nooks gegevensmap met je gesprekken en het logboek.
//!
//! Nooks eigen tools gaan via een tekstprotocol: het model antwoordt met JSON als {"name": "…", "parameters": {…}}, wat de
//! gedeelde tool-loop oppikt. De sessie wordt tussen rondes hervat.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use super::{LoopTool, ModelConversation, ModelTurn, OnText, PromptImage, ToolResult};
use crate::{paths, NookError, Result};

/// Ingebouwde tools van Claude Code die het brein nooit mag gebruiken. Bestanden lezen zou Nooks eigen gegevens tonen en
/// WebFetch zou ze overal heen kunnen sturen; Nooks eigen tools doen bestanden en pagina's met hun eigen controles.
pub const BLOCKED_TOOLS: [&str; 12] =
    ["Bash", "Edit", "Write", "MultiEdit", "NotebookEdit", "Task", "Read", "Glob", "Grep", "LS", "WebFetch", "TodoWrite"];

fn candidates() -> Vec<PathBuf> {
    let home = dirs::home_dir().unwrap_or_default();
    let mut list = vec![
        home.join(".claude/local/claude"),
        home.join(".local/bin/claude"),
        PathBuf::from("/usr/local/bin/claude"),
        PathBuf::from("/usr/bin/claude"),
        home.join(".npm-global/bin/claude"),
        home.join(".bun/bin/claude"),
        home.join(".volta/bin/claude"),
    ];
    if cfg!(windows) {
        if let Some(appdata) = std::env::var_os("APPDATA") {
            list.insert(0, PathBuf::from(appdata).join("npm").join("claude.cmd"));
        }
        list.insert(0, home.join(".local").join("bin").join("claude.exe"));
        list.insert(0, home.join(".claude").join("local").join("claude.exe"));
    }
    list
}

fn executable(path: &Path) -> bool {
    path.is_file()
}

/// Waar `claude` staat: bekende plekken, dan het zoekpad.
pub fn locate() -> Option<PathBuf> {
    if let Some(hit) = candidates().into_iter().find(|p| executable(p)) {
        return Some(hit);
    }
    let names: &[&str] = if cfg!(windows) { &["claude.exe", "claude.cmd"] } else { &["claude"] };
    std::env::var_os("PATH")
        .and_then(|path| std::env::split_paths(&path).flat_map(|dir| names.iter().map(move |n| dir.join(n))).find(|p| executable(p)))
}

pub fn protocol_text(tools: &[LoopTool], allow_web_search: bool) -> String {
    if tools.is_empty() {
        return String::new();
    }
    let mut lines = vec![
        "You have these tools from Nook. To use one, reply ONLY with JSON for each tool call on its own line, like {\"name\": \"list_events\", \"parameters\": {\"from\": \"…\", \"to\": \"…\"}}. You will receive the result back. Actions (calendar, reminders, email, apps) are shown to the user first.".to_string(),
        if allow_web_search {
            "You may use your built-in tool WebSearch for web queries. To read a page, use Nook's read_webpage tool.".into()
        } else {
            "Do not use the web for this request.".into()
        },
        "Tools:".into(),
    ];
    for tool in tools {
        let schema = super::tool_loop::sorted(tool.schema.get("properties").unwrap_or(&json!({})));
        lines.push(format!("- {}: {} Parameters: {schema}", tool.name, tool.description));
    }
    lines.join("\n")
}

pub fn arguments(model: &str, system: &str, resume: Option<&str>, allow_web_search: bool) -> Vec<String> {
    let mut args: Vec<String> =
        ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
            .map(String::from)
            .to_vec();
    args.extend([
        "--model".into(),
        if model.is_empty() { "haiku".into() } else { model.into() },
        "--append-system-prompt".into(),
        system.into(),
    ]);
    if allow_web_search {
        args.extend(["--allowedTools".into(), "WebSearch".into()]);
    }
    args.push("--disallowedTools".into());
    args.extend(BLOCKED_TOOLS.iter().map(|t| t.to_string()));
    if !allow_web_search {
        args.push("WebSearch".into());
    }
    // Niet de instellingen, hooks of MCP-servers van de gebruiker laden: dit is Nooks brein, geen agentsessie.
    args.extend(["--max-turns", "6", "--setting-sources", "local", "--strict-mcp-config"].map(String::from));
    if let Some(resume) = resume {
        args.extend(["--resume".into(), resume.into()]);
    }
    args
}

/// Het gebruikersbericht dat Claude Code via stdin leest (daar passen ook plaatjes in, zodat Read dicht kan blijven).
pub fn stream_input(message: &str, images: &[PromptImage]) -> String {
    let mut content: Vec<Value> = images
        .iter()
        .map(|i| json!({"type": "image", "source": {"type": "base64", "media_type": i.media_type, "data": i.base64}}))
        .collect();
    content.push(json!({"type": "text", "text": message}));
    format!("{}\n", json!({"type": "user", "message": {"role": "user", "content": content}}))
}

/// Wat uit één regel stream-json komt.
#[derive(Debug, Default, PartialEq)]
pub struct Parsed {
    pub delta: Option<String>,
    pub message_text: Option<String>,
    pub result: Option<(String, bool)>,
    pub session: Option<String>,
}

pub fn parse_line(line: &str) -> Parsed {
    let Ok(event) = serde_json::from_str::<Value>(line.trim()) else { return Parsed::default() };
    let mut parsed = Parsed { session: event["session_id"].as_str().map(str::to_string), ..Default::default() };
    match event["type"].as_str() {
        Some("stream_event") => {
            if event["event"]["type"] == "content_block_delta" && event["event"]["delta"]["type"] == "text_delta" {
                parsed.delta = event["event"]["delta"]["text"].as_str().map(str::to_string);
            }
        }
        Some("assistant") => {
            let text: String = event["message"]["content"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|b| b["type"] == "text")
                .filter_map(|b| b["text"].as_str())
                .collect();
            if !text.is_empty() {
                parsed.message_text = Some(text);
            }
        }
        Some("result") => {
            parsed.result = Some((event["result"].as_str().unwrap_or("").to_string(), event["is_error"].as_bool().unwrap_or(false)));
        }
        _ => {}
    }
    parsed
}

pub struct ClaudeCodeConversation {
    model: String,
    system: String,
    message: String,
    allow_web_search: bool,
    session: Option<String>,
    images: Vec<PromptImage>,
    /// De Claude-account-map uit de Agents-tab, als die gekozen is.
    config_dir: Option<PathBuf>,
}

impl ClaudeCodeConversation {
    pub fn new(model: &str, system: &str, prompt: &str, allow_web_search: bool) -> Self {
        Self {
            model: model.into(),
            system: system.into(),
            message: prompt.into(),
            allow_web_search,
            session: None,
            images: vec![],
            config_dir: None,
        }
    }

    pub fn with_config_dir(mut self, dir: Option<PathBuf>) -> Self {
        self.config_dir = dir;
        self
    }

    async fn call(&mut self, path: &Path, system: &str, on_text: OnText<'_>) -> Result<String> {
        let mut command = tokio::process::Command::new(path);
        command
            .args(arguments(&self.model, system, self.session.as_deref(), self.allow_web_search))
            .current_dir(paths::brain_scratch_directory())
            .env("NOOK_INTERNAL", "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        if let Some(dir) = &self.config_dir {
            command.env("CLAUDE_CONFIG_DIR", dir);
        }
        if let Some(parent) = path.parent() {
            let mut list = vec![parent.to_path_buf()];
            list.extend(std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect::<Vec<_>>()).unwrap_or_default());
            if let Ok(joined) = std::env::join_paths(list) {
                command.env("PATH", joined);
            }
        }
        let mut child = command.spawn().map_err(|e| NookError(format!("Claude Code kon niet starten: {e}")))?;
        if let Some(mut stdin) = child.stdin.take() {
            stdin.write_all(stream_input(&self.message, &self.images).as_bytes()).await?;
            drop(stdin);
        }
        self.images.clear();
        let stdout = child.stdout.take().ok_or_else(|| NookError::new("Claude Code gaf geen uitvoer."))?;
        let mut reader = BufReader::new(stdout).lines();
        let mut text = String::new();
        let mut finished: Option<(String, bool)> = None;
        let mut raw = String::new();
        let work = async {
            while let Some(line) = reader.next_line().await? {
                if raw.len() < 4_000 {
                    raw.push_str(&line);
                    raw.push('\n');
                }
                let parsed = parse_line(&line);
                if let Some(session) = parsed.session {
                    self.session = Some(session);
                }
                if let Some(delta) = parsed.delta {
                    text.push_str(&delta);
                    if let Some(cb) = on_text {
                        cb(super::text::visible(&text));
                    }
                }
                if let Some(message) = parsed.message_text {
                    if text.is_empty() {
                        text = message;
                    }
                }
                if parsed.result.is_some() {
                    finished = parsed.result;
                }
            }
            Ok::<(), std::io::Error>(())
        };
        match tokio::time::timeout(Duration::from_secs(120), work).await {
            Ok(result) => result?,
            Err(_) => {
                let _ = child.kill().await;
                return Err(NookError::new("Claude Code antwoordde niet binnen twee minuten."));
            }
        }
        let status = child.wait().await?;
        let mut errors = String::new();
        if let Some(mut stderr) = child.stderr.take() {
            use tokio::io::AsyncReadExt;
            let _ = stderr.read_to_string(&mut errors).await;
        }
        let detail = format!("{raw}{errors}");
        // Nooit opnieuw proberen zonder de afschermende vlaggen: dan zou Claude Code de hooks van de gebruiker laden.
        if !status.success() && (detail.contains("setting-sources") || detail.contains("strict-mcp-config")) {
            return Err(NookError::new("Deze versie van Claude Code is te oud om veilig als Nooks brein te draaien. Werk hem bij (`claude update`) en probeer het opnieuw."));
        }
        match finished {
            Some((result, true)) => {
                if result.to_lowercase().contains("limit") {
                    Err(NookError(format!("Je Claude-limiet is bereikt. {result}")))
                } else {
                    Err(NookError(format!(
                        "Claude Code: {}",
                        if result.is_empty() { "er ging iets mis".into() } else { result.chars().take(240).collect::<String>() }
                    )))
                }
            }
            Some((result, false)) => Ok(if result.is_empty() { text } else { result }),
            None => {
                let lower = detail.to_lowercase();
                if lower.contains("login") || lower.contains("authenticat") {
                    return Err(NookError::new(
                        "Claude Code is niet ingelogd. Draai `claude` in een terminal, log in met je abonnement en probeer het opnieuw.",
                    ));
                }
                let short = detail.trim().chars().take(200).collect::<String>();
                Err(NookError(format!("Claude Code antwoordde niet{}", if short.is_empty() { ".".into() } else { format!(": {short}") })))
            }
        }
    }
}

#[async_trait::async_trait]
impl ModelConversation for ClaudeCodeConversation {
    async fn next(&mut self, tools: &[LoopTool], on_text: OnText<'_>) -> Result<ModelTurn> {
        let path = locate().ok_or_else(|| {
            NookError::new("Claude Code staat niet op deze computer. Installeer het (claude.com/product/claude-code), draai `claude` in een terminal om in te loggen, en probeer het opnieuw.")
        })?;
        let system = format!("{}\n\n{}", self.system, protocol_text(tools, self.allow_web_search));
        let text = self.call(&path, &system, on_text).await?;
        if let Some(cb) = on_text {
            cb(super::text::visible(&text));
        }
        // Tool-aanroepen staan als JSON in de tekst: de gedeelde loop haalt ze eruit.
        Ok(ModelTurn { text, calls: vec![], finished: false })
    }

    fn add_results(&mut self, results: &[ToolResult]) {
        let parts: Vec<String> = results.iter().map(|r| format!("Result of {}:\n{}", r.call.name, r.output)).collect();
        self.message = format!(
            "{}\n\nNow respond to the request in natural language, or invoke another tool only if strictly necessary.",
            parts.join("\n\n")
        );
    }

    fn add_instruction(&mut self, text: &str) {
        self.message = format!("{}\n\n{text}", self.message);
    }

    fn attach(&mut self, images: &[PromptImage]) {
        self.images = images.to_vec();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runs_locked_down() {
        let args = arguments("", "sys", None, false);
        assert!(args.windows(2).any(|w| w == ["--model", "haiku"]));
        assert!(
            args.contains(&"--strict-mcp-config".to_string())
                && args.contains(&"Read".to_string())
                && args.contains(&"WebSearch".to_string())
        );
        assert!(!args.contains(&"--allowedTools".to_string()));
        let web = arguments("sonnet", "sys", Some("abc"), true);
        assert!(web.windows(2).any(|w| w == ["--allowedTools", "WebSearch"]) && web.windows(2).any(|w| w == ["--resume", "abc"]));
    }

    #[test]
    fn reads_the_stream() {
        let delta = parse_line(
            r#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hoi"}},"session_id":"s1"}"#,
        );
        assert_eq!(delta.delta.as_deref(), Some("Hoi"));
        assert_eq!(delta.session.as_deref(), Some("s1"));
        let result = parse_line(r#"{"type":"result","result":"Klaar","is_error":false,"session_id":"s1"}"#);
        assert_eq!(result.result, Some(("Klaar".into(), false)));
        let message = parse_line(r#"{"type":"assistant","message":{"content":[{"type":"text","text":"A"},{"type":"tool_use"}]}}"#);
        assert_eq!(message.message_text.as_deref(), Some("A"));
        let input = stream_input("wat is dit", &[PromptImage { media_type: "image/png".into(), base64: "AAA".into() }]);
        assert!(input.ends_with('\n') && input.contains("\"type\":\"image\""));
    }
}
