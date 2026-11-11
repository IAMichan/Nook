import SwiftUI
import UniformTypeIdentifiers

// The side panel's tabs and its list of tools: small tabs that each carry what
// they show (the page's title, the pull request's number and title), with a cross at the end that closes them;
// + right after the last tab; and with no tab open a short list to open one, each row with the key that opens it.

extension EnvironmentValues {
    /// Whether what a panel shows may take the keyboard when it appears (the list of tools, a terminal, a file being
    /// edited). A session that opens with its side panel already open keeps the keyboard in its own composer; the panel
    /// takes it only once you open something in it.
    @Entry var sidePanelTakesFocus = true
}

/// One tab of the side panel: what it shows, as `SidePanelTabBar` draws it.
struct SidePanelTabItem<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    /// The mark before the title.
    let icon: AnyView
    /// Something in it you have not looked at yet: a small dot on the icon.
    var fresh = false
    var help: String? = nil
    /// A small control right after the tab, such as the browser's + for another browser tab.
    var after: AnyView? = nil
    /// Kept at the front of the row: it shows a pin where the others show a cross, and is closed from its menu.
    var pinned = false
    var id: Value { value }
}

/// The side panel's tab row: the tabs scroll sideways when they do not fit, + follows the last one, and `trailing`
/// (the button that closes the panel) stays at the end.
struct SidePanelTabBar<Value: Hashable, Add: View, Trailing: View>: View {
    let items: [SidePanelTabItem<Value>]
    let selected: Value
    let onSelect: (Value) -> Void
    let onClose: (Value) -> Void
    /// Dragging a tab onto another puts it in that place (`SidePanelTabOrder`). Nil keeps the order as it is.
    var onMove: ((_ moved: Value, _ onto: Value) -> Void)? = nil
    /// Pins a tab to the front of the row, or lets it go again (its context menu). Nil offers no pin.
    var onTogglePin: ((Value) -> Void)? = nil
    @State private var dragging: Value?
    @ViewBuilder var add: () -> Add
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NookTheme.Spacing.xs) {
                        ForEach(items) { item in
                            SidePanelTab(item: item, active: item.value == selected,
                                         select: { onSelect(item.value) }, close: { onClose(item.value) },
                                         togglePin: onTogglePin.map { toggle in { toggle(item.value) } })
                                .modifier(SidePanelTabReorder(value: item.value, dragging: $dragging, move: onMove))
                                .id(item.value)
                            if let after = item.after { after }
                        }
                        add()
                    }
                }
                .onChange(of: selected) { _, value in
                    withAnimation(NookTheme.scroll) { proxy.scrollTo(value) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .frame(height: SidePanelMetrics.header)
    }
}

