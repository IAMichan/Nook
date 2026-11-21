//! De werkruimte-brug (`WorkspaceBridgeProtocol` op de Mac): Nooks eigen terminal, browser en pull requests als tools
//! voor coding-agents. Een agent bereikt ze via een kleine MCP-server (`nook --mcp`, als `~/.nook/nook-mcp`) die elk
//! verzoek over de lokale verbinding aan Nook doorgeeft. Nook beslist wat direct mag en vraagt jou de rest.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use uuid::Uuid;

use super::browser_script;
use super::models::{ExecutionMode, PermissionPolicy, RunProvider};
use super::schedule::{ScheduleRule, ScheduledTask, ScheduledTaskTarget, MINIMUM_INTERVAL_SECONDS};
use crate::agents::risk::RiskLevel;
use crate::i18n::tr;

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
    BrowserSnapshot,
    BrowserClick,
    BrowserType,
    BrowserWaitFor,
    // Delegating to a child session (`delegation`).
    OrchestratorCapabilities,
    DelegateTask,
    TaskStatus,
    TaskWait,
    TaskCancel,
    PullRequestCreate,
    WatchPullRequest,
    GetPullRequestStatus,
    SessionList,
    SessionRead,
    SessionStart,
    SessionSend,
    SessionWait,
    SessionSearch,
    SessionOrganize,
    SessionQuestions,
    // Scheduled tasks (`schedule` / `scheduler`).
    ScheduleTask,
    ListScheduledTasks,
    UpdateScheduledTask,
    RunScheduledTaskNow,
    // Secrets (`secret_files`).
    RequestSecret,
    // Nook itself (`bridge_nook`).
    NookTools,
    NookUse,
    NookChatList,
    NookChatRead,
    NookChatSend,
    // The user's chat apps (`bridge_nook::chat_use`).
    ChatList,
    ChatRead,
    ChatSend,
    TakeOverScreen,
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
    pub const ALL: [BridgeTool; 42] = [
        Self::WorkspaceInfo,
        Self::TerminalRun,
        Self::TerminalRead,
        Self::TerminalList,
        Self::TerminalStop,
        Self::BrowserOpen,
        Self::BrowserRead,
        Self::BrowserScreenshot,
        Self::BrowserSnapshot,
        Self::BrowserClick,
        Self::BrowserType,
        Self::BrowserWaitFor,
        Self::OrchestratorCapabilities,
        Self::DelegateTask,
        Self::TaskStatus,
        Self::TaskWait,
        Self::TaskCancel,
        Self::PullRequestCreate,
        Self::WatchPullRequest,
        Self::GetPullRequestStatus,
        Self::SessionList,
        Self::SessionRead,
        Self::SessionStart,
        Self::SessionSend,
        Self::SessionWait,
        Self::SessionSearch,
        Self::SessionOrganize,
        Self::SessionQuestions,
        Self::ScheduleTask,
        Self::ListScheduledTasks,
        Self::UpdateScheduledTask,
        Self::RunScheduledTaskNow,
        Self::RequestSecret,
        Self::NookTools,
        Self::NookUse,
        Self::NookChatList,
        Self::NookChatRead,
        Self::NookChatSend,
        Self::ChatList,
        Self::ChatRead,
        Self::ChatSend,
        Self::TakeOverScreen,
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
            Self::BrowserSnapshot => "browser_snapshot",
            Self::BrowserClick => "browser_click",
            Self::BrowserType => "browser_type",
            Self::BrowserWaitFor => "browser_wait_for",
            Self::OrchestratorCapabilities => "orchestrator_capabilities",
            Self::DelegateTask => "delegate_task",
            Self::TaskStatus => "task_status",
            Self::TaskWait => "task_wait",
            Self::TaskCancel => "task_cancel",
            Self::PullRequestCreate => "pull_request_create",
            Self::WatchPullRequest => "watch_pull_request",
            Self::GetPullRequestStatus => "get_pull_request_status",
            Self::SessionList => "session_list",
            Self::SessionRead => "session_read",
            Self::SessionStart => "session_start",
            Self::SessionSend => "session_send",
            Self::SessionWait => "session_wait",
            Self::SessionSearch => "session_search",
            Self::SessionOrganize => "session_organize",
            Self::SessionQuestions => "session_questions",
            Self::ScheduleTask => "schedule_task",
            Self::ListScheduledTasks => "list_scheduled_tasks",
            Self::UpdateScheduledTask => "update_scheduled_task",
            Self::RunScheduledTaskNow => "run_scheduled_task_now",
            Self::RequestSecret => "request_secret",
            t @ (Self::NookTools
            | Self::NookUse
            | Self::NookChatList
            | Self::NookChatRead
            | Self::NookChatSend
            | Self::ChatList
            | Self::ChatRead
            | Self::ChatSend
            | Self::TakeOverScreen) => super::bridge_nook::name(t),
        }
    }

    pub fn effect(self) -> Effect {
        match self {
            Self::WorkspaceInfo
            | Self::TerminalRead
            | Self::TerminalList
            | Self::BrowserRead
            | Self::BrowserScreenshot
            | Self::OrchestratorCapabilities
            | Self::TaskStatus
            | Self::TaskWait
            | Self::BrowserSnapshot
            | Self::BrowserWaitFor
            | Self::GetPullRequestStatus
            | Self::SessionList
            | Self::SessionRead
            | Self::SessionWait
            | Self::SessionSearch
            | Self::ListScheduledTasks => Effect::Read,
            Self::SessionStart
            | Self::SessionSend
            | Self::SessionOrganize
            | Self::SessionQuestions
            | Self::ScheduleTask
            | Self::UpdateScheduledTask
            | Self::RunScheduledTaskNow
            | Self::WatchPullRequest
            | Self::RequestSecret
            | Self::TerminalRun
            | Self::TerminalStop
            | Self::BrowserOpen
            | Self::BrowserClick
            | Self::BrowserType
            | Self::DelegateTask
            | Self::TaskCancel => Effect::Local,
            Self::PullRequestCreate => Effect::Outward,
            t @ (Self::NookTools
            | Self::NookUse
            | Self::NookChatList
            | Self::NookChatRead
            | Self::NookChatSend
            | Self::ChatList
            | Self::ChatRead
            | Self::ChatSend
            | Self::TakeOverScreen) => super::bridge_nook::effect(t),
        }
    }

    /// De tool achter een naam zoals een agent hem meldt: kaal, of met een MCP-voorvoegsel.
    pub fn named(name: &str) -> Option<Self> {
        let bare = [TOOL_PREFIX, "nook__", "nook."].iter().find_map(|p| name.strip_prefix(p)).unwrap_or(name);
        Self::ALL.into_iter().find(|t| t.name() == bare)
    }

    /// Short label for the timeline, in the user's language.
    pub fn label(self) -> &'static str {
        match self {
            Self::WorkspaceInfo => tr("Nook-werkruimte", "Nook workspace"),
            Self::TerminalRun => tr("Nook-terminal", "Nook terminal"),
            Self::TerminalRead => tr("Uitvoer Nook-terminal", "Nook terminal output"),
            Self::TerminalList => tr("Nook-terminals", "Nook terminals"),
            Self::TerminalStop => tr("Stop Nook-terminal", "Stop Nook terminal"),
            Self::BrowserOpen => tr("Nook-browser", "Nook browser"),
            Self::BrowserRead => tr("Lees Nook-browser", "Read Nook browser"),
            Self::BrowserScreenshot => tr("Screenshot Nook-browser", "Nook browser screenshot"),
            Self::BrowserSnapshot => tr("Elementen Nook-browser", "Nook browser elements"),
            Self::BrowserClick => tr("Klik in Nook-browser", "Click in Nook browser"),
            Self::BrowserType => tr("Typ in Nook-browser", "Type in Nook browser"),
            Self::BrowserWaitFor => tr("Wacht op Nook-browser", "Wait for Nook browser"),
            Self::OrchestratorCapabilities => tr("Agents om aan te delegeren", "Agents to delegate to"),
            Self::DelegateTask => tr("Taak delegeren", "Delegate task"),
            Self::TaskStatus => tr("Stand van taak", "Task status"),
            Self::TaskWait => tr("Wacht op taken", "Wait for tasks"),
            Self::TaskCancel => tr("Stop taak", "Stop task"),
            Self::PullRequestCreate => tr("Pull request", "Pull request"),
            Self::WatchPullRequest => tr("Volg pull request", "Watch pull request"),
            Self::GetPullRequestStatus => tr("Status pull request", "Pull request status"),
            Self::SessionList => tr("Nook-sessies", "Nook sessions"),
            Self::SessionRead => tr("Lees sessie", "Read session"),
            Self::SessionStart => tr("Start sessies", "Start sessions"),
            Self::SessionSend => tr("Bericht aan sessie", "Message to session"),
            Self::SessionWait => tr("Wacht op sessies", "Wait for sessions"),
            Self::SessionSearch => tr("Zoek in sessies", "Search sessions"),
            Self::SessionOrganize => tr("Organiseer sessies", "Organize sessions"),
            Self::SessionQuestions => tr("Vragen van sessies", "Session questions"),
            Self::ScheduleTask => tr("Taak inplannen", "Schedule task"),
            Self::ListScheduledTasks => tr("Geplande taken", "Scheduled tasks"),
            Self::UpdateScheduledTask => tr("Geplande taak aanpassen", "Update scheduled task"),
            Self::RunScheduledTaskNow => tr("Geplande taak nu uitvoeren", "Run scheduled task now"),
            Self::RequestSecret => tr("Geheim opvragen", "Request secret"),
            t @ (Self::NookTools
            | Self::NookUse
            | Self::NookChatList
            | Self::NookChatRead
            | Self::NookChatSend
            | Self::ChatList
            | Self::ChatRead
            | Self::ChatSend
            | Self::TakeOverScreen) => super::bridge_nook::label(t),
        }
    }

    /// Het meest zeggende argument: het commando, het adres, de titel of de terminal.
    pub fn detail(input: &Value) -> Option<String> {
        [
            "command",
            "url",
            "title",
            "name",
            "query",
            "action",
            "terminal_id",
            "session_id",
            "task_id",
            "task",
            "tool",
            "message",
            "reason",
            "chat",
            "to",
            "ref",
            "selector",
            "text",
        ]
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
            Self::BrowserSnapshot => "Lists interactive elements on Nook's browser page with refs (e.g. \"e7\") for browser_click and browser_type. Re-snapshot after page changes.",
            Self::BrowserClick => "Clicks an element in Nook's browser by ref (preferred), selector or text. Direct on localhost; other sites need approval unless full rights.",
            Self::BrowserType => "Types into a field in Nook's browser by ref, selector or text (replaces unless append: true; submit: true submits). Direct on localhost; other sites need approval unless full rights. Never type passwords or secrets the user did not give you for this.",
            Self::BrowserWaitFor => "Waits for text or a CSS selector to appear (or disappear with gone: true) in Nook's browser (default 10s, max 30s).",
            Self::OrchestratorCapabilities => "Lists agents Nook can run for delegate_task (installed status, models, rights), your mode/rights, and delegation limits.",
            Self::DelegateTask => "Delegates a task to a new, visible agent session in your folder (your mode/rights or narrower, never more). The child sees only the task text, not this conversation: write a complete brief. Concurrent file-changing tasks get a git worktree each and return the branch to merge. Returns task_id at once (Nook tells you when it finishes), or waits with wait: true. The user approves unless full rights.",
            Self::TaskStatus => "Reads a delegated task's state (queued, running, waiting, completed, failed, cancelled) and latest summary.",
            Self::TaskWait => "Waits for delegated tasks until any (default) or all finish or ask a question (up to timeout_seconds); tasks keep running on timeout.",
            Self::TaskCancel => "Stops a delegated task and any tasks it delegated.",
            Self::PullRequestCreate => "Proposes a pull request for the current branch of your folder. The user approves it in Nook first; Nook then pushes the branch and opens the pull request through GitHub's API with the user's own connection (or GitHub's page in Nook's browser to finish it). Use this instead of `gh pr create`, also when gh reports a rate limit. Commit your work before calling this. Returns the link.",
            Self::WatchPullRequest => "Starts (or stops with stop: true) watching a pull request or merge request for this session. Nook checks CI, merge conflicts, reviews and merge/close state in the background and wakes this session when something actionable happens.",
            Self::GetPullRequestStatus => "Reads the current status of a pull request or merge request (defaults to the open PR for this folder's branch): state, CI checks, mergeability/conflicts, reviews and comments.",
            Self::SessionList => "Lists the user's sessions in Nook (most recent first): id, title, agent, status, folder and branch. Use it to find a session to read with session_read.",
            Self::SessionStart => "Starts 1-20 top-level sessions (default: beside you; or folder, worktree, or scratch). The user approves unless full rights. Returns their ids. Use delegate_task instead when you need a subtask's result.",
            Self::SessionSend => "Sends a message to another Nook session as an agent, not the user (mode: queue after its turn (default), auto, steer into the running turn, or restart). Prefer queue: steer or restart only when the receiver must change its running work now. The receiver keeps its own task, so ask only what bears on it. The user approves unless full rights. You cannot message yourself.",
            Self::SessionWait => "Waits until any (default) or all listed sessions finish their turn or ask the user a question (up to timeout_seconds).",
            Self::SessionRead => "Reads a summary of another Nook session: what the user asked, what the agent answered, the commands it ran and the files it changed.",
            Self::SessionSearch => "Searches across Nook sessions' titles, folders, branches and conversation timelines, returning matching sessions and redacted excerpts.",
            Self::SessionOrganize => "Organizes Nook sessions: pin, unpin, settle, reopen, snooze, wake, archive, unarchive, mark_unread, mark_read, or rename. Waits for the user's approval unless full rights.",
            Self::SessionQuestions => "Lists or reads pending multiple-choice questions (and read-only notices of pending permission prompts) across Nook sessions, or answers a pending multiple-choice question (never approves permission prompts).",
            Self::ScheduleTask => "Creates a scheduled task in Nook (interval, fixed time, one-shot, or webhook). Always waits for the user's approval in Nook; scheduled runs never get full bypass rights.",
            Self::ListScheduledTasks => "Lists scheduled tasks in Nook (defaults to tasks for your folder or session; pass all: true for all tasks).",
            Self::UpdateScheduledTask => "Updates or deletes an existing scheduled task in Nook (title, prompt, schedule rule, enabled state, rights, or delete: true). Always waits for the user's approval.",
            Self::RunScheduledTaskNow => "Runs a scheduled task once right now. Always waits for the user's approval.",
            Self::RequestSecret => "Asks the user in Nook for a secret (API key, token, password). Always waits for the user's approval. Defaults to delivery: \"file\" so the secret is written to an owner-only temporary file and never enters the conversation history.",
            t @ (Self::NookTools | Self::NookUse | Self::NookChatList | Self::NookChatRead | Self::NookChatSend | Self::ChatList | Self::ChatRead | Self::ChatSend | Self::TakeOverScreen) => super::bridge_nook::summary(t),
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
            Self::BrowserSnapshot => {
                object(json!({"limit": {"type": "integer", "description": "Max elements (default 150, max 400)."}}), &[])
            }
            Self::BrowserClick => object(Value::Object(browser_script::target_properties()), &[]),
            Self::BrowserType => {
                let mut properties = browser_script::target_properties();
                properties.insert("value".into(), json!({"type": "string", "description": "Text to type."}));
                properties
                    .insert("append".into(), json!({"type": "boolean", "description": "Append instead of replacing (default false)."}));
                properties.insert("submit".into(), json!({"type": "boolean", "description": "Submit form after typing (default false)."}));
                object(Value::Object(properties), &["value"])
            }
            Self::BrowserWaitFor => object(
                json!({
                    "text": {"type": "string", "description": "Text to wait for."},
                    "selector": {"type": "string", "description": "CSS selector to wait for."},
                    "gone": {"type": "boolean", "description": "Wait until gone instead (default false)."},
                    "timeout_seconds": {"type": "integer", "description": "Max wait seconds (default 10, max 30)."}
                }),
                &[],
            ),
            Self::OrchestratorCapabilities => object(json!({}), &[]),
            Self::DelegateTask => object(
                json!({
                    "task": {"type": "string", "description": "Complete brief; the child sees nothing of this conversation."},
                    "agent": {"type": "string", "description": "claude, codex, gemini, opencode, cursor, grok or antigravity (default: yours)."},
                    "model": {"type": "string", "description": "Model for agent."},
                    "title": {"type": "string", "description": "Session title (default: first line of task)."},
                    "role": {"type": "string", "enum": ["implementation", "research", "review", "design", "test", "general"], "description": "research, review and design default to Plan mode unless plan: false."},
                    "plan": {"type": "boolean", "description": "Run read-only in Plan mode (default: your mode)."},
                    "rights": {"type": "string", "enum": ["ask", "acceptEdits", "bypass"], "description": "ask, acceptEdits or bypass (never above yours)."},
                    "isolation": {"type": "string", "enum": ["shared", "worktree"], "description": "shared (same folder) or worktree (own branch to merge; auto-selected on concurrent edits)."},
                    "wait": {"type": "boolean", "description": "Wait for completion (default false)."},
                    "timeout_seconds": {"type": "integer", "description": "Max wait seconds (default 45, max 840)."},
                    "client_request_id": {"type": "string", "description": "Idempotency key for retries."}
                }),
                &["task"],
            ),
            Self::TaskStatus | Self::TaskCancel => {
                object(json!({"task_id": {"type": "string", "description": "Task id from delegate_task."}}), &["task_id"])
            }
            Self::TaskWait => object(
                json!({
                    "task_ids": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 8, "description": "Task ids from delegate_task."},
                    "mode": {"type": "string", "enum": ["any", "all"], "description": "any (default) or all."},
                    "timeout_seconds": {"type": "integer", "description": "Max wait seconds (default 45, max 840)."}
                }),
                &["task_ids"],
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
            Self::WatchPullRequest => object(
                json!({
                    "url": {"type": "string", "description": "Pull request or merge request URL (defaults to the open PR for this folder's branch)."},
                    "repository": {"type": "string", "description": "Repository in owner/repo format (used with number)."},
                    "number": {"type": "integer", "description": "Pull request or merge request number."},
                    "stop": {"type": "boolean", "description": "Stop watching the pull request for this session. Default false."}
                }),
                &[],
            ),
            Self::GetPullRequestStatus => object(
                json!({
                    "url": {"type": "string", "description": "Pull request or merge request URL (defaults to the open PR for this folder's branch)."},
                    "repository": {"type": "string", "description": "Repository in owner/repo format (used with number)."},
                    "number": {"type": "integer", "description": "Pull request or merge request number."}
                }),
                &[],
            ),
            Self::SessionList => {
                object(json!({"limit": {"type": "integer", "description": "How many sessions to return (default 15, at most 50)."}}), &[])
            }
            Self::SessionRead => {
                object(json!({"session_id": {"type": "string", "description": "The session id from session_list."}}), &["session_id"])
            }
            Self::SessionStart => object(
                json!({
                    "task": {"type": "string", "description": "Self-contained first message."},
                    "title": {"type": "string", "description": "Session title (default: from the task)."},
                    "agent": {"type": "string", "description": "Agent id (default: Nook's default agent)."},
                    "model": {"type": "string", "description": "Model id (default: the agent's)."},
                    "plan": {"type": "boolean", "description": "Start in Plan mode."},
                    "sessions": {"type": "array", "minItems": 1, "maxItems": 20, "items": {"type": "object"}, "description": "Batch of session objects with task, title, agent, model, plan."},
                    "folder": {"type": "string", "description": "Absolute folder path (default: yours)."},
                    "worktree": {"type": "boolean", "description": "Create a new git worktree per session."},
                    "base": {"type": "string", "description": "Worktree base ref (e.g. origin/main)."},
                    "scratch": {"type": "boolean", "description": "Start in a scratch folder."},
                    "client_request_id": {"type": "string", "description": "Idempotency key for retries."}
                }),
                &[],
            ),
            Self::SessionSend => object(
                json!({
                    "session_id": {"type": "string", "description": "Session id from session_list."},
                    "message": {"type": "string", "description": "Self-contained message."},
                    "mode": {"type": "string", "enum": ["auto", "queue", "steer", "restart"], "description": "queue (default), auto, steer or restart."},
                    "client_request_id": {"type": "string", "description": "A retry sends nothing twice."}
                }),
                &["session_id", "message"],
            ),
            Self::SessionWait => object(
                json!({
                    "session_ids": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 8, "description": "Session ids."},
                    "mode": {"type": "string", "enum": ["any", "all"], "description": "any (default) or all."},
                    "timeout_seconds": {"type": "integer", "description": "Max wait seconds (default 45, max 840)."}
                }),
                &["session_ids"],
            ),
            Self::SessionSearch => object(
                json!({
                    "query": {"type": "string", "description": "Text to search for across session titles, folders, branches and conversation timelines."},
                    "session_id": {"type": "string", "description": "Restrict search to one session id."},
                    "project": {"type": "string", "description": "Filter by project name or path substring."},
                    "limit": {"type": "integer", "description": "Maximum sessions to return (default 10, max 25)."},
                    "include_archived": {"type": "boolean", "description": "Include archived sessions (default false, or true when session_id is passed)."}
                }),
                &["query"],
            ),
            Self::SessionOrganize => object(
                json!({
                    "session_id": {"type": "string", "description": "Session id from session_list."},
                    "session_ids": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 20, "description": "Multiple session ids (all except rename)."},
                    "action": {"type": "string", "enum": ["pin", "unpin", "settle", "reopen", "snooze", "wake", "archive", "unarchive", "mark_unread", "mark_read", "rename"], "description": "Action to perform."},
                    "title": {"type": "string", "description": "New session title when action is rename."},
                    "hours": {"type": "integer", "description": "Hours to snooze (1-168) when action is snooze."},
                    "until": {"type": "string", "description": "When action is snooze: tonight, tomorrow, next_week, or an ISO-8601 timestamp."}
                }),
                &["action"],
            ),
            Self::SessionQuestions => object(
                json!({
                    "action": {"type": "string", "enum": ["list", "read", "answer"], "description": "list (default), read (when session_id given) or answer (when answers given)."},
                    "session_id": {"type": "string", "description": "Session id to inspect or answer."},
                    "request_id": {"type": "string", "description": "Specific pending question request_id (defaults to the first pending question in that session)."},
                    "answers": {"type": "object", "description": "Object mapping question keys (\"q1\", \"q2\", or question header) to the chosen option label or array of labels."}
                }),
                &[],
            ),
            Self::ScheduleTask => object(
                json!({
                    "title": {"type": "string", "description": "Short task title."},
                    "prompt": {"type": "string", "description": "Prompt the scheduled session runs."},
                    "rule": {"type": "string", "enum": ["interval", "fixed_time", "once", "webhook"], "description": "Schedule type (inferred automatically when every_minutes/daily_at/once_at is given)."},
                    "every_minutes": {"type": "integer", "description": "Repeat every N minutes (minimum 1)."},
                    "every_hours": {"type": "integer", "description": "Repeat every N hours."},
                    "interval_seconds": {"type": "integer", "description": "Repeat every N seconds (minimum 60)."},
                    "daily_at": {"type": "string", "description": "Local wall-clock time HH:MM (24h), e.g. \"09:00\"."},
                    "weekdays": {"type": "array", "items": {"type": "string"}, "description": "Optional weekdays for fixed_time (sun..sat or 1..7; empty = every day)."},
                    "once_at": {"type": "string", "description": "ISO-8601 timestamp for a one-shot task."},
                    "folder": {"type": "string", "description": "Folder for new-session runs (default: your folder)."},
                    "session_id": {"type": "string", "description": "Existing session id to send each run to instead of starting a new session."},
                    "fresh": {"type": "boolean", "description": "When targeting an existing session, start a fresh conversation per run (default false)."},
                    "agent": {"type": "string", "description": "Agent id for new-session runs (default: Nook's default agent)."},
                    "rights": {"type": "string", "enum": ["ask", "acceptEdits"], "description": "Rights for scheduled runs: ask (default) or acceptEdits (never bypass)."},
                    "enabled": {"type": "boolean", "description": "Start enabled (default true)."},
                    "client_request_id": {"type": "string", "description": "Idempotency key for retries."}
                }),
                &["prompt"],
            ),
            Self::ListScheduledTasks => object(
                json!({
                    "all": {"type": "boolean", "description": "Return all scheduled tasks instead of only those for your folder/session (default false)."}
                }),
                &[],
            ),
            Self::UpdateScheduledTask => object(
                json!({
                    "task_id": {"type": "string", "description": "Scheduled task id from list_scheduled_tasks or schedule_task."},
                    "title": {"type": "string", "description": "New title."},
                    "prompt": {"type": "string", "description": "New prompt."},
                    "rule": {"type": "string", "enum": ["interval", "fixed_time", "once", "webhook"], "description": "Updated schedule rule type."},
                    "every_minutes": {"type": "integer", "description": "Updated interval in minutes."},
                    "every_hours": {"type": "integer", "description": "Updated interval in hours."},
                    "interval_seconds": {"type": "integer", "description": "Updated interval in seconds."},
                    "daily_at": {"type": "string", "description": "Updated local time HH:MM."},
                    "weekdays": {"type": "array", "items": {"type": "string"}, "description": "Updated weekdays for fixed_time."},
                    "once_at": {"type": "string", "description": "Updated ISO-8601 timestamp for once."},
                    "enabled": {"type": "boolean", "description": "Enable or pause the task."},
                    "rights": {"type": "string", "enum": ["ask", "acceptEdits"], "description": "Updated rights (ask or acceptEdits)."},
                    "delete": {"type": "boolean", "description": "Delete this scheduled task (default false)."}
                }),
                &["task_id"],
            ),
            Self::RunScheduledTaskNow => object(
                json!({
                    "task_id": {"type": "string", "description": "Scheduled task id from list_scheduled_tasks or schedule_task."}
                }),
                &["task_id"],
            ),
            Self::RequestSecret => object(
                json!({
                    "name": {"type": "string", "description": "Short secret identifier (e.g. OPENAI_API_KEY, NPM_TOKEN). 1-64 ASCII letters, digits, ., _, -."},
                    "reason": {"type": "string", "description": "Plain-language explanation shown to the user of why this secret is needed."},
                    "delivery": {"type": "string", "enum": ["file", "value"], "description": "file (default, owner-only temp file so the value stays out of chat history) or value (inline)."},
                    "sign_in_url": {"type": "string", "description": "Optional https:// URL where the user can create or copy the token."}
                }),
                &["name", "reason"],
            ),
            t @ (Self::NookTools
            | Self::NookUse
            | Self::NookChatList
            | Self::NookChatRead
            | Self::NookChatSend
            | Self::ChatList
            | Self::ChatRead
            | Self::ChatSend
            | Self::TakeOverScreen) => super::bridge_nook::schema(t),
        }
    }

    /// De tool zoals `tools/list` hem beschrijft.
    pub fn definition(self) -> Value {
        json!({
            "name": self.name(),
            "description": self.summary(),
            "inputSchema": self.schema(),
            "annotations": {"readOnlyHint": self.effect() == Effect::Read, "openWorldHint": self.effect() == Effect::Outward || matches!(self, Self::BrowserOpen | Self::BrowserClick | Self::BrowserType | Self::WatchPullRequest | Self::GetPullRequestStatus)}
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
    /// Another agent gets a task (`delegate_task`).
    Delegation,
    /// Creating, editing or running a scheduled task always asks the user.
    Schedule,
    /// Handing a secret to an agent always asks the user.
    Secret,
}

impl Reason {
    pub fn message(self) -> &'static str {
        match self {
            Self::Disabled => "Agents may not use Nook's workspace: the user switched this off in Nook's settings.",
            Self::PlanMode => "This session is in Plan mode: Nook's tools may only look, not change anything.",
            Self::Dangerous => "Nook refuses this command: it is dangerous (it can delete or overwrite a lot, or reads secrets).",
            Self::NeedsReview => "This command needs the user's approval.",
            Self::Outward => "This goes outside the user's computer and needs the user's approval.",
            Self::Delegation => "Handing a task to another agent needs the user's approval.",
            Self::Schedule => "Changing or running a scheduled task always needs the user's approval.",
            Self::Secret => "Sharing a secret with an agent always needs the user's approval.",
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
    if super::bridge_nook::TOOLS.contains(&tool) {
        return super::bridge_nook::verdict(tool, caller, true);
    }
    if tool.effect() == Effect::Read {
        return Verdict::Allow;
    }
    if caller.mode == Some(ExecutionMode::Plan) {
        return Verdict::Refuse(Reason::PlanMode);
    }
    match tool {
        BridgeTool::PullRequestCreate => Verdict::Ask(Reason::Outward),
        // Scheduling and secret requests ALWAYS require explicit user approval, even under Bypass rights.
        BridgeTool::ScheduleTask | BridgeTool::UpdateScheduledTask | BridgeTool::RunScheduledTaskNow => {
            Verdict::Ask(Reason::Schedule)
        }
        BridgeTool::RequestSecret => Verdict::Ask(Reason::Secret),
        // On a real site a click can send or buy something; `page_verdict` lets the user's own dev server through.
        BridgeTool::BrowserClick | BridgeTool::BrowserType | BridgeTool::SessionOrganize
            if caller.permission == Some(PermissionPolicy::Bypass) =>
        {
            Verdict::Allow
        }
        BridgeTool::BrowserClick | BridgeTool::BrowserType | BridgeTool::SessionOrganize => Verdict::Ask(Reason::NeedsReview),
        // A child never has more rights than its parent, and the user sees it start; with full rights it starts directly.
        BridgeTool::DelegateTask | BridgeTool::SessionStart | BridgeTool::SessionSend
            if caller.permission == Some(PermissionPolicy::Bypass) =>
        {
            Verdict::Allow
        }
        BridgeTool::DelegateTask | BridgeTool::SessionStart | BridgeTool::SessionSend => Verdict::Ask(Reason::Delegation),
        BridgeTool::TerminalRun => match command.unwrap_or(RiskLevel::Review) {
            RiskLevel::Danger => Verdict::Refuse(Reason::Dangerous),
            RiskLevel::Safe => Verdict::Allow,
            RiskLevel::Review if caller.permission == Some(PermissionPolicy::Bypass) => Verdict::Allow,
            RiskLevel::Review => Verdict::Ask(Reason::NeedsReview),
        },
        _ => Verdict::Allow,
    }
}

/// Policy for `session_questions`: listing/reading is always allowed (even in Plan mode), while answering is
/// refused in Plan mode, allowed directly for a caller's own delegated child or under Bypass, and asks otherwise.
pub fn question_verdict(caller: &BridgeCaller, answering: bool, own_task: bool, enabled: bool) -> Verdict {
    if !enabled {
        return Verdict::Refuse(Reason::Disabled);
    }
    if !answering {
        return Verdict::Allow;
    }
    if caller.mode == Some(ExecutionMode::Plan) {
        return Verdict::Refuse(Reason::PlanMode);
    }
    if own_task || caller.permission == Some(PermissionPolicy::Bypass) {
        Verdict::Allow
    } else {
        Verdict::Ask(Reason::Delegation)
    }
}

/// The rule for clicking and typing on a page: the user's own dev server (a loopback address) is a sandbox, so that runs
/// directly; any other site follows `verdict`.
pub fn page_verdict(tool: BridgeTool, caller: &BridgeCaller, page_host: &str, enabled: bool) -> Verdict {
    match verdict(tool, caller, None, enabled) {
        Verdict::Ask(_) if is_loopback(page_host) => Verdict::Allow,
        v => v,
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
pub const INSTRUCTIONS: &str = "You are running inside Nook, a desktop app the user is watching while you work. Nook's workspace is available through the `nook` MCP tools: start long-running processes such as dev servers or watchers with terminal_run (the user sees them in Nook's terminal; check their output with terminal_read), open local or https pages in Nook's browser with browser_open and verify them with browser_read (its text and console), and when the work is committed and ready, propose a pull request with pull_request_create (the user approves it in Nook). You can check or watch a pull request with get_pull_request_status and watch_pull_request, search/organize/inspect other sessions with session_search, session_organize and session_questions, manage scheduled tasks with schedule_task / list_scheduled_tasks / update_scheduled_task / run_scheduled_task_now (changes always ask the user), and ask the user for API keys or tokens safely with request_secret (delivered as an owner-only file by default so the value stays out of chat history). nook_tools and nook_use reach Nook's own tools and connectors (actions wait for the user's approval), chat_list, chat_read and chat_send reach the user's chat apps, nook_chat_list, nook_chat_read and nook_chat_send reach Nook Chat, and take_over_screen lets you read the user's screen for a while. Always open pull requests that way, never with `gh pr create --web` or by opening GitHub's page in the user's browser; when `gh` reports a rate limit, call pull_request_create, which uses GitHub's API instead. Short commands whose output you need right away can still run in your own shell.";

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

// MARK: Scheduled tasks arguments & rendering (AG-09)

/// Parses a weekday name or number (`1` = Sunday .. `7` = Saturday, matching [`ScheduleRule::FixedTime`]).
pub fn parse_weekday(raw: &Value) -> Result<u32, String> {
    if let Some(n) = raw.as_u64() {
        if (1..=7).contains(&n) {
            return Ok(n as u32);
        }
        return Err(format!("Weekday number must be 1 (Sunday) through 7 (Saturday), got {n}."));
    }
    let Some(text) = raw.as_str().map(str::trim).filter(|s| !s.is_empty()) else {
        return Err("Weekdays must be names (sun..sat) or numbers (1..7).".into());
    };
    match text.to_ascii_lowercase().as_str() {
        "1" | "sun" | "sunday" | "zo" | "zondag" => Ok(1),
        "2" | "mon" | "monday" | "ma" | "maandag" => Ok(2),
        "3" | "tue" | "tues" | "tuesday" | "di" | "dinsdag" => Ok(3),
        "4" | "wed" | "wednesday" | "wo" | "woensdag" => Ok(4),
        "5" | "thu" | "thur" | "thurs" | "thursday" | "do" | "donderdag" => Ok(5),
        "6" | "fri" | "friday" | "vr" | "vrijdag" => Ok(6),
        "7" | "sat" | "saturday" | "za" | "zaterdag" => Ok(7),
        other => Err(format!("Unknown weekday \"{other}\". Use sun..sat or 1..7.")),
    }
}

/// Parses an `HH:MM` wall-clock string into `(hour, minute)`.
pub fn parse_clock_time(raw: &str) -> Result<(u32, u32), String> {
    let (h, m) = raw.trim().split_once(':').ok_or_else(|| format!("Time \"{raw}\" must be HH:MM (24-hour), e.g. \"09:00\"."))?;
    let hour: u32 = h.parse().map_err(|_| format!("Invalid hour in \"{raw}\"."))?;
    let minute: u32 = m.parse().map_err(|_| format!("Invalid minute in \"{raw}\"."))?;
    if hour > 23 || minute > 59 {
        return Err(format!("Time \"{raw}\" is out of range (00:00..23:59)."));
    }
    Ok((hour, minute))
}

/// Parses a [`ScheduleRule`] from bridge tool arguments. Returns `Ok(None)` when no rule fields were passed
/// (useful for partial `update_scheduled_task` calls).
pub fn parse_schedule_rule_optional(a: &Map<String, Value>) -> Result<Option<ScheduleRule>, String> {
    let explicit = a.get("rule").and_then(Value::as_str).map(|s| s.trim().to_ascii_lowercase());
    let every_minutes = a.get("every_minutes").and_then(Value::as_i64);
    let every_hours = a.get("every_hours").and_then(Value::as_i64);
    let interval_seconds = a.get("interval_seconds").and_then(Value::as_i64);
    let daily_at = a.get("daily_at").or_else(|| a.get("at_time")).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty());
    let once_at = a.get("once_at").or_else(|| a.get("at")).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty());
    let has_weekdays = a.get("weekdays").is_some();

    let kind = match explicit.as_deref() {
        Some("interval") => Some("interval"),
        Some("fixed_time" | "fixedtime" | "daily") => Some("fixed_time"),
        Some("once") => Some("once"),
        Some("webhook") => Some("webhook"),
        Some(other) => return Err(format!("Unknown schedule rule \"{other}\". Use interval, fixed_time, once or webhook.")),
        None => {
            if interval_seconds.is_some() || every_minutes.is_some() || every_hours.is_some() {
                Some("interval")
            } else if daily_at.is_some() || has_weekdays {
                Some("fixed_time")
            } else if once_at.is_some() {
                Some("once")
            } else {
                None
            }
        }
    };

    let Some(kind) = kind else { return Ok(None) };
    match kind {
        "interval" => {
            let seconds = if let Some(s) = interval_seconds {
                s
            } else if let Some(m) = every_minutes {
                m.saturating_mul(60)
            } else if let Some(h) = every_hours {
                h.saturating_mul(3600)
            } else {
                return Err("Give every_minutes, every_hours or interval_seconds for an interval rule.".into());
            };
            if seconds < MINIMUM_INTERVAL_SECONDS {
                return Err(format!("Interval must be at least {MINIMUM_INTERVAL_SECONDS} seconds (1 minute)."));
            }
            if seconds > 365 * 24 * 3600 {
                return Err("Interval cannot exceed 365 days.".into());
            }
            Ok(Some(ScheduleRule::Interval { seconds }))
        }
        "fixed_time" => {
            let clock = daily_at.ok_or("Give daily_at (HH:MM, 24-hour local time) for a fixed_time rule.")?;
            let (hour, minute) = parse_clock_time(clock)?;
            let mut weekdays = Vec::new();
            if let Some(arr) = a.get("weekdays").and_then(Value::as_array) {
                for item in arr {
                    let day = parse_weekday(item)?;
                    if !weekdays.contains(&day) {
                        weekdays.push(day);
                    }
                }
                weekdays.sort_unstable();
            }
            Ok(Some(ScheduleRule::FixedTime { hour, minute, weekdays }))
        }
        "once" => {
            let raw = once_at.ok_or("Give once_at (an ISO-8601 timestamp) for a once rule.")?;
            let parsed = DateTime::parse_from_rfc3339(raw)
                .map_err(|_| format!("once_at \"{raw}\" must be an ISO-8601 timestamp (e.g. 2026-11-22T09:00:00Z)."))?;
            Ok(Some(ScheduleRule::Once { at: parsed.with_timezone(&Utc) }))
        }
        "webhook" => Ok(Some(ScheduleRule::Webhook)),
        _ => unreachable!(),
    }
}

/// Caps scheduled-task permissions: never `Bypass`, never higher than the caller's own rights.
pub fn parse_schedule_permission(
    raw: Option<&Value>,
    caller_permission: Option<PermissionPolicy>,
) -> Result<PermissionPolicy, String> {
    let requested = match raw.and_then(Value::as_str).map(|s| s.trim().to_ascii_lowercase()).as_deref() {
        None | Some("") | Some("ask") => PermissionPolicy::Ask,
        Some("acceptedits" | "accept_edits") => PermissionPolicy::AcceptEdits,
        Some("bypass") => return Err("Scheduled tasks cannot run with bypass rights; use ask or acceptEdits.".into()),
        Some(other) => return Err(format!("Unknown rights \"{other}\". Use ask or acceptEdits.")),
    };
    let capped = match (requested, caller_permission) {
        (PermissionPolicy::AcceptEdits, Some(PermissionPolicy::Ask)) => PermissionPolicy::Ask,
        (req, _) => req,
    };
    Ok(capped)
}

/// Builds a new [`ScheduledTask`] from `schedule_task` arguments.
pub fn parse_schedule_create(
    a: &Map<String, Value>,
    caller_folder: &str,
    default_provider: RunProvider,
    caller_permission: Option<PermissionPolicy>,
    now: DateTime<Utc>,
) -> Result<ScheduledTask, String> {
    let prompt = a.get("prompt").and_then(Value::as_str).map(str::trim).unwrap_or("");
    if prompt.is_empty() {
        return Err("Give the prompt the scheduled task should run in prompt.".into());
    }
    let rule = parse_schedule_rule_optional(a)?
        .ok_or("Give a schedule: every_minutes, every_hours, daily_at (HH:MM), once_at (ISO-8601), or rule: \"webhook\".")?;
    let title = a
        .get("title")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.chars().take(120).collect::<String>())
        .unwrap_or_else(|| super::models::title_from(prompt, 60));

    let target = if let Some(sid) = a.get("session_id").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()) {
        let id = Uuid::parse_str(sid).map_err(|_| format!("{sid} is not a session id from session_list."))?;
        let fresh = a.get("fresh").and_then(Value::as_bool).unwrap_or(false);
        ScheduledTaskTarget::ExistingSession { id, fresh }
    } else {
        let folder = a
            .get("folder")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or(caller_folder);
        if folder.is_empty() {
            return Err("Give folder or session_id for the scheduled task.".into());
        }
        let provider = match a.get("agent").and_then(Value::as_str).map(|s| s.trim().to_ascii_lowercase()).filter(|s| !s.is_empty()) {
            Some(name) => RunProvider::ALL
                .into_iter()
                .find(|p| p.id() == name || p.display_name().to_ascii_lowercase() == name)
                .ok_or_else(|| format!("Unknown agent \"{name}\"."))?,
            None => default_provider,
        };
        ScheduledTaskTarget::NewSession { project_path: folder.to_string(), provider, profile_id: None }
    };

    let permission = parse_schedule_permission(a.get("rights"), caller_permission)?;
    let mut task = ScheduledTask::new(&title, prompt, rule, target, now);
    task.permission = permission;
    task.enabled = a.get("enabled").and_then(Value::as_bool).unwrap_or(true);
    Ok(task)
}

/// Requested mutation on an existing scheduled task (`update_scheduled_task`).
#[derive(Debug, Clone, PartialEq)]
pub enum ScheduleUpdate {
    Delete(Uuid),
    Save(ScheduledTask, Vec<String>),
}

/// Applies `update_scheduled_task` arguments to an existing [`ScheduledTask`], returning the updated task and a list
/// of human-readable changes for the approval card.
pub fn parse_schedule_update(
    a: &Map<String, Value>,
    existing: &ScheduledTask,
    caller_permission: Option<PermissionPolicy>,
) -> Result<ScheduleUpdate, String> {
    if a.get("delete").and_then(Value::as_bool) == Some(true) {
        return Ok(ScheduleUpdate::Delete(existing.id));
    }
    let mut updated = existing.clone();
    let mut changes = Vec::new();
    if let Some(title) = a.get("title").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()) {
        updated.title = title.chars().take(120).collect();
        changes.push(format!("title → {}", updated.title));
    }
    if let Some(prompt) = a.get("prompt").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()) {
        updated.prompt = prompt.to_string();
        changes.push("prompt updated".into());
    }
    if let Some(rule) = parse_schedule_rule_optional(a)? {
        changes.push(format!("schedule → {}", describe_schedule_rule(&rule)));
        updated.rule = rule;
    }
    if let Some(enabled) = a.get("enabled").and_then(Value::as_bool) {
        updated.enabled = enabled;
        changes.push(if enabled { "enabled" } else { "paused" }.into());
    }
    if a.get("rights").is_some() {
        let perm = parse_schedule_permission(a.get("rights"), caller_permission)?;
        updated.permission = perm;
        changes.push(format!("rights → {}", if perm == PermissionPolicy::AcceptEdits { "acceptEdits" } else { "ask" }));
    }
    if changes.is_empty() {
        return Err("Give at least one field to update (title, prompt, rule/every_minutes/daily_at/once_at, enabled, rights) or delete: true.".into());
    }
    Ok(ScheduleUpdate::Save(updated, changes))
}

