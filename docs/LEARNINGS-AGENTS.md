# What Nook learned from Code

[Code]() is an open-source "agent harness control surface": one web, desktop and
mobile app that runs Claude Code, Codex, Cursor, Grok Build, OpenCode, Antigravity and Pi on your own machine. Its
workspace overlaps with Nook's Agents tab, so it is a good source of field-tested details. This page records what we
studied (October 2026), what Nook took over, and what is still open.

> **License.** Code is **MIT**, like Nook. Where Nook adapts its code (the terminal link patterns), the notice is in
> [`THIRD-PARTY-NOTICES.md`](../THIRD-PARTY-NOTICES.md); everything else below is re-implemented in Nook's own style.

## Already in Nook before this round

The thread layout ("Worked for 1m 3s", steps folded into one line), passkeys in the in-app browser, the session panel,
the prompt stash (⌘S), composer drafts and history, proposed plans, agent questions with digit shortcuts, GitHub call-outs
in Markdown, the context-window ring, dev-server detection with `lsof`, editor and terminal choice, branch pickers,
worktrees and their overview, per-turn diffs, project scripts, git checkpoints, stacked git actions, source-control hosts
(GitHub, GitLab, Gitea, Forgejo, Bitbucket, Azure DevOps), context handoff between agents, the orchestrator tools
(`delegate_task`, `session_send`, …), remote machines over SSH, `nook://prompt` links on the Mac, and the companion's QR
pairing and push actions.

## Added in this round

| Code | Nook | Where |
|---|---|---|
| Cmd-click links in the terminal: URLs, `path:line:col`, quoted paths; sentence punctuation and unopened brackets trimmed; `GET /x?y` request lines left alone | ⌘-click in Nook's terminal: a local address opens in Nook's browser, other web addresses in your browser, a path in your editor at its line; other schemes are ignored | `TerminalLinks`, `NookTerminalView` |
| Open a file at `line:column` with the editor's own convention (`--goto`, `path:line:col`, JetBrains `--line/--column` from 0) | The same for VS Code, Cursor, Windsurf, VSCodium, Zed, Sublime Text, Xcode (`xed --line`) and JetBrains IDEs; a file is never handed to its default app | `EditorLaunch`, `WorkspaceManager.openFile` |
| File links in assistant answers (relative paths, `file://`, `#L12` anchors) | Links in an agent's answer open in your editor at the line, read from the session's folder | `FileLink`, `MarkdownView`, `SelectableProse` |
| File context menu in the diff panel | Right-click a changed file: open in editor, show in Finder, copy path, copy path in repository | `FileContextMenu` |
| Port discovery that only offers real web servers (HTML or a redirect) | Dev servers in a session's folder are probed once per 15 s; databases and debuggers no longer show | `DevServerProbe` |
| Web view crash recovery | The workspace browser reloads a page whose process crashed, at most once per ten seconds | `BrowserStore.webViewWebContentProcessDidTerminate` |
| Quit confirmation while work is running | Quitting asks while sessions Nook runs are working (not on logout or an update restart); "Don't ask again" and a switch in Settings › Workspace | `AppDelegate.applicationShouldTerminate` |
| Offer to delete a thread's worktree | "Delete with worktree" when no other session uses it; Git keeps a worktree with uncommitted changes | `WorktreeCleanup` |
| Markdown list continuation in the composer | A line break after `- item`, `- [x] task` or `7. step` starts the next item (zero padding kept); after an empty item the list ends | `ComposerLists` |
| Text generation policies (Conventional Commits, repository conventions, custom) | Settings › Workspace › Commit messages: Nook's style, Conventional Commits, like the repository (its recent subjects as examples) or your own instructions | `CommitStyle` |
| SSH host discovery and Tailscale peers | Adding a machine offers `~/.ssh/config` aliases, `known_hosts` entries (no hashed entries, no git forges) and online tailnet devices by MagicDNS name | `RemoteHostDiscovery` |
| Prompt links on the phone; no banner for the thread on screen | Nook Companion registers `nook://` (also fixing the Camera scan of the pairing code), opens `nook://prompt` in New session prefilled, and stays quiet about the session you are looking at | `PromptLink` (now in `packages/protocol`), `NookCompanionApp` |
| Viewed files that clear after a push | Tick pull request files as viewed; a mark keeps the file's blob revision and lapses when a push changes the file | `PullRequestViewedFiles` |
| Resource telemetry per agent (pid + start time, deltas) | A working session's header shows CPU and memory of its agent and all its child processes, sampled only while on screen | `ResourceUsage`, `ProcessTable` |
| Pull request review guides | A Guide tab on every pull request: stops in reading order, files with notes, "Look closely" and "Skim", maintainer questions; tied to the head commit | `PullRequestReviewGuide` |
| `thread_wait` in the orchestrator MCP server | `task_wait`: wait for any or all of up to eight delegated tasks | `WorkspaceBridge`, `DelegatedTask.WaitMode` |
| Cite a selection of an answer in the composer | Right-click selected words of an agent's answer › Quote in your message | `EnvironmentValues.quoteSelection` |
| Back through multiple agent questions, drafts kept | Back returns to an earlier question with its answer picked; what you started on the later one waits | `RunQuestionPanel` |
| Live Activity per agent thread (`AgentActivity`, `agentLiveActivity.ios.ts`, `liveActivityPreferences.ts`): phase, project, model; finished results stay 15 minutes; a stale date; a switch in Settings | One Live Activity per session working on the Mac (Lock Screen and Dynamic Island): project, title, agent and model, *working / waiting for you / done / failed*. The Mac starts, updates and ends it with `liveactivity` pushes from its own APNs key (push-to-start and per-activity tokens through the companion protocol, rate-limited); a done or failed session stays 15 minutes; past the stale date it reads *Out of date*; a switch in the phone's menu turns it off. Unlike one card for all threads, and without a cloud relay | `LiveActivityPlanner` (`packages/protocol`), `CompanionNotifier`, `NookActivity` widget extension, `LiveActivities` |
| Model manifest (`model-manifest.json`, `ModelCatalog.ts`, `modelOrdering.ts`): bundled, refreshed from the repository, last valid copy kept, newer bundle wins by `updatedAt`, `minVersion` per agent, favorites and custom ids | The agent model pickers read a bundled manifest refreshed from Nook's repository (never while you keep the model list offline); a model that needs a newer CLI says which update unlocks it; favorites first, custom model ids from the search field (see below) | `ModelManifest`, `WorkspaceManager+ModelManifest`, `AgentModelPicker` |

