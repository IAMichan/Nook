# Connecting Coding Agents to Nook

Nook displays what your AI coding agents are doing right inside the notch. Any agent that can invoke a shell command or write to a Unix domain socket can report to Nook and get its own dedicated session row.

Everything stays on your Mac: events travel over a local Unix socket (`0600`) that only your user account can open. If Nook is not running, the hook script exits cleanly as a no-op and the agent continues without interruption.

## Built-In Integrations

In **Settings › Agents**, you can connect these agents with one click. Nook previews the exact file changes first, creates a timestamped backup next to the configuration file, and writes only after your confirmation. Any file that cannot be read or contains invalid JSON is left untouched, as is any plugin file not created by Nook.

| Agent | Configuration File | Mechanism | What You See |
|---|---|---|---|
| Claude Code | `~/.claude/settings.json` | hooks, `--agent claude-code` | progress, approvals, questions |
| Claude (Desktop app) | same hooks | detected via `CLAUDE_CODE_ENTRYPOINT=claude-desktop` | progress, approvals, questions |
| Claude (cloud) | zero config | session list from your Claude account | status, title, repo; open in Claude |
| Codex | `~/.codex/hooks.json` | hooks, `--agent codex` | progress, approvals |
| Gemini CLI | `~/.gemini/settings.json` | hooks, `--agent gemini` | progress |
| Antigravity (`agy`) | `~/.gemini/config/hooks.json` | dedicated `nook` group, `--agent antigravity`, space-free path via `~/.nook/nook-hook`, no `PreToolUse` | progress |
| Cursor | `~/.cursor/hooks.json` | hooks, `--agent cursor` | progress |
| Copilot CLI | `~/.copilot/hooks/nook.json` | dedicated file, `--agent copilot` | progress |
| Muse Code | `~/.config/muse/settings.json` | hooks, `--agent muse` | progress |
| OpenCode | `~/.config/opencode/plugins/nook.js` | plugin | progress |
| Amp | `~/.config/amp/plugins/nook.ts` | plugin | progress |
| Hermes | `~/.hermes/plugins/nook/` | plugin, then `hermes plugins enable nook` | progress, "waiting for approval" |

Restart the agent after connecting. Inline tool approvals from the notch are supported for Claude Code and Codex; for other hook-based agents, Nook never blocks execution and the agent prompts you in its own UI as usual.

## Supervising & Controlling Agents

If you quit and reopen Nook, agents that kept running in your terminal reappear immediately: Nook persists known hook sessions (`agent-sessions.json`) and restores them, pruning any session whose process has exited on the first scan.

All agent sessions converge in a single registry (`AgentSessionRegistry`): hooks, process scanning, transcripts, and sessions launched by Nook itself are deduplicated so each conversation appears once, while two processes in the same folder remain two separate rows. Internal helper processes spawned by Nook (`NOOK_RUN_ID` or `NOOK_INTERNAL`) are excluded and never terminated.

- **In the Notch** (**Agents** tab, compact view): see what is running and what is waiting for you, approve or deny tool calls, answer multiple-choice questions, and send quick follow-ups. Clicking **New Session** opens the workspace window; accounts are managed in Settings.
- **In the Main Window** (`⌥⌘W` › **Agents**): full conversation timeline, inline approvals, stop (`⌘.`), resume, retry, and per-turn mode, permission, and model controls. The right inspector displays branch, worktree, changed files with diffs, **Commit**, **Push**, and **Pull Request** actions.

