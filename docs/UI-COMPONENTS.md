# Shared UI Components (macOS)

The notch, the Workspace, and Settings share one visual language. Before writing a view modifier chain by hand, check
whether one of the building blocks below already does it; when a pattern shows up a third time, add it here instead of
copying it again.

## Theme — `apps/macos/NotchUI/Theme/NookTheme.swift`

| Token / helper | Use |
| --- | --- |
| `NookTheme.paper`, `textStrong`, `textSecondary`, `textTertiary`, `textMuted`, `ink` | Text colors, from brightest to most muted |
| `NookTheme.canvas`, `surface`, `field`, `well`, `smoke`, `graphite` | Surfaces: the window canvas, a lifted sidebar or menu, a text field, a sunken code well, and the two card fills |
| `NookTheme.line`, `line2`, `hairline`, `fieldStroke`, `separator` | Hairlines and strokes; `separator` is the clearer line between the items of a list |
| `NookTheme.blue` | Links, renamed files, and diff hunk headers |
| `NookTheme.mint`, `amber`, `coral`, `violet`, `iris` | State: done, waiting on you, error, merged, Nook itself |
| `NookTheme.rowRest`, `rowHover`, `rowSelected`, `rowFill(selected:hovering:rest:)` | List rows and cards at rest, under the pointer, and selected |
| `NookTheme.TextStyle.caption`, `detail`, `label`, `body`, `strong`, `title`, `heading`, `display`, `code` | The type scale: the same kind of text is the same size everywhere. `detail` is the line under a title (a setting's explanation, a hint, an error); `heading` heads a sheet or a setup step. Never SwiftUI's own `.caption`, `.callout`, or `.headline` |
| `NookTheme.font(_:_:)`, `mono(_:_:)`, `rounded(_:_:)` | A size the scale does not cover (an icon, a numeral); never `Font.system(size:)` inline |
| `NookTheme.Radius.chip`, `control`, `card`, `panel`, `sheet`, `pill` | Corner radii: 6, 8, 10, 12, 14, 20. Name the element, not the number |
| `NookTheme.Spacing.xxs … xxxl` | Padding and stack spacing on a 4 pt grid: 2, 4, 6, 8, 12, 16, 24, 32 (`xxxl` between the sections of a page) |
| `NookTheme.open`, `close`, `swap`, `hover`, `reveal`, `scroll` | Animations: opening and closing the notch, switching tabs, hover feedback, showing or hiding part of a panel (a section, a preview, a selection), and scrolling to a line. Never an inline `.easeOut(duration:)` |
| `.hoverLift(_:scale:)` | The shared hover lift of buttons and chips |

Workspace views use the `WS` palette in `NotchUI/Workspace/WorkspaceComponents.swift`, which is built from these
tokens (`WS.background` is `NookTheme.canvas`, `WS.sidebar` is `NookTheme.surface`).

### Calm by default

Nook should feel quiet. The surfaces sit on one neutral grey ramp a step apart, so regions read by their fill and need
almost no strokes; a stroke is only a shade lighter than what it edges; state colors are softened a little so a badge
informs without shouting; motion settles without overshoot. When you add a view:

- Group with space and fill, not with lines: a `panelCard()` for rows that belong together, `NookDivider` between them.
- One accent per view at most. Buttons in a header are the same quiet round `NookIconButton`; only a notice's main
  action is filled.
- Words before chrome: a title, one line under it, and nothing in uppercase or tracked.

## Keeping it one design

Nook has one visual language, and the repository guards it in three places:

1. **`UIConsistencyTests`** (`apps/macos/Tests/NookTests/UIConsistencyTests.swift`) reads every source under `NotchUI`
   and `App` and fails when a view uses `Font.system(size:)` inline, one of SwiftUI's own text styles (`.caption`,
   `.callout`, `.headline`, `.system(.body)`), a literal `Color(hex:)` / `Color(red:)` / `NSColor(white:)`, a system
   state or text color (`.red`, `.orange`, `.green`, `.secondary`), or a corner radius written as a number from the scale. It runs with the Xcode tests and with
   `./scripts/core-tests.sh`.
   It also fails when a search field or a 1 pt divider is built inline instead of with `NookSearchField` or
   `NookDivider`, so these look and behave the same everywhere.
