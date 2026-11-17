# The Tauri app: what has been ported from the Mac

`apps/tauri` brings Nook to Windows, Linux, and Android. The macOS app is the specification; this list tracks what is
already there. [WINDOWS-PARITY.md](WINDOWS-PARITY.md) is the checklist of everything still missing.

✓ = ported and tested in the app · ◐ = partial, or only compiled and not actually run · ○ = not yet · — = not possible on this platform

> Windows code compiles locally with `cargo check -p nook --target x86_64-pc-windows-gnu` (needs `mingw-w64`). In CI
> the **Windows checks** job runs clippy, the Rust tests and the interface tests on `windows-latest`, including the
> Windows-only tests (named pipes for hooks, `cmd /C` MCP servers, the Task Scheduler task). The app itself has not
> (yet) been run on a real Windows PC. Android builds only in CI (job **Android**); the Android SDK could not be downloaded
> locally.

**Want to help?** Every ○ and ◐ row below is open for contributors, and so is the [To do](#to-do) list. You don't need
a Mac for any of it. See [CONTRIBUTING.md](../CONTRIBUTING.md#windows-linux--android-tauri).

## Core and chat

| Part (Mac) | Tauri | Where |
|---|---|---|
| `AIProvider`, `BrainSelection`, `AppSettings` | ✓ | `core/src/provider.rs`, `core/src/settings.rs` |
| `ToolRunner` (tool loop, recovery, cache, JSON in text) | ✓ | `core/src/brain/tool_loop.rs` |
| Anthropic, OpenAI-compatible, Ollama (streaming, tools, images; Ollama frees memory after 90 s, Think Along unloads a model it loaded itself) | ✓ | `core/src/brain/conversations.rs`, `services/think.rs` |
| `BrainService` (prompts, prioritizing, `use_source`, context budget) | ✓ | `core/src/brain/service.rs` |
| `ConversationWindow` (the conversation sized to the brain: newest turn up to two thirds, recent turns whole, older ones shortened with "…", the rest folded into a recap of earlier questions that intent and research leave out) | ✓ | `core/src/brain/conversation_window.rs`, `Conversation::window_hiding` in `core/src/nooks.rs`, used by `commands/chat.rs`, `service.rs` (Claude Code and small local models get it as text) |
| `ModelProfile`, `ModelAdvisor`, `ModelDownload` (one-click Ollama install) | ✓ | `core/src/brain/profile.rs`, `model_download.rs` |
| `ChatIntent`, `LocalIntent`, `QueryPlan`, `SourceScope`, `Fuzzy`, `NookDates`, `FollowUps` | ✓ | `core/src/brain/` |
| `Research`, `Retrieval` (searching on its own, numbered sources) | ✓ | `core/src/brain/research.rs`, `retrieval.rs` |
| Sources card under an answer (status per source, unread sources on top with a reason and Try again, errors in plain language) | ◐ (no cited excerpt on hover, cited/uncited dots or mail sources by sender, BR-40) | `components/SourcesView.svelte`, `lib/sources.ts` |
| Chat tables: text columns with digits in a name don't become a chart (`ChartRescue.tableNumber`) | ✓ | `core/src/brain/chart.rs` |
| `ActionGate`, `CommandRisk` (also what runs inside `sh -c`, `xargs`, `find -exec`, and on Windows `cmd /c` and PowerShell `-Command`), `Undo`, `NetworkGuard`, `LocalQuality` | ✓ | `core/src/brain/` |
| Live plan above an answer (`update_plan`, `TaskChecklistCard`): the brain keeps a step checklist for a request of several steps, offered to every brain that works in steps, never to agents; a step left running when the answer stops reads as still to do | ✓ (parsing and settling unit-tested; not run against a live model) | `core/src/brain/task_steps.rs`, `src-tauri/src/tools/plan.rs`, `components/TaskChecklist.svelte`, `lib/task-steps.ts` |
| Memory (`Memory`, `NookMemory`, Settings › Assistant) | ✓ (importing MCP memory ◐) | `core/src/brain/memory.rs`, `tools/memory.rs` |
| Web, weather, charts, mail drafts | ✓ (mail via `mailto:`; `.ics` invitations are BR-22) | `tools/{web,charts,mail}.rs` |
| `ClaudeCodeBrain` | ◐ (not tested with a real `claude`) | `core/src/brain/claude_code.rs` |
| Text in pictures for every brain (`ChatImage.describe`): the pictures of a question are read on this computer (Windows OCR, tesseract on Linux) at 1568 px, and each brain gets "Image: … Text recognized in the image (OCR…)" with the question, so one that cannot see still knows what they show | ◐ (the description is unit-tested; Windows OCR and tesseract are not run on a picture in a test; PNG and JPEG only; nothing is added where the platform cannot read pictures) | `core/src/brain/chat_image.rs`, `ScreenReader::read_image_text`, `services::screen::describe_images` |
| `NookStore`, `NookChat` (Nooks, `nooks.json`, archive, search) | ✓ | `core/src/store.rs`, `core/src/nooks.rs` |
| Asking about a selection (`SelectionAsk`: a bar above selected text anywhere in Nook, the answer in a card beside it) | ◐ | `src/components/SelectionAsk.svelte` (mounted once in `App.svelte` for the main window), `src/lib/selection-ask.ts` (+ tests), `nook_new_background` in `src-tauri/src/commands/selection_ask.rs`, setting `selectionAsk` (Settings › Brain › Answers). Ask Nook, Explain, Translate and Copy over a selection by drag, double click or keys; the answer is a background Nook asked through the chat's `ask`, shown in a card with follow-up, Stop, and Continue in chat. Checked with unit tests and in a browser with a stubbed backend, not yet in the running app. Not ported: the bar in the bar window and the other small windows, Quote into an agent session's reply box, the drag across several chat messages with the chat around a selection as context (`TranscriptSelection`), and the hidden note that tells the brain the quote is material, not instructions. |
| `SecretStore` | ✓ | Credential Manager, Secret Service, private app folder on Android |
| Plans with Run, never run twice, Undo | ✓ | `src-tauri/src/commands/plans.rs` |
| Main window like the Mac and the Claude app: list grouped Today / Yesterday / Previous 7 days / Older under the pinned, time-of-day greeting with a "waiting for you" line, title you rename in place, sidebar state remembered, sidebar as an overlay in a narrow window | ◐ (tested in unit tests and svelte-check; not run on a real window; split view and torn-off tabs UI-35, back and forward UI-36, resizable sidebar UI-37, the Mac's list with header tabs, hover card and multi-select BR-45) | `lib/conversation-list.ts`, `components/NookList.svelte`, `components/Chat.svelte`, `views/Main.svelte` |
| Onboarding (welcome card, three steps) | ✓ | `src/views/` |
| Interface in the Mac's five languages (English by default or the system language; Dutch, German, French, Spanish; Settings › General › Language), tray menu included | ◐ (Rust error and status messages partly Dutch, FD-04) | `lib/i18n.svelte.ts`, `lib/i18n/*.ts`, `lib/i18n.test.ts` |
| Main window sidebar like the Mac (`PanelSidebar`): Search and Talk in the head; tabs Nook, Agents, Chats, and Music while something plays; Settings, Pull requests, Usage in the footer | ◐ (seen in a browser with a stubbed backend; the visual audit found the orb in the head and extra footer icons, UI-85; no update button in the footer, UI-38, and no resizable width, UI-37) | `views/Main.svelte`, `lib/shell-routes.ts` |
| Empty chat like the Mac (`NookTab.emptyState`, `NookStarters`, `NookGlance`): date, greeting with what waits, For you, glance cards (agents, next event, now playing), starter grid | ◐ (no plan-limits card, BR-49; no split view, UI-35; fewer starter signals, BR-50; starter grid not yet checked against `NookStarters`, UI-42) | `components/Chat.svelte`, `ForYou.svelte`, `HomeGlance.svelte`, `StarterGrid.svelte` |
| Settings like the Mac: the Mac's pages in its five groups (Nook, Intelligence, Agents, Connections, System; Gamer Mode as a Tauri-first page), a page with several subjects behind one tab bar (`SettingsPartTabs`), icons, search over the subjects (Ctrl+F or /), breadcrumb bar, Overview page. Mac subjects without Tauri content yet (Notifications per app, Worktrees, Editor & browser, Projects & pull requests, Machines, the privacy parts) wait for their items | ◐ (layout and its aliases unit-tested; not seen in a real window; no search over every row, attention counts, restore per page, page intros, folds, setup sheets or one field style, UI-03…UI-11; a short Overview, UI-07) | `lib/settings-pages.ts` (+ tests), `views/Settings.svelte`, `views/settings/SettingsPartTabs.svelte`, `views/settings/Overview.svelte` |
| Settings controls like the Mac's (`SettingsFormStyle`, `SettingsRowToggleStyle`, `SettingsControl`): a switch for every on/off row (a checkbox with `role="switch"`, drawn as a switch; weekday picks stay boxes), capsule menus with up/down chevrons 28 px high, segmented pickers for two to four choices (appearance, background work), small buttons in the control fill, rows 12 px high padding in cards on the surface | ✓ (compared with the Mac's Settings rendered offscreen; seen in a browser with a stubbed backend, not on a real window) | `views/settings/settings.css`, `views/settings/Segmented.svelte` |
| Settings › Shortcuts: the global shortcuts (moved from General) and a cheat sheet of the main window's keys with a filter (`ShortcutCheatSheetView`) | ◐ (the sheet is checked against `shellShortcut` in tests; in-app keys can't be rebound and the capture, point-to-bar and open-panel keys are missing, UI-19; most Mac key commands are missing, UI-62) | `views/settings/Shortcuts.svelte`, `lib/shortcut-sheet.ts` |
| Settings › Instructions: default answer style (`ResponseStyle`) and your own standing instructions, both in the brain's system prompt | ◐ (style and free text; the Mac's saved prompts, spaces and context inspector ○; prompt tested in core, not against a live model) | `views/settings/Instructions.svelte`, `core/src/instructions.rs`, `brain/service.rs` |
| Settings › Agents › Archive: archived coding agent sessions and Nook conversations, search, restore, delete, "Delete all archived…" with one confirmation, never what still works | ✓ (seen in a browser with a stubbed backend) | `views/settings/Archive.svelte`, `lib/archive.ts` |
| Settings › Maintenance: data folder, cache size and clearing, export settings (save dialog), restore defaults (keeps language, welcome, window), versions to copy, updates via the releases page (no built-in updater) | ◐ (core tested; commands compiled for Windows, not run in a real window) | `views/settings/Maintenance.svelte`, `core/src/maintenance.rs`, `commands/maintenance.rs` |
| Settings › About: version, source code, what's new, report a problem, license, open source notices | ✓ | `views/settings/About.svelte` |
| `NookTheme` tokens: type scale, spacing, radii, palette | ◐ (motion tokens and reduced motion not checked against `NookTheme`, UI-75; built-in themes UI-70) | `src/app.css` |
| Settings › Appearance: System, Light or Dark (light = `NookPalette.nookLight`; the bar stays dark, as the notch does), accent color (moved from General; the soft white turns near-black in light), density (compact, comfortable, spacious as a zoom of the window) | ◐ (seen in a browser with a stubbed backend in both looks; the Mac's custom themes, face, VS Code import and per-token colors ○; density zooms the whole window instead of the Mac's separate type and spacing scales) | `views/settings/Appearance.svelte`, `lib/theme.ts`, `src/app.css`, `App.svelte` |
| `AppleIntelligence`, `EmbeddedModel` (MLX), `MacReport` | — | Apple only; local thinking goes through Ollama or LM Studio |

