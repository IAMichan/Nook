# Shared UI Components (macOS)

The notch, the Workspace, and Settings share one visual language. Before writing a view modifier chain by hand, check
whether one of the building blocks below already does it; when a pattern shows up a third time, add it here instead of
copying it again.

## Theme — `apps/macos/NotchUI/Theme/NookTheme.swift`

| Token / helper | Use |
| --- | --- |
| `NookTheme.paper`, `ink`, `textSecondary`, `textTertiary` | Text colors |
| `NookTheme.field`, `smoke`, `graphite`, `line`, `line2` | Surfaces and hairlines |
| `NookTheme.mint`, `amber`, `coral`, `violet`, `iris` | State: done, waiting on you, error, merged, Nook itself |
| `NookTheme.rowRest`, `rowHover`, `rowSelected`, `rowFill(selected:hovering:rest:)` | List rows and cards at rest, under the pointer, and selected |
| `NookTheme.font(_:_:)`, `mono(_:_:)` | Typography |
| `NookTheme.open`, `close`, `swap`, `hover` | Animations |
| `.hoverLift(_:scale:)` | The shared hover lift of buttons and chips |

Workspace views use the `WS` palette in `NotchUI/Workspace/WorkspaceComponents.swift`.

## Components — `apps/macos/NotchUI/Components`

| Component | File | Use |
| --- | --- | --- |
| `NookPrimaryButton`, `SmallPrimaryButton`, `NookGhostButton`, `SmallGhostButton` | `NookButtons.swift` | Text buttons on cards and in chat |
| `NookIconButton` | `NookButtons.swift` | Round symbol button (mic, close, play) |
| `ToolbarIconButton` | `NookButtons.swift` | Small borderless symbol button in a panel header or under a message |
| `.cardBackground(_:stroke:radius:style:)` | `CardBackground.swift` | Rounded fill with a 1 pt stroke: field cards and tinted notices |
| `Pasteboard.copy(_:)` | `Pasteboard.swift` | Put text on the pasteboard |
| `Bar`, `PulseDot`, `ShimmerText`, `PullRequestPill` | `AgentIndicators.swift` | Progress bar, live dot, shimmering current step, pull request state |
| `AgentStatusBadge`, `RowBadgeBackground`, `SteppedPulseDot` | `StatusStyleView.swift` | Session state in rows |
| `HoverCard`, `.hoverCard(_:)` | `HoverCard.swift` | Detail popover on hover |
| `DropdownHeader`, `DropdownRow`, `DropdownDivider`, `ComposerDropdown` | `ComposerDropdown.swift` | Menus of the composer and pickers |
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
| `ServiceRowLayout`, `MCPServiceRow`, `OneClickServiceCard` | `ServiceRows.swift` | Connection rows |

## File layout

Keep a tab or panel file to the view it is named after. Its rows, cards, and helpers go into their own files next to it
(for example `NookTab.swift` → `NookChatMessage.swift`, `NookConversationList.swift`, `NookStarters.swift`; `AgentsTab.swift` →
`AgentFormat.swift`, `GitHead.swift`), and anything a second feature uses moves to `NotchUI/Components`.
