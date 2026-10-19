//! De werkruimte-brug (`WorkspaceBridge` op de Mac): Nooks terminal, browser en pull requests voor coding-agents. Agents
//! komen binnen via `nook-mcp`, dat elk MCP-bericht over de lokale verbinding `bridge` doorgeeft.
//!
//! Nook is de poortwachter: lezen gebeurt meteen; een commando alleen meteen als het duidelijk onschuldig is (of de
//! sessie alle rechten heeft), gevaarlijke commando's worden geweigerd, en een pull request wacht altijd op jou. In
//! Plan-modus mag een agent alleen kijken. Alles wat een agent hier doet is zichtbaar en komt in het auditlog.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{DateTime, Utc};
use nook_core::agents::ipc::{self, BoxStream};
use nook_core::agents::models::{AgentApproval, ApprovalOrigin};
use nook_core::agents::risk::{self, RiskLevel};
use nook_core::workspace::bridge::{
    allowed_url, call_response, handle_rpc, verdict, BridgeCaller, BridgeTool, Reason, RpcAction, ToolResult, Verdict,
};
use nook_core::workspace::models::{EventKind, PermissionPolicy, WorkspaceRun};
use nook_core::workspace::paths::{self, Verdict as PathVerdict};
use nook_core::workspace::source_control::{RemoteRepository, SourceControlHost};
use serde_json::{Map, Value};
use tauri::{AppHandle, Emitter, Manager};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use uuid::Uuid;

use super::terminals::{TerminalInfo, TerminalOwner};
use super::WorkspaceState;
use crate::agents::{lock, AgentsState};
use crate::state::AppState;

/// Een verzoek van een agent dat in de balk op jouw beslissing wacht: een commando dat niet duidelijk onschuldig is,
/// of een pull request.
#[derive(Debug, Clone)]
pub struct BridgeRequest {
    pub id: String,
    pub caller: BridgeCaller,
    pub tool: BridgeTool,
    pub title: String,
    /// Alles wat er gaat gebeuren, nooit ingekort: wat je toestaat is wat je zag.
    pub detail: String,
    pub note: String,
    pub created: DateTime<Utc>,
    /// De verbinding van de agent; gaat die dicht (de agent stopte), dan wordt het verzoek ingetrokken.
    pub connection: String,
}

#[derive(Default)]
pub struct Bridge {
    pending: Mutex<Vec<BridgeRequest>>,
    waiters: Mutex<HashMap<String, tokio::sync::oneshot::Sender<bool>>>,
}

/// Hoe lang een verzoek op jou wacht voordat de agent "niet toegestaan" hoort.
const APPROVAL_TIMEOUT: Duration = Duration::from_secs(600);

struct Context {
    agent_id: String,
    cwd: String,
    env: Map<String, Value>,
    connection: String,
}

impl Bridge {
    pub fn pending(&self) -> Vec<BridgeRequest> {
        lock(&self.pending).clone()
    }

    pub fn approval(r: &BridgeRequest) -> AgentApproval {
        AgentApproval {
            id: format!("bridge-{}", r.id),
            origin: ApprovalOrigin::Bridge { request_id: r.id.clone() },
            agent_name: r.caller.agent.clone(),
            project: nook_core::agents::text::project_name(&r.caller.directory),
            tool: r.tool.name().into(),
            title: r.title.clone(),
            command: r.detail.clone(),
            diff: vec![],
            note: r.note.clone(),
            danger: false,
            can_always: false,
            can_terminal: false,
            session_key: r.caller.run.as_ref().map(|id| format!("run:{id}")).unwrap_or_else(|| "bridge".into()),
            created: r.created,
        }
    }

    pub fn decide(&self, app: &AppHandle, id: &str, allow: bool) -> bool {
        self.finish(app, id, allow, if allow { "Toegestaan" } else { "Geweigerd" })
    }

    fn finish(&self, app: &AppHandle, id: &str, allowed: bool, message: &str) -> bool {
        let Some(waiter) = lock(&self.waiters).remove(id) else { return false };
        lock(&self.pending).retain(|r| r.id != id);
        let _ = app.emit("agent-approval-gone", serde_json::json!({"id": format!("bridge-{id}"), "message": message}));
        let _ = waiter.send(allowed);
        true
    }

