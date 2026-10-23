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

## Still open

Larger pieces, roughly by value. Each fits Nook's architecture; none is started.

- **A usage widget on the iPhone.** Plan limits on the Home Screen; the `NookActivity` widget extension that now carries
  the Live Activity can host it.
- **Composer chips.** Context references (`[label](nook-context:…)`) as inline chips that delete as one, with undo grouped
  per kind of edit. Needs the composer moved from `TextField` to an `NSTextView`.
- **Keybindings wired to commands.** `Keybindings.swift` parses rules with `when` clauses but nothing dispatches them;
  a central key monitor in the panel would make every shortcut configurable.
- **Model manifest.** A bundled `model-manifest.json`, refreshed from the repository, with `minVersion` per agent so the
  picker says which CLI update unlocks a model; favorites and custom model ids in the picker.
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

## Not adopted

The hosted cloud relay (Nook's companion is deliberately serverless), the Electron and CLI shells, VS Code theme
import (a native app follows the system), and the live terminal on the phone (it would undo the companion's
least-privilege design).
