# Windows parity: the checklist to make the Windows app match the Mac

The macOS app (`apps/macos`) is the specification. The Windows app is the Tauri app (`apps/tauri`), which also
builds for Linux and Android. [TAURI.md](TAURI.md) says what has been ported; this file lists **everything that is
still missing**, as numbered items, so the gap can be closed one item at a time.

The list comes from an audit on 2026-11-16 of every Mac area against the Tauri code (file by file, tool name by tool
name, and the Mac commits since 2026-11-01). Nothing here was run on a real Windows PC; "missing" means no code or UI
was found.

## How to use this list

- **One item, one pull request.** Pick an unticked item, port it, and in the same PR tick it here (`- [x]`) and update
  its row in [TAURI.md](TAURI.md). Large items (L) may be split into several PRs; tick the item when the last one lands.
- **Port the behaviour, not the code.** Read the Mac files named in the item, then build the same behaviour in Rust
  (`core/src` for logic, `src-tauri/src` for the app and platform) and Svelte (`src`). Logic goes into `core` with unit
  tests, as the rest of the port does.
- **Same words, same look.** User-facing strings go through `tr()` in all five languages; the layout follows the Mac's
  panel and [UI-COMPONENTS.md](UI-COMPONENTS.md).
- **Prove it.** Each item is done when it has tests in `core` or `src`, and the "Done when" of its section holds. A
  Windows-only path also needs a run on a real Windows PC (see FD-01) before it counts as ✓ in TAURI.md; until then it
  is ◐.
- **New Mac work.** From now on, a Mac PR that adds a feature either ports it to Tauri in the same change or adds an
  item here (FD-06), so this list stays complete.

Sizes: **S** about a day · **M** a few days · **L** a week or more. Prefixes: FD foundation, UI shell and Settings,
BR Nook Chat and the brain, AG coding agents, CH chat apps and connectors, SV system services, CO companion.

## Suggested order

1. **Foundation** (section 1): without a Windows test machine and the shared components, everything after it is
   guesswork and drifts apart again.
2. **What every Windows user sees first:** SV-01 updater, UI-01…UI-12 Settings structure, UI-45…UI-51 bar, tray and
   taskbar, SV-15 toasts, FD-04 Dutch strings.
3. **Coding agents** (section 4), Nook's most used part: the MCP bridge (AG-01…AG-13), the side panel (AG-100…),
   the composer (AG-90…), then the session lifecycle.
4. **Chat apps** (section 5): CH-01 and CH-02 first; they unlock almost every other CH item.
5. **Nook Chat and the brain** (section 3), then **system services** (section 6) and the **companion** (section 7).
6. Section 8 lists what can't be ported, with the Windows alternative; decide per row whether to build the
   alternative.

## 1. Foundation (FD)

- [ ] **FD-01** A real Windows 11 test machine (or VM with GPU and microphone) and a written smoke test per area in `docs/SCENARIOS.md` style; run the "compiled, never run" list (FD-02) on it · M
- [ ] **FD-02** Verify on Windows what is only compiled today, and fix what breaks: autocomplete everywhere (`platform/windows/autocomplete.rs`), "Hey Nook" and dictation (`platform/windows/speech.rs`), screen reading and OCR (`platform/windows/screen.rs`), media controls (`platform/windows/media.rs`), quiet and screen sharing (`platform/windows/quiet.rs`), energy (`services/energy.rs`), system tools (`platform/windows/system.rs`), Flow and the Notetaker with a microphone and WASAPI loopback, the companion server (Task Scheduler, keep-awake, mDNS, APNs), agent notices, Selection Ask, Settings › Maintenance, global shortcut conflicts, named-pipe security for hooks and the MCP bridge (`core/src/agents/ipc.rs`) · L
- [x] **FD-03** Run the Tauri tests on `windows-latest` in CI, not only `cargo check` for the Windows target. The `Windows checks` job in `tauri.yml` already ran clippy and `cargo test --workspace` there; it now also runs the interface tests, and the hook named pipe and `cmd /C` MCP servers have Windows tests · M
- [ ] **FD-04** Rust error and status messages in five languages: about 550 Dutch-only strings (about 307 in `core/src`, 248 in `src-tauri/src`; most in `workspace/manager.rs`, `commands/workspace.rs`, `commands/connectors.rs`, `commands/chat.rs`, `companion/client.rs`, `connectors/oauth.rs`, `brain/action_gate.rs`) wrapped in `tr`/`trf` with catalog rows; a test that fails on new Dutch literals · L
  - Progress: `i18n::tests::no_new_dutch_text_outside_tr` fails on Dutch literals outside `tr`/`trf`; `DUTCH_LEFT` in `core/src/i18n/tests.rs` lists what each file still has and only goes down. Done: `workspace/manager.rs`, `commands/workspace.rs`.
- [ ] **FD-05** Shared desktop components in `src/components/ui/`: move Sheet, Dialog, Menu, TabBar, Toggle, SearchField, EmptyState, Banner and StatusPill out of `views/companion/ui/`, and add the Svelte twins of `NookTooltip`/`HoverCard`, `ConfirmedButton` (replaces the remaining `confirm()` calls), `NookSkeleton`/`PatientSpinner`/`BusyLine`, `NookCountBadge`, `NookFilterChip`/`ChipFlow`, `NookStatTile`, `NookTag`, `NookSectionLabel`, `ListEmptyNote`/`LoadFailedNote`, `IconDetailRow`, `CopyIconButton`, `RefreshIconButton` (with feedback), `TabCloseButton`, `HoverReveal`/`HoverRowFill`, `DisclosureChevron`, `TimelineNewDivider`/`TimelineEarlierRow`, `ProjectIconView`, `DropdownTileGrid`/`ModelPickerDropdown`, `EmojiBrowser`, `ImageModal`, `QRCodeView`, `NookAcknowledgeButton`; list them next to their Swift names in UI-COMPONENTS.md · L
- [x] **FD-06** Keep this list complete: a line in the PR template and AGENTS.md that a Mac feature PR either ports to Tauri or adds an item here · S
- [x] **FD-07** Correct TAURI.md where the audit found it wrong: WhatsApp Web inside Nook is possible through WebView2 (CH-73), and rows marked ✓ that miss parts listed here · S

## 2. Shell, Settings, look (UI)

Mac reference: `apps/macos/App/Settings/SettingsView.swift` (`SettingsSection`: 17 pages in 5 groups, 38 subjects),
`SettingsSidebar.swift`, `SettingsSearch.swift`, `UI/Panel`, `UI/Character`, `NotchRootView.swift`, `AppDelegate.swift`.
`Brain/SettingsPanes.swift` is not Nook's Settings but the table of macOS System Settings panes (see UI-13).

Visual audit (2026-11-17): every Settings page and the Nook, Agents and Chats tabs were rendered on both sides (Mac
offscreen through `NSHostingView`, Tauri through Vite with a stubbed backend and default settings) and compared. UI-77…UI-87
are the visible differences that no item listed yet; the rest were already covered by UI-01…UI-75, BR, AG, CH and SV items.

### 2.1 Settings window

