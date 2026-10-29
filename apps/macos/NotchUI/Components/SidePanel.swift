import SwiftUI

// One side panel for everything that opens beside a conversation or a list: the lists of the Nook, Agents and Chats
// tabs, a command's terminal, the tool panel with its tabs, a turn's diff or a file, a pull request beside its list, an
// artifact beside its app, and the docked session panel. They all work the same way:
//
// - Each sits flat on the canvas with a line on the side of what it sits beside: a drag line (drag to resize,
//   double-click for its usual width, `.sidePanel(_:width:…)`), or a plain line for a panel of fixed width
//   (`.fixedSidePanel(width:)`). Each slides in from its own edge.
// - Each starts with a header of the same height (`SidePanelHeader`, or `SidePanelTabBar` for the tool panel) that
//   ends in the same close button: a cross (`SidePanelCloseButton`).
// - A session's header has one toggle per side (`SidePanelToggle`): the list on the left, the bottom panel, the side
//   panel on the right, each with the mark of its side (`Edge.panelSymbol`), lit while it is open.
// - The tool panel and a diff or file the conversation opens take turns on the right instead of stacking
//   (`SessionSideLink`, `SessionDetailOpen`).

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
    /// Room between a panel and the drag line on the conversation's side.
    static let gap: CGFloat = NookTheme.Spacing.sm
}

extension View {
    /// Makes this a side panel on `edge` of the conversation: `SidePanelMetrics.gap` from the drag line on the
    /// conversation's side, as wide as `width` (see `resizablePanel`), sliding in from its own edge.
    func sidePanel(_ edge: HorizontalEdge, width: Binding<Double>, defaultWidth: Double,
                   minimum: Double = PanelLayout.minimumPanel, available: Double, rest: Double) -> some View {
        let leading = edge == .leading
        return padding(leading ? Edge.Set.trailing : Edge.Set.leading, SidePanelMetrics.gap)
            .resizablePanel(width: width, defaultWidth: defaultWidth, minimum: minimum, available: available, rest: rest,
                            edge: leading ? HorizontalEdge.trailing : HorizontalEdge.leading, divider: true)
            .transition(.move(edge: leading ? Edge.leading : Edge.trailing).combined(with: .opacity))
    }

    /// Makes this a panel of fixed `width` on the right of what it sits beside (the docked session panel): the same
    /// line and gap as a resizable one, without the drag.
    func fixedSidePanel(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            NookDivider(vertical: true).frame(width: CGFloat(PanelSplit.handle))
            self.frame(width: width).padding(.leading, SidePanelMetrics.gap)
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}

/// The top row of a side panel: what it shows on the left (a `SidePanelTitle`, or a picker), its own actions, and at
/// the end the buttons every panel has: wider or narrower when `wide` is given, then the close button.
struct SidePanelHeader<Leading: View, Actions: View>: View {
    let closeHelp: String
    let wide: Binding<Bool>?
    let close: () -> Void
    let leading: Leading
    let actions: Actions

    init(closeHelp: String, wide: Binding<Bool>? = nil, close: @escaping () -> Void,
         @ViewBuilder leading: () -> Leading, @ViewBuilder actions: () -> Actions) {
        self.closeHelp = closeHelp
        self.wide = wide
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
                if let wide { SidePanelWidenButton(wide: wide) }
                SidePanelCloseButton(help: closeHelp, action: close)
            }
        }
        .frame(height: SidePanelMetrics.header)
    }
}

extension SidePanelHeader where Actions == EmptyView {
    init(closeHelp: String, wide: Binding<Bool>? = nil, close: @escaping () -> Void,
         @ViewBuilder leading: () -> Leading) {
        self.init(closeHelp: closeHelp, wide: wide, close: close, leading: leading) { EmptyView() }
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

/// Wider or narrower: switches a panel between its two usual widths (`PanelLayout.wide`).
private struct SidePanelWidenButton: View {
    @Binding var wide: Bool

    var body: some View {
        ToolbarIconButton(wide ? "arrow.right.to.line" : "arrow.left.to.line", tr(wide ? "ws.outputs.narrow" : "ws.outputs.widen")) {
            withAnimation(NookTheme.reveal) { wide.toggle() }
        }
    }
}

/// A button in a session's header that opens or closes the panel on `edge`: lit while it is open, with a dot when
/// that panel has something you have not seen.
struct SidePanelToggle: View {
    let edge: Edge
    let open: Bool
    var fresh = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: edge.panelSymbol)
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(open ? NookTheme.paper : NookTheme.textSecondary)
                .frame(width: 26, height: ToolbarGroup.itemHeight)
                .background(RoundedRectangle(cornerRadius: ToolbarGroup.itemRadius, style: .continuous)
                    .fill(open ? NookTheme.smoke : Color.clear))
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

/// From a session's workbench to the conversation inside it. The tool panel and a diff or file the conversation shows
/// beside itself take turns: `toolOpen` says the tool panel is open (the diff or file closes for it), and `makeRoom`
/// closes the tool panel for a diff or file.
struct SessionSideLink {
    var toolOpen = false
    var makeRoom: () -> Void = {}
}

extension EnvironmentValues {
    @Entry var sessionSide = SessionSideLink()
}

/// From the conversation up to its workbench: it shows a diff or a file beside itself, which takes room from the docked
/// session panel, and a new plan does not push it away.
struct SessionDetailOpen: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension View {
    /// For a conversation that shows a diff or a file beside itself (`detailOpen`): opening one closes the tool panel,
    /// and opening the tool panel closes it (`closeDetail`), so the two never stack.
    func sharesSessionSide(detailOpen: Bool, closeDetail: @escaping () -> Void) -> some View {
        modifier(SessionSideShare(detailOpen: detailOpen, closeDetail: closeDetail))
    }
}

private struct SessionSideShare: ViewModifier {
    @Environment(\.sessionSide) private var link
    let detailOpen: Bool
    let closeDetail: () -> Void

    func body(content: Content) -> some View {
        content
            .preference(key: SessionDetailOpen.self, value: detailOpen)
            .onChange(of: detailOpen) { _, open in
                if open { link.makeRoom() }
            }
            .onChange(of: link.toolOpen) { _, open in
                if open { withAnimation(NookTheme.reveal) { closeDetail() } }
            }
    }
}