2. **`scripts/ui-lint.sh`** checks the same rules with `grep`, so it runs anywhere, and the *UI consistency* job in
   `.github/workflows/build.yml` runs it on every pull request.
3. **This document** is the catalogue: a pattern that shows up a third time becomes a component here.

When a file genuinely draws its own colors (a brand mark, a chart palette, Nook's face), add it to the allow-list in
both `UIConsistencyTests.ownColors` and `OWN_COLORS` in `scripts/ui-lint.sh`, with the reason in a comment; never
loosen the rule itself.

The checklist for a new or changed view:

- Text: a `NookTheme.TextStyle`, or `NookTheme.font` / `mono` / `rounded` for the odd size. Color from the text ramp
  (`paper` › `textStrong` › `textSecondary` › `textTertiary` › `textMuted`), never `.secondary` or `.tertiary`. Settings
  follows the same rules as the panel: a caption under a setting is `TextStyle.detail` in `textSecondary`, a warning
  under it `amber`, an error `coral`.
- Surfaces: `canvas` under a window, `surface` for what lifts off it, `field` for input, `well` for code and logs,
  `rowFill(selected:hovering:)` for rows. Strokes are `line`, `line2`, `hairline`, or `fieldStroke`.
- State color means one thing everywhere: `iris` is Nook, `mint` is done or listening, `amber` waits on you,
  `coral` is an error, `violet` is merged.
- Corners from `NookTheme.Radius`, spacing from `NookTheme.Spacing`, hover with `.hoverLift`, animation with
  `NookTheme.open` / `close` / `swap` / `hover` / `reveal` / `scroll`, and a looping animation (a pulse, a blinking
  cursor) stops with Reduce Motion.
- One layout: the notch, the main window, and a sheet show the same `PanelView`; Settings is the one place for
  configuration. A new task opens inside the panel, not in a new window with its own layout.
- The buttons at the bottom of a notification are always a `NookNoticeActions` row, never loose buttons.
- A short notice (a strip under the notch, a note in the panel's bar, a toast) is always a `NookNotice`: mark, message,
  its own actions, and, when it closes by itself, the OK with its countdown ring. Its time runs on a `NoticeClock`, so
  the ring and the notice hold together while the pointer is on it. A notice that waits for you has no OK.
- A notification card says its state in `NookCard.status` (a tinted pill at the end of its header, colored by its
  `DoneTone`) and an agent's changed lines in `NookCard.changes`; its `context` keeps only who and where.
- The result of an action is a `ToastCenter` toast, never a local notice string, banner or alert (see *Toasts*).
- Every string through `tr("key")` in all five languages, and a `.help` and accessibility label on a symbol-only control
  or menu (`ToolbarIconButton` and `NookIconButton` set both from their label).
- A destructive action asks first (`ConfirmedButton` / `.confirmDelete`) unless it can be undone; a sheet's Cancel has
  `.keyboardShortcut(.cancelAction)` and its main button `.defaultAction`.
- A field where you write words (not a name, a path or a search) gets `@` through `.mentions` and `MentionSuggestions`.
- A search is a `NookSearchField`, a list's title row a `PanelListHeader` (with `PanelNewButton` when it starts
  something), a group's name a `NookSectionLabel`, a count a `NookCountBadge`, a line a `NookDivider` (between the items of a list a `NookRowSeparator`), and a notice under
  the tabs a `PanelNoticeBar`. Change one of these and every tab follows.
- Empty: `WSEmptyState` for a whole panel, `ListEmptyNote` in a list. Loading: `ProgressView().controlSize(.small)`.
  Errors: `coralSoft` text, or a coral-tinted `.cardBackground` notice with a retry.

## Toasts — the result of what you did

`ToastCenter.shared` is the one way to report a short result, on the Mac and (as `toast` in `src/lib/toast.svelte.ts`) in
the Tauri app. Use it whenever an action ends and its own view does not stay to show how it went.

- **Where it shows:** on one surface with `.nookToastHost()` (the panel in the notch and the main window, Settings): the
  key window's, else the one opened last. With none on screen, the notch shows it in its confirmation strip
  (`NotchViewModel.showToast`), but never over a card or a question that waits for you. A new window gets
  `.nookToastHost()` once, at its root.
- **Kinds keep the state colors:** `success` mint, `error` coral, `warning` amber, `info` iris. An error stays longest,
  every toast stays while hovered, and an error with a detail can be copied in one click.
- **Words:** the title says what happened in a few words ("Pushed", "Couldn't remove the worktree", `toast.failed` for
  "%@ failed"); the error's own text goes in `detail`, never glued into the title.
- **Not a toast:** a decision Nook waits for (a card or an approval with `NookNoticeActions`), a problem with a form you
  are filling in (it stays next to that form), a load error that replaces the content (`WSEmptyState`), something
  that stays true (a status row or banner), and the checkmark a copy button shows on itself. No `.alert` for an
  error after an action, and no local `notice`/`status` strings that do a toast's job.
- **The notch's own flows** keep `viewModel.finish`: a card's outcome, a quick command, and an agent that finished.

## Components — `apps/macos/NotchUI/Components`

| Component | File | Use |
| --- | --- | --- |
| `NookPrimaryButton`, `SmallPrimaryButton`, `NookGhostButton`, `SmallGhostButton` | `NookButtons.swift` | Text buttons on cards, in chat, and in the panel's own forms (optional SF Symbol before the title). They dim by themselves when `.disabled`; do not add an `.opacity` for it. Inside the panel use these, not `.borderedProminent` |
| `NookNotice`, `NoticeClock` | `NookNotice.swift` | The one shape of every short notice: the strips under the notch (result, suggestion, moment), `PanelNoticeBar` and the toast. Mark, message and line, its actions, and with `countdown` the OK with its ring; `NoticeClock` runs the same time out and holds while the pointer is on the notice |
| `NookAcknowledgeButton`, `CountdownRing` | `NookButtons.swift` | The white "OK" that closes a notice at once, with a ring counting down until it closes by itself (card `acknowledge` + `countdown`, compact strip) |
| `NookActionBar` | `NookButtons.swift` | A notice's other actions in one dark bar with thin dividers, next to its OK |
| `NookNoticeActions`, `NookNoticeAction` | `NookNoticeActions.swift` | The button row at the bottom of every notification (cards, approvals, questions, panel notices): main action and its "not now" in one pill (`NookSplitButton`), muted extras, rarer actions in a "…" menu (`NookMoreMenu`), optional mic. Use it for any new notification instead of loose buttons |
| `ToastCenter`, `NookToastView`, `.nookToastHost()` | `NookToast.swift` | The one toast for the result of something you did (saved, pushed, failed): `ToastCenter.shared.success(…)`, `.error(…)` (also takes an `Error`, under a title that says what failed), `.warning(…)`, `.info(…)`, with at most one `NookToastAction`. See *Toasts* above |
| `NookSearchField` | `PanelBlocks.swift` | The one search field (panel lists, Settings rows, menus, the command palette): magnifying glass, text, a clear button, Escape clears and then calls `onEscape`. `panel`, `inline` (in a Settings form or a menu) and `large` (a palette). Never build a search field by hand |
| `PanelListHeader`, `PanelNewButton` | `PanelBlocks.swift` | The title row on top of every tab's list (Nook, Agents, Chats, Pull requests): name, `NookCountBadge`, the list's actions; `PanelNewButton` is the "new" in it, lit while the new one is open |
| `NookCountBadge` | `PanelBlocks.swift` | How many wait for you: a small amber count, on a tab or a list title |
| `NookFilterChip` | `PanelBlocks.swift` | One chip in a row of filters ("All", "Sessions 4"): a quiet capsule, filled with the accent when chosen, with an optional count. Search everything uses it for its kinds |
| `NookSectionLabel` | `PanelBlocks.swift` | A group's name in a list or on a page ("Pinned", "For you"), lined up with the rows under it |
| `NookDivider` | `PanelBlocks.swift` | The one line between rows or regions, horizontal (with an `inset`) or `vertical` |
| `NookRowSeparator` | `PanelBlocks.swift` | The clearer line between the items of a list (the Chats tab), in `NookTheme.separator`; placed before every item but the first |
| `PanelNoticeBar` | `PanelBlocks.swift` | A `NookNotice` under the tabs (a permission request, an agent's question, a short note): symbol, title, a line, and its `NookNoticeActions`; `tone` tints a risky one, `countdown` adds the OK for a note that closes by itself |
| `.panelCard()` | `PanelBlocks.swift` | The quiet card that groups rows: field fill, panel corners, no stroke |
| `NookIconButton` | `NookButtons.swift` | Round symbol button (mic, close, play) |
| `ToolbarIconButton` | `NookButtons.swift` | Small borderless symbol button in a panel header, a row, or under a message, with hover feedback; `width`/`height` for a tighter row and `enabled` for a dimmed one. Never hand-roll a `.plain` button around a lone `Image` |
| `ConfirmedButton`, `.confirmDelete(_:question:detail:confirmTitle:action:)` | `ConfirmDestructive.swift` | Anything that cannot be undone (delete, remove a key, sign out, clear a history) asks first in the same dialog. `.confirmDelete` is for menu items, which cannot hold a dialog themselves |
| `ListEmptyNote` | `ListEmptyNote.swift` | The one line a list shows when it is empty or has no matches; a whole empty panel is a `WSEmptyState` |
| `.cardBackground(_:stroke:radius:style:)` | `CardBackground.swift` | Rounded fill with a 1 pt stroke: field cards and tinted notices |
| `Pasteboard.copy(_:)` | `Pasteboard.swift` | Put text on the pasteboard |
| `.onEscapeKey(enabled:perform:)` | `EscapeKey.swift` | Escape that closes what is open (a chat in the Chats tab) also when nothing in the window has the keyboard, where `onExitCommand` hears nothing; a text field being typed in keeps its own Escape |
| `Bar`, `PulseDot`, `ShimmerText`, `PullRequestPill` | `AgentIndicators.swift` | Progress bar, live dot, shimmering current step, pull request state in a row |
| `PullRequestStateBadge` | `AgentIndicators.swift` | A pull request's state as a tinted capsule with GitHub's mark and the word, optionally after its number (pull request page, watched pull request); never draw the state by hand |
| `CheckOutcomeGlyph` | `AgentIndicators.swift` | The outcome of a CI check or step (passing, failing, running, skipped); the pull request page and the CI popover of a watched pull request |
| `PullRequestFreshness` | `NotchUI/Pills/PullRequestsPanel.swift` | "Updated 20 s ago": how fresh a pull request list or page is, ticking along; next to its refresh button |
| `AgentStatusBadge`, `RowBadgeBackground`, `SteppedPulseDot` | `StatusStyleView.swift` | Session state in rows |
| `HoverCard`, `.hoverCard(_:)` | `HoverCard.swift` | Detail popover on hover |
| `DropdownHeader`, `DropdownRow`, `DropdownDivider`, `ComposerDropdown` | `ComposerDropdown.swift` | Menus of the composer and pickers |
| `ComposerTray`, `ComposerTrayDivider` | `ComposerTray.swift` | The tray tucked behind the composer box: under it for a new session (folder and branch), above it for a running one (watched pull request, queued messages). Anything that belongs to the next message goes in here instead of a loose strip |
| `.mentions(_:text:config:)`, `MentionSuggestions`, `ComposerConfig.mentions(folder:)` | `MentionField.swift` | `@` in any field where you write words (a follow-up, a prompt, a mail, a commit message): `.mentions` on the text field itself, `MentionSuggestions` right above its box, both sharing a `ComposerModel` the view owns. `@` lists people from your chats and, with a folder, its files, put in as plain words. `SessionComposer` and `ChatReplyField` have the same list built in |
| `SelectionModeButton`, `.selectable(…)`, `SelectionBar` | `ListSelectionViews.swift` | Selecting several rows |
| `NookTabBar` | `NookTabBar.swift` | Segmented tabs, with an optional symbol, unread dot (`fresh`) or amber count (`count`) |
| `ChatTranscript` | `ChatTranscript.swift` | A conversation as bubbles (a WhatsApp card, the Chats tab): day lines, runs per person, colored names in a group, links, media, copy menu, the message a bubble answers quoted at its top and the emoji on it underneath. Given `onReply`/`onReact`, a bubble under the pointer offers to answer it or react with an emoji (also in its right-click menu). Never draw chat bubbles by hand |
| `EmojiBrowser` | `EmojiBrowser.swift` | Every emoji to choose from (`EmojiCatalog`, Unicode's own list): a search by English name and by Nook's own names, a tab per group, a grid per group. Behind the "+" of the reaction picker; never build an emoji grid by hand |
| `ChatPhotoZoom` | `ChatTranscript.swift` | A chat photo enlarged over the card or chat it is in, sharp once the file is read; a click or Escape shrinks it back, the open button shows it in Quick Look |
| `ChatMessageText` | `ChatMessageText.swift` | A message's text as its app shows it, the same in every chat (`ChatFormat` reads the markup): *bold*, _italic_, ~strikethrough~, `code`, code blocks in a box, quotes behind a bar, lists with their markers, links. Drawn by `ChatTranscript`; never draw a message's text by hand |
| `ChatPollView` | `ChatPollView.swift` | A poll in a chat bubble, the same for every app (`ChatPoll`): the question, each option with its share and count, your choice ticked; with `onVote` a click votes, without it the poll says to vote in the app. Drawn by `ChatTranscript`; never draw a poll by hand |
| `ChatBubble(_:time:)` | `ChatMediaViews.swift` | Any chat app's message (`InboxMessage`) as a bubble, its file included. A bridge only fills `InboxMessage.media` (`ChatMedia`); every chat then shows photos, videos, GIFs, stickers and audio the same way |
| `ChatStickerView`, `ChatGIFView`, `ChatAudioView` | `ChatMediaViews.swift` | A sticker on its own (no bubble), a GIF that loops silently (a real GIF or a short video), an audio or voice message with play, progress and length. Drawn by `ChatTranscript`; never draw chat media by hand |
| `TicksView` | `ChatTranscript.swift` | How far your own message got (clock, one grey tick, two grey, two blue, failed), in every chat app that says it (`ChatReceipt`): after a bubble's time and in front of a chat's newest message in the Chats list. Given `ChatBubble.readers`, a click on them opens `MessageInfoView`. Never draw ticks by hand |
| `MessageInfoView` | `ChatReceiptViews.swift` | Your own message's info in a group: how many read it, then who read it (with the time), who has it, and who does not yet (`ChatReceipts.everyone`). Opened from a bubble's ticks |
| `ChatMembersButton`, `ChatPersonBadge` | `ChatReceiptViews.swift` | A group's people: "5 members" under a chat's name that lists them, and a person's initials on their own tint (`ChatPersonBadge.tint(for:)`, the color of their name in a group's bubbles too). Never pick a person's color by hand |
| `ChatReplyField` | `ChatReplyField.swift` | The answer field under a chat (the Chats tab, and every full card with a field in the notch): Return adds a line and Cmd+Return sends, "@" opens the menu with "@nook" and ready-made requests, "@nook …" lets Nook write the message into the field first, shown as Nook's draft in an iris panel above it: Stop while it writes, go back to the request, or steer it (Shorter, Friendlier, More formal, Other words, or a change typed in its own field) before you send it. With `outgoing` a message on its way leaves the field for a mint panel above it (a gliding paper plane, "Sending to …" shimmering, the message), which shows a check and "Sent" for a moment once the chat has it. With `quote` it answers one message, shown above the field until sent or let go (the cross, Escape); with `onEscape`, Escape in the field with nothing to let go of closes what holds it. With `.extras(…)` it takes more than text: buttons before the text, what waits above the field, a button in place of send while nothing is typed, a bar that stands in for the field, and Cmd-V for pictures and files. Never build a chat's answer field by hand |
| `ChatComposerModel`, `ChatAttachMenu`, `ChatEmojiButton`, `ChatMicButton`, `ChatRecordingBar`, `ChatComposerPanels` | `ChatComposer.swift` | What a chat sends besides text, plugged into `ChatReplyField.extras` (the Chats tab): "+" with photos and videos, files, GIFs, stickers, audio, a poll, a location and a contact (only what the chat's app can send, `ChatOutgoing.Kind`), the emoji browser, a voice message recorded in place of the field, the files waiting to go (each with what it goes as), and the poll, place, contact and sticker panels above the field. Never build a chat's attachments by hand |

Workspace-only blocks (`InfoRow`, `WSEmptyState`, `WSSectionTitle`, `StatusBadge`) live in
`NotchUI/Workspace/WorkspaceComponents.swift`.

## The panel — notch and main window

The main window (`WorkspaceView`) is the open notch with more room: it shows the same `PanelView` (with
`inWindow: true`, which uses `windowTab`/`windowSheet` and lets the close button close the window) and the same
`PanelOrb` (Nook with his task ring, next to the tabs). Change the panel once and both follow; do not build a separate
window layout. In the window the header's empty space moves the window, the traffic lights replace the close
button, the window remembers its tab (and opens at an agent that waits for you), and the chat keeps a readable width
(`PanelLayout.readableChat`). In the notch, the window button continues on the same tab in the window.

The bell in the header (`NoticeBellButton` in `NotchUI/Pills/NoticeCenter.swift`) lists what Nook told you since he
started, so a card that closed before you looked can still be read and opened. A new notice Nook gives by himself (an
agent that finished, a request, a message) is kept with `AppModel.logNotice` where it is decided, before the card, strip
or banner shows, so one held back by quiet mode or a busy notch is kept as well. Toasts, the results of what you did,
are not kept there.

## Settings — `apps/macos/App/Settings`

| Component | File | Use |
| --- | --- | --- |
| `SettingToggle(_:detail:isOn:)` | `SettingsBlocks.swift` | A switch with a caption under its title |
| `SettingLabel(_:detail:)` | `SettingsBlocks.swift` | The same title and caption, for rows with a button or picker |
| `StatusRow`, `SettingsHeader`, `Keycap` | `SettingsBlocks.swift` | Status lines, section headers, keyboard keys |
| `SettingNote(_:tone:)` | `SettingsBlocks.swift` | The one hint or status line under a setting: `info`, `success`, `warning`, `error`; a warning or error carries a symbol, not only a color |
| `SettingsLinkRow` | `SettingsBlocks.swift` | A row that leads to another page or flow: tile, title, line under it, chevron; a status symbol only when something is not done |
| `InUseLabel` | `SettingsBlocks.swift` | The mint "In use" check on the chosen model, file or key |
| `HoverActionsRow` | `SettingsBlocks.swift` | A row whose buttons show under the pointer; at rest a small symbol says its state (memory rows) |
| `SettingsTile`, `HealthPill`, `SetupStep`, `GalleryCard`, `IntroCard` | `SettingsStyle.swift` | Tiles, health pills, setup steps |
| `ServiceRowLayout`, `ServiceStatusLabel` | `ServiceRows.swift` | The one row shape of every connected service (icon, name with state, one line, actions) |
| `GalleryCard`, `GalleryGrid`, `ConnectMethodBadge` | `SettingsStyle.swift`, `ServiceRows.swift` | The one card shape of everything you can add; the badge says how (sign in, a key, MCP) |
| `ServiceCategoryChips` | `ServiceRows.swift` | The category filter under the connections search field |
| `OneClickServiceCard`, `GitHubSignInCard`, `MCPServiceRow` | `ServiceRows.swift` | Services that sign in on their own page |
| `GitLabCard`, `GitLabHostRow`, `GitLabSetupSheet` | `GitLabSettings.swift` | GitLab in the same card, row, and setup-sheet shapes |
| `MCPPresetCard`, `MCPCustomCard`, `MCPServerCardRow`, `AddMCPServerWizardSheet` | `MCPSettingsSection.swift` | MCP servers in the same shapes |
| `SetupSheet`, `SetupStep` | `SettingsStyle.swift` | Every setup flow: icon and title on top, numbered steps, one clear button below |

Settings › Connections is one page in one layout: search and category chips, what needs you, your connections (rows),
the apps on this Mac (switches), and one catalogue of everything you can add (cards). A new service gets a row and a
card in these shapes, and a `SetupSheet` when it needs steps; it never gets a section of its own.

## File layout

Keep a tab or panel file to the view it is named after. Its rows, cards, and helpers go into their own files next to it
(for example `NookTab.swift` → `NookChatMessage.swift`, `NookConversationList.swift`, `NookStarters.swift`; `AgentsTab.swift` →
`AgentFormat.swift`, `GitHead.swift`), and anything a second feature uses moves to `NotchUI/Components`.