## Model manifest

**The problem.** Nook hard-coded each agent's quick-pick models (`["", "sonnet", "opus", "haiku"]` in
`RunProvider.suggestedModels`). A new Claude model needed a Nook release, and a model the installed CLI was too old for
failed only after you sent the task.

**What Code does** (`apps/server/src/provider/model-manifest.json`, `packages/provider-core/src/server/ModelCatalog.ts`,
`docs/internals/model-manifest.md`):

- A **bundled manifest** allows offline startup; a copy fetched from the repository's `main` lets model data change
  between releases.
- A fetched copy must **pass validation** before it replaces the cache; a failed fetch or invalid data keeps the last
  usable manifest.
- A **newer bundle wins by `updatedAt`**, so a release can correct model data before the next successful fetch. Fetch
  time cannot tell which copy holds the newer edit; `updatedAt` can, so it is bumped on every change.
- Entries set `adapter.<agent>.minVersion`. A model above the installed CLI is reported as **update required**, and the
  picker says which update unlocks it. Codex still lists its own models (`model/list`), which cannot name models
  released after the installed build, so the manifest adds exactly those.
- `status: current | legacy` classifies models, `aliases` map short names, `badge: "new"` marks new ones.
- Tests use **synthetic model names**, so adding a model is a JSON edit that never needs a test change.

**In Nook:**

| Code | Nook |
|---|---|
| `model-manifest.json` | `apps/macos/Services/Workspace/model-manifest.json`, bundled as an app resource and fetched from `main` (`ModelManifest.remoteURL`) |
| Schema + adapter validation | `ModelManifest.parse` / `validate`: schema version 1, ids usable as a `--model` argument (no spaces, never starting with `-`), no id or alias used twice, the default listed, `minVersion` parseable and only under the owning agent's key, 256 KB at most |
| Cache keeps the last valid copy | `ModelManifest.accepting(_:over:)` returns nil for an invalid or older copy; `ModelManifestStore` stores only accepted bytes (`~/Library/Application Support/Nook/workspace/model-manifest.json`) |
| Newer bundle wins | `ModelManifest.preferred(bundled:cached:)` |
| `minVersion` against the CLI | `CLIVersion` parses `claude --version` ("2.1.280 (Claude Code)") and `codex --version` ("codex-cli 0.153.0"), numeric parts and pre-releases; `ModelManifest.requiredVersion` says "update" only when both versions are known |
| Codex discovery + manifest overlay | `ModelChoice.list`: the agent's own list first, in its order, classified by the manifest; then the manifest models it did not list (all of them for Claude, only the update-required ones when the agent lists its own) |
| `sortModelsForProviderInstance` (`apps/web/src/modelOrdering.ts`) | `ModelOrdering.sorted`: the agent default on top, then favorites, then the rest, each in the given order |
| Custom model ids | `ModelPreferences.customID` / `remembering`: type an id in the model search and pick "Use “…”"; the last eight per agent are kept |

**Wiring.** `WorkspaceManager+ModelManifest` loads the preferred copy at launch, reads the agents' versions (once, again
when the program moves or after half an hour) and builds the menus (`menuModelIDs`, `modelChoice`, `sameModel`) for the
composer's model picker (`AgentModelPicker`), the session settings (`NextTurnSettings` in `WorkspaceComponents.swift`),
Settings › Workspace › Models per agent, and the agent bridge's capability list. In the menus:

- A model that needs a newer agent shows "Needs Claude Code 2.1.300 or newer", cannot be picked, and its tooltip names
  the installed version.
- New models carry a "New" label; legacy ones stay hidden until you search, unless one is in use or a favorite.
- A star on each row toggles a favorite (`WorkspaceSettings.favoriteModels`); favorites are listed first.
- A saved alias ("opus") reads as its model and shows it chosen, and never waits on an update: the agent resolves an
  alias itself.

