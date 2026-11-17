//! Reasoning through a coding agent you are already signed in to, with your own subscription or account instead of an
//! API key: Codex with your ChatGPT account (`codex exec`), Gemini CLI with your Google account (`gemini -p`), Grok with
//! your xAI account (`grok -p`), Kimi Code with your Kimi account (`kimi -p`) and Mistral Vibe with your Mistral account
//! (`vibe -p`). Port of the Mac's `SubscriptionBrain`. Claude Code, the first member of this family, keeps its own
//! `claude_code` module because it resumes sessions.
//!
//! All run locked down, as Claude Code does: no shell, no file reading or writing, no extensions, plugins, sub-agents or
//! MCP servers of your own, and web search only when the Web source is allowed for the request (Kimi and Vibe never
//! search). Each call runs in an empty folder of its own, never Nook's data folder. Nook's own tools go through the same
//! JSON text protocol as with Claude Code, and the whole conversation is sent again each round, so nothing is kept on
//! disk between calls.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use super::{LoopTool, ModelConversation, ModelTurn, OnText, PromptImage, ToolResult};
use crate::agents::AgentKind;
use crate::i18n::trf;
use crate::provider::AIProvider;
use crate::{paths, NookError, Result};

/// The coding agent Nook already knows (and runs) whose own login this provider thinks with; `None` for the APIs and
/// for Kimi Code and Mistral Vibe, which Nook only uses as a brain. Its account comes from Settings › Agents.
pub fn agent(provider: AIProvider) -> Option<AgentKind> {
    match provider {
        AIProvider::ClaudeCode => Some(AgentKind::Claude),
        AIProvider::CodexCli => Some(AgentKind::Codex),
        AIProvider::GeminiCli => Some(AgentKind::Gemini),
        AIProvider::GrokCli => Some(AgentKind::Grok),
        _ => None,
    }
}

// MARK: Finding the program

fn folders() -> Vec<PathBuf> {
    let home = dirs::home_dir().unwrap_or_default();
    let mut list: Vec<PathBuf> = vec![];
    if cfg!(windows) {
        if let Some(appdata) = std::env::var_os("APPDATA") {
            list.push(PathBuf::from(appdata).join("npm"));
        }
    }
    list.extend([
        home.join(".local/bin"),
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/usr/local/bin"),
        PathBuf::from("/usr/bin"),
        home.join(".npm-global/bin"),
        home.join(".bun/bin"),
        home.join(".volta/bin"),
        home.join(".cargo/bin"),
        home.join(".kimi-code/bin"),
        home.join(".grok/bin"),
    ]);
    list
}

fn names(command: &str) -> Vec<String> {
    if cfg!(windows) {
        vec![format!("{command}.exe"), format!("{command}.cmd")]
    } else {
        vec![command.to_string()]
    }
}

/// Where the agent's program is: known folders first, then the search path.
pub fn locate(provider: AIProvider) -> Option<PathBuf> {
    if provider == AIProvider::ClaudeCode {
        return super::claude_code::locate();
    }
    let command = provider.cli_command()?;
    let path: Vec<PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
    folders().into_iter().chain(path).flat_map(|dir| names(command).into_iter().map(move |n| dir.join(n))).find(|p| p.is_file())
}

/// Signed in with the agent's own login: Vibe's saved sign-in, otherwise (as far as Nook can tell from here) installed.
pub fn is_signed_in(provider: AIProvider) -> bool {
    if provider == AIProvider::VibeCli {
        let file = dirs::home_dir().unwrap_or_default().join(".vibe").join(".env");
        return std::fs::read_to_string(file).unwrap_or_default().contains("MISTRAL_API_KEY=");
    }
    locate(provider).is_some()
}

/// The script an npm `.cmd` shim on Windows runs (`"%dp0%\node_modules\…\cli.js" %*`), relative to the shim's folder.
/// A `.cmd` refuses arguments with quotes or newlines ("batch file arguments are invalid"), and a prompt always has
/// them, so Nook runs the script with Node itself.
pub fn npm_shim_script(shim: &str) -> Option<String> {
    // The shim names `%dp0%\node.exe` first; the script is the quoted path that ends in a JavaScript file.
    shim.match_indices("%dp0%\\").find_map(|(index, marker)| {
        let rest = &shim[index + marker.len()..];
        let script = &rest[..rest.find('"')?];
        [".js", ".mjs", ".cjs"].iter().any(|e| script.ends_with(e)).then(|| script.to_string())
    })
}

