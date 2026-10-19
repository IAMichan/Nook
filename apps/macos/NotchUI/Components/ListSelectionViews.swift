import AppKit
import SwiftUI

// The pieces the Nooks and the Agents list share for acting on several rows at once: the button that starts selecting,
// the round check in front of each row, and the bar with the count and the actions. The rules are in `ListSelection`.

/// "Select" next to the search field; while selecting it ends it again.
struct SelectionModeButton: View {
    let active: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: active ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? NookTheme.paper : NookTheme.textSecondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(active ? NookTheme.smoke : NookTheme.field))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(active ? tr("select.done") : tr("select.help"))
        .accessibilityLabel(active ? tr("select.done") : tr("select.start"))
    }
}

/// A row while selecting: a round check in front, and a ring around the row when it is picked.
struct SelectableRow: ViewModifier {
    let active: Bool
    let selected: Bool
    let toggle: () -> Void

    func body(content: Content) -> some View {
        HStack(spacing: 4) {
            if active {
                Button(action: toggle) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(selected ? NookTheme.iris : NookTheme.textTertiary)
                        .frame(width: 22, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            content
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(NookTheme.iris.opacity(selected ? 0.55 : 0), lineWidth: 1))
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
    /// Asked in the bar before the action runs; the second click confirms.
    var confirm: String?
    let perform: () -> Void
    var id: String { symbol + label }
}

/// The bar under a list while selecting: how many are picked, select all, done, and the actions as icons. An action
/// that cannot be undone asks first, in place of the count.
struct SelectionBar: View {
    let count: Int
    let allSelected: Bool
    let actions: [SelectionAction]
    let toggleAll: () -> Void
    let done: () -> Void
    @State private var confirming: String?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(confirmText ?? (count == 0 ? tr("select.none") : tr("select.count", count)))
                    .font(NookTheme.font(12, .medium))
                    .foregroundStyle(confirmText == nil ? NookTheme.textSecondary : NookTheme.coral)
                    .lineLimit(1)
                Spacer(minLength: 4)
                textButton(allSelected ? tr("button.clear") : tr("select.all"), action: toggleAll)
                    .keyboardShortcut("a", modifiers: .command)
                textButton(tr("select.done"), action: done)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            HStack(spacing: 4) {
                ForEach(actions) { action in
                    iconButton(action)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(NookTheme.smoke))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onChange(of: count) { _, _ in confirming = nil }
    }

    private var confirmText: String? {
        guard let confirming else { return nil }
        return actions.first { $0.id == confirming }?.confirm
    }

    private func run(_ action: SelectionAction) {
        if action.confirm != nil, confirming != action.id {
            confirming = action.id
            return
        }
        confirming = nil
        action.perform()
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(NookTheme.font(12, .semibold))
                .foregroundStyle(NookTheme.iris)
                .fixedSize()
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ action: SelectionAction) -> some View {
        let usable = action.enabled && count > 0
        let asking = confirming == action.id
        return Button { run(action) } label: {
            Image(systemName: action.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(asking ? NookTheme.paper : (action.destructive ? NookTheme.coral : NookTheme.paper))
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(asking ? NookTheme.coral.opacity(0.8) : NookTheme.field))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .opacity(usable ? 1 : 0.4)
        .help(action.label)
        .accessibilityLabel(action.label)
    }
}

/// What a click on a row means right now: ⌘ and ⇧ pick rows, as in any Mac list.
enum SelectionClick {
    @MainActor static func modifiers() -> (command: Bool, shift: Bool) {
        let flags = NSEvent.modifierFlags
        return (flags.contains(.command), flags.contains(.shift))
    }
}
