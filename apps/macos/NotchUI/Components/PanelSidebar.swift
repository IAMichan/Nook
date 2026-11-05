import SwiftUI

// The main window's sidebar, as in t3code: one column along the window's left edge, from the top of the window to the
// bottom. Its head is the title bar's row: the traffic lights, and search, talk and split view. Nook himself stays in the notch.
// Then the tabs (Nook, Agents, Chats, Music) on one bar of marks, the name only on the tab you are on, then the list of
// the tab you are on (its sessions, its Nooks, its chats), and the footer at the bottom.
//
// The list belongs to its tab, so the tab draws the column; `PanelView` hands it what goes on top through the
// environment (`panelSidebar`), and the tab starts its first column with `PanelSidebarTop`. While that shows, the
// panel drops its own header (the floating capsule with the tabs). Where no tab column shows (the list put away, a
// narrow window that shows one column at a time) the panel folds the sidebar to a rail of icons (`PanelSidebarTop`
// with `compact`), so the tabs stay along the left edge. Agents is the exception: its list goes away altogether, with
// `PanelSidebarToggle` in one spot beside the traffic lights to bring it back (⌘1 and on still switch tabs). The notch
// has no room for a sidebar and never gets the context: it keeps its capsule.

/// What the sidebar shows on top, from `PanelView` in the main window.
struct PanelSidebarContext {
    let tabs: [NookTabBar<PanelTab>.Item]
    /// The tab you are on, lit in the list.
    let selected: PanelTab
    /// The tab split view shows beside it, outlined.
    let beside: PanelTab?
    /// The tab the panel shows, for the split view button.
    let current: PanelTab
    let select: (PanelTab) -> Void
    let search: () -> Void
    let talk: () -> Void
}

enum PanelSidebarMetrics {
    /// The window's title bar row, with an empty unified toolbar so the traffic lights sit in its middle: the sidebar's
    /// head fills it, and a session's header (30 pt) is centered on the same line beside it.
    static let titleBand: CGFloat = 52
    /// How far below the window's top the content beside the sidebar starts, so a 30 pt header is centered on the band.
    static let contentTop: CGFloat = (titleBand - 30) / 2
    /// The room the traffic lights take from the window's left edge (they end near 80 pt).
    static let trafficLights: CGFloat = 88
    /// The toggle that puts the Agents list away (`PanelSidebarToggle`): right of the traffic lights, in the same spot
    /// with the list out or away.
    static let toggle: CGFloat = 28
    /// How far a conversation's header starts from the content's edge with the list away, past the traffic lights and
    /// the toggle. The content itself starts `collapsedContentLeading` from the window's edge.
    static let collapsedContentLeading: CGFloat = NookTheme.Spacing.lg
    static let collapsedHeaderInset: CGFloat = trafficLights + toggle + NookTheme.Spacing.sm - collapsedContentLeading
    /// The head of the sidebar fills the title bar's row.
    static let head: CGFloat = titleBand
    /// A tab in the rail of icons, and the search field above them.
    static let row: CGFloat = 32
    /// The bar with the tabs on one line, so the list under it keeps the room four rows would take.
    static let tabBar: CGFloat = 34
    /// A tab on that bar: the bar's height without its padding.
    static let tabBarItem: CGFloat = tabBar - NookTheme.Spacing.xxs * 2
    /// The narrowest a tab on the bar gets: a tab without its name, its mark with room for the status on its corner.
    static let tabBarItemMinimum: CGFloat = 28
    /// The column a row's mark stands in.
    static let mark: CGFloat = 18
    /// Room between the window's edge and the sidebar's rows, and the same between its rows and the line on its right.
    static let inset: CGFloat = NookTheme.Spacing.md
    /// The narrowest the head fits in: the room for the traffic lights, the Agents toggle or Search, back and forward,
    /// then talk (28 pt each) and split view (30 pt), with the row's spacing between them. A column narrower than this
    /// would push its rows off the left edge.
    static let headWidth: CGFloat = trafficLights - inset + 28 * 4 + 30 + NookTheme.Spacing.xxs * 6
    /// The narrowest the sidebar's whole column gets: its head with the inset on the left and the gap to its line on the
    /// right. Narrower, search would slide under the traffic lights and split view past the line on the right.
    static let minimumColumn: Double = Double(inset + headWidth + SidePanelMetrics.sidebarGap)
}