/// Human-readable description of a [`ScheduleRule`].
pub fn describe_schedule_rule(rule: &ScheduleRule) -> String {
    match rule {
        ScheduleRule::Interval { seconds } => {
            if *seconds % 3600 == 0 {
                let h = seconds / 3600;
                format!("every {h} hour{}", if h == 1 { "" } else { "s" })
            } else if *seconds % 60 == 0 {
                let m = seconds / 60;
                format!("every {m} minute{}", if m == 1 { "" } else { "s" })
            } else {
                format!("every {seconds} seconds")
            }
        }
        ScheduleRule::FixedTime { hour, minute, weekdays } => {
            let days = if weekdays.is_empty() {
                "every day".to_string()
            } else {
                let names = ["?", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
                weekdays
                    .iter()
                    .filter_map(|d| names.get(*d as usize).copied())
                    .collect::<Vec<_>>()
                    .join(", ")
            };
            format!("{hour:02}:{minute:02} ({days})")
        }
        ScheduleRule::Once { at } => format!("once at {}", at.to_rfc3339()),
        ScheduleRule::Webhook => "webhook".into(),
        ScheduleRule::Message { .. } => "on matching message".into(),
    }
}

/// Formats one scheduled task as a compact line for `list_scheduled_tasks` / confirmations.
pub fn render_scheduled_task(task: &ScheduledTask) -> String {
    let state = if task.enabled { "enabled" } else { "paused" };
    let target = match &task.target {
        ScheduledTaskTarget::NewSession { project_path, provider, .. } => {
            format!("new {} session in {project_path}", provider.display_name())
        }
        ScheduledTaskTarget::ExistingSession { id, fresh } => {
            format!("session {id}{}", if *fresh { " (fresh)" } else { "" })
        }
        ScheduledTaskTarget::Nook => "Nook Chat".into(),
    };
    let next = task.next_run.map(|t| format!(" · next: {}", t.to_rfc3339())).unwrap_or_default();
    let last = task
        .last_status
        .map(|s| format!(" · last: {s:?}").to_ascii_lowercase())
        .unwrap_or_default();
    format!("- {} · {} · {} · {state} · {target}{next}{last}", task.id, task.title, describe_schedule_rule(&task.rule))
}

/// Formats a list of scheduled tasks, noting when global scheduled tasks are turned off in Settings.
pub fn render_scheduled_tasks(tasks: &[ScheduledTask], scheduled_tasks_enabled: bool) -> String {
    let mut lines = Vec::new();
    if !scheduled_tasks_enabled {
        lines.push("Note: Scheduled tasks are currently switched off globally in Nook (Settings › Automation).".into());
    }
    if tasks.is_empty() {
        lines.push("No scheduled tasks.".into());
    } else {
        lines.push(format!("# Scheduled tasks ({})", tasks.len()));
        for t in tasks {
            lines.push(render_scheduled_task(t));
        }
    }
    lines.join("\n")
}

// MARK: Pull request status & watching (AG-10)

/// Hosting platform for a pull / merge request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PrHost {
    Github,
    GitLab(String),
}