    async fn ask(
        &self,
        app: &AppHandle,
        caller: &BridgeCaller,
        tool: BridgeTool,
        title: String,
        detail: String,
        note: String,
        connection: &str,
    ) -> bool {
        let id = Uuid::new_v4().simple().to_string()[..8].to_string();
        let request = BridgeRequest {
            id: id.clone(),
            caller: caller.clone(),
            tool,
            title,
            detail,
            note,
            created: Utc::now(),
            connection: connection.into(),
        };
        let (tx, rx) = tokio::sync::oneshot::channel();
        lock(&self.waiters).insert(id.clone(), tx);
        lock(&self.pending).push(request.clone());
        let _ = app.emit("agent-approval", Self::approval(&request));
        crate::agents::open_bar(app);
        match tokio::time::timeout(APPROVAL_TIMEOUT, rx).await {
            Ok(Ok(allowed)) => allowed,
            _ => {
                self.finish(app, &id, false, "Verlopen");
                false
            }
        }
    }

    /// De agent hing op (gestopt, of zijn beurt is voorbij): zijn open verzoeken worden ingetrokken.
    fn connection_closed(&self, app: &AppHandle, connection: &str) {
        let ids: Vec<String> = lock(&self.pending).iter().filter(|r| r.connection == connection).map(|r| r.id.clone()).collect();
        for id in ids {
            self.finish(app, &id, false, "Ingetrokken: de agent stopte");
        }
    }
}

/// Luistert op `bridge`, alleen op desktop en als agents lokaal kunnen draaien.
pub fn listen(app: &AppHandle) {
    let handle = app.clone();
    tauri::async_runtime::spawn(async move {
        let h = handle.clone();
        let on_connection: Arc<dyn Fn(BoxStream) + Send + Sync> = Arc::new(move |stream| {
            tauri::async_runtime::spawn(serve(h.clone(), stream));
        });
        if let Err(e) = ipc::listen(ipc::address("bridge"), on_connection).await {
            log::error!("Werkruimte-brug kon niet luisteren: {e}");
        }
    });
}

async fn serve(app: AppHandle, stream: BoxStream) {
    let (mut reader, mut writer) = tokio::io::split(stream);
    let Some(line) = ipc::read_line(&mut reader, Duration::from_secs(5)).await else { return };
    let Ok(object) = serde_json::from_slice::<Value>(&line) else { return };
    let Some(message) = object.get("message").cloned() else { return };
    let context = Context {
        agent_id: object.get("agent").and_then(Value::as_str).unwrap_or("agent").into(),
        cwd: object.get("cwd").and_then(Value::as_str).unwrap_or("").into(),
        env: object.get("env").and_then(Value::as_object).cloned().unwrap_or_default(),
        connection: Uuid::new_v4().to_string(),
    };
    let closed = async {
        let mut sink = [0u8; 1024];
        loop {
            match reader.read(&mut sink).await {
                Ok(0) | Err(_) => break,
                Ok(_) => continue,
            }
        }
    };
    tokio::pin!(closed);
    let work = respond(&app, &message, &context);
    tokio::pin!(work);
    let reply = tokio::select! {
        r = &mut work => r,
        _ = &mut closed => {
            if let Some(ws) = app.try_state::<WorkspaceState>() {
                ws.bridge.connection_closed(&app, &context.connection);
            }
            return;
        }
    };
    if let Some(reply) = reply {
        let _ = writer.write_all(format!("{reply}\n").as_bytes()).await;
        let _ = writer.flush().await;
        let _ = tokio::time::timeout(Duration::from_secs(2), &mut closed).await;
    }
    let _ = writer.shutdown().await;
}

async fn respond(app: &AppHandle, message: &Value, context: &Context) -> Option<Value> {
    match handle_rpc(message) {
        RpcAction::Ignore => None,
        RpcAction::Reply(v) => Some(v),
        RpcAction::Call { id, tool, arguments } => {
            let outcome = call(app, tool, &arguments, context).await;
            Some(call_response(&id, &outcome))
        }
    }
}

fn workspace(app: &AppHandle) -> Option<tauri::State<'_, WorkspaceState>> {
    app.try_state::<WorkspaceState>()
}

/// De sessie achter een aanroep: de sessie die Nook startte (haar id staat in de omgeving), een sessie die in die map
/// werkt, of een agent die je zelf in een terminal startte en die de brug zelf koppelde.
fn caller(app: &AppHandle, context: &Context) -> Option<BridgeCaller> {
    let ws = workspace(app)?;
    if let Some(run) =
        context.env.get("NOOK_RUN_ID").and_then(Value::as_str).and_then(|r| Uuid::parse_str(r).ok()).and_then(|id| ws.manager.run(id))
    {
        return Some(run_caller(&run));
    }
    let folder = paths::normalize(&context.cwd);
    if folder.is_empty() {
        return None;
    }
    if let Some(run) = ws.manager.runs().into_iter().find(|r| r.status.is_active() && paths::normalize(&r.working_directory) == folder) {
        return Some(run_caller(&run));
    }
    let session = app
        .try_state::<AgentsState>()
        .and_then(|a| a.hub.sessions().into_iter().find(|s| !s.cwd.is_empty() && paths::normalize(&s.cwd) == folder));
    Some(BridgeCaller {
        run: None,
        agent: session.as_ref().map(|s| s.name.clone()).unwrap_or_else(|| display_name(&context.agent_id)),
        title: session.map(|s| s.summary).unwrap_or_default(),
        directory: folder,
        mode: None,
        permission: None,
    })
}

