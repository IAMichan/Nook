# Nook Workspace for Coding Agents

Coding agents (such as Claude Code and Codex) can use Nook's integrated workspace directly: start long-running dev servers in a visible Nook terminal, open and inspect pages in Nook's built-in browser (including console errors and screenshots), delegate subtasks to other agents, and propose pull requests that you approve right in the notch.

Agents connect through a lightweight local MCP server (`nook-mcp`) that forwards requests over a user-only Unix domain socket to Nook. Sessions started inside Nook receive it automatically; external terminal sessions can be linked with one click in **Settings › Workspace**.

## Core Principles

1. **Always Visible.** Anything an agent starts or opens via Nook appears right beside its session in the **Agents** tab: its terminal (badged with the agent's icon) and the workspace browser (*"Opened by Claude Code"*).
2. **Nook Is the Gatekeeper.** An agent's own CLI flags never bypass Nook's policy. Read-only operations run immediately; commands that are not provably harmless and all pull requests wait for your explicit **Allow**; dangerous commands are always refused (`CommandRisk`). Sessions in **Plan** mode are strictly read-only.
3. **Unified Approval Flow.** Requests appear in the exact same approval card as every other agent prompt (`ApprovalCenter`, `ApprovalView`), both in the notch and inline in the session view, and are recorded in the SQLite audit log (`agent_terminal_run`, `agent_pull_request_create`, …).
4. **Zero External Dependencies.** Like `nook-hook`, `nook-mcp` is a self-contained Perl script (pre-installed on every Mac) communicating over a `0600` Unix domain socket (`bridge.sock`). If Nook is not running, the script responds as an empty MCP server so your agent continues uninterrupted.

## Architecture

```text
Claude Code / Codex ──stdio (MCP)──▶ nook-mcp (Perl) ──bridge.sock──▶ WorkspaceBridge (Nook)
                                                                         │
                     ┌───────────────────────────────────────────────────┼──────────────────────────┐
                     ▼                         ▼                         ▼                          ▼
              BridgePolicy            TerminalStore              BrowserStore            GitService + GitHub
         (allow / ask / refuse)     (visible terminal)   (DOM text, console, screenshot)   (push + pull request)
                     │
                     ▼
              ApprovalCenter ──▶ Approval card in the notch & session view
```

| Component | File | Role |
|---|---|---|
| Protocol, policies, launch args | `Services/Workspace/WorkspaceBridgeProtocol.swift` | `BridgeTool` schemas, `BridgePolicy`, `BridgeURLPolicy`, `BridgeLaunch`, `BridgeRPC` (JSON-RPC). Pure Foundation, fully unit-tested. |
| Argument checks | `Services/Workspace/WorkspaceBridgeArguments.swift` | Validation for scheduled tasks, pull request targets, browser targets and secret names; the `client_request_id` ledger; the browser scripts; secret redaction. Pure Foundation, tested in `WorkspaceBridgeToolsTests`. |
| Newer tools | `Services/Workspace/WorkspaceBridge+Tools.swift` | Scheduled tasks, pull request watch/status, browser click/type/snapshot/wait, `request_secret`. |
| MCP server script | `Services/Workspace/WorkspaceBridgeScript.swift` | Self-contained Perl script `nook-mcp` (`~/Library/Application Support/Nook/`, symlinked at `~/.nook/nook-mcp`). |
| Bridge service | `Services/Workspace/WorkspaceBridge.swift` | Listens on `bridge.sock`, identifies the calling session, enforces `BridgePolicy`, requests approval, and executes tools. |
| Process launcher | `Services/Workspace/AgentProcess.swift` | Automatically attaches `nook-mcp` to sessions launched by Nook. |
| UI integration | `NotchUI/Pills/SessionTools.swift`, `TerminalSessions.swift`, `BrowserView.swift`, `AgentRunPanel.swift` | Activity dots, agent badges on terminal tabs, *"Opened by …"* banner in browser, inline approvals. |

### Connecting External Terminal Agents

For sessions you launch yourself in an external terminal, click **Connect** in **Settings › Workspace** (or run):

```sh
claude mcp add --scope user nook -- ~/.nook/nook-mcp --agent claude-code
codex mcp add nook -- ~/.nook/nook-mcp --agent codex
```

## Available MCP Tools

| Tool | Description | Policy |
|---|---|---|
| `workspace_info` | Working directory, current branch, changed files, active terminals, open browser URL, PR capability, and policy summary. | Immediate |
| `terminal_run` | Starts a command in a new, visible Nook terminal (e.g., dev server, watcher) and returns its terminal ID (`t3`) and initial output. | Safe dev commands: immediate · Other commands: requires approval · Dangerous commands: refused |
| `terminal_read` | Reads recent output lines from a terminal in the same project directory, including running state and exit code. | Immediate |
| `terminal_list` | Lists terminals in the same project directory and which session started them. | Immediate |
| `terminal_stop` | Sends `Ctrl-C` (and optionally closes) a terminal started by the same agent. | Immediate |
| `browser_open` | Opens a URL in Nook's workspace browser and waits for load completion. Allows `https://` and local `http://` (`localhost`, `127.0.0.1`, `*.localhost`). | Immediate |
| `browser_read` | Returns page title, URL, visible text, and console errors/warnings since page load. | Immediate |
| `browser_screenshot` | Captures a JPEG screenshot of the page for layout verification. | Immediate |
| `pull_request_create` | Pushes the branch and opens a pull request via your connected GitHub account (or opens the GitHub compare URL). | Always requires approval |
| `orchestrator_capabilities` | Lists which agents Nook can spawn for delegated subtasks, available models, and current session permissions. | Immediate |
| `delegate_task` | Delegates a focused subtask (`research`, `review`, `design`, `test`, `implementation`) to a child agent session visible beside the parent. | Requires approval (unless session has full access); disabled in Plan mode |
| `task_status` | Returns status (`queued`, `running`, `waiting`, `completed`, `failed`, `cancelled`) and latest output of a delegated task. | Immediate |
| `task_wait` | Waits for up to eight delegated tasks until any one (`mode: any`) or all of them (`mode: all`) have finished or ask a question, at most `timeout_seconds` (default 45, at most 840). Returns each task's state and which are settled; tasks keep running after a timeout and wake the parent when done. | Immediate |
| `task_cancel` | Cancels a delegated task and any subtasks it spawned. | Immediate (disabled in Plan mode) |
| `session_read` | Reads a summary of another Nook session (prompt, answer, commands, changed files) for `@`-mentions. | Immediate |
| `browser_snapshot` | Lists the links, buttons, fields and headings on the page, each interactive one with a ref (`e7`) for `browser_click` / `browser_type`. Password values are never shown. | Immediate |
| `browser_click` | Clicks one element by ref, CSS selector or visible text. | Local pages (`localhost`): immediate · Other sites: requires approval (unless the session has full access); disabled in Plan mode |
| `browser_type` | Types into one field (replace or append, optionally submit its form), firing `input`/`change` so frameworks notice. The typed text is never written to the audit log. | Same as `browser_click` |
| `browser_wait_for` | Waits until text or a selector appears (or is gone), at most 30 seconds. | Immediate |
| `list_scheduled_tasks` | Lists scheduled tasks for the caller's folder or session (`all: true` for every task) with schedule, target, rights, next and last run. | Immediate |
| `schedule_task` | Proposes a scheduled task: every N minutes or at a time on chosen weekdays, in a new session in a folder or as a message to this session. Rights are `ask` or `acceptEdits`, never `bypass` and never more than the caller. Deduplicated by `client_request_id`. | Always requires approval; disabled in Plan mode |
| `update_scheduled_task` | Proposes a change to a task's title, prompt, schedule, rights or on/off state; the card shows the task after the change and before it. | Always requires approval; disabled in Plan mode |
| `run_scheduled_task_now` | Runs a task once with its own prompt; returns `started`, `busy` or `not available`. Deduplicated by `client_request_id`. | Always requires approval; disabled in Plan mode |
| `watch_pull_request` | Turns on the session's existing pull request watch (GitHub / GitLab, see `WorkspaceManager.watchPullRequest`): news goes to the timeline, and failed CI, reviews and comments wake the agent with a message. Kept with the session across restarts; `stop: true` ends it. Sessions Nook started only. | Immediate (disabled in Plan mode) |
| `get_pull_request_status` | Reads state, CI with failed checks, each reviewer's verdict and the comment count, via the same snapshot as the watch. Review and comment texts are left out. | Immediate |
| `request_secret` | Asks for a named secret. The card shows the name and the agent's reason; on **Allow** Nook returns the value kept under `agent-secret.<name>` in its keychain (`SecretStore`), or asks you to paste one (optionally keeping it). The value goes only to the calling session, between `<nook-secret>` markers that Nook's timeline replaces before storing or showing tool output; the audit entry records the name only. | Always requires approval; disabled in Plan mode |

## Multi-Agent Delegation (`delegate_task`)

Delegation rules are implemented in `Delegation.swift` (pure Foundation, tested in `DelegationTests`):

- **No privilege escalation:** Child sessions inherit the parent's mode and permissions (or a narrower subset); requests for broader permissions are refused. A parent in Plan mode cannot spawn an Agent-mode child.
- **Scoped context:** The child session receives only the explicit task prompt and role—never the parent's full conversation history.
- **Bounded depth:** Maximum delegation depth of 2 levels and at most 4 concurrent child tasks per session.
- **Cascading stop:** Stopping a parent session automatically stops all of its active child tasks.

## Security Guarantees

- The socket directory is `0700` and `bridge.sock` is `0600`, with peer UID verification on every connection (`UnixSocketServer`).
- Approval cards display the **entire** command or pull request details (repository, head → base branch, title, body) along with `CommandRisk` warnings.
- Agents cannot send arbitrary keystrokes to an existing interactive shell; they can only start tracked commands via `terminal_run` and read output from terminals in their own project directory.
- Agents can only reach secrets kept under the `agent-secret.` prefix, never Nook's own keys and tokens. The agent's own transcript (outside Nook) does contain a secret it was given.
- A retried call with the same `client_request_id` gets the first answer; a retry while the first call still waits for you gets no second approval card.
- The workspace browser uses an ephemeral data store (no persistent cookies or disk storage across app launches) and blocks `file://` and custom URL schemes.