/// Resolved pull request / merge request reference.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PullRequestRef {
    pub host: PrHost,
    /// `owner/repo` on GitHub or `group/project` (possibly nested) on GitLab.
    pub repo: String,
    pub number: i64,
    pub url: String,
}

/// Parsed target from `watch_pull_request` or `get_pull_request_status`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PullRequestTarget {
    /// Detect the open PR/MR for the caller's current git branch.
    Current,
    /// A full URL or `repository` + `number` reference.
    Ref(PullRequestRef),
    /// A bare PR number for the caller's current repository remote.
    Number(i64),
}

/// Parses a GitHub PR URL (`https://github.com/owner/repo/pull/42`) or GitLab MR URL
/// (`https://gitlab.example.com/group/proj/-/merge_requests/42`).
pub fn parse_pr_url(raw: &str) -> Option<PullRequestRef> {
    let url = url::Url::parse(raw.trim()).ok()?;
    if !matches!(url.scheme(), "https" | "http") {
        return None;
    }
    let host = url.host_str()?.to_ascii_lowercase();
    let segments: Vec<&str> = url.path_segments()?.filter(|s| !s.is_empty()).collect();
    if host == "github.com" || host == "www.github.com" {
        if segments.len() >= 4 && segments[2] == "pull" {
            let number: i64 = segments[3].parse().ok()?;
            if number <= 0 {
                return None;
            }
            let repo = format!("{}/{}", segments[0], segments[1]);
            return Some(PullRequestRef {
                host: PrHost::Github,
                url: format!("https://github.com/{repo}/pull/{number}"),
                repo,
                number,
            });
        }
        return None;
    }
    // GitLab: /<group...>/<project>/-/merge_requests/<iid>
    if let Some(dash) = segments.iter().position(|s| *s == "-") {
        if dash >= 2 && segments.get(dash + 1) == Some(&"merge_requests") {
            let number: i64 = segments.get(dash + 2)?.parse().ok()?;
            if number <= 0 {
                return None;
            }
            let repo = segments[..dash].join("/");
            return Some(PullRequestRef {
                host: PrHost::GitLab(host.clone()),
                url: format!("https://{host}/{repo}/-/merge_requests/{number}"),
                repo,
                number,
            });
        }
    }
    None
}

