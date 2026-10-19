//! De werkruimte-brug (`WorkspaceBridgeProtocol` op de Mac): Nooks eigen terminal, browser en pull requests als tools
//! voor coding-agents. Een agent bereikt ze via een kleine MCP-server (`nook --mcp`, als `~/.nook/nook-mcp`) die elk
//! verzoek over de lokale verbinding aan Nook doorgeeft. Nook beslist wat direct mag en vraagt jou de rest.

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

use super::models::{ExecutionMode, PermissionPolicy};
use crate::agents::risk::RiskLevel;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BridgeTool {
    WorkspaceInfo,
    TerminalRun,
    TerminalRead,
    TerminalList,
    TerminalStop,
    BrowserOpen,
    BrowserRead,
    BrowserScreenshot,
    PullRequestCreate,
    SessionList,
    SessionRead,
}

/// Wat een aanroep kan veranderen: niets, iets zichtbaars op deze computer, of iets daarbuiten.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Effect {
    Read,
    Local,
    Outward,
}

pub const SERVER_NAME: &str = "nook";
/// Het voorvoegsel van Claude Code voor de tools van deze server.
pub const TOOL_PREFIX: &str = "mcp__nook__";

impl BridgeTool {
    pub const ALL: [BridgeTool; 11] = [
        Self::WorkspaceInfo,
        Self::TerminalRun,
        Self::TerminalRead,
        Self::TerminalList,
        Self::TerminalStop,
        Self::BrowserOpen,
        Self::BrowserRead,
        Self::BrowserScreenshot,
        Self::PullRequestCreate,
        Self::SessionList,
        Self::SessionRead,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Self::WorkspaceInfo => "workspace_info",
            Self::TerminalRun => "terminal_run",
            Self::TerminalRead => "terminal_read",
            Self::TerminalList => "terminal_list",
            Self::TerminalStop => "terminal_stop",
            Self::BrowserOpen => "browser_open",
            Self::BrowserRead => "browser_read",
            Self::BrowserScreenshot => "browser_screenshot",
            Self::PullRequestCreate => "pull_request_create",
            Self::SessionList => "session_list",
            Self::SessionRead => "session_read",
        }
    }

    pub fn effect(self) -> Effect {
        match self {
            Self::WorkspaceInfo
            | Self::TerminalRead
            | Self::TerminalList
            | Self::BrowserRead
            | Self::BrowserScreenshot
            | Self::SessionList
            | Self::SessionRead => Effect::Read,
            Self::TerminalRun | Self::TerminalStop | Self::BrowserOpen => Effect::Local,
            Self::PullRequestCreate => Effect::Outward,
        }
    }

    /// De tool achter een naam zoals een agent hem meldt: kaal, of met een MCP-voorvoegsel.
    pub fn named(name: &str) -> Option<Self> {
        let bare = [TOOL_PREFIX, "nook__", "nook."].iter().find_map(|p| name.strip_prefix(p)).unwrap_or(name);
        Self::ALL.into_iter().find(|t| t.name() == bare)
    }

    /// Kort label voor de tijdlijn.
    pub fn label(self) -> &'static str {
        match self {
            Self::WorkspaceInfo => "Nook-werkruimte",
            Self::TerminalRun => "Nook-terminal",
            Self::TerminalRead => "Uitvoer Nook-terminal",
            Self::TerminalList => "Nook-terminals",
            Self::TerminalStop => "Stop Nook-terminal",
            Self::BrowserOpen => "Nook-browser",
            Self::BrowserRead => "Lees Nook-browser",
            Self::BrowserScreenshot => "Screenshot Nook-browser",
            Self::PullRequestCreate => "Pull request",
            Self::SessionList => "Nook-sessies",
            Self::SessionRead => "Lees sessie",
        }
    }

    /// Het meest zeggende argument: het commando, het adres, de titel of de terminal.
    pub fn detail(input: &Value) -> Option<String> {
        ["command", "url", "title", "terminal_id", "session_id"]
            .iter()
            .find_map(|k| input.get(*k).and_then(Value::as_str).filter(|v| !v.is_empty()).map(str::to_string))
    }

    pub fn summary(self) -> &'static str {
        match self {
            Self::WorkspaceInfo => "Describes the workspace Nook gives you: your folder, branch and changes, the terminals open in Nook for this folder, the page in Nook's browser, whether pull requests can be created, and which tools run directly or need the user's approval. Call it once before using the other nook tools.",
            Self::TerminalRun => "Starts a shell command in a new, visible terminal in Nook (the user sees it next to your session). Use it for long-running processes such as dev servers, watchers or test runs in watch mode, and for anything the user should be able to see or take over. Returns a terminal id and the first output; read more with terminal_read. Commands that are not clearly harmless wait for the user's approval; dangerous ones are refused. For short commands whose output you need right away, keep using your own shell.",
            Self::TerminalRead => "Reads the latest output of one of Nook's terminals in your folder, with whether it is still running and its exit code.",
            Self::TerminalList => "Lists Nook's terminals in your folder: id, title, folder, running or exited, and whether you started it.",
            Self::TerminalStop => "Stops the process in a terminal you started with terminal_run (Ctrl-C). With close: true the terminal is also closed.",
            Self::BrowserOpen => "Opens a page in Nook's built-in browser, visible to the user next to your session: https addresses, or http on this computer (localhost, 127.0.0.1) such as the dev server you started. Waits until the page has loaded and reports its title.",
            Self::BrowserRead => "Reads the page open in Nook's browser: title, address, visible text, and console errors and warnings logged since it loaded.",
            Self::BrowserScreenshot => "Takes a screenshot of the page in Nook's browser, to check layout and visual changes. Works best while the browser is visible in Nook.",
            Self::PullRequestCreate => "Proposes a pull request for the current branch of your folder. The user approves it in Nook first; Nook then pushes the branch and opens the pull request on GitHub with the user's own connection (or the GitHub page to finish it). Commit your work before calling this. Returns the link.",
            Self::SessionList => "Lists the user's sessions in Nook (most recent first): id, title, agent, status, folder and branch. Use it to find a session to read with session_read.",
            Self::SessionRead => "Reads a summary of another Nook session: what the user asked, what the agent answered, the commands it ran and the files it changed.",
        }
    }

    pub fn schema(self) -> Value {
        let object = |props: Value, required: &[&str]| json!({"type": "object", "properties": props, "required": required});
        let terminal_id = json!({"type": "string", "description": "The terminal id from terminal_run or terminal_list, such as \"t2\"."});
        match self {
            Self::WorkspaceInfo | Self::TerminalList | Self::BrowserRead => object(json!({}), &[]),
            Self::TerminalRun => object(
                json!({
                    "command": {"type": "string", "description": "The complete shell command, for example \"npm run dev\"."},
                    "cwd": {"type": "string", "description": "Folder to run it in, absolute or relative to your folder. Defaults to your folder."},
                    "title": {"type": "string", "description": "Short title for the terminal tab. Defaults to the command."}
                }),
                &["command"],
            ),
            Self::TerminalRead => object(
                json!({"terminal_id": terminal_id, "lines": {"type": "integer", "description": "How many of the last lines to return (default 80, at most 400)."}}),
                &["terminal_id"],
            ),
            Self::TerminalStop => object(
                json!({"terminal_id": terminal_id, "close": {"type": "boolean", "description": "Also close the terminal tab. Default false."}}),
                &["terminal_id"],
            ),
            Self::BrowserOpen => object(
                json!({"url": {"type": "string", "description": "The address: https://…, or http://localhost:3000 for a local server."}}),
                &["url"],
            ),
            Self::BrowserScreenshot => object(
                json!({"max_width": {"type": "integer", "description": "Maximum width of the image in pixels (default 1280)."}}),
                &[],
            ),
            Self::PullRequestCreate => object(
                json!({
                    "title": {"type": "string", "description": "Title of the pull request."},
                    "body": {"type": "string", "description": "Description in Markdown: what changed and how it was tested."},
                    "base": {"type": "string", "description": "Branch to merge into. Defaults to the session's base branch or the repository's default branch."},
                    "draft": {"type": "boolean", "description": "Open as draft. Default true."}
                }),
                &["title"],
            ),
            Self::SessionList => {
                object(json!({"limit": {"type": "integer", "description": "How many sessions to return (default 15, at most 50)."}}), &[])
            }
            Self::SessionRead => {
                object(json!({"session_id": {"type": "string", "description": "The session id from session_list."}}), &["session_id"])
            }
        }
    }

    /// De tool zoals `tools/list` hem beschrijft.
    pub fn definition(self) -> Value {
        json!({
            "name": self.name(),
            "description": self.summary(),
            "inputSchema": self.schema(),
            "annotations": {"readOnlyHint": self.effect() == Effect::Read, "openWorldHint": self.effect() == Effect::Outward || self == Self::BrowserOpen}
        })
    }
}