fn run_caller(run: &WorkspaceRun) -> BridgeCaller {
    BridgeCaller {
        run: Some(run.id.to_string()),
        agent: run.provider.display_name().into(),
        title: run.title.clone(),
        directory: run.working_directory.clone(),
        mode: Some(run.mode),
        permission: Some(run.permission),
    }
}

fn display_name(agent: &str) -> String {
    match agent {
        "claude-code" => "Claude Code".into(),
        "codex" => "Codex".into(),
        "" => "Agent".into(),
        other => {
            let mut c = other.chars();
            c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
        }
    }
}

/// Het antwoord bij een geweigerde aanroep, in woorden waar de agent iets mee kan.
fn refusal(reason: Reason) -> &'static str {
    match reason {
        Reason::Disabled => "The user has switched off agent access to Nook's workspace (Settings › Agents › Workspace).",
        Reason::PlanMode => "This session is in Plan mode: it may read, not start processes or open pull requests. Describe the step in your plan instead.",
        Reason::Dangerous => "Nook refuses this command through its terminal because it is dangerous. Ask the user to run it themselves if it is really needed.",
        Reason::NeedsReview | Reason::Outward => "The user did not approve this in Nook.",
    }
}

fn enabled(app: &AppHandle) -> bool {
    workspace(app).map(|w| lock(&w.settings).agent_tools).unwrap_or(false)
}

fn audit(app: &AppHandle, tool: BridgeTool, caller: &BridgeCaller, args: &str, result: &str) {
    if let Some(state) = app.try_state::<AppState>() {
        state.store.audit(&format!("agent_{}", tool.name()), &format!("{} · {args}", caller.agent), result);
    }
}

fn arg<'a>(a: &'a Map<String, Value>, key: &str) -> &'a str {
    a.get(key).and_then(Value::as_str).unwrap_or("").trim()
}

async fn call(app: &AppHandle, tool: BridgeTool, a: &Map<String, Value>, context: &Context) -> ToolResult {
    let Some(caller) = caller(app, context) else {
        return ToolResult::error("Nook could not tell which session this is. Start the agent from a project folder.");
    };
    let result = match tool {
        BridgeTool::WorkspaceInfo => workspace_info(app, &caller).await,
        BridgeTool::TerminalRun => terminal_run(app, a, &caller, context).await,
        BridgeTool::TerminalRead => terminal_read(app, a, &caller),
        BridgeTool::TerminalList => Ok(terminal_list(app, &caller)),
        BridgeTool::TerminalStop => terminal_stop(app, a, &caller),
        BridgeTool::BrowserOpen => browser_open(app, a, &caller).await,
        BridgeTool::BrowserRead => browser_read(app).await,
        BridgeTool::BrowserScreenshot => {
            Err("Nook cannot take a screenshot of its browser on this platform yet. Use browser_read to check the page's text and console instead.".into())
        }
        BridgeTool::PullRequestCreate => pull_request_create(app, a, &caller, context).await,
        BridgeTool::SessionList => Ok(session_list(app, a)),
        BridgeTool::SessionRead => session_read(app, a),
    };
    result.unwrap_or_else(ToolResult::error)
}

fn check(app: &AppHandle, tool: BridgeTool, caller: &BridgeCaller, command: Option<RiskLevel>) -> Verdict {
    verdict(tool, caller, command, enabled(app))
}

// MARK: Werkruimte

