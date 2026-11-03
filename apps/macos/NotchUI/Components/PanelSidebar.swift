import SwiftUI

// The main window's sidebar: one column along the window's left edge, from the title bar to the bottom.
// On top Nook with talk and split view, then the tabs (Nook, Agents, Chats, Music) and Search as rows, then the list of
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
    /// Nook himself with his task ring, at the head of the sidebar.
    let orb: AnyView
}

enum PanelSidebarMetrics {
    /// Nook's size at the head of the sidebar: his ring stays inside the row of a session's header beside it.
    static let orb: CGFloat = 22
    /// The head of the sidebar is as tall as a session's header, so the two read as one line across the window.
    static let head: CGFloat = 30
    /// A tab row.
    static let row: CGFloat = 30
    /// Room between the window's edge and the sidebar's rows.
    static let inset: CGFloat = NookTheme.Spacing.md
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

/// The head of the sidebar: Nook with talk and split view, the tabs, and Search. Nothing outside the main window.
/// `compact` is the rail of icons the Chats tab folds its sidebar into.
struct PanelSidebarTop: View {
    var compact = false
    @Environment(\.panelSidebar) private var context

    var body: some View {
        if let context {
            VStack(alignment: compact ? .center : .leading, spacing: NookTheme.Spacing.xxs) {
                head(context)
                    .padding(.bottom, NookTheme.Spacing.sm)
                ForEach(Array(context.tabs.enumerated()), id: \.element.id) { index, item in
                    PanelSidebarRow(symbol: PanelSplitChoice.symbol(item.value), title: item.title, count: item.count,
                                    shortcut: "⌘\(index + 1)", selected: item.value == context.selected,
                                    beside: item.value == context.beside, compact: compact) {
                        context.select(item.value)
                    }
                }
                PanelSidebarRow(symbol: "magnifyingglass", title: tr("search.sidebar"), shortcut: "⌘K", compact: compact,
                                help: tr("search.button"), action: context.search)
                NookDivider()
                    .padding(.top, NookTheme.Spacing.sm)
                    .padding(.bottom, NookTheme.Spacing.xs)
            }
            .preference(key: PanelSidebarShown.self, value: true)
        }
    }

    private func head(_ context: PanelSidebarContext) -> some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            context.orb
                .frame(width: PanelSidebarMetrics.head, height: PanelSidebarMetrics.head)
            if !compact {
                Spacer(minLength: NookTheme.Spacing.xs)
                NookIconButton(systemName: "mic", label: tr("button.talk"), size: 28, action: context.talk)
                PanelSplitButton(current: context.current)
            }
        }
        .frame(height: PanelSidebarMetrics.head)
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
    }
}

/// A tab in the sidebar: its mark and name, what waits on it as an amber count, and its shortcut under the pointer.
/// Selected on `rowSelected`; the tab split view shows beside it outlined. In the rail only the mark, centered.
private struct PanelSidebarRow: View {
    let symbol: String
    let title: String
    var count = 0
    let shortcut: String
    var selected = false
    var beside = false
    var compact = false
    var help: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.md) {
                Image(systemName: symbol)
                    .font(NookTheme.font(12.5, .medium))
                    .frame(width: 18)
                    .overlay(alignment: .topTrailing) {
                        if compact && count > 0 {
                            Circle().fill(NookTheme.amber).frame(width: 6, height: 6).offset(x: 3, y: -2)
                        }
                    }
                if !compact {
                    Text(title)
                        .font(NookTheme.TextStyle.body)
                        .lineLimit(1)
                    Spacer(minLength: NookTheme.Spacing.xs)
                    if count > 0 {
                        NookCountBadge(count: count)
                    } else {
                        Text(shortcut)
                            .font(NookTheme.TextStyle.caption)
                            .foregroundStyle(NookTheme.textTertiary)
                            .opacity(hovering ? 1 : 0)
                    }
                }
            }
            .foregroundStyle(selected || hovering ? NookTheme.paper : NookTheme.textSecondary)
            .padding(.horizontal, compact ? 0 : NookTheme.Spacing.md)
            .frame(maxWidth: compact ? PanelSidebarMetrics.row + NookTheme.Spacing.sm : .infinity,
                   minHeight: PanelSidebarMetrics.row, maxHeight: PanelSidebarMetrics.row)
            .background(shape.fill(NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear)))
            .overlay { if beside { shape.strokeBorder(NookTheme.border, lineWidth: 1) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(help ?? "\(title) (\(shortcut))")
        .accessibilityLabel(count > 0 ? "\(title), \(count)" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(beside ? tr("split.beside") : "")
    }
}

extension View {
    /// The first column of a tab in the main window, which starts with `PanelSidebarTop`: its rows keep
    /// `PanelSidebarMetrics.inset` from the window's edge. Elsewhere unchanged.
    func panelSidebarColumn() -> some View {
        modifier(PanelSidebarColumn())
    }
}

private struct PanelSidebarColumn: ViewModifier {
    @Environment(\.panelSidebar) private var context

    func body(content: Content) -> some View {
        content
            .padding(.leading, context == nil ? 0 : PanelSidebarMetrics.inset)
            .environment(\.inPanelSidebar, context != nil)
    }
}
