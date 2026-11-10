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
| `session_start` | Starts a new session in a folder, with rights that ask you. Used by `nook start`. | Requires approval, unless the session runs with full rights |
| `orchestrator_capabilities` | Lists which agents Nook can spawn for delegated subtasks, available models, and current session permissions. | Immediate |
| `delegate_task` | Delegates a focused subtask (`research`, `review`, `design`, `test`, `implementation`) to a child agent session visible beside the parent. | Requires approval (unless session has full access); disabled in Plan mode |
| `task_status` | Returns status (`queued`, `running`, `waiting`, `completed`, `failed`, `cancelled`) and latest output of a delegated task. | Immediate |
| `task_wait` | Waits for up to eight delegated tasks until any one (`mode: any`) or all of them (`mode: all`) have finished or ask a question, at most `timeout_seconds` (default 45, at most 840). Returns each task's state and which are settled; tasks keep running after a timeout and wake the parent when done. | Immediate |
| `task_cancel` | Cancels a delegated task and any subtasks it spawned. | Immediate (disabled in Plan mode) |
| `session_read` | Reads a summary of another Nook session (prompt, answer, commands, changed files) for `@`-mentions. | Immediate |
| `session_search` | Searches the user's sessions (titles and timelines, `TimelineSearch`), most recent first, and returns each matching session with its id and a few excerpts; `session_id` searches one, `include_archived` adds archived ones. A full-text index in `runs.sqlite` (FTS5, trigrams of the folded text of each event, `RunEventLog.sessions(mentioning:)`) first names the sessions that mention the text, so every session is searched, not only the newest 300; timelines open in Nook are always searched too. Without FTS5, or for a query under three characters, the newest sessions are read as before. | Immediate |
| `session_organize` | Pins or unpins, settles or reopens, snoozes (`until`: hour, evening, tomorrow) or wakes, archives or unarchives, marks unread or read one session: the same actions as the Agents list (`InboxStore`, `FinishedSessions`, `SessionVisits`). A session that works or waits cannot be settled, snoozed or archived. | Requires approval, unless the session runs with **Allow everything**; disabled in Plan mode |
| `session_questions` | Lists (`action: list`) and reads (`read`) the questions other sessions wait on, with their options, and answers one (`answer`, checked against the question's options). Permission requests are not questions and never show here. The answered session's timeline says who answered. | List and read: immediate (also in Plan mode) · Answer a task the caller delegated: immediate · Any other answer: requires approval, unless the session runs with **Allow everything**; disabled in Plan mode |
| `render_page` | Shows an HTML page (`html`, `title`, `height` 80–1200, at most 512 KB, at most 24 per session) inline in the caller's own timeline: a chart, a diagram, a mock-up. Kept as a file with the session (`RenderedPage`, removed with it) and drawn by `RenderedPageRow` in a sandboxed frame (`allow-scripts` only) under the MCP app policy with no declared origins, so nothing loads or connects; the web view has no message handler and cancels every navigation, and exists only while its row is on screen and Nook is not saving energy, so a page that animates costs nothing out of sight. Only for sessions Nook runs. `show_chart` stays Nook Chat's own. | Immediate (disabled in Plan mode) |
| `browser_snapshot` | Lists the links, buttons, fields and headings on the page, each interactive one with a ref (`e7`) for `browser_click` / `browser_type`. Password values are never shown. | Immediate |
| `browser_click` | Clicks one element by ref, CSS selector or visible text. | Local pages (`localhost`): immediate · Other sites: requires approval (unless the session has full access); disabled in Plan mode |
| `browser_type` | Types into one field (replace or append, optionally submit its form), firing `input`/`change` so frameworks notice. The typed text is never written to the audit log. | Same as `browser_click` |
| `browser_wait_for` | Waits until text or a selector appears (or is gone), at most 30 seconds. | Immediate |
| `list_scheduled_tasks` | Lists scheduled tasks for the caller's folder or session (`all: true` for every task) with schedule, target, rights, next and last run. | Immediate |
| `schedule_task` | Proposes a scheduled task: every N minutes or at a time on chosen weekdays, in a new session in a folder or as a message to this session. Rights are `ask` or `acceptEdits`, never `bypass` and never more than the caller. Deduplicated by `client_request_id`. | Always requires approval; disabled in Plan mode |
| `update_scheduled_task` | Proposes a change to a task's title, prompt, schedule, rights or on/off state; the card shows the task after the change and before it. | Always requires approval; disabled in Plan mode |
| `run_scheduled_task_now` | Runs a task once with its own prompt; returns `started`, `busy` or `not available`. Deduplicated by `client_request_id`. | Always requires approval; disabled in Plan mode |
| `watch_pull_request` | Turns on the session's existing pull request watch (GitHub / GitLab, see `WorkspaceManager.watchPullRequest`): news goes to the timeline, and failed CI, a merge conflict with the base branch (also one already there when the watch starts), reviews and comments wake the agent with a message. While the agent works that message waits in the queue; failed checks or a conflict solved in the meantime, or a merge or close, take it out again (`PullRequestNews.stillNeeded`), also in a last look just before it goes out. Kept with the session across restarts; `stop: true` ends it. Sessions Nook started only. | Immediate (disabled in Plan mode) |
| `get_pull_request_status` | Reads state, CI with failed checks, each reviewer's verdict, the comment count and whether an open one has merge conflicts, via the same snapshot as the watch. Review and comment texts are left out. | Immediate |
| `request_secret` | Asks for a named secret. The card shows the name and the agent's reason; on **Allow** Nook returns the value kept under `agent-secret.<name>` in its keychain (`SecretStore`), or asks you to paste one (optionally keeping it). The value goes only to the calling session, between `<nook-secret>` markers that Nook's timeline replaces before storing or showing tool output; the audit entry records the name only. | Always requires approval; disabled in Plan mode |
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
- **Nook Chat → agents.** Nook Chat has `list_agent_sessions`, `read_agent_session`, `message_agent_session` and `start_agent_session` (`AppModel+AgentSessionTools.swift`, source `agents`). Reading uses the same summary as `session_list` / `session_read` (`WorkspaceManager+Digest.swift`); messaging and starting are actions the user approves in the chat's plan. A session starts with the user's default account, model, effort and rights for that agent, only in a project folder the user worked in before. `list_remote_machines` and `add_remote_machine` (an action the user approves; it saves the machine and runs the same connection test as Settings › Machines) cover the machines sessions can run on over SSH, and `start_agent_session` with `machine` starts a session in a folder there. A password never goes through a tool: when a machine needs one, the user types it in Nook (`RemotePasswordField`), and starting there fails with that instruction until they have. Coding agents get these tools through `nook_use` like every other Nook tool.
- **The screen.** An agent can hand a whole task to Nook with `nook_use` `take_over` (Nook does it on this Mac with its own checkpoints; the agent gets the summary, so this also works when the screen is kept on this Mac), or ask for the screen itself with `take_over_screen` and work with `read_ui`, `look_ui` and `control_ui` (`WorkspaceBridge+Screen.swift`).
- **Music.** `search_music` and `play_music` (`AppModel+MusicTools.swift`) use the Music tab's search (Spotify's Web API when connected, otherwise the Music library) and play a track by id or by the best match; `media_control` keeps pausing and skipping.