/// Parses `watch_pull_request` / `get_pull_request_status` target arguments.
pub fn parse_pr_target(a: &Map<String, Value>) -> Result<PullRequestTarget, String> {
    if let Some(raw_url) = a.get("url").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()) {
        let parsed = parse_pr_url(raw_url)
            .ok_or_else(|| format!("Unrecognised pull/merge request URL: \"{raw_url}\". Pass a GitHub PR or GitLab MR URL."))?;
        return Ok(PullRequestTarget::Ref(parsed));
    }
    let number = a.get("number").and_then(Value::as_i64);
    let repo = a.get("repository").or_else(|| a.get("repo")).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty());
    match (repo, number) {
        (Some(r), Some(n)) if n > 0 && r.contains('/') => Ok(PullRequestTarget::Ref(PullRequestRef {
            host: PrHost::Github,
            url: format!("https://github.com/{r}/pull/{n}"),
            repo: r.to_string(),
            number: n,
        })),
        (Some(_), None) => Err("Pass number together with repository.".into()),
        (Some(r), Some(_)) => Err(format!("Invalid repository \"{r}\" or pull request number.")),
        (None, Some(n)) if n > 0 => Ok(PullRequestTarget::Number(n)),
        (None, Some(_)) => Err("Pull request number must be a positive integer.".into()),
        (None, None) => Ok(PullRequestTarget::Current),
    }
}

