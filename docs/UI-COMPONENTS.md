# Shared UI Components (macOS)

The notch, the Workspace, and Settings share one visual language. Before writing a view modifier chain by hand, check
whether one of the building blocks below already does it; when a pattern shows up a third time, add it here instead of
copying it again.

## Theme — `apps/macos/NotchUI/Theme/NookTheme.swift`

| Token / helper | Use |
| --- | --- |
| `NookTheme.paper`, `textStrong`, `textSecondary`, `textTertiary`, `textMuted`, `ink` | Text colors, from brightest to most muted |
| `NookTheme.canvas`, `surface`, `field`, `well`, `smoke`, `graphite` | Surfaces: the window canvas, a lifted sidebar or menu, a text field, a sunken code well, and the two card fills |
| `NookTheme.line`, `line2`, `hairline`, `fieldStroke` | Hairlines and strokes |
| `NookTheme.blue` | Links, renamed files, and diff hunk headers |
| `NookTheme.mint`, `amber`, `coral`, `violet`, `iris` | State: done, waiting on you, error, merged, Nook itself |
| `NookTheme.rowRest`, `rowHover`, `rowSelected`, `rowFill(selected:hovering:rest:)` | List rows and cards at rest, under the pointer, and selected |
| `NookTheme.TextStyle.caption`, `label`, `body`, `strong`, `title`, `code` | The type scale: the same kind of text is the same size everywhere |
| `NookTheme.font(_:_:)`, `mono(_:_:)`, `rounded(_:_:)` | A size the scale does not cover (an icon, a numeral); never `Font.system(size:)` inline |
| `NookTheme.Radius.chip`, `control`, `card`, `panel`, `sheet`, `pill` | Corner radii: 6, 8, 10, 12, 14, 20. Name the element, not the number |
| `NookTheme.Spacing.xxs … xxl` | Padding and stack spacing on a 4 pt grid: 2, 4, 6, 8, 12, 16, 24 |
| `NookTheme.open`, `close`, `swap`, `hover` | Animations |
| `.hoverLift(_:scale:)` | The shared hover lift of buttons and chips |

Workspace views use the `WS` palette in `NotchUI/Workspace/WorkspaceComponents.swift`, which is built from these
tokens (`WS.background` is `NookTheme.canvas`, `WS.sidebar` is `NookTheme.surface`).

## Keeping it one design

Nook has one visual language, and the repository guards it in three places:

1. **`UIConsistencyTests`** (`apps/macos/Tests/NookTests/UIConsistencyTests.swift`) reads every source under `NotchUI`
   and `App` and fails when a view uses `Font.system(size:)` inline, a literal `Color(hex:)` / `Color(red:)` /
   `NSColor(white:)`, or a corner radius written as a number from the scale. It runs with the Xcode tests and with
   `./scripts/core-tests.sh`.
2. **`scripts/ui-lint.sh`** checks the same rules with `grep`, so it runs anywhere, and the *UI consistency* job in
   `.github/workflows/build.yml` runs it on every pull request.
3. **This document** is the catalogue: a pattern that shows up a third time becomes a component here.