Key capabilities:
- **Unified Approvals** (`ApprovalCenter`, `ApprovalView`): shows the complete command or file diff, risk level, and **Allow**, **Always**, **Deny**, or **In Terminal**. Approving in the window or terminal immediately clears the notch card.
- **Running Sessions:** Continue a busy external session safely as a fork (`--fork-session`) so two writers never collide, or choose **Take Over** (`⋯`) to stop the external process and continue the session directly inside Nook.
- **Sessions Managed by Nook ("In Nook"):** Supports Claude Code, Codex, Gemini CLI, OpenCode, Cursor, Grok, and Antigravity with persistent per-session connections: Codex via `codex app-server`, Claude Code via a persistent streaming process, and others via ACP. Includes git checkpoints in isolated worktrees, auto-generated session titles, one-click Commit / Push / PR (always in English), and automatic resume when rate limits reset.
- **Cloud Sessions:** Anthropic cloud sessions (started in the Claude Mac/iOS app or on `claude.ai/code`) are read-only polled at most once per minute using your existing Claude Code login and listed as **Claude (cloud)** with an **Open in Claude** button.
- **Full Transcript & Reasoning:** Reads agent transcripts to show collapsible reasoning steps (`thinking` / `thoughts`), commands, file edits, searches, and subagents inline.

## Nook Workspace MCP for Your Agents

Agents can use Nook's integrated terminal, browser, and PR workflow via a local MCP server (`~/.nook/nook-mcp`): start a dev server in a visible Nook terminal (`terminal_run`, `terminal_read`), open and inspect pages in Nook's browser (`browser_open`, `browser_read`, `browser_screenshot`), and propose a pull request (`pull_request_create`). Sessions started by Nook receive this automatically; external agents can be linked in **Settings › Agents › Workspace**. See [WERKRUIMTE-AGENTS.md](WERKRUIMTE-AGENTS.md).

## Connecting a Custom Agent

### 1. Via the Hook Script (Recommended)

The hook script is installed at:

```text
~/Library/Application Support/Nook/nook-hook.sh
```

Configure your agent to invoke it on each lifecycle event, passing the event JSON on `stdin`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "type": "command", "command": "\"$HOME/Library/Application Support/Nook/nook-hook.sh\" --agent my-tool" }
    ]
  }
}
```

- `--agent <name>`: Identifier under which the agent appears in Nook (lowercase letters, digits, `-`, and `_`, up to 32 characters).
- `<EventName>` (optional): Event name for agents that do not include `hook_event_name` in their JSON payload, e.g. `--agent my-tool Stop`.

### 2. Via the `nook_agent` JSON Field

If you cannot pass CLI arguments, include `nook_agent` directly in the JSON payload:

```json
{ "hook_event_name": "UserPromptSubmit", "session_id": "s1", "nook_agent": "my-tool", "prompt": "Write unit tests" }
```

### 3. Directly Over the Unix Socket

Send a single newline-terminated JSON line to:

```text
~/Library/Application Support/Nook/hub.sock
```

```json
{"agent":"my-tool","mode":"event","event":{"hook_event_name":"Stop","session_id":"s1","cwd":"/Users/you/project"}}
```

## Supported Hook Events

Nook normalizes event names from Claude Code and common aliases (`BeforeTool`, `preToolUse`, `beforeSubmitPrompt`, `PreInvocation`, `session_start`, etc.):

| Event | Nook Behavior |
|---|---|
| `SessionStart` | Marks the agent session as working |
| `UserPromptSubmit` | Starts a new turn; displays `prompt` as the current step |
| `PreToolUse` | Adds a running tool step (`tool_name`, `tool_input`) |
| `PostToolUse` / `PostToolUseFailure` | Completes the latest step as done or failed |
| `Notification` | Marks the agent as waiting for user attention; displays `message` in the notch |
| `Stop` | Marks the turn as finished; uses `last_assistant_message` as summary |
| `StopFailure` | Marks the turn as failed (`error`) |
| `SubagentStart` / `SubagentStop` | Tracks subagent lifecycle |
| `SessionEnd` | Removes the session from active lists |

## Quick Test

With Nook running:

```sh
echo '{"hook_event_name":"UserPromptSubmit","session_id":"t1","prompt":"hello","nook_agent":"demo"}' \
  | ~/Library/Application\ Support/Nook/nook-hook.sh
```

You will immediately see **Demo** in the notch with the prompt `"hello"`.