/// One CI check on a pull request snapshot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrCheckSummary {
    pub name: String,
    /// `"passing"`, `"failing"`, `"pending"`, `"skipped"`.
    pub outcome: String,
    pub detail: String,
}

/// One review or comment entry on a pull request snapshot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrReviewSummary {
    pub id: String,
    pub author: String,
    /// e.g. `"APPROVED"`, `"CHANGES_REQUESTED"`, `"COMMENTED"`.
    pub state: String,
    pub body: String,
}

/// Normalized snapshot of a GitHub PR or GitLab MR used both for `get_pull_request_status` and background watching.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PullRequestSnapshot {
    pub repo: String,
    pub number: i64,
    pub title: String,
    pub url: String,
    /// `"open"`, `"draft"`, `"merged"`, `"closed"`.
    pub state: String,
    pub head_branch: String,
    pub base_branch: String,
    pub head_sha: String,
    pub conflicted: bool,
    pub merge_state: String,
    pub checks: Vec<PrCheckSummary>,
    pub reviews: Vec<PrReviewSummary>,
    pub comment_ids: Vec<String>,
}

impl PullRequestSnapshot {
    pub fn is_terminal(&self) -> bool {
        matches!(self.state.as_str(), "merged" | "closed")
    }

    pub fn failing_checks(&self) -> Vec<&str> {
        self.checks.iter().filter(|c| c.outcome == "failing").map(|c| c.name.as_str()).collect()
    }
}

