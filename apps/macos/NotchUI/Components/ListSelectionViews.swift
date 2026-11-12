import AppKit
import SwiftUI

// The pieces the Nooks and the Agents list share for acting on several rows at once: the round check in front of each
// row and the bar with the count and the actions. Selecting starts with a ⌘- or ⇧-click on a row; the rules are in
// `ListSelection`.

/// A row while selecting: a round check in front, and a ring around the row when it is picked.
struct SelectableRow: ViewModifier {
    let active: Bool
    let selected: Bool
    let toggle: () -> Void

    func body(content: Content) -> some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            if active {
                Button(action: toggle) {
                    Image(icon: selected ? "checkmark.circle.fill" : "circle")
                        .font(NookTheme.font(14))
                        .foregroundStyle(selected ? NookTheme.iris : NookTheme.textTertiary)
                        .frame(width: 22, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.nookPlain)
                .accessibilityLabel(tr("select.start"))
                .padding(.leading, 2)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            content
                .roundedStroke(NookTheme.iris.opacity(selected ? 0.55 : 0), radius: NookTheme.Radius.panel)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension View {
    func selectable(active: Bool, selected: Bool, toggle: @escaping () -> Void) -> some View {
        modifier(SelectableRow(active: active, selected: selected, toggle: toggle))
    }
}

/// One action in the selection bar.
struct SelectionAction: Identifiable {
    let symbol: String
    let label: String
    var destructive = false
    var enabled = true
    /// Asked in the bar before the action runs, with Cancel and `confirmTitle` beside it.
    var confirm: String?
    /// The button that sends it after the question ("Yes, merge"); the label when nil.
    var confirmTitle: String?
    /// Under the question: what it will touch, and what it leaves out.
    var confirmDetail: String?
    /// How many of the picked rows it applies to, on its button as "Merge (2 of 3)" when that is not all of them.
    var count: Int?
    /// The bar's main action: filled, and the last button.
    var primary = false
    /// Why it leaves rows out, on its tooltip: all of them while it is off, the ones it skips while it runs on fewer.
    var leftOutHelp: String?
    /// A line to write in under the question before it runs (a comment that goes with a close), with its placeholder.
    /// Nil for none.
    var note: Binding<String>? = nil
    var notePlaceholder: String? = nil
    let perform: () -> Void
    var id: String { symbol + label }
}

/// The bar under a list while selecting, kept compact and centred however wide the list is. On top how many are
/// picked (with an optional line saying which), select all and done; under it the actions as buttons with their names,
/// the main one filled. Names give way to icons only where the list is too narrow for them. An action that cannot be
/// undone asks first: the bar then says what will happen, with Cancel and the button that does it.
struct SelectionBar: View {
    let count: Int
    let allSelected: Bool
    let actions: [SelectionAction]
    /// Under the count: which rows these are, or what the actions will do with them.
    var detail: String? = nil
    let toggleAll: () -> Void
    let done: () -> Void
    @State private var confirming: String?

    /// The bar never gets wider than this: on a wide page its ends would be too far apart to read as one thing.
    private static let maxWidth: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            if let asking = actions.first(where: { $0.id == confirming }) {
                question(asking)
            } else {
                header
                actionRow
            }
        }
        .padding(NookTheme.Spacing.md + NookTheme.Spacing.xxs)
        .frame(maxWidth: Self.maxWidth)
        .roundedBackground(NookTheme.graphite, radius: NookTheme.Radius.panel)
        .roundedStroke(NookTheme.line2, radius: NookTheme.Radius.panel)
        .frame(maxWidth: .infinity)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onChange(of: count) { _, _ in confirming = nil }
        .animation(NookTheme.hover, value: confirming)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(count == 0 ? tr("select.none") : tr("select.count", count))
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                if let detail, count > 0 {
                    Text(detail)
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(3)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            textButton(allSelected ? tr("button.clear") : tr("select.all"), action: toggleAll)
                .keyboardShortcut("a", modifiers: .command)
            textButton(tr("select.done"), action: done)
                .keyboardShortcut(.escape, modifiers: [])
        }
    }

    /// The actions with their names; only icons where that does not fit. The main one sits last, on the right.
    private var actionRow: some View {
        let ordered = actions.filter { !$0.primary } + actions.filter(\.primary)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: NookTheme.Spacing.xs) {
                ForEach(ordered.filter { !$0.primary }) { actionButton($0, labeled: true) }
                Spacer(minLength: NookTheme.Spacing.sm)
                ForEach(ordered.filter(\.primary)) { actionButton($0, labeled: true) }
            }
            HStack(spacing: NookTheme.Spacing.xs) {
                ForEach(ordered) { actionButton($0, labeled: false) }
                Spacer(minLength: 0)
            }
        }
    }

    /// "Merge 2 pull requests?", what it touches, and Cancel beside the button that does it.
    private func question(_ action: SelectionAction) -> some View {
        AdaptiveActionRow(alignment: .center) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(action.confirm ?? action.label)
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(action.destructive ? NookTheme.coral : NookTheme.paper)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = action.confirmDetail {
                    Text(detail)
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = action.note {
                    TextField(action.notePlaceholder ?? "", text: note, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(NookTheme.TextStyle.body)
                        .lineLimit(1...4)
                        .padding(.horizontal, NookTheme.Spacing.md)
                        .padding(.vertical, NookTheme.Spacing.sm)
                        .roundedBackground(NookTheme.field, radius: NookTheme.Radius.control)
                        .padding(.top, NookTheme.Spacing.xs)
                }
            }
        } actions: {
            SmallGhostButton(title: tr("button.cancel")) { confirming = nil }
                .keyboardShortcut(.escape, modifiers: [])
            if action.destructive {
                destructiveButton(action.confirmTitle ?? action.label) { send(action) }
            } else {
                SmallPrimaryButton(title: action.confirmTitle ?? action.label, systemName: action.symbol) { send(action) }
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    private func run(_ action: SelectionAction) {
        if action.confirm != nil {
            confirming = action.id
            return
        }
        send(action)
    }

    private func send(_ action: SelectionAction) {
        confirming = nil
        action.perform()
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(NookTheme.iris)
                .fixedSize()
        }
        .buttonStyle(.nookPlain)
    }

    private func title(_ action: SelectionAction) -> String {
        guard let shown = action.count, shown != count else { return action.label }
        return tr("select.partial", action.label, shown, count)
    }

    @ViewBuilder
    private func actionButton(_ action: SelectionAction, labeled: Bool) -> some View {
        let usable = action.enabled && count > 0
        Group {
            if labeled, action.primary {
                SmallPrimaryButton(title: title(action), systemName: action.symbol) { run(action) }
            } else {
                Button { run(action) } label: {
                    HStack(spacing: NookTheme.Spacing.xs) {
                        // NookSymbol: an SF Symbol name, or one of Nook's own marks (a pull request's merged or closed state).
                        NookSymbol(action.symbol, size: 12)
                            .font(NookTheme.font(12, .medium))
                        if labeled {
                            Text(title(action)).font(NookTheme.TextStyle.strong).lineLimit(1).fixedSize()
                        }
                    }
                    .foregroundStyle(action.destructive ? NookTheme.coral : (action.primary ? NookTheme.iris : NookTheme.paper))
                    .padding(.horizontal, labeled ? NookTheme.Spacing.md : 0)
                    .frame(minWidth: 30)
                    .frame(height: labeled ? 30 : 26)
                    .roundedBackground(NookTheme.field, radius: NookTheme.Radius.control)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.nookPlain)
                .opacity(usable ? 1 : 0.4)
            }
        }
        .disabled(!usable)
        .help(tooltip(action, usable: usable))
        .accessibilityLabel(action.label)
    }

    /// The name, and why rows are left out when the action skips some or cannot run at all.
    private func tooltip(_ action: SelectionAction, usable: Bool) -> String {
        guard let leftOut = action.leftOutHelp, !leftOut.isEmpty else { return action.label }
        if !usable { return leftOut }
        guard let shown = action.count, shown != count else { return action.label }
        return title(action) + "\n" + leftOut
    }

    private func destructiveButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(NookTheme.TextStyle.strong)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, NookTheme.Spacing.md)
                .frame(height: 30)
                .roundedBackground(NookTheme.coral.opacity(0.85), radius: NookTheme.Radius.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
    }
}

/// What a click on a row means right now: ⌘ and ⇧ pick rows, as in any Mac list.
enum SelectionClick {
    @MainActor static func modifiers() -> (command: Bool, shift: Bool) {
        let flags = NSEvent.modifierFlags
        return (flags.contains(.command), flags.contains(.shift))
    }
}
