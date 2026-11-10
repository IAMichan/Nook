# Shared UI Components (macOS)

The notch, the Workspace, and Settings share one visual language. Before writing a view modifier chain by hand, check
whether one of the building blocks below already does it; when a pattern shows up a third time, add it here instead of
copying it again.

## Theme — `apps/macos/NotchUI/Theme/NookTheme.swift`

| Token / helper | Use |
| --- | --- |
| `NookTheme.paper`, `textStrong`, `textSecondary`, `textTertiary`, `textMuted`, `ink` | Text colors, from brightest to most muted |
| `NookTheme.canvas`, `surface`, `field`, `well`, `smoke`, `graphite` | Surfaces: the window canvas, a lifted sidebar or menu, a text field, a sunken code well, and the two card fills |
| `NookTheme.line`, `line2`, `hairline`, `border`, `fieldStroke`, `separator` | Hairlines and strokes; `border` is the line between a window's columns and panels (`NookDivider`), `separator` the clearer line between the items of a list |
| `NookTheme.blue` | Links, renamed files, and diff hunk headers |
| `NookTheme.mint`, `amber`, `coral`, `violet`, `iris` | State: done, waiting on you, error, merged, Nook itself |
| `NookTheme.Syntax.keyword`, `string`, `comment`, `number`, `type`, `property`, `tag`, `attribute` | Syntax colors of code in a diff (`DiffText`, via `DiffSyntaxStyle`) and in the file viewer (`FileViewer`), muted under the diff's own tints; each has a dark and a light value. Only for code, never for state |
| `NookTheme.rowRest`, `rowHover`, `rowSelected`, `rowFill(selected:hovering:rest:)` | List rows and cards at rest, under the pointer, and selected |
| `NookTheme.TextStyle.caption`, `detail`, `label`, `body`, `strong`, `title`, `heading`, `display`, `code` | The type scale: the same kind of text is the same size everywhere. `detail` is the line under a title (a setting's explanation, a hint, an error); `heading` heads a sheet or a setup step. Never SwiftUI's own `.caption`, `.callout`, or `.headline` |
| `NookTheme.font(_:_:)`, `mono(_:_:)`, `rounded(_:_:)` | A size the scale does not cover (an icon, a numeral); never `Font.system(size:)` inline |
| `NookTheme.Radius.chip`, `control`, `card`, `panel`, `sheet`, `pill` | Corner radii: 6, 8, 10, 12, 14, 20. Name the element, not the number |
| `NookTheme.Spacing.xxs … xxxl` | Padding and stack spacing on a 4 pt grid: 2, 4, 6, 8, 12, 16, 24, 32 (`xxxl` between the sections of a page) |
| `NookTheme.open`, `close`, `swap`, `hover`, `reveal`, `scroll` | Animations: opening and closing the notch, switching tabs, hover feedback, showing or hiding part of a panel (a section, a preview, a selection), and scrolling to a line. Never an inline `.easeOut(duration:)` |
| `.hoverLift(_:scale:)` | The shared hover lift of buttons and chips |

Appearance and themes (Settings › Appearance): `NookTheme`'s named colors resolve through the `NookPalette` of the theme
in effect (`NookPalette.swift`): `NookAppearanceMode` (System / Light / Dark) picks light or dark, `NookColorTheme` is a
built-in theme (the default "Nook" is the original dark look; Midnight, Paper and High contrast come with it) and
`VSCodeThemeImport` turns a VS Code color theme JSON into a `NookCustomTheme` (editor, sidebar and accent colors).
State colors keep their meaning in every theme. A file that must draw its own colors takes them from the palette or
stays on the allow-list with a reason. The notch stays dark in every theme. The tests check text contrast (WCAG AA) of
every theme in both appearances.

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

The dark theme reads calm because it uses so little: a pure grey ramp (a pure black canvas `#000000`, raised surfaces about 4–8 % lighter, no blue cast), separation by tonal steps,
faint white fills and one light grey `border` between columns instead of grey panels, and color only where it carries meaning. Calm never costs
clarity: every text color, `textTertiary` included, reads at WCAG AA (4.5:1 or more) on every surface up to `smoke`,
and a selected row stands a full step above a hovered one. In practice:

- **Color means state, nothing else.** A status mark and its word, an error, a diff's `+`/`−` in the diff itself, and
  links (`NookTheme.blue`, no underline). Headers, composer controls, menus, bubbles, tool rows and counters stay grey.
  An agent's brand color lives in its logo only, and a row's logo is grey until the pointer is on the row or it is
  selected (`AgentMark(quiet:)`). The composer keeps Nook's own quiet tint for every agent.
- **Show at rest only what you use most.** Row actions, message actions, a tool row's chevron,
  and the panel header's rarer buttons (talk, the window) appear under the pointer. A finished turn is folded
  into "Worked for …"; a thought shows two lines; a successful step has no mark (only a failure does).
- **Lists are a sidebar, not a stack of cards.** A row has no fill at rest (`rowFill(…, rest: .clear)`); only the
  row under the pointer and the selected one lift. A session row reads as a thread in t3code (`AgentListRow`): the
  folder with the status or time, the name, and a line with the branch (a worktree's with its own mark), the changes
  (`+12 −3`, or the changed files) and the pull request, with the agent's logo at its end. Under a project's header the
  folder line goes, the name lines up with the project's name, and the second line shows only when there is a branch, a
  change or a pull request; without one the row is 36 pt and the logo stands beside the status. The status's mark and
  word both wear its color, and Snoozed and Settled are shelves docked at the list's foot, kept folded or open. Model, machine and the first prompt are in the hover card.
- **No boxes around groups.** Toolbar groups (`.toolbarGroup()`) and the composer's choices have no fill or stroke of
  their own; a gap separates them (`ComposerDivider`), and a button gets a fill only under the pointer. Badges in a
  row (`RowBadgeBackground`) have no fill: a mark and a word. A card that reports a problem (recovery, an error, a
  usage limit) stands on `surface`; only its symbol carries the state color.
- **One reading column.** A conversation and its composer are one centered column of at most 736 pt
  (`.chatColumn()`, `PanelLayout.chatColumn`), so lines stay readable in a wide window. Beside a session's panels it
  is centered in the room they leave, with the same margin on both sides (`PanelSplit.columnStart`). `SessionComposer` keeps to
  that column by itself, so every chat with an agent or with Nook gets the same composer: a `Radius.composer` box on
  `surface` with a hairline outline and a faint light on its top edge, the text 16 pt in, the choices inside the box on
  one row with the round send button, 8 pt from the corner. Only a notch card keeps its choices in a tray under the box. Your own message is a soft
  `NookTheme.bubble` with `Radius.bubble` and no edge; the agent's answer has no bubble, its running text in
  `textStrong` (a step under the headings in `paper`) with relaxed line spacing.
- **One answer from Nook.** Nook's answer reads the same in the Nook chat and in the notch's card for a question asked
  with Double Tap or from a notice (`NotchUI/Components/NookAnswer.swift`): `NookAnswerView` draws its Markdown, the
  card's `CardDetail.answer` shows it in the title's place, and `.answerReferences(_:)` turns its `[2]` into a small grey
  raised number that opens source 2 (a chat opens in the Chats tab) and names it on hover. The cited sources are
  `AnswerSourceChips`, and what Nook can do next is `AnswerOfferChips` in both places. Never draw an answer's text as a
  plain `Text` or build another offer chip.
- **One message component.** Every conversation (the Nook chat, a session Nook runs, an agent's own transcript, and
  the iPhone's chat and transcripts) draws its messages with `TranscriptUserMessage` and `TranscriptReply`: the same
  14 pt text, the same `TranscriptStyle.turnGap` above each of your messages, and the same footer (time and copy, plus
  an answer's own actions such as try again) on hover. The work between the messages is one set of views too
  (`TranscriptWork.swift`), whether Nook runs the session or it comes from the agent's own transcript. In an agent's conversation, one Nook runs or one from its own
  transcript, only the final answer of a turn has the footer, the turn's changed files sit inside that answer above
  it, and the newest answer's options can be clicked. Never draw a message bubble or an answer of your own.
- **Shared with the iPhone.** Nook Companion on the iPhone is the same design, not a copy of it. It compiles
  `NotchUI/Theme/NookTheme.swift` (as `Theme` there) and everything in `apps/macos/NotchUI/Shared`, which the Mac compiles
  with the rest of `NotchUI` (`apps/ios/project.yml`):
  - the theme: every color, radius, spacing and animation is the Mac's exactly; the type scale is the Mac's a step
    larger and on Dynamic Type (`NookTheme.textFont`, `phoneTextScale`), so both apps keep the same proportions;
  - buttons (`ButtonParts.swift`: `NookPrimaryButton`, `NookGhostButton`, `NookIconButton`), a notification's actions
    (`NookNoticeActions.swift`: `NookSplitButton`, `NookNoticeAction`, `NookMoreMenu`);
  - list parts (`PanelParts.swift`: `NookCountBadge`, `NookSectionLabel`, `NookShelfHeader`, `NookFilterChip`,
    `NookDivider`, `NookRowSeparator`, `.panelCard()`, `AdaptiveActionRow`, `WSEmptyState`, `StatusBadgeLabel`,
    `RowBadgeBackground`), `ListEmptyNote` and `.cardBackground`;
  - agents (`AgentLogo.swift`: `AgentLogo`, `AgentMark`, `AccountBadge`; `AgentRowParts.swift`: `AgentRowLayout`,
    `AgentRowTitle`, `AgentRowBranch`, the three lines of a session's row);
  - conversations (`ChatParts.swift`: `ChatListRowContent`, `ChatBubbleShape`, `ChatDayDivider`, `ChatQuote`,
    `MessageTicks`, `MessageTicksMark`, `ChatTypingBubble`, `ChatPersonTint`, `ChatInitialsFace`;
    `TranscriptParts.swift`: `TranscriptStyle`, `TranscriptUserBubble`, `.transcriptFolded`, `TranscriptTime`).

  They take everything from `NookTheme` and differ per platform only through `SharedMetrics` (a finger-sized row and
  button, the phone's narrower bubble inset) and `#if os(macOS)` where the platform asks for it (hover on the Mac). Texts
  go through `sharedText(key, english)`: the Mac's `tr` key, the phone's string catalog (add the phone's translations to
  `apps/ios/NookCompanion/Localizable.xcstrings`). The iPhone builds its screens from them; what is only the phone's
  (`ThemeViews.swift`, `PanelComponents.swift`, `MessageViews.swift`) wraps a shared part and draws as its Mac
  counterpart. Change a shared part once and both apps follow. Never copy one of them into an app; when the phone needs a
  part the Mac has inline, move it to `Shared` and use it from both.

## Keeping it one design

Nook has one visual language, and the repository guards it in three places:

1. **`UIConsistencyTests`** (`apps/macos/Tests/NookTests/UIConsistencyTests.swift`) reads every source under `NotchUI`
   and `App` and fails when a view uses `Font.system(size:)` inline, one of SwiftUI's own text styles (`.caption`,
   `.callout`, `.headline`, `.system(.body)`), a literal `Color(hex:)` / `Color(red:)` / `NSColor(white:)`, a system
   state or text color (`.red`, `.orange`, `.green`, `.secondary`), or a corner radius written as a number from the scale. It runs with the Xcode tests and with
   `./scripts/core-tests.sh`.
   It also fails when a search field or a 1 pt divider is built inline instead of with `NookSearchField` or
   `NookDivider`, so these look and behave the same everywhere, and when a pull request icon is named or sized by hand
   (`arrow.triangle.pull`, a `PullRequestStateGlyph` outside `PullRequestIcons.swift`) instead of through `PullRequestIcon`.
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
  cursor) stops with Reduce Motion. Anything that loops for long (a pulse, a halo, a spinner, a shimmer, dots, a symbol) is a
  `LayerLoop`, `ShimmerLayer`, `LayerLevelBars`, or `LayerSymbol` at an `EnergyPlan` rate: Core Animation draws it, and the
  main thread does nothing per frame. Never `repeatForever` or `.symbolEffect`, which run at the display's own rate and
  redraw the whole window on every frame. Only what follows live input (Nook himself, voice levels) is a `TimelineView(.nookFrames(fps:paused:))`.
- One layout: the notch, the main window, and a sheet show the same `PanelView`; Settings is the one place for
  configuration. A new task opens inside the panel, not in a new window with its own layout.
- The buttons at the bottom of a notification are always a `NookNoticeActions` row, never loose buttons.
- A short notice (a strip under the notch, a note in the panel's bar, a toast) is always a `NookNotice`: mark, message,
  its own actions, and, when it closes by itself, the OK with its countdown ring. A card with an OK and the compact
  agent notice in the notch's row end in the same `NookNoticeEnd`; never place a `NookAcknowledgeButton` by hand.
  Two families, one rule: a notice that closes by itself has its actions in a `NookActionBar` and the OK with its ring
  (`NookNoticeEnd`); one that waits for you (an approval, a question) asks with `NookNoticeActions` and has no OK. Its time runs on a `NoticeClock`, so
  the ring and the notice hold together while the pointer is on it. A notice that waits for you has no OK.
- A coding agent's notice is an `AgentStatusNotice` handed to `AppModel.deliverAgentNotice`, for every agent alike: the card
  shows the agent's logo (`NookCard.agent`), what the session is about as its title and the last reply as a quiet
  `.summary` under it; the strip shows the logo with its state as a badge (`NoticeMark`). Never build an agent's card
  or strip by hand.
- A notification card says its state in `NookCard.status` (a tinted pill at the end of its header, colored by its
  `DoneTone`) and an agent's changed lines in `NookCard.changes`; its `context` keeps only who and where.
- The result of an action is a `ToastCenter` toast, never a local notice string, banner or alert (see *Toasts*).
- Every string through `tr("key")` in all five languages, and a `.help` and accessibility label on a symbol-only control
  or menu (`ToolbarIconButton` and `NookIconButton` set both from their label).
- A destructive action asks first (`ConfirmedButton` / `.confirmDelete`) unless it can be undone; a sheet's Cancel has
  `.keyboardShortcut(.cancelAction)` and its main button `.defaultAction`.
- A key that runs a command (send, find, the command palette, a new session, undo…) is a keybinding command, offered
  with `.keyCommand` / `.keyCommands` and listed in `Keybindings.commandIDs` and `defaults`, never a hidden
  `Button("").keyboardShortcut(…)` or an `onKeyPress` with modifiers. That keeps it rebindable in
  `~/.nook/keybindings.json` and listed under Settings › Shortcuts (see [`KEYBINDINGS.md`](KEYBINDINGS.md)).
- A field where you write words (not a name, a path or a search) gets `@` through `.mentions` and `MentionSuggestions`.
- A search is a `NookSearchField`, a list's title row a `PanelListHeader` (with `PanelNewButton` when it starts
  something), a group's name a `NookSectionLabel`, a count a `NookCountBadge`, a line a `NookDivider` (between the items of a list a `NookRowSeparator`), and a notice in a
  tab a `PanelNoticeBar` (`floating:` for what waits for you over the panel's bottom edge; toasts sit top right). Change one of these and every tab follows.
- Empty: `WSEmptyState` for a whole panel, `ListEmptyNote` in a list. Loading: a whole panel or pane waiting for its content shows `PatientSpinner()` (nothing for the first 350 ms, so a quick load never flashes a spinner; show what was read last time while reading again where you can); a button or a row that is busy shows `ProgressView().controlSize(.small)`.
  Errors: `coralSoft` text, or a `.cardBackground` notice on `surface` with a coral symbol and a retry.

## Toasts — the result of what you did

`ToastCenter.shared` is the one way to report a short result, on the Mac and (as `toast` in `src/lib/toast.svelte.ts`) in
the Tauri app. Use it whenever an action ends and its own view does not stay to show how it went.

- **Where it shows:** in the top-right corner, under the header, at most 360 pt wide, sliding in from the right (as in
  the Tauri app). Up to three show at once as a stack (`NookToastStack`): the newest in front, the older ones a step
  smaller peeking out under it, spread out into a column while the pointer is on the stack; more wait their turn. On one surface with `.nookToastHost()` (the panel in the notch and the main window, Settings): the
  key window's, else the one opened last. With none on screen, the notch shows it in its confirmation strip
  (`NotchViewModel.showToast`), but never over a card or a question that waits for you. A new window gets
  `.nookToastHost()` once, at its root. What waits for you on that surface (a permission request, an agent's question)
  floats over the bottom edge instead, just above the composer, through `.nookToastHost { … }` and
  `PanelNoticeBar(floating: true)`.
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
| `NookPrimaryButton`, `SmallPrimaryButton`, `NookGhostButton`, `SmallGhostButton` | `Shared/ButtonParts.swift` (`SmallPrimaryButton`, `SmallGhostButton`: `NookButtons.swift`) | Text buttons on cards, in chat, and in the panel's own forms (optional SF Symbol before the title). They dim by themselves when `.disabled`; do not add an `.opacity` for it. Inside the panel use these, not `.borderedProminent` |
| `ProjectIconView` | `ProjectIconView.swift` | A project's icon wherever projects are listed (composer menu via `DropdownRow(projectIcon:)`, session list headers, Settings › Projects): emoji, monogram on a named tint, or an image, else the folder symbol |
| `NookNotice`, `NookNoticeEnd`, `NoticeClock` | `NookNotice.swift` | The one shape of every short notice: the strips under the notch (result, suggestion, moment), `PanelNoticeBar` and the toast. Mark, message and line, its actions, and with `countdown` the OK with its ring. `NookNoticeEnd` is that end (actions + OK with ring) on its own, shared by `NookNotice`, the compact agent notice in the notch's row and a card with an OK; `NoticeClock` runs the same time out and holds while the pointer is on the notice |
| `NoticeMark` | `NookNotice.swift` | The mark at the start of a notice: its state's symbol in the state color, or for a coding agent its `AgentLogo` with the state as a small badge on the corner. `NookNotice` draws it (pass `agent:`), and so does the compact agent notice in the notch's row; never draw a notice's mark by hand |
| `TranscriptUserMessage`, `TranscriptReply`, `TranscriptMessageFooter`, `TranscriptTime`, `TranscriptStyle` | `TranscriptMessage.swift` | The messages of every conversation: yours as a bubble on the right (pictures above it, a long one folded, a steer mark, and with `onEdit` an "Edit from here" pencil in its hover footer), the answer as Markdown on the left with what came with it in `extras` (a chart, a mail, a turn's changed files) and its own `actions` in the hover footer. Used by `ChatMessageView` (Nook chat), `EventRow` (a session Nook runs) and `TranscriptConversation` (an agent's transcript); `TranscriptStyle`, `TranscriptUserBubble` and `TranscriptTime` are in `NotchUI/Shared/TranscriptParts.swift`, and the iPhone builds the same two views on them in `MessageViews.swift` |
| `TranscriptPromptRail` | `TranscriptTimeline.swift` | The marks of your messages on the leading edge of a conversation, always in sight: one short mark per message (`PromptMark`), in order and the same distance apart however far apart the messages are, the stack centered on the edge; when more marks than fit, the newest show. A click jumps to the message, hovering shows the prompt. There is no scroll bar or thumb: the scroll view hides its indicators and scrolls on its own. Used by `TranscriptConversation` (an agent's transcript), `AgentRunPanel` (a session Nook runs) and the Nook chat (`NookChatView`); never build a second minimap or show the system scroll bar beside a transcript |
| `TranscriptWorkLine`, `TranscriptThought`, `TranscriptStepDetail`, `TranscriptWorkGroup`, `TranscriptFold`, `TranscriptFoldLine`, `TranscriptWorkingLine`, `TranscriptLiveLine`, `TranscriptStepText`, `TranscriptSymbols` | `TranscriptWork.swift` | The agent's work between the messages, the same in a session Nook runs (`EventRow`, `ToolRow`, `TimelineBlockView`) and in an agent's own transcript (`TranscriptConversation`): a step as a verb and what it was done to, a thought's headline, steps in a row behind one sentence, a finished turn folded under "Worked for …", "Working for …" under your message and the live line at the end. A `RunEvent` becomes a step with `AgentToolStep(event:)` |
| `NookAcknowledgeButton`, `CountdownRing` | `NookButtons.swift` | The white "OK" that closes a notice at once, with a ring counting down until it closes by itself (card `acknowledge` + `countdown`, compact strip) |
| `NookActionBar` | `NookButtons.swift` | A notice's own actions (`NookNoticeAction`) in one dark bar with thin dividers, next to its OK; drawn by `NookNoticeEnd`, never placed by hand |
| `NookNoticeActions`, `NookNoticeAction` | `Shared/NookNoticeActions.swift` | The button row at the bottom of every notification (cards, approvals, questions, panel notices): main action and its "not now" in one pill (`NookSplitButton`), muted extras, rarer actions in a "…" menu (`NookMoreMenu`), optional mic. Use it for any new notification instead of loose buttons |
| `ToastCenter`, `NookToastView`, `NookToastStack`, `.nookToastHost()` | `NookToast.swift` | The one toast for the result of something you did (saved, pushed, failed): `ToastCenter.shared.success(…)`, `.error(…)` (also takes an `Error`, under a title that says what failed), `.warning(…)`, `.info(…)`, with at most one `NookToastAction`. See *Toasts* above |
| `NookSearchField` | `PanelBlocks.swift` | The one search field (panel lists, Settings rows, menus, the command palette): magnifying glass, text, a clear button, Escape clears and then calls `onEscape`. `panel`, `inline` (in a Settings form or a menu) and `large` (a palette). Never build a search field by hand |
| `.focusOnAppear(_:)` | `PanelBlocks.swift` | Puts the keyboard in a palette's field as it opens (⌘K search, the command palette), also when it appears with a transition or the panel takes the keyboard later. Use it instead of `.onAppear { focused = true }` on a field that must take typing at once |
| `QRCodeView`, `QRCode` | `QRCode.swift` | The one QR code for a phone to scan (linking a chat app, WhatsApp, pairing the companion): crisp pixels on a light card, with a label for VoiceOver. Never draw a QR image by hand |
| `NookSearchLauncher`, `NookKeyHint` | `PanelBlocks.swift` | A button drawn as a `NookSearchField` that opens a search (the Chats tab's rail of icons, ⌘K), and a shortcut as a small key cap |
| `PanelSidebarTop`, `.panelSidebarColumn()`, `PanelSidebarToggle` | `PanelSidebar.swift` | The head of the main window's sidebar (the title bar's row, Search, the tabs) at the top of a tab's first column, the inset that column keeps from the window's edge, and the toggle that puts the Agents list away, in one spot right of the traffic lights; nothing in the notch |
| `PanelListHeader`, `PanelNewButton` | `PanelBlocks.swift` | The title row on top of every tab's list (Nook, Agents, Chats, Pull requests): name, `NookCountBadge`, the list's actions; `PanelNewButton` is the "new" in it, lit while the new one is open |
| `NookCountBadge` | `Shared/PanelParts.swift` | How many wait for you: a small amber count, on a tab in the notch or a list title |
| `PullRequestRow`, `PullRequestTag`, `PullRequestLineCounts` | `NotchUI/Pills/PullRequestRow.swift` | One pull request in a list: state mark, then the number and title, checks and review, lines changed; under it the author, repository, labels, stack position, age, with its quick actions. In a session's own list (`linked:`) it indents by its place in a chain, shows the branches instead of the labels, and has a ⋯ menu under the pointer. The Pull requests page and the side panel's picker both draw their rows with it; never build a second pull request row. `PullRequestLineCounts` is the "+120 −8" of a row, the pull request page's header and a changed file: grouped numbers and a real minus sign, never drawn by hand |
| `PullRequestDetailView` and its tabs | `NotchUI/Pills/PullRequestDetailView*.swift`, `PullRequestDetailParts.swift` | The pull request page. The main file holds its state, the top (crumbs, title, branches), the tab bar and the page that scrolls; each tab is an extension in its own file (`+Summary`, `+Guide`, `+Timeline`, `+Code`), merging and the stack are in `+Merge`. The small pieces they share (`PullRequestSummarySection`, `PullRequestHoverRow`, `PullRequestTimelineRail`, the loading ghosts …) are in `PullRequestDetailParts.swift`. A new part of the page goes in the file of the tab it belongs to. Responsive: beside the list it takes the room it has, filling a wide window it is one centered column of `PullRequestDetailView.pageWidth` (960 pt, `.pullRequestPageColumn()`, inside the scroll view so the wheel works beside it); where a line does not fit a narrow panel (the tab bar with what the tab holds, a file's header, a comment's emoji) it moves its second half to a line of its own with `ViewThatFits` instead of cutting it off |
| `SidePanelPullRequestPicker` | `NotchUI/Pills/SidePanelPullRequestPicker.swift` | The side panel's Pull request tab before one is open: the session's own pull requests from `PullRequestSync.linked` (`LinkedPullRequests`: its branches and the ones you linked, chains indented), then the rest of your pull requests, with a footer that counts them and links another |
| `PullRequestCodeTab`, `PullRequestConversationRow`, `PullRequestInlineEditor`, `SessionPullRequestRow` | `PullRequestDetailView+Code.swift`, `PullRequestConversationView.swift`, `SessionPullRequestRow.swift` | The Code tab on `StackedDiffList` with line comments that wait for the review; one conversation with its reply, resolve, edit and emoji controls (from `\.pullRequestCommentActions`); the field those write in; a session panel's compact row with its one action (`PullRequestRowAction`) |
| `PullRequestChecksStatus`, `PullRequestBreakdownCard`, `PullRequestEditableLine` | `NotchUI/Pills/PullRequestChecksStatus.swift` | The pull request page's checks in the tab bar with their popover, the hover that splits the changed lines by kind of file (`PullRequestChangeBreakdown`), and a pencil beside what can be edited in place |
| `PullRequestFilterStore` | `PullRequestFilter.swift` | The one search and Filters of every pull request list, kept across launches; the page and the side panel's picker bind to it, so a filter set in one applies in the other |
| `PullRequestSearchBar` | `PullRequestFilterMenu.swift` | The search and Filters of a pull request list: search field (takes `label:bug`), an optional middle (Sort), and `PullRequestFilterMenu`. Open by default; the Filters show closed and merged. The Pull requests page and the side panel's picker both use it; never build a second pull request filter |
| `NookFilterChip` | `Shared/PanelParts.swift` | One chip in a row of filters ("All", "Sessions 4"): a quiet capsule, filled with the accent when chosen, with an optional count and an optional `mark` (the state of what it stands for, shown only while it runs or when it failed, as on the Actions page's workflow chips). Search everything uses it for its kinds |
| `NookSectionLabel` | `Shared/PanelParts.swift` | A group's name in a list or on a page ("Pinned", "For you"), lined up with the rows under it |
| `NookDivider` | `Shared/PanelParts.swift` | The one line between rows or regions, horizontal (with an `inset`) or `vertical` |
| `NookRowSeparator` | `Shared/PanelParts.swift` | The clearer line between the items of a list (the Chats tab), in `NookTheme.separator`; placed before every item but the first |
| `PanelNoticeBar` | `PanelBlocks.swift` | A `NookNotice` in a tab, or with `floating` in the toast's bubble over the panel's bottom edge (a permission request, an agent's question, a short note): symbol, title, a line, and its `NookNoticeActions`; `tone` tints a risky one, `countdown` adds the OK for a note that closes by itself |
| `AdaptiveActionRow` | `Shared/PanelParts.swift` | Text beside its buttons (a confirmation, a recovery card, a banner, a sheet's footer): the buttons on the right while the text keeps a readable width, on a line of their own under it in a narrow tab or split view. Use it for every such row instead of an `HStack` with a `Spacer` and buttons, which squeezes the text to a word per line |
| `ComposerUsageRing` | `ComposerRich.swift` | Among the choices of a session's composer, right after the effort: a small ring filled to the window with the least room left, with its percentage. Its popover is the account's `UsageLimitRows` and "All limits", which opens `UsageModal`. Shown from the first percent, also while the agent works, in the composers of new, running, outside and earlier sessions (`ComposerUsageRing.forAccount`), for every agent `QuotaService` has limits for |
| `UsageLimitRows`, `UsageTone`, `LimitPaceIcon` | `UsageLimitViews.swift` | One account's limits in the usage modal's layout: a small card per window (name, percentage **used** with the pace icon, a bar with the even-pace line and the reset time inside it), the full reset and the pace in the card's tooltip, amber from 75 % used and coral from 90 %. The composer's popover and Settings › Usage & costs; never draw a limit bar by hand |
| `UsageLimitsModal`, `UsageModal`, `UsageLimitPools` | `UsageLimitViews.swift` | The usage limits as a modal, never a page: per agent a card per window with what is left of the pool in large type and its pace, beside a bar with a segment per account (the pace line cut into it, what a reset gives back hatched, the account's details on click). One component for every way in: the footer's usage button bottom left, "All limits" under the composer's ring, the command palette and search open it over the panel (`UsageModal`, through `AppModel.usageModalOpen`); Settings › Usage & costs shows it as a sheet. Built on `LimitPool` |
| `ResetCreditRow` | `ResetCreditRow.swift` | An account's banked reset credits and "Use a reset" (after a confirmation), in the usage limits sheet, Settings › Usage & costs and a limited session's banner. Shows nothing for an account without credits |
| `.panelCard()` | `Shared/PanelParts.swift` | The quiet card that groups rows: field fill, panel corners, no stroke |
| `NookIconButton` | `Shared/ButtonParts.swift` | Round symbol button (mic, close, play) |
| `ToolbarIconButton` | `NookButtons.swift` | Small borderless symbol button in a panel header, a row, or under a message, with hover feedback; `width`/`height` for a tighter row, `enabled` for a dimmed one, and `selected` for a toggle that is on (a diff's display option). Never hand-roll a `.plain` button around a lone `Image` |
| `CopyIconButton`, `CopyGhostButton`, `CopiedMoment` | `NookButtons.swift` | Every copy button: the symbol turns into a checkmark (or the word into "Copied") for 1.5 s, and a second click restarts the moment. Never hand-roll a `copied` flag with `asyncAfter`; a button of another shape holds a `@StateObject CopiedMoment` |
| `.composerFocusOnAppear(_:enabled:)` | `PanelBlocks.swift` | Focuses a composer when it appears, again after the panel becomes key, without stealing focus from another text field. Use it on every composer |
| `.rowActionsBackdrop(_:)` | `NookButtons.swift` | Puts a list row's hover buttons on the row's own fill, fading in from the left, so the title runs out softly underneath them instead of colliding with them |
| `ConfirmedButton`, `.confirmDelete(_:question:detail:confirmTitle:action:)` | `ConfirmDestructive.swift` | Anything that cannot be undone (delete, remove a key, sign out, clear a history) asks first in the same dialog. `.confirmDelete` is for menu items, which cannot hold a dialog themselves |
| `PatientSpinner` | `PatientSpinner.swift` | What a panel or pane shows while its content loads: invisible for the first 350 ms, then a small spinner that fades in |
| `ListEmptyNote` | `Shared/ListEmptyNote.swift` | The one line a list shows when it is empty or has no matches; a whole empty panel is a `WSEmptyState` |
| `.cardBackground(_:stroke:radius:style:)` | `Shared/CardBackground.swift` | Rounded fill with a 1 pt stroke: field cards and tinted notices |
| `Pasteboard.copy(_:)` | `Pasteboard.swift` | Put text on the pasteboard |
| `.chatColumn()` | `PanelResize.swift` | Keeps a conversation, its composer or an agent's question to one centered column of `PanelLayout.chatColumn` (736 pt) |
| `.outside(_:spacing:)` | `PanelResize.swift` | Hangs a view just outside one edge of another without taking room from it: the scroll-to-end pill above a composer, the react and reply buttons beside a chat bubble. Use it instead of an `alignmentGuide`, which is ignored on conditional content |
| `TimelineNewDivider` | `TimelineNewDivider.swift` | The line in a session's conversation above what came in since you last looked ("New since your last visit"). Placed once as the conversation opens (`TimelineLanding.firstNew`, the visit kept in `TimelineVisitStore`); the conversation itself always opens at its end |
| `FileContextMenu`, `.sessionFileMenu(_:runID:path:)` | `FileContextMenu.swift` | The right-click menu of a session's file: open in your editor (at a line, through `WorkspaceManager.openFile`), show in Finder, copy the path or the path in the repository. Use it on every row that shows a changed file |
| `.keyCommand(_:perform:)`, `.keyCommands(_:context:enabled:priority:)`, `KeyCommandCenter` | `KeyCommands.swift` | Offers keybinding commands (`Keybindings.commandIDs`) to the panel's one key monitor while the view is in a window; `context` adds `when` flags (`paletteOpen`, `turnRunning`…), `enabled` limits it to while a field has the keyboard, `priority: -1` makes a window-wide fallback. See [`KEYBINDINGS.md`](KEYBINDINGS.md) |
| `.focusArea(_:focus:)`, `FocusAreas` | `FocusAreas.swift` | Marks a part of the window (the session list, the conversation, the composer, a side or bottom panel) for F6 / ⇧F6 and for `panelFocus` (⌘W closes a panel's tab). A part SwiftUI focuses passes `focus:`. Nothing runs until a key asks |
| `.windowKeyCommands()` | `WindowKeyCommands.swift` | The window-wide keys of `PanelView`: F6 / ⇧F6, and in a terminal ⌘W (close it) and ⌘D / ⇧⌘D (split it) |
| `CommandHoldMonitor` | `CommandHoldHint.swift` | ⌘ held alone for 200 ms, for a list's ⌘-number hints (`NookKeyHint` in the row's right slot, as the Agents list does); start it when the list appears and stop it when it goes, so no monitor runs otherwise |
| `OpenSessionActions` | `NotchUI/Pills/OpenSessionActions.swift` | What the keys and the command palette do to the open session (pin, settle, stop, rename, fork, snooze, copy, open in the editor); never repeat these per caller |
| `.onEscapeKey(enabled:perform:)` | `EscapeKey.swift` | Escape that closes what is open (a chat in the Chats tab) also when nothing in the window has the keyboard, where `onExitCommand` hears nothing; a text field being typed in keeps its own Escape |
| `.onWindowKeyDown(enabled:perform:)` | `EscapeKey.swift` | A palette's keys (Return, ↑/↓, Tab, ⌘1–9) taken in its window before the focused field sees them, so a list steers while its search field keeps the keyboard; keys an input method is composing stay the field's. Search everything uses it |
| `LayerSymbol` | `LayerLoops.swift` | An SF Symbol that pulses or turns while something runs, run by Core Animation; never `.symbolEffect`, which updates the whole window at the display rate |
| `LayerLoop`, `ShimmerLayer`, `LayerLevelBars` | `LayerLoops.swift` | Looping animations run by Core Animation (pulse, halo, spinner, wave of dots, a glow along a view's edges, shimmer over text, live level bars): no main-thread work per frame |
| `BrowserTakeoverOverlay` | `NotchUI/Workspace/BrowserTakeover.swift` | Over every web view of a browser while an agent drives it: the breathing edge glow (`LayerLoop` `.edgeGlow`) and a pill naming the agent with Stop, then Allow again. Lay it over any new place that shows a browser's page |
| `NookFrames` (`.nookFrames(fps:paused:)`) | `NookFrames.swift` | The shared clock for animations that follow live input (Nook's pose, voice levels): frames of different animations fall on one grid, so they cost one window update together |
| `Bar`, `PulseDot`, `ShimmerText`, `PullRequestPill` | `AgentIndicators.swift` | Progress bar, live dot, shimmering current step, pull request state in a row |
| `PullRequestIcon`, `PullRequestStateIcon`, `PullRequestReviewIcon`, `CheckOutcomeGlyph` | `PullRequestIcons.swift` | The one icon and color of every pull request status. `PullRequestIcon` names the symbol and tint of a state (open, draft, conflict, merged, closed, stack), a check outcome, a review (approved, changes requested, required, none, commented, dismissed), a merge blocker, and `generic` for pull requests in general (navigation, Create PR). `PullRequestStateIcon` draws a state's mark at `.inline` (12 pt: rows, pills, tabs, menus) or `.header` (16 pt); `PullRequestReviewIcon` and `CheckOutcomeGlyph` draw a review and a check. An event or action shows the mark of the state it leads to (Reopen and Ready open, Close closed, Merge merged). Colors: mint good to go, amber waits on you, coral broken (closed the softer coral), violet merged, grey nothing to do yet. Never name a pull request symbol or color by hand |
| `FileTypeGlyph` | `FileTypeGlyph.swift` | The small colored symbol for a kind of file, as an editor's file tree shows it (a React atom for `.tsx`, braces for `.json`, `#` for CSS, a terminal for a shell script, the Swift bird). An agent's answer (`SelectableProse`) sets it before every file link; use it wherever a file is named by its kind rather than its Finder icon (`FileIcons`) |
| `NookSymbol` | `NookSymbol.swift` | A symbol by name: an SF Symbol, or Nook's own pull request mark (`nook.pr.<state>`, from `PullRequestIcon.symbol`). Views that take a symbol name (`DropdownRow`, palettes, side panel launchers, the timeline) draw it through this, so a pull request mark works there too; never `arrow.triangle.pull`, `arrow.triangle.merge` or a warning triangle for a pull request |
| `CICheckLogView` | `CICheckLog.swift` | One CI check read in Nook: its outcome and name, the steps of its GitHub Actions job in a short list of their own and the end of its log (followed while the job runs), in colour (errors coral, warnings amber, group names bold) and wrapped to the width, opening on the errors and warnings when there are any, with Copy log and the check's own page. The CI popover of a watched pull request, the checks on a pull request's Summary and a job on the Actions page show it (a job passes `repository:` instead of `pullRequest:`); never send a check with a log to GitHub |
| `ActionsRepoBar`, `ActionsRepoTab`, `ActionsRepoPicker` | `NotchUI/Pills/ActionsRepoBar.swift` | The repositories on top of the Actions page, as tabs that keep their order: the owner's picture, the name (with the owner when two tabs share it), a `CheckOutcomeGlyph` only while something runs or a workflow's newest run failed (`WorkflowRepoStatus`), × under the pointer, and ⇧⌘[ / ⇧⌘] to step through them. The "+" at the end is a `ComposerDropdown` with a `DropdownSearch` over every repository the page knows, Return opening the first match or a typed "owner/repo". The Tauri app has the same in `RepoTabs.svelte` and `RepoPicker.svelte` |
| `WorkflowRunRow`, `WorkflowRunGhostList`, `WorkflowRunDetail`, `WorkflowRunWords` | `NotchUI/Pills/ActionsPanel.swift`, `WorkflowRunDetail.swift` | A repository's GitHub Actions on the Actions page (Agents › the play icon under the list): one run in a list (its mark, what it is about, workflow and number, branch, what started it, who, and its status line with clock), and one run opened with its jobs, re-run and cancel. A finished run without jobs has no log on GitHub, so in place of its jobs it says why (`WorkflowRunNoJobs`): the newer run of the same workflow and branch that replaced it (with a button to it), a workflow file GitHub could not start (with a link to the file at that commit), skipped, or waiting for approval; the Tauri app shows the same from `noJobs` in `RunView.svelte`. A run and a job show their state as a `PullRequestCheck` (`WorkflowRun.check`, `WorkflowJob.check`), so they use `CheckOutcomeGlyph` and `CICheckStatusText` like a check on a pull request; never draw a run's status by hand. While the first runs or jobs load, the page shows their shape (`WorkflowRunGhostList`, built from `PullRequestGhostBar`) instead of a spinner |
| `ComposerInbox`, `SessionContextTarget`, `SessionFixButton` | `NotchUI/Components/SessionContext.swift` | The one way from the side panel to the composer of the session beside it, for every agent: `ComposerInbox.shared.add(text, to:)` puts text from `SessionPrompts` in the draft, to read before sending; it never sends. `sessionContextTarget` is nil outside a session, so a view offers the action only where it can land. Never write to a composer from a panel any other way |
| `PullRequestDescription` | `NotchUI/Components/SessionContext.swift` | A pull request's description with its task boxes as controls (`MarkdownTasks`); ticking one is an edit, so it goes through the page's confirmation |
| `MathView` | `NotchUI/Chat/MathView.swift` | `$…$`, `$$…$$` and ```` ```math ```` in answers and Markdown previews as typeset math, from the KaTeX in `Resources/katex` (offline, no CDN; loaded only when a message holds math, and not while an unclosed formula is still streaming). Detection and escaping are `MathText` (`Brain/MathText.swift`); dollar amounts and code stay text |
| `CodeRenderView`, `MermaidPage` | `NotchUI/Chat/CodeRender.swift`, `Services/Workspace/MermaidPage.swift` | HTML, SVG or Mermaid as what it draws, in chat code blocks and for `.mmd` files in `FileViewer`. Mermaid uses the script in `Resources/mermaid`, under a policy that lets the page reach nothing; never load it from a CDN |
| `PullRequestMergeStatusLabel` | `AgentIndicators.swift` | Whether a pull request can be merged (`PullRequestMergeStatus`, "Ready to merge", "Checks failing", "Merged") as its mark and word in the state's color, without a fill. The merge bar at the top of the pull request page shows it beside the main action |
| `PullRequestStateBadge` | `AgentIndicators.swift` | The same mark and word in a quiet `smoke` pill, optionally after the number in grey (watched pull request, hover card); never draw the state by hand |
| `PullRequestLiveStateBadge` | `AgentIndicators.swift` | The same badge for a pull request link, kept current from `PullRequestStatusStore` (the one status the row badges, the composer tray and the pull request page share); use it wherever a pull request's state shows outside its own page |
| `LabelChip`, `LabelDot` | `PullRequestMarks.swift` | A pull request label: a dot in the label's own GitHub color (`Color(hexString:)`) and its name in an outlined capsule, with an optional "+2". List rows, the pull request Summary, and the Labels filter |
| `PullRequestCommentCard`, `PullRequestConversationList` | `NotchUI/Pills/PullRequestConversationView.swift` | A pull request comment or review as a card (author, verdict pill, reactions and time in a header strip, the file and line with **Outdated**, the text) on the Summary and the Timeline; the Summary's conversation of threads with their replies, folded resolved threads, its filter and paging (`PullRequestConversation`). Never draw a pull request comment by hand |
| `GitHubAvatar` | `PullRequestMarks.swift` | A GitHub account's picture by login, its initials (`ChatPersonBadge`) until it loads or for a bot. Pull request rows, reviewers, comments, the Author filter |
| `ChipFlow` | `PullRequestMarks.swift` | A `Layout` that wraps chips onto as many rows as the width needs (a pull request's labels) |
| `PullRequestFreshness` | `NotchUI/Pills/PullRequestsPanel.swift` | "Updated 20 s ago": how fresh a pull request list or page is, ticking along; next to its refresh button |
| `AgentStatusBadge`, `RowBadgeBackground`, `SteppedPulseDot` | `StatusStyleView.swift` (its layout `StatusBadgeLabel` and `RowBadgeBackground`: `Shared/PanelParts.swift`) | Session state in rows |
| `HoverCard`, `.hoverCard(_:)`, `HoverCardButton` | `HoverCard.swift` | Detail popover on hover. It stays while the pointer is on the view or on the card, and a moment after, so what it holds can be clicked; `HoverCardButton` is such a line, and a click on it closes the card |
| `.detailCard(onDetail:_:)`, `RowChangesCard`, `RowPullRequestCard` | `HoverCard.swift`, `RowDetailCards.swift` | A part of a row with its own hover card (a session row's changed files, its pull request badge); the row holds its own card back while the pointer is on that part. `RowPullRequestCard` takes a `SessionPullRequests`: it counts the requests (and the merged ones) when there is more than one, lists those of earlier branches and worktrees under their own heading, and each opens beside its session. A file in `RowChangesCard` opens in the session's Changes tab |
| `DropdownHeader`, `DropdownRow`, `DropdownDivider`, `ComposerDropdown` | `ComposerDropdown.swift` | Menus of the composer and pickers; `DropdownRow(favorite:)` adds a favorite star (the model menus) |
| `ModelPickerDropdown`, `ModelPicker` | `ModelPicker.swift` | The one model picker, drawn the same everywhere: the agents' (`AgentModelPicker`: a new session, a running one, a conversation continued in Nook) and Nook's own brain in the chat (`BrainChip`). One width, a rail of places (this Mac's local models first, set apart, where the caller can run them; then an agent or service per logo, once per account when it has several, its badge telling them apart) with a "+" that opens Settings, and a column with the place's name, an optional line (the account, or what "On your Mac" means), rows above the search (several models), the search, the models (`ModelPickerItem`: logo, star, "New", a disabled reason) and actions (a model typed in the search, fetch models), and a Settings link. Callers hand over `ModelPickerPlace`s and a `ModelPickerList` per place; never build a second model menu |
| `NookAccessMenu` | `NookAccessMenu.swift` | What Nook may do by itself (`NookAccess`: Ask first, Small things right away, More by itself) as a choice in a composer, the Nook chat's and the Double Tap field's counterpart of an agent's access menu; ⇧Tab (`composer.access`) moves to the next level while its composer has the keyboard. Next to `BrainChip` wherever you write to Nook |
| `.conversationCard()` | `Shared/CardBackground.swift` | A card in a conversation (plan, question, task list, subagent): the field fill, a hairline and `Radius.conversationCard`. State shows in its marks, not in a tinted edge. Approvals (`ApprovalView(inline: true)`) and errors (`TimelineProblemCard`) are rows of the timeline instead, lined up with the work lines. |
| `.composerDrop(of:_:perform:)`, `ComposerDrop`, `ComposerDropSlot` | `ImageAttachment.swift` | Dragging a file, folder or picture over a composer opens the row above its text with an empty dashed place the size of the tile it becomes, in every composer (agent, Nook, an agent's question, a chat app). `.composerDrop` is `onDrop` plus that state: it also keeps the row open while what was dropped is being read, so the box does not shrink and grow again. Put it on a view that holds the row as well as the field; when the row opens the field moves, and the pointer must stay inside the drop area or the row closes again. `ImageAttachmentStrip(dropSlot:)` draws the place after the tiles |
| `ComposerTray`, `ComposerTrayDivider` | `ComposerTray.swift` | The tray tucked behind the composer box: under it for a new session (folder and branch), above it for a running one (watched pull request, queued messages). Anything that belongs to the next message goes in here instead of a loose strip. `SessionComposer.choicesBelowBox()` puts the agent, model and mode choices in such a tray, so the box stays one line (the chat of a running session uses it) |
| `ComposerErrorLine` | `ComposerTray.swift` | Why the last thing done at a composer failed (a file the Nook chat could not read, an agent action that did not go through): a coral line right by that box, with an optional close button. Use it instead of an error card in the notch for a problem that belongs to the box |
| `ComposerFieldStyle`, `ComposerMarkdownStyle` | `Components/ComposerFieldStyle.swift`, `Services/Workspace/ComposerMarkdownStyle.swift` | Markdown styled in the session composer as you type (bold, italic, inline code, headings, lists, task lists, code fences; Settings › Appearance turns it off). The text sent stays plain Markdown; Tab and Shift+Tab nest list items (`ComposerLists.nest`). Huge drafts stay plain |
| `ComposerQuoteChips` | `ComposerQuoteChips.swift` | Passages of an answer picked for the next message (right-click › Quote in Your Message / Ask About This on a selection, or ⇧⌘L / ⌘L), as removable chips in the `ComposerTray` above the box; they go out as Markdown quotes in front of what you type (`ComposerQuotes`). A pencil on a chip adds your own note, sent under its quote; a click on the chip scrolls the timeline back to the answer it came from |
| `SelectionAskBar`, `SelectionAskCard`, `SelectionAskRoot` | `SelectionAsk/SelectionAskViews.swift` | The bar above words selected anywhere in Nook (Ask Nook, Explain, Translate, Quote; with Selection Ask off, only the floating Quote over words of a session's answer) and the card with Nook's answer under them, with the chat's own `ChatMessageView` and a `SessionComposer` for a follow-up; shown by `SelectionAskController` in a child panel of the window. Never build a second "ask about this" popover |
| `.mentions(_:text:config:)`, `MentionSuggestions`, `ComposerConfig.mentions(folder:)` | `MentionField.swift` | `@` in any field where you write words (a follow-up, a prompt, a mail, a commit message): `.mentions` on the text field itself, `MentionSuggestions` right above its box, both sharing a `ComposerModel` the view owns. `@` lists people from your chats and, with a folder, its files, put in as plain words. `SessionComposer` and `ChatReplyField` have the same list built in |
| `SelectionModeButton`, `.selectable(…)`, `SelectionBar` | `ListSelectionViews.swift` | Selecting several rows |
| `StackedDiffList`, `StackedDiffToolbar`, `StackedDiffFile` | `StackedDiff.swift` | Changes laid out as a stacked diff: every file in one scroll under a sticky 32 pt header (chevron in the file's color, path, copy, lines), folded at first and read when opened, a tree of the files on the right on request; the toolbar shows the total lines, how the diff is shown (without whitespace changes, without test files by `DiffFileFilter`, wrapped or scrolled sideways, one column or side by side with `DiffSplitRow`; kept across launches under `DiffDisplayKeys` and handed to `DiffText` as `DiffDisplay`), and folds every file or shows the tree. ⌘F (`chat.find`) while the pointer is over the list opens the `TimelineFindBar` and finds in every file, folded ones too (`DiffFind`): Return and Shift-Return step through the matches, each unfolds its file and scrolls to its line. The changes of a folder, of a session Nook runs and of a turn all use it; never build a file list beside a single diff |
| `TimelineProblemCard`, `CodeBlock` | `NotchUI/Workspace/RunTimelineRows.swift` | A conversation's timeline, the same for a session Nook runs and an agent's own transcript: an error or a usage limit is a `TimelineProblemCard` on `surface` (only the symbol in the state color, an error's words in soft coral), and what a tool call was given and gave back opens as `CodeBlock`s (title, copy, mono text that scrolls past 260 pt). A compaction is a quiet centered caption with room around it, no line. Never draw an error row or a tool's output by hand |
| `.sidePanel(_:width:…)`, `.fixedSidePanel(width:)`, `SidePanelHeader`, `SidePanelTitle`, `SidePanelToolbar`, `SidePanelCloseButton`, `SidePanelToggle` | `SidePanel.swift` | Every panel beside a conversation or a list: the lists of the Nook, Agents and Chats tabs, a command's terminal, the tool panel, a pull request beside its list, an artifact beside its app, and the docked session panel. `.sidePanel(.leading/.trailing, …)` gives it the drag line on the side of what it sits beside (drag to resize, double-click to reset; a line you build yourself moves its size through `PanelDrag`: a live `@State` while dragging, no animation, saved once at the end), the gap to that line; a list on the left slides in from its edge, a panel on the right opens and closes at once (put `.sidePanelsOpenAtOnce(shown)` on the row that holds it and what it sits beside, so that one takes its new width in the same frame instead of being laid out again on every frame of a slide); `.fixedSidePanel` the same line and gap without the drag. `SidePanelHeader` is its 32 pt top row (a `SidePanelTitle` or a picker, its own actions, and the close button). What a tab shows starts with one `SidePanelToolbar` under it (34 pt, the same inset, a line under it): the browser's address, the terminal's folder and its action group, the changes' counts, the local servers, a file's name; a tab with nothing to show is a `WSEmptyState`. Every panel closes with the same cross (`SidePanelCloseButton`), as a tab does; the sidebar marks (`Edge.panelSymbol`) are only for the toggles (`SidePanelToggle`: the bottom panel, the session panel and the side panel at the end of the session's header, in the order of the panels on screen, above the docked session panel while it is open, so they stay put when it opens or closes; the Agents list in `PanelSidebarToggle` beside the traffic lights, in the header only in the notch). A session has one panel on the right, at one width: a turn's diff opens in its Changes tab (`TurnDiffPanel`, with the scope picker) and a file in its File tab, and closing the panel keeps its tabs for when it opens again. The session panel is a card beside the conversation while the window has room for it, until you close it; without room, or closed, the branch button opens it. What the agent waits for (a question, an approval) takes the composer's place in every kind of session. Never give a panel its own header, line or close button |
| `TerminalDeck`, `TerminalActionBar` | `Workspace/TerminalSessions.swift` | Every place terminals show (Agents › Terminals, a session's Terminal tab, the terminal beside the chat). `TerminalDeck` fills the room with the active terminal's split (its panes side by side or stacked, equal sizes, a `NookDivider` between them, up to `TerminalStore.maxPerGroup`) and, once there are several terminals, a 150 pt list on the right grouped by split, each row's terminal mark turning into a cross under the pointer. `TerminalActionBar` is the one bordered group of buttons with a line between each (split right, split down, new terminal, close the active one after asking); it sits at the end of the terminal's `SidePanelToolbar`, never over the terminal's text. Never build terminal tabs or split buttons inline |
| `.listPanel(stacked:…)`, `PanelLayout.stacks(_:)`, `PanelBackButton` | `SidePanel.swift`, `PanelResize.swift` | A tab with a list beside a conversation (Nook, Agents, Chats) narrower than `PanelLayout.sideBySide` (split view, a small window) shows one column at a time over the whole width, as a phone does: the list, or what it opened with a `PanelBackButton` (chevron) first in its header back to the list. `.listPanel(stacked:…)` is the list's `.sidePanel` side by side and the whole width when stacked. Never squeeze a list and a conversation under their minimum widths |
| `.onLayoutWidthChange`, `.onLayoutHeightChange` | `PanelResize.swift` | How a tab or pane learns the room it has to lay out its panels (`available:` of a `.sidePanel`, `PanelLayout.stacks`): the width or height in steps of `PanelLayout.layoutStep` (8 pt), rounded down. Never measure it to the point with `onGeometryChange` into `@State`: every point of a window resize then lays the whole window out again |
| `SidePanelTabBar`, `SidePanelLauncher` | `SidePanelTabs.swift` | The side panel beside a session: small tabs that carry what they show (the page's title, a pull request's number and title) with an icon that turns into a cross under the pointer, + right after the last tab, the close button at the end; and with no tab open a short list of tools, each with the key that opens it (↑↓ and Return work too). **Pull request** (P) opens a tab that lists the pull requests to pick (`SidePanelPullRequestPicker`): the one for the session's branch first, then yours, review requests and watched ones |
| `NookTabBar` | `NookTabBar.swift` | Segmented tabs, with an optional symbol, unread dot (`fresh`) or amber count (`count`); `prominent` puts the selected tab on the accent, as in the panel header's floating capsule (tabs, search, talk, split view); `segmented` draws small tabs on a shared track, as on a pull request's page; `beside` outlines a second open tab on the accent, as split view does in the panel header |
| `ChatListRowContent` | `NotchUI/Shared/ChatParts.swift` | A chat's row in a list, on the Mac (`ChatsRow`) and the iPhone (`InboxRow`): the face, name and when, the newest message after your ticks (or who types), and where it stands at the end (`trailing`). Something new sets the name in paper and the time in amber. The caller adds the platform's click, hover and menus. Never lay out a chat row by hand |
| `ChatAttachmentReview`, `ChatAttachmentEdits`, `ChatAttachmentKindMenu` | `ChatAttachmentReview.swift` | What waits to go in a chat, big, over the conversation, with the chat's own field under it for the words that go along: a picture to crop, turn, draw and write on (`ChatImageEdit`, made into the picture that goes at the send by `ChatImageRender`), any other file in Quick Look. Several files sit as thumbnails in the row above the field: a click shows one, the arrow keys in an empty field walk the row, and the bin on the thumbnail in view (or its context menu) removes it |
| `ChatTranscript` | `ChatTranscript.swift` | A conversation as bubbles (a WhatsApp card, the Chats tab): day lines, runs per person, colored names in a group, links, media, copy menu, the message a bubble answers quoted at its top and the emoji on it underneath. Given `onReply`/`onReact`, a bubble under the pointer offers to answer it or react with an emoji. A message's ⌄ menu and its right-click menu are one `MessageMenuItems` (reply, react, forward, copy, edit, info, delete), so they always match. Never draw chat bubbles by hand |
| `NookMenuEntry`, `NookMenuItems`, `.onRightClickMenu(enabled:copiesSelection:_:)` | `RightClickMenu.swift` | One menu as a list of entries, drawn both behind a button (`Menu { NookMenuItems(entries:) }`) and on a right-click or Control-click. Use `.onRightClickMenu` instead of `.contextMenu` on anything with selectable text: that text answers a right-click with the system menu before `.contextMenu` hears it. With `copiesSelection`, words selected inside the view come first as Copy, which copies only them |
| `ChatAddressMenu` | `ChatTranscript.swift` | "Copy link" and "Copy email address" for each address in a message (`ChatFormat.addresses`), naming the address when there are several: in every chat's message menu |
| `ChatForwardPicker` | `ChatForwardPicker.swift` | Forwarding a message, over the open chat: the message quoted on top, a `NookSearchField`, every chat Nook can write in (of every app) to tick, dimmed where the chat cannot take the message's file; Forward sends through `AppModel.forwardChatMessage` |
| `ChatMarkButton`, `ChatReadMark`, `ChatTicks` | `NotchUI/Pills/ChatsSidebar.swift` | Where a chat stands (a count of what is new, one grey tick for read in Nook, two mint ticks for read in its app too) and the steps between those states: `ChatMarkButton` shows the mark the chat gets and a word ("Read", "Read in WhatsApp", "Unread"), `compact` in a row under the pointer. Never mark a chat read or unread with a lone icon |
| `EmojiBrowser` | `EmojiBrowser.swift` | Every emoji to choose from (`EmojiCatalog`, Unicode's own list): a search by English name and by Nook's own names, a tab per group, a grid per group. Behind the "+" of the reaction picker; never build an emoji grid by hand |
| `ImageModal`, `ImageModalButton` | `ImageModal.swift` | The one way a picture is shown big, in every composer (agent, Nook, a chat app, a queued message), every message to an agent or Nook and every chat: as large as the room allows, sharp once the file is read, on the `ChatMediaStage` over the window or the notch's panel (a dimmed backdrop with room around the picture); a notch card shows it over itself. A click or Escape shrinks it back, the open button shows it in Quick Look, and while it is open the keys stay out of the field behind it. Wrap a small picture in `ImageModalButton` to open it; never open a picture big by hand |
| `ChatMessageText` | `ChatMessageText.swift` | A message's text as its app shows it, the same in every chat (`ChatFormat` reads the markup): *bold*, _italic_, ~strikethrough~, `code`, code blocks in a box, quotes behind a bar, lists with their markers, links. Drawn by `ChatTranscript`; never draw a message's text by hand |
| `MailThreadView`, `MailMessageCard`, `MailThreadAction` | `MailThreadView.swift` | A mail app's conversation as mail, not bubbles (every chat of `MailChatData.apps` in the Chats tab): the subject on top, every mail a card, oldest first; the newest and the unread ones open, the rest one line (who, the start of the text, when). An open mail shows who wrote it to whom, when, its attachments and its whole text (read from Mail as it opens), with the quoted mail folded behind "Show quoted text"; under the pointer and in its right-click menu: Reply, Reply all, Forward, Open in Mail. Never draw mail as bubbles |
| `MailComposeView` | `MailComposeView.swift` | Writing a mail in the pane beside a list: From (every address of every account), To, Cc, Subject on lines of their own, the text over the rest, Send (⌘↩), Open in Mail, Discard (Escape). A new mail, an answer to everyone and a forward all use it; never build a mail form by hand |
| `MailDates` | `MailThreadView.swift` | When a mail came, as mail apps say it: the time today, the weekday this week, day and month this year, the year before that; `full` for a tooltip |
| `ChatPollView` | `ChatPollView.swift` | A poll in a chat bubble, the same for every app (`ChatPoll`): the question, each option with its share and count, your choice ticked, and "View votes" listing who chose each option where the app names them; with `onVote` a click votes, without it the poll says to vote in the app. Drawn by `ChatTranscript`; never draw a poll by hand |
| `ChatBubble(_:time:)` | `ChatMediaViews.swift` | Any chat app's message (`InboxMessage`) as a bubble, its file included. A bridge only fills `InboxMessage.media` (`ChatMedia`); every chat then shows photos, videos, GIFs, stickers and audio the same way |
| `ChatStickerView`, `ChatGIFView`, `ChatAudioView` | `ChatMediaViews.swift` | A sticker on its own (no bubble), a GIF that loops silently (a real GIF or a short video), an audio or voice message with play, progress and length. Drawn by `ChatTranscript`; never draw chat media by hand |
| `MessageTicksMark`, `MessageTicks` | `NotchUI/Shared/ChatParts.swift` | How far your own message got (clock, one grey tick, two grey, two blue, failed), in every chat app that says it (`ChatReceipt`): after a bubble's time and in front of a chat's newest message in the Chats list. Given `ChatBubble.readers`, a click on them opens `MessageInfoView`. Never draw ticks by hand |
| `MessageInfoView` | `ChatReceiptViews.swift` | Your own message's info in a group: how many read it, then who read it (with the time), who has it, and who does not yet (`ChatReceipts.everyone`). Opened from a bubble's ticks |
| `ChatReadMark`, `ChatTicks`, `ChatReadLine` | `NotchUI/Pills/ChatsSidebar.swift` | Where a chat stands, the same for every chat app (`ChatReadState`): the amber count of what is new, one grey tick for read in Nook, two mint ticks for read in the app too. `ChatReadMark` ends a row in the Chats list, `ChatReadLine` sits above a chat's answer field with the one step left (read in Nook, or *Mark as read in <app>*). Never draw a chat's read state by hand; a sent message's own ticks stay a `MessageTicksMark` |
| `ChatMembersButton`, `ChatPersonBadge` | `ChatReceiptViews.swift` | A group's people: "5 members" under a chat's name that lists them, and a person's initials on their own tint (`ChatPersonBadge.tint(for:)`, the color of their name in a group's bubbles too). Never pick a person's color by hand |
| `ChatLinkPreview` | `ChatLinkPreview.swift` | What a web address in a chat message leads to, under its text in every chat: a picture or GIF as itself, a video that plays in the bubble, a sound file with its player, any other page as a card with its picture, site and title (a play mark for a video page). Previews come from `ChatLinkPreviews` (LinkPresentation, fetched once per address) and video frames from `ChatVideoStills`. Never draw a link's preview by hand |
| `ChatBubbleShape`, `ChatDayDivider`, `ChatQuote`, `ChatTypingBubble` | `NotchUI/Shared/ChatParts.swift` | A chat app's message bubble: a rounded box (`Radius.chatBubble`) with a small tail at its top corner on the first message of a run, filled `chatMine` (yours) or `chatTheirs`. Every bubble keeps `ChatBubbleShape.tail` points of room on its side so a run lines up; the typing bubble uses it too. With it: the day between messages, the message a bubble answers (`QuotedMessage` wraps `ChatQuote`), and someone typing. Shared with the iPhone. Never draw a chat bubble's outline by hand |
| `ChatCallRow` | `ChatMediaViews.swift` | A call in a chat, the same for every app: a round mark with its kind (arrow in or out, a camera for video, a hung-up phone in coral for one you missed), what it was and who rang and how long. `ChatFormat.call` reads any app's call line into a `ChatCall`; never draw a call by hand |
| `ChatLimitsLine` | `ChatsSidebar.swift` | In the tray above the answer field of a chat Nook can only read, for every app: what is missing and one button, "Link <app>" (Settings › Chat apps) for an app Nook can link, else "Open <app>"; a cross hides it for that app |
| `ChatReplyField` | `ChatReplyField.swift` | The answer field under a chat (the Chats tab, and every full card with a field in the notch): Return sends (as Cmd+Return), Shift- or Option-Return adds a line, "@" opens the menu with "@nook" and ready-made requests, "@nook …" lets Nook write the message into the field first (it comes in a few words at a time), shown as Nook's draft in an iris panel above it: what you asked, where Nook looked (a chip per lookup in mail, chats, the calendar), Stop while it writes, go back to the request, step between Nook's versions, steer it (Shorter, Friendlier, More formal, Other words, a change typed in its own field, or a new "@nook …" typed over the draft), and what Nook proposes to do (a reminder, an event) with one Do it button (`.runsActions`), as a plan in Nook Chat. Sending stays the field's own button. The field is a soft round box whose buttons sit at its foot; the send button lights up (iris for "@nook …") once there is something to send. With `outgoing` a message on its way leaves the field for a mint panel above it (a gliding paper plane, "Sending to …" shimmering, the message), which shows a check and "Sent" for a moment once the chat has it. With `quote` it answers one message, shown above the field until sent or let go (the cross, Escape); with `onEscape`, Escape in the field with nothing to let go of closes what holds it. With `.extras(…)` it takes more than text: buttons before the text, what waits above the field, a button in place of send while nothing is typed, a bar that stands in for the field, and Cmd-V for pictures and files. Never build a chat's answer field by hand |
| `ChatComposerModel`, `ChatAttachMenu`, `ChatEmojiButton`, `ChatMicButton`, `ChatRecordingBar`, `ChatComposerPanels` | `ChatComposer.swift` | What a chat sends besides text, plugged into `ChatReplyField.extras` (the Chats tab): "+" with photos and videos, files, GIFs, stickers, audio, a poll, a location and a contact (only what the chat's app can send, `ChatOutgoing.Kind`), the emoji browser, a voice message recorded in place of the field, the files waiting to go (each with what it goes as), and the poll, place, contact and sticker panels above the field. Never build a chat's attachments by hand |
| `RemotePasswordField` | `RemotePasswordField.swift` | The password for a machine that logs in over SSH with one (Settings › Machines, the new-session composer, a session on that machine after Nook restarted): a secure field, Keep in Keychain and Unlock, checked with a real login before `RemotePasswords` keeps it (in memory for this run of Nook, or also in the Keychain vault when ticked). Never ask for an SSH password by hand |

Workspace-only blocks (`InfoRow`, `WSSectionTitle`, `StatusBadge`) live in
`NotchUI/Workspace/WorkspaceComponents.swift`; `WSEmptyState`, used by the iPhone too, is in `NotchUI/Shared/PanelParts.swift`.

## The panel — notch and main window

The main window (`WorkspaceView`) is the open notch with more room: it shows the same `PanelView` (with
`inWindow: true`, which uses `windowTab`/`windowSheet` and lets the close button close the window). Nook himself
(`PanelOrb`, with his task ring) stays in the notch; the window is the place to work and has no Nook of its own. Change the panel once and both follow; do not build a separate
window layout. In the window the header's empty space (`WindowTitleBarArea`) moves the window and zooms it on a double-click, the traffic lights replace the close
button, the window remembers its tab (and opens at an agent that waits for you), and the chat keeps a readable width
(`PanelLayout.readableChat`). In the notch, the window button continues on the same tab in the window.

In the window the tabs live in a sidebar along the left edge, as in t3code (`PanelSidebar.swift`): `PanelView` hands
the tab a `PanelSidebarContext` through the environment, and the tab's first column starts with `PanelSidebarTop`
(the title bar's row with search, talk and split view, then the tabs on one 34 pt bar: the selected one with its mark,
name and what goes on there on `rowSelected` — waiting sessions in amber or a pulse while one works, unread chats as a
`NookCountBadge`, the bars while music plays — and the others only their mark with that status as a dot on its corner,
amber for what waits for you and blue for what is busy, their name and shortcut in the tooltip) and carries `.panelSidebarColumn()`.
The window has an empty unified toolbar, so its title bar is a 52 pt row (`PanelSidebarMetrics.titleBand`) with the
traffic lights in the middle: the sidebar's column runs up into it and a session's header is centered on it. A scroll
view may draw past its top into that row, so a conversation's header stands on the canvas above it
(`.conversationHeaderBackground()`); every header of a conversation uses it. The tab's list
follows under it, with its `PanelListHeader` as a quiet section label (`sidebarTitle`; Agents instead has a `ghost` `NookSearchField`
and its buttons on one row, and back and forward beside the traffic lights), and
the `PanelFooter` at the bottom. Music has no list of its own: `PanelView` draws its column, with `MusicSidebar` (the sections and the playlists) in place of a list. The Music pages
themselves keep one grid (`MusicLayout` in `MusicTab.swift`): the header band, what scrolls and the player bar share the
same two edges; the band holds the one title (Home's greeting, a section's name) with back and the section's own
controls; tracks are flat rows (`MusicTrackRow`, `MusicTrackTile`) whose hover fill reaches past that edge
(`.musicRowBleed()`), an open playlist and the full player have no card around them, and the player bar is the
composer's box. While a tab draws the
head (`PanelSidebarShown`), the panel leaves out its floating capsule and the window its left margin and its own Nook;
when no column shows it (one column at a time, a task over the tab), the capsule comes back. Agents' list goes away
altogether: `PanelSidebarToggle` floats in one spot right of the traffic lights, with the list out or away, and a
conversation's header starts past it (`sessionHeaderInset`). A new
tab with a list starts its first column the same way; the notch never gets the context and keeps the capsule.

The header has no notice list. What Nook told you since he started is kept in the notice history (`NoticeHistory`),
which search finds, so a card that closed before you looked can still be read and opened. A new notice Nook gives by himself (an
agent that finished, a request, a message) is kept with `AppModel.logNotice` where it is decided, before the card, strip
or banner shows, so one held back by quiet mode or a busy notch is kept as well. Toasts, the results of what you did,
are not kept there.

After talk, split view (`PanelSplitButton` and `PanelSplitPane` in `NotchUI/Pills/PanelSplit.swift`) shows a
second tab (the Nook chat, Agents, Chats or Music) on the right of the current one, as a resizable `.sidePanel`. The
choice and width are remembered (`PanelSplitChoice`) and shared by the notch and the main window; the tab you are on
never shows beside itself. Show a tab beside another through it; do not build a second split.

## Settings — `apps/macos/App/Settings`

| Component | File | Use |
| --- | --- | --- |
| `SettingToggle(_:detail:isOn:)` | `SettingsBlocks.swift` | A switch with its title only; the detail shows on hover and to VoiceOver |
| `SettingLabel(_:detail:)`, `SettingLabel(_:hint:)` | `SettingsBlocks.swift` | The title of a row with a button or picker: `detail:` keeps a caption for what must be seen (a state, a step), `hint:` shows the title only with the explanation on hover |
| `StatusRow`, `Keycap` | `SettingsBlocks.swift` | Status lines (their buttons are always small, set by the row itself), keyboard keys |
| `SettingsSidebar`, `SettingsSidebarRow`, `SettingsPageBar`, `SettingsLayout` | `SettingsSidebar.swift` | The Settings window, laid out as t3code's: a 240 pt sidebar with the search on top (⌘F or /, ↑ ↓ and Return through the results) and the pages in their groups (`SettingsSection.Group`; the first and last have no heading), a 48 pt bar over the page with the breadcrumb, the page's ⓘ and its main step, and the page in a column of readable width. A page is one subject and never has tabs: a part that grows becomes a page of its own. A new page is a `SettingsSection` case in one group with a `sidebarSymbol`; never a second sidebar or header |
| `AgentName` | `SettingsStyle.swift` | A coding agent's name with its logo, everywhere Settings names one (a picker, a button, a menu, a row); never an agent's name as plain text |
| Connection sheets | `SetupSheet`, `SetupStep`, `SheetPart` | Every connection sheet has the same shape. Not linked: numbered steps from 1, the last one Nook checking the link, also when nothing has to be filled in ("Ready to add") or the app cannot be linked yet (that is step 1, in plain words). Linked: the state as a pill beside the title, then `SheetPart`s in this order: account or status, sign-in or key, "In Nook", "What Nook can do with it", and anything rarely needed folded away last. Buttons: Done alone where the steps do the work, Cancel and the step on the right for a form, disconnecting on the left. A step title never carries its own number |
| `SettingsFold` | `SettingsHighlight.swift` | A whole group of rarely needed settings, folded as t3code folds them: one row with a chevron, the group's name and on the right a summary of what is inside (the current choice, a count). A search for a setting inside opens it. Never a `DisclosureGroup` called "Advanced" inside another group: name what it holds, or make it a fold of its own |
| `SetupSheet(title:subtitle:width:)` | `SettingsStyle.swift` | Every dialog Settings opens: icon, title and one line on top, the content in the middle, and at the bottom Cancel and the one step (`.borderedProminent`, Return), or Done. A sheet that shows a file or a diff passes a larger `width`; never a dialog laid out by hand |
| `SettingText`, `.settingsAnchor(_:)`, `SettingsHighlight` | `SettingsHighlight.swift` | A setting's name that a search can land on: the page scrolls it to the middle and lights it for a moment. `SettingToggle`, `SettingLabel` and `SettingsSectionTitle` do this themselves; a plain `Toggle`, `Picker`, `LabeledContent` or section header for a setting in `SettingsSearch.index` takes `SettingText("key")` as its label |
| `SettingsSectionTitle(_:info:)`, `SettingsInfoButton` | `SettingsBlocks.swift` | A Settings section header with an optional ⓘ that holds its explanation; use it instead of an explanatory footer. A footer is only for a warning, an error, or the step that unlocks the section |
| `SettingNote(_:tone:)` | `SettingsBlocks.swift` | The one hint or status line under a setting: `info`, `success`, `warning`, `error`; a warning or error carries a symbol, not only a color |
| `SettingsLinkRow` | `SettingsBlocks.swift` | A row that leads to another page or flow: tile, title, line under it, chevron; a status symbol only when something is not done |
| `InUseLabel` | `SettingsBlocks.swift` | The mint "In use" check on the chosen model, file or key |
| `HoverActionsRow` | `SettingsBlocks.swift` | A row whose buttons show under the pointer; at rest a small symbol says its state (memory rows) |
| `SettingsTile`, `HealthPill`, `SetupStep`, `IntroCard` | `SettingsStyle.swift` | Tiles, health pills, setup steps |
| `NookStatTile` | `NookStatTile.swift` | One number with its label and a line under it, on a statistics page (autocomplete, music) |
| `ServiceRowLayout`, `ServiceStatusLabel` | `ServiceRows.swift` | The one row shape of everything linked (chat apps, services, GitLab, your own servers, the iPhone, Spotify): icon, name with state, one line, then Fix when it needs you, a switch where it has one, and Manage |
| `ServiceRowShape`, `AgentTile` | `ServiceRows.swift` | The same row with an icon of its own: the coding agents and their accounts under Settings › Agents use it with `AgentTile`, so an agent reads like any other linked thing. Never draw a status pill in a row; `HealthPill` is only for the status line of a sheet |
| `ChatAccountRow` | `ServiceRows.swift` | One account of a chat app in its sheet (WhatsApp, Telegram, Teams, Slack, Messages, Snapchat, the chat service's apps): a `ServiceRowLayout` with the app's icon |
| `ChatLinkedAccountRow` | `ServiceRows.swift` | A linked chat app's account in its sheet, built on `ChatAccountRow`, the same for every app: its state from one rule (`ChatAccountHealth`: reading, off in Nook, failing, signed out), "Sign in again" only when the sign-in is gone, and "Sign out" behind a confirmation. Never work out a chat account's state or its buttons by hand |
| `ChatAppNoticeRows`, `ChatModeList` | `ChatNoticeRuleRows.swift` | What a chat app does in Nook, the same rows in every app's sheet: shown in Chats, its new messages in the notch, the kinds of chat that stay quiet, every chat automatic/always/never or hidden (shown again one by one), and whether answering reads the chat in the app. Never build an app's notice rules by hand |
| `ConnectionCatalog`, `ConnectionOption` | `ConnectionCatalog.swift` | Everything Nook can link, built from each kind's own catalogue; a new service is added there, never as a section of its own |
| `AddConnectionSheet`, `ConnectionOptionGrid`, `ConnectionOptionTile`, `ConnectionCategoryChips` | `ConnectionCatalog.swift` | The one way to add anything: pick it (search or a group), then its steps in the same sheet. A tile shows how it links (`ConnectMethodBadge`) or that it is linked |
| `ServiceSignInSheet` | `ConnectionCatalog.swift` | A service you sign in to on its own page, in two steps, with its key as the other way |
| `SettingsFormSheet`, `IPhoneSheet` | `ConnectionCatalog.swift` | A sheet whose content is plain settings rows |
| `ConnectMethodBadge`, `MCPServiceRow` | `ServiceRows.swift` | How an option links; a service you signed in to |
| `GitLabHostRow`, `GitLabSetupSheet` | `GitLabSettings.swift` | GitLab in the same row and setup-sheet shapes |
| `MCPServerCardRow`, `AddMCPServerWizardSheet` | `MCPSettingsSection.swift` | MCP servers in the same shapes |
| `SetupSheet`, `SetupStep` | `SettingsStyle.swift` | Every setup flow: icon and title on top, numbered steps, one clear button below |
| `SheetPart` | `SettingsStyle.swift` | A part of a sheet for something already set up: its name and its rows. A linked chat app's sheet is always Accounts, In Nook, then Advanced folded away |

Settings › Chat apps and Settings › Services (`ConnectionsPage`, one view in two parts) hold everything you link or sign
in to: the Add button in the page's header (`SettingsPageAction`), then what you have by kind (chat apps; services and your own servers), each in the
`ServiceRowLayout` shape with what needs you first, then the apps on this Mac (switches) and the chat options. Adding
always goes through `AddConnectionSheet`, and managing opens the same sheet the steps were in. A new service gets an
option in `ConnectionCatalog`, a row in this shape, and a `SetupSheet` when it needs steps; it never gets a section or
page of its own. Whatever stops working shows in `ConnectionProblems`, which the Overview and the sidebar badge read.

## File layout

Keep a tab or panel file to the view it is named after. Its rows, cards, and helpers go into their own files next to it
(for example `NookTab.swift` → `NookChatMessage.swift`, `NookConversationList.swift`, `NookStarters.swift`; `AgentsTab.swift` →
`AgentFormat.swift`, `GitHead.swift`), and anything a second feature uses moves to `NotchUI/Components`.