**Network rules.** The fetch goes through `NetworkGuard.fetch` (public hosts only, every redirect checked), at most every
six hours (`ModelManifestRefresh`), and never while **Settings › Workspace › Check for new models online** is off: then
only the bundled list is used and nothing goes online for it.

**Adding a model** is a JSON edit: add the entry, set `adapter.<agent>.minVersion` when it needs a newer CLI, and bump
`updatedAt`. `ModelManifestTests.testTheBundledManifestValidates` checks the file.

## Keybindings

**In Code** (`apps/web/src/keybindings.ts`): shortcuts are rules `{ key, command, when }`. One key handler builds a
context (`terminalFocus`, `terminalOpen`, …), resolves the pressed chord against the defaults plus the user's
`keybindings.json` (the last matching rule wins), and dispatches the command. Bad rules are skipped and reported;
`mod` is ⌘ on the Mac and Ctrl elsewhere.

**In Nook** (implemented after the round above):

- `Services/Workspace/Keybindings.swift` (Foundation-only, tested in `KeybindingsTests`): `KeyChord` (parse, format,
  `pressed` from a key event's unshifted characters and key code), `WhenExpression`, `KeybindingRule`,
  `Keybindings.defaults`, `commandIDs`, `contextKeys`, `match`, `conflicts`, `load` / `read` of
  `~/.nook/keybindings.json`, `unknownCommands` and `chords(for:)`.
- `NotchUI/Components/KeyCommands.swift`: `KeyCommandCenter`, the one local key monitor for the panel. It builds the
  context (`composerFocus`, `composerDraft`, `turnRunning` from the focused composer; `editableFocus`, `terminalFocus`
  from the first responder; `paletteOpen` from the agents' tab), matches over `Keybindings.effective(user:)` and runs
  the handler a view offers with `.keyCommand` / `.keyCommands`, scoped to the window the key was pressed in.
- The hard-coded shortcuts it covers are gone: ⌘Return, ⌘S and the history keys in `SessionComposer`, ⌘Return in
  `ChatReplyField`, the hidden ⌘F buttons in `AgentRunPanel` and `PullRequestsPanel`, ⌘K in `AgentsTab`, ⌘N in
  `WorkspaceView` and `NookConversationList`, ⌘Z in `AgentInboxList`. ⇧⌘Return sends the first queued message.
- Settings › Shortcuts › **Panel keys** lists every command with its keys, marks the commands nothing runs yet, and
  shows the file's state, the rules it skipped (with their position), unknown commands and conflicts.

**Differences from Code**, on purpose:

- A rule adds a key; the default stays (Code does the same). ⌘S (`composer.stash`) asks only for `composerFocus`,
  because in an empty composer it brings a stashed draft back.
- A matched command that nothing on screen handles lets the key go on to the focused view, so a rule for a command
  that is not wired yet never swallows a key.
- Keys inside a field or a list (Return, Tab, Escape, plain arrows) stay with that view; they are not commands.

See [`KEYBINDINGS.md`](KEYBINDINGS.md) for the defaults, the file format and how to add a command.

## Still open

Larger pieces, roughly by value. Each fits Nook's architecture; none is started.

- **A usage widget on the iPhone.** Plan limits on the Home Screen; the `NookActivity` widget extension that now carries
  the Live Activity can host it.
- **Composer chips.** Context references (`[label](nook-context:…)`) as inline chips that delete as one, with undo grouped
  per kind of edit. Needs the composer moved from `TextField` to an `NSTextView`.
- **Pi and Muse as managed providers.** Pi speaks LF-delimited JSON RPC over stdio (`prompt`, `get_state`, `set_model`,
  `fork`, `compact`); Nook would add a `RunProvider` and inject the workspace bridge as a Pi extension.
- **Browser.** Device presets with rotate and zoom, history and address suggestions per project, several tabs, and
  recording a page to a video an agent can read.
- **Terminal.** Split panes, and scrollback restored after a restart (bounded, with query/response escapes removed).
- **Diffs.** Syntax highlighting, a file tree, a choice of base branch, collapsed files, and review comments on a range of
  lines.
- **Portable handoffs.** Carry selected messages verbatim when switching agents, and point at the rest through
  `session_read`, instead of only a summary.
- **Companion.** A real diff review on the phone, dictation in the composer, a share extension and Home Screen quick
  actions, and a notice when the phone app is older than the Mac's protocol.
- **SSH password sign-in** through `SSH_ASKPASS` with the password in the Keychain.
- **Provider compatibility ranges** (`compatibility` in manifest): per agent, which CLI versions are supported,
  degraded or broken, with a recommended range, so Nook can warn before a session starts on a CLI known to break.
- **Default-model overlay** (`applyCatalogDefault`): the manifest moves an agent's default to a newer member of the
  same family, carrying its aliases along.

## Not adopted

The hosted cloud relay (Nook's companion is deliberately serverless), the Electron and CLI shells, VS Code theme
import (a native app follows the system), and the live terminal on the phone (it would undo the companion's
least-privilege design).
