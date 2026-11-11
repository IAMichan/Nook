# Nook Workspace for Coding Agents

Coding agents (such as Claude Code and Codex) can use Nook's integrated workspace directly: start long-running dev servers in a visible Nook terminal, open and inspect pages in Nook's built-in browser (including console errors and screenshots), delegate subtasks to other agents, and propose pull requests that you approve right in the notch.

Agents connect through a lightweight local MCP server (`nook-mcp`) that forwards requests over a user-only Unix domain socket to Nook. Sessions started inside Nook receive it automatically; external terminal sessions can be linked with one click in **Settings › Automation**.

## Core Principles

1. **Always Visible.** Anything an agent starts or opens via Nook appears right beside its session in the **Agents** tab: its terminal (badged with the agent's icon) and the workspace browser (*"Opened by Claude Code"*).
2. **Nook Is the Gatekeeper.** An agent's own CLI flags never bypass Nook's policy. Read-only operations run immediately; commands that are not provably harmless and pull requests wait for your explicit **Allow**, unless the session runs with **Allow everything**; dangerous commands are always refused (`CommandRisk`). Sessions in **Plan** mode are strictly read-only.
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

For sessions you launch yourself in an external terminal, click **Connect** in **Settings › Automation** (or run):

```sh
claude mcp add --scope user nook -- ~/.nook/nook-mcp --agent claude-code
codex mcp add nook -- ~/.nook/nook-mcp --agent codex
```

### Updating the agents

**Settings › Agents › Updates** lists each agent program Nook found, with its installed version (`--version`) and the
newest one. Which installer owns a program is read from its real path once symlinks are resolved (`AgentUpdates.owner`):
a Homebrew cask or formula (`brew upgrade [--cask] <name>`), a global npm install (`npm install -g <package>@latest`,
with the npm of the Node that holds it), pnpm, Bun, Volta, mise (`mise upgrade <tool>`), or the agent's own updater
(`claude update`, `opencode upgrade`, `cursor-agent update`). A program inside an app bundle, or one Nook does not
recognise, is left to you and its row says so. The newest version comes from Homebrew's own index (`brew info --json=v2`)
or the npm registry (through `NetworkGuard`), looked up when the page opens and at most every half hour.

**Update** and **Update all** (every agent with a newer version and a command) ask first: the confirmation lists the
commands and the running sessions of those agents, which keep the version they started with. The updates run one after
another with their last output line on the agent's row, each start and end goes to the audit log, and afterwards Nook
reads the version again, asks the agent again for its models, and says how it went. In a model picker, a model that needs
a newer agent comes with an **Update** row that opens this question. Antigravity's ACP server (Nook installs that release
itself) and ACP registry agents (run with npx or uvx) are not listed.

### Pi

Pi (`pi`, the pi.dev agent) runs as a session in Nook over its RPC mode: one `pi --mode rpc` process per turn that reads
and writes one JSON object per line (`PiRPC`, `PiStreamParser`, `WorkspaceManager+Pi`). Nook sends `get_state` and the
`prompt` (or `compact` for `/compact`), reads streamed text and thoughts, tool calls, usage with cost and the end of the
turn, and resumes the conversation from the session file `get_state` names (`--session`). Pi has no permission system
and no MCP client, so Nook loads an extension into every Pi session (`PiExtension`, written to
`~/Library/Application Support/Nook/nook-pi-extension.ts`): its blocking `tool_call` hook asks through Pi's `confirm`
dialog, which Nook shows as an approval (Supervised asks before everything but reads, Auto-accept edits also lets
`edit` and `write` through, Full access asks nothing; there is no "Auto", Pi has no reviewer), and it starts `nook-mcp`
and registers its tools in Pi as `mcp__nook__*`. Models come from `get_available_models` (a short-lived process
without session or extensions), thinking levels go with `--thinking`, accounts with `PI_CODING_AGENT_DIR`. Not built:
a native fork and rollback (Pi's `fork` needs an entry id of its session), Pi's own session files as past sessions, and
Pi's select, input and editor dialogs (cancelled). The wire format follows Pi's documented protocol; it has not been run
against a real Pi on this Mac, only against recorded transcripts (`PiRPCTests`).
### Sessions that outlive Nook

With **Keep sessions running when Nook closes** on (off by default), every agent runs through `nook-keeper` (`SessionKeeper`),
one small Perl process per agent in a session of its own. It writes the agent's stdout to a spool in `~/.nook/keep/<id>` (a
folder only you can enter) and takes stdin and signals over a socket there. Quitting or updating lets go of the agents at work;
the next launch attaches from the last line Nook handled (`reattachKeptRuns`). After a crash that position is unknown, so Nook
goes on from the current end: what happened in between stays out of the timeline. A session that waits for your approval or a
question is not kept: what it asked went with Nook, and it stops as before. An agent that asks for approval while Nook is closed
waits until Nook is back. A keeper whose agent ended waits a week for Nook, then cleans up.

### Guest links