/// Compares two consecutive snapshots of a watched PR and returns actionable change descriptions (empty if nothing
/// changed that needs the agent's attention).
pub fn diff_pr_snapshots(prev: &PullRequestSnapshot, next: &PullRequestSnapshot) -> Vec<String> {
    let mut notes = Vec::new();
    if prev.state != next.state {
        notes.push(format!("State changed: {} → {}", prev.state, next.state));
    }
    if !prev.conflicted && next.conflicted {
        notes.push(format!("Merge conflict detected against {}.", next.base_branch));
    } else if prev.conflicted && !next.conflicted {
        notes.push("Merge conflict resolved.".into());
    }
    let prev_failed: std::collections::HashSet<&str> = prev.failing_checks().into_iter().collect();
    let new_failures: Vec<&str> = next.failing_checks().into_iter().filter(|n| !prev_failed.contains(n)).collect();
    if !new_failures.is_empty() {
        notes.push(format!("CI check(s) failed: {}", new_failures.join(", ")));
    }
    let prev_pending = prev.checks.iter().any(|c| c.outcome == "pending");
    let next_all_passing = !next.checks.is_empty() && next.checks.iter().all(|c| matches!(c.outcome.as_str(), "passing" | "skipped"));
    if prev_pending && next_all_passing && next.failing_checks().is_empty() {
        notes.push("All CI checks are now passing.".into());
    }
    let prev_reviews: std::collections::HashSet<&str> = prev.reviews.iter().map(|r| r.id.as_str()).collect();
    for rev in &next.reviews {
        if !prev_reviews.contains(rev.id.as_str()) {
            let excerpt = if rev.body.trim().is_empty() {
                String::new()
            } else {
                format!(": {}", crate::agents::text::shorten(&super::bridge_nook::shielded(&rev.body), 200))
            };
            notes.push(format!("New review by @{} ({}){excerpt}", rev.author, rev.state));
        }
    }
    let prev_comments: std::collections::HashSet<&str> = prev.comment_ids.iter().map(String::as_str).collect();
    let new_comments = next.comment_ids.iter().filter(|id| !prev_comments.contains(id.as_str())).count();
    if new_comments > 0 {
        notes.push(format!("{new_comments} new comment(s) posted."));
    }
    notes
}