/// The program to start and the arguments that go before the agent's own.
fn launch(path: &Path) -> (PathBuf, Vec<String>) {
    let is_shim = path.extension().is_some_and(|e| e.eq_ignore_ascii_case("cmd"));
    if is_shim {
        if let (Some(dir), Some(script)) = (path.parent(), std::fs::read_to_string(path).ok().as_deref().and_then(npm_shim_script)) {
            let local = dir.join("node.exe");
            let node = if local.is_file() { local } else { PathBuf::from("node") };
            return (node, vec![dir.join(script).to_string_lossy().into_owned()]);
        }
    }
    (path.to_path_buf(), vec![])
}

// MARK: The prompt

pub fn protocol_text(tools: &[LoopTool], allow_web_search: bool) -> String {
    if tools.is_empty() {
        return String::new();
    }
    let mut lines = vec![
        "You have these tools from Nook. To use one, reply ONLY with JSON for each tool call on its own line, like {\"name\": \"list_events\", \"parameters\": {\"from\": \"…\", \"to\": \"…\"}}. You will receive the result back. Actions (calendar, reminders, email, apps) are shown to the user first.".to_string(),
        if allow_web_search {
            "You may use your built-in web search for web queries. To read a page, use Nook's read_webpage tool.".into()
        } else {
            "Do not use the web for this request.".into()
        },
        "These are ALL your tools: you have no shell, no files and no other tools here. When a source's tools are not listed, call use_source; never tell the user a tool is missing before checking this list.".into(),
        "Nook's tools are not function calls: never invoke them through tool use, always write the JSON line in your reply text.".into(),
        "Tools:".into(),
    ];
    for tool in tools {
        let schema = super::tool_loop::sorted(tool.schema.get("properties").unwrap_or(&json!({})));
        lines.push(format!("- {}: {} Parameters: {schema}", tool.name, tool.description));
    }
    lines.join("\n")
}

