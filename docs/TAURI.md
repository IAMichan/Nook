# The Tauri app: what has been ported from the Mac

`apps/tauri` brings Nook to Windows, Linux, and Android. The macOS app is the specification; this list tracks what is
already there. [WINDOWS-PARITY.md](WINDOWS-PARITY.md) is the checklist of everything still missing.

✓ = ported and tested in the app · ◐ = partial, or only compiled and not actually run · ○ = not yet · — = not possible on this platform

Each section is a list of entries, one line each, sorted by part name with a blank line between them, so parallel pull
requests add and edit entries in different spots and don't conflict. Put a new entry in its sorted spot, not at the
end; `scripts/docs-merge-layout.py --fix` sorts and spaces them, and CI checks the layout.

> Windows code compiles locally with `cargo check -p nook --target x86_64-pc-windows-gnu` (needs `mingw-w64`). In CI
> the **Windows checks** job runs clippy, the Rust tests and the interface tests on `windows-latest`, including the
> Windows-only tests (named pipes for hooks, `cmd /C` MCP servers, the Task Scheduler task). The app itself has not
> (yet) been run on a real Windows PC. Android builds only in CI (job **Android**); the Android SDK could not be downloaded
> locally.

**Want to help?** Every ○ and ◐ entry below is open for contributors, and so is the [To do](#to-do) list. You don't need
a Mac for any of it. See [CONTRIBUTING.md](../CONTRIBUTING.md#windows-linux--android-tauri).

## Core and chat

- `ActionGate`, `CommandRisk` (also what runs inside `sh -c`, `xargs`, `find -exec`, and on Windows `cmd /c` and PowerShell `-Command`), `Undo`, `NetworkGuard`, `LocalQuality`. **Tauri:** ✓. **Where:** `core/src/brain/`

- `AIProvider`, `BrainSelection`, `AppSettings`. **Tauri:** ✓. **Where:** `core/src/provider.rs`, `core/src/settings.rs`

- Anthropic, OpenAI-compatible, Ollama (streaming, tools, images; Ollama frees memory after 90 s, Think Along unloads a model it loaded itself). **Tauri:** ✓. **Where:** `core/src/brain/conversations.rs`, `services/think.rs`

- `AppleIntelligence`, `EmbeddedModel` (MLX), `MacReport`. **Tauri:** —. **Where:** Apple only; local thinking goes through Ollama or LM Studio

- Asking about a selection (`SelectionAsk`: a bar above selected text anywhere in Nook, the answer in a card beside it). **Tauri:** ◐. **Where:** `src/components/SelectionAsk.svelte` (mounted once in `App.svelte` for the main window), `src/lib/selection-ask.ts` (+ tests), `nook_new_background` in `src-tauri/src/commands/selection_ask.rs`, setting `selectionAsk` (Settings › Brain › Answers). Ask Nook, Explain, Translate and Copy over a selection by drag, double click or keys; the answer is a background Nook asked through the chat's `ask`, shown in a card with follow-up, Stop, and Continue in chat. Checked with unit tests and in a browser with a stubbed backend, not yet in the running app. Not ported: the bar in the bar window and the other small windows, Quote into an agent session's reply box, the drag across several chat messages with the chat around a selection as context (`TranscriptSelection`), and the hidden note that tells the brain the quote is material, not instructions.

- `BrainService` (prompts, prioritizing, `use_source`, context budget). **Tauri:** ✓. **Where:** `core/src/brain/service.rs`

- Changing settings from the chat (`AppModel+SettingsTools`, `SettingsCatalog`): `get_settings`, `change_setting` (approved in the plan, through the same save as Settings, undone with "undo that") and `open_settings` at a subject; 16 settings (languages, the bar's placement and hiding, look, energy, web search, Think Along, screens, reading aloud, Hey Nook, agent sounds and notices, memory). The Mac's notch switches, face style, dictation, per-kind notices for chats/Nook/suggestions and lyrics wait for their own Settings rows (UI-16, UI-56, UI-17); `bar_placement` (top/floating) stands for the Mac's `notch_placement`. **Tauri:** ✓ (catalog, words to values, read/write round trip and undo unit-tested; not run against a live model). **Where:** `core/src/settings_catalog.rs`, `src-tauri/src/tools/settings.rs`

- Chat tables: text columns with digits in a name don't become a chart (`ChartRescue.tableNumber`). **Tauri:** ✓. **Where:** `core/src/brain/chart.rs`

- `ChatIntent`, `LocalIntent`, `QueryPlan`, `SourceScope`, `Fuzzy`, `NookDates`, `FollowUps` (up to three next steps under an answer, two on a card, with the Mac's prompt). **Tauri:** ✓. **Where:** `core/src/brain/`

- `ClaudeCodeBrain`. **Tauri:** ◐ (not tested with a real `claude`). **Where:** `core/src/brain/claude_code.rs`

- `ConversationWindow` (the conversation sized to the brain: newest turn up to two thirds, recent turns whole, older ones shortened with "…", the rest folded into a recap of earlier questions that intent and research leave out). **Tauri:** ✓. **Where:** `core/src/brain/conversation_window.rs`, `Conversation::window_hiding` in `core/src/nooks.rs`, used by `commands/chat.rs`, `service.rs` (Claude Code and small local models get it as text)

- Empty chat like the Mac (`NookTab.emptyState`, `NookStarters`, `NookGlance`): date, greeting with what waits, For you, glance cards (agents, next event, plan limits per account with the fullest window and the Mac's amber/coral tones, now playing), starter grid. **Tauri:** ◐ (plan limits only for Claude Code accounts, the only agent that reports plan windows here so far, AG-47; no split view, UI-35; fewer starter signals, BR-50; starter grid not yet checked against `NookStarters`, UI-42). **Where:** `components/Chat.svelte`, `ForYou.svelte`, `HomeGlance.svelte`, `StarterGrid.svelte`

- Interface in the Mac's five languages (English by default or the system language; Dutch, German, French, Spanish; Settings › General › Language), tray menu included. **Tauri:** ◐ (Rust error and status messages partly Dutch, FD-04). **Where:** `lib/i18n.svelte.ts`, `lib/i18n/*.ts`, `lib/i18n.test.ts`

- Live plan above an answer (`update_plan`, `TaskChecklistCard`): the brain keeps a step checklist for a request of several steps, offered to every brain that works in steps, never to agents; a step left running when the answer stops reads as still to do. **Tauri:** ✓ (parsing and settling unit-tested; not run against a live model). **Where:** `core/src/brain/task_steps.rs`, `src-tauri/src/tools/plan.rs`, `components/TaskChecklist.svelte`, `lib/task-steps.ts`

- Main window like the Mac and the Claude app: list grouped Today / Yesterday / Previous 7 days / Older under the pinned, time-of-day greeting with a "waiting for you" line, title you rename in place, sidebar state remembered, sidebar as an overlay in a narrow window. **Tauri:** ◐ (tested in unit tests and svelte-check; not run on a real window; split view and torn-off tabs UI-35, back and forward UI-36, resizable sidebar UI-37, the Mac's list with header tabs, hover card and multi-select BR-45). **Where:** `lib/conversation-list.ts`, `components/NookList.svelte`, `components/Chat.svelte`, `views/Main.svelte`

- Main window sidebar like the Mac (`PanelSidebar`): Search and Talk in the head; tabs Nook, Agents, Chats, and Music while something plays; Settings, Pull requests, Usage in the footer. **Tauri:** ◐ (seen in a browser with a stubbed backend; the visual audit found the orb in the head and extra footer icons, UI-85; no update button in the footer, UI-38, and no resizable width, UI-37). **Where:** `views/Main.svelte`, `lib/shell-routes.ts`

- Markdown in answers and transcripts (`MarkdownView`, `MarkdownExtras`, `SyntaxTokenizer`, `CodeRender`, `AnswerImages`): syntax colours for 11 languages, fence file names (`title=`, `file=`, bare path), line wrap, Run in terminal for safe shell blocks in a session folder, nested/unclosed `<details>`, standalone images (`https:` / `http://localhost` / verified local files via `read_answer_image`), right-aligned numeric tables with copy as Markdown or CSV, callouts, hover link addresses with host suffix, Mermaid/KaTeX, and sandboxed HTML/SVG preview with strict CSP. **Tauri:** ✓ (parser, syntax tokenizer, image magic-byte loader and i18n unit-tested; not yet visual-checked in the running window). **Where:** `core/src/brain/answer_images.rs`, `src/lib/syntax.ts`, `src/lib/markdown-blocks.ts`, `src/components/Markdown*.svelte`, `commands::read_answer_image`

- Memory (`Memory`, `NookMemory`, Settings › Assistant), with importing the MCP memory server's knowledge graph (found in npm's cache on macOS, Linux and Windows, imported once with a running total and an audit entry, and an offer to remove the old server). **Tauri:** ✓ (import parsing, the cache paths and the old-server check unit-tested; the import has not been run on a real graph on Windows). **Where:** `core/src/brain/memory.rs`, `tools/memory.rs`, `views/settings/Memory.svelte`

- `MessageTrust`: phishing and scam scoring (a brand from another domain, look-alike domains, log-in, payment and deadline pressure, prizes, gift cards, the "new number" story; less for someone the user wrote with), a WARNING line above a WhatsApp chat the brain reads or finds, and the Mac's phishing rule in the system prompt. **Tauri:** ◐ (the Mac's cases unit-tested; WhatsApp is the only chat and mail reader in Tauri so far: other chat apps and mail get the marker when their readers land in section 5; owed replies and reply suggestions are CH-39). **Where:** `core/src/brain/message_trust.rs`, `whatsapp::lines_with_trust`

- `ModelProfile`, `ModelAdvisor`, `ModelDownload` (one-click Ollama install). **Tauri:** ✓. **Where:** `core/src/brain/profile.rs`, `model_download.rs`

- Nook Chat titles (`nameAfterFirstAnswer`, `ConversationTitle`): after a Nook's first answer the chosen brain writes a two-to-five-word title, only while the title is still the question's own; a local brain skips it while another answer runs. **Tauri:** ◐ (prompt and cleaning unit-tested; not run against a live brain). **Where:** `core/src/brain/conversation_title.rs`, `name_after_first_answer` in `commands/chat.rs`

- Nook's own browser from Nook Chat (`read_nook_browser`, `open_in_nook_browser`): reads the open page without starting the browser; opens `https://` addresses after approval in the chat's plan and brings the browser window forward. **Tauri:** ◐ (`https` check and page formatting unit-tested; compiles for Windows; not run inside the app window). **Where:** `core/src/workspace/browser.rs`, `src-tauri/src/tools/browser.rs`

- `NookAccess`: what Nook may do by itself from the chat, chosen under the composer (a chip, or Shift+Tab) and in Settings › Assistant: ask first, small things right away (music, volume, an app, a reminder, a to-do), or more (also an event without guests, ticking off a reminder, a note); only when the user's own words ask for it; the old "small things" switch migrates. **Tauri:** ◐ (levels, migration and the word checks unit-tested in core and the frontend; not clicked through in the running app; changing an event always asks because the app cannot see an event's guests, and taking over a task waits for BR-29). **Where:** `core/src/brain/access.rs`, `can_run_without_asking` in `commands/chat.rs`, `lib/access.ts`, `components/Composer.svelte`

- `NookStore`, `NookChat` (Nooks, `nooks.json`, archive, search). **Tauri:** ✓. **Where:** `core/src/store.rs`, `core/src/nooks.rs`

- `NookTheme` tokens: type scale (with `strong` as `--text-emphasis`), spacing, radii, palette (dark and light), motion durations, tooltip width; checked 1:1 against the Swift sources by a test, and a lint that stops new inline colors, font sizes and radii (`UIConsistencyTests`). **Tauri:** ✓ (deviation: `--menu` stays white in light, because Tauri menus use the theme's text color where the Mac draws its dark menus with their own; the 149 older files with inline values are UI-76). **Where:** `src/app.css`, `src/theme/theme-tokens.test.ts`, `src/theme/ui-lint.test.ts`, `src/theme/ui-baseline.json`

- Onboarding (welcome card, three steps). **Tauri:** ✓. **Where:** `src/views/`

- OpenRouter sign-in instead of a key (`OpenRouterSignIn`): OpenRouter's page in the system browser, PKCE, the code back on 127.0.0.1, traded for a key that goes into the keychain like a pasted one. **Tauri:** ◐ (page address, code and key handling unit-tested; not signed in against OpenRouter for real; the Mac comes back through `nook://`, here through the loopback the MCP sign-in uses). **Where:** `core/src/connectors/openrouter.rs`, `openrouter_sign_in`, `views/settings/Brain.svelte`

- Plans with Run, never run twice, Undo. **Tauri:** ✓. **Where:** `src-tauri/src/commands/plans.rs`

- `Research`, `Retrieval` (searching on its own, numbered sources). **Tauri:** ✓. **Where:** `core/src/brain/research.rs`, `retrieval.rs`

- `SecretStore`. **Tauri:** ✓. **Where:** Credential Manager, Secret Service, private app folder on Android

- Settings controls like the Mac's (`SettingsFormStyle`, `SettingsRowToggleStyle`, `SettingsControl`): a switch for every on/off row (a checkbox with `role="switch"`, drawn as a switch; weekday picks stay boxes), capsule menus with up/down chevrons 28 px high, segmented pickers for two to four choices (appearance, background work), small buttons in the control fill, rows 12 px high padding in cards on the surface. **Tauri:** ✓ (compared with the Mac's Settings rendered offscreen; seen in a browser with a stubbed backend, not on a real window). **Where:** `views/settings/settings.css`, `views/settings/Segmented.svelte`

- Settings like the Mac: the Mac's pages in its five groups (Nook, Intelligence, Agents, Connections, System; Gamer Mode as a Tauri-first page), a page with several subjects behind one tab bar (`SettingsPartTabs`), icons, search over the subjects (Ctrl+F or /), breadcrumb bar, Overview page. Mac subjects without Tauri content yet (Notifications per app, Worktrees, Editor & browser, Projects & pull requests, Machines, the privacy parts) wait for their items. **Tauri:** ◐ (layout and its aliases unit-tested; not seen in a real window; no search over every row, attention counts, restore per page, page intros, folds, setup sheets or one field style, UI-03…UI-11; a short Overview, UI-07). **Where:** `lib/settings-pages.ts` (+ tests), `views/Settings.svelte`, `views/settings/SettingsPartTabs.svelte`, `views/settings/Overview.svelte`

- Settings › About: version, source code, what's new, report a problem, license, open source notices. **Tauri:** ✓. **Where:** `views/settings/About.svelte`

- Settings › Agents › Archive: archived coding agent sessions and Nook conversations, search, restore, delete, "Delete all archived…" with one confirmation, never what still works. **Tauri:** ✓ (seen in a browser with a stubbed backend). **Where:** `views/settings/Archive.svelte`, `lib/archive.ts`

- Settings › Appearance: System, Light or Dark (light = `NookPalette.nookLight`; the bar stays dark, as the notch does), accent color (moved from General; the soft white turns near-black in light), density (compact, comfortable, spacious as a zoom of the window). **Tauri:** ◐ (seen in a browser with a stubbed backend in both looks; the Mac's custom themes, face, VS Code import and per-token colors ○; density zooms the whole window instead of the Mac's separate type and spacing scales). **Where:** `views/settings/Appearance.svelte`, `lib/theme.ts`, `src/app.css`, `App.svelte`

- Settings › Instructions: default answer style (`ResponseStyle`) and your own standing instructions, both in the brain's system prompt. **Tauri:** ◐ (style and free text; the Mac's saved prompts, spaces and context inspector ○; prompt tested in core, not against a live model). **Where:** `views/settings/Instructions.svelte`, `core/src/instructions.rs`, `brain/service.rs`

- Settings › Maintenance: data folder, cache size and clearing, export settings (save dialog), restore defaults (keeps language, welcome, window), versions to copy, updates via the releases page (no built-in updater). **Tauri:** ◐ (core tested; commands compiled for Windows, not run in a real window). **Where:** `views/settings/Maintenance.svelte`, `core/src/maintenance.rs`, `commands/maintenance.rs`

- Settings › Shortcuts: the global shortcuts (moved from General) and a cheat sheet of the main window's keys with a filter (`ShortcutCheatSheetView`). **Tauri:** ◐ (the sheet is checked against `shellShortcut` in tests; in-app keys can't be rebound and the capture, point-to-bar and open-panel keys are missing, UI-19; most Mac key commands are missing, UI-62). **Where:** `views/settings/Shortcuts.svelte`, `lib/shortcut-sheet.ts`

- Shared components (`ConfirmedButton`/`.confirmDelete`, dialog, sheet, menu, switch, search field, empty state, banner, status pill, tab bar) for the desktop and the companion alike, listed next to their Swift names in UI-COMPONENTS.md. **Tauri:** ◐ (FD-05 parts 1–3: the moved companion parts, `ConfirmedButton`, tooltip, hover card, loading, badges, chips, tags, notes, icon buttons, hover rows, project icon, QR code, image modal, timeline dividers, tile grid; the model picker and emoji browser still to build). **Where:** `src/components/ui/`, `src/lib/confirm.ts`, `src/lib/ui-parts.ts`, `src/lib/project-icon.ts` (+ tests)

- Sources card under an answer (status per source, unread sources on top with a reason and Try again, errors in plain language). **Tauri:** ◐ (no cited excerpt on hover, cited/uncited dots or mail sources by sender, BR-40). **Where:** `components/SourcesView.svelte`, `lib/sources.ts`

- Text in pictures for every brain (`ChatImage.describe`): the pictures of a question are read on this computer (Windows OCR, tesseract on Linux) at 1568 px, and each brain gets "Image: … Text recognized in the image (OCR…)" with the question, so one that cannot see still knows what they show. **Tauri:** ◐ (the description is unit-tested; Windows OCR and tesseract are not run on a picture in a test; PNG and JPEG only; nothing is added where the platform cannot read pictures). **Where:** `core/src/brain/chat_image.rs`, `ScreenReader::read_image_text`, `services::screen::describe_images`

- `ToolRunner` (tool loop, recovery, cache, JSON in text). **Tauri:** ✓. **Where:** `core/src/brain/tool_loop.rs`

- Web, weather, charts, mail drafts. **Tauri:** ◐ (mail via `mailto:` with To, Cc and Bcc; a ```mail block or a quoted mail in an answer (Nook Chat and agent transcripts) becomes an editable mail card with Send and Open in mail app; `.ics` invitations built in `calendar_invite.rs` with `Open .ics`, attached sending and `reply_to`/`from` wait on CH-91). **Where:** `core/src/brain/calendar_invite.rs`, `tools/{web,charts,mail}.rs`, `components/{MailDraftView,MarkdownBody}.svelte`, `lib/mail-block.ts`

- Zip archives, folders and pasted paths as attachments (`ZipText`, `FileText.folder`, `askAbout`): a zip lists its files and gives the text of the readable ones (read in memory, refused above 500 MB unpacked, 2 MB a file, 400,000 characters); a folder lists its files without hidden folders and build output; a path dropped on the main window or pasted into the field is attached, only from the home folder and never hidden folders, app data or key files. **Tauri:** ◐ (zip, folder and the path rules unit-tested; dropping and pasting not tried in the running app or on Windows). **Where:** `core/src/attachments.rs`, `read_attachment_path` in `commands/brain.rs`, `lib/paths.ts`, `components/Composer.svelte`

## Connectors

- `@chat` (WhatsApp chat next to the chat), sending via WhatsApp Web. **Tauri:** ○. **Where:** Possible through a WebView2 (Windows) or WebKitGTK (Linux) pane, as the Mac's `EmbeddedApps`/`WhatsAppWeb`; not built yet (CH-73)

- Apple Notes, Reminders, Mail.app, Messages, Bear, Things. **Tauri:** —. **Where:** Mac apps

- Calendars: ICS ("Other calendars"), Cal.com, `check_availability`, `find_time` (buffers, time-of-day preference, weekends). **Tauri:** ✓. **Where:** `ics.rs`, `agenda.rs`, `feeds.rs`, `brain/meeting_times.rs`

- Connecting with OAuth (Notion, Linear, Stripe, Vercel, Sentry); repairing an expired key by signing in. **Tauri:** ◐ (not tested against the real services) · — Android. **Where:** `oauth.rs`, `commands/connectors.rs`

- Custom sources (web APIs, webhooks). **Tauri:** ✓. **Where:** `custom.rs`

- Framework (Connector, Hub, catalog, brands). **Tauri:** ✓. **Where:** `core/src/connectors/`

- GitHub (read; review, single & batch merge via `github_merge_prs`, close as an action). **Tauri:** ✓. **Where:** `github.rs`, `pull_batch_merge.rs`

- GitLab, Vercel, Stripe, Notion, Cal.com, n8n, Resend. **Tauri:** ✓ (GitLab token checked first via `/api/v4/user`). **Where:** `gitlab.rs`, `cloud.rs`

- MCP client (stdio, HTTP). **Tauri:** ✓ (stdio desktop only). **Where:** `core/src/connectors/mcp/`

- One inbox for every chat app (`ChatInbox`, `InboxThread`, `BridgedChat`, `ChatBridge`): one set of rules for new, read in Nook, read in the app, marked unread, answered, removed, gone, edits, deletions, ticks, kept messages and dropped chats; saved as `chat-inbox.json` without the messages of an app that keeps them (WhatsApp). **Tauri:** ✓ (unit-tested; WhatsApp is on it, the other apps come with the chat helper). **Where:** `core/src/chats/` (`inbox.rs`, `bridge.rs`, `store.rs`), `Inbox` in `core/src/connectors/whatsapp/mod.rs` translates

- Portfolio. **Tauri:** ○. **Where:** 

- Pull requests under Agents: yours, awaiting your review, followed organizations and repositories (Settings › Accounts & connections), filters (status, involvement, author, draft, checks), reading with reviews and comments (GitHub HTML as Markdown), a GitHub Actions check's steps and log read in Nook (`CheckLog.svelte`), merging after confirmation in the bar, with an action log. **Tauri:** ◐ (tested against a fake API, not against GitHub itself). **Where:** `pulls.rs`, `github_markdown.rs`, `views/agents/pulls/`

- Second account per service, account per chat. **Tauri:** ◐ (no second WhatsApp account, CH-70; agent accounts for Claude and Codex only, AG-27). **Where:** `accounts.rs`, `ChatAccounts.svelte`

- Settings › Accounts & connections as one catalog: search, categories, rows for your connections (including GitLab and custom MCP servers), cards with Sign in / With a key / MCP. **Tauri:** ◐ (several MCP sign-in presets missing, CH-95; the add sheet isn't grouped as on the Mac, CH-96). **Where:** `views/settings/Accounts.svelte`, `views/connectors/`

- Sign in with GitHub. **Tauri:** ◐. **Where:** Sign in and Repair take over the `gh auth token` login (a token stays under "With a token"); device flow is waiting on a client ID; opening `gh auth login --web` itself ○

- System calendars (Apple Calendar). **Tauri:** —. **Where:** No API in this port

- WhatsApp card in the bar: chat as bubbles with ticks, photos in the card (large with a click), files and videos open with the system app, reply, Mute, Let Nook reply (reads only that chat, only suggests a reply to that chat, learns nothing). **Tauri:** ◐ (tested with a fake gateway, not with a real phone; only in the bar, not on Android; video doesn't play in the card and documents show no first page). **Where:** `views/connectors/WhatsAppCard.svelte`, `lib/whatsapp.svelte.ts`, `src-tauri/src/commands/whatsapp.rs`

- WhatsApp live (GOWA). **Tauri:** ◐ (start the gateway yourself; installer ○). **Where:** `core/src/connectors/whatsapp/`

- WhatsApp per chat: people, groups, status updates, and channels each a row; per chat Automatic, Always, or Never; hidden chats back one by one. **Tauri:** ✓. **Where:** `core/src/connectors/whatsapp/mod.rs`, `views/connectors/WhatsApp.svelte`

## Platform services

- "Hey Nook". **Tauri:** ◐ Windows · — Linux and Android. **Where:** `platform/windows/speech.rs`

- App menus (`AppMenu`): `list_app_menu`, `app_menu_command` (always approved in the plan; path parsing, `&` mnemonic cleaning, validation and listing unit-tested). **Tauri:** ◐ Windows (Win32 `HMENU` + UI Automation, compiled for Windows, not run on a Windows PC) · ◐ Linux (AT-SPI menu walk and `DoAction`, not tested against a live desktop) · — Android. **Where:** `core/src/brain/app_menu.rs`, `src-tauri/src/tools/screen.rs`, `platform/windows/menu.rs`, `platform/linux/atspi.rs`

- Autocomplete everywhere (`AutocompleteController`, `CompletionSuggestion`, `CompletionPrivacy`, `CompletionEmoji`, Settings › Autocomplete). **Tauri:** ◐ Windows (compiled, not run on a real PC; Testing tab on Linux too) · — Linux and Android. **Where:** `core/src/services/autocomplete/`, `src-tauri/src/services/autocomplete.rs`, `platform/windows/autocomplete.rs`

- Energy plan (`EnergyPolicy`, `EnergyMonitor`): Automatic, Saver, Full power; screen reading and Think Along follow it, the orb rests. **Tauri:** ◐ (Windows: battery, power saving, CPU load; Linux: `/sys`, load average, screensaver; not tested in the app) · — Android. **Where:** `core/src/services/energy.rs`, `services/energy.rs`, Settings › General

- Flow dictation. **Tauri:** ◐ (logic with tests; not tested with a microphone). **Where:** `core/src/services/flow.rs`

- Look Along, Think Along (answers in the app's language, not that of Nook's own question). **Tauri:** ◐ (no backoff up to 2 h kept across restarts and not the Mac's full nudge filter, SV-17). **Where:** `core/src/services/think_along.rs`

- Meetings and screen sharing (`QuietPolicy`, `QuietWatch`): quiet, hide from viewers, hide completely, Nook in screenshots. **Tauri:** ◐ Windows (window list, microphone via the privacy registry, `WDA_EXCLUDEFROMCAPTURE`; only compiled) · ◐ Linux (X11 and `pactl`; keeping out of a share isn't possible, then only quiet; not tested in the app) · — Android. **Where:** `core/src/services/quiet.rs`, `services/quiet.rs`, `platform/{windows,linux}/quiet.rs`, Settings › Voice & sound

- Music (`NowPlayingService`, Music tab). **Tauri:** ◐ now playing and controls only: MPRIS on Linux, Windows media controls (only compiled); no Spotify, search, queue, playlists, library, history, lyrics or output picker (SV-30…SV-39). **Where:** `platform/linux/mpris.rs`, `platform/windows/media.rs`

- Nook itself (orb, ring, sounds). **Tauri:** ◐ (not all 17 moods, face looks and reactions, SV-20; no buddy moments, SV-19; one sound for all events, SV-53). **Where:** `components/Orb.svelte`, `lib/sounds.ts`

- Notetaker. **Tauri:** ◐ (no speaker recognition). **Where:** `core/src/services/notes.rs`

- Reading the screen (`ScreenReader`, `ScreenContext`, `AppTextReader`). **Tauri:** ✓ Linux (AT-SPI, X11, tesseract) · ◐ Windows (UI Automation, OCR) · — Android. **Where:** `core/src/services/screen.rs`, `platform/`

- Screen region. **Tauri:** ◐ (no annotating, pasting back or Ask, SV-74). **Where:** `services/part.rs`

- System notifications (`SystemNotifier`, `BannerText`): Windows toasts with Allow/Deny (Allow, Show and Deny when the request doesn't fit; Show and Deny when it is dangerous), a reply field and Mark as read, grouped per chat and agent session, high priority for what waits on you, silent (Nook plays its own sounds), withdrawn when decided elsewhere; a click is a `nook://notice` link, so it opens the right place after a restart. Agents use them when Settings › Voice & sound › Notices is set to **System notification** (requests, done, failed, waiting). **Tauri:** ◐ Windows (WinRT toasts; only compiled, not run on a real PC) · ◐ Linux and Android (title and text only; a request falls back to the bar). **Where:** `core/src/services/toast/`, `src-tauri/src/notices.rs`, `platform/windows/toast.rs`. Deviations: the option is named "System notification" instead of "macOS notification", and lives in the existing Notice size row until Settings › Notifications (UI-17, SV-10) exists. Not yet: reply and Mark as read from a chat toast (CH-67), reply to an agent (AG-51), answering a chat toast after a restart (it opens the chat instead)

- System: apps, volume, clipboard, files, notifications, system and network status (`system_status`, `network_status`: processor, memory, battery, disk, uptime, heaviest apps, local and public IP). **Tauri:** ✓ Linux · ◐ Windows (report formatting and process grouping unit-tested; Windows battery/system status compiled for Windows, not run on a Windows PC). **Where:** `core/src/brain/system_report.rs`, `platform/*`, `tools/{system,files,clipboard}.rs`

- Today, weekly recap (with agent figures per project). **Tauri:** ◐ (Today lacks failed agents, owed replies, birthdays, connector failures, autocomplete savings and the Mac's ranking, SV-18, SV-13). **Where:** `core/src/services/recap.rs`, `views/Today.svelte`

- Voice: read aloud, speech to text (whisper.cpp or a chosen service). **Tauri:** ◐ (reading aloud tested; recording not, no microphone). **Where:** `core/src/services/`, `services/voice.rs`

## Gamer Mode (Tauri first, not on the Mac yet)

A coach for games, opened from **Gamer Mode** in the main navigation. The first game is Valorant. While Gamer Mode is
on and Valorant is the app in front, Nook takes a screenshot of the user's own screen every few seconds (Settings ›
Gamer Mode) and lets the chosen brain read it into structured events. It never reads game memory or sends input to the
game. Events can also be logged by hand.

- Coach: enemy patterns over rounds, a changed or stale setup (only rounds Nook watched count), good adaptation, my habits, general tips. **Tauri:** ✓. **Where:** `core/src/games/valorant/coach.rs`

- Match memory: rounds with events (agent, ability, place, round time, effect, confidence, source), kept apart from earlier matches. **Tauri:** ✓. **Where:** `core/src/games/valorant/memory.rs` (`games/valorant.json`)

- Reading a screenshot (prompt, strict JSON parsing, only known agents and abilities). **Tauri:** ◐ (Windows and Linux; not run against a live match yet) · — Android (logging by hand works). **Where:** `core/src/games/valorant/observe.rs`, `src-tauri/src/games.rs`

- Supported games (one entry per game, its coach view in `GamerMode.svelte`). **Tauri:** ✓. **Where:** `core/src/games/mod.rs`, `src/views/games/GamerMode.svelte`

- Valorant Coach page, logging by hand, coaching as a toast, Settings › Gamer Mode. **Tauri:** ✓. **Where:** `src/views/games/`, `src/lib/games.ts`, `src/lib/gamer.svelte.ts`, `src/views/settings/Games.svelte`

- Valorant knowledge: agents, abilities (with aliases such as "tripwire"), ability kinds, maps, callouts as one key. **Tauri:** ✓. **Where:** `core/src/games/valorant/catalog.rs`

## Agents and workspace

- Agent notifications: expanded or compact (Settings › Voice & sound › Notifications), OK with a countdown ring. **Tauri:** ◐ (compiled; not tested in the app). **Where:** `views/Bar.svelte`, `views/agents/AgentAlerts.svelte`

- Agents tab, new session (with thinking level; choices remembered as soon as you make them), timeline. **Tauri:** ◐ (free-text model field instead of the catalog, AG-25; composer chips and attachments, AG-90; auto-settle, settle actions and the list's row details, AG-110…AG-114; session lifecycle commands, AG-60…AG-83). **Where:** `views/agents/`

- Approving in the bar, multiple-choice questions (an open panel stays put and asks in a narrow bar). **Tauri:** ◐ (no "why it asks" and project scope, AG-43; no deny with a reason on desktop, AG-44; no granted rules, AG-45; no option previews or own answer with files, AG-46). **Where:** `views/agents/`

- Automatic titles (the chosen brain titles a new session from its first message; a name you typed wins; rename by double-clicking the title). **Tauri:** ◐ (prompt, parsing and fallback unit-tested; not run against a live brain; no per-project title rules or "Regenerate title"). **Where:** `core/src/workspace/titles.rs`, `src-tauri/src/workspace/automation.rs`

- Automations for Nook Chat itself (`ScheduledTaskTarget.nook`, `AppModel+ScheduleTools`): `schedule_task`, `list_scheduled_tasks`, `update_scheduled_task` and `set_up_secretary` from the chat (every change is an action the user approves in the plan); daily, weekdays, weekly, interval (at least 15 minutes) and once; each run a conversation of its own in the background with the run's note for the brain (work as the secretary, prepare every step as a proposal, what is new since the previous run), a quiet run that finds nothing new leaves no conversation; 15-minute limit; the task list in Settings › Agents › Automation shows them, with "Nook Chat answers it" as a destination. **Tauri:** ◐ (parsing, the run note, the secretary and the scheduler's Nook runs unit-tested; the app glue compiles for Windows and was not run against a live brain. Still ○: autonomy (BR-12), runs started by a message (BR-16), ). The Nook list has Conversations and **Scheduled** tabs (an amber count of runs waiting for you, a dot for an unread answer; tasks that will run first, then paused and done; run now and pause on each row; a click opens the latest run's conversation), a bar over a run's conversation (run now, pause, edit), and the run's question shows as a *Scheduled run* line (`components/NookTasks.svelte`, `NookTaskBar.svelte`, `ScheduledRunMarker.svelte`, `lib/nook-tasks.ts`; tab bar, count badge and empty state are local until FD-05). **Where:** `core/src/workspace/nook_schedule.rs`, `scheduler.rs` (`NookRun`, `finish_run`), `src-tauri/src/workspace/nook_runs.rs`, `src-tauri/src/tools/schedule.rs`, `views/settings/AgentsAutomation.svelte`

- Codex app-server, ACP agents, Antigravity. **Tauri:** ◐ (tested with fake `codex`, ACP and `agy_acp_server` scripts; not yet against the real agents). **Where:** `core/src/workspace/driver.rs` picks the transport from `RunProvider::transport()`: Codex over `codex app-server` (approvals for commands, file changes and MCP confirmations, questions, `turn/steer`, `turn/interrupt`, `thread/resume`; `codex exec` when `app-server --help` fails), Gemini CLI (`--acp`, headless when its help has no `--acp`), OpenCode and Cursor (`acp`), Grok (`agent stdio`) and Antigravity over ACP (`acp.rs`: `session/new`, `session/resume` or `session/load` without replaying, model/effort/mode settings, `session/request_permission` to the approval card or answered by the session's rights, `session/cancel`, `authenticate` on "Authentication required"). Antigravity (`antigravity.rs`): profile folder per account, Google sign-in link checked and opened, mode per rights, carry-on when it ends silent. Not ported: the Mac's pinned Antigravity server installer (no Windows/Linux release to pin; put `agy_acp_server` in `<Nook>/tools/antigravity-acp` or on `PATH`), images in prompts, ACP cost, a `session/load` that never answers, keeping a process between turns

- Delegating: Nook Chat hands a task to a new session (`start_agent_session`, approved in the plan) · a session delegates to a child session (`delegate_task`). **Tauri:** ✓ Nook Chat (`src-tauri/src/tools/agents.rs`) · ◐ sessions: `orchestrator_capabilities`, `delegate_task` (approval card unless full rights; `wait`, `client_request_id`, a worktree for a second writer in the same folder), `task_status`, `task_wait` (any/all, up to 840 s) and `task_cancel` (also the tasks it delegated) on the bridge; a parent that did not wait gets the result as a message when the task ends. Rules, states, results and placement are unit-tested in `core/src/workspace/delegation.rs`; not run against a live agent. Not yet: a task's question passed to its parent (`questionMessage` on the Mac). **Where:** `core/src/workspace/delegation.rs`, `src-tauri/src/workspace/bridge/tasks.rs`

- Diff with line numbers and highlighted words (`UnifiedDiff`). **Tauri:** ✓. **Where:** `lib/workspace/unifiedDiff.ts`, `views/agents/UnifiedDiffView.svelte`

- Finishing stuck sessions (`SessionLiveness`: transcript, the session's own process via the hook). **Tauri:** ◐ (with tests; not with a real `claude`). **Where:** `core/src/agents/liveness.rs`

- Git: changes, commit, push, pull request (all GitHub accounts, owner first), worktrees. **Tauri:** ◐ (no auto-pull, publish or Settings › Source control, AG-120; no worktree cleanup report, AG-121; no commit style or PR body check, AG-122; GitHub only, AG-124; no "Work on this PR", AG-125). **Where:** `core/src/workspace/`

- Handing a session to another agent or account (⋯ › Hand off to another agent…), with a budgeted context handoff shown in the timeline; switching back resumes the agent's own conversation with only what it missed. **Tauri:** ◐ (end to end with a fake `claude`; the menu was not clicked through in the app; no fork). **Where:** `core/src/workspace/handoff.rs`, `views/agents/run/HandOff.svelte`

- Hub via hooks (Claude Code, Codex, Gemini CLI, Cursor, …). **Tauri:** ◐ (no "Started by an agent in …", AG-40, compaction line, AG-41, or approval audit log, AG-42). **Where:** `core/src/agents/`, `nook --hook` / `~/.nook/nook-hook`

- Linking with diff and backup (`AgentConfigInstaller`). **Tauri:** ✓. **Where:** `core/src/agents/`

- Nook's own tools, Nook Chat and the screen for agents (`nook_tools`, `nook_use`, `nook_chat_*`, `take_over_screen`), agent sessions and music search as tools for Nook Chat. **Tauri:** ◐ `nook_tools`/`nook_use` (the brain's registry; reads run directly, every action waits for the bar's approval card, whatever the session's rights, then runs through the action gate's plan runner and the audit log), `nook_chat_list`/`_read`/`_send` (sending always asks), `take_over_screen` read-only (the screen-reading tools for one session for up to 30 minutes; Nook cannot click or type for agents on Windows/Linux), and `list_agent_sessions`, `read_agent_session`, `message_agent_session`, `start_agent_session` for Nook Chat. Sources kept on this device never reach an agent. JSON-RPC, rules, chat rendering and session start are unit-tested in core; the app glue compiles (Windows target) but was not run against a live agent. Left out: music search (MPRIS and Windows media controls only report and control what plays; there is no Spotify connection yet), machines over SSH, and the notch strip with Stop while an agent holds the screen. **Where:** `core/src/workspace/bridge_nook.rs`, `src-tauri/src/workspace/bridge/nook.rs`, `src-tauri/src/tools/agents.rs`

- Readable MCP tool names (`McpToolName`) in approvals, timeline, and MCP connectors. **Tauri:** ✓. **Where:** `core/src/agents/mcp_name.rs`

- Scheduled tasks (every day or some weekdays at a time, interval, once, webhook; to a new session or one session, fresh or continued; off until Settings › Agents › Automation allows them; "ask" by default, never full rights unattended; a fixed time missed by more than 10 minutes while asleep is skipped, an overdue interval or once-task runs on wake). **Tauri:** ◐ (unit tests for next run, DST, missed runs, overlap, restart; end to end with a fake `claude`; the settings page type-checks but was not clicked through in the app). **Where:** `core/src/workspace/schedule.rs`, `scheduler.rs`, `src-tauri/src/workspace/automation.rs`, `views/settings/AgentsAutomation.svelte`

- Terminals (portable-pty + xterm.js), browser (opens http(s):// addresses such as http://localhost:3000 directly; http and https only), dev servers. **Tauri:** ◐ (one browser window for all sessions and no right panel per session, where the Mac app gives each session its own, AG-100) · `browser_screenshot` ◐ (a JPEG at most `max_width` wide; WebView2 through the DevTools protocol, WebKitGTK and WKWebView snapshots; the shrinking is unit-tested, the capture compiles for Windows but was not run on a Windows PC). **Where:** `src-tauri/src/workspace/`, `src-tauri/src/workspace/snapshot.rs`

- Usage and limits. **Tauri:** ◐. **Where:** `views/workspace/`

- Webhooks for scheduled tasks (`POST http://127.0.0.1:<port>/hooks/<task>`, loopback only, HMAC-SHA256 `X-Hub-Signature-256` with the secret in the secret store, delivery id against replays, 60 a minute, queue of 20, payload quoted as untrusted data, `{{body.path}}`/`{{headers.name}}` placeholders; the run always asks). **Tauri:** ◐ (signed delivery over a real socket tested end to end; the Mac's filters, duplicate key, coalescing, deliveries log and public relay are not ported). **Where:** `core/src/workspace/webhook.rs`, `scheduler.rs`

- Workspace for agents (MCP bridge `nook --mcp`). **Tauri:** ✓ · other sessions ◐: `session_start` (1–20 sessions beside the caller, in a folder, in a worktree each, or in a scratch folder under `~/.nook/scratch`; approval card unless full rights; they start with ask rights), `session_send` (framed as another agent's message; queue, auto, steer or restart) and `session_wait` (any/all). Arguments unit-tested in `core/src/workspace/bridge_sessions.rs`; not run against a live agent. Different from the Mac: a session cannot start idle (a title without a first message), and the answer has no `nook://` link, because the Tauri app has no session links yet. **Where:** `src-tauri/src/workspace/`, `src-tauri/src/workspace/bridge/sessions.rs`

- Workspace sessions: Claude Code, Codex `exec`, Gemini CLI, queue, resume. **Tauri:** ✓ (tested with a fake `claude`). **Where:** `core/src/workspace/manager.rs`

## Companion and Android

- Android as a companion, laid out and worded as the iPhone app (see COMPANION.md, *Android*): the companion is the whole app once paired; tabs, headers, cards, shelves, transcript in turns, docked approvals, composer with Steer now, New session, Nook chat, Chats with the WhatsApp skin, Settings; a kept live connection (`subscribe`, `watch`, `watchChat`) while in front. **Tauri:** ◐ (browser tests against a fake computer with Android phone emulation, unit tests, `cargo check` for aarch64-linux-android; not run on a real phone; pull requests, review, pictures and dictation added; still missing: see ANDROID-COMPANION-TODO.md). **Where:** `src/views/companion/`, `core/src/companion/client.rs`

- Android project, phone layout, Share with Nook, back button. **Tauri:** ◐ (APK only via CI). **Where:** `src-tauri/gen/android`

- Away from home through a relay (`CompanionRelayClient`): a room per paired phone and one for the pairing window, the relay in the code (`&r=`) and in each answer, keep-alive, reconnect after sleep or on another network, *Test relay*. **Tauri:** ✓ (end to end against a fake relay that speaks the real mux; Nook's relay from the build setting `NOOK_RELAY_URL`; setting up your own relay on Cloudflare from Settings is not ported: deploy `apps/relay` and enter its address). **Where:** `core/src/companion/relay.rs`

- Companion protocol (`CompanionModels`, `CompanionSeal`, `CompanionPush`). **Tauri:** ✓ (test vectors). **Where:** `core/src/companion/`

- Companion server on Windows and Linux (pairing the iPhone app or Nook on Android) with what the Mac offers: a kept live connection (`subscribe`, `watch`, `watchChat`, `watchConversation`), retries (`CommandReceipts`), `platform`; starting sessions, conversations, history, manage, steer, pictures, diff, terminals and files; Home, usage, music; Nook chat; the Chats tab; pull requests. **Tauri:** ◐ (sessions from a terminal: approve, answer and end, CO-10; no snooze or main thread; Chats: WhatsApp; pull requests: GitHub, without *Work on this*; no Live Activities, CO-07, `appIcons`, `attachments`; no scopes per phone, CO-03). **Where:** `core/src/companion/` (`server.rs`, `live.rs`, `*_digest.rs`), `src-tauri/src/companion/` (`backend.rs`, `remote.rs`, `home.rs`, `nook_chat.rs`, `inbox.rs`, `pulls.rs`)

- Device key (`CompanionDeviceKey`): the server lists `deviceKey`, keeps the phone's public half (`bindKey`) and refuses its unsigned requests; Android makes a key per pairing, binds it and signs every request. **Tauri:** ✓ (end to end over TCP, and CryptoKit's signatures as test vectors). **Where:** `core/src/companion/device_key.rs`

- Keeping Nook running (no Mac counterpart; how t3code runs its server as a service): a Task Scheduler task at sign-in and every minute with `IgnoreNew` on Windows, a systemd user service with `Restart=on-failure` on Linux, both starting `nook --background`. **Tauri:** ✓ (not yet run on a real PC). **Where:** `src-tauri/src/companion/background.rs`

- Keeping the computer awake (`KeepAwake`, `KeepAwakePolicy`). **Tauri:** ✓ (`SetThreadExecutionState` on Windows, `systemd-inhibit` on Linux; Windows follows the power plan's lid setting). **Where:** `core/src/companion/keep_awake.rs`, `src-tauri/src/companion/keep_awake.rs`

- Push notifications via APNs. **Tauri:** ◐ (not tested against Apple). **Where:** `core/src/companion/apns.rs`

- Push through the relay (`RelayPush`, `RelayPushClient`): each notification sealed with a key derived from the phone's pairing key and posted to the relay's `/v1/push`, so no Apple developer account is needed; Nook on Android registers its Firebase token (`register` with `fcm`) and always goes through the relay; Settings › Companion chooses between the relay and your own APNs key. **Tauri:** ◐ (end to end against a fake relay, and the Mac's sealed vector opens; not tried against Nook's relay with a real phone). **Where:** `core/src/companion/relay_push.rs`, `server.rs`, `src/views/settings/CompanionPush.svelte`

- Routes (`CompanionEndpoints`): the `.local` name and every LAN and Tailscale address in the code (`&a=`) and in each `hello`/`list` answer; an address in 100.64/10 counts as Tailscale only when its interface is named after it or `tailscale ip -4` names it. **Tauri:** ✓. **Where:** `core/src/companion/server.rs` (`Reach`), `src-tauri/src/companion/reach.rs`

- Scopes per phone (`CompanionScopes`): read, approve, operate, chats, music and Nook chat, chosen before pairing and per paired phone in Settings › Companion; the server refuses a request outside them (`scope`), leaves out of every answer and live update what the phone may not see, lists only the features it may use, and ends its live connection when they change; a phone paired before scopes may do everything. **Tauri:** ✓ (behaviour; the Settings view is drawn in the current Tauri Companion page, not yet as the Mac's pairing sheet and phone rows: UI-88). **Where:** `core/src/companion/scopes.rs`, `server.rs`, `store.rs`, `src/views/settings/CompanionScopes.svelte`

- Secrets in the Android Keystore. **Tauri:** ○ (private app folder without backup). **Where:** `platform/secrets.rs`

- Sessions in a terminal from the phone (`CompanionAgents.send`, `end`): a message continues the session in Nook (Claude Code, Codex, Gemini CLI; a copy while the terminal still works, `--fork-session`), with pictures; `canSend` says when it can; *End* ends the process. **Tauri:** ✓ (not run with a real phone). **Where:** `core/src/companion/sessions.rs` (`can_continue_in_nook`), `src-tauri/src/companion/backend.rs`, `remote.rs`, `commands/workspace.rs` (`continue_live`)

- Versions (`CompanionCompatibility`, `CompanionWire`): answers compressed for a phone that can open them, `protocolVersion`, `appVersion` and `oldestPhone` on `hello`, `list` and `subscribe`; the computer keeps what each phone runs, and Settings › Companion shows its app version and says when it is too old or a version behind. **Tauri:** ✓ (behaviour; drawn as lines under the phone in the current Tauri Companion page, not yet as the Mac's `ConnectionRow` with its status and an expanded note: UI-88). **Where:** `core/src/companion/models.rs` (`phone_supported`, `phone_behind`), `server.rs`, `store.rs`, `src/views/settings/Companion.svelte`

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