private struct PanelSidebarKey: EnvironmentKey {
    static let defaultValue: PanelSidebarContext? = nil
}

private struct InPanelSidebarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by `PanelView` in the main window only; nil in the notch and in the tab split view shows beside another.
    var panelSidebar: PanelSidebarContext? {
        get { self[PanelSidebarKey.self] }
        set { self[PanelSidebarKey.self] = newValue }
    }

    /// Inside the sidebar's column (`panelSidebarColumn`): a list's title row is a quiet section label there.
    var inPanelSidebar: Bool {
        get { self[InPanelSidebarKey.self] }
        set { self[InPanelSidebarKey.self] = newValue }
    }
}

/// True while a tab draws the sidebar's head: `PanelView` then leaves out its own header, and the window its margins.
struct PanelSidebarShown: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// The head of the sidebar: the title bar's row with search, talk and split view, and the tabs. Nothing
/// outside the main window. `compact` is the rail of icons the Chats tab folds its sidebar into.
struct PanelSidebarTop: View {
    var compact = false
    /// Back and forward through what you opened, right of the traffic lights, for a tab that keeps such a trail.
    var history: AnyView? = nil
    /// The tab floats `PanelSidebarToggle` over the head, in the spot right of the traffic lights. Its list has a search
    /// field of its own, so the head leaves out Search (⌘K still opens it).
    var hasToggle = false
    @Environment(\.panelSidebar) private var context

    var body: some View {
        if let context {
            VStack(alignment: compact ? .center : .leading, spacing: NookTheme.Spacing.xxs) {
                head(context)
                // The rail of icons has no room for the head's buttons: Search everything is a glyph on top of it.
                if compact {
                    NookSearchLauncher(prompt: tr("search.sidebar"), shortcut: "⌘K", help: tr("search.button"),
                                       compact: true, height: PanelSidebarMetrics.row, action: context.search)
                        .padding(.bottom, NookTheme.Spacing.sm)
                }
                if compact {
                    tabs(context)
                } else {
                    HStack(spacing: NookTheme.Spacing.xxs) { tabs(context) }
                        .padding(NookTheme.Spacing.xxs)
                        .frame(maxWidth: .infinity, minHeight: PanelSidebarMetrics.tabBar,
                               maxHeight: PanelSidebarMetrics.tabBar)
                        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous)
                            .fill(NookTheme.surface))
                }
                NookDivider()
                    .padding(.top, NookTheme.Spacing.md)
                    .padding(.bottom, NookTheme.Spacing.xs)
            }
            .preference(key: PanelSidebarShown.self, value: true)
        }
    }

    private func tabs(_ context: PanelSidebarContext) -> some View {
        ForEach(Array(context.tabs.enumerated()), id: \.element.id) { index, item in
            PanelSidebarTabButton(tab: item.value, title: item.title, count: item.count,
                                  shortcut: "⌘\(index + 1)", selected: item.value == context.selected,
                                  beside: item.value == context.beside, compact: compact) {
                context.select(item.value)
            }
        }
    }

    /// The title bar's row: room for the traffic lights, then search (⌘K), talk and split view.
    private func head(_ context: PanelSidebarContext) -> some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            Color.clear
                .frame(width: PanelSidebarMetrics.trafficLights - PanelSidebarMetrics.inset)
            if hasToggle { Color.clear.frame(width: PanelSidebarMetrics.toggle) }
            if !compact, let history { history }
            Spacer(minLength: 0)
            if !compact {
                if !hasToggle {
                    NookIconButton(systemName: "magnifyingglass", label: tr("search.button"), size: 28, action: context.search)
                        .help(tr("search.button"))
                }
                NookIconButton(systemName: "mic", label: tr("button.talk"), size: 28, action: context.talk)
                PanelSplitButton(current: context.current)
            }
        }
        .frame(height: PanelSidebarMetrics.head)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shows or puts away the Agents list. It floats over the window instead of sitting in the list, so it stays in one spot
/// right of the traffic lights, with the list out or away, on every page of the tab.
struct PanelSidebarToggle: View {
    let open: Bool
    let action: () -> Void