/// A TOML basic string, for Codex's `-c key=value` overrides.
pub fn toml_string(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() => out.push_str(&format!("\\u{:04X}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

// MARK: Codex

/// `codex exec` that only answers: none of your config, rules, plugins, apps or MCP servers; read-only and without its
/// shell, image reader or sub-agents; nothing saved; Nook's instructions as developer instructions; the prompt on stdin
/// and the answer in a file. Your ChatGPT login still comes from `CODEX_HOME`.
pub fn codex_arguments(model: &str, system: &str, allow_web_search: bool, answer_path: &str, image_paths: &[String]) -> Vec<String> {
    let mut args: Vec<String> =
        ["exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check", "-s", "read-only"]
            .map(String::from)
            .to_vec();
    for feature in ["shell_tool", "unified_exec", "view_image", "plugins", "apps", "multi_agent"] {
        args.extend(["-c".into(), format!("features.{feature}=false")]);
    }
    args.extend([
        "-c".into(),
        if allow_web_search { r#"web_search="live""#.into() } else { r#"web_search="disabled""#.into() },
        "-c".into(),
        format!("developer_instructions={}", toml_string(system)),
        "-c".into(),
        r#"model_reasoning_effort="low""#.into(),
    ]);
    if !model.is_empty() {
        args.extend(["-m".into(), model.into()]);
    }
    args.extend(["--output-last-message".into(), answer_path.into()]);
    for path in image_paths {
        args.extend(["-i".into(), path.clone()]);
    }
    args.push("-".into());
    args
}

// MARK: Gemini CLI

/// `gemini -p` that only answers: no extensions, the JSON reply, and the default approval mode, under which nothing
/// that asks for approval can run headless. The rest is locked in the settings file of `gemini_settings`.
pub fn gemini_arguments(model: &str, prompt: &str) -> Vec<String> {
    let mut args: Vec<String> =
        ["-p", prompt, "--output-format", "json", "-e", "none", "--approval-mode", "default"].map(String::from).to_vec();
    if !model.is_empty() {
        args.extend(["-m".into(), model.into()]);
    }
    args
}

/// Gemini CLI's system settings (they override yours for this run only): no built-in tool but web search when allowed,
/// the reading and writing tools excluded by name as well, no extensions, MCP servers or skills, and no GEMINI.md.
pub fn gemini_settings(allow_web_search: bool) -> Value {
    let mut blocked = vec![
        "run_shell_command",
        "read_file",
        "read_many_files",
        "write_file",
        "replace",
        "edit",
        "glob",
        "search_file_content",
        "grep_search",
        "list_directory",
        "web_fetch",
        "save_memory",
        "write_todos",
        "activate_skill",
    ];
    if !allow_web_search {
        blocked.push("google_web_search");
    }
    json!({
        "tools": {"core": [if allow_web_search { "google_web_search" } else { "nook_no_tools" }], "exclude": blocked},
        "admin": {"extensions": {"enabled": false}, "mcp": {"enabled": false}, "skills": {"enabled": false}},
        "context": {"fileName": "NOOK-BRAIN-NO-CONTEXT.md"},
    })
}

fn json_object(text: &str) -> Option<Value> {
    let start = text.find('{')?;
    let end = text.rfind('}')?;
    (start < end).then(|| serde_json::from_str(&text[start..=end]).ok()).flatten()
}

/// Gemini CLI's JSON reply: `response` holds the answer, `error.message` what went wrong.
pub fn gemini_answer(stdout: &str) -> std::result::Result<String, Option<String>> {
    let object = json_object(stdout).ok_or(None)?;
    match object["response"].as_str() {
        Some(response) if !response.is_empty() => Ok(response.to_string()),
        _ => Err(object["error"]["message"].as_str().map(str::to_string)),
    }
}

// MARK: Grok

/// `grok -p` that only answers: no built-in tool but web search (and that one off unless allowed), every shell, file
/// and MCP call denied as well, no sub-agents, plan mode or memory, and Nook's instructions as the whole system prompt.
pub fn grok_arguments(model: &str, system: &str, prompt: &str, allow_web_search: bool) -> Vec<String> {
    let mut args: Vec<String> = [
        "-p",
        prompt,
        "--output-format",
        "json",
        "--system-prompt-override",
        system,
        "--tools",
        "web_search",
        "--disallowed-tools",
        "Agent",
        "--no-subagents",
        "--no-plan",
        "--max-turns",
        "4",
        "--no-auto-update",
    ]
    .map(String::from)
    .to_vec();
    for rule in ["Bash", "Read", "Edit", "Write", "Grep", "MCPTool"] {
        args.extend(["--deny".into(), rule.into()]);
    }
    if !allow_web_search {
        args.push("--disable-web-search".into());
    }
    if !model.is_empty() {
        args.extend(["-m".into(), model.into()]);
    }
    args
}

/// Grok's JSON reply: `text` (or `result`) holds the answer.
pub fn grok_answer(stdout: &str) -> Option<String> {
    let object = json_object(stdout)?;
    object["text"].as_str().or_else(|| object["result"].as_str()).filter(|a| !a.is_empty()).map(str::to_string)
}

// MARK: Kimi Code

/// The agent file Kimi Code runs as: no tools and no sub-agents at all; its body is the whole system prompt.
pub fn kimi_agent_file(system: &str) -> String {
    format!("---\nname: nook-brain\ndescription: Nook's brain, which only answers.\ntools: []\nsubagents: []\n---\n\n{system}\n")
}

pub fn kimi_arguments(model: &str, prompt: &str, agent_file: &str) -> Vec<String> {
    let mut args: Vec<String> = ["-p", prompt, "--agent-file", agent_file, "--output-format", "stream-json"].map(String::from).to_vec();
    if !model.is_empty() {
        args.extend(["-m".into(), model.into()]);
    }
    args
}

/// The last assistant message without tool calls in Kimi Code's stream-json lines.
pub fn kimi_answer(output: &str) -> Option<String> {
    let mut answer = None;
    for line in output.lines() {
        let Ok(object) = serde_json::from_str::<Value>(line) else { continue };
        if object["role"] != "assistant" || object["tool_calls"].as_array().is_some_and(|c| !c.is_empty()) {
            continue;
        }
        let text = match &object["content"] {
            Value::String(text) => text.clone(),
            Value::Array(parts) => parts.iter().filter_map(|p| p["text"].as_str()).collect(),
            _ => String::new(),
        };
        if !text.is_empty() {
            answer = Some(text);
        }
    }
    answer
}

// MARK: Mistral Vibe

/// `vibe -p` that only answers: only a tool that does not exist is enabled, which in programmatic mode switches every
/// other tool off. Vibe has no system prompt flag, so Nook's instructions lead the prompt.
pub fn vibe_arguments(system: &str, prompt: &str) -> Vec<String> {
    vec![
        "-p".into(),
        format!("<instructions>\n{system}\n</instructions>\n\n{prompt}"),
        "--enabled-tools".into(),
        "nook_no_tools".into(),
        "--max-turns".into(),
        "3".into(),
        "--output".into(),
        "text".into(),
    ]
}

// MARK: Errors

fn short_tail(text: &str, count: usize) -> String {
    let chars: Vec<char> = text.chars().collect();
    chars[chars.len().saturating_sub(count)..].iter().collect()
}

/// What went wrong, in words: not signed in, a limit, a program too old for the safety flags, or its own message.
pub fn failure(provider: AIProvider, stdout: &str, stderr: &str) -> NookError {
    let name = provider.title();
    let detail = format!("{stderr}\n{stdout}").trim().to_string();
    let lower = detail.to_lowercase();
    if ["login", "log in", "auth", "sign in"].iter().any(|w| lower.contains(w)) {
        return NookError(trf(
            "{name} is niet ingelogd. Log in via Instellingen › Brein en probeer het opnieuw.",
            "{name} is not signed in. Sign in under Settings › Brain and try again.",
            &[("name", &name)],
        ));
    }
    // Never retried without the isolation flags: that would load the user's own tools and rules.
    if ["unexpected argument", "unknown argument", "unknown option"].iter().any(|w| lower.contains(w)) {
        return NookError(trf(
            "Deze versie van {name} is te oud om veilig als Nooks brein te draaien. Werk hem bij en probeer het opnieuw.",
            "This version of {name} is too old to run safely as Nook's brain. Update it and try again.",
            &[("name", &name)],
        ));
    }
    if lower.contains("limit") || lower.contains("quota") {
        return NookError(trf(
            "Je limiet van {name} is bereikt. {detail}",
            "Your {name} limit has been reached. {detail}",
            &[("name", &name), ("detail", &short_tail(&detail, 200))],
        ));
    }
    NookError(trf(
        "{name} gaf geen antwoord: {detail}",
        "{name} did not answer: {detail}",
        &[("name", &name), ("detail", &short_tail(&detail, 240))],
    ))
}

pub fn not_installed(provider: AIProvider) -> NookError {
    NookError(trf(
        "{name} staat niet op deze computer. Stel het in via Instellingen › Brein.",
        "{name} is not on this computer. Set it up in Settings › Brain.",
        &[("name", &provider.title())],
    ))
}

// MARK: Running

struct Output {
    success: bool,
    stdout: String,
    stderr: String,
}

/// Runs the agent in its own empty folder, capped at 2 minutes; stopping the answer ends the program.
async fn execute(
    path: &Path,
    arguments: Vec<String>,
    environment: &[(String, String)],
    directory: &Path,
    stdin: Option<&str>,
    provider: AIProvider,
) -> Result<Output> {
    let (program, mut args) = launch(path);
    args.extend(arguments);
    let mut command = tokio::process::Command::new(&program);
    command
        .args(&args)
        .current_dir(directory)
        .stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    for (key, value) in environment {
        command.env(key, value);
    }
    // The agent's own folder first on the search path, so a Node script finds its Node.
    if let Some(parent) = path.parent() {
        let mut list = vec![parent.to_path_buf()];
        list.extend(std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect::<Vec<_>>()).unwrap_or_default());
        if let Ok(joined) = std::env::join_paths(list) {
            command.env("PATH", joined);
        }
    }
    #[cfg(windows)]
    {
        // No console window flashing up for every answer.
        command.creation_flags(0x0800_0000);
    }
    let mut child = command.spawn().map_err(|e| NookError(format!("{}: {e}", provider.title())))?;
    let mut out = child.stdout.take();
    let mut err = child.stderr.take();
    let input = stdin.map(str::to_string);
    let mut child_stdin = child.stdin.take();
    let work = async {
        // Fed while the output is read, so a large prompt never blocks on a full pipe.
        let feed = async {
            if let (Some(pipe), Some(text)) = (child_stdin.as_mut(), input.as_deref()) {
                let _ = pipe.write_all(text.as_bytes()).await;
            }
            drop(child_stdin.take());
        };
        let read_out = async {
            let mut s = String::new();
            if let Some(o) = out.as_mut() {
                let _ = o.read_to_string(&mut s).await;
            }
            s
        };
        let read_err = async {
            let mut s = String::new();
            if let Some(e) = err.as_mut() {
                let _ = e.read_to_string(&mut s).await;
            }
            s
        };
        let ((), stdout, stderr) = tokio::join!(feed, read_out, read_err);
        let status = child.wait().await?;
        Ok::<Output, std::io::Error>(Output { success: status.success(), stdout, stderr })
    };
    match tokio::time::timeout(Duration::from_secs(120), work).await {
        Ok(result) => Ok(result?),
        Err(_) => Err(NookError(trf(
            "{name} antwoordde niet binnen twee minuten.",
            "{name} did not answer within two minutes.",
            &[("name", &provider.title())],
        ))),
    }
}

/// The account chosen as default under Settings › Agents, for the agents Nook runs (`CODEX_HOME` and the like).
fn account_environment(provider: AIProvider) -> Vec<(String, String)> {
    let Some(kind) = agent(provider) else { return vec![] };
    let store = crate::agents::profiles::ProfileStore::load(Some(paths::support_directory().join("agent-profiles.json")));
    store.preferred(kind).environment().into_iter().collect()
}

/// One answer from the agent: `system` as its instructions, `message` the whole conversation so far.
pub async fn call(
    provider: AIProvider,
    path: &Path,
    model: &str,
    system: &str,
    message: &str,
    allow_web_search: bool,
    images: &[PromptImage],
) -> Result<String> {
    let run = paths::brain_scratch_directory().join(format!("run-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&run)?;
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(run.clone());

    let mut environment = account_environment(provider);
    // Nook's own thinking: the agent's hooks, if any, leave it out of the bar.
    environment.push(("NOOK_INTERNAL".into(), "1".into()));
    let answer_file = run.join("answer.txt");
    let mut stdin: Option<&str> = None;
    let arguments = match provider {
        AIProvider::GrokCli => {
            environment.push(("GROK_MEMORY".into(), "0".into()));
            grok_arguments(model, system, message, allow_web_search)
        }
        AIProvider::KimiCli => {
            let agent_file = run.join("nook-brain.md");
            std::fs::write(&agent_file, kimi_agent_file(system))?;
            kimi_arguments(model, message, &agent_file.to_string_lossy())
        }
        AIProvider::VibeCli => vibe_arguments(system, message),
        AIProvider::GeminiCli => {
            let settings_file = run.join("settings.json");
            let system_file = run.join("system.md");
            std::fs::write(&settings_file, gemini_settings(allow_web_search).to_string())?;
            std::fs::write(&system_file, system)?;
            environment.push(("GEMINI_CLI_SYSTEM_SETTINGS_PATH".into(), settings_file.to_string_lossy().into_owned()));
            environment.push(("GEMINI_SYSTEM_MD".into(), system_file.to_string_lossy().into_owned()));
            gemini_arguments(model, message)
        }
        _ => {
            use base64::Engine;
            let mut image_paths = vec![];
            for (index, image) in images.iter().enumerate() {
                let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(&image.base64) else { continue };
                let suffix = image.media_type.rsplit('/').next().unwrap_or("png");
                let file = run.join(format!("image-{index}.{suffix}"));
                if std::fs::write(&file, bytes).is_ok() {
                    image_paths.push(file.to_string_lossy().into_owned());
                }
            }
            stdin = Some(message);
            codex_arguments(model, system, allow_web_search, &answer_file.to_string_lossy(), &image_paths)
        }
    };
    let output = execute(path, arguments, &environment, &run, stdin, provider).await?;
    let answer = match provider {
        AIProvider::GeminiCli => match gemini_answer(&output.stdout) {
            Ok(answer) => answer,
            Err(Some(message)) => {
                return Err(NookError(trf(
                    "{name} gaf geen antwoord: {detail}",
                    "{name} did not answer: {detail}",
                    &[("name", &provider.title()), ("detail", &message.chars().take(240).collect::<String>())],
                )))
            }
            Err(None) => return Err(failure(provider, &output.stdout, &output.stderr)),
        },
        AIProvider::GrokCli => grok_answer(&output.stdout).ok_or_else(|| failure(provider, &output.stdout, &output.stderr))?,
        AIProvider::KimiCli => kimi_answer(&output.stdout).ok_or_else(|| failure(provider, &output.stdout, &output.stderr))?,
        AIProvider::VibeCli => {
            if !output.success || output.stdout.trim().is_empty() {
                return Err(failure(provider, &output.stdout, &output.stderr));
            }
            output.stdout
        }
        _ => {
            let answer = std::fs::read_to_string(&answer_file).unwrap_or_default();
            if answer.is_empty() {
                return Err(failure(provider, &output.stdout, &output.stderr));
            }
            answer
        }
    };
    Ok(answer.trim().to_string())
}

/// A conversation with one of these agents. The whole transcript goes along each round.
pub struct CliConversation {
    provider: AIProvider,
    model: String,
    system: String,
    allow_web_search: bool,
    transcript: String,
    images: Vec<PromptImage>,
}

impl CliConversation {
    pub fn new(provider: AIProvider, model: &str, system: &str, prompt: &str, allow_web_search: bool) -> Self {
        Self { provider, model: model.into(), system: system.into(), allow_web_search, transcript: prompt.into(), images: vec![] }
    }

    /// The transcript the next round sends (for tests).
    pub fn transcript(&self) -> &str {
        &self.transcript
    }
}

#[async_trait::async_trait]
impl ModelConversation for CliConversation {
    async fn next(&mut self, tools: &[LoopTool], on_text: OnText<'_>) -> Result<ModelTurn> {
        let path = locate(self.provider).ok_or_else(|| not_installed(self.provider))?;
        let searches = self.allow_web_search && self.provider.cli_searches_web();
        let system = format!("{}\n\n{}", self.system, protocol_text(tools, searches));
        let images = std::mem::take(&mut self.images);
        let text = call(self.provider, &path, &self.model, &system, &self.transcript, searches, &images).await?;
        self.transcript.push_str(&format!("\n\nAssistant:\n{text}"));
        if let Some(cb) = on_text.filter(|_| !text.is_empty()) {
            cb(super::text::visible(&text));
        }
        // Tool calls are written as JSON in the text: the shared loop extracts them.
        Ok(ModelTurn { text, calls: vec![], finished: false })
    }

    fn add_results(&mut self, results: &[ToolResult]) {
        let parts: Vec<String> = results.iter().map(|r| format!("Result of {}:\n{}", r.call.name, r.output)).collect();
        self.transcript.push_str(&format!(
            "\n\n{}\n\nNow respond to the request in natural language, or invoke another tool only if strictly necessary.",
            parts.join("\n\n")
        ));
    }

    fn add_instruction(&mut self, text: &str) {
        self.transcript.push_str(&format!("\n\n{text}"));
    }

    fn attach(&mut self, images: &[PromptImage]) {
        // Codex takes pictures with the prompt; the others only read them as files, which stays off.
        if self.provider.cli_takes_images() {
            self.images = images.to_vec();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::brain::ToolCallRequest;

    fn has_pair(args: &[String], a: &str, b: &str) -> bool {
        args.windows(2).any(|w| w[0] == a && w[1] == b)
    }

    #[test]
    fn codex_runs_locked_down() {
        let args = codex_arguments("", "Be \"Nook\"\nnow", false, "/run/answer.txt", &[]);
        for flag in ["--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check"] {
            assert!(args.contains(&flag.to_string()), "{flag}");
        }
        assert!(has_pair(&args, "-s", "read-only"));
        for feature in ["shell_tool", "unified_exec", "view_image", "plugins", "apps", "multi_agent"] {
            assert!(has_pair(&args, "-c", &format!("features.{feature}=false")));
        }
        assert!(has_pair(&args, "-c", r#"web_search="disabled""#));
        assert!(has_pair(&args, "-c", r#"developer_instructions="Be \"Nook\"\nnow""#));
        assert!(!args.contains(&"-m".to_string()), "no model: the account's default");
        assert_eq!(args.last().unwrap(), "-", "the prompt comes on stdin");
        let web = codex_arguments("gpt-5", "s", true, "/a", &["/img.png".into()]);
        assert!(has_pair(&web, "-c", r#"web_search="live""#) && has_pair(&web, "-m", "gpt-5") && has_pair(&web, "-i", "/img.png"));
    }

    #[test]
    fn gemini_has_no_tools_but_search_when_allowed() {
        let off = gemini_settings(false);
        assert_eq!(off["tools"]["core"], json!(["nook_no_tools"]));
        assert!(off["tools"]["exclude"].as_array().unwrap().contains(&json!("google_web_search")));
        assert!(off["tools"]["exclude"].as_array().unwrap().contains(&json!("run_shell_command")));
        assert_eq!(off["admin"]["mcp"]["enabled"], json!(false));
        let on = gemini_settings(true);
        assert_eq!(on["tools"]["core"], json!(["google_web_search"]));
        assert!(!on["tools"]["exclude"].as_array().unwrap().contains(&json!("google_web_search")));
        let args = gemini_arguments("", "hi");
        assert!(has_pair(&args, "-p", "hi") && has_pair(&args, "-e", "none") && has_pair(&args, "--approval-mode", "default"));
    }

    #[test]
    fn gemini_reply_and_error() {
        assert_eq!(gemini_answer("noise\n{\"response\": \"Hallo\"}\n"), Ok("Hallo".into()));
        assert_eq!(gemini_answer(r#"{"error": {"message": "quota"}}"#), Err(Some("quota".into())));
        assert_eq!(gemini_answer("no json"), Err(None));
    }

    #[test]
    fn grok_denies_everything_but_search() {
        let args = grok_arguments("", "sys", "hi", false);
        assert!(has_pair(&args, "--system-prompt-override", "sys") && has_pair(&args, "--tools", "web_search"));
        for rule in ["Bash", "Read", "Edit", "Write", "Grep", "MCPTool"] {
            assert!(has_pair(&args, "--deny", rule));
        }
        assert!(args.contains(&"--disable-web-search".to_string()) && args.contains(&"--no-subagents".to_string()));
        assert!(!grok_arguments("", "s", "p", true).contains(&"--disable-web-search".to_string()));
        assert_eq!(grok_answer(r#"{"text": "Klaar"}"#).as_deref(), Some("Klaar"));
        assert_eq!(grok_answer(r#"{"result": "Ok"}"#).as_deref(), Some("Ok"));
        assert_eq!(grok_answer(r#"{"text": ""}"#), None);
    }

    #[test]
    fn kimi_runs_as_an_agent_without_tools() {
        let file = kimi_agent_file("Be Nook.");
        assert!(file.contains("tools: []") && file.contains("subagents: []") && file.ends_with("Be Nook.\n"));
        let args = kimi_arguments("", "hi", "/run/nook-brain.md");
        assert!(has_pair(&args, "--agent-file", "/run/nook-brain.md") && has_pair(&args, "--output-format", "stream-json"));
        let stream = [
            r#"{"role":"assistant","content":"Let me look","tool_calls":[{"id":"1"}]}"#,
            r#"{"role":"tool","content":"…"}"#,
            r#"{"role":"assistant","content":[{"type":"text","text":"Het "},{"type":"text","text":"antwoord"}]}"#,
            "not json",
        ]
        .join("\n");
        assert_eq!(kimi_answer(&stream).as_deref(), Some("Het antwoord"));
        assert_eq!(kimi_answer(""), None);
    }

    #[test]
    fn vibe_leads_with_the_instructions() {
        let args = vibe_arguments("Be Nook.", "hi");
        assert_eq!(args[1], "<instructions>\nBe Nook.\n</instructions>\n\nhi");
        assert!(has_pair(&args, "--enabled-tools", "nook_no_tools") && has_pair(&args, "--output", "text"));
    }

    #[test]
    fn failures_say_what_to_do() {
        crate::i18n::set_language("en");
        let p = AIProvider::CodexCli;
        assert!(failure(p, "", "Error: please login first").0.contains("not signed in"));
        assert!(failure(p, "", "error: unexpected argument '--ignore-rules'").0.contains("too old"));
        assert!(failure(p, "usage limit reached", "").0.contains("limit has been reached"));
        assert!(failure(p, "", "boom").0.ends_with("did not answer: boom"));
    }

    #[test]
    fn npm_shims_run_their_script() {
        let shim = "@ECHO off\r\nGOTO start\r\n:find_dp0\r\nSET dp0=%~dp0\r\nEXIT /b\r\n:start\r\nSETLOCAL\r\nCALL :find_dp0\r\n\r\nIF EXIST \"%dp0%\\node.exe\" (\r\n  SET \"_prog=%dp0%\\node.exe\"\r\n) ELSE (\r\n  SET \"_prog=node\"\r\n  SET PATHEXT=%PATHEXT:;.JS;=;%\r\n)\r\n\r\nendLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & \"%_prog%\"  \"%dp0%\\node_modules\\@google\\gemini-cli\\dist\\index.js\" %*\r\n";
        assert_eq!(npm_shim_script(shim).as_deref(), Some("node_modules\\@google\\gemini-cli\\dist\\index.js"));
        assert_eq!(npm_shim_script("@echo off\r\nfoo.exe %*"), None);
    }

    #[test]
    fn toml_strings_are_escaped() {
        assert_eq!(toml_string("a\"b\\c\nd\te"), r#""a\"b\\c\nd\te""#);
        assert_eq!(toml_string("\u{1}"), r#""\u0001""#);
    }

    #[test]
    fn the_protocol_names_every_tool() {
        let tools = [LoopTool::action("send_mail", "Sends a mail.", json!({"properties": {"to": {"type": "string"}}}))];
        let text = protocol_text(&tools, false);
        assert!(text.contains("- send_mail: Sends a mail.") && text.contains("Do not use the web") && text.contains("no shell"));
        assert!(protocol_text(&tools, true).contains("built-in web search"));
        assert!(protocol_text(&[], true).is_empty());
    }

    #[test]
    fn the_transcript_grows_with_results_and_instructions() {
        let mut conversation = CliConversation::new(AIProvider::GeminiCli, "", "sys", "User: hi", false);
        conversation.add_results(&[ToolResult {
            call: ToolCallRequest { id: "1".into(), name: "list_events".into(), input: json!({}) },
            output: "Nothing today".into(),
            is_error: false,
        }]);
        conversation.add_instruction("Answer now.");
        let t = conversation.transcript();
        assert!(t.starts_with("User: hi\n\nResult of list_events:\nNothing today\n\nNow respond"));
        assert!(t.ends_with("\n\nAnswer now."));
        conversation.attach(&[PromptImage { media_type: "image/png".into(), base64: "AAA".into() }]);
        assert!(conversation.images.is_empty(), "Gemini CLI does not get pictures");
        let mut codex = CliConversation::new(AIProvider::CodexCli, "", "s", "p", false);
        codex.attach(&[PromptImage { media_type: "image/png".into(), base64: "AAA".into() }]);
        assert_eq!(codex.images.len(), 1);
    }

    #[test]
    fn agents_nook_runs_share_their_account() {
        assert_eq!(agent(AIProvider::CodexCli), Some(AgentKind::Codex));
        assert_eq!(agent(AIProvider::GrokCli), Some(AgentKind::Grok));
        assert_eq!(agent(AIProvider::KimiCli), None);
    }
}