async fn workspace_info(app: &AppHandle, caller: &BridgeCaller) -> Result<ToolResult, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let mut lines = vec![format!("# Nook workspace for {}", caller.agent), format!("Folder: {}", caller.directory)];
    let m = ws.manager.clone();
    let dir = caller.directory.clone();
    let git = tauri::async_runtime::spawn_blocking(move || {
        let g = m.git()?;
        let remote = g.remotes(&dir).into_iter().find(|r| r == "origin").or_else(|| g.remotes(&dir).into_iter().next());
        Some((g.current_branch(&dir), g.changed_file_count(&dir), remote.and_then(|r| g.remote_url(&dir, &r))))
    })
    .await
    .ok()
    .flatten();
    if let Some((branch, changed, _)) = &git {
        if let Some(b) = branch {
            lines.push(format!("Branch: {b}"));
        }
        if let Some(base) =
            caller.run.as_ref().and_then(|r| Uuid::parse_str(r).ok()).and_then(|id| ws.manager.run(id)).and_then(|r| r.base_branch)
        {
            lines.push(format!("Base branch: {base}"));
        }
        if let Some(c) = changed {
            lines.push(format!("Uncommitted changes: {c} file(s)"));
        }
    }
    if let (Some(mode), Some(permission)) = (caller.mode, caller.permission) {
        lines.push(format!("Session: mode {}, rights {}", serde_plain(&mode), serde_plain(&permission)));
    }
    lines.push(String::new());
    lines.push("## Terminals in this folder".into());
    let terminals = ws.terminals.in_folder(&caller.directory);
    if terminals.is_empty() {
        lines.push("- none".into());
    }
    for t in &terminals {
        lines.push(format!("- {}", describe(t, caller)));
    }
    let folder = paths::normalize(&caller.directory);
    let servers =
        tauri::async_runtime::spawn_blocking(move || nook_core::workspace::terminal::scan_dev_servers(&folder)).await.unwrap_or_default();
    lines.push(String::new());
    lines.push("## Local servers in this folder".into());
    if servers.is_empty() {
        lines.push("- none listening".into());
    }
    for s in servers {
        lines.push(format!("- {} (pid {}) · {} — open it with browser_open", s.command, s.pid, s.url));
    }
    lines.push(String::new());
    lines.push("## Browser".into());
    let b = ws.browser.state();
    if b.open && !b.url.is_empty() {
        lines.push(format!("- {} · {}{}", b.title, b.url, b.opened_by.map(|a| format!(" (opened by {a})")).unwrap_or_default()));
    } else {
        lines.push("- nothing open".into());
    }
    lines.push(String::new());
    lines.push("## Pull requests".into());
    match git.and_then(|g| g.2).and_then(|u| RemoteRepository::detect(&u)) {
        Some(repo) if repo.host == SourceControlHost::Github && !super::github_tokens(app, &repo.display_name()).is_empty() => lines.push(format!(
            "- {}: pull_request_create pushes the branch and opens the pull request with the user's GitHub connection, after their approval.",
            repo.display_name()
        )),
        Some(repo) => lines.push(format!(
            "- {}: no connection to {} in Nook; pull_request_create pushes the branch and opens the page for the user to finish, after their approval.",
            repo.display_name(),
            repo.host.name()
        )),
        None => lines.push("- this folder has no remote Nook recognises".into()),
    }
    lines.push(String::new());
    lines.push("## Rules".into());
    if !enabled(app) {
        lines.push("- The user has switched agent access off: only reading works.".into());
    } else if caller.mode == Some(nook_core::workspace::models::ExecutionMode::Plan) {
        lines.push("- Plan mode: you can read terminals and the browser, but not start processes or open pull requests.".into());
    } else {
        lines.push("- Reading terminals and the browser, opening pages and stopping your own terminals run directly.".into());
        lines.push(if caller.permission == Some(PermissionPolicy::Bypass) {
            "- Commands run directly; dangerous ones are refused.".into()
        } else {
            "- Clearly harmless commands run directly; others wait for the user's approval; dangerous ones are refused.".into()
        });
        lines.push("- A pull request always waits for the user's approval.".into());
    }
    Ok(ToolResult::text(lines.join("\n")))
}

fn serde_plain<T: serde::Serialize>(v: &T) -> String {
    serde_json::to_value(v).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default()
}

fn describe(t: &TerminalInfo, caller: &BridgeCaller) -> String {
    let mut line = format!("{} · {} · ", t.short_id, t.title);
    if t.running {
        line += "running";
    } else {
        line += "exited";
        if let Some(c) = t.exit_code {
            line += &format!(" ({c})");
        }
    }
    line += &format!(" · {}", t.origin);
    match &t.owner {
        Some(o) if o.key == caller.key() => line += " · started by you",
        Some(o) => line += &format!(" · started by {}", o.agent),
        None => line += " · the user's own terminal",
    }
    line
}

// MARK: Terminal

