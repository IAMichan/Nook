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
| Memory (`Memory`, `NookMemory`, Settings › Memory) | ✓ (importing MCP memory ◐) | `core/src/brain/memory.rs`, `tools/memory.rs` |
| Web, weather, charts, mail drafts | ✓ (mail via `mailto:`) | `tools/{web,charts,mail}.rs` |
| `ClaudeCodeBrain` | ◐ (not tested with a real `claude`) | `core/src/brain/claude_code.rs` |
| `NookStore`, `NookChat` (Nooks, `nooks.json`, archive, search) | ✓ | `core/src/store.rs`, `core/src/nooks.rs` |
| `SecretStore` | ✓ | Credential Manager, Secret Service, private app folder on Android |
| Plans with Run, never run twice, Undo | ✓ | `src-tauri/src/commands/plans.rs` |
| Onboarding (welcome card, three steps) | ✓ | `src/views/` |
| `AppleIntelligence`, `EmbeddedModel` (MLX), `MacReport` | — | Apple only; local thinking goes through Ollama or LM Studio |

## Connectors

| Part (Mac) | Tauri | Where |
|---|---|---|
| Framework (Connector, Hub, catalog, brands) | ✓ | `core/src/connectors/` |
| Calendars: ICS ("Other calendars"), Cal.com, `check_availability` | ✓ | `ics.rs`, `agenda.rs`, `feeds.rs` |
| System calendars (Apple Calendar) | — | No API in this port |
| GitHub (read; review, merge, close as an action) | ✓ | `github.rs` |
| Pull requests under Agents: yours, awaiting your review, followed organizations and repositories (Settings › Accounts & connections), filters (status, involvement, author, draft, checks), reading with reviews and comments (GitHub HTML as Markdown), merging after confirmation in the bar, with an action log | ◐ (tested against a fake API, not against GitHub itself) | `pulls.rs`, `github_markdown.rs`, `views/agents/pulls/` |
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
| Codex app-server, ACP agents, Antigravity | ○ | |
| Delegating, handing off, scheduled tasks, webhooks, automatic titles | ○ | |
| Git: changes, commit, push, pull request (all GitHub accounts, owner first), worktrees | ✓ | `core/src/workspace/` |
| Terminals (portable-pty + xterm.js), browser (opens http(s):// addresses such as http://localhost:3000 directly; http and https only), dev servers | ✓ (no browser screenshot) | `src-tauri/src/workspace/` |
| Workspace for agents (MCP bridge `nook --mcp`) | ✓ | `src-tauri/src/workspace/` |
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

- The interface is Dutch-only; the Mac also has English, German, French, and Spanish.
- Real testing on Windows and on an Android device.
- Everything marked ○ above.

## Testing against fake services

- Fake brain: start your own server and set `OLLAMA_HOST=http://127.0.0.1:<port>`.
- Fake APIs, debug builds only: `NOOK_GITHUB_API_URL` and `NOOK_<SERVICE>_API_URL`. ICS feeds accept `http://` only for 127.0.0.1 and localhost.
- Fake agent: a `claude` script in `PATH` that prints stream-json.