## Connectors

| Part (Mac) | Tauri | Where |
|---|---|---|
| Framework (Connector, Hub, catalog, brands) | ✓ | `core/src/connectors/` |
| Calendars: ICS ("Other calendars"), Cal.com, `check_availability` | ✓ | `ics.rs`, `agenda.rs`, `feeds.rs` |
| System calendars (Apple Calendar) | — | No API in this port |
| GitHub (read; review, merge, close as an action) | ✓ | `github.rs` |
| Pull requests under Agents: yours, awaiting your review, followed organizations and repositories (Settings › Accounts & connections), filters (status, involvement, author, draft, checks), reading with reviews and comments (GitHub HTML as Markdown), a GitHub Actions check's steps and log read in Nook (`CheckLog.svelte`), merging after confirmation in the bar, with an action log | ◐ (tested against a fake API, not against GitHub itself) | `pulls.rs`, `github_markdown.rs`, `views/agents/pulls/` |
| Sign in with GitHub | ◐ | Sign in and Repair take over the `gh auth token` login (a token stays under "With a token"); device flow is waiting on a client ID; opening `gh auth login --web` itself ○ |
| Second account per service, account per chat | ◐ (no second WhatsApp account, CH-70; agent accounts for Claude and Codex only, AG-27) | `accounts.rs`, `ChatAccounts.svelte` |
| GitLab, Vercel, Stripe, Notion, Cal.com, n8n, Resend | ✓ (GitLab token checked first via `/api/v4/user`) | `gitlab.rs`, `cloud.rs` |
| Settings › Accounts & connections as one catalog: search, categories, rows for your connections (including GitLab and custom MCP servers), cards with Sign in / With a key / MCP | ◐ (several MCP sign-in presets missing, CH-95; the add sheet isn't grouped as on the Mac, CH-96) | `views/settings/Accounts.svelte`, `views/connectors/` |
| Custom sources (web APIs, webhooks) | ✓ | `custom.rs` |
| Connecting with OAuth (Notion, Linear, Stripe, Vercel, Sentry); repairing an expired key by signing in | ◐ (not tested against the real services) · — Android | `oauth.rs`, `commands/connectors.rs` |
| MCP client (stdio, HTTP) | ✓ (stdio desktop only) | `core/src/connectors/mcp/` |
| WhatsApp live (GOWA) | ◐ (start the gateway yourself; installer ○) | `core/src/connectors/whatsapp/` |
| One inbox for every chat app (`ChatInbox`, `InboxThread`, `BridgedChat`, `ChatBridge`): one set of rules for new, read in Nook, read in the app, marked unread, answered, removed, gone, edits, deletions, ticks, kept messages and dropped chats; saved as `chat-inbox.json` without the messages of an app that keeps them (WhatsApp) | ✓ (unit-tested; WhatsApp is on it, the other apps come with the chat helper) | `core/src/chats/` (`inbox.rs`, `bridge.rs`, `store.rs`), `Inbox` in `core/src/connectors/whatsapp/mod.rs` translates |
| WhatsApp card in the bar: chat as bubbles with ticks, photos in the card (large with a click), files and videos open with the system app, reply, Mute, Let Nook reply (reads only that chat, only suggests a reply to that chat, learns nothing) | ◐ (tested with a fake gateway, not with a real phone; only in the bar, not on Android; video doesn't play in the card and documents show no first page) | `views/connectors/WhatsAppCard.svelte`, `lib/whatsapp.svelte.ts`, `src-tauri/src/commands/whatsapp.rs` |
| WhatsApp per chat: people, groups, status updates, and channels each a row; per chat Automatic, Always, or Never; hidden chats back one by one | ✓ | `core/src/connectors/whatsapp/mod.rs`, `views/connectors/WhatsApp.svelte` |
| `@chat` (WhatsApp chat next to the chat), sending via WhatsApp Web | ○ | Possible through a WebView2 (Windows) or WebKitGTK (Linux) pane, as the Mac's `EmbeddedApps`/`WhatsAppWeb`; not built yet (CH-73) |
| Portfolio | ○ | |
| Apple Notes, Reminders, Mail.app, Messages, Bear, Things | — | Mac apps |

## Platform services

| Part (Mac) | Tauri | Where |
|---|---|---|
| Reading the screen (`ScreenReader`, `ScreenContext`, `AppTextReader`) | ✓ Linux (AT-SPI, X11, tesseract) · ◐ Windows (UI Automation, OCR) · — Android | `core/src/services/screen.rs`, `platform/` |
| Screen region | ◐ (no annotating, pasting back or Ask, SV-74) | `services/part.rs` |
| Look Along, Think Along (answers in the app's language, not that of Nook's own question) | ◐ (no backoff up to 2 h kept across restarts and not the Mac's full nudge filter, SV-17) | `core/src/services/think_along.rs` |
| Music (`NowPlayingService`, Music tab) | ◐ now playing and controls only: MPRIS on Linux, Windows media controls (only compiled); no Spotify, search, queue, playlists, library, history, lyrics or output picker (SV-30…SV-39) | `platform/linux/mpris.rs`, `platform/windows/media.rs` |
| System: apps, volume, clipboard, files, notifications | ✓ Linux · ◐ Windows | `platform/*`, `tools/{system,files,clipboard}.rs` |
| Voice: read aloud, speech to text (whisper.cpp or a chosen service) | ◐ (reading aloud tested; recording not, no microphone) | `core/src/services/`, `services/voice.rs` |
| "Hey Nook" | ◐ Windows · — Linux and Android | `platform/windows/speech.rs` |
| Autocomplete everywhere (`AutocompleteController`, `CompletionSuggestion`, `CompletionPrivacy`, `CompletionEmoji`, Settings › Autocomplete) | ◐ Windows (compiled, not run on a real PC; Testing tab on Linux too) · — Linux and Android | `core/src/services/autocomplete/`, `src-tauri/src/services/autocomplete.rs`, `platform/windows/autocomplete.rs` |
| Flow dictation | ◐ (logic with tests; not tested with a microphone) | `core/src/services/flow.rs` |
| Notetaker | ◐ (no speaker recognition) | `core/src/services/notes.rs` |
| Today, weekly recap (with agent figures per project) | ◐ (Today lacks failed agents, owed replies, birthdays, connector failures, autocomplete savings and the Mac's ranking, SV-18, SV-13) | `core/src/services/recap.rs`, `views/Today.svelte` |
| Nook itself (orb, ring, sounds) | ◐ (not all 17 moods, face looks and reactions, SV-20; no buddy moments, SV-19; one sound for all events, SV-53) | `components/Orb.svelte`, `lib/sounds.ts` |
| Meetings and screen sharing (`QuietPolicy`, `QuietWatch`): quiet, hide from viewers, hide completely, Nook in screenshots | ◐ Windows (window list, microphone via the privacy registry, `WDA_EXCLUDEFROMCAPTURE`; only compiled) · ◐ Linux (X11 and `pactl`; keeping out of a share isn't possible, then only quiet; not tested in the app) · — Android | `core/src/services/quiet.rs`, `services/quiet.rs`, `platform/{windows,linux}/quiet.rs`, Settings › Voice & sound |
| Energy plan (`EnergyPolicy`, `EnergyMonitor`): Automatic, Saver, Full power; screen reading and Think Along follow it, the orb rests | ◐ (Windows: battery, power saving, CPU load; Linux: `/sys`, load average, screensaver; not tested in the app) · — Android | `core/src/services/energy.rs`, `services/energy.rs`, Settings › General |

## Gamer Mode (Tauri first, not on the Mac yet)

A coach for games, opened from **Gamer Mode** in the main navigation. The first game is Valorant. While Gamer Mode is
on and Valorant is the app in front, Nook takes a screenshot of the user's own screen every few seconds (Settings ›
Gamer Mode) and lets the chosen brain read it into structured events. It never reads game memory or sends input to the
game. Events can also be logged by hand.

| Part | Tauri | Where |
|---|---|---|
| Supported games (one entry per game, its coach view in `GamerMode.svelte`) | ✓ | `core/src/games/mod.rs`, `src/views/games/GamerMode.svelte` |
| Valorant knowledge: agents, abilities (with aliases such as "tripwire"), ability kinds, maps, callouts as one key | ✓ | `core/src/games/valorant/catalog.rs` |
| Match memory: rounds with events (agent, ability, place, round time, effect, confidence, source), kept apart from earlier matches | ✓ | `core/src/games/valorant/memory.rs` (`games/valorant.json`) |
| Coach: enemy patterns over rounds, a changed or stale setup (only rounds Nook watched count), good adaptation, my habits, general tips | ✓ | `core/src/games/valorant/coach.rs` |
| Reading a screenshot (prompt, strict JSON parsing, only known agents and abilities) | ◐ (Windows and Linux; not run against a live match yet) · — Android (logging by hand works) | `core/src/games/valorant/observe.rs`, `src-tauri/src/games.rs` |
| Valorant Coach page, logging by hand, coaching as a toast, Settings › Gamer Mode | ✓ | `src/views/games/`, `src/lib/games.ts`, `src/lib/gamer.svelte.ts`, `src/views/settings/Games.svelte` |

## Agents and workspace

| Part (Mac) | Tauri | Where |
|---|---|---|
| Hub via hooks (Claude Code, Codex, Gemini CLI, Cursor, …) | ◐ (no "Started by an agent in …", AG-40, compaction line, AG-41, or approval audit log, AG-42) | `core/src/agents/`, `nook --hook` / `~/.nook/nook-hook` |
| Finishing stuck sessions (`SessionLiveness`: transcript, the session's own process via the hook) | ◐ (with tests; not with a real `claude`) | `core/src/agents/liveness.rs` |
| Agent notifications: expanded or compact (Settings › Voice & sound › Notifications), OK with a countdown ring | ◐ (compiled; not tested in the app) | `views/Bar.svelte`, `views/agents/AgentAlerts.svelte` |
| Readable MCP tool names (`McpToolName`) in approvals, timeline, and MCP connectors | ✓ | `core/src/agents/mcp_name.rs` |
| Linking with diff and backup (`AgentConfigInstaller`) | ✓ | `core/src/agents/` |
| Approving in the bar, multiple-choice questions (an open panel stays put and asks in a narrow bar) | ◐ (no "why it asks" and project scope, AG-43; no deny with a reason on desktop, AG-44; no granted rules, AG-45; no option previews or own answer with files, AG-46) | `views/agents/` |
| Agents tab, new session (with thinking level; choices remembered as soon as you make them), timeline | ◐ (free-text model field instead of the catalog, AG-25; composer chips and attachments, AG-90; auto-settle, settle actions and the list's row details, AG-110…AG-114; session lifecycle commands, AG-60…AG-83) | `views/agents/` |
| Diff with line numbers and highlighted words (`UnifiedDiff`) | ✓ | `lib/workspace/unifiedDiff.ts`, `views/agents/UnifiedDiffView.svelte` |
| Workspace sessions: Claude Code, Codex `exec`, Gemini CLI, queue, resume | ✓ (tested with a fake `claude`) | `core/src/workspace/manager.rs` |
| Codex app-server, ACP agents, Antigravity | ◐ (tested with fake `codex`, ACP and `agy_acp_server` scripts; not yet against the real agents) | `core/src/workspace/driver.rs` picks the transport from `RunProvider::transport()`: Codex over `codex app-server` (approvals for commands, file changes and MCP confirmations, questions, `turn/steer`, `turn/interrupt`, `thread/resume`; `codex exec` when `app-server --help` fails), Gemini CLI (`--acp`, headless when its help has no `--acp`), OpenCode and Cursor (`acp`), Grok (`agent stdio`) and Antigravity over ACP (`acp.rs`: `session/new`, `session/resume` or `session/load` without replaying, model/effort/mode settings, `session/request_permission` to the approval card or answered by the session's rights, `session/cancel`, `authenticate` on "Authentication required"). Antigravity (`antigravity.rs`): profile folder per account, Google sign-in link checked and opened, mode per rights, carry-on when it ends silent. Not ported: the Mac's pinned Antigravity server installer (no Windows/Linux release to pin; put `agy_acp_server` in `<Nook>/tools/antigravity-acp` or on `PATH`), images in prompts, ACP cost, a `session/load` that never answers, keeping a process between turns |
| Scheduled tasks (every day or some weekdays at a time, interval, once, webhook; to a new session or one session, fresh or continued; off until Settings › Agents › Automation allows them; "ask" by default, never full rights unattended; a fixed time missed by more than 10 minutes while asleep is skipped, an overdue interval or once-task runs on wake) | ◐ (unit tests for next run, DST, missed runs, overlap, restart; end to end with a fake `claude`; the settings page type-checks but was not clicked through in the app) | `core/src/workspace/schedule.rs`, `scheduler.rs`, `src-tauri/src/workspace/automation.rs`, `views/settings/AgentsAutomation.svelte` |
| Webhooks for scheduled tasks (`POST http://127.0.0.1:<port>/hooks/<task>`, loopback only, HMAC-SHA256 `X-Hub-Signature-256` with the secret in the secret store, delivery id against replays, 60 a minute, queue of 20, payload quoted as untrusted data, `{{body.path}}`/`{{headers.name}}` placeholders; the run always asks) | ◐ (signed delivery over a real socket tested end to end; the Mac's filters, duplicate key, coalescing, deliveries log and public relay are not ported) | `core/src/workspace/webhook.rs`, `scheduler.rs` |
| Automations for Nook Chat itself (`ScheduledTaskTarget.nook`, `schedule_task` from the chat) and their place in the Nook tab (the **Scheduled** section, the bar over a run's conversation, the *Scheduled run* marker) | ○ | Not yet ported: the Mac's `AppModel+ScheduleTools.swift`, `ScheduledTaskStore.runInNook` and `UI/Panel/NookScheduledTasks.swift` are the reference. |
| Automatic titles (the chosen brain titles a new session from its first message; a name you typed wins; rename by double-clicking the title) | ◐ (prompt, parsing and fallback unit-tested; not run against a live brain; no per-project title rules or "Regenerate title") | `core/src/workspace/titles.rs`, `src-tauri/src/workspace/automation.rs` |
| Handing a session to another agent or account (⋯ › Hand off to another agent…), with a budgeted context handoff shown in the timeline; switching back resumes the agent's own conversation with only what it missed | ◐ (end to end with a fake `claude`; the menu was not clicked through in the app; no fork) | `core/src/workspace/handoff.rs`, `views/agents/run/HandOff.svelte` |
| Delegating: Nook Chat hands a task to a new session (`start_agent_session`, approved in the plan) · a session delegates to a child session (`delegate_task`) | ✓ Nook Chat (`src-tauri/src/tools/agents.rs`) · ◐ sessions: the rules (rights never above the parent, depth 2, 4 at once, the child sees only the task) and starting the child are in `core/src/workspace/delegation.rs` and `commands::automation::delegate`, but the bridge has no `delegate_task`/`task_status` tool yet | `core/src/workspace/delegation.rs` |
| Git: changes, commit, push, pull request (all GitHub accounts, owner first), worktrees | ◐ (no auto-pull, publish or Settings › Source control, AG-120; no worktree cleanup report, AG-121; no commit style or PR body check, AG-122; GitHub only, AG-124; no "Work on this PR", AG-125) | `core/src/workspace/` |
| Terminals (portable-pty + xterm.js), browser (opens http(s):// addresses such as http://localhost:3000 directly; http and https only), dev servers | ◐ (one browser window for all sessions and no right panel per session, where the Mac app gives each session its own, AG-100) · `browser_screenshot` ◐ (a JPEG at most `max_width` wide; WebView2 through the DevTools protocol, WebKitGTK and WKWebView snapshots; the shrinking is unit-tested, the capture compiles for Windows but was not run on a Windows PC) | `src-tauri/src/workspace/`, `src-tauri/src/workspace/snapshot.rs` |
| Workspace for agents (MCP bridge `nook --mcp`) | ◐ (about 20 of the Mac's 48 tools; browser driving, sessions, delegation, scheduling, pull request watching, secrets, devices and rendered pages are AG-02…AG-13) | `src-tauri/src/workspace/` |
| Nook's own tools, Nook Chat and the screen for agents (`nook_tools`, `nook_use`, `nook_chat_*`, `take_over_screen`), agent sessions and music search as tools for Nook Chat | ◐ `nook_tools`/`nook_use` (the brain's registry; reads run directly, every action waits for the bar's approval card, whatever the session's rights, then runs through the action gate's plan runner and the audit log), `nook_chat_list`/`_read`/`_send` (sending always asks), `take_over_screen` read-only (the screen-reading tools for one session for up to 30 minutes; Nook cannot click or type for agents on Windows/Linux), and `list_agent_sessions`, `read_agent_session`, `message_agent_session`, `start_agent_session` for Nook Chat. Sources kept on this device never reach an agent. JSON-RPC, rules, chat rendering and session start are unit-tested in core; the app glue compiles (Windows target) but was not run against a live agent. Left out: music search (MPRIS and Windows media controls only report and control what plays; there is no Spotify connection yet), machines over SSH, and the notch strip with Stop while an agent holds the screen | `core/src/workspace/bridge_nook.rs`, `src-tauri/src/workspace/bridge/nook.rs`, `src-tauri/src/tools/agents.rs` |
| Usage and limits | ◐ | `views/workspace/` |

## Companion and Android

| Part (Mac) | Tauri | Where |
|---|---|---|
| Companion protocol (`CompanionModels`, `CompanionSeal`, `CompanionPush`) | ✓ (test vectors) | `core/src/companion/` |
| Companion server on Windows and Linux (pairing the iPhone app or Nook on Android) with what the Mac offers: a kept live connection (`subscribe`, `watch`, `watchChat`, `watchConversation`), retries (`CommandReceipts`), `platform`; starting sessions, conversations, history, manage, steer, pictures, diff, terminals and files; Home, usage, music; Nook chat; the Chats tab; pull requests | ◐ (sessions from a terminal: approve, answer and end, CO-10; no snooze or main thread; Chats: WhatsApp; pull requests: GitHub, without *Work on this*; no Live Activities, CO-07, `appIcons`, `attachments`; no scopes per phone, CO-03) | `core/src/companion/` (`server.rs`, `live.rs`, `*_digest.rs`), `src-tauri/src/companion/` (`backend.rs`, `remote.rs`, `home.rs`, `nook_chat.rs`, `inbox.rs`, `pulls.rs`) |
| Device key (`CompanionDeviceKey`): the server lists `deviceKey`, keeps the phone's public half (`bindKey`) and refuses its unsigned requests; Android makes a key per pairing, binds it and signs every request | ✓ (end to end over TCP, and CryptoKit's signatures as test vectors) | `core/src/companion/device_key.rs` |
| Push through the relay (`RelayPush`, `RelayPushClient`): each notification sealed with a key derived from the phone's pairing key and posted to the relay's `/v1/push`, so no Apple developer account is needed; Nook on Android registers its Firebase token (`register` with `fcm`) and always goes through the relay; Settings › Companion chooses between the relay and your own APNs key | ◐ (end to end against a fake relay, and the Mac's sealed vector opens; not tried against Nook's relay with a real phone) | `core/src/companion/relay_push.rs`, `server.rs`, `src/views/settings/CompanionPush.svelte` |
| Versions (`CompanionCompatibility`, `CompanionWire`): answers compressed for a phone that can open them, `protocolVersion`, `appVersion` and `oldestPhone` on `hello`, `list` and `subscribe`; the computer keeps what each phone runs, and Settings › Companion shows its app version and says when it is too old or a version behind | ✓ (behaviour; drawn as lines under the phone in the current Tauri Companion page, not yet as the Mac's `ConnectionRow` with its status and an expanded note: UI-88) | `core/src/companion/models.rs` (`phone_supported`, `phone_behind`), `server.rs`, `store.rs`, `src/views/settings/Companion.svelte` |
| Sessions in a terminal from the phone (`CompanionAgents.send`, `end`): a message continues the session in Nook (Claude Code, Codex, Gemini CLI; a copy while the terminal still works, `--fork-session`), with pictures; `canSend` says when it can; *End* ends the process | ✓ (not run with a real phone) | `core/src/companion/sessions.rs` (`can_continue_in_nook`), `src-tauri/src/companion/backend.rs`, `remote.rs`, `commands/workspace.rs` (`continue_live`) |
| Push notifications via APNs | ◐ (not tested against Apple) | `core/src/companion/apns.rs` |
| Routes (`CompanionEndpoints`): the `.local` name and every LAN and Tailscale address in the code (`&a=`) and in each `hello`/`list` answer; an address in 100.64/10 counts as Tailscale only when its interface is named after it or `tailscale ip -4` names it | ✓ | `core/src/companion/server.rs` (`Reach`), `src-tauri/src/companion/reach.rs` |
| Away from home through a relay (`CompanionRelayClient`): a room per paired phone and one for the pairing window, the relay in the code (`&r=`) and in each answer, keep-alive, reconnect after sleep or on another network, *Test relay* | ✓ (end to end against a fake relay that speaks the real mux; Nook's relay from the build setting `NOOK_RELAY_URL`; setting up your own relay on Cloudflare from Settings is not ported: deploy `apps/relay` and enter its address) | `core/src/companion/relay.rs` |
| Keeping the computer awake (`KeepAwake`, `KeepAwakePolicy`) | ✓ (`SetThreadExecutionState` on Windows, `systemd-inhibit` on Linux; Windows follows the power plan's lid setting) | `core/src/companion/keep_awake.rs`, `src-tauri/src/companion/keep_awake.rs` |
| Keeping Nook running (no Mac counterpart; how t3code runs its server as a service): a Task Scheduler task at sign-in and every minute with `IgnoreNew` on Windows, a systemd user service with `Restart=on-failure` on Linux, both starting `nook --background` | ✓ (not yet run on a real PC) | `src-tauri/src/companion/background.rs` |
| Android as a companion, laid out and worded as the iPhone app (see COMPANION.md, *Android*): the companion is the whole app once paired; tabs, headers, cards, shelves, transcript in turns, docked approvals, composer with Steer now, New session, Nook chat, Chats with the WhatsApp skin, Settings; a kept live connection (`subscribe`, `watch`, `watchChat`) while in front | ◐ (browser tests against a fake computer with Android phone emulation, unit tests, `cargo check` for aarch64-linux-android; not run on a real phone; pull requests, review, pictures and dictation added; still missing: see ANDROID-COMPANION-TODO.md) | `src/views/companion/`, `core/src/companion/client.rs` |
| Android project, phone layout, Share with Nook, back button | ◐ (APK only via CI) | `src-tauri/gen/android` |
| Secrets in the Android Keystore | ○ (private app folder without backup) | `platform/secrets.rs` |

## To do

The full list of what is still missing for a 1:1 match with the Mac, as numbered items to work through one by one, is
[WINDOWS-PARITY.md](WINDOWS-PARITY.md).

- Error messages written on the Rust side are still partly Dutch (FD-04); the interface itself has the Mac's five
  languages.
- Real testing on Windows and on an Android device.
- Everything marked ○ above.

## Testing against fake services

- Fake brain: start your own server and set `OLLAMA_HOST=http://127.0.0.1:<port>`.
- Fake APIs, debug builds only: `NOOK_GITHUB_API_URL` and `NOOK_<SERVICE>_API_URL`. ICS feeds accept `http://` only for 127.0.0.1 and localhost.
- Fake agent: a `claude` script in `PATH` that prints stream-json.