/// Een map voor een commando: absoluut, `~/…`, of ten opzichte van de map van de aanroeper. Hij moet bestaan en geen
/// systeemmap zijn.
fn resolve_folder(raw: &str, caller: &BridgeCaller) -> Result<String, String> {
    let home = nook_core::agents::home_dir().to_string_lossy().into_owned();
    let base = if caller.directory.is_empty() { home.clone() } else { caller.directory.clone() };
    let mut path = if raw.trim().is_empty() { base.clone() } else { expand_tilde(raw.trim()) };
    if !std::path::Path::new(&path).is_absolute() {
        path = std::path::Path::new(&base).join(&path).to_string_lossy().into_owned();
    }
    let normalized = paths::normalize(&path);
    match paths::verdict(&normalized) {
        PathVerdict::Ok => Ok(normalized),
        PathVerdict::Forbidden if normalized == paths::normalize(&home) => Ok(normalized),
        PathVerdict::Forbidden => Err(format!("Nook does not run commands in system folders ({normalized}).")),
        _ => Err(format!("That folder does not exist: {normalized}")),
    }
}

async fn terminal_run(app: &AppHandle, a: &Map<String, Value>, caller: &BridgeCaller, context: &Context) -> Result<ToolResult, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let command = arg(a, "command");
    if command.is_empty() {
        return Err("Give the command to run.".into());
    }
    let folder = resolve_folder(arg(a, "cwd"), caller)?;
    let assessment = risk::assess(command);
    match check(app, BridgeTool::TerminalRun, caller, Some(assessment.level)) {
        Verdict::Refuse(reason) => {
            audit(app, BridgeTool::TerminalRun, caller, command, &format!("geweigerd: {reason:?}"));
            let extra = if reason == Reason::Dangerous { format!(" ({})", assessment.note) } else { String::new() };
            return Err(format!("{}{extra}", refusal(reason)));
        }
        Verdict::Ask(_) => {
            let note = [nook_core::agents::tilde(&folder), assessment.note.clone()]
                .into_iter()
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(" · ");
            let allowed = ws
                .bridge
                .ask(
                    app,
                    caller,
                    BridgeTool::TerminalRun,
                    format!("{} wil een commando starten in de terminal van Nook", caller.agent),
                    command.into(),
                    note,
                    &context.connection,
                )
                .await;
            if !allowed {
                audit(app, BridgeTool::TerminalRun, caller, command, "niet toegestaan");
                return Err(refusal(Reason::NeedsReview).into());
            }
        }
        Verdict::Allow => {}
    }
    let title = arg(a, "title");
    let title: String = if title.is_empty() { command.chars().take(40).collect() } else { title.chars().take(40).collect() };
    let owner = TerminalOwner { agent: caller.agent.clone(), key: caller.key() };
    let terminal = ws.terminals.open(app, &folder, Some(command), Some(&title), Some(owner))?;
    audit(app, BridgeTool::TerminalRun, caller, command, &terminal.short_id);
    let _ = app.emit("bridge-used", serde_json::json!({"directory": caller.directory, "tool": "terminal"}));
    note_run(app, caller, &format!("Gestart in terminal {}: {command}", terminal.short_id));
    // Even wachten, zodat de agent ziet of het startte (of mislukte) zonder nog een aanroep.
    tokio::time::sleep(Duration::from_secs(2)).await;
    let output = ws.terminals.output(&terminal.id, 40).unwrap_or_default();
    Ok(ToolResult::text(format!(
        "Started in Nook terminal {id} in {folder}; the user can see it next to your session. Read more output with terminal_read {{\"terminal_id\": \"{id}\"}} and stop it with terminal_stop.\n\nOutput so far:\n{}",
        if output.is_empty() { "(nothing yet)".into() } else { output },
        id = terminal.short_id
    )))
}

/// Een terminal die de aanroeper mag zien: een in zijn map (of eronder), of een die hij zelf startte.
fn terminal_for(app: &AppHandle, a: &Map<String, Value>, caller: &BridgeCaller) -> Result<TerminalInfo, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let reference = arg(a, "terminal_id");
    let t = ws
        .terminals
        .find(reference)
        .ok_or_else(|| format!("There is no Nook terminal \"{reference}\". Use terminal_list to see the terminals in your folder."))?;
    let mine = t.owner.as_ref().is_some_and(|o| o.key == caller.key());
    let in_folder = nook_core::workspace::terminal::within(&t.origin, &caller.directory);
    if !mine && !in_folder {
        return Err(format!("Terminal {} belongs to another folder.", t.short_id));
    }
    Ok(t)
}

fn terminal_read(app: &AppHandle, a: &Map<String, Value>, caller: &BridgeCaller) -> Result<ToolResult, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let t = terminal_for(app, a, caller)?;
    let lines = a.get("lines").and_then(Value::as_u64).unwrap_or(80).clamp(1, 400) as usize;
    let state = if t.running {
        "running".to_string()
    } else {
        format!("exited{}", t.exit_code.map(|c| format!(" with code {c}")).unwrap_or_default())
    };
    let output = ws.terminals.output(&t.id, lines).unwrap_or_default();
    Ok(ToolResult::text(format!(
        "Terminal {} · {} · {state}\n\n{}",
        t.short_id,
        t.title,
        if output.is_empty() { "(no output)".into() } else { wrap(&output) }
    )))
}

