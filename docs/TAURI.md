# The Tauri app: what has been ported from the Mac

`apps/tauri` brings Nook to Windows, Linux, and Android. The macOS app is the specification; this list tracks what is
already there.

✓ = ported and tested in the app · ◐ = partial, or only compiled and not actually run · ○ = not yet · — = not possible on this platform

> Windows code compiles in CI and locally with `cargo check -p nook --target x86_64-pc-windows-gnu`, but has not (yet)
> been run on a real Windows PC. Android builds only in CI (job **Android**); the Android SDK could not be downloaded
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
| `ModelProfile`, `ModelAdvisor`, `ModelDownload` (one-click Ollama install) | ✓ | `core/src/brain/profile.rs`, `model_download.rs` |
| `ChatIntent`, `LocalIntent`, `QueryPlan`, `SourceScope`, `Fuzzy`, `NookDates`, `FollowUps` | ✓ | `core/src/brain/` |
| `Research`, `Retrieval` (searching on its own, numbered sources) | ✓ | `core/src/brain/research.rs`, `retrieval.rs` |
| Sources card under an answer (status per source, unread sources on top with a reason and Try again, errors in plain language) | ✓ | `components/SourcesView.svelte`, `lib/sources.ts` |
| Chat tables: text columns with digits in a name don't become a chart (`ChartRescue.tableNumber`) | ✓ | `core/src/brain/chart.rs` |
| `ActionGate`, `CommandRisk`, `Undo`, `NetworkGuard`, `LocalQuality` | ✓ | `core/src/brain/` |
| Memory (`Memory`, `NookMemory`, Settings › Assistant) | ✓ (importing MCP memory ◐) | `core/src/brain/memory.rs`, `tools/memory.rs` |
| Web, weather, charts, mail drafts | ✓ (mail via `mailto:`) | `tools/{web,charts,mail}.rs` |
| `ClaudeCodeBrain` | ◐ (not tested with a real `claude`) | `core/src/brain/claude_code.rs` |
| `NookStore`, `NookChat` (Nooks, `nooks.json`, archive, search) | ✓ | `core/src/store.rs`, `core/src/nooks.rs` |
| Asking about a selection (`SelectionAsk`: a bar above selected text anywhere in Nook, the answer in a card beside it) | ◐ | `src/components/SelectionAsk.svelte` (mounted once in `App.svelte` for the main window), `src/lib/selection-ask.ts` (+ tests), `nook_new_background` in `src-tauri/src/commands/selection_ask.rs`, setting `selectionAsk` (Settings › Brain › Answers). Ask Nook, Explain, Translate and Copy over a selection by drag, double click or keys; the answer is a background Nook asked through the chat's `ask`, shown in a card with follow-up, Stop, and Continue in chat. Checked with unit tests and in a browser with a stubbed backend, not yet in the running app. Not ported: the bar in the bar window and the other small windows, Quote into an agent session's reply box, the drag across several chat messages with the chat around a selection as context (`TranscriptSelection`), and the hidden note that tells the brain the quote is material, not instructions. |
| `SecretStore` | ✓ | Credential Manager, Secret Service, private app folder on Android |
| Plans with Run, never run twice, Undo | ✓ | `src-tauri/src/commands/plans.rs` |
| Main window like the Mac and the Claude app: list grouped Today / Yesterday / Previous 7 days / Older under the pinned, time-of-day greeting with a "waiting for you" line, title you rename in place, sidebar state remembered, sidebar as an overlay in a narrow window | ✓ (tested in unit tests and svelte-check; not run on a real window) | `lib/conversation-list.ts`, `components/NookList.svelte`, `components/Chat.svelte`, `views/Main.svelte` |
| Onboarding (welcome card, three steps) | ✓ | `src/views/` |
| Interface in the Mac's five languages (English by default or the system language; Dutch, German, French, Spanish; Settings › General › Language), tray menu included | ✓ (Rust error messages partly Dutch) | `lib/i18n.svelte.ts`, `lib/i18n/*.ts`, `lib/i18n.test.ts` |
| Main window sidebar like the Mac (`PanelSidebar`): Search and Talk in the head; tabs Nook, Agents, Chats, and Music while something plays; Settings, Pull requests, Usage in the footer | ✓ (seen in a browser with a stubbed backend; not on a real window) | `views/Main.svelte`, `lib/shell-routes.ts` |
| Empty chat like the Mac (`NookTab.emptyState`, `NookStarters`, `NookGlance`): date, greeting with what waits, For you, glance cards (agents, next event, now playing), starter grid | ✓ (no plan-limits card, no split view) | `components/Chat.svelte`, `ForYou.svelte`, `HomeGlance.svelte`, `StarterGrid.svelte` |
| Settings like the Mac: groups, icons, search (Ctrl+F or /), breadcrumb bar, Overview page | ✓ | `views/Settings.svelte`, `views/settings/Overview.svelte` |
| Settings › Shortcuts: the global shortcuts (moved from General) and a cheat sheet of the main window's keys with a filter (`ShortcutCheatSheetView`) | ✓ (the sheet is checked against `shellShortcut` in tests) | `views/settings/Shortcuts.svelte`, `lib/shortcut-sheet.ts` |
| Settings › Instructions: default answer style (`ResponseStyle`) and your own standing instructions, both in the brain's system prompt | ◐ (style and free text; the Mac's saved prompts, spaces and context inspector ○; prompt tested in core, not against a live model) | `views/settings/Instructions.svelte`, `core/src/instructions.rs`, `brain/service.rs` |
| Settings › Agents › Archive: archived coding agent sessions and Nook conversations, search, restore, delete, "Delete all archived…" with one confirmation, never what still works | ✓ (seen in a browser with a stubbed backend) | `views/settings/Archive.svelte`, `lib/archive.ts` |
| Settings › Maintenance: data folder, cache size and clearing, export settings (save dialog), restore defaults (keeps language, welcome, window), versions to copy, updates via the releases page (no built-in updater) | ◐ (core tested; commands compiled for Windows, not run in a real window) | `views/settings/Maintenance.svelte`, `core/src/maintenance.rs`, `commands/maintenance.rs` |
| Settings › About: version, source code, what's new, report a problem, license, open source notices | ✓ | `views/settings/About.svelte` |
| `NookTheme` tokens: type scale, spacing, radii, palette | ✓ | `src/app.css` |
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
| Second account per service, account per chat | ✓ | `accounts.rs`, `ChatAccounts.svelte` |
| GitLab, Vercel, Stripe, Notion, Cal.com, n8n, Resend | ✓ (GitLab token checked first via `/api/v4/user`) | `gitlab.rs`, `cloud.rs` |
| Settings › Accounts & connections as one catalog: search, categories, rows for your connections (including GitLab and custom MCP servers), cards with Sign in / With a key / MCP | ✓ | `views/settings/Accounts.svelte`, `views/connectors/` |
| Custom sources (web APIs, webhooks) | ✓ | `custom.rs` |
| Connecting with OAuth (Notion, Linear, Stripe, Vercel, Sentry); repairing an expired key by signing in | ◐ (not tested against the real services) · — Android | `oauth.rs`, `commands/connectors.rs` |
| MCP client (stdio, HTTP) | ✓ (stdio desktop only) | `core/src/connectors/mcp/` |
| WhatsApp live (GOWA) | ◐ (start the gateway yourself; installer ○) | `core/src/connectors/whatsapp/` |
| WhatsApp card in the bar: chat as bubbles with ticks, photos in the card (large with a click), files and videos open with the system app, reply, Mute, Let Nook reply (reads only that chat, only suggests a reply to that chat, learns nothing) | ◐ (tested with a fake gateway, not with a real phone; only in the bar, not on Android; video doesn't play in the card and documents show no first page) | `views/connectors/WhatsAppCard.svelte`, `lib/whatsapp.svelte.ts`, `src-tauri/src/commands/whatsapp.rs` |
| WhatsApp per chat: people, groups, status updates, and channels each a row; per chat Automatic, Always, or Never; hidden chats back one by one | ✓ | `core/src/connectors/whatsapp/mod.rs`, `views/connectors/WhatsApp.svelte` |
| `@chat` (WhatsApp chat next to the chat), sending via WhatsApp Web | — | No `@open` mechanism and no embedded WhatsApp Web in this port |
| Portfolio | ○ | |
| Apple Notes, Reminders, Mail.app, Messages, Bear, Things | — | Mac apps |

## Platform services

| Part (Mac) | Tauri | Where |
|---|---|---|
| Reading the screen (`ScreenReader`, `ScreenContext`, `AppTextReader`) | ✓ Linux (AT-SPI, X11, tesseract) · ◐ Windows (UI Automation, OCR) · — Android | `core/src/services/screen.rs`, `platform/` |
| Screen region | ✓ (without annotating) | `services/part.rs` |
| Look Along, Think Along (answers in the app's language, not that of Nook's own question) | ✓ | `core/src/services/think_along.rs` |
| Music (`NowPlayingService`, Music tab) | ✓ MPRIS · ◐ Windows media controls | `platform/linux/mpris.rs`, `platform/windows/media.rs` |
| System: apps, volume, clipboard, files, notifications | ✓ Linux · ◐ Windows | `platform/*`, `tools/{system,files,clipboard}.rs` |
| Voice: read aloud, speech to text (whisper.cpp or a chosen service) | ◐ (reading aloud tested; recording not, no microphone) | `core/src/services/`, `services/voice.rs` |
| "Hey Nook" | ◐ Windows · — Linux and Android | `platform/windows/speech.rs` |
| Autocomplete everywhere (`AutocompleteController`, `CompletionSuggestion`, `CompletionPrivacy`, `CompletionEmoji`, Settings › Autocomplete) | ◐ Windows (compiled, not run on a real PC; Testing tab on Linux too) · — Linux and Android | `core/src/services/autocomplete/`, `src-tauri/src/services/autocomplete.rs`, `platform/windows/autocomplete.rs` |
| Flow dictation | ◐ (logic with tests; not tested with a microphone) | `core/src/services/flow.rs` |
| Notetaker | ◐ (no speaker recognition) | `core/src/services/notes.rs` |
| Today, weekly recap (with agent figures per project) | ✓ | `core/src/services/recap.rs`, `views/Today.svelte` |
| Nook itself (orb, ring, sounds) | ✓ | `components/Orb.svelte`, `lib/sounds.ts` |
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
| Hub via hooks (Claude Code, Codex, Gemini CLI, Cursor, …) | ✓ | `core/src/agents/`, `nook --hook` / `~/.nook/nook-hook` |
| Finishing stuck sessions (`SessionLiveness`: transcript, the session's own process via the hook) | ◐ (with tests; not with a real `claude`) | `core/src/agents/liveness.rs` |
| Agent notifications: expanded or compact (Settings › Voice & sound › Notifications), OK with a countdown ring | ◐ (compiled; not tested in the app) | `views/Bar.svelte`, `views/agents/AgentAlerts.svelte` |
| Readable MCP tool names (`McpToolName`) in approvals, timeline, and MCP connectors | ✓ | `core/src/agents/mcp_name.rs` |
| Linking with diff and backup (`AgentConfigInstaller`) | ✓ | `core/src/agents/` |
| Approving in the bar, multiple-choice questions (an open panel stays put and asks in a narrow bar) | ✓ | `views/agents/` |
| Agents tab, new session (with thinking level; choices remembered as soon as you make them), timeline | ✓ | `views/agents/` |
| Diff with line numbers and highlighted words (`UnifiedDiff`) | ✓ | `lib/workspace/unifiedDiff.ts`, `views/agents/UnifiedDiffView.svelte` |
| Workspace sessions: Claude Code, Codex `exec`, Gemini CLI, queue, resume | ✓ (tested with a fake `claude`) | `core/src/workspace/manager.rs` |
| Codex app-server, ACP agents, Antigravity | ◐ (tested with fake `codex`, ACP and `agy_acp_server` scripts; not yet against the real agents) | `core/src/workspace/driver.rs` picks the transport from `RunProvider::transport()`: Codex over `codex app-server` (approvals for commands, file changes and MCP confirmations, questions, `turn/steer`, `turn/interrupt`, `thread/resume`; `codex exec` when `app-server --help` fails), Gemini CLI (`--acp`, headless when its help has no `--acp`), OpenCode and Cursor (`acp`), Grok (`agent stdio`) and Antigravity over ACP (`acp.rs`: `session/new`, `session/resume` or `session/load` without replaying, model/effort/mode settings, `session/request_permission` to the approval card or answered by the session's rights, `session/cancel`, `authenticate` on "Authentication required"). Antigravity (`antigravity.rs`): profile folder per account, Google sign-in link checked and opened, mode per rights, carry-on when it ends silent. Not ported: the Mac's pinned Antigravity server installer (no Windows/Linux release to pin; put `agy_acp_server` in `<Nook>/tools/antigravity-acp` or on `PATH`), images in prompts, ACP cost, a `session/load` that never answers, keeping a process between turns |
| Delegating, handing off, scheduled tasks, webhooks, automatic titles | ○ | |
| Git: changes, commit, push, pull request (all GitHub accounts, owner first), worktrees | ✓ | `core/src/workspace/` |
| Terminals (portable-pty + xterm.js), browser (opens http(s):// addresses such as http://localhost:3000 directly; http and https only), dev servers | ✓ (no browser screenshot; one browser window for all sessions, where the Mac app gives each session its own) | `src-tauri/src/workspace/` |
| Workspace for agents (MCP bridge `nook --mcp`) | ✓ | `src-tauri/src/workspace/` |
| Nook's own tools, Nook Chat and the screen for agents (`nook_tools`, `nook_use`, `nook_chat_*`, `take_over_screen`), agent sessions and music search as tools for Nook Chat | ◐ `nook_tools`/`nook_use` (the brain's registry; reads run directly, every action waits for the bar's approval card, whatever the session's rights, then runs through the action gate's plan runner and the audit log), `nook_chat_list`/`_read`/`_send` (sending always asks), `take_over_screen` read-only (the screen-reading tools for one session for up to 30 minutes; Nook cannot click or type for agents on Windows/Linux), and `list_agent_sessions`, `read_agent_session`, `message_agent_session`, `start_agent_session` for Nook Chat. Sources kept on this device never reach an agent. JSON-RPC, rules, chat rendering and session start are unit-tested in core; the app glue compiles (Windows target) but was not run against a live agent. Left out: music search (MPRIS and Windows media controls only report and control what plays; there is no Spotify connection yet), machines over SSH, and the notch strip with Stop while an agent holds the screen | `core/src/workspace/bridge_nook.rs`, `src-tauri/src/workspace/bridge/nook.rs`, `src-tauri/src/tools/agents.rs` |
| Usage and limits | ◐ | `views/workspace/` |

## Companion and Android

| Part (Mac) | Tauri | Where |
|---|---|---|
| Companion protocol (`CompanionModels`, `CompanionSeal`, `CompanionPush`) | ✓ (test vectors) | `core/src/companion/` |
| Companion server on Windows and Linux (pairing the iPhone app): all workspace and hook sessions; approve, answer, steer, stop | ✓ (sessions from a terminal: approve and answer only) | `core/src/companion/`, `src-tauri/src/companion/backend.rs` |
| Push notifications via APNs | ◐ (not tested against Apple) | `core/src/companion/apns.rs` |
| Android as a companion (like the iPhone app) | ✓ (notifications only while the app runs; no FCM) | `src/views/companion/` |
| Android project, phone layout, Share with Nook, back button | ◐ (APK only via CI) | `src-tauri/gen/android` |
| Secrets in the Android Keystore | ○ (private app folder without backup) | `platform/secrets.rs` |

## To do

- Error messages written on the Rust side are still partly Dutch; the interface itself has the Mac's five languages.
- Real testing on Windows and on an Android device.
- Everything marked ○ above.

## Testing against fake services

- Fake brain: start your own server and set `OLLAMA_HOST=http://127.0.0.1:<port>`.
- Fake APIs, debug builds only: `NOOK_GITHUB_API_URL` and `NOOK_<SERVICE>_API_URL`. ICS feeds accept `http://` only for 127.0.0.1 and localhost.
- Fake agent: a `claude` script in `PATH` that prints stream-json.