When a file genuinely draws its own colors (a brand mark, a chart palette, Nook's face), add it to the allow-list in
both `UIConsistencyTests.ownColors` and `OWN_COLORS` in `scripts/ui-lint.sh`, with the reason in a comment; never
loosen the rule itself.

The checklist for a new or changed view:

- Text: a `NookTheme.TextStyle`, or `NookTheme.font` / `mono` / `rounded` for the odd size. Color from the text ramp
  (`paper` › `textStrong` › `textSecondary` › `textTertiary` › `textMuted`).
- Surfaces: `canvas` under a window, `surface` for what lifts off it, `field` for input, `well` for code and logs,
  `rowFill(selected:hovering:)` for rows. Strokes are `line`, `line2`, `hairline`, or `fieldStroke`.
- State color means one thing everywhere: `iris` is Nook, `mint` is done or listening, `amber` waits on you,
  `coral` is an error, `violet` is merged.
- Corners from `NookTheme.Radius`, spacing from `NookTheme.Spacing`, hover with `.hoverLift`, animation with
  `NookTheme.open` / `close` / `swap` / `hover`.
- One layout: the notch, the main window, and a sheet show the same `PanelView`; Settings is the one place for
  configuration. A new task opens inside the panel, not in a new window with its own layout.
- The buttons at the bottom of a notification are always a `NookNoticeActions` row, never loose buttons.
- Every string through `tr("key")` in all five languages, and a `.help` or accessibility label on a symbol-only control.

## Components — `apps/macos/NotchUI/Components`

| Component | File | Use |
| --- | --- | --- |
| `NookPrimaryButton`, `SmallPrimaryButton`, `NookGhostButton`, `SmallGhostButton` | `NookButtons.swift` | Text buttons on cards and in chat (optional SF Symbol before the title) |
| `NookAcknowledgeButton`, `CountdownRing` | `NookButtons.swift` | The white "OK" that closes a notice at once, with a ring counting down until it closes by itself (card `acknowledge` + `countdown`, compact strip) |
| `NookActionBar` | `NookButtons.swift` | A notice's other actions in one dark bar with thin dividers, next to its OK |
| `NookNoticeActions`, `NookNoticeAction` | `NookNoticeActions.swift` | The button row at the bottom of every notification (cards, approvals, questions, panel notices): main action and its "not now" in one pill (`NookSplitButton`), muted extras, rarer actions in a "…" menu (`NookMoreMenu`), optional mic. Use it for any new notification instead of loose buttons |
| `NookIconButton` | `NookButtons.swift` | Round symbol button (mic, close, play) |
| `ToolbarIconButton` | `NookButtons.swift` | Small borderless symbol button in a panel header or under a message |
| `.cardBackground(_:stroke:radius:style:)` | `CardBackground.swift` | Rounded fill with a 1 pt stroke: field cards and tinted notices |
| `Pasteboard.copy(_:)` | `Pasteboard.swift` | Put text on the pasteboard |
| `Bar`, `PulseDot`, `ShimmerText`, `PullRequestPill` | `AgentIndicators.swift` | Progress bar, live dot, shimmering current step, pull request state in a row |
| `PullRequestStateBadge` | `AgentIndicators.swift` | A pull request's state as a tinted capsule with GitHub's mark and the word, optionally after its number (pull request page, watched pull request); never draw the state by hand |
| `AgentStatusBadge`, `RowBadgeBackground`, `SteppedPulseDot` | `StatusStyleView.swift` | Session state in rows |
| `HoverCard`, `.hoverCard(_:)` | `HoverCard.swift` | Detail popover on hover |
| `DropdownHeader`, `DropdownRow`, `DropdownDivider`, `ComposerDropdown` | `ComposerDropdown.swift` | Menus of the composer and pickers |
| `ComposerTray`, `ComposerTrayDivider` | `ComposerTray.swift` | The tray tucked behind the composer box: under it for a new session (folder and branch), above it for a running one (watched pull request, queued messages). Anything that belongs to the next message goes in here instead of a loose strip |
| `SelectionModeButton`, `.selectable(…)`, `SelectionBar` | `ListSelectionViews.swift` | Selecting several rows |
| `NookTabBar` | `NookTabBar.swift` | Segmented tabs, with an optional symbol, unread dot (`fresh`) or amber count (`count`) |

Workspace-only blocks (`InfoRow`, `WSEmptyState`, `WSSectionTitle`, `StatusBadge`) live in
`NotchUI/Workspace/WorkspaceComponents.swift`.

## The panel — notch and main window

The main window (`WorkspaceView`) is the open notch with more room: it shows the same `PanelView` (with
`inWindow: true`, which uses `windowTab`/`windowSheet` and lets the close button close the window) and the same
`PanelOrb` (Nook with his task ring, next to the tabs). Change the panel once and both follow; do not build a separate
window layout. In the window the header's empty space moves the window, the traffic lights replace the close
button, the window remembers its tab (and opens at an agent that waits for you), and the chat keeps a readable width
(`PanelLayout.readableChat`). In the notch, the window button continues on the same tab in the window.

## Settings — `apps/macos/App/Settings`

| Component | File | Use |
| --- | --- | --- |
| `SettingToggle(_:detail:isOn:)` | `SettingsBlocks.swift` | A switch with a caption under its title |
| `SettingLabel(_:detail:)` | `SettingsBlocks.swift` | The same title and caption, for rows with a button or picker |
| `StatusRow`, `SettingsHeader`, `Keycap` | `SettingsBlocks.swift` | Status lines, section headers, keyboard keys |
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