/// Uitvoer van een terminal is onbetrouwbare data, net als elke tool-uitvoer.
fn wrap(text: &str) -> String {
    nook_core::brain::text::wrap_untrusted(text)
}

fn terminal_list(app: &AppHandle, caller: &BridgeCaller) -> ToolResult {
    let Some(ws) = workspace(app) else { return ToolResult::error("Nook is not ready.") };
    let mut list = ws.terminals.in_folder(&caller.directory);
    for t in ws.terminals.list() {
        if t.owner.as_ref().is_some_and(|o| o.key == caller.key()) && !list.iter().any(|x| x.id == t.id) {
            list.push(t);
        }
    }
    if list.is_empty() {
        return ToolResult::text(format!("No Nook terminals in {}.", caller.directory));
    }
    ToolResult::text(list.iter().map(|t| format!("- {}", describe(t, caller))).collect::<Vec<_>>().join("\n"))
}

fn terminal_stop(app: &AppHandle, a: &Map<String, Value>, caller: &BridgeCaller) -> Result<ToolResult, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let t = terminal_for(app, a, caller)?;
    if !t.owner.as_ref().is_some_and(|o| o.key == caller.key()) {
        return Err(format!("You can only stop terminals you started with terminal_run; {} is not one of them.", t.short_id));
    }
    if let Verdict::Refuse(reason) = check(app, BridgeTool::TerminalStop, caller, None) {
        return Err(refusal(reason).into());
    }
    let _ = ws.terminals.interrupt(&t.id);
    let close = a.get("close").and_then(Value::as_bool).unwrap_or(false);
    if close {
        ws.terminals.close(app, &t.id);
    }
    audit(app, BridgeTool::TerminalStop, caller, t.command.as_deref().unwrap_or(&t.title), if close { "gesloten" } else { "gestopt" });
    Ok(ToolResult::text(if close {
        format!("Stopped and closed terminal {}.", t.short_id)
    } else {
        format!("Sent Ctrl-C to terminal {}; it stays open with its output.", t.short_id)
    }))
}

// MARK: Browser

async fn browser_open(app: &AppHandle, a: &Map<String, Value>, caller: &BridgeCaller) -> Result<ToolResult, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let raw = arg(a, "url");
    let Some(url) = allowed_url(raw) else {
        return Err(format!(
            "Nook's browser opens https addresses, and http only on this computer (localhost, 127.0.0.1). \"{raw}\" is neither."
        ));
    };
    if let Verdict::Refuse(reason) = check(app, BridgeTool::BrowserOpen, caller, None) {
        return Err(refusal(reason).into());
    }
    let failure = ws.browser.load_for(app, &url, &caller.agent, Duration::from_secs(15)).await;
    let _ = app.emit("bridge-used", serde_json::json!({"directory": caller.directory, "tool": "browser"}));
    audit(app, BridgeTool::BrowserOpen, caller, &url, failure.as_deref().unwrap_or("geladen"));
    if let Some(f) = failure {
        return Err(format!("Opened {url} in Nook's browser, but it did not load: {f}"));
    }
    tokio::time::sleep(Duration::from_millis(300)).await;
    let state = ws.browser.state();
    Ok(ToolResult::text(format!(
        "Opened {} in Nook's browser{}. The user can see it next to your session. Check it with browser_read.",
        if state.url.is_empty() { url.clone() } else { state.url.clone() },
        if state.title.is_empty() { String::new() } else { format!(" · {}", state.title) }
    )))
}

async fn browser_read(app: &AppHandle) -> Result<ToolResult, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let page = ws.browser.page_text(app).await?;
    let console = ws.browser.console(app).await;
    let start = console.len().saturating_sub(40);
    let mut text = format!(
        "# {}\nURL: {}\n\n{}",
        page.title,
        page.url,
        if page.text.is_empty() { "(no visible text)".into() } else { nook_core::brain::text::wrap_untrusted(&page.text) }
    );
    text +=
        &format!("\n\n## Console errors and warnings\n{}", if console.is_empty() { "none".into() } else { console[start..].join("\n") });
    Ok(ToolResult::text(text))
}

// MARK: Pull request

