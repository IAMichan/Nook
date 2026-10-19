# Nook Workspace for Coding Agents

Coding agents (such as Claude Code and Codex) can use Nook's integrated workspace directly: start long-running dev servers in a visible Nook terminal, open and inspect pages in Nook's built-in browser (including console errors and screenshots), delegate subtasks to other agents, and propose pull requests that you approve right in the notch.

Agents connect through a lightweight local MCP server (`nook-mcp`) that forwards requests over a user-only Unix domain socket to Nook. Sessions started inside Nook receive it automatically; external terminal sessions can be linked with one click in **Settings › Agents › Workspace**.

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
| MCP server script | `Services/Workspace/WorkspaceBridgeScript.swift` | Self-contained Perl script `nook-mcp` (`~/Library/Application Support/Nook/`, symlinked at `~/.nook/nook-mcp`). |
| Bridge service | `Services/Workspace/WorkspaceBridge.swift` | Listens on `bridge.sock`, identifies the calling session, enforces `BridgePolicy`, requests approval, and executes tools. |
| Process launcher | `Services/Workspace/AgentProcess.swift` | Automatically attaches `nook-mcp` to sessions launched by Nook. |
| UI integration | `NotchUI/Pills/SessionTools.swift`, `TerminalSessions.swift`, `BrowserView.swift`, `AgentRunPanel.swift` | Activity dots, agent badges on terminal tabs, *"Opened by …"* banner in browser, inline approvals. |

### Connecting External Terminal Agents

For sessions you launch yourself in an external terminal, click **Connect** in **Settings › Agents › Workspace** (or run):

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
| `task_cancel` | Cancels a delegated task and any subtasks it spawned. | Immediate (disabled in Plan mode) |
| `session_read` | Reads a summary of another Nook session (prompt, answer, commands, changed files) for `@`-mentions. | Immediate |

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
- The workspace browser uses an ephemeral data store (no persistent cookies or disk storage across app launches) and blocks `file://` and custom URL schemes.
