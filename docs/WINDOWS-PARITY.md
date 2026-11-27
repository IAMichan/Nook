# Windows parity: the checklist to make the Windows app match the Mac

The macOS app (`apps/macos`) is the specification. The Windows app is the Tauri app (`apps/tauri`), which also
builds for Linux and Android. [TAURI.md](TAURI.md) says what has been ported; this file lists **everything that is
still missing**, as numbered items, so the gap can be closed one item at a time.

The list comes from an audit on 2026-11-16 of every Mac area against the Tauri code (file by file, tool name by tool
name, and the Mac commits since 2026-11-01). Nothing here was run on a real Windows PC; "missing" means no code or UI
was found.

## How to use this list

- **One item, one pull request.** Pick an unticked item, port it, and in the same PR tick it here (`- [x]`) and update
  its entry in [TAURI.md](TAURI.md). Large items (L) may be split into several PRs; tick the item when the last one lands.
- **Keep the blank lines.** Items are separated by a blank line so that ticking neighbouring items in parallel pull
  requests merges without a conflict; `scripts/docs-merge-layout.py` checks this in CI.
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
- [x] **FD-05** Shared desktop components in `src/components/ui/`: move Sheet, Dialog, Menu, TabBar, Toggle, SearchField, EmptyState, Banner and StatusPill out of `views/companion/ui/`, and add the Svelte twins of `NookTooltip`/`HoverCard`, `ConfirmedButton` (replaces the remaining `confirm()` calls), `NookSkeleton`/`PatientSpinner`/`BusyLine`, `NookCountBadge`, `NookFilterChip`/`ChipFlow`, `NookStatTile`, `NookTag`, `NookSectionLabel`, `ListEmptyNote`/`LoadFailedNote`, `IconDetailRow`, `CopyIconButton`, `RefreshIconButton` (with feedback), `TabCloseButton`, `HoverReveal`/`HoverRowFill`, `DisclosureChevron`, `TimelineNewDivider`/`TimelineEarlierRow`, `ProjectIconView`, `DropdownTileGrid`/`ModelPickerDropdown`, `EmojiBrowser`, `ImageModal`, `QRCodeView`, `NookAcknowledgeButton`; list them next to their Swift names in UI-COMPONENTS.md · L
  - [x] Part 1: Sheet, Dialog, Menu, TabBar, Toggle, SearchField, EmptyState, Banner, StatusPill (with `Ico` and `PulseDot`) moved to `src/components/ui/` with a desktop look and the phone look inside `.phone`; `ConfirmedButton` and `ask()` replace the last `confirm()` calls
  - [x] Part 2: `NookTooltip`/`HoverCard`, `NookSkeleton`/`PatientSpinner`/`BusyLine`, `NookCountBadge`, `NookFilterChip`/`ChipFlow`, `NookStatTile`, `NookTag`, `NookSectionLabel`, `ListEmptyNote`/`LoadFailedNote`, `IconDetailRow`, `CopyIconButton`, `RefreshIconButton`, `TabCloseButton`, `HoverReveal`/`HoverRowFill`, `DisclosureChevron` (logic in `lib/ui-parts.ts` with tests)
  - [x] Part 3: `TimelineNewDivider`/`TimelineEarlierRow`, `ProjectIconView`, `DropdownTileGrid`, `ImageModal`, `QRCodeView` (the Companion and WhatsApp QR codes use it), `NookAcknowledgeButton` (already `components/NoticeOk.svelte`)
  - [x] Part 4: `ModelPickerDropdown` (`src/components/ui/ModelPickerDropdown.svelte`, `lib/model-picker.ts`, shared by `BrainPicker.svelte` and `AgentModelPicker.svelte`) and `EmojiBrowser` (`src/components/ui/EmojiBrowser.svelte`, Unicode Emoji 15.1 `lib/emoji-catalog.ts` with Nook shortcodes, decayed frecency `lib/emoji-usage.ts`, wired into `ChatDetail.svelte`'s composer smiley and `Menu.svelte`'s reaction picker "+")

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