/// A small tab: the icon and the title, on a soft fill while selected. Under the pointer the cross that closes it takes
/// the icon's place, so a tab never changes width and a row of tabs stays free of crosses.
private struct SidePanelTab<Value: Hashable>: View {
    let item: SidePanelTabItem<Value>
    let active: Bool
    let select: () -> Void
    let close: () -> Void
    var togglePin: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            ZStack {
                item.icon
                    .overlay(alignment: .bottomTrailing) {
                        if item.fresh {
                            Circle().fill(NookTheme.iris).frame(width: 5, height: 5).offset(x: 2, y: 2)
                        }
                    }
                    .opacity(hovering && !item.pinned ? 0 : 1)
                    .accessibilityHidden(true)
                Button(action: close) {
                    Image(icon: "xmark")
                        .font(NookTheme.font(9, .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.nookPlain)
                .opacity(hovering && !item.pinned ? 1 : 0)
                .allowsHitTesting(hovering && !item.pinned)
                .help(tr("tab.close"))
                .accessibilityLabel(tr("tab.close") + " " + item.title)
            }
            .frame(width: 16, height: 16)
            Button(action: select) {
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 108, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            .help(item.help ?? item.title)
            if item.pinned {
                Image(icon: "pin.fill")
                    .font(NookTheme.font(8, .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
                    .accessibilityLabel(tr("tab.pinned"))
            }
        }
        .font(NookTheme.TextStyle.detail)
        .foregroundStyle(active || hovering ? NookTheme.paper : NookTheme.textSecondary)
        .padding(.leading, NookTheme.Spacing.sm)
        .padding(.trailing, NookTheme.Spacing.md)
        .frame(height: 24)
        .roundedBackground(NookTheme.rowFill(selected: active, hovering: hovering, rest: .clear), radius: NookTheme.Radius.chip)
        .contentShape(Rectangle())
        .nookClickable()
        .onTapGesture(perform: select)
        // In the main window the tabs lie in the title bar's row, where `onHover` hears nothing.
        .trackedHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .contextMenu {
            if let togglePin {
                Button(item.pinned ? tr("tab.unpin") : tr("tab.pin"), action: togglePin)
            }
            Button(tr("tab.close"), action: close)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Makes a tab draggable and a place to drop one: the tab being dragged takes the place of the one it is over at once,
/// so the row shows where it will land. Without `move` the tab is left as it is.
private struct SidePanelTabReorder<Value: Hashable>: ViewModifier {
    let value: Value
    @Binding var dragging: Value?
    let move: ((Value, Value) -> Void)?

    func body(content: Content) -> some View {
        if let move {
            content
                .onDrag {
                    dragging = value
                    return NSItemProvider(object: "nook.sidepanel.tab" as NSString)
                }
                .onDrop(of: [.plainText], delegate: SidePanelTabDrop(target: value, dragging: $dragging, move: move))
        } else {
            content
        }
    }
}

private struct SidePanelTabDrop<Value: Hashable>: DropDelegate {
    let target: Value
    @Binding var dragging: Value?
    let move: (Value, Value) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(NookTheme.swap) { move(dragging, target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// One choice in `SidePanelLauncher`.
struct SidePanelLaunch: Identifiable {
    let id: String
    let symbol: String
    let title: String
    /// The letter that opens it while the list is in view.
    let key: Character
    /// Nil when it can be opened; otherwise why not, shown when you hover the dimmed row.
    var disabledReason: String? = nil
    let open: () -> Void
}

/// The open side panel before any tab: a title and one row per tool with its icon,
/// its name and the key that opens it. ↑ and ↓ move the highlight, Return opens it, and a row's letter opens it at once.
struct SidePanelLauncher: View {
    let title: String
    let items: [SidePanelLaunch]
    @State private var highlight: Int?
    @FocusState private var focused: Bool
    @Environment(\.sidePanelTakesFocus) private var takesFocus

    private var available: [SidePanelLaunch] { items.filter { $0.disabledReason == nil } }

    var body: some View {
        VStack(spacing: NookTheme.Spacing.lg) {
            Text(title)
                .font(NookTheme.TextStyle.strong)
                .foregroundStyle(NookTheme.paper)
            VStack(spacing: NookTheme.Spacing.xxs) {
                ForEach(items) { item in
                    row(item)
                }
            }
            .frame(maxWidth: 320)
        }
        .padding(.horizontal, NookTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { if takesFocus { focused = true } }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.return) {
            guard let highlight, available.indices.contains(highlight) else { return .ignored }
            available[highlight].open()
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]),
                  let letter = press.characters.lowercased().first,
                  let item = available.first(where: { Character($0.key.lowercased()) == letter }) else { return .ignored }
            item.open()
            return .handled
        }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !available.isEmpty else { return .ignored }
        let count = available.count
        highlight = highlight.map { ($0 + step + count) % count } ?? (step > 0 ? 0 : count - 1)
        return .handled
    }

    private func row(_ item: SidePanelLaunch) -> some View {
        let enabled = item.disabledReason == nil
        let lit = enabled && available.firstIndex(where: { $0.id == item.id }) == highlight
        return Button(action: item.open) {
            HStack(spacing: 10) {
                NookSymbol(item.symbol, size: 16)
                    .font(NookTheme.font(13, .medium))
                    .frame(width: 16)
                Text(item.title).lineLimit(1)
                Spacer(minLength: NookTheme.Spacing.sm)
                Text(String(item.key).uppercased())
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .frame(minWidth: 20, minHeight: 20)
                    .roundedBackground(NookTheme.line2, radius: NookTheme.Radius.chip)
            }
            .font(NookTheme.TextStyle.body)
            .foregroundStyle(enabled ? NookTheme.paper : NookTheme.textTertiary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .roundedBackground(lit ? NookTheme.smoke : Color.clear, radius: NookTheme.Radius.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .help(item.disabledReason ?? item.title)
        .onHover { inside in
            guard enabled, let index = available.firstIndex(where: { $0.id == item.id }) else { return }
            if inside { highlight = index } else if highlight == index { highlight = nil }
        }
    }
}
