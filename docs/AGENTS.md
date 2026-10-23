# Connecting Coding Agents to Nook

Nook displays what your AI coding agents are doing right inside the notch. Any agent that can invoke a shell command or write to a Unix domain socket can report to Nook and get its own dedicated session row.

Everything stays on your Mac: events travel over a local Unix socket (`0600`) that only your user account can open. If Nook is not running, the hook script exits cleanly as a no-op and the agent continues without interruption.

## Built-In Integrations

In **Settings › Agents**, you can connect these agents with one click. Nook previews the exact file changes first, creates a timestamped backup next to the configuration file, and writes only after your confirmation. Any file that cannot be read or contains invalid JSON is left untouched, as is any plugin file not created by Nook.

| Agent | Configuration File | Mechanism | What You See |
|---|---|---|---|
| Claude Code | `~/.claude/settings.json` | hooks, `--agent claude-code` | progress, approvals, questions |
| Claude (Desktop app) | same hooks | detected via `CLAUDE_CODE_ENTRYPOINT=claude-desktop` | progress, approvals, questions |
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

- **Pull Requests** (**Agents** › **Pull requests**): every open GitHub pull request you wrote or are asked to review, per connected account, plus the open pull requests of the organizations (`acme`) and repositories (`acme/web`) you add under **Settings › Agents › Watched pull requests** (shown as **Watched**, searched with every connected account). A search by title, repository, `#number`, `@author` or branch (`⌘F`) that also takes qualifiers (`label:bug`, `label:bug,ui`, `-label:wip`, a scoped label such as `area:ui`, `author:ada`, `draft:false`, `review:approved|changes-requested|required|none`, `checks:failing|pending|passing`, `repo:owner/name`), a **Sort** button (sort order and grouping) and a **Filters** button (state, involvement, author with counts and a search, labels in their colors with counts, drafts, review decision, checks, repository). The filters are kept across launches. Rows show GitHub's state mark with a conflict warning on it, the checks and review decision, the lines changed, the author's picture, the repository, up to three colored labels and when it last changed; group headings carry a count and a rule. Clicking one opens it inside Nook, beside the list when the page is wide enough (the open row highlighted) and in its place otherwise, with four tabs: **Summary** (reviewers ringed by their verdict, labels, then the description, the checks and the comments in sections that fold, bot comments hidden until asked), **Guide**, **Timeline** (reviews, (line) comments, commits, labels, review requests, force-pushes, mentions, the merge) and **Code** (each changed file with its diff). The bar beside the tabs shows the checks on Summary, the comment, commit and approval counts with the order on Timeline, and the files viewed on Code. Opened pull requests stay as tabs above the page (at most eight; the right-click menu closes one, the others, the ones to the right, or all). Holding **Shift** shows quick actions at the end of each row (close and merge, close and ready for review for a draft, reopen); the first click asks to confirm, the second sends it, and each is logged (`github_close_pr`, `github_merge_pr`, `github_ready_pr`, `github_reopen_pr`). A quick merge checks the pull request again first (open, no conflict, write access, no failing checks) and uses the merge method last picked on a page. Pull requests whose base branch is another open pull request's head form a **stack**: rows show their place (`2/3`), and the page's stack menu opens another one of it or merges the stack from the bottom up to the one you read, pointing each next one at the base branch first (`github_change_base`). With more than one GitHub account, **Filters › Account** lists one of them. Ready for review is also in the page's ⋯ menu for a draft. **Merge** (merge commit, squash, or rebase, as the repository allows) asks for confirmation, pins the head commit you looked at (GitHub refuses if someone pushed since), uses the account the pull request is listed under, and logs the result to the action log (`github_merge_pr`). Rows show the review decision (approved, changes requested, review required), a conflict mark and up to three labels; the list sorts by merge readiness, by what is blocked on you, or by size. On the page, **Write** opens a composer for a comment or a review (comment, approve, request changes), the ⋯ menu copies the link, number or `gh pr checkout` command, requests reviewers, edits the title and description, updates an out-of-date branch, and closes or reopens it. Every write asks for a second click and is logged (`github_review_pr`, `github_comment_pr`, `github_close_pr`, `github_reopen_pr`, `github_edit_pr`, `github_request_reviewers`, `github_update_branch`). Files read in order (source with its tests, then docs, then generated files); a file you marked viewed and that was pushed to since says **Changed**. The timeline can be read newest first. A github.com pull request link in a session's conversation opens in a **Pull request** tab in that session's side panel (in Nook's own chat, on this page); its ↗ button opens it on GitHub.

