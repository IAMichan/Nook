import SwiftUI

// One side panel for everything that opens beside a conversation or a list: the lists of the Nook, Agents and Chats
// tabs, a command's terminal, the tool panel with its tabs, a turn's diff or a file, a pull request beside its list, an
// artifact beside its app, and the docked session panel. They all work the same way:
//
// - Each sits flat on the canvas with a line on the side of what it sits beside: a drag line (drag to resize,
//   double-click for its usual width, `.sidePanel(_:width:…)`), or, for a panel of fixed width, only the same room
//   without a line (`.fixedSidePanel(width:)`). A list on the left slides in from its edge; a panel on the right opens
//   and closes at once (`sidePanelsOpenAtOnce`).
// - Each starts with a header of the same height (`SidePanelHeader`, or `SidePanelTabBar` for the tool panel) that
//   ends in the same close button: a cross (`SidePanelCloseButton`).
// - What a tab shows starts with one bar of the same height under that header (`SidePanelToolbar`): the browser's
//   address, the terminal's folder, the changes' counts, a file's name. A tab with nothing to show says so with a
//   `WSEmptyState`, never an empty pane.
// - A session's header ends in one toggle per panel (`SidePanelToggle`), in the order of the panels on screen: the bottom
//   panel, the session panel and the side panel on the right, each with its own mark (`Edge.panelSymbol`), lit while it
//   is open. They stay put when the session panel opens or closes: above it, or at the end of the conversation's header.
//   The list on the left has its toggle in one spot beside the traffic lights (`PanelSidebarToggle`); only the notch
//   keeps it in the header.
// - A turn's diff opens in the tool panel's Changes tab and a file in its File tab (`SessionSideLink`), so a session has
//   one panel on the right, at one width.

extension Edge {
    /// The mark of the panel on this side of a conversation, on the toggle in a session's header that shows or hides it.
    var panelSymbol: String {
        switch self {
        case .leading: return "sidebar.left"
        case .trailing: return "sidebar.right"
        case .top, .bottom: return "rectangle.bottomthird.inset.filled"
        }
    }
}

enum SidePanelMetrics {
    /// Every side panel's header (a title row or a tab row) is this tall, so what they show starts on one line.
    static let header: CGFloat = 32
    /// The bar of what a tab shows, under the header (`SidePanelToolbar`): no line under it, the room under it parts it
    /// from what the tab shows.
    static let toolbar: CGFloat = 28
    static let toolbarGap: CGFloat = NookTheme.Spacing.md
    /// Room between a panel and the drag line on the conversation's side.
    static let gap: CGFloat = NookTheme.Spacing.sm
    /// Room between a tab's list and the line beside it: with half the line's own room, the list sits as far from the
    /// line as from the panel's outer edge (28 pt in the notch and the window), centered in its column.
    static let listGap: CGFloat = 28 - CGFloat(PanelSplit.handle) / 2
    /// The same for the main window's sidebar: its rows sit as far from the line as from the window's edge.
    static let sidebarGap: CGFloat = PanelSidebarMetrics.inset - CGFloat(PanelSplit.handle) / 2
}

extension EnvironmentValues {
    /// How far a line that spans its whole column (a column's drag line, the line under a panel's toolbar) runs on past
    /// that column on each side: to the window's edge, or to the drag line beside it. The window keeps its margins
    /// for text and buttons, but its lines meet each other and the edges instead of stopping short.
    @Entry var lineBleed = EdgeInsets()
}

extension View {
    /// Lets a full-width line run on past its column by `lineBleed` (see there).
    func bleedsHorizontally(_ bleed: EdgeInsets) -> some View {
        padding(.leading, -bleed.leading).padding(.trailing, -bleed.trailing)
    }

    /// Lets a full-height line run on past its column by `lineBleed`.
    func bleedsVertically(_ bleed: EdgeInsets) -> some View {
        padding(.top, -bleed.top).padding(.bottom, -bleed.bottom)
    }
}

/// A side panel's lines reach its drag line across the gap between them; on the far side they keep what is outside.
private struct SidePanelBleed: ViewModifier {
    let edge: HorizontalEdge
    let gap: CGFloat
    @Environment(\.lineBleed) private var outer

    func body(content: Content) -> some View {
        var bleed = outer
        if edge == .leading { bleed.trailing = gap } else { bleed.leading = gap }
        return content.environment(\.lineBleed, bleed)
    }
}

/// How a side panel comes and goes: on the left it slides from its edge (a fade under Reduce Motion), on the right it is
/// there at once.
private struct SidePanelTransition: ViewModifier {
    let slides: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(!slides ? .identity : reduceMotion ? .opacity : AnyTransition.move(edge: .leading).combined(with: .opacity))
    }
}