- [x] **UI-01** Same pages and groups as the Mac: 17 pages in Nook, Intelligence, Agents, Connect, System, pages with several subjects behind a tab bar (#1572, #1641); Tauri has 18 pages in 7 groups → `views/Settings.svelte`, `lib/shell-routes.ts` · M
- [x] **UI-02** One shared tab bar for a page's subjects (`SettingsPartTabs`) · S
- [ ] **UI-03** Search over about 170 settings by their on-screen name, with the page path, scrolling to and lighting the row (`SettingsSearch`, `SettingsHighlight`) · M
- [ ] **UI-04** Attention counts on sidebar rows · S
- [ ] **UI-05** Restore defaults per page with a confirmation (`SettingsRestore`) · S
- [ ] **UI-06** Page intro and a line per subject (`SettingsPageIntro`) · S
- [ ] **UI-07** Overview with a row per page, the setup checklist, outdated agents, words typed today, automation next/failed, phone last seen, update status (#1653) · M
- [ ] **UI-08** Folding sections (`SettingsFold`, #1651) · S
- [ ] **UI-09** Setup sheets as numbered steps ending in a check (`SetupSheet`, `SetupCheckStep`) · M
- [ ] **UI-10** One field style and rows grouped into cards, note tones (`SettingsFormStyle`, `SettingToggle`, `SettingFieldRow`, `SettingNote`, #1607, #1551) · M
- [ ] **UI-11** Settings components `SettingsTile`, `SettingsLinkRow`, `InUseLabel`, `ConnectMethodBadge` · S
- [ ] **UI-12** Every Settings row the chat can change through BR-20 exists in the UI with the same key · S
- [ ] **UI-13** Open the right OS settings page from a task: a table of `ms-settings:` URIs (GNOME/KDE panels on Linux) in `core/src/brain/os_settings.rs` (`SettingsPanes`) · M

### 2.2 Settings pages and rows

- [ ] **UI-15** General: inbox working projects, confirm quit while sessions run, session list options, the confirmations list (`GeneralListAndConfirmations`); hold to quit is SV-80 · S
- [ ] **UI-16** General › Bar (the notch page): show bar, bar on every screen, which screen, hide when idle, open on hover, open the main window at launch; `hide_when_idle` and `screen_choice` already exist in core without UI · S
- [ ] **UI-17** Notifications page: per kind (agents, chats, Nook, suggestions) card / strip / system / off, quiet hours, warning when system notifications are blocked, per-app rules with search (with SV-10, CH-66) · M
- [ ] **UI-18** Sound: a file picker per event with preview (with SV-53) · S
- [ ] **UI-19** Shortcuts: rebind in-app keys (`KeybindingsSettingsSection`, a keys file), window-capture target, point-to-bar and open-panel global keys · M
- [ ] **UI-20** Brain: subscription brains (BR-02), OpenRouter sign-in (BR-04), pick up a key copied on the service's page (`ClipboardKeyCatcher`), searchable model list, local-vs-external warning, screen brain (BR-03), "no images" hint · L
- [ ] **UI-21** Assistant: Double Tap settings (SV-45), take over on tap, buddy moments with tone and birthday and "breathe now" (SV-19), manage permissions link · L
- [ ] **UI-22** Instructions: saved prompts, spaces, context inspector (BR-55, BR-56) · M
- [ ] **UI-23** Typing › Dictation under Typing as on the Mac, with the translate row and the right-key option; Typing › Apps per-website rules · M
- [ ] **UI-24** Agents: list on the left with details on the right (#1572), own ACP agents (AG-21), Antigravity installer (AG-23), updates (AG-28), per-account options (CH-98), Codex app-server and OpenCode server switches · L
- [ ] **UI-25** Agents › Usage: subscriptions, usage by model, week recap, token savings (with AG-49) · M
- [ ] **UI-26** Sessions page: models per agent, online model list, auto models/accounts, title and agent instructions, steer by default, timeline detail, screen reader, max sessions at work, continue after relaunch, text generation, tidying, snooze options, auto-settle rules, kept sessions · L
- [ ] **UI-27** Sessions › Worktrees (branch prefix, build leftovers, cleanup report) and Sessions › Open in (editor, terminal, search engine, where links open, trusted certificates, default browser, browser extension, browser memory) · M
- [ ] **UI-28** Automation: public webhook relay, port check, secret providers, remote MCP, Nook's own scheduled tasks · M
- [ ] **UI-29** Projects & pull requests page: per-project overrides (agent, permission, isolation, branch prefix, cleanup, browser sign-ins, instructions), archived projects, watched pull requests, code hosts, commit style, no-agent-credits switches · L
- [ ] **UI-30** Chats page: collect notifications, read on open, read in the app on open, other apps, extra field, Giphy, Beeper import, chat notice rules, connector health · M
- [ ] **UI-31** Devices › Machines (SSH machines, with AG-132) · L
- [ ] **UI-32** Privacy: privacy level, "what leaves this computer", forget screen text, apps Nook never reads, OS permissions overview (SV-75), the On this device source picker as its own subject · M
- [ ] **UI-33** Maintenance: updater and channel (SV-01, SV-02), redacted diagnostics export, provider traffic log, OpenTelemetry (SV-05), demo data switch, energy moved here as on the Mac · L
- [x] **UI-77** Settings controls drawn as on the Mac: a switch for every on/off row (Tauri draws checkboxes), capsule pickers with up/down chevrons instead of native selects, segmented controls for two to four choices (appearance, background work, privacy level, tone; Tauri draws tiles or a select), small grey capsule buttons, and the Mac's compact row height (Tauri rows are about a third taller); found in the visual audit, builds on UI-10. Privacy level and tone use `Segmented.svelte` when UI-32 and UI-79 add them · M

- [ ] **UI-77** Settings controls drawn as on the Mac: a switch for every on/off row (Tauri draws checkboxes), capsule pickers with up/down chevrons instead of native selects, segmented controls for two to four choices (appearance, background work, privacy level, tone; Tauri draws tiles or a select), small grey capsule buttons, and the Mac's compact row height (Tauri rows are about a third taller); found in the visual audit, builds on UI-10 · M
- [ ] **UI-78** Section headings as on the Mac: a bold title with an optional grey line under it and an action on the right ("Open setup", "Add account"); Tauri draws small grey labels · S
- [ ] **UI-79** Appearance in the Mac's order: preview with mood picker (UI-56), Style cards Minimal / Classic / Playful with a face colour row, a "Face and finish" fold, "Nook as buddy" (small moments, tone, a sample line, birthday, breathe now; moved here from Assistant, see UI-21), Theme as a segmented control above the theme grid (UI-70), a "Text and layout" fold; Tauri shows appearance tiles, accent colour and density · M
- [ ] **UI-80** Assistant rows as on the Mac: "Search the web when needed", the Double Tap section (UI-21), "What Nook may do" as Ask / Small / More (BR-10) instead of the "Do small things right away" checkbox, and the note that points to Brain when the brain runs locally · S
- [ ] **UI-81** Typing › Complete as on the Mac: the first tab has "Type less, in every app" and "In Nook's composers" (next prompt AG-70, reply suggestions in chats, actions from conversations, the model for suggestions, how your message goes on, SV-60) with the no-local-model warning; Tauri's sliders and keys belong under Style and context · M
- [ ] **UI-82** Brain page layout as on the Mac: the "Choose a brain" card on top, "Where Nook thinks" Local / External, models recommended for this computer's memory with Install, a connection test row, an "All models and runtimes" fold, then "Quality of the local brain" (evidence first, check answers, measure); Tauri starts with the Answers rows (with UI-20) · M
- [ ] **UI-83** Services page as on the Mac: a search field over the connections, "Nothing linked yet" with suggested service tiles and Sign in, "Add connection" in the section heading, and a Music section (Spotify row, keep listening history, clear it, look up lyrics online; features in SV-31, SV-36, SV-37); Tauri shows only the intro until something is linked · M
- [ ] **UI-84** Memory as on the Mac: "What Nook remembers (n)" with a field to add one, each memory with when it was seen, how sure and how often used, learned sources with a count, and Forget all · S

### 2.3 Main window

- [ ] **UI-35** Split view (a second tab beside the current one) and a tab torn off into its own window, reopened after a restart (`PanelSplit`, `TabWindowController`) · L
- [ ] **UI-36** Back and forward through opened sessions and Nooks (Ctrl+[ and Ctrl+]) · S
- [ ] **UI-37** Resizable sidebar with a remembered width, floating toggle on Agents (`PanelResize`, `PanelSidebarToggle`) · S
- [ ] **UI-38** Update button in the footer and the what's new / install / restart panel (with SV-01) · M
- [ ] **UI-39** Clone progress stack at the top right with Hide and Cancel (`CloneNoticeStack`) · S
- [ ] **UI-40** Cheat sheet as an overlay on its own key, not only in Settings · S
- [ ] **UI-41** Tooltips in Nook's own look, only when text is cut off; feedback on every refresh click (#1656, #1657, #1630) · M
- [ ] **UI-42** Starter grid two per row with an arrow on hover, checked against `NookStarters` · S
- [ ] **UI-85** Window sidebar head and foot as on the Mac (`PanelSidebar`): no orb at the top left (Nook lives in the bar), search, talk and the sidebar toggle in the head (back and forward on Agents, UI-36), the tab switcher with a label only on the open tab; footer Settings, Pull requests, Automation, Usage on the left and refresh/update on the right (UI-38); Tauri shows the orb, a workspace and a games icon and a status dot · S
- [ ] **UI-86** Agent session rows as on the Mac: project badge and name with age, the title, branch, +/− line counts, the agent's icon and a state such as Done; filter, folder and new-session buttons beside the search; the new-session composer with the agent's icon as picker, + and microphone inside it and the worktree choice below (Tauri shows text chips and a Start session button; with AG-90…AG-96) · M
- [ ] **UI-87** Nook chat composer footer as on the Mac: +, model, access level (BR-10) and sources inside the composer; Tauri puts "Automatic" and the model under it · S

### 2.4 Bar, tray and taskbar (the Windows equivalents of notch, menu bar and Dock)

- [ ] **UI-45** The bar's new-track strip and equalizer while music plays · M
- [ ] **UI-46** Proposal sentence under the bar ("Shall I add this to your calendar?" with View and OK) and friendly moments (with SV-19) · M
- [ ] **UI-47** Top-edge bar: open on hover, on every monitor, hide when idle (`platform/desktop.rs place_bar`) · M
- [ ] **UI-48** Live tray menu: needs-you line, next meeting, running agents, now playing, update, word count in the tooltip (the Mac's menu bar menu) · M
- [ ] **UI-49** Taskbar overlay badge for waiting items and a jump list (New Nook, Settings) (the Mac's Dock icon) · M
- [ ] **UI-50** Quit asks while sessions run and stops agents step by step before a deadline (CTRL_BREAK, then TerminateProcess) · M
- [ ] **UI-51** Started at login: the main window opens without taking focus · S

### 2.5 Nook himself (orb)

Moods, face, reactions and buddy are SV-19 and SV-20.

- [ ] **UI-55** Idle frame rate follows the energy plan; the orb takes the open tab's mood · S
- [ ] **UI-56** Large live preview with a mood picker on the Appearance page · S

### 2.6 Cards and keyboard

- [ ] **UI-60** File preview window for photos, PDFs and video with "Open in app" (`FilePreviewWindow`) · M
- [ ] **UI-61** Bar cards checked against `CardView`: one sentence, one detail line, at most two buttons, tinted state pill · S
- [ ] **UI-62** Every Mac key command (`KeyCommands`): next/previous session, back/forward, pin, rename, settle, undo, interrupt, copy reference, open in editor, reopen closed panel, close tab, terminal toggle and split, diff toggle, effort up/down, focus areas (F6), composer stash, start in background, paste as text, alternate send, find in chat, selection ask/quote, cheat sheet → `lib/shell-shortcuts.ts` with a rebindable store · L
- [ ] **UI-63** Hold Ctrl to show key hints (`CommandHoldHint`); one Escape order and focus-area cycling · S

### 2.7 Theme

- [ ] **UI-70** Built-in themes Warm, Mono, Midnight, Paper, High contrast, chosen apart for light and dark (`NookPalette.builtIn`) · M
- [ ] **UI-71** VS Code theme import · M
- [ ] **UI-72** Colour per token with reset and live preview, readable-contrast fix (#1483, #1492, #1495, #1526) · L
- [ ] **UI-73** `.nooklook` export and import (#1609) · S
- [ ] **UI-74** Colour-blind diff colours; switches for math rendering and the rich composer · S
- [ ] **UI-75** Density as separate type and spacing scales instead of a window zoom; radii and motion tokens (springs, reduced motion) checked against `NookTheme` · M
## 3. Nook Chat and the brain (BR)

### 3.1 Brain core and providers

- [x] **BR-01** Budgeted conversation window: the newest turn gets up to two thirds, shortened turns end in "…" (`Brain/ConversationWindow.swift`); Tauri sends a fixed last 12 turns (`commands/chat.rs`) → `core/src/brain/conversation_window.rs`, used by `service.rs` and `claude_code.rs` · M
- [ ] **BR-02** Subscription brains through Codex, Gemini, Grok, Kimi and Mistral Vibe CLIs (`Brain/SubscriptionBrain.swift`); Tauri has only `ClaudeCode` → `core/src/brain/subscription.rs`, new `provider.rs` variants · M
- [ ] **BR-03** Screen brain split: a local model reads the screen and on-device sources and writes a clean note for the external brain (`PrivateBrief`, `answerTogether`, `ScreenBrainSection`) → `core/src/brain/private_brief.rs`, Settings › Brain › Screen work · M
- [ ] **BR-04** OpenRouter sign-in with PKCE instead of pasting a key (`OpenRouterSignIn`) · S
- [x] **BR-05** OCR for images sent to brains that can't see images (`ChatImage`) · S
- [ ] **BR-06** Brain-written title after the first answer (`nameAfterFirstAnswer`) · S
- [ ] **BR-07** Follow-up offers capped at 3 like the Mac (Tauri: 2) · S
- [ ] **BR-08** Phishing and scam scoring for mail and chat messages in research context and reply suggestions (`MessageTrust`; same work as CH-39) · S
- [x] **BR-09** Nested command judging (`sh -c`, `xargs`, `find -exec`) in `command_risk.rs` with the Mac's tests · S

### 3.2 Access, plans, autonomy

- [ ] **BR-10** Three access levels (ask, small, more) chosen in the composer with Shift+Tab (`NookAccess`); Tauri has one `auto_run_safe` toggle → `core/src/brain/access.rs`, `Composer.svelte` · M
- [x] **BR-11** `update_plan`: the live step checklist above an answer → `src-tauri/src/tools/plan.rs`, `MessageView.svelte` · S
- [ ] **BR-12** Automation autonomy (ask, decide through a judge, auto) and the unattended-tools policy (`AppModel+Autonomy`) · M

### 3.3 Nook Chat automations

- [ ] **BR-15** `ScheduledTaskTarget.nook` and the tools `schedule_task`, `list_scheduled_tasks`, `update_scheduled_task`, `set_up_secretary` (`AppModel+ScheduleTools`) → `src-tauri/src/tools/schedule.rs` · L
- [ ] **BR-16** Automations that start when a matching message arrives, and the quiet "nothing new" answer (4cdac90ca) · M
- [ ] **BR-17** Scheduled tab in the Nook list with an amber count, the bar over a run's conversation, the "Scheduled run" marker (`NookScheduledTasks`) · M

### 3.4 Tools for Nook Chat

- [x] **BR-20** `get_settings`, `change_setting`, `open_settings` with the settings catalog (`AppModel+SettingsTools`, `SettingsCatalog`) → `src-tauri/src/tools/settings.rs`, `core/src/settings_catalog.rs` · M
- [x] **BR-21** `find_time` with buffers, time-of-day preference and weekends (`MeetingTimes`, `Availability`) · S
- [x] **BR-22** `compose_mail` with an `.ics` invitation (`CalendarInvite`); `reply_to` and `from` come with CH-91 · M
- [x] **BR-23** `github_merge_prs` (batch merge) · S
- [ ] **BR-24** `run_command` with `CommandRisk` and the terminal beside the chat · M
- [x] **BR-25** `open_in_nook_browser`, `read_nook_browser` · S
- [x] **BR-26** `network_status` and `system_status` (the Mac's `mac_status`: battery, disk, memory) · S
- [ ] **BR-27** `list_remote_machines`, `add_remote_machine` (with AG-132) · L
- [ ] **BR-28** `search_music`, `play_music` (needs SV-31 Spotify) · M
- [ ] **BR-29** `take_over`, `wait_for_user`, `read_ui`, `control_ui`: Nook acting in apps, stopping at the point of no return (`TakeoverPolicy`, `UIControl`) on UI Automation + `SendInput` (Windows), AT-SPI (Linux) · L
- [ ] **BR-30** `list_app_menu`, `app_menu_command` through a UI Automation menu walk (`AppMenu`) · M
- [ ] **BR-31** `read_browser_tab` through the extension (CH-60) or UI Automation (`BrowserTabReader`) · M

### 3.5 Chat UI (Nook tab)

- [ ] **BR-40** Sources: cited excerpt on hover or click with highlighted lines, dot for cited and dimmed uncited sources, mail sources by sender, strip model-written "Sources:" lists (`ChatSourcesView`, aa6afaa94) · M
- [x] **BR-41** Markdown like the Mac: syntax colours, file name on a fence, wrap and run buttons, `<details>`, images on their own line, table copy as Markdown or CSV, link address on hover, HTML/SVG preview in a sandboxed frame (`MarkdownView`, `MarkdownExtras`, `CodeRender`) · M
- [ ] **BR-42** MCP apps (`ui://` resources) in a sandboxed frame (`McpAppViews`) · M
- [ ] **BR-43** Brain chip showing the model, opening the picker (`BrainChip`) · S
- [ ] **BR-44** Queue messages while Nook answers, reorder, hold (`NookChat.enqueue/moveQueued/holdQueue`) · M
- [ ] **BR-45** Conversation list like the Mac: Conversations/Scheduled header tabs, For you card, one-line settled rows, hover card, archive shelf, multi-select, mark unread (`NookConversationList`) · M
- [ ] **BR-46** Split view: an app, Nook's browser or a terminal beside the chat with a draggable divider · M
- [ ] **BR-47** Working indicator: elapsed timer, shimmering current step, error card with Details · S
- [x] **BR-48** Zip archives, folders and pasted paths as attachments · S
- [ ] **BR-49** Plan-limits card on the empty chat (`NookGlance`) · S
- [ ] **BR-50** More starter signals: GitHub reviews, failing builds, unread mail (`SmartSuggestions`) · S

### 3.6 Instructions, inspector, search

- [ ] **BR-55** Saved prompts with `{{variables}}` and `/trigger`, and spaces (instructions and files per conversation) (`InstructionStores`, `PromptLibrary`, `NookSpace`) · M
- [ ] **BR-56** Context inspector: each part the model reads with its token size (`ContextBreakdown`) · S
- [ ] **BR-57** Search everything: agent sessions and transcripts (settled and archived too), chats, call notes, memories, notices, settings and actions, ranked (`AppModel+Search`); today only conversations and commands → `commands/search.rs`, `CommandPalette.svelte` · M

### 3.7 Suggestions and selection

- [ ] **BR-60** Suggested steps from chats, agent sessions and Nook Chat with a "Do it" bar, own setting and model (`AppModel+ActionSuggestions`, bd2f11059; shared with CH-62 and AG-71) · M
- [ ] **BR-61** One-click suggestions under the quick field (`DoubleTapSuggest`) · S
- [ ] **BR-62** Selection Ask complete: the bar in the small windows, a drag across messages as context, the hidden note that the quote is material, Quote into an agent's reply box · M
- [x] **BR-63** Import MCP memory · S

## 4. Coding agents and the workspace (AG)

### 4.1 MCP bridge (`nook --mcp`)

The Mac's bridge has 48 tools (`apps/macos/Services/Workspace/WorkspaceBridgeProtocol.swift`); Tauri's
(`core/src/workspace/bridge.rs`, `bridge_nook.rs`) has 14: `workspace_info`, `terminal_run/read/list/stop`,
`browser_open`, `browser_read`, `pull_request_create`, `session_list`, `session_read`, `nook_tools`, `nook_use`,
`nook_chat_list/read/send`, `chat_list/read/send`, `take_over_screen` (read-only).

- [x] **AG-01** `browser_screenshot`: offered in `tools/list`; WebView2 through the DevTools protocol (`Page.captureScreenshot`), WebKitGTK `get_snapshot`, WKWebView `takeSnapshot` (`src-tauri/src/workspace/snapshot.rs`) · M
- [ ] **AG-02** `browser_snapshot`, `browser_click`, `browser_type`, `browser_wait_for` on `src-tauri/src/workspace/browser.rs` (DOM refs, click and type through JS) · M
- [ ] **AG-03** `in: "user"` on `browser_*` (`BridgeUserBrowser`): drive the user's own Chrome/Edge through the browser extension (needs CH-60) · L
- [ ] **AG-04** `orchestrator_capabilities`, `delegate_task`, `task_status`, `task_wait`, `task_cancel` on top of `core/src/workspace/delegation.rs` · M
- [ ] **AG-05** `session_start` (1–20 sessions, with `account` and `rights` per session), `session_send`, `session_wait` · M
- [ ] **AG-06** `session_search` (`TimelineSearch`), `session_organize` (pin, settle, rename), `session_questions` · M
- [ ] **AG-07** `session_suggest` and the suggested-session card in the timeline · M
- [ ] **AG-08** `render_page` (`RenderedPage`, `McpApps`, `McpUI`): a sandboxed page in the timeline · M
- [ ] **AG-09** `schedule_task`, `list_scheduled_tasks`, `update_scheduled_task`, `run_scheduled_task_now` (wrap `scheduler.rs`; always ask) · S
- [ ] **AG-10** `watch_pull_request`, `get_pull_request_status` (wrap `connectors/pulls.rs`) · S
- [ ] **AG-11** `request_secret` (`SecretFiles`): ACL-restricted file on Windows plus the secret field on the approval card · M
- [ ] **AG-12** `device_list/open/screenshot/close` for Android emulators and devices through `adb` (`AndroidDevices.swift`); the iOS Simulator part is Mac-only · M
- [ ] **AG-13** `take_over_screen` acting for agents: click and type through `SendInput` (Windows), XTest/portal (Linux) · L

### 4.2 Agents and transports

- [ ] **AG-20** Pi agent (`AgentKind.pi`, `PiRPC`, `WorkspaceManager+Pi`, `PiRPCTurnDriver`): `pi --mode rpc` driver in `core/src/workspace/driver.rs` · L
- [ ] **AG-21** Own ACP agents (`CustomAgents`, `AcpAgentsSettings`, `AcpInstaller`): profile store, adapter install, Settings › Agents page · M
- [ ] **AG-22** OpenCode through `opencode serve` (`OpenCodeServerHost`, `OpenCodeServerTurnDriver`) instead of ACP only · M
- [ ] **AG-23** Antigravity installer (`AntigravityInstaller`): pin a Windows/Linux build once one exists, or document why not · S
- [ ] **AG-24** `ProviderCapabilities`: speed tiers, live model/effort change during a turn, Ultracode, `forksNatively` in `core/src/workspace/models.rs` · M
- [ ] **AG-25** Model catalog and picker (`AgentModelCatalog`, `AgentModelMenu`, `ModelManifest`, `model-manifest.json`): replace the free-text model field in `RunComposer.svelte` · M
- [ ] **AG-26** Auto model (`AutoModel`, `WorkspaceManager+AutoModel`): picks agent, account and model per turn · L
- [ ] **AG-27** Accounts for Gemini (`GEMINI_CLI_HOME`) and the other agents in `profiles.rs` (now Claude and Codex only) · S
- [ ] **AG-28** Agent updates (`AgentUpdater`, `AgentUpdates`, `AgentUpdatesSection`, `AppModel+AgentUpdates`): Settings › Agents › Updates · M
- [ ] **AG-29** "Agent too old for this model" with an update offer (`AgentVersionRejection`) · S
- [ ] **AG-30** Sign-in after an expired login (`AgentSignInFailure`) · M
- [ ] **AG-31** MCP connectors waiting for sign-in above the composer (`ConnectorSignIn`, `WorkspaceManager+ConnectorSignIn`) · M
- [ ] **AG-32** Readiness and token advice (`AgentReadiness`, `AgentAdvice`, `TokenSavings`, `AgentTuning`, `TokenSettingsSection`) · M
- [ ] **AG-33** OpenTelemetry environment passed to agents Nook starts (`AgentTelemetry`; the exporter is SV-05) · S
- [ ] **AG-34** Images in prompts for Claude and ACP agents · M

### 4.3 Hub, approvals and usage

- [ ] **AG-40** "Started by an agent in …" (`SpawnedSessions`): parent-process lineage in `core/src/agents/hub.rs` · S
- [ ] **AG-41** "Compacting the conversation…" from PreCompact hooks (`HookCompaction`) · S
- [ ] **AG-42** Audit log for hook approvals (`ApprovalAudit`) · S
- [ ] **AG-43** Why the agent asks, and the "Always allow X · this project" scope in `ApprovalCard.svelte` · S
- [ ] **AG-44** Deny with a reason on desktop (exists only in the companion) · S
- [ ] **AG-45** Granted rules per project with revoke (`GrantedRules`) · M
- [ ] **AG-46** Option previews and your own answer with files in `QuestionCard.svelte` · S
- [ ] **AG-47** Active usage polling and reset credits (`ClaudeUsage`, `CodexUsage`, `CodexRateLimits`, `QuotaService`) in `core/src/agents/usage.rs` · M
- [ ] **AG-48** Antigravity quota and CLIProxyAPI hubs (`AntigravityUsage`, `CLIProxyUsage`, `CLIProxyHub`) · M
- [ ] **AG-49** Usage modal like the Mac (`LimitPool`, `UsageLedger`, `PriceTable`, `UsageLimitCard`: pooling by plan, cost and token tabs, costliest chats, agent filter, Manage usage) · M
- [ ] **AG-50** CPU/resource badge per session (`ResourceUsage`, `ProcessTree`) · S
- [ ] **AG-51** Reply to an agent from a Windows toast · S

### 4.4 Session lifecycle

- [ ] **AG-60** `/clear`: a fresh conversation in the same session with a divider (`+FreshConversation`) · S
- [ ] **AG-61** `/btw` and `/side` side chats (`+SideChat`, `SideChatStrip`) · M
- [ ] **AG-62** Roll back the conversation, not only files ("Edit from here", Codex `thread/rollback`, `ConversationRollback`) · M
- [ ] **AG-63** Fork from an earlier turn · M
- [ ] **AG-64** Restart agent (end the process, resume the conversation) (`+Restart`) · S
- [ ] **AG-65** Size and idle `/compact`, the "auto-compact at" line, amber warning, live compaction state (`+Compaction`, `+IdleCompaction`, `CompactionProgress`) · M
- [ ] **AG-66** Context breakdown per part instead of only a `ctx %` pill (`+ContextUsage`) · M
- [ ] **AG-67** `/goal` strip (`+Goals`, `SessionGoal`) · S
- [ ] **AG-68** `/` command list in the composer (`AgentCommands`, `available_commands_update`) · S
- [ ] **AG-69** Steer receipts ("waiting to be read / not read") · S
- [ ] **AG-70** Suggested next prompt as ghost text, and choosing who writes titles, commits and PR text; title rules, Regenerate title (`+NextPrompt`, `TextGenerators`, `TextGeneration`, `TextGenerationSettings`) · M
- [ ] **AG-71** Session suggestions and suggested steps (`SessionSuggestion`, `AppModel+SessionSuggestion`, #1683) · M
- [ ] **AG-72** Main thread mode and sub-threads (`SubThreadLineage`, `SubThreadBeside`) · L
- [ ] **AG-73** Subagents and background commands in the timeline and panel; wake turns joined (`BackgroundCommandActivity`, `AgentProgress`, #1610, #1611, #1428, #1680) · M
- [ ] **AG-74** Editable plan checklist and the Tasks strip with the current phase (`PlanChecklist`, `AgentWorkStrips`) · M
- [ ] **AG-75** Cap on sessions working at once (`+Capacity`, `SessionCapacity`) · S
- [ ] **AG-76** Build slots and priority (`AgentGovernor`, #1480, #1403): Job Objects on Windows, `nice` on Linux · M
- [ ] **AG-77** Keep sessions running while Nook is closed (`SessionKeeper`, `KeptRuns`, `KeptTransport`, `KeptSessionsSettings`), reusing `companion/background.rs` · L
- [ ] **AG-78** Wait on quit and resume on next launch; pending questions survive a restart (`QuitShutdown`) · S
- [ ] **AG-79** Fresh conversation after a lost or overfull context (`+VersionRejection`, `FailureClassifier`) · S
- [ ] **AG-80** Resume at limit reset with the account choice, and snooze until reset · S
- [ ] **AG-81** Read-only guest link for a session (`GuestShares`, `GuestLink`) · M
- [ ] **AG-82** Session export (`SessionExport`) · S
- [ ] **AG-83** Search across sessions and the archive (`TimelineSearch`, #1498) · M

### 4.5 Composer and new session

- [ ] **AG-90** Chips and attachments in `RunComposer.svelte`: files, folders, pictures, drop, paste, `@` file/session/PR/skill/model (`ComposerChips`) · L
- [ ] **AG-91** Dictation, autocomplete (#1522) and inline model names in the session composer · M
- [ ] **AG-92** A new-session draft per folder (`ComposerDraftStore`) · S
- [ ] **AG-93** Prompt library, skill index, Explain/Fix from the side panel (`PromptLibrary`, `SkillIndex`, `SessionPrompts`, `ComposerInbox`) · M
- [ ] **AG-94** Worktree setup checklist and progress, blocking setup scripts, 5 s base-fetch cap (`WorktreeSetupChecklist`, `WorktreeSetupProgress`, #1518) · M
- [ ] **AG-95** Sessions without a project, "Turn into project" (`ScratchProjects`) · S
- [ ] **AG-96** Picker shortcuts (effort, access), send-and-… shortcut, `OpenSessionActions` · S

### 4.6 Side panel per session

- [ ] **AG-100** One right panel per session with Changes, Terminal, Browser, PR, Files, Outputs, Subagents tabs, and one browser per session (`SessionToolPanel`, `SessionTools`, `SidePanelTabOrder`) · L
- [ ] **AG-101** View, edit and save files; Mermaid; file links (`FileViewing`, `FileLinks`) · M
- [ ] **AG-102** Outputs: documents and videos the agent handed over (`SessionOutputs`, `ArtifactHistory`) · M
- [ ] **AG-103** Review comments on a diff line into the composer; stage or discard a hunk (`ReviewComments`, `HunkPatch`) · M
- [ ] **AG-104** Linked pull requests, branch tray, PR badges and hover cards in rows (`LinkedPullRequests`, `RunBranchTray`, `PullRequestSync`) · M
- [ ] **AG-105** Browser element snippets into the composer (#1570) · S

### 4.7 Agents list

- [ ] **AG-110** Auto-settle rules, settle on PR merge (`AutoSettlePolicy`, `AutoSettleRulesRows`, #1621) · M
- [ ] **AG-111** Settle actions: stop dev servers, run a command, close idle terminals (`SettleActions`, `AppModel+SettleActions`) · S
- [ ] **AG-112** Bulk delete, custom snooze, dropping files onto a row · S
- [ ] **AG-113** Project favicon, multi-project label (#1549), changed-line counts, project menus, add project source (#1482) · M
- [ ] **AG-114** One notice per finished turn with logo and gist (`AgentStatusNotice`); `AgentAlerts.svelte` covers part · S

### 4.8 Git and source control

- [ ] **AG-120** Auto-pull, publish, project archive, Settings › Source control (`SourceControl`, `SourceControlSettings`) · M
- [ ] **AG-121** Worktree cleanup with report, archive, move, build leftovers (#1616), disk usage warning (`WorktreeCleanup`, `WorktreeCleanupReportView`, `WorktreeArchive`, `WorktreeMove`, `BuildLeftovers`) · M
- [ ] **AG-122** Commit style, removing agent credits from commits, PR body check against the template (`CommitStyle`, `PullRequestBodyCheck`, #1561) · S
- [ ] **AG-123** Skip approval for a PR the user asked for (#1602), PR news as a new turn (#1601), PR mentions · S
- [ ] **AG-124** Other forges for session PRs: GitLab, Gitea, Bitbucket, Azure DevOps (`ForgeSettings`) · L
- [ ] **AG-125** "Work on this PR" (`AppModel+PullRequestCheckout`) in `PullRequestView.svelte` · S

### 4.9 Automation and remote

- [ ] **AG-130** Scheduled tasks that act on their own without a session (#1676); Nook Chat as a target is BR-15…BR-17 · M
- [ ] **AG-131** Webhook filters, duplicate key, coalescing, deliveries log, public relay, deliveries kept across a quit (`WebhookRelay`, #1677) · M
- [ ] **AG-132** Remote machines over SSH (`RemoteMachines`, `RemoteBridge`, `RemoteHostDiscovery`, `RemoteMachinesSettings`, #1533) · L
- [ ] **AG-133** Nook as a remote MCP server with tunnel and grants (`RemoteMCP*`, `RemoteMCPSettings`) · L
- [ ] **AG-134** Stop a dev server the session started, also on settle · S

## 5. Chat apps, mail and connectors (CH)

### 5.1 Foundation (blocks almost every chat app)

- [x] **CH-01** One inbox for all apps (`ChatInbox`, `InboxThread`, `BridgedChat`, `ChatBridge`): `core/src/chats/{inbox,bridge,store}.rs`; move WhatsApp onto it first · L
- [ ] **CH-02** Nook's chat helper (`apps/chatd`, `ChatHelper`, `ChatServiceData`, `ChatLiveStream`, `ChatLinker`): build `nook-chatd.exe` in CI, child-process manager in `src-tauri/src/chats/helper.rs`, `/v1` client and `/v1/ws` live line in `core/src/chats/chatd.rs`. This unlocks Telegram, Signal, Messenger, Instagram, X, LinkedIn and Slack · L
- [ ] **CH-03** Sign-in window that hands cookies or tokens to the helper (`ChatSignInWindow`, `WebSignInAgent`): a private `WebviewWindow` per step running the step's `extractJS` · M
- [ ] **CH-04** Reading other apps' notifications (`ChatCaptureService`) for Discord, Google Chat, Viber, LINE…: `UserNotificationListener` or `wpndatabase.db` on Windows, D-Bus monitor on Linux, in `src-tauri/src/platform/*/notifications.rs` · M
- [ ] **CH-05** Per-app notification layouts (`MessagingApp`, `NoticeLayout`) in `core/src/chats/apps.rs` · S
- [ ] **CH-06** Chat history on disk, backfill, edits and deletions (`ChatStore`, `ChatArchive`, `ChatBackfill`, `ChatReconcile`): SQLite in `core/src/chats/archive.rs` · L
- [ ] **CH-07** Chat history in Search everything (`ChatHistorySearch`, `NookSearch`, `SearchCenter`) · M
- [ ] **CH-08** People and names across apps, no guessing between equal matches (`ChatIdentity`, `ChatHandle`, `ChatNames`, `ChatRecipients.pick`) · M

### 5.2 Each chat app

WhatsApp is the only chat app in Tauri today (read, send text, unread, bar card, Chats tab, per-chat rules).

- [ ] **CH-10** Telegram (through chatd; TDLib `tdjson.dll` as fallback) · M
- [ ] **CH-11** Slack chats, unread, card and rules (chatd, or a slack.com web session); today only a custom source · M
- [ ] **CH-12** Teams chats: Graph `Chat.Read` with device-code sign-in, or a web session, in `core/src/chats/teams.rs`; today only a send-only webhook · L
- [ ] **CH-13** Signal through chatd · M
- [ ] **CH-14** Instagram through chatd and the sign-in window · M
- [ ] **CH-15** Messenger through chatd and the sign-in window · M
- [ ] **CH-16** LinkedIn through chatd and the sign-in window · M
- [ ] **CH-17** X through chatd and the sign-in window · M
- [ ] **CH-18** Discord and Google Chat through the notification reader (CH-04) · S
- [ ] **CH-19** Snapchat through a hidden web session (`SnapchatBridge`, `SnapchatWebSession`) · M
- [ ] **CH-20** Beeper import (`BeeperImport`, `BeeperImporter`, `BeeperImportSection`); Beeper Desktop runs on Windows on localhost:23373 · M
- [ ] **CH-21** Chat apps list in Settings with numbered linking steps per app (QR, phone code, website, token) (`ChatAppsCatalog`, `ChatAppStates`, `ChatAppSheet`, `ChatBridgeSettings`) · M

### 5.3 Chats tab

- [ ] **CH-30** One list across apps with per-app filters and account rows (`ChatsTab`, `ChatsSidebar`) · M
- [ ] **CH-31** Status and Channels tabs (`ChatsListKind`) · S
- [ ] **CH-32** Pinned chats (`ChatPins`) · S
- [ ] **CH-33** People view with notes and birthdays (`ChatPeople`) · M
- [ ] **CH-34** Chat info: description, admins, groups in common, export, block, report (`ChatsInfoSheet`, `ChatProfile`, `ChatCommonGroups`) · M
- [ ] **CH-35** Scroll back for older messages (`ChatHistoryBridge`) · M
- [ ] **CH-36** Join/leave and group change lines (`ChatMembershipLine`, `ChatGroupChange`) · S
- [ ] **CH-37** "What Nook can't do in this chat" line (`ChatLimitsLine`) · S
- [ ] **CH-38** You owe a reply / Waiting for reply / reminders, owed replies and birthdays in Today (`ChatFollowUps`, `ChatFollowUpTick`, `ChatFollowUpStore`) · M
- [ ] **CH-39** Leave scam and phishing chats out of owed replies and reply suggestions (scoring itself is BR-08) · S
- [ ] **CH-40** Snooze a chat · S
- [ ] **CH-41** Scheduled send (`ChatScheduledSend`) · M

### 5.4 Messages and composer

- [ ] **CH-45** Reactions: show, send, who reacted (`ChatReactions`) · M
- [ ] **CH-46** Reply with a quote · S
- [ ] **CH-47** Edit, delete for everyone, delete for me, message info, right-click menu (`MessageMenuItems`, `ChatHiddenMessages`) · M
- [ ] **CH-48** Forward (`ChatForward`) · S
- [ ] **CH-49** Send photos, videos and files: "+", drop, paste · M
- [ ] **CH-50** Edit a picture before sending: crop, rotate, draw, text (`ChatImageEdit`, `ChatAttachmentStage`) · M
- [ ] **CH-51** Stickers, GIFs (Giphy), frequent emoji · M
- [ ] **CH-52** Record and send voice notes (`OggOpus`) · M
- [ ] **CH-53** Polls: show, vote, send (`ChatPoll`) · M
- [ ] **CH-54** Typing line, group "read by", read times, ticks on older messages (`ChatTyping`, `ChatReceipts`) · S
- [ ] **CH-55** Mentions by name and an `@` list of group members (`ChatMentions`, `ChatTags`) · S
- [ ] **CH-56** Video stills, document first pages, media cache across restarts, video playing in the card (`ChatFileThumbnails`, `ChatPictureDisk`, `ChatMediaWarmup`) · M
- [ ] **CH-57** Link previews, call rows, "Edited"/"Deleted" marks with earlier versions · S
- [ ] **CH-58** Mark unread; pin, mute, archive and delete in the app itself (`ChatAbilities`) · M
- [ ] **CH-59** Keep the reading position while older content loads (`TranscriptReadingAnchor`) · S

### 5.5 Suggestions, notices and calls

- [ ] **CH-60** Browser extension: native-messaging host for Chrome, Edge and Brave, the `chrome_*` tools, Settings page (`BrowserExtensionService/Host/Hub/Tools/Look`, `BrowserExtensionSection`, #1573, #1627) in `src-tauri/src/browser_ext/` · L
- [ ] **CH-61** Suggested reply as ghost text in the empty field (#1654), ghost completion while typing · S
- [ ] **CH-62** Suggested steps above the field (`ChatActionSuggestion`, #1683) · M
- [ ] **CH-63** `@nook` in a chat field to draft, change or look things up · M
- [ ] **CH-64** Notice priority for questions and mentions (`ChatNoticePriority`) · S
- [ ] **CH-65** One bar card for every chat app: `WhatsAppCard.svelte` → `ChatCard.svelte` · M
- [ ] **CH-66** Notice rules for every app, quiet bots, muted-in-its-app, Settings › Notifications with "how" and "from whom" (`ChatNoticeRules`, `ChatNoticeRuleRows`, `NoticeRulesSettings`) · M
- [ ] **CH-67** Windows toast with Reply and Mark read · M
- [ ] **CH-68** Read on reply and read-when-opened for every app (#1593); the card refreshes live while up · S
- [ ] **CH-69** Calls: call button and call card, microphone detection, start through the app's URI (`AppModel+ChatCall`, `ChatCallCenter`, `ChatCallDevices`) · M

### 5.6 WhatsApp

- [ ] **CH-70** Second WhatsApp account and a picture per account (`WhatsAppAccounts`) · M
- [ ] **CH-71** Install GOWA from Settings (`WhatsAppGOWA`, `WhatsAppSettingsSection`) · M
- [ ] **CH-72** Recent WhatsApp fixes: re-read quiet chats that moved, fetch media on arrival, typing and group unread counts (15fab7633, bfd3f0639, a8c5b8907) · S
- [ ] **CH-73** WhatsApp Web inside Nook and `@chat` / `@open` (`EmbeddedApps`, `WhatsAppWeb`, `WhatsAppWebSender`) through WebView2; TAURI.md's "—" is wrong · M

### 5.7 Brain tools for chats and mail

- [ ] **CH-80** `chat_inbox` and `chat_send` on the shared inbox; point `chat_list/read/send` (#1679) at them; `bridge_nook.rs::chat_use` refuses everything but WhatsApp today · M
- [ ] **CH-81** #1679 follow-ups: hide device-only sources from agents per call, clamp the limit · S
- [ ] **CH-82** Dead mappings `search_messages`, `messages_open_chats`, `read_messages`, `read_whatsapp` in `research.rs`/`intent.rs`: map to `chat_inbox` or remove · S
- [ ] **CH-83** Chat and mail data behind `find_time`'s invitations: send the `.ics` from BR-22 through CH-91 · S
- [ ] **CH-84** Browser tab reading in Sources and research (`research.rs` names it already); the tool itself is BR-31 · S

### 5.8 Mail and calendar (Windows alternatives to Mail.app and EventKit)

- [ ] **CH-90** Mail reading: `mail_unread`, `inbox_mail`, `search_mail`, `read_mail`, `trash_mail`, `mark_mail` on Microsoft Graph, the Gmail API and IMAP in `core/src/connectors/mail/` · L
- [ ] **CH-91** Mail as chats and sending after Send: Graph `sendMail`, Gmail; `compose_mail` with `reply_to` threading (#1628), attachments and `.ics` invitations (#1682) · M
- [ ] **CH-92** Read and write calendars: Graph, Google Calendar or WinRT `AppointmentStore` (ICS is read-only) · M

### 5.9 Connectors and accounts

- [ ] **CH-95** Missing MCP sign-in presets: Atlassian, Canva, Supabase, Neon, Hugging Face, Cal.com (MCP), Resend (MCP), GitLab (MCP) in `core/src/connectors/mcp/connector.rs` · S
- [ ] **CH-96** Add sheet grouped as on the Mac, deep link to one chat app's sheet (`ConnectionCatalog`, `ConnectionsPage`) · S
- [ ] **CH-97** 1Password `op://` secret provider (`SecretProvidersSection`) · M
- [ ] **CH-98** Agent account options: on/off, program path, extra arguments, environment, custom models (`AccountOptionsSection`) · M
- [ ] **CH-99** Settings for notification collection, read behaviour, GIF key (`ChatOptionsSection`) · S
- [ ] **CH-100** `nook://` links and default-browser routing (`AppModel+IncomingLinks`) through `tauri-plugin-deep-link` · S
- [ ] **CH-101** "Fix it" buttons next to chat errors (`ChatRecovery`) · S
- [ ] **CH-102** Import sign-ins, history and saved passwords from another browser for Nook's browser (`BrowserImportSheet`, `BrowserMemorySettings`) · M
- [ ] **CH-103** Portfolio (`PortfolioConnector`): off on the Mac too; port when it is switched on there · S
## 6. System services (SV)

### 6.1 Updates and telemetry

- [ ] **SV-01** App updater: `tauri-plugin-updater` on GitHub Releases with signatures, check at launch, every 30 min and on wake, Update button (`AppUpdater`, `ReleaseUpdateCore`, `Ed25519Verifier`) → `src-tauri/src/updates.rs` · L
  - Progress: `core/src/updates` (versions, channel, release choice, Ed25519 check, release notes, receipt) with the Mac's tests; the release signs the Windows setup and the AppImage (`scripts/sign-update.sh`) and stamps version and key into the build. Still to do: checking, downloading and installing in `src-tauri/src/updates.rs`, and the button and panel (with UI-38). The Mac checks every 4 minutes, not 30.
- [ ] **SV-02** Stable/Beta channel (`ReleaseChannel`) · S
- [ ] **SV-03** Update trial and rollback after a crash (`UpdateTrial`, `UpdateTrialRunner`) · M
- [ ] **SV-04** Daily updates of GOWA, ACP agents and Antigravity (`ToolUpdates`) · M
- [ ] **SV-05** OpenTelemetry export: OTLP/HTTP, endpoint per signal, headers in the secret store, `OTEL_EXPORTER_OTLP_*`, Test button, also passed to agents Nook starts (`Telemetry/*`, `TelemetrySettingsSection`; includes AG-33) · M

### 6.2 Attention, notices and Today

- [ ] **SV-10** Display style per source (card, line, system notification, list only) and per-app switches (`NoticeRules`, `NoticeRulesSettings`) · M
- [ ] **SV-11** Shared pacing and a daily interruption budget (`NoticePacer`, `InterruptionBudget`) · M
- [ ] **SV-12** History of missed notices, searchable, opens its source (`NoticeLog`, `NoticeHistory`) · M
- [ ] **SV-13** Shared ranking with learned weights for Today, menu and phone (`AttentionItem`, `AttentionScorer`, `AttentionFeedback`) · M
- [ ] **SV-14** One app-kind catalog (browser, call, chat, editor, terminal) with Windows exe names (`AppCatalog`) · S
- [x] **SV-15** Rich Windows toasts: Allow/Deny buttons, groups, priority, clicks that survive a restart, short gist for long approvals (`SystemNotifier`, 5b67dce9f, 730ba42b9; base for AG-51 and CH-67) · M
- [ ] **SV-16** Configurable snooze durations and times of day (`SnoozeOptionsSection`) · S
- [ ] **SV-17** Think Along backoff up to 2 h and kept across restarts; the full nudge filter (`NudgeFilter`, `ThinkAlongBackoff`) · S
- [ ] **SV-18** Today complete: agents waiting or failed, replies you owe, birthdays, next event within 3 h, connector failures, autocomplete "saved you", ranking (`AppModel+Today`) · M
- [ ] **SV-19** Buddy moments: good morning, welcome back, break, milestones, while you were away (`BuddyMoments`, `BuddyService`, `AppModel+Buddy`) · M
- [ ] **SV-20** Orb with all 17 moods, face looks, reactions to clicks and typing, mouth following read-aloud (`NookMood`, `NookOrb+Face`, `NookPresence`) · M

### 6.3 Music

- [ ] **SV-30** Music page: where it plays, search everywhere (9b8aec483); today now playing only · M
- [ ] **SV-31** Spotify connection with PKCE and your own client ID (`SpotifyWebAPI`, `MusicConnectionSection`) · M
- [ ] **SV-32** Search tracks, albums, playlists (`+Search`) · M
- [ ] **SV-33** Queue: Nook queue, Spotify queue, Up Next (`+Queue`, `MusicAppQueue`) · M
- [ ] **SV-34** Playlists: list, open, create, rename, delete, add, remove (`+Playlists`) · M
- [ ] **SV-35** Library and top artists and tracks (`+Library`) · M
- [ ] **SV-36** Listening history, stats, streaks, for the recap (`+History`) · M
- [ ] **SV-37** Lyrics through lrclib.net (`LyricsService`) · S
- [ ] **SV-38** Output picker: Windows audio endpoints and Spotify Connect devices (`MusicOutputs`) · M
- [ ] **SV-39** Real equalizer levels through per-process WASAPI loopback (`AudioLevelMonitor`) · M

### 6.4 Voice, Flow, Double Tap, Notetaker

- [ ] **SV-45** Double Tap: double-tap a key, a field in the bar, then fill a form, write at the cursor or edit a part, with a step card, Undo and Send (`DoubleTap/*`) → `core/src/services/double_tap/` and a keyboard hook with UI Automation on Windows · L
- [ ] **SV-46** Flow on a held modifier alone (right Ctrl), through the low-level keyboard hook · S
- [ ] **SV-47** Multi-language dictation (`MultiDictation`) · S
- [ ] **SV-48** Parakeet and reuse of models already in the Hugging Face cache (`Parakeet`, `VoiceModelCopies`) · S
- [ ] **SV-49** Field and screen context for dictation cleanup (f9fefac0d) · S
- [ ] **SV-50** Speaker recognition in the Notetaker (sherpa-onnx embeddings) · L
- [ ] **SV-51** Wake word only after a loudness check, paused while locked, on low battery or under the energy plan · S
- [ ] **SV-52** Read-aloud button under each answer (958ad68ad) · S
- [ ] **SV-53** A sound per event (e1b3c566d) · S

### 6.5 Autocomplete

- [ ] **SV-60** Autocomplete in Nook's own composers, model warm-up on focus (`ComposerCompleter`, `ComposerAutocompleteSection`; 1b9370040, def79d3fa, e7928b73e) · M
- [ ] **SV-61** Chat context in autocomplete, reply suggestion in an empty chat field (a2de49d80, 372f2bdba; with CH-61) · M
- [ ] **SV-62** Learning from your writing (`CompletionLearning`, b51aadf82) · M
- [ ] **SV-63** Personal adapter training (`CompletionAdapter*`, `CompletionGGUFWriter`, `AutocompleteAdapterSection`) with llama.cpp finetune, or record as left out · L
- [ ] **SV-64** Everything `docs/AUTOCOMPLETE.md` lists as not yet ported: typo fixes, terminals, insert modes, screen context, token healing, write-ahead memo, ranking candidates, word alternatives, Suggest-now key, per-website rules, battery behaviour, 30-day chart · L
- [ ] **SV-65** Choosing the generator per kind (CLI or API) with Test (`TextGenerationSettings`; with AG-70) · S

### 6.6 Screen, windows, control

- [ ] **SV-70** Capture-window shortcut: picture plus UI Automation text into a composer (`WindowCapture`, `WindowCaptureText`, b2f8b673f) · M
- [ ] **SV-71** Drag the orb onto a window to attach it, with a halo (`WindowAttach`) · M
- [ ] **SV-72** Nook clicks and types in apps (`UIDriver`, `AppModel+Control`; the base for BR-29 and AG-13) · L
- [ ] **SV-73** Record-call global shortcut on Windows defaults · S
- [ ] **SV-74** Screen region: annotate (arrows, boxes, pen), paste where you were, Ask (`ScreenPart`) · M
- [ ] **SV-75** One permissions page with Windows privacy deep links (`SystemPermissions`) · S
- [ ] **SV-76** Run a user script (PowerShell or `.lnk`) as an approved tool, as the Mac's `run_shortcut` · S

### 6.7 App shell

- [ ] **SV-80** Hold Ctrl+Q to quit (`QuitHoldMonitor`) · S
- [ ] **SV-81** Notice when a database can't be opened, with recovery (`AppModel+StorageIncidents`, `SQLiteRecovery`) · S
- [ ] **SV-82** Eval question set to compare local models (`LocalEvalRunner`) · S
- [ ] **SV-83** Main and Settings windows in the taskbar and Alt+Tab (`DockPresence`) · S

## 7. Companion: the PC as server for the phone (CO)

- [x] **CO-01** The rest of the companion protocol. The audit missed that `core/src/companion/server.rs` with `src-tauri/src/companion/backend.rs` already dispatches every group: `options`/`start`; `timeline`/`watch`/`diff`/`entry`/`history`; `terminals`/`files`/`fileData`; `chats`/`chat`/`ask`/`chatStop`/`watchConversation`; `home`/`usage`/`music`; `inbox`/`inboxChat`/`inboxSend`/`inboxMark`/`watchChat`/`avatars`; `manage`/`subscribe`/`requestUpdate`; `pulls`/`pull`/`pullAct`/`pullWork` (checked during FD-07). Only `liveActivity` is missing, which is CO-07 · L
- [x] **CO-02** Compression, `protocolVersion`, `appVersion`, `oldestPhone` (`CompanionWire`, `CompanionCompatibility`): compression, `protocolVersion` and `appVersion` were already there; `oldestPhone` and keeping each phone's versions came with CO-09 · S
- [ ] **CO-03** Scopes per phone: read, approve, operate, chats, music, Nook Chat (`CompanionScopes`, `CompanionSetupSheets`) · M
- [x] **CO-04** Request-id receipts so a retried request runs once (`CommandReceipts`): already in `core/src/companion/live.rs` (`receipts_answer_a_repeat_once`) and `server.rs` · S
- [x] **CO-05** Images with messages and new sessions (`CompanionImages`): already in `core/src/companion/remote_digest.rs` (`image_bytes`, `message`, with tests) and listed as `images` · S
- [x] **CO-06** Sealed push through the relay instead of your own .p8 key (`RelayPushClient`); also Firebase pushes to Nook on Android (`register` with `fcm`) · M
- [ ] **CO-07** Live Activity planner and updates (`CompanionNotifier`) · M
- [ ] **CO-08** Deploy your own relay on Cloudflare from Settings (`CloudflareRelayDeployer`, `CloudflareRelaySetup`) · M
- [x] **CO-09** Per-phone app version and "phone too old" notice in Settings › iPhone · S
- [x] **CO-10** Steer and stop terminal sessions from the phone, not only approve and answer: a message continues the session in Nook (a copy while the terminal still works) and *End* ends its process, as on the Mac; steering a running terminal turn is not possible there either · M
- [ ] **CO-11** Android Keystore for secrets (TAURI.md ○) · M

## 8. Not portable: Mac-only parts and the Windows alternative

These stay out of a 1:1 port because Windows has no such API. Decide per row whether to build the alternative; when
it is built, add an item above and mark the row in TAURI.md.

| Mac part | Why not | Windows alternative |
|---|---|---|
| Notch, menu bar, Dock | macOS shell | Top-edge bar, tray menu, taskbar badge and jump list (UI-45…UI-51) |
| `AppleIntelligence`, `EmbeddedModel` (MLX), `MacReport` | Apple frameworks | Ollama or LM Studio (already used) |
| Apple Calendar (EventKit): `create_event`, `update_event`, `delete_event` | EventKit | Microsoft Graph, Google Calendar, CalDAV or WinRT `AppointmentStore` (CH-92) |
| Reminders: `create_reminder`, `complete_reminder`, `delete_reminder`, `list_reminders`, `search_reminders` | Reminders.app | Microsoft To Do through Graph |
| Contacts: `search_contacts`, `ContactPhotos` | Contacts.app | Graph or Google People |
| Mail.app: `inbox_mail`, `mail_unread`, `read_mail`, `search_mail`, `MailIndex`, `MailStats`, `MailActions`, `MailSender` | Mail.app and AppleScript | Graph, Gmail API or IMAP (CH-90, CH-91) |
| Notes.app: `list_notes`, `search_notes`, `read_note`, `create_note` | Notes.app | OneNote through Graph, or a Markdown/Obsidian folder |
| Messages/iMessage, FaceTime: `search_messages`, `read_messages`, `messages_open_chats` | `chat.db` | None (Phone Link has no API); SMS could come later through the Android companion |
| Bear, Things: `search_bear`, `read_bear`, `search_things` | Mac apps | None |
| Shortcuts.app: `run_shortcut` | Shortcuts | PowerShell scripts or Power Automate Desktop (SV-76) |
| `read_open_app`, `@open` mirror of a Mac app (`MacAppMirror`, `EmbeddedAppView`) | macOS windows | A WebView2 pane for web apps (CH-73) |
| WhatsApp Desktop's local database | encrypted on Windows | The gateway or chatd |
| AppleScript focus of Terminal/iTerm (`SessionFocus+Mac`) | AppleScript | Win32 `SetForegroundWindow`, Windows Terminal (partly in `src-tauri/src/agents/terminal.rs`) |
| iOS Simulator (`Simulators`, `SimulatorStream`) | Xcode | Android emulator through `adb`/`scrcpy` (AG-12) |
| `SudoAskpass` | sudo | UAC explainer on Windows, `SUDO_ASKPASS` on Linux |
| VoiceOver announcements (`AgentAnnouncements`) | VoiceOver | UI Automation live regions, ARIA live regions |
| Keychain secret provider | Keychain | Credential Manager (already used) and the `op` CLI (CH-97) |
| Claude Desktop computer use (`request_access`) | Mac-only in the Claude app | None |
| AX accessibility, Vision OCR, `SFSpeechRecognizer`, `AVSpeechSynthesizer` | Apple frameworks | UI Automation, `Windows.Media.Ocr`, whisper.cpp or `Windows.Media.SpeechRecognition`, WinRT `SpeechSynthesizer` (mostly already used) |
| Core Audio process tap | Core Audio | WASAPI loopback (used for the Notetaker; per process still needed, SV-39) |
| Carbon hot keys, `CGEventTap` | Carbon | `WH_KEYBOARD_LL` (SV-45, SV-46) |
| MLX personal adapter, FluidAudio Parakeet and diarizer | Apple silicon | llama.cpp, sherpa-onnx (SV-48, SV-50, SV-63) |
| AirPlay output | AirPlay | Windows audio endpoints and Spotify Connect (SV-38) |
| Sparkle-style app swap | macOS | Tauri updater with NSIS/MSI (SV-01) |
| Portfolio | switched off on the Mac too | Port when it ships there (CH-103) |