/// Label en detail voor de tijdlijn als dit een tool van de brug is.
pub fn describe_tool(tool: &str, input: &Value) -> Option<(String, Option<String>)> {
    if !tool.starts_with(TOOL_PREFIX) {
        return None;
    }
    let t = BridgeTool::named(tool)?;
    Some((t.label().into(), BridgeTool::detail(input)))
}

/// Wie de brug aanroept: een sessie die Nook draait, of een agent in een terminal die de brug zelf koppelde.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BridgeCaller {
    /// Het id van de sessie in Nook, of `None` voor een agent in een terminal.
    pub run: Option<String>,
    pub agent: String,
    pub title: String,
    pub directory: String,
    pub mode: Option<ExecutionMode>,
    pub permission: Option<PermissionPolicy>,
}

impl BridgeCaller {
    /// Wie een terminal bezit: de sessie, of de agent in zijn map.
    pub fn key(&self) -> String {
        match &self.run {
            Some(id) => format!("run:{id}"),
            None => format!("ext:{}:{}", self.agent, self.directory),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Reason {
    /// Agents mogen de werkruimte niet gebruiken (Instellingen).
    Disabled,
    /// De sessie staat in Plan-modus: kijken mag, wijzigen niet.
    PlanMode,
    /// Het commando is gevaarlijk: nooit via de brug.
    Dangerous,
    /// Het commando is niet duidelijk onschuldig.
    NeedsReview,
    /// Het gaat buiten deze computer (een push, een pull request).
    Outward,
}

impl Reason {
    pub fn message(self) -> &'static str {
        match self {
            Self::Disabled => "Agents may not use Nook's workspace: the user switched this off in Nook's settings.",
            Self::PlanMode => "This session is in Plan mode: Nook's tools may only look, not change anything.",
            Self::Dangerous => "Nook refuses this command: it is dangerous (it can delete or overwrite a lot, or reads secrets).",
            Self::NeedsReview => "This command needs the user's approval.",
            Self::Outward => "This goes outside the user's computer and needs the user's approval.",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Allow,
    Ask(Reason),
    Refuse(Reason),
}

/// De regels van de brug, voor elke agent dezelfde. Nook is de poortwachter: de rechten van de agent zelf verruimen
/// Nooks tools nooit.
pub fn verdict(tool: BridgeTool, caller: &BridgeCaller, command: Option<RiskLevel>, enabled: bool) -> Verdict {
    if !enabled {
        return Verdict::Refuse(Reason::Disabled);
    }
    if tool.effect() == Effect::Read {
        return Verdict::Allow;
    }
    if caller.mode == Some(ExecutionMode::Plan) {
        return Verdict::Refuse(Reason::PlanMode);
    }
    match tool {
        BridgeTool::PullRequestCreate => Verdict::Ask(Reason::Outward),
        BridgeTool::TerminalRun => match command.unwrap_or(RiskLevel::Review) {
            RiskLevel::Danger => Verdict::Refuse(Reason::Dangerous),
            RiskLevel::Safe => Verdict::Allow,
            RiskLevel::Review if caller.permission == Some(PermissionPolicy::Bypass) => Verdict::Allow,
            RiskLevel::Review => Verdict::Ask(Reason::NeedsReview),
        },
        _ => Verdict::Allow,
    }
}

/// Welke adressen een agent in Nooks browser mag openen: elke https-pagina, en http alleen op deze computer.
pub fn allowed_url(raw: &str) -> Option<String> {
    let text = raw.trim();
    if text.is_empty() || text.contains(' ') {
        return None;
    }
    let candidate = if text.contains("://") {
        text.to_string()
    } else {
        let host = text.split('/').next().unwrap_or(text);
        let bare = host.split(':').next().unwrap_or(host).to_lowercase();
        format!("{}{text}", if is_loopback(&bare) { "http://" } else { "https://" })
    };
    let (scheme, rest) = candidate.split_once("://")?;
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let authority = authority.rsplit('@').next().unwrap_or(authority);
    let host = if authority.starts_with('[') {
        authority.split(']').next().map(|h| format!("{h}]")).unwrap_or_default()
    } else {
        authority.split(':').next().unwrap_or("").to_string()
    }
    .to_lowercase();
    if host.is_empty() || !host.chars().all(|c| c.is_ascii_alphanumeric() || "-._[]:".contains(c)) {
        return None;
    }
    // Een poort is alleen cijfers ("javascript:alert(1)" is geen adres).
    let port = if authority.starts_with('[') {
        authority.rsplit_once(']').map(|(_, p)| p.strip_prefix(':').unwrap_or(p)).filter(|p| !p.is_empty())
    } else {
        authority.split_once(':').map(|(_, p)| p)
    };
    if let Some(p) = port {
        if p.is_empty() || !p.chars().all(|c| c.is_ascii_digit()) {
            return None;
        }
    }
    match scheme.to_lowercase().as_str() {
        "https" => Some(candidate),
        "http" if is_loopback(&host) => Some(candidate),
        _ => None,
    }
}

pub fn is_loopback(host: &str) -> bool {
    let bare = host.trim_matches(['[', ']']).to_lowercase();
    ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(&bare.as_str()) || bare.ends_with(".localhost")
}

/// Terminaluitvoer zoals een agent hem krijgt: de laatste regels, zonder het lege scherm onder de prompt.
pub fn terminal_tail(text: &str, lines: usize, limit: usize) -> String {
    let mut rows: Vec<&str> = text.split('\n').map(|l| l.trim_end()).collect();
    while rows.last().is_some_and(|r| r.is_empty()) {
        rows.pop();
    }
    let start = rows.len().saturating_sub(lines.max(1));
    let shown = rows[start..].join("\n");
    let count = shown.chars().count();
    if count > limit {
        format!("…{}", shown.chars().skip(count - limit).collect::<String>())
    } else {
        shown
    }
}

/// De toelichting voor de agent, na je eigen instructies.
pub const INSTRUCTIONS: &str = "You are running inside Nook, a desktop app the user is watching while you work. Nook's workspace is available through the `nook` MCP tools: start long-running processes such as dev servers or watchers with terminal_run (the user sees them in Nook's terminal; check their output with terminal_read), open local or https pages in Nook's browser with browser_open and verify them with browser_read or browser_screenshot, and when the work is committed and ready, propose a pull request with pull_request_create (the user approves it in Nook). Short commands whose output you need right away can still run in your own shell.";

/// Hoe een sessie die Nook draait de brug krijgt: de MCP-server op de opdrachtregel van de agent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeLaunch {
    /// Pad van `nook-mcp`.
    pub script: String,
}

impl BridgeLaunch {
    /// Claude Code: de server als `--mcp-config` (naast je eigen servers) en zijn tools vooraf toegestaan, omdat Nook
    /// zelf over elke aanroep beslist.
    pub fn claude_arguments(&self, run_id: &str) -> Vec<String> {
        let config = json!({"mcpServers": {SERVER_NAME: {"type": "stdio", "command": self.script, "args": ["--agent", "claude-code"], "env": {"NOOK_RUN_ID": run_id}}}});
        vec!["--mcp-config".into(), config.to_string(), "--allowedTools".into(), format!("mcp__{SERVER_NAME}")]
    }

    /// Codex: de server als instellingen op de opdrachtregel, met een ruime tijdslimiet (wachten op jouw OK).
    pub fn codex_arguments(&self, run_id: &str) -> Vec<String> {
        let prefix = format!("mcp_servers.{SERVER_NAME}");
        vec![
            "-c".into(),
            format!("{prefix}.command={}", toml(&self.script)),
            "-c".into(),
            format!("{prefix}.args=[{}, {}]", toml("--agent"), toml("codex")),
            "-c".into(),
            format!("{prefix}.env={{ NOOK_RUN_ID = {} }}", toml(run_id)),
            "-c".into(),
            format!("{prefix}.tool_timeout_sec=900"),
        ]
    }
}

/// Een TOML-tekst tussen aanhalingstekens.
pub fn toml(text: &str) -> String {
    let mut out = String::from("\"");
    for c in text.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 || c as u32 == 0x7f => out.push_str(&format!("\\u{:04X}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

pub const PROTOCOL_VERSION: &str = "2025-06-18";

/// De uitkomst van één tool-aanroep: tekst en eventueel een afbeelding.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolResult {
    pub text: String,
    pub image_base64: Option<String>,
    pub image_mime_type: Option<String>,
    pub is_error: bool,
}

impl ToolResult {
    pub fn text(text: impl Into<String>) -> Self {
        Self { text: text.into(), ..Default::default() }
    }

    pub fn error(text: impl Into<String>) -> Self {
        Self { text: text.into(), is_error: true, ..Default::default() }
    }

    pub fn content(&self) -> Value {
        let mut parts = vec![];
        if !self.text.is_empty() {
            parts.push(json!({"type": "text", "text": self.text}));
        }
        if let Some(data) = &self.image_base64 {
            parts.push(
                json!({"type": "image", "data": data, "mimeType": self.image_mime_type.clone().unwrap_or_else(|| "image/jpeg".into())}),
            );
        }
        if parts.is_empty() {
            parts.push(json!({"type": "text", "text": "Done."}));
        }
        Value::Array(parts)
    }
}

/// Wat de MCP-server met één bericht doet: zelf beantwoorden, een tool laten uitvoeren door Nook, of niets
/// (een notificatie zonder id).
pub enum RpcAction {
    Reply(Value),
    Call { id: Value, tool: BridgeTool, arguments: Map<String, Value> },
    Ignore,
}

pub fn handle_rpc(message: &Value) -> RpcAction {
    let Some(id) = message.get("id").filter(|v| !v.is_null()).cloned() else { return RpcAction::Ignore };
    let method = message.get("method").and_then(Value::as_str).unwrap_or("");
    let params = message.get("params").cloned().unwrap_or(json!({}));
    let result = |value: Value| RpcAction::Reply(json!({"jsonrpc": "2.0", "id": id, "result": value}));
    let failure = |code: i64, text: String| RpcAction::Reply(json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": text}}));
    match method {
        "initialize" => {
            let requested = params.get("protocolVersion").and_then(Value::as_str).filter(|v| !v.is_empty()).unwrap_or(PROTOCOL_VERSION);
            result(json!({
                "protocolVersion": requested,
                "capabilities": {"tools": {"listChanged": false}},
                "serverInfo": {"name": SERVER_NAME, "title": "Nook workspace", "version": "1"},
                "instructions": INSTRUCTIONS
            }))
        }
        "ping" => result(json!({})),
        "tools/list" => result(json!({"tools": BridgeTool::ALL.iter().map(|t| t.definition()).collect::<Vec<_>>()})),
        "tools/call" => {
            let name = params.get("name").and_then(Value::as_str).unwrap_or("");
            match BridgeTool::named(name) {
                Some(tool) => RpcAction::Call {
                    id: id.clone(),
                    tool,
                    arguments: params.get("arguments").and_then(Value::as_object).cloned().unwrap_or_default(),
                },
                None => failure(-32602, format!("Unknown tool: {name}")),
            }
        }
        other => failure(-32601, format!("Method not found: {other}")),
    }
}

/// Het antwoord op een tool-aanroep.
pub fn call_response(id: &Value, outcome: &ToolResult) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": {"content": outcome.content(), "isError": outcome.is_error}})
}

#[cfg(test)]
mod tests {
    use super::*;

    fn caller(mode: Option<ExecutionMode>, permission: Option<PermissionPolicy>) -> BridgeCaller {
        BridgeCaller { run: Some("r".into()), agent: "Claude Code".into(), title: "t".into(), directory: "/w".into(), mode, permission }
    }

    #[test]
    fn rules_per_tool_rights_and_risk() {
        let agent = caller(Some(ExecutionMode::Agent), Some(PermissionPolicy::AcceptEdits));
        assert_eq!(verdict(BridgeTool::TerminalRead, &agent, None, true), Verdict::Allow);
        assert_eq!(verdict(BridgeTool::TerminalRun, &agent, Some(RiskLevel::Safe), true), Verdict::Allow);
        assert_eq!(verdict(BridgeTool::TerminalRun, &agent, Some(RiskLevel::Review), true), Verdict::Ask(Reason::NeedsReview));
        assert_eq!(verdict(BridgeTool::TerminalRun, &agent, Some(RiskLevel::Danger), true), Verdict::Refuse(Reason::Dangerous));
        assert_eq!(verdict(BridgeTool::PullRequestCreate, &agent, None, true), Verdict::Ask(Reason::Outward));
        let bypass = caller(Some(ExecutionMode::Agent), Some(PermissionPolicy::Bypass));
        assert_eq!(verdict(BridgeTool::TerminalRun, &bypass, Some(RiskLevel::Review), true), Verdict::Allow);
        assert_eq!(verdict(BridgeTool::TerminalRun, &bypass, Some(RiskLevel::Danger), true), Verdict::Refuse(Reason::Dangerous));
        assert_eq!(verdict(BridgeTool::PullRequestCreate, &bypass, None, true), Verdict::Ask(Reason::Outward), "altijd jouw OK");
        let plan = caller(Some(ExecutionMode::Plan), Some(PermissionPolicy::Bypass));
        assert_eq!(verdict(BridgeTool::BrowserRead, &plan, None, true), Verdict::Allow);
        assert_eq!(verdict(BridgeTool::BrowserOpen, &plan, None, true), Verdict::Refuse(Reason::PlanMode));
        assert_eq!(verdict(BridgeTool::TerminalRun, &plan, Some(RiskLevel::Safe), true), Verdict::Refuse(Reason::PlanMode));
        assert_eq!(verdict(BridgeTool::WorkspaceInfo, &agent, None, false), Verdict::Refuse(Reason::Disabled));
    }

    #[test]
    fn browser_addresses() {
        assert_eq!(allowed_url("localhost:3000").as_deref(), Some("http://localhost:3000"));
        assert_eq!(allowed_url("https://example.com/x").as_deref(), Some("https://example.com/x"));
        assert_eq!(allowed_url("example.com").as_deref(), Some("https://example.com"));
        assert_eq!(allowed_url("http://app.localhost:5173").as_deref(), Some("http://app.localhost:5173"));
        assert!(allowed_url("http://example.com").is_none());
        assert!(allowed_url("file:///etc/passwd").is_none());
        assert!(allowed_url("javascript:alert(1)").is_none());
        assert!(allowed_url("http://localhost.evil.com").is_none());
        assert!(allowed_url("").is_none());
    }

    #[test]
    fn launch_arguments() {
        let b = BridgeLaunch { script: "/h/.nook/nook-mcp".into() };
        let c = b.claude_arguments("run-1");
        assert_eq!(c[0], "--mcp-config");
        let config: Value = serde_json::from_str(&c[1]).unwrap();
        assert_eq!(config["mcpServers"]["nook"]["env"]["NOOK_RUN_ID"], "run-1");
        assert_eq!(c[3], "mcp__nook");
        let x = b.codex_arguments("run-1");
        assert!(x.contains(&"mcp_servers.nook.command=\"/h/.nook/nook-mcp\"".to_string()));
        assert!(x.contains(&"mcp_servers.nook.tool_timeout_sec=900".to_string()));
        assert_eq!(toml("a\"b\\c"), "\"a\\\"b\\\\c\"");
    }

    #[test]
    fn json_rpc() {
        let RpcAction::Reply(init) =
            handle_rpc(&json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26"}}))
        else {
            panic!()
        };
        assert_eq!(init["result"]["protocolVersion"], "2025-03-26");
        assert!(matches!(handle_rpc(&json!({"jsonrpc": "2.0", "method": "notifications/initialized"})), RpcAction::Ignore));
        let RpcAction::Reply(list) = handle_rpc(&json!({"id": 2, "method": "tools/list"})) else { panic!() };
        assert_eq!(list["result"]["tools"].as_array().unwrap().len(), BridgeTool::ALL.len());
        let RpcAction::Call { tool, arguments, .. } =
            handle_rpc(&json!({"id": 3, "method": "tools/call", "params": {"name": "terminal_run", "arguments": {"command": "ls"}}}))
        else {
            panic!()
        };
        assert_eq!(tool, BridgeTool::TerminalRun);
        assert_eq!(arguments["command"], "ls");
        let RpcAction::Reply(bad) = handle_rpc(&json!({"id": 4, "method": "tools/call", "params": {"name": "nope"}})) else { panic!() };
        assert_eq!(bad["error"]["code"], -32602);
        let shot = ToolResult { text: String::new(), image_base64: Some("AAA".into()), image_mime_type: None, is_error: false };
        assert_eq!(call_response(&json!(5), &shot)["result"]["content"][0]["type"], "image");
        assert_eq!(BridgeTool::named("mcp__nook__browser_open"), Some(BridgeTool::BrowserOpen));
        assert_eq!(terminal_tail("a\nb\nc\n\n  \n", 2, 100), "b\nc");
    }
}