extension View {
    /// Makes this a side panel on `edge` of the conversation: `SidePanelMetrics.gap` from the drag line on the
    /// conversation's side, as wide as `width` (see `resizablePanel`). On the left it slides in from its edge; on the right
    /// it is there at once (`sidePanelsOpenAtOnce`).
    func sidePanel(_ edge: HorizontalEdge, width: Binding<Double>, defaultWidth: Double,
                   minimum: Double = PanelLayout.minimumPanel, available: Double, rest: Double,
                   gap: CGFloat = SidePanelMetrics.gap) -> some View {
        let leading = edge == .leading
        return modifier(SidePanelBleed(edge: edge, gap: gap))
            .padding(leading ? Edge.Set.trailing : Edge.Set.leading, gap)
            .resizablePanel(width: width, defaultWidth: defaultWidth, minimum: minimum, available: available, rest: rest,
                            edge: leading ? HorizontalEdge.trailing : HorizontalEdge.leading, divider: true)
            .modifier(SidePanelTransition(slides: leading))
    }

    /// Opens and closes the side panels on the right of this view at once, without a slide: put it on the row that
    /// holds them and what they sit beside, with `shown` saying which of them show. When it changes, nothing in the row
    /// animates: the panel is simply there (or gone) and what sits beside it takes its new width in the same frame.
    /// A slide laid both out again on every frame (the conversation's text wrapped anew, a page in the panel resized),
    /// which made opening a panel stutter.
    func sidePanelsOpenAtOnce<Shown: Equatable>(_ shown: Shown) -> some View {
        transaction(value: shown) { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    /// Makes this a tab's list on the left: a side panel beside the conversation (`sidePanel`), or the whole width while
    /// the tab shows one column at a time (`PanelLayout.stacks`).
    @ViewBuilder
    func listPanel(stacked: Bool, width: Binding<Double>, defaultWidth: Double, available: Double, rest: Double) -> some View {
        if stacked {
            frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            // Leading: a row wider than the list (the footer in a narrow list) runs out on the right, instead of the
            // whole list being centered on it and pushed against the left edge.
            frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .modifier(ListPanelSide(width: width, defaultWidth: defaultWidth, available: available, rest: rest))
        }
    }

    /// Makes this a panel of fixed `width` on the right of what it sits beside (the docked session panel): the same
    /// room and gap as a resizable one, without the drag and without a line, so it reads as part of the conversation.
    func fixedSidePanel(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: CGFloat(PanelSplit.handle))
            self.modifier(SidePanelBleed(edge: .trailing, gap: SidePanelMetrics.gap))
                .frame(width: width).padding(.leading, SidePanelMetrics.gap)
        }
        .transition(.identity)
    }
}

/// A tab's list beside the conversation. As the sidebar of the main window its rows sit as far from the line as from
/// the window's edge (`PanelSidebarMetrics.inset`), instead of the wider room a list keeps in the notch.
private struct ListPanelSide: ViewModifier {
    let width: Binding<Double>
    let defaultWidth: Double
    let available: Double
    let rest: Double
    @Environment(\.panelSidebar) private var sidebar

    func body(content: Content) -> some View {
        // As the main window's sidebar the list is never narrower than its head (`PanelSidebarMetrics.minimumColumn`).
        content.sidePanel(.leading, width: width, defaultWidth: defaultWidth,
                          minimum: sidebar == nil ? PanelLayout.minimumList
                              : max(PanelLayout.minimumList, PanelSidebarMetrics.minimumColumn),
                          available: available, rest: rest,
                          gap: sidebar == nil ? SidePanelMetrics.listGap : SidePanelMetrics.sidebarGap)
    }
}

/// The top row of a side panel: what it shows on the left (a `SidePanelTitle`, or a picker), its own actions, and at
/// the end the close button every panel has.
struct SidePanelHeader<Leading: View, Actions: View>: View {
    let closeHelp: String
    let close: () -> Void
    let leading: Leading
    let actions: Actions

    init(closeHelp: String, close: @escaping () -> Void,
         @ViewBuilder leading: () -> Leading, @ViewBuilder actions: () -> Actions) {
        self.closeHelp = closeHelp
        self.close = close
        self.leading = leading()
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            leading
            Spacer(minLength: NookTheme.Spacing.xs)
            HStack(spacing: NookTheme.Spacing.xxs) {
                actions
                SidePanelCloseButton(help: closeHelp, action: close)
            }
        }
        .frame(height: SidePanelMetrics.header)
    }
}

extension SidePanelHeader where Actions == EmptyView {
    init(closeHelp: String, close: @escaping () -> Void,
         @ViewBuilder leading: () -> Leading) {
        self.init(closeHelp: closeHelp, close: close, leading: leading) { EmptyView() }
    }
}