    var body: some View {
        SidePanelToggle(edge: .leading, open: open, help: tr(open ? "agents.list.hide" : "agents.list.show"), action: action)
            .frame(width: PanelSidebarMetrics.toggle, height: PanelSidebarMetrics.toggle)
            .padding(.leading, PanelSidebarMetrics.trafficLights)
            // Up to the middle of the title bar's row, from the content's top.
            .offset(y: (PanelSidebarMetrics.titleBand - PanelSidebarMetrics.toggle) / 2 - PanelSidebarMetrics.contentTop)
    }
}

/// Back and forward through the sessions you opened, as ⌘[ and ⌘]. `SessionHistory` is not observed, so nothing else
/// redraws when you open a session: these two read it again once the session on screen changed, after it was recorded.
struct SessionHistoryButtons: View {
    /// The session on screen.
    let current: String
    let back: () -> Void
    let forward: () -> Void
    @State private var canGoBack = false
    @State private var canGoForward = false

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            button("arrow.left", tr("a11y.back"), enabled: canGoBack, back)
            button("arrow.right", tr("a11y.forward"), enabled: canGoForward, forward)
        }
        .task(id: current) {
            await Task.yield()
            canGoBack = SessionHistory.shared.trail.canGoBack
            canGoForward = SessionHistory.shared.trail.canGoForward
        }
    }

    private func button(_ symbol: String, _ label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        ToolbarIconButton(symbol, label, height: 28, width: 28, enabled: enabled, symbolSize: 13) {
            if enabled { action() }
        }
        .help(label)
    }
}

/// A tab in the sidebar. On the bar, the tab you are on shows its mark, name and what goes on there
/// (`PanelSidebarTabStatus`) on `rowSelected`, and the others only their mark with that status as a dot on its corner;
/// the name and shortcut of those are in the tooltip. In the rail every tab is its mark with the dot. The tab split view
/// shows beside this one is outlined.
private struct PanelSidebarTabButton: View {
    let tab: PanelTab
    let title: String
    var count = 0
    let shortcut: String
    var selected = false
    var beside = false
    var compact = false
    let action: () -> Void
    @State private var hovering = false