async fn pull_request_create(
    app: &AppHandle,
    a: &Map<String, Value>,
    caller: &BridgeCaller,
    context: &Context,
) -> Result<ToolResult, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let title = arg(a, "title").to_string();
    if title.is_empty() {
        return Err("Give the pull request a title.".into());
    }
    let body = a.get("body").and_then(Value::as_str).unwrap_or("").to_string();
    let draft = a.get("draft").and_then(Value::as_bool).unwrap_or(true);
    if let Verdict::Refuse(reason) = check(app, BridgeTool::PullRequestCreate, caller, None) {
        return Err(refusal(reason).into());
    }
    let run = caller.run.as_ref().and_then(|r| Uuid::parse_str(r).ok());
    let session_base = run.and_then(|id| ws.manager.run(id)).and_then(|r| r.base_branch);
    let requested = arg(a, "base").to_string();
    let m = ws.manager.clone();
    let dir = caller.directory.clone();
    let facts = tauri::async_runtime::spawn_blocking(move || {
        let g = m.git()?;
        let remotes = g.remotes(&dir);
        let remote = if remotes.iter().any(|r| r == "origin") {
            "origin".to_string()
        } else {
            remotes.first().cloned().unwrap_or_else(|| "origin".into())
        };
        let base = if requested.is_empty() { session_base.or_else(|| g.default_branch(&dir, &remote)) } else { Some(requested) };
        Some((g.current_branch(&dir), remote.clone(), g.remote_url(&dir, &remote), base, g.changed_file_count(&dir)))
    })
    .await
    .map_err(|e| e.to_string())?
    .ok_or("Git is not available on this computer.")?;
    let (branch, remote, url, base, changed) = facts;
    let branch = branch.ok_or("The folder is not on a branch (detached HEAD). Create a branch first.")?;
    let repo = url.as_deref().and_then(RemoteRepository::detect).ok_or(
        "This folder has no remote Nook recognises (GitHub, GitLab, Bitbucket, Gitea, Forgejo or Azure DevOps), so it cannot open a pull request for it.",
    )?;
    let mut base = base.unwrap_or_default();
    for prefix in ["origin/".to_string(), format!("{remote}/")] {
        if let Some(rest) = base.strip_prefix(&prefix) {
            base = rest.to_string();
        }
    }
    if base.is_empty() {
        return Err("Nook could not tell which branch to merge into; pass base.".into());
    }
    if base == branch {
        return Err(format!("You are on {branch} itself. Work on a separate branch, then propose the pull request."));
    }
    let tokens = super::github_tokens(app, &repo.display_name());
    let via_connector = repo.host == SourceControlHost::Github && !tokens.is_empty();
    let word = if repo.host.uses_merge_requests() { "merge request" } else { "pull request" };
    let mut detail =
        format!("{} · {branch} → {base}{}\n\n{title}", repo.display_name(), if draft && via_connector { " · draft" } else { "" });
    if !body.trim().is_empty() {
        detail += &format!("\n\n{}", body.trim());
    }
    let mut notes = vec![format!("Nook pusht eerst {branch} naar {remote}.")];
    if let Some(c) = changed.filter(|c| *c > 0) {
        notes.push(format!("Let op: {c} bestanden zijn nog niet gecommit en gaan niet mee."));
    }
    if !via_connector {
        notes.push("Er is geen koppeling met deze host: Nook opent daarna de pagina in je browser om af te ronden.".into());
    }
    let allowed = ws
        .bridge
        .ask(
            app,
            caller,
            BridgeTool::PullRequestCreate,
            format!("{} wil een pull request openen", caller.agent),
            detail,
            notes.join(" "),
            &context.connection,
        )
        .await;
    let summary = format!("{} {branch} → {base}", repo.display_name());
    if !allowed {
        audit(app, BridgeTool::PullRequestCreate, caller, &summary, "niet toegestaan");
        return Err(refusal(Reason::Outward).into());
    }
    let m = ws.manager.clone();
    let (dir, r2, b2) = (caller.directory.clone(), remote.clone(), branch.clone());
    tauri::async_runtime::spawn_blocking(move || m.git().ok_or_else(|| "Git ontbreekt".to_string())?.push(&dir, &r2, &b2).map_err(|e| e.0))
        .await
        .map_err(|e| e.to_string())?
        .map_err(|e| {
            audit(app, BridgeTool::PullRequestCreate, caller, &summary, "push mislukt");
            format!("Pushing {branch} to {remote} failed: {e}")
        })?;
    if let Some(id) = run {
        ws.manager.refresh_git(id);
    }
    if !via_connector {
        if let Some(page) = repo.new_pull_request_url(&base, &branch, Some(&title), Some(&body), draft) {
            use tauri_plugin_opener::OpenerExt;
            let _ = app.opener().open_url(page, None::<&str>);
        }
        audit(app, BridgeTool::PullRequestCreate, caller, &summary, &format!("pagina op {} geopend", repo.host_name));
        return Ok(ToolResult::text(format!(
            "Pushed {branch} to {remote}. Nook has no connection to {}, so it opened the page for a new {word} in the user's browser for them to finish it.",
            repo.host_name
        )));
    }
    let link = nook_core::workspace::source_control::create_github_pull_request(
        &tokens,
        &repo.display_name(),
        &title,
        &body,
        &branch,
        &base,
        draft,
    )
    .await?;
    audit(app, BridgeTool::PullRequestCreate, caller, &summary, &link);
    if let Some(id) = run {
        ws.manager.note(id, &format!("Pull request geopend: {link}"));
    }
    Ok(ToolResult::text(format!("Pushed {branch} to {remote} and opened the {word}{}: {link}", if draft { " as draft" } else { "" })))
}