/// The bar of what a tab shows, right under the panel's header or tabs: the same height and inset in every tab, with
/// the line under it (`divider`), so switching tabs never moves the content up or down.
struct SidePanelToolbar<Content: View>: View {
    var divider = false
    @ViewBuilder var content: () -> Content
    @Environment(\.lineBleed) private var bleed

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: NookTheme.Spacing.xs) { content() }
                .padding(.horizontal, NookTheme.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: SidePanelMetrics.toolbar)
            if divider { NookDivider().bleedsHorizontally(bleed) }
        }
        .padding(.bottom, SidePanelMetrics.toolbarGap)
    }
}

/// What a side panel shows, in its header: a quiet mark and the name ("Terminal", a file's name).
struct SidePanelTitle: View {
    let symbol: String
    let title: String
    var help: String? = nil

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            NookSymbol(symbol, size: 12)
                .font(NookTheme.font(11, .semibold))
                .foregroundStyle(NookTheme.textTertiary)
            Text(title)
                .font(NookTheme.TextStyle.strong)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(help ?? title)
    }
}

/// The last button of every side panel's header: a cross that puts the panel away, the same cross as on a tab.
struct SidePanelCloseButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        ToolbarIconButton("xmark", help, action)
    }
}

/// The first button of a conversation's header while its tab shows one column at a time (`PanelLayout.stacks`): back
/// to the list, the same chevron on every tab.
struct PanelBackButton: View {
    let action: () -> Void

    var body: some View {
        ToolbarIconButton("chevron.left", tr("a11y.back")) {
            withAnimation(NookTheme.reveal) { action() }
        }
    }
}

/// A button in a session's header that opens or closes the panel on `edge`: lit while it is open, with a dot when
/// that panel has something you have not seen.
struct SidePanelToggle: View {
    let edge: Edge
    /// A mark of its own, for a panel that is not simply the one on `edge`.
    var symbol: String? = nil
    let open: Bool
    var fresh = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(icon: symbol ?? edge.panelSymbol)
                .font(NookTheme.font(13, .medium))
                .foregroundStyle(open ? NookTheme.paper : NookTheme.textSecondary)
                .frame(width: 28, height: 28)
                .roundedBackground(open ? NookTheme.smoke : Color.clear, radius: NookTheme.Radius.control)
                .overlay(alignment: .topTrailing) {
                    if fresh {
                        Circle().fill(NookTheme.iris).frame(width: 5, height: 5).padding(NookTheme.Spacing.xs)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(NookTheme.reveal, value: fresh)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

// MARK: One panel on the right

/// From a session's workbench to the conversation inside it: opens a turn's diff in the Changes tab or a file step in the
/// File tab of the side panel on the right, and reports which file is shown.
/// A command the agent runs opens in the panel's Terminal tab (`toggleConsole`), with its output as it comes in.
struct SessionSideLink {
    var shownFile: String? = nil
    /// Whether the tool panel is open on the right: a file that opens by itself leaves it be.
    var panelOpen = false
    /// Whether the conversation sits beside a side panel at all: `showFile` does nothing where it does not.
    var hasPanel = false
    var showFile: (String) -> Void = { _ in }
    var openDiff: (TurnDiffSelection) -> Void = { _ in }
    /// Opens the command in the Terminal tab, or puts it away when that tab shows it already.
    var toggleConsole: (UUID) -> Void = { _ in }
}

extension SessionSideLink: Equatable {
    /// By what it says, not its actions: the workbench makes new closures on every redraw (they reach the same state), and an
    /// environment value that is never equal redrew every answer and row that reads it on each streamed token.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.shownFile == rhs.shownFile && lhs.panelOpen == rhs.panelOpen && lhs.hasPanel == rhs.hasPanel
    }
}

extension EnvironmentValues {
    @Entry var sessionSide = SessionSideLink()
    /// How far a conversation's header starts in: past the traffic lights and the list's toggle while the list is away.
    @Entry var sessionHeaderInset: CGFloat = 0
}

/// From the conversation up to its workbench: where its composer sits, so a page the agent opened floats just above it.
struct SessionComposerBounds: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

extension View {
    /// What takes the composer's place (an approval, a question) tells the workbench the same, so a page the agent opened
    /// floats above its buttons.
    func sessionComposerBounds() -> some View {
        anchorPreference(key: SessionComposerBounds.self, value: .bounds) { $0 }
    }
}

/// The conversation of a session above its composer: where the page its agent opened rests, for the row that floats it.
struct SessionBrowserRest: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

/// The room a side panel of `width` takes with its drag line and gap.
enum SidePanelRoom {
    static func of(_ width: Double) -> Double { width + PanelSplit.handle + Double(SidePanelMetrics.gap) }
}