    private var named: Bool { selected && !compact }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(systemName: PanelSplitChoice.symbol(tab))
                    .font(NookTheme.font(13, .medium))
                    .foregroundStyle(selected ? NookTheme.paper : hovering ? NookTheme.textSecondary : NookTheme.textTertiary)
                    .frame(width: PanelSidebarMetrics.mark)
                    .overlay(alignment: .topTrailing) {
                        if !named {
                            PanelSidebarTabStatus(tab: tab, waiting: count, asDot: true)
                                .offset(x: 3, y: -2)
                        }
                    }
                if named {
                    Text(title)
                        .font(NookTheme.font(13, .medium))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    PanelSidebarTabStatus(tab: tab, waiting: count)
                }
            }
            .padding(.horizontal, named ? NookTheme.Spacing.md : 0)
            .frame(minWidth: named ? nil : PanelSidebarMetrics.tabBarItemMinimum,
                   maxWidth: named ? nil : compact ? PanelSidebarMetrics.row + NookTheme.Spacing.sm : .infinity)
            .frame(height: compact ? PanelSidebarMetrics.row : PanelSidebarMetrics.tabBarItem)
            .background(shape.fill(NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear)))
            .overlay {
                if beside {
                    shape.strokeBorder(NookTheme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        // A tab torn off into a window of its own (`TabWindowController`).
        .contextMenu {
            if PanelSplitChoice.choices.contains(TabWindowController.key(tab)) {
                Button(tr("split.toWindow")) { TabWindowController.shared.open(tab, app: AppModel.shared) }
            }
        }
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help("\(title) (\(shortcut))")
        .accessibilityLabel(count > 0 ? "\(title), \(count)" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(beside ? tr("split.beside") : "")
        // The name stays whole; the tabs without one share what is left of the bar.
        .fixedSize(horizontal: named, vertical: false)
    }
}

/// What goes on in a tab: on Agents the sessions waiting for you (amber) or a pulse while one works, on Chats the unread
/// messages, on Music the bars while something plays. Beside a tab's name it shows those; `asDot` on the corner of a mark
/// it shrinks to a dot, amber for what waits for you and blue for what is busy. Each observes only what it shows, so
/// the rest of the sidebar does not redraw with it.
private struct PanelSidebarTabStatus: View {
    let tab: PanelTab
    let waiting: Int
    var asDot = false

    private static let dotSize: CGFloat = 6

    var body: some View {
        switch tab {
        case .agents:
            if waiting > 0 {
                if asDot { Dot(color: NookTheme.amber) } else { NookCountBadge(count: waiting) }
            } else {
                AgentsWorking(asDot: asDot)
            }
        case .inbox: ChatsUnread(capture: ChatCaptureService.shared, asDot: asDot)
        case .music: MusicPlaying(asDot: asDot)
        case .nook, .chat, .connect, .shelf: EmptyView()
        }
    }

    private struct Dot: View {
        let color: Color

        var body: some View {
            Circle().fill(color).frame(width: PanelSidebarTabStatus.dotSize, height: PanelSidebarTabStatus.dotSize)
        }
    }

    private struct AgentsWorking: View {
        let asDot: Bool
        @EnvironmentObject private var app: AppModel

        var body: some View {
            if !app.workspace.activeRuns.isEmpty || app.activeAgents.contains(where: { $0.status == .running }) {
                SteppedPulseDot(color: AgentDisplayState.working.tone.color, size: PanelSidebarTabStatus.dotSize)
                    .frame(width: asDot ? PanelSidebarTabStatus.dotSize : 16, height: asDot ? PanelSidebarTabStatus.dotSize : 16)
                    .help(AgentDisplayState.working.longWord)
            }
        }
    }

    private struct ChatsUnread: View {
        @ObservedObject var capture: ChatCaptureService
        let asDot: Bool

        var body: some View {
            let unread = capture.visibleUnread
            if unread > 0 {
                if asDot { Dot(color: NookTheme.amber) } else { NookCountBadge(count: unread) }
            }
        }
    }

    private struct MusicPlaying: View {
        let asDot: Bool
        @EnvironmentObject private var app: AppModel

        var body: some View {
            Playing(nowPlaying: app.nowPlaying, asDot: asDot)
        }

        private struct Playing: View {
            @ObservedObject var nowPlaying: NowPlayingService
            let asDot: Bool

            var body: some View {
                if nowPlaying.current?.isPlaying == true {
                    if asDot {
                        Dot(color: NookTheme.blue)
                    } else {
                        EqualizerBars(color: NookTheme.textSecondary, height: 10)
                            .frame(height: 16)
                    }
                }
            }
        }
    }
}

extension View {
    /// The header of a conversation (a session's, the Nook chat's) stands on the canvas, above what scrolls under it:
    /// in the main window a scroll view may draw past its top into the title bar's row, and the conversation's lines
    /// ran through the header's title. There the canvas reaches up to the window's top too.
    func conversationHeaderBackground() -> some View {
        modifier(ConversationHeaderBackground())
    }

    /// The first column of a tab in the main window, which starts with `PanelSidebarTop`: its rows keep
    /// `PanelSidebarMetrics.inset` from the window's edge, and it runs up to the window's top, where its head fills the
    /// title bar's row, while the content beside it starts `contentTop` lower. Elsewhere unchanged.
    func panelSidebarColumn() -> some View {
        modifier(PanelSidebarColumn())
    }
}

private struct PanelSidebarColumn: ViewModifier {
    @Environment(\.panelSidebar) private var context

    func body(content: Content) -> some View {
        content
            .padding(.leading, context == nil ? 0 : PanelSidebarMetrics.inset)
            .padding(.top, context == nil ? 0 : -PanelSidebarMetrics.contentTop)
            .environment(\.inPanelSidebar, context != nil)
    }
}

private struct ConversationHeaderBackground: ViewModifier {
    @Environment(\.panelSidebar) private var context

    func body(content: Content) -> some View {
        content
            .background {
                NookTheme.canvas
                    .padding(.top, context == nil ? 0 : -PanelSidebarMetrics.contentTop)
                    .padding(.bottom, -NookTheme.Spacing.sm)
                    .allowsHitTesting(false)
            }
            .zIndex(1)
    }
}