// MARK: Sessies

fn session_list(app: &AppHandle, a: &Map<String, Value>) -> ToolResult {
    let Some(ws) = workspace(app) else { return ToolResult::error("Nook is not ready.") };
    let limit = a.get("limit").and_then(Value::as_u64).unwrap_or(15).clamp(1, 50) as usize;
    let mut runs: Vec<WorkspaceRun> = ws.manager.runs().into_iter().filter(|r| !r.archived).collect();
    runs.sort_by_key(|r| std::cmp::Reverse(r.updated_at));
    if runs.is_empty() {
        return ToolResult::text("No sessions.");
    }
    ToolResult::text(
        runs.iter()
            .take(limit)
            .map(|r| {
                format!(
                    "- {} · {} · {} · {} · {}{}",
                    r.id,
                    r.title,
                    r.provider.display_name(),
                    serde_plain(&r.status),
                    r.working_directory,
                    r.branch.as_ref().map(|b| format!(" · {b}")).unwrap_or_default()
                )
            })
            .collect::<Vec<_>>()
            .join("\n"),
    )
}

/// Een samenvatting van een andere sessie: wat gevraagd, beantwoord, uitgevoerd en gewijzigd werd. Begrensd, nooit
/// het ruwe gesprek.
fn session_read(app: &AppHandle, a: &Map<String, Value>) -> Result<ToolResult, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let run = Uuid::parse_str(arg(a, "session_id"))
        .ok()
        .and_then(|id| ws.manager.run(id))
        .ok_or("No such session. Use the id from the reference the user gave you.")?;
    let events = ws.manager.timeline(run.id);
    let mut lines = vec![
        format!("# Session: {}", run.title),
        format!("Agent: {} · status: {}", run.provider.display_name(), serde_plain(&run.status)),
        format!("Folder: {}", run.working_directory),
    ];
    if let Some(b) = &run.branch {
        lines.push(format!("Branch: {b}"));
    }
    lines.push(String::new());
    let clip = |t: &str, n: usize| nook_core::agents::text::shorten(t, n);
    let mut body = vec![];
    for e in &events {
        match e.kind {
            EventKind::User => body.push(format!("User: {}", clip(&e.text, 600))),
            EventKind::Assistant => body.push(format!("Agent: {}", clip(&e.text, 800))),
            EventKind::Tool if e.tool.as_deref().is_some_and(|t| ["Bash", "shell", "run_shell_command"].contains(&t)) => {
                body.push(format!("Ran: {}", clip(&e.text, 200)))
            }
            EventKind::FileChange => body.push(format!("Changed: {}", e.detail.as_deref().unwrap_or(&e.text))),
            EventKind::Error => body.push(format!("Error: {}", clip(&e.text, 300))),
            _ => {}
        }
    }
    if body.is_empty() {
        lines.push("Nothing has happened in this session yet.".into());
    } else {
        let start = body.len().saturating_sub(60);
        if start > 0 {
            lines.push(format!("({start} earlier items left out)"));
        }
        lines.push(nook_core::brain::text::wrap_untrusted(&body[start..].join("\n")));
    }
    Ok(ToolResult::text(lines.join("\n")))
}

/// Een regel in de tijdlijn van de sessie die de brug gebruikte.
fn note_run(app: &AppHandle, caller: &BridgeCaller, text: &str) {
    let (Some(ws), Some(id)) = (workspace(app), caller.run.as_ref().and_then(|r| Uuid::parse_str(r).ok())) else { return };
    ws.manager.note(id, text);
}

fn expand_tilde(path: &str) -> String {
    match path.strip_prefix("~") {
        Some(rest) if rest.is_empty() || rest.starts_with('/') || rest.starts_with('\\') => {
            format!("{}{rest}", nook_core::agents::home_dir().to_string_lossy())
        }
        _ => path.into(),
    }
}