/// Renders a [`PullRequestSnapshot`] as structured Markdown for `get_pull_request_status`.
pub fn render_pr_status(s: &PullRequestSnapshot) -> String {
    let mut lines = vec![
        format!("# {}#{} — {}", s.repo, s.number, s.title),
        format!("URL: {}", s.url),
        format!("State: {} · {} → {}", s.state, s.head_branch, s.base_branch),
    ];
    let merge = if s.conflicted {
        "merge conflict (dirty)".to_string()
    } else if s.merge_state.is_empty() {
        "unknown".to_string()
    } else {
        s.merge_state.clone()
    };
    lines.push(format!("Mergeability: {merge}"));

    lines.push(String::new());
    lines.push("## CI checks".into());
    if s.checks.is_empty() {
        lines.push("- none reported".into());
    } else {
        let passing = s.checks.iter().filter(|c| c.outcome == "passing").count();
        let failing = s.checks.iter().filter(|c| c.outcome == "failing").count();
        let pending = s.checks.iter().filter(|c| c.outcome == "pending").count();
        lines.push(format!("Summary: {passing} passing, {failing} failing, {pending} pending"));
        for c in &s.checks {
            let detail = if c.detail.is_empty() { String::new() } else { format!(" ({})", c.detail) };
            lines.push(format!("- [{}] {}{detail}", c.outcome, c.name));
        }
    }

    lines.push(String::new());
    lines.push(format!("## Reviews ({}) & comments ({})", s.reviews.len(), s.comment_ids.len()));
    if s.reviews.is_empty() {
        lines.push("- no reviews yet".into());
    } else {
        for r in s.reviews.iter().rev().take(10) {
            let body = if r.body.trim().is_empty() {
                String::new()
            } else {
                format!(": {}", crate::agents::text::shorten(&super::bridge_nook::shielded(&r.body), 240))
            };
            lines.push(format!("- @{} ({}){body}", r.author, r.state));
        }
    }
    lines.join("\n")
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
        // Clicking and typing: direct on the user's own dev server, asked elsewhere, never in Plan mode.
        assert_eq!(verdict(BridgeTool::BrowserSnapshot, &plan, None, true), Verdict::Allow);
        assert_eq!(verdict(BridgeTool::BrowserWaitFor, &plan, None, true), Verdict::Allow);
        assert_eq!(page_verdict(BridgeTool::BrowserClick, &agent, "localhost", true), Verdict::Allow);
        assert_eq!(page_verdict(BridgeTool::BrowserType, &agent, "example.com", true), Verdict::Ask(Reason::NeedsReview));
        assert_eq!(page_verdict(BridgeTool::BrowserClick, &bypass, "example.com", true), Verdict::Allow);
        assert_eq!(page_verdict(BridgeTool::BrowserClick, &plan, "localhost", true), Verdict::Refuse(Reason::PlanMode));
        assert_eq!(page_verdict(BridgeTool::BrowserClick, &agent, "localhost", false), Verdict::Refuse(Reason::Disabled));
        // Delegating: asked unless full rights; looking at tasks is reading; stopping your own task runs directly.
        assert_eq!(verdict(BridgeTool::DelegateTask, &agent, None, true), Verdict::Ask(Reason::Delegation));
        assert_eq!(verdict(BridgeTool::DelegateTask, &bypass, None, true), Verdict::Allow);
        assert_eq!(verdict(BridgeTool::DelegateTask, &plan, None, true), Verdict::Refuse(Reason::PlanMode));
        assert_eq!(verdict(BridgeTool::TaskWait, &plan, None, true), Verdict::Allow);
        assert_eq!(verdict(BridgeTool::TaskCancel, &agent, None, true), Verdict::Allow);
        assert_eq!(verdict(BridgeTool::SessionStart, &agent, None, true), Verdict::Ask(Reason::Delegation));
        assert_eq!(verdict(BridgeTool::SessionSend, &bypass, None, true), Verdict::Allow);
        assert_eq!(verdict(BridgeTool::SessionSend, &plan, None, true), Verdict::Refuse(Reason::PlanMode));
        assert_eq!(verdict(BridgeTool::SessionWait, &plan, None, true), Verdict::Allow);
        // AG-06, AG-09, AG-10, AG-11 policies:
        assert_eq!(verdict(BridgeTool::SessionSearch, &plan, None, true), Verdict::Allow);
        assert_eq!(verdict(BridgeTool::SessionOrganize, &agent, None, true), Verdict::Ask(Reason::NeedsReview));
        assert_eq!(verdict(BridgeTool::SessionOrganize, &bypass, None, true), Verdict::Allow);
        assert_eq!(verdict(BridgeTool::SessionOrganize, &plan, None, true), Verdict::Refuse(Reason::PlanMode));
        assert_eq!(question_verdict(&plan, false, false, true), Verdict::Allow);
        assert_eq!(question_verdict(&plan, true, true, true), Verdict::Refuse(Reason::PlanMode));
        assert_eq!(question_verdict(&agent, true, true, true), Verdict::Allow);
        assert_eq!(question_verdict(&agent, true, false, true), Verdict::Ask(Reason::Delegation));
        assert_eq!(question_verdict(&bypass, true, false, true), Verdict::Allow);
        assert_eq!(verdict(BridgeTool::ListScheduledTasks, &plan, None, true), Verdict::Allow);
        assert_eq!(verdict(BridgeTool::ScheduleTask, &bypass, None, true), Verdict::Ask(Reason::Schedule));
        assert_eq!(verdict(BridgeTool::UpdateScheduledTask, &bypass, None, true), Verdict::Ask(Reason::Schedule));
        assert_eq!(verdict(BridgeTool::RunScheduledTaskNow, &bypass, None, true), Verdict::Ask(Reason::Schedule));
        assert_eq!(verdict(BridgeTool::ScheduleTask, &plan, None, true), Verdict::Refuse(Reason::PlanMode));
        assert_eq!(verdict(BridgeTool::GetPullRequestStatus, &plan, None, true), Verdict::Allow);
        assert_eq!(verdict(BridgeTool::WatchPullRequest, &agent, None, true), Verdict::Allow);
        assert_eq!(verdict(BridgeTool::WatchPullRequest, &plan, None, true), Verdict::Refuse(Reason::PlanMode));
        assert_eq!(verdict(BridgeTool::RequestSecret, &bypass, None, true), Verdict::Ask(Reason::Secret));
        assert_eq!(verdict(BridgeTool::RequestSecret, &plan, None, true), Verdict::Refuse(Reason::PlanMode));
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
        assert_eq!(BridgeTool::named("mcp__nook__request_secret"), Some(BridgeTool::RequestSecret));
        assert_eq!(terminal_tail("a\nb\nc\n\n  \n", 2, 100), "b\nc");
    }

    #[test]
    fn schedule_argument_parsing_and_rights_cap() {
        let now = Utc::now();
        let a = json!({
            "title": "Nightly tests",
            "prompt": "Run cargo test and summarize failures",
            "daily_at": "02:30",
            "weekdays": ["mon", "wed", "fri"],
            "rights": "acceptEdits"
        })
        .as_object()
        .unwrap()
        .clone();
        let task = parse_schedule_create(&a, "/repo", RunProvider::Claude, Some(PermissionPolicy::Bypass), now).unwrap();
        assert_eq!(task.title, "Nightly tests");
        assert_eq!(task.rule, ScheduleRule::FixedTime { hour: 2, minute: 30, weekdays: vec![2, 4, 6] });
        assert_eq!(task.permission, PermissionPolicy::AcceptEdits);
        assert!(describe_schedule_rule(&task.rule).contains("02:30"));

        // Caller with Ask rights cannot escalate scheduled task to AcceptEdits.
        let capped = parse_schedule_create(&a, "/repo", RunProvider::Claude, Some(PermissionPolicy::Ask), now).unwrap();
        assert_eq!(capped.permission, PermissionPolicy::Ask);

        // Bypass is always refused for scheduled tasks.
        let mut bad = a.clone();
        bad.insert("rights".into(), json!("bypass"));
        assert!(parse_schedule_create(&bad, "/repo", RunProvider::Claude, Some(PermissionPolicy::Bypass), now).is_err());

        // Interval < 60s is refused.
        let short = json!({"prompt": "hi", "interval_seconds": 10}).as_object().unwrap().clone();
        assert!(parse_schedule_create(&short, "/repo", RunProvider::Claude, None, now).is_err());

        // Update and delete parsing.
        let upd = json!({"enabled": false, "every_hours": 4}).as_object().unwrap().clone();
        let ScheduleUpdate::Save(saved, changes) = parse_schedule_update(&upd, &task, Some(PermissionPolicy::Bypass)).unwrap() else {
            panic!("expected save")
        };
        assert!(!saved.enabled);
        assert_eq!(saved.rule, ScheduleRule::Interval { seconds: 4 * 3600 });
        assert_eq!(changes.len(), 2);

        let del = json!({"delete": true}).as_object().unwrap().clone();
        assert_eq!(parse_schedule_update(&del, &task, None).unwrap(), ScheduleUpdate::Delete(task.id));

        let rendered = render_scheduled_tasks(&[saved], false);
        assert!(rendered.contains("switched off globally") && rendered.contains("Nightly tests"));
    }

    #[test]
    fn pull_request_target_diff_and_render() {
        let gh = parse_pr_url("https://github.com/acme/web/pull/42").unwrap();
        assert_eq!(gh.host, PrHost::Github);
        assert_eq!(gh.repo, "acme/web");
        assert_eq!(gh.number, 42);

        let gl = parse_pr_url("https://gitlab.example.com/team/sub/app/-/merge_requests/19").unwrap();
        assert_eq!(gl.host, PrHost::GitLab("gitlab.example.com".into()));
        assert_eq!(gl.repo, "team/sub/app");
        assert_eq!(gl.number, 19);

        assert!(parse_pr_url("https://example.com/not-a-pr").is_none());
        assert_eq!(parse_pr_target(&Map::new()).unwrap(), PullRequestTarget::Current);
        assert_eq!(parse_pr_target(json!({"number": 7}).as_object().unwrap()).unwrap(), PullRequestTarget::Number(7));
        assert!(parse_pr_target(json!({"repository": "acme/web"}).as_object().unwrap()).is_err());

        let base = PullRequestSnapshot {
            repo: "acme/web".into(),
            number: 42,
            title: "Fix login".into(),
            url: "https://github.com/acme/web/pull/42".into(),
            state: "open".into(),
            head_branch: "fix/login".into(),
            base_branch: "main".into(),
            head_sha: "abc123".into(),
            conflicted: false,
            merge_state: "clean".into(),
            checks: vec![PrCheckSummary { name: "ci/tests".into(), outcome: "pending".into(), detail: "in_progress".into() }],
            reviews: vec![],
            comment_ids: vec![],
        };
        let mut next = base.clone();
        next.conflicted = true;
        next.checks[0].outcome = "failing".into();
        next.reviews.push(PrReviewSummary {
            id: "rev-1".into(),
            author: "alice".into(),
            state: "CHANGES_REQUESTED".into(),
            body: "Please handle empty tokens".into(),
        });
        next.comment_ids.push("c-1".into());

        let diffs = diff_pr_snapshots(&base, &next);
        assert!(diffs.iter().any(|d| d.contains("Merge conflict")));
        assert!(diffs.iter().any(|d| d.contains("ci/tests")));
        assert!(diffs.iter().any(|d| d.contains("alice")));
        assert!(diffs.iter().any(|d| d.contains("1 new comment")));

        let rendered = render_pr_status(&next);
        assert!(rendered.contains("acme/web#42"));
        assert!(rendered.contains("merge conflict"));
        assert!(rendered.contains("[failing] ci/tests"));
        assert!(rendered.contains("@alice (CHANGES_REQUESTED)"));
    }
}
