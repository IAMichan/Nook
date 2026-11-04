import SwiftUI

// The main window's sidebar: one column along the window's left edge, from the top of the window to the
// bottom. Its head is the title bar's row: the traffic lights, and search, talk and split view. Nook himself stays in the notch.
// Then the tabs (Nook, Agents, Chats, Music) as rows, then the list of
// the tab you are on (its sessions, its Nooks, its chats), and the footer at the bottom.
//
// The list belongs to its tab, so the tab draws the column; `PanelView` hands it what goes on top through the
// environment (`panelSidebar`), and the tab starts its first column with `PanelSidebarTop`. While that shows, the
// panel drops its own header (the floating capsule with the tabs). Where no tab column shows (the list put away, a
// narrow window that shows one column at a time, a task over the tab) the header comes back, so the tabs are always
// in reach. The notch has no room for a sidebar and never gets the context: it keeps its capsule.

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
    /// The head of the sidebar fills the title bar's row.
    static let head: CGFloat = titleBand
    /// A tab row, and the search field above them.
    static let row: CGFloat = 32
    /// The column a row's mark stands in.
    static let mark: CGFloat = 18
    /// Room between the window's edge and the sidebar's rows, and the same between its rows and the line on its right.
    static let inset: CGFloat = NookTheme.Spacing.lg
    /// The narrowest the head fits in: the room for the traffic lights, then search and talk (28 pt) and split view
    /// (30 pt), with the row's spacing between them. A column narrower than this would push its rows off the left edge.
    static let headWidth: CGFloat = trafficLights - inset + 28 + 28 + 30 + NookTheme.Spacing.xxs * 4
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
                ForEach(Array(context.tabs.enumerated()), id: \.element.id) { index, item in
                    PanelSidebarRow(tab: item.value, title: item.title, count: item.count,
                                    shortcut: "⌘\(index + 1)", selected: item.value == context.selected,
                                    beside: item.value == context.beside, compact: compact) {
                        context.select(item.value)
                    }
                }
                NookDivider()
                    .padding(.top, NookTheme.Spacing.md)
                    .padding(.bottom, NookTheme.Spacing.xs)
            }
            .preference(key: PanelSidebarShown.self, value: true)
        }
    }

    /// The title bar's row: room for the traffic lights, then search (⌘K), talk and split view.
    private func head(_ context: PanelSidebarContext) -> some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            Color.clear
                .frame(width: PanelSidebarMetrics.trafficLights - PanelSidebarMetrics.inset)
            Spacer(minLength: 0)
            if !compact {
                NookIconButton(systemName: "magnifyingglass", label: tr("search.button"), size: 28, action: context.search)
                    .help(tr("search.button"))
                NookIconButton(systemName: "mic", label: tr("button.talk"), size: 28, action: context.talk)
                PanelSplitButton(current: context.current)
            }
        }
        .frame(height: PanelSidebarMetrics.head)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A tab in the sidebar: its mark (filled while it is the tab you are on) and name, and at the end what goes on there
/// (`PanelSidebarTabStatus`), or its shortcut under the pointer. Selected on `rowSelected` with a hairline edge, as a
/// thread in; the tab split view shows beside it outlined. In the rail only the mark, centered.
private struct PanelSidebarRow: View {
    let tab: PanelTab
    let title: String
    var count = 0
    let shortcut: String
    var selected = false
    var beside = false
    var compact = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.sm + NookTheme.Spacing.xxs) {
                Image(systemName: PanelSplitChoice.symbol(tab))
                    .symbolVariant(selected ? .fill : .none)
                    .font(NookTheme.font(13, .medium))
                    .foregroundStyle(selected ? NookTheme.paper : hovering ? NookTheme.textSecondary : NookTheme.textTertiary)
                    .frame(width: PanelSidebarMetrics.mark)
                    .overlay(alignment: .topTrailing) {
                        if compact && count > 0 {
                            Circle().fill(NookTheme.amber).frame(width: 6, height: 6).offset(x: 3, y: -2)
                        }
                    }
                if !compact {
                    Text(title)
                        .font(NookTheme.font(13, .medium))
                        .foregroundStyle(selected || hovering ? NookTheme.paper : NookTheme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: NookTheme.Spacing.xs)
                    // What goes on there, or under the pointer the shortcut when nothing does.
                    ZStack(alignment: .trailing) {
                        PanelSidebarTabStatus(tab: tab, waiting: count)
                            .opacity(hovering ? 0 : 1)
                        NookKeyHint(text: shortcut)
                            .opacity(hovering ? 1 : 0)
                    }
                }
            }
            .padding(.horizontal, compact ? 0 : NookTheme.Spacing.sm)
            .frame(maxWidth: compact ? PanelSidebarMetrics.row + NookTheme.Spacing.sm : .infinity,
                   minHeight: PanelSidebarMetrics.row, maxHeight: PanelSidebarMetrics.row)
            .background(shape.fill(NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear)))
            .overlay {
                if selected {
                    shape.strokeBorder(NookTheme.line2, lineWidth: 1)
                } else if beside {
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
    }
}

/// What goes on in a tab, at the end of its row: on Agents the sessions waiting for you (amber) or a pulse while one
/// works, on Chats the unread messages, on Music the bars while something plays. Each observes only what it shows, so
/// the rest of the sidebar does not redraw with it.
private struct PanelSidebarTabStatus: View {
    let tab: PanelTab
    let waiting: Int

    var body: some View {
        switch tab {
        case .agents:
            if waiting > 0 { NookCountBadge(count: waiting) } else { AgentsWorking() }
        case .inbox: ChatsUnread(capture: ChatCaptureService.shared)
        case .music: MusicPlaying()
        case .nook, .chat, .connect, .shelf: EmptyView()
        }
    }

    private struct AgentsWorking: View {
        @EnvironmentObject private var app: AppModel

        var body: some View {
            if !app.workspace.activeRuns.isEmpty || app.activeAgents.contains(where: { $0.status == .running }) {
                SteppedPulseDot(color: AgentDisplayState.working.tone.color, size: 6)
                    .frame(width: 16, height: 16)
                    .help(AgentDisplayState.working.longWord)
            }
        }
    }

    private struct ChatsUnread: View {
        @ObservedObject var capture: ChatCaptureService

        var body: some View {
            let unread = capture.visibleUnread
            if unread > 0 {
                Text(unread > 99 ? "99+" : "\(unread)")
                    .font(NookTheme.rounded(10.5, .semibold))
                    .foregroundStyle(NookTheme.textSecondary)
                    .padding(.horizontal, NookTheme.Spacing.xs + NookTheme.Spacing.xxs)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(NookTheme.smoke))
                    .fixedSize()
            }
        }
    }

    private struct MusicPlaying: View {
        @EnvironmentObject private var app: AppModel

        var body: some View {
            Playing(nowPlaying: app.nowPlaying)
        }

        private struct Playing: View {
            @ObservedObject var nowPlaying: NowPlayingService

            var body: some View {
                if nowPlaying.current?.isPlaying == true {
                    EqualizerBars(color: NookTheme.textSecondary, height: 10)
                        .frame(height: 16)
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