Every coding agent gets these tools: they are part of the bridge, which every agent Nook runs (and every agent linked in Settings › Automation) receives.

## Multi-Agent Delegation (`delegate_task`)

Delegation rules are implemented in `Delegation.swift` (pure Foundation, tested in `DelegationTests`):

- **No privilege escalation:** Child sessions inherit the parent's mode and permissions (or a narrower subset); requests for broader permissions are refused. A parent in Plan mode cannot spawn an Agent-mode child.
- **Scoped context:** The child session receives only the explicit task prompt and role—never the parent's full conversation history.
- **Bounded depth:** Maximum delegation depth of 2 levels and at most 4 concurrent child tasks per session.
- **Cascading stop:** Stopping a parent session automatically stops all of its active child tasks.
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
- Agents can only reach secrets kept under the `agent-secret.` prefix, never Nook's own keys and tokens. The agent's own transcript (outside Nook) does contain a secret it was given.
- A retried call with the same `client_request_id` gets the first answer; a retry while the first call still waits for you gets no second approval card.
- The workspace browser blocks `file://` and custom URL schemes. What it keeps of sign-ins follows `BrowserSignInPolicy` (`BrowserProfiles`): **Ask** (the default), **Keep** or **Forget**, set for all browsers in Settings › Browser and per project in Settings › Projects. Every project, and Nook's own browser, gets a persistent store of its own that no other project reaches; a project's agents can use its sign-ins. While the policy is Ask, the browser writes to that store too, and the first sign-in (a password sent from a form, `BrowserSignInScript`) asks above the page whether to stay signed in: Keep stores the answer where the question came from (the project's own row if it set Ask itself, otherwise the setting for all), Don't keep empties the store, Later asks again next time. A store that was never kept is emptied at the next launch. Forget uses one ephemeral store, so nothing reaches the disk. Sessions on another machine always forget.