Key capabilities:
- **Unified Approvals** (`ApprovalCenter`, `ApprovalView`): shows the complete command or file diff, risk level, and **Allow**, **Always**, **Deny**, or **In Terminal**. Approving in the window or terminal immediately clears the notch card.
- **Running Sessions:** Continue a busy external session safely as a fork (`--fork-session`) so two writers never collide, or choose **Take Over** (`⋯`) to stop the external process and continue the session directly inside Nook.
- **Sessions Managed by Nook ("In Nook"):** Supports Claude Code, Codex, Gemini CLI, OpenCode, Cursor, Grok, and Antigravity with persistent per-session connections: Codex via `codex app-server`, Claude Code via a persistent streaming process, and others via ACP. Includes git checkpoints in isolated worktrees, auto-generated session titles, one-click Commit / Push / PR (always in English), and automatic resume when rate limits reset.
- **Cloud Sessions:** Sessions in Anthropic's cloud (started in the Claude Mac/iOS app or on `claude.ai/code`) are not read by Nook. When a Claude subscription account is connected, the Agents list shows a **Cloud sessions on claude.ai/code** button that opens them there.
- **Claude Subscription Login:** Nook never uses Claude Code's subscription login (OAuth token) itself; Anthropic allows it only in Claude Code and claude.ai. Everything Claude-related goes through the official `claude` CLI. The 5-hour and weekly limits come from Claude Code's status line and the `rate_limit_event` messages of sessions in Nook, and while those are quiet Nook asks the unmodified `claude` binary for them with the `get_usage` control request (the numbers behind `/usage`): without a prompt and only for signed-in accounts: in the background at most every ten minutes, and sooner when it matters — when you open the usage overview (every two minutes while it stays open) and after a Claude turn in Nook, at most once a minute per account; the refresh button in those views reads them at once (at most every ten seconds) (all slower when the energy plan takes it easy). The CLI uses its own login; Nook never reads, stores or forwards it. They are kept between launches.
- **Open What the Agent Points At:** a file link in an agent's answer (`src/app.swift:12:3`, `./README.md`, `#L20` anchors, `file://` links) opens in your editor at that line, read from the session's folder; in Nook's terminal, ⌘-click opens a local address in Nook's browser, any other web address in your browser and a path in your editor. Each editor gets the position its own way (`--goto` for VS Code, Cursor, Windsurf and VSCodium, `path:line:col` for Zed and Sublime Text, `xed --line` for Xcode, `--line`/`--column` for JetBrains), and a file is never opened in its default app. Changed files have a right-click menu: open in editor, show in Finder, copy the path or the path in the repository.
- **What a Session Costs:** a working session's header shows the CPU and memory of its agent and every process it started ("34 % · 512 MB"), read every three seconds while the session is on screen (`ResourceUsage`).
- **Tidy Endings:** quitting Nook while sessions it runs are working asks first (not on logout, shutdown or an update restart; switch it off in **Settings › Workspace**), and deleting a session offers **Delete with worktree** when no other session uses its worktree (Git refuses one with uncommitted changes, so nothing is lost).
- **Commit Messages in Your Style:** **Settings › Workspace › Commit messages** picks how Commit and Pull Request write their text: Nook's own style, Conventional Commits, like the repository (its recent commit subjects as examples), or your own instructions (`CommitStyle`).
- **Pull Request Review:** tick files as viewed (a mark lapses when a push changes the file), and open the **Guide** tab for a review guide: Claude Code or Codex reads the whole diff and writes the stops in reading order, each file with a note, what to look at closely and what to skim, and the questions only a maintainer can answer. The guide stays on this Mac and says when it was written for an earlier commit.
- **Quote Part of an Answer:** select words in an agent's answer and right-click › **Quote in your message** to put just that passage above your next message. With several questions from an agent, **Back** returns to an earlier one with its answer still picked.
- **Usage of Every Agent:** **Agents › Usage** (tabs **Cost**, **Tokens** and **Limits**) and **Settings › Usage** read the transcripts of Claude Code, Codex, Gemini CLI and Antigravity on this Mac (also sessions you ran in a terminal, for the last 90 days) and shows: cost at API list prices or tokens, over 24 hours, 7, 30 or 90 days; a large total with each agent's share; a stacked chart per agent (point at a column for its figures); totals for processed, cached and uncached input, output and cache savings; bars that split tokens and cost by type; and a breakdown per model (rank, share, a bar per model) or per day. A model opens with its cost per million tokens, cache hit rate and its own trend, and a model without a known price can get one (`UsageLedger`, `ModelRates`, `UsagePrices`). An agent with several accounts also shows them as one pool per limit window, a segment per account, with what the next reset gives back (`LimitPool`).
- **Full Transcript & Reasoning:** Reads agent transcripts to show collapsible reasoning steps (`thinking` / `thoughts`), commands, file edits, searches, and subagents inline. The conversation reads like a thread (`TranscriptPresentation`): your messages in a bubble on the right, answers as plain text on the left, steps in a row as one line ("Ran 3 commands and read 2 files"), each finished turn folded into "Worked for 1m 3s", and a running turn showing "Working for 12s" with the live step at its end. A turn that changed files ends in a changed-files card ("3 changed files +12 −4", the files as a folder tree); a file in it, **Open diff** or `⌘D` opens the diff panel beside the conversation, where you pick the latest turn, any turn or all turns, and every file or one (`TurnDiff`, made from the agent's own edits). Sessions Nook runs get the same card and panel, with the lines and diffs read from git between the snapshots around each turn. A message you sent while the agent worked, from Nook, the terminal or the Claude desktop app, shows as your prompt marked "Sent while working" (Claude Code writes it as a queued command); away from the end, a pill brings you back.

## Nook Workspace MCP for Your Agents

Agents can use Nook's integrated terminal, browser, and PR workflow via a local MCP server (`~/.nook/nook-mcp`): start a dev server in a visible Nook terminal (`terminal_run`, `terminal_read`), open and inspect pages in Nook's browser (`browser_open`, `browser_read`, `browser_screenshot`), and propose a pull request (`pull_request_create`). Sessions started by Nook receive this automatically; external agents can be linked in **Settings › Workspace**. See [WERKRUIMTE-AGENTS.md](WERKRUIMTE-AGENTS.md).

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