- [x] **UI-03** Search over about 170 settings by their on-screen name, with the page path, scrolling to and lighting the row (`SettingsSearch`, `SettingsHighlight`) · M Done (2026-11-20): the sidebar search finds the pages first, then about 200 settings by the name their page shows (`lib/settings-search.svelte.ts`, the page's own `tr` pairs, so every language reads as on screen), each with its page path. Opening one opens the subject, opens the fold it sits in (`Fold keys`), scrolls the row to the middle and lights it for 1.6 s (`lightSetting`); `settings-search.test.ts` fails when a name no longer appears on a page.

- [x] **UI-04** Attention counts on sidebar rows · S Done (2026-11-20): the counts the Mac shows (`SettingsSidebar(badges:)`): Overview its attention list, Chat apps a chat app that is on but lost its link, Services the linked services whose last refresh failed or need a new sign-in, Typing one while completing is on without a model (`views/settings/attention.svelte.ts`, `attention.badge`).

- [x] **UI-05** Restore defaults per page with a confirmation (`SettingsRestore`) · S Done (2026-11-20): "Restore defaults" in the bar over General (session list, ask before quitting) and Appearance (look, accent, theme, density, diff colors, custom colors), the pages the Mac has it on, with a confirmation, dimmed once nothing differs. Hold to quit is not a Windows setting (SV-80).

- [x] **UI-06** Page intro and a line per subject (`SettingsPageIntro`) · S Done (2026-11-20): every page opens with its name, one line on what it holds, the tab bar of its subjects with a line on the one shown, and the data note of a few subjects (`views/settings/intro.ts`).

- [x] **UI-07** Overview with a row per page, the setup checklist, outdated agents, words typed today, automation next/failed, phone last seen, update status (#1653) · M

- [x] **UI-08** Folding sections (`SettingsFold`, #1651) · S Done (2026-11-20): `views/settings/Fold.svelte` (chevron, name, summary while closed), used for Face and finish, Text and layout, Custom colors, All models and runtimes, Model per agent and Away from home; a search for a setting inside opens it.

- [x] **UI-09** Setup sheets as numbered steps ending in a check (`SetupSheet`, `SetupCheckStep`) · M Done: shared `SetupSheet`, `SetupStep`, `SetupCheckStep`, `StepAction`, `SheetPart`, and `setup-check.ts` under `apps/tauri/src/components/ui/`, adopted across `PairPhoneSheet`, `ServiceSheet`, `GitLabSheet`, and `McpAddSheet`.

- [x] **UI-10** One field style and rows grouped into cards, note tones (`SettingsFormStyle`, `SettingToggle`, `SettingFieldRow`, `SettingNote`, #1607, #1551) · M Done: unified Settings field style (`28px` height, `220px` inline width, `--field` / `--field-stroke` lifting to `--line2` on focus) in `views/settings/settings.css`, shared `SettingsSection`, `SettingToggle`, `SettingFieldRow`, `SettingNote` (with icon+color tones `info`/`success`/`warning`/`error`), and `setting-note.ts` under `apps/tauri/src/views/settings/`, adopted in `General.svelte` and `Notch.svelte`.

- [x] **UI-11** Settings components `SettingsTile`, `SettingsLinkRow`, `InUseLabel`, `ConnectMethodBadge` · S Done (2026-11-26): added `views/settings/SettingsTile.svelte`, `SettingsLinkRow.svelte`, `InUseLabel.svelte`, and `ConnectMethodBadge.svelte` with pure helpers and unit tests (`lib/settings-ui.ts`, `lib/settings-pages.ts` section/tile icon maps), wired into `Overview.svelte`, `Assistant.svelte`, `PairPhoneSheet.svelte`, `ModelAdvice.svelte`, `CatalogueCard.svelte`, and `Accounts.svelte`.

- [x] **UI-12** Every Settings row the chat can change through BR-20 exists in the UI with the same key · S Done (2026-11-26): aligned `core/src/settings_catalog.rs` and `src-tauri/src/tools/settings.rs` 1:1 with the Settings UI (all 26 catalog keys including `nook_style`, `show_bar`, `open_window_at_launch`, `dictation`, `notices_chats`/`notices_nook`/`notices_suggestions`, `online_lyrics`, synced `notices_agents` card/strip/system/off, moved `energy_mode` to `maintenance`, synced all 37 `SECTIONS` with `settingsSections`, and added cross-layer UI binding tests in `src/lib/settings-catalog.test.ts`).

- [x] **UI-13** Open the right OS settings page from a task: a table of `ms-settings:` URIs (GNOME/KDE panels on Linux) in `core/src/brain/os_settings.rs` (`SettingsPanes`) · M Done (2026-11-23): `core/src/brain/os_settings.rs` maps Windows `ms-settings:` URIs plus GNOME/KDE panels with Dutch/English keyword matching (`matching`, `find`, `guide`).

### 2.2 Settings pages and rows

- [x] **UI-15** General: inbox working projects, confirm quit while sessions run, session list options, the confirmations list (`GeneralListAndConfirmations`); hold to quit is SV-80 · S Done (2026-11-20): Session list (group by project, working sessions on their own shelf, one stored view shared with the Agents tab's filter menu, `lib/agents-view.ts`) and Confirmations ("Ask before quitting while sessions are working", `confirm_quit`, asked by the tray's Quit, see UI-50). "Hold ⌘Q to quit" is the Mac's own (SV-80).

- [x] **UI-16** General › Bar (the notch page): show bar, bar on every screen, which screen, hide when idle, open on hover, open window at launch, equaliser color (`NotchSettingsSection`, `BarScreenChoice`) · S Done (2026-11-23): `views/settings/Notch.svelte` now has every Mac Bar row including "Show Nook on every screen" (mirrored top bars on secondary screens while Nook opens on the screen your mouse is on) and "Open panel when hovering over the bar", wired to `platform/desktop.rs` and `views/BarMirror.svelte`.

- [ ] **UI-17** Notifications page: per kind (agents, chats, Nook, suggestions) card / strip / system / off, quiet hours, warning when system notifications are blocked, per-app rules with search (with SV-10, CH-66) · M Still open: notices for chats and Nook are posted from the Chats views and the bar, which another helper owns right now, and quiet hours need one notice path in Rust first; Windows has the agent notice size only. Update 2026-11-20: done as a model and one Rust path. `nook_core::services::notice_rules` (the Mac's `NoticeRules`: style per source, apps on or off, quiet hours with "approvals and questions still come through") decides every notice through `notices::decide` and the `notice_decide` command; agents follow it now (the bar's card or line, system notifications, approvals), and the page shows a style per source and quiet hours. Open: chats, Nook and Think Along do not ask `notice_decide` yet (their views belong to other helpers), there are no per-app lists, and "quiet for the session you are watching" has no signal on Windows. Update 2026-11-20 (later): Notifications per app has a switch per agent (`noticeRules.apps`, "agents:<name>"), read by `notice_decide` for every agent notice; chat apps join once the chats ask `notice_decide`.

- [x] **UI-18** Sound: a file picker per event with preview (with SV-53) · S Done (2026-11-21): all four moments (done, permission, attention, error) have their own picker (Nook's sound, a Windows sound, your own file, or none) with preview, and "Custom sounds" opens the folder.

- [ ] **UI-19** Shortcuts: rebind in-app keys (`KeybindingsSettingsSection`, a keys file), window-capture target, point-to-bar and open-panel global keys · M Update 2026-11-21: Panel keys is one flat list in the Mac's order (`Keybindings.commandIDs`), without group captions. The Mac's composer keys (send, new line, dictate, message history, access level, draft undo/redo, send the first queued message, command palette) have no Windows command yet.
  - Part done (in-app keys): the main window's keys are rules (`lib/keybindings.ts`, the Mac's `Keybindings`: key, command, when; the last match wins, `-command` takes a key away), with your own in `keybindings.json` in Nook's data folder (`src-tauri/src/keybindings.rs`). Settings › Shortcuts › Panel keys lists every command with its keys from the live rules, Change records the next chord, Reset puts the default back, and two commands on one key are flagged; the cheat sheet reads the same rules. Open: the window-capture target (no window capture on Windows yet, SV-70) and the global point-to-bar and open-panel keys.

- [ ] **UI-20** Brain: subscription brains (BR-02), OpenRouter sign-in (BR-04), pick up a key copied on the service's page (`ClipboardKeyCatcher`), searchable model list, local-vs-external warning, screen brain (BR-03), "no images" hint · L

- [x] **UI-21** Assistant: Double Tap settings (SV-45), take over on tap, buddy moments with tone and birthday and "breathe now" (SV-19), manage permissions link · L Done (2026-11-23): `views/settings/Assistant.svelte` now has Double Tap settings, take-over-on-tap, buddy moments (tone, birthday, breathe now), and Manage permissions (the Windows Double Tap global hotkey runtime stays tracked in SV-45).

- [x] **UI-22** Instructions: saved prompts, spaces, context inspector (BR-55, BR-56) · M Done (2026-11-23): `views/settings/Instructions.svelte` now includes saved prompts, spaces, and a live context inspector.

- [ ] **UI-23** Typing › Dictation under Typing as on the Mac, with the translate row and the right-key option; Typing › Apps per-website rules · M

- [ ] **UI-24** Agents: list on the left with details on the right (#1572), own ACP agents (AG-21), Antigravity installer (AG-23), updates (AG-28), per-account options (CH-98), Codex app-server and OpenCode server switches · L Partly done (2026-11-21): list-and-detail layout, agent version checks, Antigravity installer, and Skills tab (`views/settings/Agents.svelte`, `workspace_agent_versions`, `workspace_skills_catalog`). Open: own ACP agents (AG-21), per-account options (CH-98), and Codex app-server / OpenCode server switches. Update (2026-11-21): the agents page is the Mac's one card (the list with logo, version in mono and a status dot on the left; the agent picked with its own scroll on the right: Link with Nook, How Nook talks to it for Antigravity's ACP server, Updates, and Accounts with "+ Add account" in the heading), every list a shared `ConnectionRow` (`views/settings/ConnectionRow.svelte`: switch, "…" menu, chevron that opens the row in place); Skills is now its own subject between Coding agents and Usage & costs (`views/settings/AgentsSkills.svelte`: where skills go, the skills the chosen agents read with SKILL.md, scripts and a switch, and the skill folders). Still different: the Mac's online skill search (skills.sh), collections, and installing or updating skills from GitHub have no Windows backend; Updates runs the install command in a terminal instead of detecting the installer.

- [ ] **UI-25** Agents › Usage: subscriptions, usage by model, week recap, token savings (with AG-49) · M

- [ ] **UI-26** Sessions page: models per agent, online model list, auto models/accounts, title and agent instructions, steer by default, timeline detail, screen reader, max sessions at work, continue after relaunch, text generation, tidying, snooze options, auto-settle rules, kept sessions · L Partly done (2026-11-20): New session, Model per agent (folded), Behavior (automatic titles, steer by default, costs), When a session stops or Nook restarts, Tidying up. Open: online model list, Auto models/accounts, title and agent instructions, timeline detail, screen reader, most sessions at work, continue after relaunch, text generation, snooze, auto-settle rules and kept sessions, which have no Windows backend yet. Update 2026-11-20: "Your own rules for titles" (`title_instructions`, given to the brain with every title). Update 2026-11-20 (later): "Instructions for every agent" (`agent_instructions`, put before the session's own instructions at launch, per project under Projects).

- [ ] **UI-27** Sessions › Worktrees (branch prefix, build leftovers, cleanup report) and Sessions › Open in (editor, terminal, search engine, where links open, trusted certificates, default browser, browser extension, browser memory) · M Partly done (2026-11-20): Worktrees tab with the folder and the branch prefix (`branch_prefix` in the workspace settings, used for every branch Nook names, `models::normalized_branch_prefix`). Open: build leftovers, cleanup report and the whole Open in tab (editor, terminal, search engine, links, certificates, default browser, extension, browser memory). Update 2026-11-20 (later): an "Editor & browser" tab with the editor a session's folder opens in (File Explorer or an editor found on the PATH: VS Code, Cursor, Windsurf, Zed, IntelliJ IDEA, Sublime Text; `workspace_editors`, `workspace_open_in(folder)` for the session view). Update 2026-11-21: Worktrees now has source-control rows, fast worktrees, build leftovers, cleanup rules, cleanup report, and orphan folders (`views/settings/Worktrees.svelte`, `workspace_worktree_cleanup_status`, `workspace_worktree_cleanup_now`). Open: terminal choice and Nook's browser settings. Update (2026-11-21): Editor & browser is complete for what Windows can do (`views/settings/OpenIn.svelte`, `core/src/workspace/open_in.rs`, `core/src/workspace/browser_history.rs`, `lib/workspace/open-in.ts`): Terminal (Nook's own, Windows Terminal, PowerShell 7, Windows PowerShell, Command Prompt found on the PATH; `workspace_terminals`, `workspace_open_terminal(folder)`), and Nook's browser with the search engine (the Mac's seven, used by the address bar), where links in an agent's conversation open (Nook's browser window or your own browser, Ctrl-click the other way; Markdown with a session folder) and Remember visited pages (kept in `browser-history.json`, agent-opened pages left out, address-bar suggestions, Visited pages with Clear history; turning it off clears them). Left out because Windows cannot do it: Sign-ins, Import sign-ins and Saved passwords (Nook's browser window is incognito and keeps nothing), trusted certificates (WebView2 has no per-site trust hook in Tauri), Extensions (Chrome Web Store installs into WebView2 are not wired) and Default web browser / Nook in your browser. Fast worktrees use APFS clones and stay Mac-only. Open: the session view's "Open in terminal" button (Agents helper) should call `openInApi.openTerminal`.

- [ ] **UI-28** Automation: public webhook relay, port check, secret providers, remote MCP, Nook's own scheduled tasks · M

- [ ] **UI-29** Projects & pull requests page: per-project overrides (agent, permission, isolation, branch prefix, cleanup, browser sign-ins, instructions), archived projects, watched pull requests, code hosts, commit style, no-agent-credits switches · L Partly done (2026-11-20): the page exists with Projects (your projects, add one from a folder, take one off the list) and Pull requests (watched organizations and repositories, moved from Services). Open: per-project overrides and archived projects (the workspace keeps no values per project yet), code hosts, commit style and the agent-credits switches. Update 2026-11-20: per-project values still open: the backend could hold them, but they only take effect when the new-session composer reads them, and that view belongs to the Agents helper. Update 2026-11-20 (later): per-project values are built: `project_overrides` in the workspace settings (name, agent, mode, permission, isolation, branch prefix, title rules, agent instructions, archived), the commands `workspace_project_settings(path)` → { path, override, defaults } and `workspace_set_project_settings(path, value)`, and the page with Inherited and a reset per value plus Archived projects. A new session already takes the project's branch prefix, agent instructions and title rules in the backend; the new-session screen still has to read `defaults` for agent, mode, permission and isolation (Agents helper). Open: code hosts, commit style and the agent-credits switches.

- [ ] **UI-30** Chats page: collect notifications, read on open, read in the app on open, other apps, extra field, Giphy, Beeper import, chat notice rules, connector health · M

- [ ] **UI-31** Devices › Machines (SSH machines, with AG-132) · L Still open: SSH machines need AG-132 first.

- [x] **UI-32** Privacy: privacy level, "what leaves this computer", forget screen text, apps Nook never reads, OS permissions overview (SV-75), the On this device source picker as its own subject · M Partly done (2026-11-20): "Forget what Nook just saw" (`screen_forget` empties the live screen cache). Open: the privacy level and "what leaves this computer" (no redaction step before a cloud AI on Windows yet; the four promises are not claimed until they hold), apps Nook never reads, the OS permissions overview and On this device as its own subject. Update 2026-11-20: Permissions overview for Windows (microphone and notifications from Windows' privacy switches, with Allow / Revoke… opening the Windows Settings page; `permissions_overview`). The privacy level and the four promises stay open. Update 2026-11-21: Privacy has the Mac's tab bar with two of its parts: Privacy (screen text, permissions, linked accounts) and Activity log (the log). Privacy level, Access and Only on this computer as the Mac splits them stay open. Update 2026-11-22: Privacy level as on the Mac: "What a cloud AI sees" Open / Balanced / Strict with its line, the local-brain note, "What leaves your computer" with the four promises, and Screen text; Access holds the permissions and linked accounts. Behavior: `brain::privacy_level` (unit-tested) filters what Nook gathered (context, screen text and every tool result in the answer loop) before an external brain gets it, and what Nook tools give a coding agent; Strict also keeps the screen and the clipboard on this computer (`Settings::kept_here`, also for agents). Still open: apps Nook never reads, and Only on this computer as its own subject. Done (2026-11-23): `views/settings/Privacy.svelte` now completes apps Nook never reads and the On this device source picker alongside Privacy level, What leaves your computer, Forget screen text, and OS permissions overview.

- [x] **UI-33** Maintenance: updater and channel (SV-01, SV-02), redacted diagnostics export, provider traffic log, OpenTelemetry (SV-05), demo data switch, energy moved here as on the Mac · L Partly done: updater and channel, energy under System (2026-11-19). Open: redacted diagnostics export and the provider traffic log (the Windows app has no log to export yet), OpenTelemetry (SV-05), and the demo data switch (only the quiet service reads `demo_data`). Update 2026-11-20: done except OpenTelemetry and demo data. Nook now writes its own log as rotating files in the data folder (`logs/nook.log`, 2 MB, three older files; `nook_core::diagnostics`), "Copy diagnostics" copies versions, set-up and the last half hour redacted (mail addresses, keys, phone numbers, your name in paths), "Show log files" opens the folder, and "Keep agent traffic" writes what Nook and each agent send each other to `workspace/provider-traffic` (4 MB per process, `workspace::traffic`). Update 2026-11-21: OpenTelemetry export (SV-05) is now in Maintenance (`views/settings/Maintenance.svelte`, `core/src/services/telemetry.rs`, `telemetry_status`/`telemetry_save_headers`/`telemetry_test`); only demo data remains open. Update 2026-11-21: OpenTelemetry export is done (SV-05, AG-33): the section sits after Diagnostics as on the Mac, and Nook sends its own agent turns, scheduled task runs and launch time; demo data is the one item left here. Done (2026-11-23): `views/settings/Maintenance.svelte` now includes the Demo data switch alongside updater/channel, redacted diagnostics export, provider traffic log, OpenTelemetry export, and energy.

- [x] **UI-77** Settings controls drawn as on the Mac: a switch for every on/off row (Tauri draws checkboxes), capsule pickers with up/down chevrons instead of native selects, segmented controls for two to four choices (appearance, background work, privacy level, tone; Tauri draws tiles or a select), small grey capsule buttons, and the Mac's compact row height (Tauri rows are about a third taller); found in the visual audit, builds on UI-10. Privacy level and tone use `Segmented.svelte` when UI-32 and UI-79 add them · M

- [x] **UI-78** Section headings as on the Mac: a bold title with an optional grey line under it and an action on the right ("Open setup", "Add account"); Tauri draws small grey labels · S. Done in `settings.css` (`h3` in the title style, `.section-info` for the grey line, `.section-head` for a title with an action) with the Mac's page intro (`intro.ts`: page line, tabs with icons, the subject's line), 32 px between sections and the bar as Settings › page; "Open setup" is on the Overview. "+ Add account" on Coding agents waits for the agent detail layout

- [x] **UI-79** Appearance in the Mac's order: preview with mood picker (UI-56), Style cards Minimal / Classic / Playful with a face colour row, a "Face and finish" fold, "Nook as buddy" (small moments, tone, a sample line, birthday, breathe now; moved here from Assistant, see UI-21), Theme as a segmented control above the theme grid (UI-70), a "Text and layout" fold; Tauri shows appearance tiles, accent colour and density · M. Partly done: the preview with mood picker, Style with the colour row, Theme as a segmented control and the "Text and layout" fold are in Mac order, with "Restore defaults" in the bar; the Style cards, "Face and finish" and "Nook as buddy" wait for Windows settings for the face (no `nookLook` yet) Update 2026-11-20: Theme now has the theme grid and VS Code import, and "Text and layout" holds density and diff colors; custom colors and sharing the look follow (UI-72, UI-73). Done (2026-11-20, later): Style cards Minimal / Classic / Playful with Nook in each look, "Face and finish" (eyes round / bars / dots, mouth expressive / line / none, gloss, glow, blush; `nook_look` in the settings, drawn by `Orb.svelte` in every window, his color the accent) and "Nook as a buddy". Differences: the mouth shows the mood (smile when done, frown on an error, open while working) but does not move along with spoken answers (no lip sync on Windows), and "Nook as a buddy" holds "Little moments" for the orb's own moments (hello hop, waking up, giggle, blush); the Mac's greetings, tone, birthday and "breathe now" have no Windows feature to switch.

- [x] **UI-80** Assistant rows as on the Mac: "Search the web when needed", the Double Tap section (UI-21), "What Nook may do" as Ask / Small / More (BR-10) instead of the "Do small things right away" checkbox, and the note that points to Brain when the brain runs locally · S Partly done: "What Nook sees" (Track all my screens, Use my screens with every question, Currently in view; the clipboard, files and calls stay there as Windows' own sources), "Proactive suggestions" (Ask about selected text and Search the web moved here from Brain, Suggest ideas while I work) and "What Nook may do" as Ask / Small things / More with its explanation; the screen area shortcut moved to Shortcuts. The Double Tap section and the "Manage permissions" row need a Windows feature Done (2026-11-23): `views/settings/Assistant.svelte` matches the Mac's Assistant rows including Search the web, Double Tap section, What Nook may do (Ask / Small / More), Manage permissions, and local-brain note.

- [ ] **UI-81** Typing › Complete as on the Mac: the first tab has "Type less, in every app" and "In Nook's composers" (next prompt AG-70, reply suggestions in chats, actions from conversations, the model for suggestions, how your message goes on, SV-60) with the no-local-model warning; Tauri's sliders and keys belong under Style and context · M Partly done: "Type less, in any app" with its line, the Mac's tab names (Apps and sites, Playground), and Model, Suggestions and Keys only once completing is on, as on the Mac. "In Nook's composers" (next prompt, reply suggestions, actions from conversations, the model for suggestions) waits for those features on Windows

- [x] **UI-82** Brain page layout as on the Mac: the "Choose a brain" card on top, "Where Nook thinks" Local / External, models recommended for this computer's memory with Install, a connection test row, an "All models and runtimes" fold, then "Quality of the local brain" (evidence first, check answers, measure); Tauri starts with the Answers rows (with UI-20) · M. Done: status card, "Where Nook thinks" (Local / External, the explanation behind ⓘ), the advised models as rows with logo, star and Install (`ModelAdvice rows`), the Connection row, the "All models and runtimes" fold (runtime, model, "Start the local brain myself"); for External: Service, Sign in, Model and Screen work. The answer rows stay under "Answers" at the end

- [ ] **UI-83** Services page as on the Mac: a search field over the connections, "Nothing linked yet" with suggested service tiles and Sign in, "Add connection" in the section heading, and a Music section (Spotify row, keep listening history, clear it, look up lyrics online; features in SV-31, SV-36, SV-37); Tauri shows only the intro until something is linked · M. Partly done: the search field, the "Services" card with "Nothing linked yet" and the catalogue tiles (graphite, Sign in in Nook's colour) inside it, the intro under the page line; "Add a connection" in the heading and the Music section are still open (no catch-all add sheet or music settings on Windows yet)

- [x] **UI-84** Memory as on the Mac: "What Nook remembers (n)" with a field to add one, each memory with when it was seen, how sure and how often used, learned sources with a count, and Forget all · S Done: "Nook remembers and learns" with its line and two switches, "What Nook remembers (n)" with the field, a search over six, the memories by kind with edit, pin, keep-local and forget under the pointer, "Learned sources" with Forget everything, and the import last. The Mac's line on where memory is stored is left out until Windows says where its memory lives

- [x] **UI-88** Settings › Companion laid out as the Mac's Settings › iPhone (`CompanionSettings`, `CompanionSetupSheets`): paired phones as `ConnectionRow`s under a `ConnectionListHeader` with "+ Pair", each with its app version and status ("Needs an update"), opening to the outdated or behind note, "What this iPhone may do" (`CompanionScopeToggles`) and the details; pairing in a `PairPhoneSheet` with numbered steps (the app, what it may do, the code, Nook seeing the phone arrive) instead of the inline code and the "next phone" switches on the page; *Send through* as a segmented control · M

- [ ] **UI-91** Settings pages that still differ from the Mac for want of a Windows feature (found while matching every page, 2026-11-19): Shortcuts has no "Record a call", "Capture the front window" with "Window captures go to", or "Open panel", and Panel keys can't be rebound (no keybindings.json, no Record); General has no Confirmations (no quit check on Windows: "Ask before quitting while sessions are working" needs Rust, "Hold ⌘Q to quit" is Mac-only); Bar & windows has no screen choice or "Hide Nook when idle" (`screen_choice` and `hide_when_idle` are stored but nothing on Windows reads them), no "Open panel when hovering" and no "Open the main window when Nook starts"; Notifications chooses one style for agents only (the Mac has a style per source, quiet while watching, quiet hours and the per-app lists); Sessions has no title rules, agent instructions, timeline detail, screen reader announcements, most working sessions, continue after relaunch, kept sessions, auto-settle rules or build leftovers, and no "Auto model choice" fold; Sessions has no "Editor & browser" tab; Worktrees has no branch prefix, source control rows or cleanup; Automation has no "Tools per agent", secret providers or remote MCP; Projects has no values per project (only the list, adding one and taking one off it), and Pull requests has no "My organizations", forge hosts or commit style; Devices has no Machines tab · L Update 2026-11-20: General now has Confirmations; Bar & windows has the screen choice, Hide Nook when idle and Open the main window at launch; Worktrees has the branch prefix; Privacy has Forget what Nook just saw. The rest of this list stays open for the reasons in UI-16, UI-17, UI-19, UI-26, UI-27, UI-29, UI-31 to UI-33. Update 2026-11-21 (side-by-side round): Sound & voice is in the Mac's order (Sounds with a picker per moment, then Speaking; the Notetaker shortcut only under Shortcuts); Dictation starts with Dictate anywhere ("Turn on dictation"); Typing's other tabs show "Autocomplete is off" with Turn on while it is off; Typing has the "In Nook's composers" heading and a model menu for suggestions; Coding agents › Usage & costs has the weekly recap, Show costs (moved from Sessions), Subscriptions and Sessions started in Nook with Period and Agent; Memory has its storage note under the intro; Assistant's access picker is drawn at its own width; Appearance's custom color is a capsule; Bar & windows dropped its extra explanation and dims "Show Nook in your screenshots" while Nook stays out of sharing; the title-rules field on Sessions is one line and no longer leaves a gap. Still different for want of a Windows feature: Coding agents' list-and-detail layout and Skills tab, the Sessions rows of UI-26, Worktrees cleanup, Nook's browser, Tools per agent, CLIProxyAPI hubs, "All agents on this computer" token totals, the next-prompt and chat-reply suggestions, Double Tap, buddy tone and birthday, the privacy level, demo data, OpenTelemetry export, Chat apps from notifications, and Services' "Add a connection". Update (2026-11-21): Editor & browser now has Terminal and Nook's browser (search engine, where links open, remembered pages); its sign-ins, passwords, certificates, extensions and default-browser rows stay out (UI-27).

### 2.3 Main window

- [x] **UI-35** Split view (a second tab beside the current one) and a tab torn off into its own window, reopened after a restart (`PanelSplit`, `TabWindowController`) · L
  - Done: the split button in the sidebar's head (Show beside: Nook, Agents, Chats, Music, Off; In its own window), the tab beside with its own header (swap with the main tab, own window, close) and drag line (double-click resets to 440), its own list (the window's sidebar stays the main tab's), the outlined tab in the tab bar that swaps on a click, and a request for a tab that already shows beside landing in that pane (`lib/panel-split.ts`, `lib/tab-windows.svelte.ts`, `components/shell/SplitButton.svelte`, `BesideHost.svelte`, `views/Main.svelte`). Torn-off tabs are windows of their own (`platform/tab_windows.rs`, `views/TabWindow.svelte`) with "Back beside the main tab", opened again at the next start; closing one by hand forgets it. Needs a run on a real Windows PC (FD-01): the torn-off windows keep the system title bar.

- [x] **UI-36** Back and forward through opened sessions and Nooks (Ctrl+[ and Ctrl+]) · S
  - Done: the Agents tab's head has the Mac's back and forward arrows through the sessions and pages you opened (`agents.back()`/`forward()`), also on Alt+Left and Alt+Right; Ctrl+[ and Ctrl+] walk that trail on Agents and the trail of Nooks you opened on the Nook tab (`lib/trail.ts`; a deleted Nook drops out), not inside a terminal, where Ctrl+[ is Escape.

- [x] **UI-37** Resizable sidebar with a remembered width, floating toggle on Agents (`PanelResize`, `PanelSidebarToggle`) · S
  - Part done: the Agents tab's sidebar toggle (lit in the head, Ctrl+B) puts the sidebar away and floats in the top left corner, remembered. Done: the sidebar's right edge is a drag line (220 to 420 px, never leaving the page less than a conversation's 360), followed once per frame and stored once at the end, double-click back to 280 (`lib/panel-resize.ts`, the Mac's `PanelSplit.width`).

- [x] **UI-38** Update button in the footer and the what's new / install / restart panel (with SV-01) · M
  - Done: the footer button opens Settings › Maintenance › Updates, which shows what is new, the steps with download progress, failures and what the last update brought.

- [x] **UI-39** Clone progress stack at the top right with Hide and Cancel (`CloneNoticeStack`) · S
  - Done: "Clone repository" runs `git clone --progress` through `workspace/clones.rs`; each clone is a notice in the window's top right corner ("Cloning owner/repo", the stage, percentage and git's own words from `core/src/workspace/clone_progress.rs`, the Mac's `GitCloneProgress`), with Hide and Cancel (which stops git and removes the half-made folder), in every window (`components/shell/CloneNotices.svelte`). The composer still gets the folder when git is done. Open: the Mac's "Cloned …" toast with Open, and the box freeing at once (the composer that asks waits for the folder; `views/agents`).

- [x] **UI-40** Cheat sheet as an overlay on its own key, not only in Settings · S
  - Done: Ctrl+/ (and ? outside a field) opens the Mac's `ShortcutCheatSheetView` over the window: the groups, a filter, "Change keys" to Settings › Shortcuts; Escape, the key again or a click beside it closes it (`components/CheatSheet.svelte`, names in `lib/shortcut-names.ts` for Settings › Shortcuts to share).

- [x] **UI-41** Tooltips in Nook's own look, only when text is cut off; feedback on every refresh click (#1656, #1657, #1630) · M
  - Part done: the shell's controls (sidebar head, tabs, footer, split pane) use the fast tooltip (`use:tip`) instead of the system's, a tab's tooltip only when its name is hidden, and the conversation title's only while it is cut off (`tip`'s new `whenCut`); the footer's refresh turns while it runs and says when Nook is up to date. Open: the same in the pages the shell does not draw (Agents, Chats, Settings, the Nook chat), which still have `title=` in places. Update 2026-11-23: the Settings pages' own buttons and switches (Voice, Archive, Pull requests, About, Shortcuts, Assistant, Automation, connection rows, emoji picker, Accounts) use `use:tip` now; Settings rows that pass a `title` to a component and the Agents, Chats and Nook chat pages are still open.

- [x] **UI-42** Starter grid two per row with an arrow on hover, checked against `NookStarters` · S
  - Done: two per row (one in a phone-wide window), each with the icon of what it is about, brightening with an arrow under the pointer (`components/StarterGrid.svelte`, the Mac's `SuggestionGrid`).

- [x] **UI-85** Window sidebar head and foot as on the Mac (`PanelSidebar`): no orb at the top left (Nook lives in the bar), search, talk and the sidebar toggle in the head (back and forward on Agents, UI-36), the tab switcher with a label only on the open tab; footer Settings, Pull requests, Automation, Usage on the left and refresh/update on the right (UI-38); Tauri shows the orb, a workspace and a games icon and a status dot · S
  - Done: no orb in the head, the tabs with the Mac's marks (sparkles, a prompt, two bubbles), a 280 px sidebar, and one footer for every tab (Settings, pull requests, Actions, usage, then refresh or the update button); Workspace, Gamer Mode, Companion, all terminals, the browser and worktrees open from search (Ctrl+K) and their Ctrl+number, as the Mac's tools do. The Nook list's head is the Mac's: Conversations and Scheduled as tabs with the new-Nook button, a filled search field, one-line rows with their age, and the Mac's empty state. Open: back and forward (UI-36) and split view (UI-35) in the head.

- [x] **UI-86** Agent session rows as on the Mac: project badge and name with age, the title, branch, +/− line counts, the agent's icon and a state such as Done; filter, folder and new-session buttons beside the search; the new-session composer with the agent's icon as picker, + and microphone inside it and the worktree choice below (Tauri shows text chips and a Start session button; with AG-90…AG-96) · M
  - Part 1 done: the list's head (a quiet search, filter and new as header icons), the empty state with "Set up coding agents", and the new-session composer with pills that carry a mark, a round send button and the worktree tray tucked under the box. Open: the rows themselves, the folder button and the agent's logo.
  - Done: the rows (`AgentListRow`: the project's initials badge and name with the status badge or age, the title, the branch with the agent's logo; hover buttons for snooze, pin and settle), the head's view menu (Group by project, Show working separately; grouping off by default as on the Mac), Add project and New session; the new-session screen (the question in display type, the composer of the Mac's metrics, "+" to add a file, one agent pill opening the model picker with the agents' rail, the models, the effort column and access and mode in its footer, microphone and round send, the worktree and base-branch tray as dropdowns); the open session's header ("project / title ⌄" with the session's actions in the chevron, the branch button, the terminal and changes toggles), the transcript's work lines ("Started by …", "Worked for 4s ›" over a hairline, no "Turn done" line) and the session composer ("+", agent pill, mic, send). The footer pages share a page header and the Mac's empty state (Pull requests, Actions, All terminals in a card) and Usage is a modal with Cost / Tokens / Limits. Not on Windows yet: "or start without a project" (the backend has no scratch-folder start outside the bridge), the account login notice, terminal splits, and +/− line counts on rows (the runs carry no line counts).

- [x] **UI-87** Nook chat composer footer as on the Mac: +, model, access level (BR-10) and sources inside the composer; Tauri puts "Automatic" and the model under it · S
  - Done: the panels behind the pills are the Mac's too (`Dropdown.svelte`, `DropdownRow.svelte`): the model picker with a rail of places (this computer, then each agent's logo, "+" to Brain settings), a search and starred rows (`BrainPicker.svelte`); the access menu with its three levels; the sources as "Automatic", "Only these" and "Never"; the plus menu (a file or folder, a part of the screen). The composer box has the Mac's surface, outline, padding and 736 px column, and the conversation the 820 px column, anchored at the bottom.
  - Done: +, the brain chip, what Nook may do and the sources are pills inside the box (`ComposerPill`: mark, text, chevron); the conversation's header is the title and a "…" menu (rename, pin, copy as Markdown, archive, delete), with no header on an empty Nook; answers use the Mac's heading sizes and the user's bubble its fill and radius.

- [x] **UI-89** The main window without a system title bar on Windows, as the Mac's runs its content into the title bar's row: the sidebar's head and the page's header fill the top row and move the window (double-click maximizes), minimize, maximize and close sit at the top right (`WindowControls.svelte`, `own_title_bar` in `platform/desktop.rs`); Linux keeps its window manager's frame. Settings takes the whole window with Back (and Escape) in its sidebar's top row, as the Mac's Settings is a window of its own. Needs a run on a real Windows PC (FD-01): resizing at the edges, Snap layouts on the maximize button (not offered by a drawn button) · M

- [x] **UI-90** Chats tab laid out as the Mac's (`ChatsTab`, `ChatsSidebar`, `ChatsList`, `ChatsDetail`): the empty page (`WSEmptyState`: inbox mark, "All your chats in one place", Turn on and Set up), the views All chats / New / Read and the apps (with Add a source and the legend) moved into the window's sidebar, the list with its title, Chats / Status / Channels tabs, search, day groups that fold and the Mac's rows (40 pt face with the app's mark, name, time in amber when new, newest message with your ticks, amber count, Read under the pointer), and the open chat with its header, "…" menu, day lines, bubbles in `--chat-mine` / `--chat-theirs` with the tail on the first of a run, the tray with what is new and the composer box with the round send button (`views/chats/*`, `lib/chats-list.ts` shared by every chat app) · M
  - Open: the main window folding its sidebar to the icon rail and putting the footer under the page while Chats is empty, and dropping the "Chats" page title (Main reads `chatsShell.folded`); Open in <app>, calls, chat info, reactions and the rest of CH-33…CH-60 (see each row).

### 2.4 Bar, tray and taskbar (the Windows equivalents of notch, menu bar and Dock)

- [x] **UI-45** The bar's new-track strip and equalizer while music plays · M
  - Done: a new track shows its title under the closed round Nook for six seconds ("Title – Artist" with three level bars, a click opens the Music tab; a message chip goes first), and while music plays the round Nook carries a small equalizer in the music tone (`lib/bar-music.ts`, `views/Bar.svelte`). The bars are a CSS loop, still under reduced motion. Open: real levels from the audio (SV-39).

- [ ] **UI-46** Proposal sentence under the bar ("Shall I add this to your calendar?" with View and OK) and friendly moments (with SV-19) · M Partly done (2026-11-20): arrival chip and compact strip under the closed bar match Mac visually; friendly moments still wait on SV-19.

- [x] **UI-47** Top-edge bar: open on hover, on every monitor, hide when idle (`platform/desktop.rs place_bar`) · M Done (2026-11-23): `platform/desktop.rs` places the bar at the top edge, follows the pointer across screens when "Show Nook on every screen" is on, draws mirrored top bars on the other monitors (`views/BarMirror.svelte`), hides when idle, and opens the panel on hover when enabled.

- [x] **UI-48** Live tray menu: needs-you line, next meeting, running agents, now playing, update, word count in the tooltip (the Mac's menu bar menu) · M Done (2026-11-26): added `menuBarCount` to `AutocompleteSettings` and Settings › Typing › Autocomplete (`Words today in the tray tooltip`), wired live `words_today` from `Autocomplete` into `tray_live::refresh` (updating on accepted words, settings changes, pause/resume, and stat resets), and added Pause/Resume autocomplete to the tray menu matching macOS `AppDelegate.rebuild` (alongside the existing status lines: next meeting, running/waiting agents, needs-you, now playing submenu, and update status).

- [x] **UI-49** Taskbar overlay badge for waiting items and a jump list (New Nook, Settings) (the Mac's Dock icon) · M Done (2026-11-23): `platform/desktop.rs` (`refresh_jump_list` via `ICustomDestinationList`, `jump_list_tasks`) publishes the Windows taskbar Jump List (New Nook, Settings, Agents, Chats) alongside the amber taskbar overlay badge; needs verification on a real Windows PC (FD-01).
  - Part done: the taskbar button carries an amber badge with the count of Nooks and sessions that wait on you (an overlay icon drawn in `tray_live::badge_pixels`, 1 to 9 then "9+"), the launcher's count on Linux. Open: the jump list (New Nook, Settings), which needs `ICustomDestinationList` through COM and a run on a real Windows PC to verify.

- [x] **UI-50** Quit asks while sessions run and stops agents step by step before a deadline (CTRL_BREAK, then TerminateProcess) · M Partly done (2026-11-20): Quit in the tray asks while Workspace sessions work ("A session is still working", Quit Anyway / Cancel, off under General › Confirmations); a restart into an update never asks. Open: the Mac's "Don't ask again" box (the Windows dialog has buttons only; the switch in Settings does it) and stopping agents step by step before a deadline (CTRL_BREAK, then TerminateProcess). Done (2026-11-23): `platform/desktop.rs` (`quit_texts_with_continue`, `polite_stop_process`, `force_terminate_process`, `shutdown_and_exit`) asks while sessions work and shuts down agents step-by-step (CTRL_BREAK / SIGTERM, then TerminateProcess / SIGKILL before the deadline); needs verification on a real Windows PC (FD-01).

- [x] **UI-51** Started at login: the main window opens without taking focus · S
  - Done: started with `--login`, the main window shows while it cannot take focus (`set_focusable(false)`, `WS_EX_NOACTIVATE` on Windows) and becomes a normal window a moment later (`open_at_launch` in `platform/desktop.rs`). Needs a run on a real Windows PC (FD-01).

### 2.5 Nook himself (orb)

Moods, face, reactions and buddy are SV-19 and SV-20.

- [x] **UI-55** Idle frame rate follows the energy plan; the orb takes the open tab's mood · S
  - Done: under the energy plan (`body.easy`) the idle loop rests, Nook does not blink, and the working and waiting loops run at a third of the pace (`components/Orb.svelte`); the open bar's Nook takes the mood of the tab on screen (the agents on Agents, "listen" on Music, the Nooks on Nook), the closed one everything that waits or works, agents included (`orbMood` in `lib/bar-music.ts`).

- [x] **UI-56** Large live preview with a mood picker on the Appearance page · S Done (2026-11-19): Nook at 88 px with a mood menu on the Appearance page.

### 2.6 Cards and keyboard

- [x] **UI-60** File preview window for photos, PDFs and video with "Open in app" (`FilePreviewWindow`) · M
  - Done: `previewFile(path)` (or the `nook-preview-file` window event) shows a photo, PDF, video or sound file over the window with its name and size, "Open in app" and close (`components/FilePreview.svelte`, `platform/file_preview.rs`; only files in your home folder, up to 64 MB inline, the CSP allows `blob:` media and frames). Open: the Nook chat's and the agents' file links still open files directly (their views call `previewFile` when they adopt it); PDFs need WebView2's viewer, so a run on a real Windows PC (FD-01).

- [x] **UI-61** Bar cards checked against `CardView`: one sentence, one detail line, at most two buttons, tinted state pill · S (verified against Mac `ZZLookBar` captures: open panel chrome, 3-column header capsule, resize grips, chip, compact strip, `ChatArrivedCard` with tails/integrated reply/split-pill, and agent alert card)

- [x] **UI-62** Every Mac key command (`KeyCommands`): next/previous session, back/forward, pin, rename, settle, undo, interrupt, copy reference, open in editor, reopen closed panel, close tab, terminal toggle and split, diff toggle, effort up/down, focus areas (F6), composer stash, start in background, paste as text, alternate send, find in chat, selection ask/quote, cheat sheet → `lib/shell-shortcuts.ts` with a rebindable store · L
  - Done (2026-11-23): every Mac command has its default key in `lib/keybindings.ts` (rebindable, UI-19), the shell runs its own and routes `cmd:<command>` to the active view (`lib/commands.ts`: `onCommand`, `onCommands`), and the views now register their handlers: `views/agents/AgentsTab.svelte` (`session.settle`, `session.pin`, `session.undo` with a 20-step undo stack, `session.copyReference`, `session.openInEditor`, `session.rename`, `modelPicker.toggle`, `effortPicker.toggle`, `permissionPicker.toggle`), `views/agents/run/RunPanel.svelte` (`terminal.toggle`, `diff.toggle`, `sessionPanel.toggle`, `sidePanel.toggle`, `panel.reopenClosed`, `tab.close`), `views/agents/run/RunComposer.svelte` (`composer.send`, `composer.sendAlternate`, `queue.steerFirst`, `session.interrupt`, `composer.stash`, `composer.pasteAsText`, `composer.startInBackground`, `composer.historyPrevious`, `composer.historyNext`, `composer.access`, `effort.up`, `effort.down`), and `components/SelectionAsk.svelte` (`selection.ask`, `selection.quote`).

- [x] **UI-63** Hold Ctrl to show key hints (`CommandHoldHint`); one Escape order and focus-area cycling · S
  - Done: Ctrl held alone for 200 ms shows each tab's Ctrl+number (`lib/key-hold.svelte.ts`, `components/ui/KeyHint.svelte`; `<html>` gets `keys-held` so a list can show its own); F6 and Shift+F6 go round the sidebar, the page, the composer and the tab beside; Escape closes innermost first (a menu or dialog, the cheat sheet, the palette, the floating list, Settings, then the page's own).

### 2.7 Theme

- [x] **UI-70** Built-in themes Warm, Mono, Midnight, Paper, High contrast, chosen apart for light and dark (`NookPalette.builtIn`) · M Done (2026-11-20): `lib/palette.ts` ports `NookPalette.generated`, `readable()` and the six built-in themes; Settings › Appearance › Theme shows a card per theme with a small window for dark and for light, and the main window sets the chosen palette as CSS variables (`App.svelte`); the bar stays dark.

- [x] **UI-71** VS Code theme import · M Done (2026-11-20): "Import VS Code theme…" reads a theme file (comments and trailing commas allowed) as the Mac maps it and uses it at once for its appearance; imported themes can be removed.

- [x] **UI-72** Colour per token with reset and live preview, readable-contrast fix (#1483, #1492, #1495, #1526) · L Done (2026-11-20): Custom colors fold with the Mac's 45 tokens in seven groups, per appearance, each with its ⓘ, hex, a color picker and reset, and Reset all; applied live over the theme. The Mac's small preview card inside the fold is left out: the whole window shows the change at once.

- [x] **UI-73** `.nooklook` export and import (#1609) · S Done (2026-11-20): Export look… and Import look… (accent, appearance, themes with imported ones, custom colors, diff colors, density) as a `.nooklook` file; Nook's face is not in it until Windows has face settings (UI-79). Update 2026-11-20: the file is now the Mac's own format (`nook-look`: accent, appearance, per appearance its theme and colors, imported themes as their VS Code source, diff colors, density and Nook's face), so a look moves between the Mac and Windows.

- [x] **UI-74** Colour-blind diff colours; switches for math rendering and the rich composer · S Partly done (2026-11-20): Diff colors Green & red / Blue & orange under Text and layout. Open: Render math (needs an offline math typesetter in the Markdown view) and the rich composer switch (the composer is another helper's area). Update 2026-11-20: "Render math" added (KaTeX was already bundled; the switch turns typesetting off in every Markdown view). Only the rich composer switch stays open. Done 2026-11-20: "Style Markdown as you type" (`richComposer`, on by default) under Text and layout: the shared composer draws headings, lists, quotes, **bold**, *italic*, `code`, ~~strike~~, links and fenced code in a layer under the field (`packages/web-ui/src/rich.ts`), character for character so the caret stays put; what is sent stays plain Markdown. Differs from the Mac: italic shows as a softer tint, not slanted, and bold as a shadow, because a slanted or heavier face would move the caret off its character in a textarea.

- [x] **UI-75** Density as separate type and spacing scales instead of a window zoom (radii, spacing, text styles, colors and motion durations are now checked against `NookTheme` by `src/theme/theme-tokens.test.ts`) · M Done (2026-11-20): compact and spacious scale every text style (0.93 / 1.07, to half a pixel) and the padding of rows in a card (0.75 / 1.25, `--row-pad-y`, `--row-pad-x`) instead of zooming the window.

- [ ] **UI-76** No inline colors, font sizes or radii in Svelte: bring `src/theme/ui-baseline.json` (149 files: 161 colors, 563 font sizes, 215 radii at the start) to zero by moving each to the theme's variables; `ui-lint.test.ts` already stops new ones · L Update 2026-11-23: the baseline is down to 110 files (119 colors, 394 font sizes, 178 radii): CountBadge, Tag, GitLabRow, Usage, Markdown, MarkdownImage and MarkdownTable now use the text styles and radius tokens. Still open: the remaining inline values sit in files other helpers are editing now (agents, chats, composer); the lint test keeps new ones out.
## 3. Nook Chat and the brain (BR)
  - Part done: the shell and services files (Main, LazyView, Toast, Bar, Music, the overlays Aside, Ghost, Listening, Recording badge, Screen part, HomeGlance, Onboarding) take their type, radii and colors from the theme; `ui-baseline.json` went down with them. Left: Orb (its face palette), the companion's phone look, and the views other helpers own.

### 3.1 Brain core and providers

- [x] **BR-01** Budgeted conversation window: the newest turn gets up to two thirds, shortened turns end in "…" (`Brain/ConversationWindow.swift`); Tauri sends a fixed last 12 turns (`commands/chat.rs`) → `core/src/brain/conversation_window.rs`, used by `service.rs` and `claude_code.rs` · M

- [x] **BR-02** Subscription brains through Codex, Gemini, Grok, Kimi and Mistral Vibe CLIs (`Brain/SubscriptionBrain.swift`); Tauri has only `ClaudeCode` → `core/src/brain/subscription.rs`, new `provider.rs` variants · M

- [x] **BR-03** Screen brain split: a local model reads the screen and on-device sources and writes a clean note for the external brain (`PrivateBrief`, `answerTogether`, `ScreenBrainSection`) → `core/src/brain/private_brief.rs`, Settings › Brain › Screen work · M

- [x] **BR-04** OpenRouter sign-in with PKCE instead of pasting a key (`OpenRouterSignIn`) · S

- [x] **BR-05** OCR for images sent to brains that can't see images (`ChatImage`) · S

- [x] **BR-06** Brain-written title after the first answer (`nameAfterFirstAnswer`) · S

- [x] **BR-07** Follow-up offers capped at 3 like the Mac (Tauri: 2) · S

- [x] **BR-08** Phishing and scam scoring for mail and chat messages in research context and reply suggestions (`MessageTrust`; same work as CH-39) · S

- [x] **BR-09** Nested command judging (`sh -c`, `xargs`, `find -exec`) in `command_risk.rs` with the Mac's tests · S

### 3.2 Access, plans, autonomy

- [x] **BR-10** Three access levels (ask, small, more) chosen in the composer with Shift+Tab (`NookAccess`); Tauri has one `auto_run_safe` toggle → `core/src/brain/access.rs`, `Composer.svelte` · M

- [x] **BR-11** `update_plan`: the live step checklist above an answer → `src-tauri/src/tools/plan.rs`, `MessageView.svelte` · S

- [x] **BR-12** Automation autonomy (ask, decide through a judge, auto) and the unattended-tools policy (`AppModel+Autonomy`) · M (mail drafts always wait: no mail sender yet, CH-91)

### 3.3 Nook Chat automations

- [x] **BR-15** `ScheduledTaskTarget.nook` and the tools `schedule_task`, `list_scheduled_tasks`, `update_scheduled_task`, `set_up_secretary` (`AppModel+ScheduleTools`) → `src-tauri/src/tools/schedule.rs` · L

- [x] **BR-16** Automations that start when a matching message arrives, and the quiet "nothing new" answer (4cdac90ca) · M
  - Done: the trigger, queue, scheduler path and the quiet answer, fed by WhatsApp's arrivals. Done (2026-11-22): every other chat app's new incoming messages reach `workspace::automation::messages_arrived` too, from what the shared inbox newly holds (`chats::notify::arrived`, called by the chat helper), before any notice rule, so a chat you keep quiet still starts its automation.

- [x] **BR-17** Scheduled tab in the Nook list with an amber count, the bar over a run's conversation, the "Scheduled run" marker (`NookScheduledTasks`) · M

### 3.4 Tools for Nook Chat

- [x] **BR-20** `get_settings`, `change_setting`, `open_settings` with the settings catalog (`AppModel+SettingsTools`, `SettingsCatalog`) → `src-tauri/src/tools/settings.rs`, `core/src/settings_catalog.rs` · M

- [x] **BR-21** `find_time` with buffers, time-of-day preference and weekends (`MeetingTimes`, `Availability`) · S

- [x] **BR-22** `compose_mail` with an `.ics` invitation (`CalendarInvite`); `reply_to` and `from` come with CH-91 · M

- [x] **BR-22b** Bcc on mail drafts and mail cards from a ```mail block or a quoted mail in an answer (`MailTemplate`, `lib/mail-block.ts`) · S

- [x] **BR-23** `github_merge_prs` (batch merge) · S

- [x] **BR-24** `run_command` with `CommandRisk` and the terminal beside the chat · M

- [x] **BR-25** `open_in_nook_browser`, `read_nook_browser` · S

- [x] **BR-26** `network_status` and `system_status` (the Mac's `mac_status`: battery, disk, memory) · S

- [ ] **BR-27** `list_remote_machines`, `add_remote_machine` (with AG-132) · L

- [x] **BR-28** `search_music`, `play_music` (needs SV-31 Spotify) · M Done (2026-11-23): `search_music` and `play_music` brain tools wired via `core/src/services/spotify.rs` and `src-tauri/src/commands/search.rs`.

- [ ] **BR-29** `take_over`, `wait_for_user`, `read_ui`, `control_ui`: Nook acting in apps, stopping at the point of no return (`TakeoverPolicy`, `UIControl`) on UI Automation + `SendInput` (Windows), AT-SPI (Linux) · L
  - Done: `read_ui`, `control_ui` (each batch approved in the plan), `wait_for_user`, and `list_app_menu`/`app_menu_command` on UI Automation and `SendInput` (`platform/windows/ui_control.rs`, `tools/ui_control.rs`), with the Mac's rules in `core/src/brain/ui_control.rs` and `takeover.rs` (blocked apps, password fields, card numbers, forbidden shortcuts, the checkpoint words, repeats, a fresh read after each batch); the Windows code passes `cargo check --target x86_64-pc-windows-gnu` but has not run on a real PC. Left: the `take_over` tool itself (one approval for a whole task, then a loop that asks only at the checkpoint) and AT-SPI on Linux.

- [x] **BR-30** `list_app_menu`, `app_menu_command` through a UI Automation menu walk (`AppMenu`) · M

- [x] **BR-31** `read_browser_tab` through the extension (CH-60) or UI Automation (`BrowserTabReader`) · M *(UI Automation + Win/AT-SPI `BrowserTabReader` ported; extension hook waits on CH-60)*

### 3.5 Chat UI (Nook tab)

- [x] **BR-40** Sources: cited excerpt on hover or click with highlighted lines, dot for cited and dimmed uncited sources, mail sources by sender, strip model-written "Sources:" lists (`ChatSourcesView`, aa6afaa94) · M

- [x] **BR-41** Markdown like the Mac: syntax colours, file name on a fence, wrap and run buttons, `<details>`, images on their own line, table copy as Markdown or CSV, link address on hover, HTML/SVG preview in a sandboxed frame (`MarkdownView`, `MarkdownExtras`, `CodeRender`) · M

- [ ] **BR-42** MCP apps (`ui://` resources) in a sandboxed frame (`McpAppViews`) · M
  - Open: MCP apps show in an agent session's timeline (`RunTimelineRows` → `McpAppBlock` on the Mac), which on Windows is `views/agents/run` (the agents helper's), and need the Codex app-server parser to keep `_meta.ui.resourceUri` and fetch the page (`mcpServer/resource/read`) in `core/src/workspace/codex_app_server.rs`; the Nook chat itself has no MCP app results.

- [x] **BR-43** Brain chip showing the model, opening the picker (`BrainChip`) · S

- [x] **BR-44** Queue messages while Nook answers, reorder, hold (`NookChat.enqueue/moveQueued/holdQueue`) · M

- [x] **BR-45** Conversation list like the Mac: Conversations/Scheduled header tabs, For you card, one-line settled rows, hover card, archive shelf, multi-select, mark unread (`NookConversationList`) · M
  - Done (`NookList.svelte`, `conversationSections` in `lib/conversation-list.ts`, `ConversationCard` in `core/src/nooks.rs`): "For you" card with its count and two-line rows (badge and what it did), pinned and day groups on one line with the agents' badge or the age, pin and clock marks, pin and archive on hover in the badge's place, the hover card beside the row (plan steps, mail draft, chart, sources, request, content, started, last active, messages, limited sources), the archive shelf at the foot opening upwards, a settled scheduled run left out unless pinned or searched, right-click (rename, pin, copy as Markdown, archive, delete after a yes), F2 rename in the row, and Ctrl/Shift-click to pick several with a bar (mark read/unread through `nook_set_flags`' new `unread`, pin, archive, delete).

- [ ] **BR-46** Split view: an app, Nook's browser or a terminal beside the chat with a draggable divider · M
  - Open: the split view lives in the main window's layout (`Main.svelte`, the shell helper's); nothing of it is in the Nook chat components.

- [x] **BR-47** Working indicator: elapsed timer, shimmering current step, error card with Details · S

- [x] **BR-48** Zip archives, folders and pasted paths as attachments · S

- [x] **BR-49** Plan-limits card on the empty chat (`NookGlance`) · S

- [x] **BR-50** More starter signals: GitHub reviews, failing builds, unread mail (`SmartSuggestions`) · S

### 3.6 Instructions, inspector, search

- [x] **BR-55** Saved prompts with `{{variables}}` and `/trigger`, and spaces (instructions and files per conversation) (`InstructionStores`, `PromptLibrary`, `NookSpace`) · M

- [x] **BR-56** Context inspector: each part the model reads with its token size (`ContextBreakdown`) · S

- [x] **BR-57** Search everything: agent sessions and transcripts (settled and archived too), chats, call notes, memories, notices, settings and actions, ranked (`AppModel+Search`) → `commands/search.rs`, `core/src/search.rs`, `CommandPalette.svelte`, `lib/search-everything.ts` · M
  - Done: Ctrl+K is the Mac's `SearchPanel` (the card under the header, the large field, kind chips with counts, "Top hit" and per-kind sections, rows with the matched words bold, the agent's logo, state, age, unread dot and "N matches", "Search with AI: …" and "Ask Nook: …", the start page, the key-hint footer with Ctrl, Tab through kinds, Ctrl+1–9, Ctrl+Return). It finds conversations (every message), Nook's runs, followed and earlier agent sessions with their transcripts, every chat app's chats in the shared inbox, call notes, memories, Settings pages and actions, with the Mac's whole query language ("exact words", -word, OR, in:, from:, is:, app:/agent:/project:/branch:, after:/before:/on:, /regex/). Left: notices (BR-65).

- [x] **BR-64** Search hits with the passage that matched: `search_everything` (`nook_core::search`) returns, per document, the best passage with its author, date and anchor and how many passages matched; the row shows "You: …" / "Nook: …" / a name with the words marked and the place after it, and opening a conversation scrolls to that message and marks it (`lib/chat-focus.svelte.ts`). Words, phrases, OR, -word and /regex/ are matched over every message, not only titles · M

- [x] **BR-65** Search over agent transcripts, chats, call notes, memories and notices, with `from:` and `app:` · L
  - Done: transcripts of Nook's runs (their timeline), followed sessions and the 150 newest earlier sessions; every chat app's chats in the shared inbox (`chat:<app>:<id>`; a hit opens its chat in the Chats tab through `chats.lastOpened` and a `nook-open-chat` window event for a Chats tab already on screen); call notes (summary, key points, to-dos, every line by speaker; opening one makes it a conversation, as on the Mac); memories (opening one goes to Settings › Memory); `from:` over who wrote each passage, `app:` on chats and notes. Left: notices, because Windows keeps no notice history (`NoticeHistory`; `notices.rs` keeps only the handlers of the toasts still up), and a chat's history beyond what the inbox keeps (the Mac's `ChatSearchBridge` asks each app's bridge).

- [x] **BR-66** Search with AI (the "Search with AI: …" row, first for a question, Ctrl+Return, `SearchAI`): `search_ai_plan` has the brain turn the question into up to four searches, the panel runs them with the question's own words (`keywordQuery`) through the same search, takes the hits in turns (`gather`, ten at most, no actions or settings, no memory kept local when the brain is not), and `search_ai_answer` answers from them citing [1], [2]…; the answer card shows working, reading, the answer with its citations in the accent, "Continue in chat", or "Choose brain" without a brain, and the list becomes the sources, cited ones first, numbered · M

- [x] **BR-67** Recently opened and recent searches on the search's start page (`SearchCenter.recentlyOpened`, `recent`), and the session find bar opening on the matched words · S Partly done (2026-11-20): start page recently opened (with live refresh, unread dot and status badge), recent searches, filter chips and AI answer Markdown/citations match Mac; opening the session find bar on the matched words still open.
  - Done: recently opened (five, newest first; what you open often ranks higher, fading over a month) and recent searches (eight, with Clear), kept in localStorage as the Mac keeps them in UserDefaults. Left: a session opening with its find bar on the matched words, which needs the Agents tab's session find bar (`views/agents`, AG-06's `TimelineSearch`); the hit already carries the passage's anchor for it.
  - Done 2026-11-21: a run that matched in its transcript opens with its find bar on the first words that matched (`lib/session-find.svelte.ts`, set by `CommandPalette` and taken once by `views/agents/run/Timeline.svelte`, which opens the bar, fills it and jumps to the first match). As on the Mac only Nook's own runs have a find bar; earlier and followed sessions open on their page.

### 3.7 Suggestions and selection

- [x] **BR-60** Suggested steps from chats, agent sessions and Nook Chat with a "Do it" bar, own setting and model (`AppModel+ActionSuggestions`, bd2f11059; shared with CH-62 and AG-71) · M
  - Done for Nook Chat: `service::propose` (action tools become steps, never run), the rules and prompt of `ChatActionSuggestion` (`core/src/brain/action_suggestion.rs`: new lines only, worth a look, complete steps, never re-offered, pace and an hourly cap, 30 s), `suggest_actions` / `run_suggested_actions` (`commands/suggestions.rs`), the bar above Nook Chat's field (`ActionSuggestionBar.svelte`, `lib/action-suggestions.svelte.ts`: dashed line, Do it, the cross, how it went), and Settings › Autocomplete › "Suggest actions from conversations" with "Model for suggestions" (a model name of the brain's service; empty is the brain's own). Open: the same bar in a chat of the Chats tab (`views/chats`, the chats helper's) and an agent session (`views/agents`), which only need to pass their place and lines; "Adjust first" for a suggested session (opens the new-session composer, `views/agents`); choosing a model of another service than the brain's.
  - 2026-11-21: the bar is now the Mac's `WhisperSuggestion` and `DraftActions` 1:1: the line on a dashed outline that turns solid on hover with the sparkles tinting, the ghost buttons ("Adjust first" for a single new session, Do it with its check), the card after Do it with the sparkles badge, title and why, each step's badge by kind (bell, calendar, mail, note, send) and the run's state ("Running…", the result in mint, a failure in coral). "Adjust first" opens the new-session composer on the step's project with the task in its box (through the composer's own draft per folder). The bar is in Nook Chat, a chat of the Chats tab (`ChatDetail.svelte`) and an agent session (`RunPanel.svelte`); from a chat, "Adjust first" reaches the Agents tab through the navigate event. Left: the model for suggestions is a model name of the brain's own service; the Mac's `TextGeneratorRow` can pick a model of another service (an API or a local model) too.

- [ ] **BR-61** One-click suggestions under the quick field (`DoubleTapSuggest`) · S
  - Done: the chips and the line above the field (`core/src/services/double_tap_suggest.rs`, with the Mac's words in five languages). Left: showing them, which needs the quick field itself (SV-45); tick this item with it.

- [x] **BR-62** Selection Ask complete: the bar in the small windows, a drag across messages as context, the hidden note that the quote is material, Quote into an agent's reply box · M (mounted across Main, Bar and detached `#tab` windows; supports Nook Chat and Chats tab message context, hidden note, and Quote into an agent session's composer)
  - Done: the hidden note that the quote is material (`selection_ask.rs`), and a selection in a Nook conversation goes with the 20 messages before it and 3 after it as context (`contextRange`, `chatNote`; `ask_about_selection`'s new `context`). Open: the same context for a selection in a chat of the Chats tab (its rows need a message id, `views/chats`), the bar in the small windows (the bar and tab windows do not mount `SelectionAsk`), and Quote into an agent's reply box (`views/agents`).

- [x] **BR-63** Import MCP memory · S

- [x] **BR-64** A terminal starts its shell at the width it has on screen, not a fixed size: `openpty` in `src-tauri/src/workspace/terminals.rs` now waits up to 500 ms for the fitted screen size from `TerminalView.svelte` (`resize`) before spawning the shell, remembers `last_shown_size` for background terminals, and ignores tiny pre-layout dimensions (`TerminalSession.shown`, unit-tested with `stty size`) · S

## 4. Coding agents and the workspace (AG)

### 4.1 MCP bridge (`nook --mcp`)

The Mac's bridge has 48 tools (`apps/macos/Services/Workspace/WorkspaceBridgeProtocol.swift`); Tauri's
(`core/src/workspace/bridge.rs`, `bridge_nook.rs`) has 14: `workspace_info`, `terminal_run/read/list/stop`,
`browser_open`, `browser_read`, `pull_request_create`, `session_list`, `session_read`, `nook_tools`, `nook_use`,
`nook_chat_list/read/send`, `chat_list/read/send`, `take_over_screen` (read-only).

- [x] **AG-01** `browser_screenshot`: offered in `tools/list`; WebView2 through the DevTools protocol (`Page.captureScreenshot`), WebKitGTK `get_snapshot`, WKWebView `takeSnapshot` (`src-tauri/src/workspace/snapshot.rs`) · M

- [x] **AG-02** `browser_snapshot`, `browser_click`, `browser_type`, `browser_wait_for` on `src-tauri/src/workspace/browser.rs` (DOM refs, click and type through JS; scripts in `core/src/workspace/browser_script.rs`; no Stop overlay on the page yet) · M

- [ ] **AG-03** `in: "user"` on `browser_*` (`BridgeUserBrowser`): drive the user's own Chrome/Edge through the browser extension (needs CH-60) · L

- [x] **AG-04** `orchestrator_capabilities`, `delegate_task`, `task_status`, `task_wait`, `task_cancel` on top of `core/src/workspace/delegation.rs` (a task's question is not yet passed to its parent; the sub-thread strip is AG-100…) · M

- [x] **AG-05** `session_start` (1–20 sessions, with `account` and `rights` per session), `session_send`, `session_wait` · M
  - Done 2026-11-22: `account` (id or label among the agent's accounts) and `rights` (ask, acceptEdits, bypass; never above the caller's, only what the agent offers) per session or as the call's default, checked before the approval card, which names them ("· Account Work · Allow edits") (`bridge_sessions::start_rights`, `start_account`). Left: starting idle without a first message (the manager always sends the task) and `nook://` session links.

- [x] **AG-06** `session_search` (`TimelineSearch`), `session_organize` (pin, settle, rename), `session_questions` · M

- [x] **AG-07** `session_suggest` and the suggested-session card in the timeline · M
  - Done 2026-11-22: the bridge tool (no approval: only a card in the caller's own timeline, refused for sessions Nook does not run) and the card (`SuggestionCard.svelte`): "New session", title, agent and place with the summary, Options (the new-session composer with the prompt), Do it here (sent as your next message), Start (a session beside this one, Ask rights) and ×; afterwards one line with Open. Every agent that uses Nook's bridge gets it. Rules in `core/src/workspace/session_cards.rs`.

- [x] **AG-08** `render_page` (`RenderedPage`, `McpApps`, `McpUI`): a sandboxed page in the timeline · M
  - Done 2026-11-22: `render_page` with html or an .html file inside the working directory (≤512 KB, height 80–1200, default 360), kept under ~/.nook/pages per session (24 at most), shown by `PageCard.svelte` as a work line that folds it and an iframe with `sandbox="allow-scripts"` (no same origin, forms, popups or navigation) behind a content policy without network (`session_cards::sandboxed`); cards stay out of a finished turn's fold. Left: the Mac's full-size and side-panel buttons and shrinking to a shorter page (the frame cannot be measured without same origin), and embedding a file's local assets. MCP apps (`ui://`) are BR-42.

- [x] **AG-09** `schedule_task`, `list_scheduled_tasks`, `update_scheduled_task`, `run_scheduled_task_now` (wrap `scheduler.rs`; always ask) · S

- [x] **AG-10** `watch_pull_request`, `get_pull_request_status` (wrap `connectors/pulls.rs`) · S

- [x] **AG-11** `request_secret` (`SecretFiles`): ACL-restricted file on Windows plus the secret field on the approval card · M

- [x] **AG-12** `device_list/open/screenshot/close` for Android emulators and devices through `adb` (`AndroidDevices.swift`); the iOS Simulator part is Mac-only · M Done (2026-11-23): `device_list`, `device_open`, `device_screenshot`, and `device_close` implemented for Android emulators/devices via `adb` in `core/src/workspace/bridge.rs` and `src-tauri/src/workspace/bridge.rs`.

- [ ] **AG-13** `take_over_screen` acting for agents: click and type through `SendInput` (Windows), XTest/portal (Linux) · L

### 4.2 Agents and transports

- [ ] **AG-20** Pi agent (`AgentKind.pi`, `PiRPC`, `WorkspaceManager+Pi`, `PiRPCTurnDriver`): `pi --mode rpc` driver in `core/src/workspace/driver.rs` · L

- [ ] **AG-21** Own ACP agents (`CustomAgents`, `AcpAgentsSettings`, `AcpInstaller`): profile store, adapter install, Settings › Agents page · M

- [ ] **AG-22** OpenCode through `opencode serve` (`OpenCodeServerHost`, `OpenCodeServerTurnDriver`) instead of ACP only · M

- [x] **AG-23** Antigravity installer (`AntigravityInstaller`): pin a Windows/Linux build once one exists, or document why not · S
  - Done: Google publishes the same pinned 1.3.0 release for Windows (x64, arm64) and Linux (x64, arm64) as for macOS; `core/src/workspace/antigravity_install.rs` pins all six (size and SHA-256 per archive, the two members and their sizes), downloads with progress, checks before unpacking, unpacks exactly the two files, test-starts the server (`initialize` must answer as `antigravity-acp` with Google sign-in) and only then makes it active; the new-session screen shows the Mac's setup line with Install and progress when Antigravity is picked (`AntigravitySetup.svelte`). The Windows x64 archive was checked against the pin (`unpacks_a_real_release_when_given`).

- [x] **AG-24** `ProviderCapabilities`: speed tiers, live model/effort change during a turn, Ultracode, `forksNatively` in `core/src/workspace/models.rs` · M
  - Done: `ProviderCapabilities` has `can_fork_from_turn`, `live_settings`, `deny_reason_in_response`, `speed_tiers`, `ultracode` and `echoes_steers` with the Mac's values per agent; the deny reason and steer receipts are built on them, and the session's model picker stays open while an agent works. The speed-tier and Ultracode controls themselves come with the drivers that pass them on (not yet on Windows).

- [x] **AG-25** Model catalog and picker (`AgentModelCatalog`, `AgentModelMenu`, `ModelManifest`, `model-manifest.json`): replace the free-text model field in `RunComposer.svelte` · M
  - Done: both composers have the Mac's agent pill and picker (`AgentModelPicker.svelte`): a rail of agents and accounts, the shown agent's models from the Mac's own `model-manifest.json` (`core/src/workspace/model_manifest.rs`, read at build time, aliases and New badges included), a search that also takes any model name the agent accepts, and the mode, effort and access in its footer.

- [ ] **AG-26** Auto model (`AutoModel`, `WorkspaceManager+AutoModel`): picks agent, account and model per turn · L

- [x] **AG-27** Accounts for Gemini (`GEMINI_CLI_HOME`) and the other agents in `profiles.rs` (now Claude and Codex only) · S Done (2026-11-23): `core/src/agents/profiles.rs` supports multi-account profiles and discovery across Gemini (`GEMINI_CLI_HOME`), Claude, Codex, Antigravity, OpenCode, Cursor, and Grok.

- [x] **AG-28** Agent updates (`AgentUpdater`, `AgentUpdates`, `AgentUpdatesSection`, `AppModel+AgentUpdates`): Settings › Agents › Updates · M Done (2026-11-23): `core/src/agents/updates.rs`, `src-tauri/src/agents/updates.rs` (`agents_updates`, `agents_update`) and `views/agents/AgentUpdates.svelte` check each agent's installed and newest version (npm registry / GitHub release, cached for an hour), detect how it was installed from the executable path (npm, pnpm, yarn, Bun, WinGet, Scoop, Cargo, uv, pipx, native installer), and update it in place.

- [x] **AG-29** "Agent too old for this model" with an update offer (`AgentVersionRejection`) · S Done (2026-11-23): `version_rejected` in `core/src/agents/updates.rs` and `lib/workspace/agent-updates.ts` detects when an API refuses a turn because the CLI is too old for the chosen model, and the failed turn card in `views/agents/run/Timeline.svelte` offers one-click `Update {agent}` and retries the turn.

- [x] **AG-30** Sign-in after an expired login (`AgentSignInFailure`) · M Done (2026-11-23): `needs_sign_in` in `core/src/workspace/recovery.rs` and `lib/workspace/agent-updates.ts` detects expired or missing authentication across agents, and the failed turn card in `views/agents/run/Timeline.svelte` offers `Log in again` to run the profile's sign-in command in Nook's terminal.

- [ ] **AG-31** MCP connectors waiting for sign-in above the composer (`ConnectorSignIn`, `WorkspaceManager+ConnectorSignIn`) · M

- [x] **AG-32** Readiness and token advice (`AgentReadiness`, `AgentAdvice`, `TokenSavings`, `AgentTuning`, `TokenSettingsSection`) · M — ported `readiness.rs`, `advice.rs`, `token_savings.rs`, and `tuning.rs` in `nook-core`, wired prompt-cache tracking, idle/size/return compaction, `AutoCompactMark`, `ClaudeToolSearch`, and `AppliedTuning` into `Manager`/`CommandInput`, added Tauri commands (`workspace_tuning_scan`, `workspace_tuning_set`, `workspace_readiness`, `workspace_limit_advice`, `workspace_offers_compact_first`), and added `TokenSettingsSection.svelte` under Settings › Coding agents › Usage & costs.

- [x] **AG-33** OpenTelemetry environment passed to agents Nook starts (`AgentTelemetry`; the exporter is SV-05) · S
  - Done (2026-11-21): every coding agent Nook starts gets the receiver from Settings › System › Maintenance (or `OTEL_EXPORTER_OTLP_*` in Nook's environment) at its next start: the standard `OTEL_EXPORTER_OTLP_*` variables for all, plus Claude Code's `CLAUDE_CODE_ENABLE_TELEMETRY`, Codex's `-c otel.*` overrides, Gemini's `GEMINI_TELEMETRY_*` and Grok's `GROK_EXTERNAL_OTEL` (`workspace::command::apply_telemetry`, wired in `Manager`); with no endpoint nothing is passed, as on the Mac.

- [x] **AG-34** Images in prompts for Claude and ACP agents · M
  - Done: pictures you add or paste end the message as paths on lines of their own (Claude Code, Codex and the rest read them from there, as on the Mac); an ACP agent also gets each one as an `image` block (base64, up to 8 MB, PNG/JPEG/GIF/WebP) when its `initialize` says it takes images, else as a `resource_link` (`acp::attachments`, `picture_paths`).

### 4.3 Hub, approvals and usage

- [x] **AG-40** "Started by an agent in …" (`SpawnedSessions`): parent-process lineage in `core/src/agents/hub.rs` · S
  - Done (2026-11-23): sessions started through the bridge or from Nook Chat open with a "Started by …" origin line (`Manager::note_origin`), and `core/src/agents/hub.rs` now walks the parent process tree (`parent_pids`) to link a terminal agent session to the session whose shell spawned it (`launched_by`), shown as a clickable "Started by an agent in {title}" link in `views/agents/LiveDetail.svelte`.

- [x] **AG-41** "Compacting the conversation…" from PreCompact hooks (`HookCompaction`) · S

- [x] **AG-42** Audit log for hook approvals (`ApprovalAudit`) · S

- [x] **AG-43** Why the agent asks, and the "Always allow X · this project" scope in `ApprovalCard.svelte` · S
  - Done: the approval card shows why it asks (the risk note) and, under its buttons, what "Always" would allow and how far it reaches, "Always allows Bash(git status:*) · this project" (`core/src/agents/permission_scope.rs`, from Claude Code's `permission_suggestions`; Codex and the ACP agents say only "session" or "always"), for hook and Nook-run requests alike; Always explains itself on hover.

- [x] **AG-44** Deny with a reason on desktop (exists only in the companion) · S
  - Done: Deny with reason on the approval card (`ApprovalCard.svelte`, Return denies, Escape closes) and from the phone (`CompanionBackend::decide_with_reason`). Claude Code gets the reason as the denial message (hooks and stream-json); agents on a driver (Codex, ACP) have no field for it, so it reaches them as a steer, or first in the queue (`Manager::decide_with_reason`). A bridge request has no agent behind it and takes a plain Deny.

- [x] **AG-45** Granted rules per project with revoke (`GrantedRules`) · M

- [x] **AG-46** Option previews and your own answer with files in `QuestionCard.svelte` · S
  - Done: each option shows its preview in the code font under it (Claude Code's `preview`, fences and trailing spaces taken off, cut at 4,000 characters; `read_preview`), and "Or type your own answer…" sends your words with files and pictures attached, pasted or dropped (the same tiles and envelope as the composer).

- [x] **AG-47** Active usage polling and reset credits (`ClaudeUsage`, `CodexUsage`, `CodexRateLimits`, `QuotaService`) in `core/src/agents/usage.rs` · M

- [x] **AG-48** Antigravity quota and CLIProxyAPI hubs (`AntigravityUsage`, `CLIProxyUsage`, `CLIProxyHub`) · M
  - Done: Antigravity quota and CLIProxyAPI hub store, no-redirect `/v0/management/auth-files` polling, secret-store management keys, and settled windows (`core/src/agents/usage.rs`, `src-tauri/src/agents/usage.rs`), with editable hub management in Settings › Coding agents › Usage & costs (`CliProxyHubs.svelte`, `AgentsUsage.svelte`) and read-only hub display in the Usage modal Limits tab (`UsageModal.svelte`).

- [x] **AG-49** Usage modal like the Mac (`LimitPool`, `UsageLedger`, `PriceTable`, `UsageLimitCard`: pooling by plan, cost and token tabs, costliest chats, agent filter, Manage usage) · M

- [x] **AG-50** CPU/resource badge per session (`ResourceUsage`, `ProcessTree`) · S
  - Done: the session header shows "34 % · 512 MB" for the agent's process tree while it works, read every three seconds, amber past three cores (`core/src/workspace/resources.rs`, `workspace_resources`).

- [x] **AG-51** Reply to an agent from a Windows toast · S
  - Done: the "done / stopped with an error" toast of a session Nook runs has a reply field; what you type goes to the session as your next message, or into its queue while it works (`Toast::agent_status`, `present_attention`). A terminal session's toast has none: Nook cannot type into a terminal.

### 4.4 Session lifecycle

- [x] **AG-60** `/clear`: a fresh conversation in the same session with a divider (`+FreshConversation`) · S
  - Done: `/clear` in the session composer arms the next message (the strip "Your next message starts a new conversation" with Keep this conversation); that message clears first (`Manager::clear_conversation`, `workspace_clear`): no session to resume and no pending handoff for any agent, handoff cursors forgotten, a "New conversation" divider in the timeline. Not while the agent works: Nook says so instead of queuing the message marked fresh as the Mac does.

- [x] **AG-61** `/btw` and `/side` side chats (`+SideChat`, `SideChatStrip`) · M

- [x] **AG-62** Roll back the conversation, not only files ("Edit from here", Codex `thread/rollback`, `ConversationRollback`) · M (`core/src/workspace/rollback.rs`, Codex `thread/rollback` + `thread/revert` fallback, Claude `--resume-session-at` + `--fork-session`, "Edit from here" with "Keep file changes" / "Revert files too", dimmed rolled-back events)

- [x] **AG-63** Fork from an earlier turn · M
  - Done: Fork in the session's menu, `/fork` in the composer, and a fork button under each of your messages ("Fork before this message") and under each answer ("Fork from this response") (`Manager::fork`, `workspace_fork`). The fork works in the same folder and never owns a worktree. Claude Code copies its own conversation (`--fork-session`) when the whole session is forked; a fork from an earlier point, and every other agent, starts from a summary of the timeline up to there. Not yet: an ACP agent's own `session/fork`.

- [x] **AG-64** Restart agent (end the process, resume the conversation) (`+Restart`) · S
  - Done by design: on Windows every turn starts the agent's process anew and resumes the conversation (`--resume`, `thread/resume`, `session/load`), and the process ends with the turn. So skills, plugins and MCP servers added since are picked up by the next message already; there is no process between turns to restart, and no menu item for it.

- [x] **AG-65** Size and idle `/compact`, the "auto-compact at" line, amber warning, live compaction state (`+Compaction`, `+IdleCompaction`, `CompactionProgress`) · M

- [x] **AG-66** Context breakdown per part instead of only a `ctx %` pill (`+ContextUsage`) · M

- [x] **AG-67** `/goal` strip (`+Goals`, `SessionGoal`) · S

- [x] **AG-68** `/` command list in the composer (`AgentCommands`, `available_commands_update`) · S
  - Done: typing `/` in the session composer lists Nook's own commands (plan, clear), Claude Code's and Codex's built-in compact and goal, and what an ACP agent announces in `available_commands_update` (kept per session, `workspace_agent_commands`); ↑/↓, Return or Tab picks. fork, btw and side follow with AG-61 and AG-63.

- [x] **AG-69** Steer receipts ("waiting to be read / not read") · S
  - Done: a steered message is marked "Steer"; for an agent that echoes it (Codex app-server `userMessage`, `echoes_steers`) it reads "Steer · waiting to be read" until the agent takes it in, and "Steer · not read" when the turn ended first.

- [x] **AG-70** Suggested next prompt as ghost text, and choosing who writes titles, commits and PR text; title rules, Regenerate title (`+NextPrompt`, `TextGenerators`, `TextGeneration`, `TextGenerationSettings`) · M Done (2026-11-23): suggested next prompt ghost text (`Tab` accept / `Esc` dismiss) in `RunComposer.svelte`, Regenerate title & title rules, and text generator pickers in `AgentsWorkspace.svelte` (per-kind CLI/API Test stays tracked in SV-65).

- [x] **AG-71** Session suggestions and suggested steps (`SessionSuggestion`, `AppModel+SessionSuggestion`, #1683) · M Done (2026-11-27): suggested-session cards (`core/src/workspace/session_cards.rs`, `src-tauri/src/workspace/bridge/cards.rs`, `src-tauri/src/commands/session_cards.rs`, `lib/workspace/session-cards.ts`, `views/agents/run/SuggestionCard.svelte` with folder/run defaults, worktree base-branch resolution, Open toast, and error reporting) and suggested steps (`core/src/brain/action_suggestion.rs`, `src-tauri/src/commands/suggestions.rs`, `lib/action-suggestions.svelte.ts`, `components/ActionSuggestionBar.svelte` mounted across Nook Chat, Chats, RunPanel, and LiveDetail with Settings › Typing toggle and model picker).

- [ ] **AG-72** Main thread mode and sub-threads (`SubThreadLineage`, `SubThreadBeside`) · L

- [x] **AG-73** Subagents and background commands in the timeline and panel; wake turns joined (`BackgroundCommandActivity`, `AgentProgress`, #1610, #1611, #1428, #1680) · M Done (2026-11-23): subagents and background commands grouped in `lib/workspace/timeline.ts`, `EventRow.svelte`, and `SessionSidePanel.svelte` with wake turns joined.

- [x] **AG-74** Editable plan checklist and the Tasks strip with the current phase (`PlanChecklist`, `AgentWorkStrips`) · M Done (2026-11-23): `core/src/workspace/tasks.rs` parses Claude Code's `TodoWrite` (and Cursor/OpenCode/Gemini todo tools), Codex's `turn/plan/updated` and ACP `plan` updates into `RunTaskStep`s shown in `components/TaskChecklist.svelte` with the current phase; `views/agents/run/PlanCard.svelte` and `lib/workspace/plan-checklist.ts` let you toggle individual steps before carrying out a plan (or carry it out in a new forked session).

- [x] **AG-75** Cap on sessions working at once (`+Capacity`, `SessionCapacity`) · S

- [x] **AG-76** Build slots and priority (`AgentGovernor`, #1480, #1403): Job Objects on Windows, `nice` on Linux · M

- [ ] **AG-77** Keep sessions running while Nook is closed (`SessionKeeper`, `KeptRuns`, `KeptTransport`, `KeptSessionsSettings`), reusing `companion/background.rs` · L

- [x] **AG-78** Wait on quit and resume on next launch; pending questions survive a restart (`QuitShutdown`) · S Done (2026-11-23): `core/src/workspace/restart.rs` waits for running agent turns to exit cleanly on quit (interrupt, grace period, then shared deadline), persists pending questions across a restart (`restored` questions send the answer as a message), and resumes sessions interrupted by quitting on the next launch when enabled (`workspace_continue_interrupted`).

- [x] **AG-79** Fresh conversation after a lost or overfull context (`+VersionRejection`, `FailureClassifier`) · S Done (2026-11-23): `core/src/workspace/recovery.rs` (`FreshConversation::classify`) detects lost sessions and overfull context windows across agents, and `Manager::recover_conversation` in `core/src/workspace/manager.rs` automatically starts a fresh conversation seeded with a summary of the timeline and replays the turn once.

- [x] **AG-80** Resume at limit reset with the account choice, and snooze until reset · S Done (2026-11-23): resume at limit reset with account selection and snooze-until-reset wired in `commands/workspace.rs`, `AgentsTab.svelte`, and `RunPanel.svelte`.

- [ ] **AG-81** Read-only guest link for a session (`GuestShares`, `GuestLink`) · M

- [x] **AG-82** Session export (`SessionExport`) · S
  - Done: Copy as Markdown and Export… in the session's menu (`lib/workspace/session-export.ts`, the Mac's format: messages whole, the work folded per step list, no thinking; `workspace_save_markdown` writes only .md files).

- [x] **AG-83** Search across sessions and the archive (`TimelineSearch`, #1498) · M
  - Done: the search field of the Agents list also finds sessions by what was said in them (`Manager::search`, user and agent messages, archived sessions too); sessions outside the list show under "Also found" with the words around the match.

### 4.5 Composer and new session

- [x] **AG-90** Chips and attachments in `RunComposer.svelte`: files, folders, pictures, drop, paste, `@` file/session/PR/skill/model (`ComposerChips`) · L
  - Done: both composers carry files, folders and pictures as tiles above the text (from "+", dropped on the window, or a pasted picture saved as a file), and lists while you type `@` (a file of the project or another session), `#` (a pull request) and `$` (a skill the agent reads). The agent gets the Mac's markers and one `<nook_context>` envelope (`lib/workspace/context-refs.ts`); your message in the timeline shows the attached paths as tiles. Not yet: `@` models.

- [ ] **AG-91** Dictation, autocomplete (#1522) and inline model names in the session composer · M

- [x] **AG-92** A new-session draft per folder (`ComposerDraftStore`) · S
  - Done: the new-session task is kept per folder (and for "no project") and comes back when you return to that folder, also after closing the window; starting the session clears it.

- [x] **AG-93** Prompt library, skill index, Explain/Fix from the side panel (`PromptLibrary`, `SkillIndex`, `SessionPrompts`, `ComposerInbox`) · M
  - Done: the prompt library (`core/src/workspace/prompts.rs`, `prompts.json`, the Mac's `SavedPrompt` rules: `{{variables}}` with defaults asked in a strip, one trigger per prompt): "+" in both composers saves what you typed as a prompt and lists your prompts, and a prompt's `/trigger` is in the `/` list; beside a session, the side panel's pull request offers Explain, Ask and Fix failing checks, which land above what you wrote in that session's composer (`session-prompts.ts`, `composer-inbox.svelte.ts`). Skills come with the `$` list (AG-90).
  - Part done: saved prompts live in Settings › Instructions (`core/src/prompt_library.rs`, as on the Mac, which uses them nowhere else). The skill index: `$` in a session composer lists the skills on disk that the session's agent reads, project before user, each agent's own folders (`core/src/workspace/skills.rs`, `workspace_skills`, front matter only, 64 KB at most). Open: Explain/Fix from the side panel (`SessionPrompts`, `ComposerInbox`), which needs the side panel (AG-100).

- [x] **AG-94** Worktree setup checklist and progress, blocking setup scripts, 5 s base-fetch cap (`WorktreeSetupChecklist`, `WorktreeSetupProgress`, #1518) · M

- [x] **AG-95** Sessions without a project, "Turn into project" (`ScratchProjects`) · S
  - Done: "or start without a project" under the new-session question ("What should we work on?" / "No project ⌄" to pick a project again); `workspace_start` with no folder makes ~/.nook/scratch/<day>-<task>-<id> (`core/src/workspace/scratch.rs`) and keeps it out of Recent; the list shows "No project" with the dashed mark; the session's menu has Turn into project (`workspace_keep_scratch`, a favorite) and Make it a git repository (`workspace_init_git`, the sessions there get the repository).

- [x] **AG-96** Picker shortcuts (effort, access), send-and-… shortcut, `OpenSessionActions` · S
  - Done: Ctrl+Shift+M (and E) opens the composer's model picker, Ctrl+Shift+A its access panel, Ctrl+Shift+S settles and Ctrl+Shift+P pins the open session, F2 renames it, Ctrl+Shift+C copies where it works, Ctrl+Alt+Return starts a new session and stays on the new-session screen (the Mac's `Keybindings` with Ctrl for ⌘). Since then: Ctrl+O opens the session's folder in the editor chosen in Settings › Editor & browser (`open_in.rs`: VS Code, Cursor, Windsurf, Zed, IntelliJ IDEA, Sublime Text when on the PATH, else Explorer), also as Open in editor in the session's menu.

### 4.6 Side panel per session

- [ ] **AG-100** One right panel per session with Changes, Terminal, Browser, PR, Files, Outputs, Subagents tabs, and one browser per session (`SessionToolPanel`, `SessionTools`, `SidePanelTabOrder`) · L Partly done (2026-11-20): per-session `SessionSidePanel` with all 7 tabs (Plans/Outputs, Subagents, Terminal, Browser, Changes, PR, File), resizable hairline, tab strip with hover close and pinning, maximize, and empty-state launcher. Open: dedicated browser instance per session.

- [x] **AG-101** View, edit and save files; Mermaid; file links (`FileViewing`, `FileLinks`) · M Done (2026-11-23): `core/src/workspace/file_view.rs`, `src-tauri/src/commands/file_view.rs` (`workspace_file_read`, `workspace_file_save`), `views/agents/run/FileViewer.svelte` and `lib/workspace/file-links.ts` open files in Nook with line numbers, syntax highlighting, Markdown document view, Mermaid diagram view, in-place editing with `Ctrl+S` and disk-conflict detection, line remarks into the composer, and clickable `path:line` links from the timeline.

- [x] **AG-102** Outputs: documents and videos the agent handed over (`SessionOutputs`, `ArtifactHistory`) · M Done (2026-11-23): `views/agents/run/OutputsPanel.svelte`, `lib/workspace/session-outputs.ts` and `lib/workspace/artifact-history.ts` collect the session's task list, plans, designs, documents, PDFs, images and videos into the Outputs tab, auto-open fresh outputs made during a turn, track previous versions of edited plans/files, and offer Open and Show in folder.

- [x] **AG-103** Review comments on a diff line into the composer; stage or discard a hunk (`ReviewComments`, `HunkPatch`) · M Done (2026-11-23): `core/src/workspace/hunk.rs` (`workspace_apply_hunk`) parses unified diff hunks and builds single-hunk patches to stage (`git apply --cached --unidiff-zero`) or discard (`git apply --reverse --unidiff-zero`) a hunk from `views/agents/run/Changes.svelte` and `views/agents/UnifiedDiffView.svelte`, while `lib/workspace/review-comments.svelte.ts` collects inline diff review comments and sends them to the agent.

- [ ] **AG-104** Linked pull requests, branch tray, PR badges and hover cards in rows (`LinkedPullRequests`, `RunBranchTray`, `PullRequestSync`) · M

- [x] **AG-135** Forge rate-limit budget with AG-104: read `X-RateLimit-*` from every answer, slow background reads as a limit runs low and stop them under the last 10%, answer requests to a used-up limit locally until the reset, and read pull request status through GraphQL once REST runs low (`ForgeRateBudget`, `ForgeRateGate`, `GitHubPullRequestSnapshotQuery`) · S

- [x] **AG-105** Browser element snippets into the composer (#1570) · S Done (2026-11-23): interactive browser element picker (`src-tauri/src/workspace/browser.rs`, `views/workspace/Browser.svelte`) inserts picked element snippets into the composer.

- [x] **AG-106** Point at a spot in a PDF beside a session: crosshair, mark, snippet with page and distance from every edge, and a picture of the area into the composer (`PdfPointPicker`, `PdfPointCapture`, `PdfPointView`) · S

### 4.7 Agents list

- [x] **AG-110** Auto-settle rules, settle on PR merge (`AutoSettlePolicy`, `AutoSettleRulesRows`, #1621) · M Done (2026-11-23): `lib/auto-settle.ts`, `AgentsWorkspace.svelte`, and `AgentsTab.svelte` evaluate inactivity, PR merge/close, and keep-open-PR auto-settle rules.

- [x] **AG-111** Settle actions: stop dev servers, run a command, close idle terminals (`SettleActions`, `AppModel+SettleActions`) · S Done (2026-11-23): `lib/auto-settle.ts`, `AgentsWorkspace.svelte`, and `commands/workspace.rs` run settle actions (stop dev servers, run command, close idle terminals).

- [x] **AG-112** Bulk delete, custom snooze, dropping files onto a row · S

- [x] **AG-113** Project favicon, multi-project label (#1549), changed-line counts, project menus, add project source (#1482) · M
  - Part done: changed-line counts on rows ("+120 −8", from git after every turn: `WorkspaceRun.lines_added`/`lines_removed`; for terminal sessions from the hub), the project's initials badge, Add project in the list's head. Open: favicons, multi-project label, the row's Project menu. Since then: the project's own icon (favicon, linked icon, monorepo web app, AppIcon picture; `core/src/workspace/favicon.rs`, `workspace_favicon`). Still open: the multi-project label (sessions here have one project) and the row's Project menu. And the row's Project menu on right-click (New session in it, favorite, Show in Explorer, Copy path, Select…), the project's own name from Settings › Projects in the rows and the new-session menu, archived projects left out of it, and the project's own values for a new session ahead of your last choices there.

- [x] **AG-114** One notice per finished turn with logo and gist (`AgentStatusNotice`); `AgentAlerts.svelte` covers part · S
  - Done: the bar's card is the Mac's `AgentStatusNotice`: the agent's logo with "Claude Code is done" and the folder, what the session is about as the title and the gist of the reply under it, the changed lines; the system notification has the same headline and gist, with a reply field for sessions Nook runs (AG-51).

### 4.8 Git and source control

- [x] **AG-120** Auto-pull, publish, project archive, Settings › Source control (`SourceControl`, `SourceControlSettings`) · M Done (2026-11-27): added `core/src/workspace/source_control_rules.rs` (`AutoPull`, `CloneLayout`, `RepositoryPublish`, `CommitReference`, `store_project_icon`, `Git::auto_pull`, `Git::clone_with_layout`, `Git::prepare_publish`, `Git::publish`, `create_github_repository`), background auto-pull loop in `src-tauri/src/workspace/mod.rs`, host-layout & SSH→HTTPS clone fallback in `clones.rs`, `workspace_publish_plan` / `workspace_publish_repository` / `workspace_project_icon_save` commands, per-project source control controls (`autoPull`, `submodules`, `agentsOff`, `icon`, Publish to GitHub) in `Projects.svelte`, and `PublishRepositoryModal.svelte`.

- [x] **AG-121** Worktree cleanup with report, archive, move, build leftovers (#1616), disk usage warning (`WorktreeCleanup`, `WorktreeCleanupReportView`, `WorktreeArchive`, `WorktreeMove`, `BuildLeftovers`) · M Done (2026-11-23): `core/src/workspace/pr_checkout.rs`, `commands/workspace_tools.rs`, and `views/settings/Worktrees.svelte` add cleanup report, `.scratch` archive, worktree move detection, build leftovers sweep, and low-disk warning.

- [x] **AG-122** Commit style, removing agent credits from commits, PR body check against the template (`CommitStyle`, `PullRequestBodyCheck`, #1561) · S Done: added `core/src/workspace/commit_style.rs` (`CommitStyle`, `strip_agent_credits`, `launch_instructions`, `pr_body_problems`, `pr_body_refusal`, `find_pr_template`), persisted settings on `WorkspaceSettings`, wired template validation and credit stripping into `pull_request_create`, `workspace_start`, and `workspace_commit_all`, and added the Settings › Pull requests controls.

- [x] **AG-123** Skip approval for a PR the user asked for (#1602), PR news as a new turn (#1601), PR mentions · S Done (2026-11-26): `pr_links` (`asked_in_events`, `mentions_in_command`, `mentions_in_message`, `mentions_in_events`) in `nook-core`, skip-approval wired into `pull_request_create`, `tool: "prwatch"` emitted on PR watch news in `bridge/pulls.rs` with `lastTurn` turn-splitting tests, and session PR mentions group in `PullRequests.svelte`.

- [ ] **AG-124** Other forges for session PRs: GitLab, Gitea, Bitbucket, Azure DevOps (`ForgeSettings`) · L

- [x] **AG-125** "Work on this PR" (`AppModel+PullRequestCheckout`) in `PullRequestView.svelte` · S Done (2026-11-23): "Work on this PR" checkout in a new worktree or local clone wired in `core/src/workspace/pr_checkout.rs`, `commands/workspace_tools.rs`, and `views/agents/pulls/PullRequestView.svelte`.

### 4.9 Automation and remote

- [ ] **AG-130** Scheduled tasks that act on their own without a session (#1676); Nook Chat as a target is BR-15…BR-17 · M

- [ ] **AG-131** Webhook filters, duplicate key, coalescing, deliveries log, public relay, deliveries kept across a quit (`WebhookRelay`, #1677) · M

- [ ] **AG-132** Remote machines over SSH (`RemoteMachines`, `RemoteBridge`, `RemoteHostDiscovery`, `RemoteMachinesSettings`, #1533) · L

- [ ] **AG-133** Nook as a remote MCP server with tunnel and grants (`RemoteMCP*`, `RemoteMCPSettings`) · L

- [x] **AG-134** Stop a dev server the session started, also on settle · S Done (2026-11-23): `core/src/workspace/dev_stop.rs` tracks dev servers by process ancestry from Nook's terminals and spawned agents, re-verifies the PID before stopping, and exposes `workspace_dev_servers` and `workspace_stop_dev_server` in `views/workspace/Terminals.svelte`.

## 5. Chat apps, mail and connectors (CH)

### 5.1 Foundation (blocks almost every chat app)

- [x] **CH-01** One inbox for all apps (`ChatInbox`, `InboxThread`, `BridgedChat`, `ChatBridge`): `core/src/chats/{inbox,bridge,store}.rs`; move WhatsApp onto it first · L

- [ ] **CH-02** Nook's chat helper (`apps/chatd`, `ChatHelper`, `ChatServiceData`, `ChatLiveStream`, `ChatLinker`): build `nook-chatd.exe` in CI, child-process manager in `src-tauri/src/chats/helper.rs`, `/v1` client and `/v1/ws` live line in `core/src/chats/chatd.rs`. This unlocks Telegram, Signal, Messenger, Instagram, X, LinkedIn and Slack · L
  - Done: the helper's child-process manager (Job Object on Windows), the `/v1` client, the `/v1/ws` live line and its bridge into the shared inbox. Open: building `nook-chatd.exe` in CI and shipping it beside `nook.exe` (`externalBin`). Its Go code is portable, but the Signal connector needs libsignal's Rust library for `x86_64-pc-windows-*`. That library builds BoringSSL with cmake, and go-sqlite3 and webp need cgo through MinGW, so it needs a Windows runner to prove.
- [x] **CH-03** Sign-in window that hands cookies or tokens to the helper (`ChatSignInWindow`, `WebSignInAgent`): a private `WebviewWindow` per step running the step's `extractJS` · M

- [ ] **CH-04** Reading other apps' notifications (`ChatCaptureService`) for Discord, Google Chat, Viber, LINE…: `UserNotificationListener` or `wpndatabase.db` on Windows, D-Bus monitor on Linux, in `src-tauri/src/platform/*/notifications.rs` · M

- [x] **CH-05** Per-app notification layouts (`MessagingApp`, `NoticeLayout`) in `core/src/chats/apps.rs` · S Done (2026-11-23): `core/src/chats/apps.rs` holds the Mac's built-in app catalog (`MessagingApp`: domains, site, `NoticeLayout` for Slack markup, speaker in text and sender in title, notifies by default, FaceTime, own link) and `parse_notice` that reads a notification by it, with tests. Windows has no notification reader yet (CH-04), so only the shared parsing and catalog exist.

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

- [x] **CH-30** One list across apps with per-app filters and account rows (`ChatsTab`, `ChatsSidebar`) · M
  - Done: the Chats tab reads every app's chats from the shared inbox (`chat_inbox_list` in `src-tauri/src/chats/inbox.rs`, `chatsApi`, `inboxEntry` in `lib/chats-list.ts`) beside WhatsApp's own list; the sidebar lists each chat app with what is new in it, and the chosen app's accounts under it while it has chats in more than one. Telegram, Signal and the helper's other apps show once nook-chatd runs (CH-02).

- [x] **CH-31** Status and Channels tabs (`ChatsListKind`) · S
  - Done: Chats / Status / Channels as tabs over the list, shown while an app has status updates or channels, each with its count of what is new; status and channels never mix with the chats.

- [x] **CH-32** Pinned chats (`ChatPins`) · S
  - Done: Pin to top / Unpin in a row's right-click menu and the open chat's "…" menu; pinned chats head the list under Pinned, for every app (`pins` in `views/chats/chat-actions.svelte.ts`, kept on this computer).

- [x] **CH-33** People view with notes and birthdays (`ChatPeople`) · M

- [ ] **CH-34** Chat info: description, admins, groups in common, export, block, report (`ChatsInfoSheet`, `ChatProfile`, `ChatCommonGroups`) · M Partly done (2026-11-23): the info sheet now shows what the helper's apps say (`core/src/chats/profile.rs`, `ChatProfile`: description, admins first with an Admin mark, number, address, username, bot, disappearing timer), the groups you share with a person (`chat_common_groups`, Show all/less, opens the group), Export chat as a text file (`chat_export`) and Block or report in the app (opens the app, as on the Mac: no chat app lets another app block). Open: WhatsApp's gateway (no profile source wired), created by/on, and the job title, business and address fields.
  - Done: the face or name in a chat's header opens its info (`views/chats/ChatInfo.svelte`): the picture, name, app and account, a group's members, and the chat's steps (read, unread, pin, mute and archive in the app where it allows, remove). Open: description, admins, groups in common, export, and block/report in the app, which neither the helper's chat list nor WhatsApp's gateway gives Nook yet.

- [ ] **CH-35** Scroll back for older messages (`ChatHistoryBridge`) · M Update (2026-11-23): WhatsApp now pages back too: every scroll back asks GOWA/OpenWA for a page more (`WhatsAppLink::load_history`, 50 per page up to 1000) until nothing new comes. Open: not verified against a live gateway.
  - Done: "Show earlier messages" at the top of a chat, and scrolling to the top, ask its app for older messages (`chat_inbox_older`): the helper's apps page back through the helper (`/paginate`, then the newest `capacity` messages as history, `ChatInbox::grow`) as long as they have more. Open: WhatsApp brings one more page (its gateway's recent 50) and no further; GOWA's chat history call has no paging that Nook uses yet.

- [x] **CH-36** Join/leave and group change lines (`ChatMembershipLine`, `ChatGroupChange`) · S Done (2026-11-23): `core/src/chats/membership.rs` (`ChatMembership`, `ChatGroupChange`, with the Mac's normalising rules), read from the helper's `MEMBERSHIP` and `GROUP_CHANGE` messages into `InboxMessage` (never counted as new), shown as centred lines in the chat and as the list preview (`lib/chat-notice.ts`, words from the Mac in five languages). WhatsApp's gateway sends no group events Nook reads, so WhatsApp has none yet.

- [x] **CH-37** "What Nook can't do in this chat" line (`ChatLimitsLine`) · S
  - Done: a chat Nook can only read (its app not linked through the helper or the gateway) shows the Mac's line above the field with Link <app> (Settings › Chat apps) and a cross that hides it for that app; the field then copies the text for the app.

- [x] **CH-38** You owe a reply / Waiting for reply / reminders, owed replies and birthdays in Today (`ChatFollowUps`, `ChatFollowUpTick`, `ChatFollowUpStore`) · M Done (2026-11-23): birthdays, owed replies and reminders are all in Today now (`birthdays` provider in `lib/inbox-sources.ts`, `chat_owed`, follow-up reminders).
  - Done: the follow-up rules in Rust (`core/src/chats/follow_up.rs`, `ChatFollowUps`): the private chats whose last word is theirs and has waited 4 hours to 14 days, questions first (`chat_owed`, for Today), waiting for a reply with a reminder once its day is up (sent as a notice through the notice rules), snoozes, and settling them with the inbox once a minute. Done (2026-11-20): owed replies on Home and the empty Nook chat ("Lisa is waiting for your reply", app · age, Reply opens that chat in Chats; the Mac's `owedChatAttention`), every chat app at once and without chats muted in their app (`owed` in `lib/inbox-sources.ts`); the reminder says "Lisa has not answered yet" with their last message, in five languages. Open: birthdays, which come from the People view's notes (CH-33).

- [x] **CH-39** Leave scam and phishing chats out of owed replies and reply suggestions (scoring itself is BR-08) · S

- [x] **CH-40** Snooze a chat · S
  - Done: snoozing a chat out of owed replies and arrival notices (`FollowUps::snooze`, `chat_snooze`, `chat_snoozes`, quiet arrival suppression in `chats/notify.rs` and `connectors/mod.rs`), user-configured snooze presets in every chat menu (`ChatRow`, `ChatDetail`, `ChatInfo`), Today owed-chat quick snooze (`lib/inbox-sources.ts`), row badge, and detail banner with one-click "Bring it back now".

- [x] **CH-41** Scheduled send (`ChatScheduledSend`) · M
  - Done: scheduled messages as on the Mac (`ChatScheduledSend`, `ChatFollowUpTick`): kept in `chat-follow-ups.json`, sent by the follow-up tick when due through the same send as one by hand, and one that comes more than two hours late (Nook was off) or whose chat is gone is not sent by itself but comes up for your OK (`chat-scheduled-confirm`); commands `chat_schedule`, `chat_scheduled`, `chat_schedule_cancel`. The Mac has no place in its UI to schedule one yet (its strings exist, no view uses them), so Windows has none either until it does.

### 5.4 Messages and composer

- [x] **CH-45** Reactions: show, send, who reacted (`ChatReactions`) · M
  - Done: reactions under a bubble as one pill (up to three emoji, the count, mint when one is yours), a click lists who put which (your row takes yours back, another's adds it from you), and the quick reactions on top of a message's menu. The helper's apps read and send them (`reactions`, `/reactions`); WhatsApp sends through GOWA's `/message/{id}/reaction` and reads them from the webhook (`message.reaction`, or a `reaction` inside a `message`, named by who wrote it, `WhatsAppLink::person_name`). OpenWA's API has no reaction call, so there Nook only shows what comes in from the other gateways.

- [x] **CH-46** Reply with a quote · S
  - Done: Reply from a message's menu puts it above the field and the answer goes as a reply (WhatsApp: GOWA `reply_message_id`, OpenWA `quotedMessageId`; the helper: `replyToMessageID`), and a bubble that answers another shows it quoted at its top, for every app: the helper's `linkedMessageID` and GOWA's `replied_to_id` fill `InboxMessage.reply_to`.

- [x] **CH-47** Edit, delete for everyone, delete for me, message info, right-click menu (`MessageMenuItems`, `ChatHiddenMessages`) · M Done (2026-11-23): message right-click menu with edit, delete for everyone, delete for me (persisted hidden messages), and message info wired in `core/src/chats/inbox.rs`, `src-tauri/src/chats/inbox.rs`, and `views/chats/ChatDetail.svelte`.
  - Done: a message's menu from the chevron at its corner or a right-click: quick reactions, Reply, Forward, Copy, Edit (your own; also arrow up in an empty field) and Delete…, which asks for everyone or for you; the helper's apps through the helper, WhatsApp through GOWA (`/message/{id}/update|revoke|delete`); an edit or a deletion made on the phone comes in from GOWA's webhook (`message_edited`, `message_revoked`, `message.edited`, `message.revoked`) and shows as "Edited" or "This message was deleted". Open: message info (who read it when; the gateways give per-person read times only to groups' webhooks Nook does not keep yet), and OpenWA, which has none of these calls.

- [x] **CH-48** Forward (`ChatForward`) · S
  - Done: Forward from a message's menu opens the Mac's picker (every chat Nook can write in, of every app, searchable, several at once) and sends the text to each, with a toast of where it went. Open: forwarding a photo or file, which waits for CH-49 on WhatsApp.

- [x] **CH-49** Send photos, videos and files: "+", drop, paste · M
  - Done: "+" beside the field, dropping files on it and pasting them: up to ten files wait as chips above the field and go with the next send, the typed text as the first one's caption, as an answer when one is quoted. WhatsApp through GOWA's multipart `/send/image|video|audio|file` or OpenWA's base64 `/messages/send-*` (`Provider::send_file`, `WhatsAppLink::send_file`), the helper's apps through `/v1/assets/upload/base64`. The full-size review and picture editing are CH-50.

- [x] **CH-50** Edit a picture before sending: crop, rotate, draw, text (`ChatImageEdit`, `ChatAttachmentStage`) · M Done (2026-11-23): `views/chats/ChatImageEditor.svelte` (wired into `ChatDetail.svelte`) supports crop, rotate, freehand draw, and text annotations before sending.

- [ ] **CH-51** Stickers, GIFs (Giphy), frequent emoji · M
  - Done: the smiley beside the field opens your most used emoji first, then a common set (`ChatEmojiButton`, counts kept on this computer), and an emoji goes in at the cursor. "+" is now the Mac's attach panel (`ChatAttachPanel`: Photo & video, File, Audio, GIF, Stickers as tiles, Poll below them where the app takes one); GIF opens GIPHY's trending GIFs and a search (`core/src/chats/giphy.rs`, `src-tauri/src/chats/gifs.rs`, `views/chats/ChatGifShelf.svelte`; Nook's own key, or yours from Settings; only GIPHY's own https files are fetched, at most 16 MB) and a click sends the GIF at once, for every app that takes files; Stickers shows the GIFs you sent lately and "GIF from file…". Open: sending a picture as a real sticker (no sticker kind in `OutgoingFile` and the helper's upload yet), the stickers that came in a chat on its shelf, and WhatsApp's GIF playback flag (a GIF goes as a video).

- [x] **CH-52** Record and send voice notes (`OggOpus`) · M
  - Done: the mic in an empty field records a voice message (`ChatMicButton`), the bar shows its time with a bin to throw it away and the arrow to send it (`ChatRecordingBar`); WebView2 records Opus in WebM, which `chats::voice::webm_to_ogg` moves into Ogg pages without decoding (`OggOpus`), and it goes as a voice note: GOWA `ptt`, OpenWA `ptt`, the helper's `voice-note`. Open: playing a voice note of a helper app in the chat (WhatsApp's play already).

- [x] **CH-53** Polls: show, vote, send (`ChatPoll`) · M
  - Done: `core/src/chats/poll.rs` (`ChatPoll`, `PollDraft` with the Mac's limits and problems, ballots that replace each other) on `InboxMessage.poll` for every app: WhatsApp's from GOWA's webhook (`poll` creation, votes one by one as `WebhookEvent::PollVote`) and OpenWA's `type: poll`, the helper's `type: POLL` with its voters by name; the bubble draws `ChatPollView.svelte` (bars, counts, your choice ticked, View votes, "Vote in the app" where Nook cannot vote) and a list line shows "📊 question". Voting (`chat_inbox_vote`): the helper's apps through `/messages/{id}/vote`, WhatsApp through OpenWA's `vote-poll`; GOWA has no vote call, as on the Mac. Sending (`chat_inbox_send_poll`, `ChatPollForm.svelte` from "+" › Poll): WhatsApp through GOWA `/send/poll` or OpenWA `/messages/send-poll`; the helper's apps have no polls another app can send, as on the Mac (`ChatOutgoing.Kind.noPolls`). Not kept: the Mac's vote ledger across restarts (`WAPollLedger`).

- [x] **CH-54** Typing line, group "read by", read times, ticks on older messages (`ChatTyping`, `ChatReceipts`) · S

- [x] **CH-55** Mentions by name and an `@` list of group members (`ChatMentions`, `ChatTags`) · S
  - Done: "@" in a group lists its people whose name fits (`ChatTags`, `chat_inbox_people`): WhatsApp's from GOWA's `/group/info` or OpenWA's `/groups/{id}`, the helper's from its chat list; a click puts "@Name " in the field, and it goes as the app's own tag: "@<number>" with `mentions` on WhatsApp (`tag_members`), the person's id in `mentions` for the helper's apps.

- [ ] **CH-56** Video stills, document first pages, media cache across restarts, video playing in the card (`ChatFileThumbnails`, `ChatPictureDisk`, `ChatMediaWarmup`) · M

- [x] **CH-57** Link previews, call rows, "Edited"/"Deleted" marks with earlier versions · S
  - Done: a message's first link shows under its words (`ChatLinkPreview`): a picture link as the picture, a page as the Mac's card (16:9 picture with a play mark for a video page, the site with its icon, the title in two lines), fetched in Rust from public addresses only, redirects checked one by one, a page cut at 512 kB and a picture at 3 MB, kept in memory only (`chats::link_preview`, `chat_link_preview`). A call an app wrote as a line ("Missed voice call", "Videoanruf 2:13") shows as the Mac's call row (`ChatFormat.call`, `ChatCallRow`: the round mark, missed in coral, who rang and how long). An edited message keeps what it said (`InboxMessage.versions`, from a read that brings new words, an edit through Nook or a deletion), and its "Edited" opens "Earlier versions" (until when, and now); a deleted one opens "Before it was deleted".

- [x] **CH-58** Mark unread; pin, mute, archive and delete in the app itself (`ChatAbilities`) · M
  - Done: Mark as unread and read in Nook or in the app for every app (the helper's apps are told; WhatsApp's gateway has no unread call, so there it stays in Nook); Mute / Unmute and Archive in the app itself for the helper's apps (`chat_inbox_in_app`, the helper's `PATCH` and `/archive`); removing a chat from Nook after a yes. Open: Pin in the app (the helper's chat list does not say yet whether a chat is pinned there), and anything in WhatsApp itself, which its gateway does not offer.

- [x] **CH-59** Keep the reading position while older content loads (`TimelineReadingAnchor` on the Mac) · S
  - Done: older messages that come in above keep the message you were reading in place (the scroll height before and after; on the Mac `TimelineReadingAnchor`), for every app.

### 5.5 Suggestions, notices and calls

- [ ] **CH-60** Browser extension: native-messaging host for Chrome, Edge and Brave, the `chrome_*` tools, Settings page (`BrowserExtensionService/Host/Hub/Tools/Look`, `BrowserExtensionSection`, #1573, #1627), and live side panel tasks that ask per step in the panel (`BrowserTask`, `ToolRunner.performs`) in `src-tauri/src/browser_ext/` · L

- [x] **CH-61** Suggested reply as ghost text in the empty field (#1654), ghost completion while typing · S Done (2026-11-26): empty-field suggested reply ghost text with `Tab` keycap (`chat_suggest_reply`) plus debounced inline ghost completion while typing (`autocomplete_playground`, `Tab` next word / `Shift+Tab` all / `Esc` dismiss / smooth type-through) in `ChatDetail.svelte` and `chat-ghost.ts`.
  - Still open after round 6: the ghost completion while typing needs the composer autocomplete (`ComposerCompletion`, `ComposerInlineGhost`, SV-60), which Windows has only as the system-wide service and its Settings playground, not inside a text field of Nook's own.
  - Done: the suggested reply (`ChatReplySuggestion`) for every app: when you open a chat whose newest message is someone else's, Nook writes the answer you would likely send (`chat_suggest_reply`, the Mac's `ChatDraft` prompt with no request, `core/src/chats/draft.rs`) and it shows grey in the empty field; Tab puts it in, typing hides it, Escape lets it go, one try per message. Open: the ghost completion while typing (the composer autocomplete, SV-60) and its switch under Typing › Complete (UI-81, another area).

- [x] **CH-62** Suggested steps above the field (`ChatActionSuggestion`, #1683) · M
  - Done: the Chats tab's open chat puts BR-60's `ActionSuggestionBar` above its field, as the Mac's `ChatReplyField.suggestsActions` does: the chat's newest message (yours too) as the turn, the chat's place (app and name), and its newest thirty lines with you as "You"; for every app.

- [x] **CH-63** `@nook` in a chat field to draft, change or look things up · M Done (2026-11-23): `@nook` in `views/chats/ChatDetail.svelte` drafts, rewrites, or looks up context directly from the chat composer.
  - Done: "@" at the start of the field offers "@nook" first; "@nook …" (or "@nook" alone for a fitting answer) and Return has Nook write the message into the field from the chat and what you asked (`chat_draft`, the Mac's `ChatDraft.system`/`prompt`/`clean`), "Nook is writing your message…" meanwhile; it is never sent by itself. Open: the lookups (`ChatDraft.lookupSystem` with Nook Chat's read tools and proposed actions) and the ready-made requests in the "@" list.

- [x] **CH-64** Notice priority for questions and mentions (`ChatNoticePriority`) · S
  - Open: on the Mac priority (a question in a private chat, a mention in a quiet group) only lets a message past the notice pacer's burst limit and never bypasses a rule; Windows has no notice pacer yet, so there is nothing for priority to change. Port it with the pacer.

- [x] **CH-65** One bar card for every chat app: `WhatsAppCard.svelte` → `ChatCard.svelte` · M
  - Open: the bar still has only WhatsApp's card (`WhatsAppCard.svelte`); the other apps' new messages reach the bar as `chat-arrived` (key, app, name, preview, style) for a shared `ChatCard.svelte`, which the bar (`views/Bar.svelte`, another area) has to show.

- [x] **CH-66** Notice rules for every app, quiet bots, muted-in-its-app, Settings › Notifications with "how" and "from whom" (`ChatNoticeRules`, `ChatNoticeRuleRows`, `NoticeRulesSettings`) · M Done (2026-11-23): per-app chat notice rules, quiet bots, muted-in-its-app, and Settings › Notifications "how" & "from whom" implemented in `core/src/services/notice_rules.rs`, `commands/services.rs`, and `views/settings/NoticeApps.svelte`.
  - Done in part: every chat notice goes through Settings › Notifications' one rule set (`notice_rules.rs` via `notices::decide`), with the app's name for its per-app switch. Open: quiet bots and "muted in its app" as rules of their own, and the per-app rows in Settings (another area).

- [x] **CH-67** Windows toast with Reply and Mark read · M
  - Done: a new message of any chat app (WhatsApp's arrival, the helper's apps from what the inbox newly holds, `chats::notify`) asks the one notice rule set first (`notices::decide`: the Chats style, the app's switch, quiet hours, quiet while sharing; as on the Mac a question or a mention is never passed as urgent); as a system notification it is a Windows toast with a reply field and Mark as read (`ToastKind::ChatReply`): the reply goes through the chat's own app, Mark as read reads it there, a click opens the chat in the Chats tab (`open-chat`). As a card or strip WhatsApp's goes to the bar as before and the other apps' as `chat-arrived`; history only shows nothing.
  - Done (2026-11-20): the bar shows the other apps' `chat-arrived` as WhatsApp's: a "Message from Lisa" chip under the closed round Nook (never opening the bar by itself), and once the bar is open the chat's card with its last four messages as bubbles, a field to answer, Read, Open in Nook (that chat in the bar's Chats tab) and Dismiss; a draft you are typing keeps its card, Esc closes it (`lib/chat-arrived.svelte.ts`, `components/ChatArrivedCard.svelte`, `views/Bar.svelte`).

- [x] **CH-68** Read on reply and read-when-opened for every app (#1593); the card refreshes live while up · S
  - Done: a chat opened in the Chats tab is read in Nook after a moment on screen, and what comes in while it stays open too, for every app; answering reads it in the app (the helper's apps always, WhatsApp with its "mark read on reply" setting). Open: the "Read in Nook when opened" and "Also read in the app" switches in Settings (UI-30, not in this change's area) and the bar card refreshing live for apps other than WhatsApp (CH-65).

- [x] **CH-69** Calls: call button and call card, microphone detection, start through the app's URI (`AppModel+ChatCall`, `ChatCallCenter`, `ChatCallDevices`) · M (`core/src/chats/call.rs`, `src-tauri/src/chats/call.rs` with URI launch + `cpal` audio devices + mic polling, header/info call buttons and floating `ChatCallCard`)

### 5.6 WhatsApp

- [x] **CH-70** Second WhatsApp account and a picture per account (`WhatsAppAccounts`) · M (`core/src/connectors/whatsapp/accounts.rs`, multi-account routing/filtering, `WhatsAppAccounts.svelte`)

- [x] **CH-71** Install GOWA from Settings (`WhatsAppGOWA`, `WhatsAppSettingsSection`) · M (`core/src/connectors/whatsapp/gowa_install.rs`, `commands/whatsapp.rs`, `WhatsApp.svelte`)

- [ ] **CH-72** Recent WhatsApp fixes: re-read quiet chats that moved, fetch media on arrival, typing and group unread counts (15fab7633, bfd3f0639, a8c5b8907) · S

- [ ] **CH-73** WhatsApp Web inside Nook and `@chat` / `@open` (`EmbeddedApps`, `WhatsAppWeb`, `WhatsAppWebSender`) through WebView2; TAURI.md's "—" is wrong · M

### 5.7 Brain tools for chats and mail

- [x] **CH-80** `chat_inbox` and `chat_send` on the shared inbox; point `chat_list/read/send` (#1679) at them; `bridge_nook.rs::chat_use` refuses everything but WhatsApp today · M
  - Done: `chat_inbox` and `chat_send` (`src-tauri/src/tools/chats.rs` on `nook_core::chats::tools`) read and write every chat app in the shared inbox alike, sending through `chats::inbox::chat_inbox_send` after the click; a name that fits two chats is asked about, never guessed. `chat_use` maps the agents' `chat_list/read/send` onto them for every app.

- [x] **CH-81** #1679 follow-ups: hide device-only sources from agents per call, clamp the limit · S
  - Done: an agent's call runs with the apps kept on this device withheld (`tools::chats::WITHHELD`, set by the bridge around reads and approved sends), and `chat_read`'s limit is clamped to 1…50 (`chats::tools::clamp_limit`).

- [x] **CH-82** Dead mappings `search_messages`, `messages_open_chats`, `read_messages`, `read_whatsapp` in `research.rs`/`intent.rs`: map to `chat_inbox` or remove · S
  - Done: the Mac-only `search_messages`, `messages_open_chats` and `read_messages` are gone from `research.rs`, `intent.rs` and `service.rs` (the tool-to-source catalog keeps them as the Mac's names); chats and chat writing now offer `chat_inbox` and `chat_send`; `read_whatsapp` stays, WhatsApp's own tool still exists.

- [x] **CH-83** Chat and mail data behind `find_time`'s invitations: send the `.ics` from BR-22 through CH-91 · S

- [x] **CH-84** Browser tab reading in Sources and research (`research.rs` names it already); the tool itself is BR-31 · S
  - Done: the browser is a source in the Sources picker (its tools register it), and a question that names the tab or the page reads it in research (`lookups` → `read_browser_tab`); a test covers it beside `chat_inbox` for a named chat app.

### 5.8 Mail and calendar (Windows alternatives to Mail.app and EventKit)

- [x] **CH-90** Mail reading: `mail_unread`, `inbox_mail`, `search_mail`, `read_mail`, `trash_mail`, `mark_mail` on Microsoft Graph, the Gmail API and IMAP in `core/src/connectors/mail/` · L

- [x] **CH-91** Mail as chats and sending after Send: Graph `sendMail`, Gmail; `compose_mail` with `reply_to` threading (#1628), attachments and `.ics` invitations (#1682) · M

- [x] **CH-92** Read and write calendars: Graph, Google Calendar or WinRT `AppointmentStore` (ICS is read-only) · M

### 5.9 Connectors and accounts

- [x] **CH-95** Missing MCP sign-in presets: Atlassian, Canva, Supabase, Neon, Hugging Face, Cal.com (MCP), Resend (MCP), GitLab (MCP) in `core/src/connectors/mcp/connector.rs` · S

- [x] **CH-96** Add sheet grouped as on the Mac, deep link to one chat app's sheet (`ConnectionCatalog`, `ConnectionsPage`) · S

- [x] **CH-97** 1Password `op://` secret provider (`SecretProvidersSection`) · M Done (2026-11-23): 1Password `op://` secret provider (`SecretReference`, `OnePasswordProvider` desktop/service-account/Connect modes) in `core/src/secrets.rs`, `commands/services.rs`, and `views/settings/Accounts.svelte`.

- [x] **CH-98** Agent account options: on/off, program path, extra arguments, environment, custom models (`AccountOptionsSection`) · M Done (2026-11-27): `AgentProfile` options (`disabled`, `executable_path`, `extra_arguments`, `variables`, `custom_models`) and keychain-backed secret variables in `core/src/agents/profiles.rs`, wired into `Manager` launch resolution (`core/src/workspace/manager.rs`, `src-tauri/src/workspace/mod.rs`), Tauri commands (`agents_profile_set_enabled`, `agents_profile_set_executable_path`, `agents_profile_set_extra_arguments`, `agents_profile_set_variables`, `agents_profile_set_custom_models`), `views/settings/AccountOptionsSection.svelte` mounted per account in `views/settings/Agents.svelte`, and disabled-account / custom-model wiring in `AgentModelPicker.svelte`, `NewSession.svelte`, and `HandOff.svelte`.

- [ ] **CH-99** Settings for notification collection, read behaviour, GIF key (`ChatOptionsSection`) · S
  - Done: Settings › Accounts & connections › Chats ends with the Mac's options (`views/connectors/ChatOptions.svelte`): Reading with "Read in Nook when opened" and "Also read in the app" (`lib/chat-options.svelte.ts`, used by the Chats tab for every app, the app told only where `abilities.markRead`), and GIFs folded away with your own GIPHY key (kept in the keychain, `chat_giphy_key_*`, remove after a yes). Open: "Collect chats from notifications" and the apps it lists, which wait for the notification reader (CH-04).

- [x] **CH-100** `nook://` links and default-browser routing (`AppModel+IncomingLinks`) through `tauri-plugin-deep-link` · S Done (2026-11-23): `nook://` deep-link parser and incoming-link router in `core/src/services/deep_link.rs` and `commands/services.rs`.

- [x] **CH-101** "Fix it" buttons next to chat errors (`ChatRecovery`) · S
  - Done: `Recovery::for_error` in `core/src/brain/suggestions.rs` (the Mac's `ChatRecoveryAction.forError`: choose a model, start Ollama or LM Studio, reconnect the brain or a connection, Settings) and the error card in `components/MessageView.svelte` with the fix first, Try again second and the raw message behind Details; a local server that is installed but stopped is started by Nook and the question asked again.

- [ ] **CH-102** Import sign-ins, history and saved passwords from another browser for Nook's browser (`BrowserImportSheet`, `BrowserMemorySettings`) · M

- [ ] **CH-103** Portfolio (`PortfolioConnector`): off on the Mac too; port when it is switched on there · S
## 6. System services (SV)

### 6.1 Updates and telemetry

- [x] **SV-01** App updater on GitHub Releases with signatures, check at launch and every 4 minutes, Update button (`AppUpdater`, `ReleaseUpdateCore`, `Ed25519Verifier`) → `src-tauri/src/updates.rs` · L
  - Done: `core/src/updates` (versions, channel, release choice, Ed25519 check, release notes, receipt, install kind) with the Mac's tests, and `src-tauri/src/updates.rs` checks, downloads, verifies and installs: the Windows setup runs passively (`/P /UPDATE /R`) and starts Nook again, the AppImage is swapped and restarted. The `.msi` (msiexec, `AUTOLAUNCHAPP`) and `.deb` (pkexec apt/dpkg) update themselves too. Checks read the update feed on the latest release (API as fallback); an administrator policy can turn updates off; the phone can install them (`installUpdate`). No wake trigger: the 4-minute check covers it.
- [x] **SV-02** Stable/Beta channel (`ReleaseChannel`) · S

- [x] **SV-03** Update trial and rollback after a crash (`UpdateTrial`, `UpdateTrialRunner`) · M Done (2026-11-23): `core/src/updates/trial.rs` and `src-tauri/src/update_runner.rs` keep the previous app binary and a copy of `nook.sqlite` when an update is applied, commit the trial after a minute of healthy running, and automatically roll back the binary and database if the new build crashes before committing.

- [ ] **SV-04** Daily updates of GOWA, ACP agents and Antigravity (`ToolUpdates`) · M

- [x] **SV-05** OpenTelemetry export: OTLP/HTTP, endpoint per signal, headers in the secret store, `OTEL_EXPORTER_OTLP_*`, Test button, also passed to agents Nook starts (`Telemetry/*`, `TelemetrySettingsSection`; includes AG-33) · M Done (2026-11-21): OTLP/HTTP JSON exporter with an endpoint per signal, headers in the system keychain (`otlp.headers`), `OTEL_EXPORTER_OTLP_*` in Nook's environment over the fields, a Test per signal that posts an empty export and reports the HTTP status (`core/src/services/telemetry.rs`). Nook now sends its own records as on the Mac (`core/src/services/nook_telemetry.rs`): each agent turn (span, turn/duration/token sums, log record), each scheduled task run and the launch time, batched every 10 seconds, a signal that fails rests a minute, never prompts, answers, paths or session ids. The Maintenance section matches the Mac (no separate on switch: a filled-in endpoint is on). Agents get the receiver too (AG-33).

### 6.2 Attention, notices and Today

- [x] **SV-10** Display style per source (card, line, system notification, list only) and per-app switches (`NoticeRules`, `NoticeRulesSettings`) · M

- [x] **SV-11** Shared pacing and a daily interruption budget (`NoticePacer`, `InterruptionBudget`) · M

- [x] **SV-12** History of missed notices, searchable, opens its source (`NoticeLog`, `NoticeHistory`) · M
  - Done: every notice is kept in memory since Nook started (`core/src/services/notice_log.rs`, the Mac's `NoticeLog`: newest first, one per chat or session, at most 100 and a week): each system notification (`notices::post`), each agent done/failed/waiting card and each chat message that arrived, also the ones Settings › Notifications keeps out of sight. The bell in the sidebar's head (`components/shell/NoticeBell.svelte`) shows how many you have not seen, a search, the entries with their state color, who and when, and opens the session, the chat, the Nook or the page they came from; remove one or clear all (`src-tauri/src/notice_history.rs`). Also searchable in Search everything (Ctrl+K).

- [x] **SV-13** Shared ranking with learned weights for Today, menu and phone (`AttentionItem`, `AttentionScorer`, `AttentionFeedback`) · M
  - Done (2026-11-22): the Mac's rules and feedback in Rust (`core/src/services/attention.rs`: needs in the Mac's order, deadlines, waiting time, actionable, ±10 from feedback that fades over two weeks, kept in `attention-feedback.json` and written only when you act) with the same scorer in TypeScript for the views (`lib/attention-rank.ts`, weights from `attention_weights`). Home and the empty Nook chat rank with it, the tray's "Needs you" is its top need (a failed session now counts), the phone's Home orders what waits on you with it. What you do teaches it: opening, dismissing, snoozing or reading a Home item, and View, OK or the countdown on an agent's card (`attention_record`). Open: chat cards and Think Along do not report back yet (the Mac also counts them).

- [x] **SV-14** One app-kind catalog (browser, call, chat, editor, terminal) with Windows exe names (`AppCatalog`) · S
  - Done: `core/src/services/app_catalog.rs` knows browsers, call, chat, mail apps, editors and terminals by their Windows exe, Linux binary or WM_CLASS and Store package names; quiet mode and Flow's style per app read it, so an app added once is known everywhere.

- [x] **SV-15** Rich Windows toasts: Allow/Deny buttons, groups, priority, clicks that survive a restart, short gist for long approvals (`SystemNotifier`, 5b67dce9f, 730ba42b9; base for AG-51 and CH-67) · M

- [x] **SV-16** Configurable snooze durations and times of day (`SnoozeOptionsSection`) · S
  - Done: the snooze options are the Mac's `SnoozeOption` (durations, and times of day on today, tomorrow or a weekday; defaults an hour, this evening 18:00, tomorrow 09:00; at most eight, the ones already past hidden, soonest first), set in Settings › Notifications › Snooze options (`views/settings/SnoozeOptions.svelte`, `lib/snooze-options.ts`) and used by Home's and the Agents list's snooze menus. Kept per computer in the interface's storage.

- [x] **SV-17** Think Along backoff up to 2 h and kept across restarts; the full nudge filter (`NudgeFilter`, `ThinkAlongBackoff`) · S
  - Done: the wait after an offer is the Mac's (15 minutes, doubled after each no, an unanswered offer counting as one, at most two hours, reset by a yes) and kept in `think-along.json` across restarts (`think_along::Backoff`); the full `NudgeFilter` drops an offer that asks without an action, is not about what is on screen, is about dates more than two weeks away, or repeats an earlier one in other words (`services/nudge_filter.rs`).

- [x] **SV-18** Today complete: agents waiting or failed, replies you owe, birthdays, next event within 3 h, connector failures, autocomplete "saved you", ranking (`AppModel+Today`) · M
  - Done: Home's inbox now also has failed agent sessions, the linked services that broke or need you to sign in again (to Settings › Connections), today's birthdays (the people you gave one in a chat's info, kept in `person-notes.json` with a note, `core/src/chats/person_notes.rs`; and all-day birthday events in your calendars, `lib/birthdays.ts`) and what autocomplete saved you today, beside the agents waiting, the replies you owe (`chat_owed`, CH-38) and the next events (`lib/inbox-sources.ts`). The order is the inbox's own ranking; learned weights are SV-13.

- [x] **SV-19** Buddy moments: good morning, welcome back, break, milestones, while you were away (`BuddyMoments`, `BuddyService`, `AppModel+Buddy`) · M

- [x] **SV-20** Orb with all 17 moods, face looks, reactions to clicks and typing, mouth following read-aloud (`NookMood`, `NookOrb+Face`, `NookPresence`) · M

### 6.3 Music

- [x] **SV-30** Music page: where it plays, search everywhere (9b8aec483); today now playing only · M Done (2026-11-23): `views/services/Music.svelte` redesigned with Now Playing, Search everywhere, Queue, Playlists, Library, History, and Output picker.

- [x] **SV-31** Spotify connection with PKCE and your own client ID (`SpotifyWebAPI`, `MusicConnectionSection`) · M Done (2026-11-23): Spotify Web API with PKCE OAuth and custom client ID in `core/src/services/spotify.rs`, `commands/search.rs`, and `Music.svelte`.

- [x] **SV-32** Search tracks, albums, playlists (`+Search`) · M Done (2026-11-23): track, album, and playlist search in `core/src/services/spotify.rs`, `commands/search.rs`, and `Music.svelte`.

- [x] **SV-33** Queue: Nook queue, Spotify queue, Up Next (`+Queue`, `MusicAppQueue`) · M Done (2026-11-23): Nook queue, Spotify queue, and Up Next wired in `commands/search.rs` and `Music.svelte`.

- [x] **SV-34** Playlists: list, open, create, rename, delete, add, remove (`+Playlists`) · M Done (2026-11-23): list, open, create, rename, delete, add, and remove playlist operations in `commands/search.rs` and `Music.svelte`.

- [x] **SV-35** Library and top artists and tracks (`+Library`) · M Done (2026-11-23): Spotify library, saved tracks, and top artists/tracks in `commands/search.rs` and `Music.svelte`.

- [x] **SV-36** Listening history, stats, streaks, for the recap (`+History`) · M Done (2026-11-23): listening history, stats, streaks, and recap views in `core/src/services/music_history.rs`, `commands/search.rs`, and `Music.svelte`.

- [x] **SV-37** Lyrics through lrclib.net (`LyricsService`) · S
  - Done (2026-11-20): only when you turn it on (from the Music tab itself; the Settings row is UI-83), and then only title, artist, album and length go to lrclib.net; synced lyrics follow the track with the current line bright and a click on a line seeks there, plain ones simply list; "Looking for lyrics…", "No lyrics found" with Search again, "Instrumental, no lyrics" and "Lyrics from LRCLIB · not synced" as on the Mac; answers kept for the run (`core/src/services/lyrics.rs`, `src-tauri/src/services/lyrics.rs`, `views/services/MusicLyrics.svelte`).

- [x] **SV-38** Output picker: Windows audio endpoints and Spotify Connect devices (`MusicOutputs`) · M Done (2026-11-23): output picker merging Windows audio endpoints and Spotify Connect devices in `core/src/services/spotify.rs`, `commands/search.rs`, and `Music.svelte`.

- [ ] **SV-39** Real equalizer levels through per-process WASAPI loopback (`AudioLevelMonitor`) · M

### 6.4 Voice, Flow, Double Tap, Notetaker

- [ ] **SV-45** Double Tap: double-tap a key, a field in the bar, then fill a form, write at the cursor or edit a part, with a step card, Undo and Send (`DoubleTap/*`) → `core/src/services/double_tap/` and a keyboard hook with UI Automation on Windows · L

- [x] **SV-46** Flow on a held modifier alone (right Ctrl), through the low-level keyboard hook · S Done (2026-11-23): `core/src/services/flow_hold.rs` and `src-tauri/src/platform/windows/hold_key.rs` use a low-level Windows keyboard hook (`WH_KEYBOARD_LL`) to start Flow dictation when holding the chosen single modifier key (`right_ctrl`, `right_alt`, `right_shift`, `right_win`) and finish on release while cancelling cleanly if another key is pressed.

- [x] **SV-47** Multi-language dictation (`MultiDictation`) · S Done (2026-11-23): multi-language dictation selection and confidence-based language picking in `core/src/services/dictation_lang.rs` and `views/settings/Voice.svelte`.

- [x] **SV-48** Parakeet and reuse of models already in the Hugging Face cache (`Parakeet`, `VoiceModelCopies`) · S Done (2026-11-23): Parakeet local model catalog and Hugging Face cache scanning/reuse in `core/src/services/transcribe.rs` and `views/settings/Voice.svelte`.

- [x] **SV-49** Field and screen context for dictation cleanup (f9fefac0d) · S Done (2026-11-23): active window/field and screen context prompt terms for dictation cleanup in `core/src/services/dictation_context.rs` and `transcribe.rs`.

- [ ] **SV-50** Speaker recognition in the Notetaker (sherpa-onnx embeddings) · L

- [x] **SV-51** Wake word only after a loudness check, paused while locked, on low battery or under the energy plan · S Done (2026-11-23): wake-word loudness gate and pause on lock/low-battery/energy-plan in `core/src/services/wake_gate.rs` and `src-tauri/src/services/flow.rs`.

- [x] **SV-52** Read-aloud button under each answer (958ad68ad) · S

- [x] **SV-53** A sound per event (e1b3c566d) · S Done (2026-11-21): all four moments (done, permission, attention, error) have their own picker and play their own sound. Update 2026-11-22: a permission request has its own sound (`NookSound::Permission`, `permission.*` in the Sounds folder, a rising tone of its own, its own picker row), as on the Mac.

### 6.5 Autocomplete

- [ ] **SV-60** Autocomplete in Nook's own composers, model warm-up on focus (`ComposerCompleter`, `ComposerAutocompleteSection`; 1b9370040, def79d3fa, e7928b73e) · M

- [ ] **SV-61** Chat context in autocomplete, reply suggestion in an empty chat field (a2de49d80, 372f2bdba; with CH-61) · M

- [ ] **SV-62** Learning from your writing (`CompletionLearning`, b51aadf82) · M

- [ ] **SV-63** Personal adapter training (`CompletionAdapter*`, `CompletionGGUFWriter`, `AutocompleteAdapterSection`) with llama.cpp finetune, or record as left out · L

- [ ] **SV-64** Everything `docs/AUTOCOMPLETE.md` lists as not yet ported: typo fixes, terminals, insert modes, screen context, token healing, write-ahead memo, ranking candidates, word alternatives, Suggest-now key, per-website rules, battery behaviour, 30-day chart · L

- [x] **SV-65** Choosing the generator per kind (CLI or API) with Test (`TextGenerationSettings`; with AG-70) · S Done (2026-11-26): `text_generation` routing/API tester in `nook-core`, `text_generator_test` Tauri command, `WorkspaceSettings.textGenerators`, and `TextGeneratorRow.svelte` per-kind CLI/API pickers with model, inline key save, and live Test button in `AgentsWorkspace.svelte`.

### 6.6 Screen, windows, control

- [ ] **SV-70** Capture-window shortcut: picture plus UI Automation text into a composer (`WindowCapture`, `WindowCaptureText`, b2f8b673f) · M

- [ ] **SV-71** Drag the orb onto a window to attach it, with a halo (`WindowAttach`) · M

- [x] **SV-72** Nook clicks and types in apps (`UIDriver`, `AppModel+Control`; the base for BR-29 and AG-13) · L

- [x] **SV-73** Record-call global shortcut on Windows defaults · S
  - Done: "Record a call" is a global shortcut (Alt+Ctrl+R by default, `notes_shortcut` in the service prefs), registered with the others and set in Settings › Shortcuts; it starts and stops the Notetaker. Needs a run on a real Windows PC (FD-01).

- [ ] **SV-74** Screen region: annotate (arrows, boxes, pen), paste where you were, Ask (`ScreenPart`) · M

- [x] **SV-75** One permissions page with Windows privacy deep links (`SystemPermissions`) · S

- [x] **SV-76** Run a user script (PowerShell or `.lnk`) as an approved tool, as the Mac's `run_shortcut` · S
  - Done (2026-11-22): `run_shortcut` runs a script from the `Scripts` folder in Nook's data folder by its name (`.ps1` through PowerShell without a profile, `.bat`/`.cmd`, a `.lnk` opened by the system, `.sh` on Linux), only after your OK in the plan ("Shortcut: name", never in the small or more lists), hidden, with a two-minute limit and the end of its output for the model; the tool lists the scripts there, and only files directly in that folder can be named (`core/src/services/user_scripts.rs`, `tools/system.rs`). Not run on Windows yet.

### 6.7 App shell

- [x] **SV-80** Hold Ctrl+Q to quit (`QuitHoldMonitor`) · S
  - Done: in the main window, Ctrl+Q shows "Hold Ctrl+Q to quit Nook", after a second "Release to quit Nook", and letting go quits through the tray's Quit (which asks while sessions work); letting go earlier or another key takes it back, and a terminal keeps its Ctrl+Q (`lib/quit-hold.ts`, the Mac's `QuitHold`). Always on: the Mac's switch for it (Settings › General) is not on Windows.

- [x] **SV-81** Notice when a database can't be opened, with recovery (`AppModel+StorageIncidents`, `SQLiteRecovery`) · S
  - Done for `nook.sqlite`: it is checked when it opens (header, schema, `quick_check` up to 8 MB); a damaged file and its `-wal`/`-shm` are moved to `nook.damaged-<date>.sqlite` and a fresh one made, any other failure leaves the file alone, and the main window shows the notice until you close it, with "Show in folder" (`core/src/storage_recovery.rs`, `components/shell/StorageNotices.svelte`). Done (2026-11-22): the JSON stores (chat inbox, follow-ups, connections, Gamer Mode, attention feedback) are read the same careful way (`storage_recovery::read_json`: a damaged file is moved to `<name>.damaged-<date>.json` with a notice instead of silently starting empty, a file out of reach is left alone), and a damaged database's notice offers "Copy recovery command" with the Mac's words (`sqlite3 "<copy>" ".recover" | sqlite3 "<copy>.recovered.sqlite"`). The notice shows in the main window, not as a bar card.

- [x] **SV-82** Eval question set to compare local models (`LocalEvalRunner`) · S

- [x] **SV-83** Main and Settings windows in the taskbar and Alt+Tab (`DockPresence`) · S
  - Done: the main window (Settings takes it whole) and torn-off tab windows are ordinary windows in the taskbar and Alt+Tab while open and leave both when closed to the tray; the bar, the suggestion and autocomplete overlays stay out (`skip_taskbar`). Needs a run on a real Windows PC (FD-01).

## 7. Companion: the PC as server for the phone (CO)

- [x] **CO-01** The rest of the companion protocol. The audit missed that `core/src/companion/server.rs` with `src-tauri/src/companion/backend.rs` already dispatches every group: `options`/`start`; `timeline`/`watch`/`diff`/`entry`/`history`; `terminals`/`files`/`fileData`; `chats`/`chat`/`ask`/`chatStop`/`watchConversation`; `home`/`usage`/`music`; `inbox`/`inboxChat`/`inboxSend`/`inboxMark`/`watchChat`/`avatars`; `manage`/`subscribe`/`requestUpdate`; `pulls`/`pull`/`pullAct`/`pullWork` (checked during FD-07). Only `liveActivity` is missing, which is CO-07 · L

- [x] **CO-02** Compression, `protocolVersion`, `appVersion`, `oldestPhone` (`CompanionWire`, `CompanionCompatibility`): compression, `protocolVersion` and `appVersion` were already there; `oldestPhone` and keeping each phone's versions came with CO-09 · S

- [x] **CO-03** Scopes per phone: read, approve, operate, chats, music, Nook Chat (`CompanionScopes`, `CompanionSetupSheets`) · M

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