**Share with a guest** in a session's menu copies a link that lets one person follow that session in a browser for 24 hours
(`GuestShares`, `GuestLink`, the relay's `worker/guest.js`). The page shows the timeline live. The guest may write a message
(up to 4 files, 10 MB together); it does not reach the agent: it waits in the session above the composer until you press
**Send** or **Dismiss**. **Stop sharing** ends the link at once, and it ends by itself after 24 hours, or when Nook quits.
The key that seals everything lives only in the link's fragment (`GuestLinkSeal`), so the relay passes bytes it cannot read.
The Mac must be on and Nook open. Guest links need a relay (Settings › iPhone).

### Nook in another app (remote MCP)

**Settings › Automation › Nook in another app** (off by default) lets a cloud assistant such as Claude.ai or ChatGPT use some of
the tools above through your relay (`RemoteMCPServer`, the relay's `worker/mcp.js`). The Mac keeps one outgoing connection; the
assistant is given an address (`<relay>/v1/mcp/<room>`, the room comes from a token in the Keychain, so the address cannot be
used to listen). In the assistant you add it as a custom connector; the assistant discovers the sign-in itself (RFC 9728 and
8414, dynamic client registration, PKCE S256).

- **Sign-in with a code.** When an assistant starts to sign in, Nook posts a notice and shows the sign-in in Settings with a
  six-digit code and the access level to give. Typing that code on the page the assistant opened is what lets it in; five wrong
  tries or ten minutes end the sign-in, and Nook can turn it down.
- **Access levels** (`RemoteAccessLevel`): *Read only* (sessions, pull request status, chats, scheduled tasks: reads only),
  *Sessions* (also follow up, start and organize sessions, answer questions) and *Full* (also Nook's apps, `nook_use` and
  `nook_chat_*`, and scheduling). Terminal, browser, simulators, rendered pages, secrets, taking over the screen and opening
  pull requests are never offered: they need a project folder or this Mac's screen. A lower level counts from the next call.
- **Grants.** A grant lasts 30 days. Access tokens last an hour and are renewed with a refresh token that works once and never
  extends the grant. Nook keeps only hashes of tokens (`remote-mcp.json`, readable by you only). Settings lists each grant with
  its access level and **Revoke**; **Revoke all and change the address** also makes a new address.
- **Every call is still Nook's.** Calls run through the bridge as an agent that is not in Nook: reads go through, anything that
  changes something (sending to a session, starting one, a message, an event, scheduling) waits for your yes in Nook, and every
  call, allowed or refused, lands in the audit log. An approval the assistant stops waiting for is withdrawn.
- **Not sealed.** Assistants speak plain HTTPS, so the relay can read what they send, like webhooks; it stores and logs none of it.

The local `nook-mcp` for agents on this Mac is unchanged.

### Android devices

The device tools also take Android devices when the Android SDK is installed (`ANDROID_HOME`, or Android Studio's folder):
`device_list` shows what `adb` sees and the virtual devices that can start, under ids that begin with `android`.
`device_screenshot` takes a picture through `adb`, and the agent drives the device with `adb` in its own shell. The Simulator
page shows them below the simulators, as a picture refreshed about once a second: touching the screen from Nook is iOS only.

### Scripts: the `nook` command line

Nook installs `~/.nook/nook`, a Perl script that makes the same calls over the same socket. Add `~/.nook` to your `PATH` to
type `nook`.

```sh
id=$(nook start . "Find why the tests are slow")   # waits for your approval in Nook
nook send "$id" "Now fix it" --wait                # exit 0 done, 1 failed, 2 waits for you, 3 Nook is not running
nook start . "Try the other fix" --base origin/main --title "Other fix"   # a worktree from origin/main
nook start --scratch "Convert these PNGs to WebP"  # a new folder without a project
nook start . --title "Release notes"               # idle: waits for your first message
nook send "$id" "Stop, use the cache" --mode steer # queue (default), auto, steer or restart
nook read "$id"
nook list
```

A script is always an outside caller: it never takes the rights of a session that works in the same folder, so starting and
messaging sessions wait for your approval, and a session it starts asks you before it acts. `nook tools` and
`nook call <tool> <json>` reach every other tool under the same rules. Only your own user can open the socket; there is no
remote access to it.

### Sessions on another machine

A session over SSH gets Nook's browser, `render_page` and read access to its own session (`RemoteBridge`). Nook copies `nook-mcp`
to `~/.nook` there (it needs Perl with `JSON::PP`) and ssh forwards a socket in that folder to `bridge-remote.sock` on the Mac.
That socket is separate from `bridge.sock`: a call on it needs a token made for that run, works only while that session is at work, and every tool that acts on the Mac
(terminals, pull requests, devices, delegation, connectors, secrets) and every other session is refused, because whoever controls that machine controls
what comes through. `localhost` in the browser is the Mac. Without Perl the session simply runs without these tools.

### Project scripts (`nook.json`)

A project lists its commands in `nook.json` at the repository root (or in a folder below it); the session panel and the
terminal bar run them, and **Add script** writes new ones there (`ProjectScripts`).

```json
{"scripts": [
  {"id": "dev", "name": "Dev server", "command": "pnpm dev", "previewUrl": "http://localhost:5173",
   "autoOpenPreview": true, "runOnWorktreeCreate": false, "stopOnSettle": true},
  {"id": "install", "name": "Install", "command": "pnpm install", "runOnWorktreeCreate": true, "async": false},
  {"id": "clean", "name": "Clean", "command": "rm -rf node_modules .next", "runOnSettle": true}
]}
```

| Key | Meaning |
|-----|---------|
| `id`, `name`, `command` | The script; `command` is required, the others are derived from it when missing. |
| `previewUrl`, `autoOpenPreview` | The page the script serves; opened in Nook's browser a moment after it starts. |
| `runOnWorktreeCreate` | Runs in a terminal next to the session when Nook makes a worktree for it (setup). |
| `async` | Only for `runOnWorktreeCreate`. `true` (the default) starts the agent while the script still runs. `false` holds the first turn (or the message that brings a removed worktree back) until the script ended: a new session stays preparing meanwhile, and stopping it ends the wait. When the script fails, or its terminal is closed first, the agent is not started and the session shows the error; the terminal stays open with it. The command runs under `/bin/sh` so its exit code can be read. |
| `stopOnSettle` | When the session settles, the terminal running this script stops, together with every process it started (each process group under the shell, except Nook's own and an agent's). |
| `runOnSettle` | When a session in a worktree of its own settles, this runs once in a new terminal in that worktree (cleanup). The terminal closes when the command succeeds and stays open with the error when it fails. It never runs for a session in the project's own checkout, which other work shares. |

Settling a session (by hand, from the selection bar, or by auto-settle) also closes its terminals that sit idle at a shell
prompt; a terminal that still runs something you started by hand stays. When another session that has not settled works in
the same folder (or a folder around it), nothing is touched, since those terminals are its too. Remote sessions are left
alone. The plan is pure and tested (`SettleActions`, `SettleActionsTests`); `AppModel.applySettleActions` carries it out.

### Dev servers

The bar of servers above a session (`DevServerStrip`) lists what listens on a port from the session's folder. A server
Nook started (below one of its terminal shells, or in the process group of an agent it runs, `DevServerOwnership`) has a
**Stop** button: it stops the server's process group, or only the server and what it started when that group is Nook's,
an agent's or a terminal shell's. A server you started in another terminal app gets no stop; a click on its greyed button
says why. Ownership is decided by pid and process group only (never by name) and checked again right before the signal.

### Scheduled tasks

A task (Settings › Automation › Scheduled tasks, or `schedule_task`) runs every N minutes, at a time on chosen weekdays,
**once** at a date and time (a run the Mac slept through runs when it wakes; afterwards the task shows as done and
editing it does not run it again unless its moment changes), or when its webhook is called.

**Where runs go:** a new session in a project each run, or one session. A one-session task either **continues the
conversation** or starts a **fresh conversation each run** (`WorkspaceManager.startFreshConversation`: the agent's
process ends and its next turn starts without the earlier conversation, for every agent; the timeline keeps every run).
The editor can change the target, which moves the task to another session; `update_scheduled_task` takes `target`
(`new_session`, `this_session`, `session` with `session_id`) and `conversation` (`continue`, `fresh`).

**Webhook tasks** (`WebhookRules`, applied in `ScheduledTaskStore.acceptWebhook` after the signature, delivery id and
rate checks):

| Rule | Behavior |
|------|----------|
| Placeholders | `{{body.path}}` (JSON or form fields, list items by index: `{{body.items.0.id}}`), `{{body}}`, `{{headers.name}}` in the prompt. Each value reaches the agent inside an `<untrusted-webhook-value field="…">` tag (a value cannot close its tag) with a note that it is outside data, not an instruction. Without placeholders the whole body is quoted as before. |
| Filters | `equals`, `is one of` (comma-separated) and `exists` on a value named like a placeholder. Every filter must pass; otherwise the sender gets `202 filtered`, nothing runs, and the Deliveries log names the first filter that failed. Objects and lists only pass `exists`. |
| Duplicate key | A template such as `{{headers.x-github-delivery}}`; a key seen in the past week (500 keys at most per task) is skipped (`202 duplicate key`). A key whose placeholders are missing skips the check. |
| Coalesce window | 10–3600 seconds: the first delivery opens the window, later ones in it do not extend it, and one run gets the latest delivery with the count. |
| Deliveries log | The latest 50 verified deliveries per task with time, outcome (accepted, filtered, duplicate, combined, skipped) and why, in the task's editor. Stored with the tasks. |

Open coalesce windows live in memory: a restart of Nook within a window drops that run (the sender's delivery was
already answered).
## Source control

How Nook makes worktrees and handles the repositories behind sessions (`WorkspaceManager+SourceControl.swift`,
`GitService+SourceControl.swift`, `SourceControl.swift`, `WorktreeCheckoutCache.swift`).

- **Fast worktrees** (Settings › Code › Worktrees, off by default). Nook keeps up to three clean checkouts of a
  repository's tracked files in `~/Library/Application Support/Nook/Checkout cache` and makes a new worktree with
  `git worktree add --no-checkout`, an APFS `clonefile` of the cached files, and the cached index with each file's own
  stat data; an older cached commit is moved forward with `git read-tree -m -u`, and `git status` must then be empty.
  Anything it cannot reproduce exactly uses plain `git worktree add`: another machine or volume, a sparse checkout, a
  filter in any attributes file (Git LFS), SHA-256, a changed `.gitattributes`, or a check that fails. Only tracked files
  are cached; the main checkout's `node_modules` is cloned (copy-on-write) into the worktree when the lockfiles match and
  Git ignores it. Repositories under 5,000 tracked files are never cached: Git is faster there. Measured on this Mac
  (2026-11-10): 30,000 files 2.8 s plain → 1.8 s cached (first `git status` 0.33 s → 0.13 s); 1,867 files (Nook) 0.76 s
  either way, because the cache is skipped.
- **Submodules** per project (recursive, top level only, or skip), applied after every new worktree on this Mac and over
  SSH; a failure is shown in the session and leaves the worktree usable.
- **Auto-pull** (opt-in, per project or for all): with the half-minute tick, at most every 15 minutes per checkout, Nook
  fetches the default branch and runs `git merge --ff-only`, only when the main checkout is on that branch, has no
  tracked changes, no merge or rebase is under way, no session works in it without a worktree, and it is strictly behind.
  Nothing runs while no project has it on. Every fast-forward lands in the action log.
- **Clones** go into `<host>/<owner>/<repo>` when that layout is on (under the layout root of the current project, else
  `~/Developer`). SSH runs with `BatchMode`; when SSH itself is refused (no key, unknown host key, no connection), the
  clone is tried once over HTTPS and a toast says so.
- **Publish** (the git button of a session without a remote, Settings › Projects, and **New project…** in the composer):
  a sheet shows what will happen and does nothing until you press Publish. Nook makes the folder a repository with a
  first commit when needed, creates the GitHub repository (private by default) with the GitHub account it uses for pull
  requests or the GitHub CLI's login, sets `origin`, and pushes with that token for this push only. An empty repository
  of the same name left by a failed push is reused. Every attempt goes to the action log. Agents cannot publish.
- **Commits in the Changes tab:** the newest 100 commits, one at a time; a hash or GitHub commit link in an agent's
  answer opens that commit there (an older one is read on its own).
- **Projects** in Settings › Projects can be archived (out of the composer, the command palette and auto-pull; reversible
  under Archived projects), get an icon (emoji, monogram on a tint, or an image copied into Nook's folder) shown in the
  composer, the session list's project headers and Settings, and switch single coding agents off.

## Available MCP Tools

| Tool | Description | Policy |
|---|---|---|
| `workspace_info` | Working directory, current branch, changed files, active terminals, open browser URL, PR capability, and policy summary. | Immediate |
| `terminal_run` | Starts a command in a new, visible Nook terminal (e.g., dev server, watcher) and returns its terminal ID (`t3`) and initial output. | Safe dev commands: immediate · Other commands: requires approval · Dangerous commands: refused |
| `terminal_read` | Reads recent output lines from a terminal in the same project directory, including running state and exit code. | Immediate |
| `terminal_list` | Lists terminals in the same project directory and which session started them. | Immediate |
| `terminal_stop` | Sends `Ctrl-C` (and optionally closes) a terminal started by the same agent. | Immediate |
| `browser_open` | Opens a URL in the browser of the agent's own session and waits for load completion. Every session has its own browser, so two agents never replace each other's page; `browser_read`, `browser_screenshot` and the tools that drive the page act on that browser too, or on Nook's own browser (Agents › Browser) while the session has no page open. Allows `https://` and local `http://` (`localhost`, `127.0.0.1`, `*.localhost`). | Local pages: immediate · Any other site: requires approval once per site per session (unless the session has full access), because whatever the agent puts in an address leaves this Mac |
| `browser_read` | Returns page title, URL, visible text, and console errors/warnings since page load. | Immediate |
| `browser_screenshot` | Captures a JPEG screenshot of the page for layout verification. | Immediate |
| `pull_request_create` | Pushes the branch and opens a pull request via your connected GitHub account (or opens the GitHub compare URL). | Requires approval, unless the session runs with **Allow everything** |
| `session_start` | Starts 1 to 20 new top-level sessions in one call `create_threads` and `thread_launch` (`BridgeSessionArguments.start`). Without `folder` they work beside the caller in its own folder or worktree; `folder` names another; `worktree` or `base` (`origin/main`) gives each a worktree of its own; `scratch` a new folder without a project. Each item of `sessions` has its own `task`, `title`, `agent`, `model` and `plan`; without `task` a session starts idle under its `title` and waits for your message. One approval card covers the call, `client_request_id` makes a retry start nothing twice, and the answer lists each session's id, `nook://` link, folder and branch. The new session's timeline opens with who started it (`NewRunConfig.startedBy`). Used by `nook start`. | Requires approval, unless the session runs with full rights |
| `session_send` | Sends another session a message, framed as another agent's words. `mode`: `queue` (default, after its turn), `auto` (steers a running turn the agent can take, otherwise as `queue`), `steer` (only into the running turn) or `restart` (stops the turn and sends this right after) `thread_send` (`WorkspaceManager.deliver`). It never takes the user's `/clear`. | Requires approval, unless the session runs with full rights |
| `session_wait` | Waits for up to eight sessions until any one (`mode: any`) or all of them are done with their turn or ask the user something, at most `timeout_seconds` (default 45, at most 840) `thread_wait`; returns each session's state and last answer. | Immediate |
| `orchestrator_capabilities` | Lists which agents Nook can spawn for delegated subtasks, available models, and current session permissions. | Immediate |
| `delegate_task` | Delegates a focused subtask (`research`, `review`, `design`, `test`, `implementation`) to a child agent session visible beside the parent. | Requires approval (unless session has full access); disabled in Plan mode |
| `task_status` | Returns status (`queued`, `running`, `waiting`, `completed`, `failed`, `cancelled`) and latest output of a delegated task. | Immediate |
| `task_wait` | Waits for up to eight delegated tasks until any one (`mode: any`) or all of them (`mode: all`) have finished or ask a question, at most `timeout_seconds` (default 45, at most 840). Returns each task's state and which are settled; tasks keep running after a timeout and wake the parent when done. | Immediate |
| `task_cancel` | Cancels a delegated task and any subtasks it spawned. | Immediate (disabled in Plan mode) |
| `session_read` | Reads a summary of another Nook session (prompt, answer, commands, changed files) for `@`-mentions. | Immediate |
| `session_search` | Searches the user's sessions (titles and timelines, `TimelineSearch`), most recent first, and returns each matching session with its id and a few excerpts; `session_id` searches one, `include_archived` adds archived ones. A full-text index in `runs.sqlite` (FTS5, trigrams of the folded text of each event, `RunEventLog.sessions(mentioning:)`) first names the sessions that mention the text, so every session is searched, not only the newest 300; timelines open in Nook are always searched too. Without FTS5, or for a query under three characters, the newest sessions are read as before. | Immediate |
| `session_organize` | Pins or unpins, settles or reopens, snoozes (`until`: hour, evening, tomorrow) or wakes, archives or unarchives, marks unread or read one session: the same actions as the Agents list (`InboxStore`, `FinishedSessions`, `SessionVisits`). A session that works or waits cannot be settled, snoozed or archived. | Requires approval, unless the session runs with **Allow everything**; disabled in Plan mode |
| `session_questions` | Lists (`action: list`) and reads (`read`) the questions other sessions wait on, with their options, and answers one (`answer`, checked against the question's options). Permission requests are not questions and never show here. The answered session's timeline says who answered. | List and read: immediate (also in Plan mode) · Answer a task the caller delegated: immediate · Any other answer: requires approval, unless the session runs with **Allow everything**; disabled in Plan mode |
| `render_page` | Shows an HTML page (`html`, `title`, `height` 80–1200, at most 512 KB, at most 24 per session) inline in the caller's own timeline: a chart, a diagram, a mock-up. Instead of `html` the agent may give `path`: an `.html` file in its working directory (`RenderedPageFile`). Nook reads it once and embeds the local stylesheets, `@import`s and scripts inline and the images, fonts and media as data: URLs (at most 2 MB each, 6 MB for the page); every file is resolved through its symlinks and must lie inside the working directory, and what does not, is missing or too large is left out and named in the reply. Not for sessions on another machine. Kept as a file with the session (`RenderedPage`, removed with it) and drawn by `RenderedPageRow` in a sandboxed frame (`allow-scripts` only) under the MCP app policy with no declared origins, so nothing loads or connects; the web view has no message handler and cancels every navigation, and exists only while its row is on screen and Nook is not saving energy, so a page that animates costs nothing out of sight. Only for sessions Nook runs. `show_chart` stays Nook Chat's own. | Immediate (disabled in Plan mode) |
| `browser_snapshot` | Lists the links, buttons, fields and headings on the page, each interactive one with a ref (`e7`) for `browser_click` / `browser_type`. Password values are never shown. | Immediate |
| `browser_click` | Clicks one element by ref, CSS selector or visible text. | Local pages (`localhost`): immediate · Other sites: requires approval (unless the session has full access); disabled in Plan mode |
| `browser_type` | Types into one field (replace or append, optionally submit its form), firing `input`/`change` so frameworks notice. The typed text is never written to the audit log. | Same as `browser_click` |
| `browser_wait_for` | Waits until text or a selector appears (or is gone), at most 30 seconds. | Immediate |

While an agent drives a browser (`browser_open`, `browser_click`, `browser_type`; `browser_snapshot` and `browser_wait_for` keep it going), every place that shows that browser's page (the side panel, Agents › Browser, the popup window and the corner of the chat) shows it: the page's edges glow and breathe in the colors of that agent's logo (`AgentLogo.colors`: Claude's orange, Gemini's blue and violet, Antigravity's three colors, a letter's color for an agent without a mark), and a pill at the bottom names the agent with a **Stop** button (`BrowserTakeoverOverlay`, state in `BrowserStore.drivenBy`). The glow goes 20 seconds after the agent's last step, or at once when you type an address yourself. **Stop** halts the page and refuses the agent's next `browser_open`, `browser_click`, `browser_type` and `browser_wait_for` in that browser with a message telling it to stop (`BrowserStore.agentsStopped`), until you press **Allow again** on the page. Reading (`browser_read`, `browser_screenshot`, `browser_snapshot`) stays allowed.
| `list_scheduled_tasks` | Lists scheduled tasks for the caller's folder or session (`all: true` for every task) with schedule, target, rights, next and last run. | Immediate |
| `schedule_task` | Proposes a scheduled task: every N minutes, at a time on chosen weekdays or once (`once_at`), in a new session in a folder or as a message to this or another session (`target`, `session_id`), continuing its conversation or fresh each run (`conversation`). Rights are `ask` or `acceptEdits`, never `bypass` and never more than the caller. Deduplicated by `client_request_id`. | Always requires approval; disabled in Plan mode |
| `update_scheduled_task` | Proposes a change to a task's title, prompt, schedule, rights, target (moving it to a new session in a folder, this session or another session), conversation mode or on/off state; the card shows the task after the change and before it. | Always requires approval; disabled in Plan mode |
| `run_scheduled_task_now` | Runs a task once with its own prompt; returns `started`, `busy` or `not available`. Deduplicated by `client_request_id`. | Always requires approval; disabled in Plan mode |
| `watch_pull_request` | Turns on the session's existing pull request watch (GitHub / GitLab, see `WorkspaceManager.watchPullRequest`): news goes to the timeline, and failed CI, a merge conflict with the base branch (also one already there when the watch starts), reviews and comments wake the agent with a message. While the agent works that message waits in the queue; failed checks or a conflict solved in the meantime, or a merge or close, take it out again (`PullRequestNews.stillNeeded`), also in a last look just before it goes out. Kept with the session across restarts; `stop: true` ends it. Sessions Nook started only. | Immediate (disabled in Plan mode) |
| `get_pull_request_status` | Reads state, CI with failed checks, each reviewer's verdict, the comment count and whether an open one has merge conflicts, via the same snapshot as the watch. Review and comment texts are left out. | Immediate |
| `request_secret` | Asks for a named secret. The card shows the name, the agent's reason and, with `url`, a button that opens the page where the secret is found or made (http or https only). On **Allow** Nook takes the value kept under `agent-secret.<name>` in its keychain (`SecretStore`) or asks you to paste one (optionally keeping it); a value that is a 1Password reference (`op://vault/item/field`) is read with the 1Password CLI at that moment and kept in memory only. By default (`delivery: "file"`) the value goes to a private file (`SecretFiles`: `~/Library/Application Support/Nook/agent-secrets/<session>/<name>`, folder `0700`, file `0600`, written with `O_EXCL | O_NOFOLLOW` and renamed into place) and the agent gets only the path, to use as `"$(cat '<path>')"`; the value never enters its transcript. Files go after 24 hours, when the session is archived or deleted, when Nook quits and at the next launch. With `delivery: "value"` the card warns first and the value comes back between `<nook-secret>` markers that Nook's timeline replaces. The audit entry records the name and how it was delivered, never the value. | Always requires approval; disabled in Plan mode; not for sessions on another machine |
| `nook_tools` | Lists Nook's own tools, the same set Nook Chat uses: messages in every chat app (`chat_inbox`, `chat_send`, `whatsapp_send`…), music (`search_music`, `play_music`, `media_control`), calendar, reminders, notes, mail drafts, contacts, connectors and the user's agent sessions. One line per tool grouped by source; `tool` gives its full description and argument schema, `query` filters. Sources the user keeps on this Mac (Settings › Privacy) are left out. | Immediate |
| `nook_use` | Runs one of those tools exactly as Nook Chat would. Read tools answer directly (results filtered by the privacy level); action tools are checked like a plan step (`AppModel.actionProblems`), shown as an approval card with the step and every argument, and then run by the plan runner (`AppModel.perform`), with its audit entry and duplicate check. | Read tools: immediate (also in Plan mode) · Action tools: always require approval, whatever the session's rights; disabled in Plan mode |
| `nook_chat_list` | Lists the user's Nook Chat conversations: id, title, whether Nook is answering, last message. | Immediate |
| `nook_chat_read` | Reads a Nook Chat conversation: questions, answers, and proposed actions with how they ended. An answer built from a source kept on this Mac is replaced by a note. | Immediate |
| `nook_chat_send` | Writes in Nook Chat (a new conversation, or `conversation_id` to follow one up) as the agent, not as the user: the chat shows the agent's name and the brain is told it is an agent's request. With `wait` (default) it returns Nook's answer; actions Nook proposes still wait for the user in Nook Chat. | Requires approval, unless the session runs with **Allow everything**; disabled in Plan mode |
| `take_over_screen` | Asks for the user's screen with a reason. On **Allow** that session holds the screen for `minutes` (default 10, at most 30) or until **Stop** in the notch, one session at a time and never while Nook takes over a task itself. Meanwhile it uses `read_ui`, `look_ui` (with the window's picture) and `control_ui` through `nook_use`: Nook's violet cursor shows where it acts and the notch shows each step. A step that pays, orders, sends, deletes, books or signs gets its own card (`TakeoverPolicy.checkpoint`); card and social security numbers are never typed. `stop: true` gives the screen back. Refused when the user keeps the screen on this Mac. | Always requires approval, whatever the session's rights; disabled in Plan mode |

## Nook Itself (`nook_tools`, `nook_use`, `nook_chat_*`)

Agents and Nook Chat share one set of tools (`AppModel.allTools`), in both directions:

- **Agent → Nook.** `nook_use` runs any of Nook's tools an agent may use (`WorkspaceBridge+Nook.swift`): send a message in WhatsApp, Messages, Telegram, Slack, Teams or the chat helper's networks, search and start music, add an event or reminder, read GitHub or Notion. Left out: Nook's own terminal and browser tools (the bridge has its own), taking over the user's windows (`take_over`, `read_ui`, `control_ui`), and chat-only tools (`show_chart`, `update_plan`). Agents run on a model outside this Mac, so the sources the user keeps on this Mac never reach them, whatever brain Nook Chat runs on, and what comes back is filtered by the privacy level.
- **Agent → Nook Chat.** `nook_chat_read` and `nook_chat_send` let an agent follow up a conversation the user had with Nook, or ask Nook something about the user's calendar, mail or chats.
- **Nook Chat → agents.** Nook Chat has `list_agent_sessions`, `read_agent_session`, `message_agent_session` and `start_agent_session` (`AppModel+AgentSessionTools.swift`, source `agents`). Reading uses the same summary as `session_list` / `session_read` (`WorkspaceManager+Digest.swift`); messaging and starting are actions the user approves in the chat's plan. A session starts with the user's default account, model, effort and rights for that agent, only in a project folder the user worked in before, or with `scratch` in a new folder without a project; `title`, `worktree` and `base` work as for `session_start`, its timeline says it was started from Nook Chat, and the answer carries its `nook://` link. `message_agent_session` takes the same `mode` as `session_send`. `list_remote_machines` and `add_remote_machine` (an action the user approves; it saves the machine and runs the same connection test as Settings › Machines) cover the machines sessions can run on over SSH, and `start_agent_session` with `machine` starts a session in a folder there. A password never goes through a tool: when a machine needs one, the user types it in Nook (`RemotePasswordField`), and starting there fails with that instruction until they have. Coding agents get these tools through `nook_use` like every other Nook tool.
- **The screen.** An agent can hand a whole task to Nook with `nook_use` `take_over` (Nook does it on this Mac with its own checkpoints; the agent gets the summary, so this also works when the screen is kept on this Mac), or ask for the screen itself with `take_over_screen` and work with `read_ui`, `look_ui` and `control_ui` (`WorkspaceBridge+Screen.swift`).
- **Music.** `search_music` and `play_music` (`AppModel+MusicTools.swift`) use the Music tab's search (Spotify's Web API when connected, otherwise the Music library) and play a track by id or by the best match; `media_control` keeps pausing and skipping.

Every coding agent gets these tools: they are part of the bridge, which every agent Nook runs (and every agent linked in Settings › Automation) receives.

## Multi-Agent Delegation (`delegate_task`)

Delegation rules are implemented in `Delegation.swift` (pure Foundation, tested in `DelegationTests`):

- **No privilege escalation:** Child sessions inherit the parent's mode and permissions (or a narrower subset); requests for broader permissions are refused. A parent in Plan mode cannot spawn an Agent-mode child.
- **Scoped context:** The child session receives only the explicit task prompt and role—never the parent's full conversation history.
- **Bounded depth:** Maximum delegation depth of 2 levels and at most 4 concurrent child tasks per session.
- **Cascading stop:** Stopping a parent session automatically stops all of its active child tasks.
- **Child does the work:** Every child is told to do the task itself, start no subtasks unless its brief asks, and end with a short report, because that report is all the parent reads (`DelegationPolicy.childNote`).
- **Results and questions come back:** A task the parent did not wait for sends its result to the parent as a message when it ends (with the branch to merge for a worktree task), and a question it asks once, so the parent answers it with `session_questions` or asks you. Agents are told not to poll.
- **Main thread:** The **Main thread** switch in the composer (new and running sessions) makes the session an orchestrator: it hands self-contained work to delegated tasks, starts independent ones together and combines their reports, so its own conversation stays small. The agent hears of the switch once, with your next message; its system prompt does not change, so the prompt cache stays warm. Tasks at work, asking something, or ended since your last message show above the composer; click one to open it. After a compaction your next message tells the agent again. On the iPhone a new session can start as a main thread, and a session's menu turns it on or off.
- **No two writers in one folder:** A child in Plan mode always shares the parent's folder. A child that may change files shares it too, unless another such child of the same parent is already working there: then it gets a git worktree of its own, on a branch from the parent's branch (`DelegationPolicy.placement`). The parent can choose with `isolation` (`shared` or `worktree`). The result of a worktree task names its `worktree` and `branch` and tells the parent to merge that branch.

## Security Guarantees

- The socket directory is `0700` and `bridge.sock` is `0600`, with peer UID verification on every connection (`UnixSocketServer`).
- **A session proves who it is.** Every session Nook runs gets a token of its own in its MCP server's environment (`NOOK_BRIDGE_TOKEN`, made per run of Nook and kept in memory only). A call gets the session's mode and rights only with that token (`BridgeIdentity`); a `NOOK_RUN_ID` without it, or an agent that merely works in the same folder as a session, counts as an agent you started yourself and asks for everything that is not a read.
- **Tools per agent.** Settings › Automation › Tools per agent switches groups of the bridge's tools (`BridgeCapability`: terminal, browser, pull requests, delegating, other sessions, devices, scheduled tasks, secrets, Nook's apps, the screen, pages) off for one agent (`BridgeAccess`). It counts for that agent's sessions in Nook and for the agent linked in a terminal (known by its `--agent` name); a call to a switched-off tool is refused with a message the agent can act on and logged. The MCP servers you add in Settings reach every agent through `nook_tools` / `nook_use` (the "Nook's apps" group): their credentials stay in Nook, reads run directly and actions ask first.
- **Nothing is allowed by default.** `BridgePolicy` lists every tool by name (an exhaustive `switch`), so a new tool cannot be allowed by accident. A tool whose handler does not ask for approval itself (`BridgeTool.asksInHandler`) is asked for centrally before it runs, so an `.ask` verdict can never be skipped.
- **Every decision is logged.** Allow, Always, Deny and In Terminal on any agent's request (hook, session in Nook or bridge), from the notch, the session view, a macOS notification or the iPhone, go to the action log as `agent_approval` with the agent, session, tool, request and where it was decided (`ApprovalAudit`). A bridge request nobody answered is logged as `expired`.
- `CommandRisk` treats a read-only program as read-only only without an option that writes a file or runs a program (`rg --pre`, `sort -o`, `git diff --output`/`--ext-diff`, `tree -o`, `less +cmd`, `uniq in out`); such a call is reviewed.
- Approval cards display the **entire** command or pull request details (repository, head → base branch, title, body) along with `CommandRisk` warnings.
- Agents cannot send arbitrary keystrokes to an existing interactive shell; they can only start tracked commands via `terminal_run` and read output from terminals in their own project directory.
- A session on another machine reaches only the tools `RemoteBridge.allows` lists, on a socket of its own, with a token per run.
- Agents can only reach secrets kept under the `agent-secret.` prefix, never Nook's own keys and tokens. A secret delivered as a file (the default) never enters the agent's transcript; one asked for with `delivery: "value"` does, in the agent's own transcript outside Nook.
- **sudo.** Every session Nook starts on this Mac gets `SUDO_ASKPASS` pointing at `nook-askpass` (`SudoAskpass`, `0700` in Nook's support folder; parity across Claude Code, Codex, Gemini CLI and every ACP agent through `AgentCommand.spec`/`acpSpec` and Codex's app-server). `sudo -A …` runs it; it sends one JSON line over `bridge.sock` (`{"askpass": {"prompt", "command"}, "cwd", "env"}`) and Nook shows a private card with the command sudo was started with and a password field (never kept). The password goes back on that connection only and the helper prints it to sudo; the agent, the timeline and the action log (which records `sudo` and the decision) never see it. Declined, timed out or without Nook, the helper exits 1. Secrets switched off for the agent, or Plan mode, decline at once. Not offered on the socket for other machines.
- **Pasted secrets.** When a paste into a session's composer (a session Nook runs, a new session, an agent's own session) looks like a secret (`SecretPasteDetector`: known key shapes, private key blocks, `NAME_TOKEN=…` assignments and a lone random token; never hashes, UUIDs, paths, addresses or identifiers), a notice above the box offers **Keep private**: the value goes to a private file and the message carries a `nook-context://v1/secret/<path>` reference, which reaches the agent as the path and how to use it. Not for sessions on another machine.
- **1Password.** Settings › Automation › Secret providers shows whether the 1Password CLI is installed and how it signs in (the 1Password app on this Mac, a service account token, or a Connect server address and token; tokens in `SecretStore`), with a Test button (`op whoami`, or reading a reference you type and dropping the value). References work for `request_secret` values and for MCP server variables and headers.
- A retried call with the same `client_request_id` gets the first answer; a retry while the first call still waits for you gets no second approval card.
- The workspace browser blocks `file://` and custom URL schemes. What it keeps of sign-ins follows `BrowserSignInPolicy` (`BrowserProfiles`): **Ask** (the default), **Keep** or **Forget**, set for all browsers in Settings › Browser and per project in Settings › Projects. Every project, and Nook's own browser, gets a persistent store of its own that no other project reaches; a project's agents can use its sign-ins. While the policy is Ask, the browser writes to that store too, and the first sign-in (a password sent from a form, `BrowserSignInScript`) asks above the page whether to stay signed in: Keep stores the answer where the question came from (the project's own row if it set Ask itself, otherwise the setting for all), Don't keep empties the store, Later asks again next time. A store that was never kept is emptied at the next launch. Forget uses one ephemeral store, so nothing reaches the disk. Sessions on another machine always forget.
