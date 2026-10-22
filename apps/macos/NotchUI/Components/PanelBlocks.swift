import SwiftUI

// The small building blocks every tab and page repeats: a search field, a list's title row, a count, a section label,
// a divider, a notice bar under the tabs, and the quiet card that groups rows. Each one looks and behaves the same
// wherever it is used, so a change here changes every place at once. Never rebuild one of these inline.

/// The one search field: a magnifying glass, the text, and a clear button once there is something to clear. Escape
/// clears it too. `panel` sits in a list in the notch or window (a soft filled field), `inline` sits in a Settings form
/// row (the form draws the row), `large` heads a command palette.
struct NookSearchField: View {
    enum Style { case panel, inline, large }

    let prompt: String
    @Binding var text: String
    var style: Style = .panel
    /// Focus from the view that owns the field, e.g. to focus it with ⌘F or when a palette opens.
    var focus: FocusState<Bool>.Binding? = nil
    var onSubmit: (() -> Void)? = nil
    /// Escape after the text is cleared (e.g. to close a palette or drop focus).
    var onEscape: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(NookTheme.font(style == .large ? 13 : 11, .medium))
                .foregroundStyle(NookTheme.textTertiary)
                .accessibilityHidden(true)
            field
            if !text.isEmpty {
                ToolbarIconButton("xmark.circle.fill", tr("button.clear"), height: 20, width: 20) { text = "" }
            }
        }
        .padding(.horizontal, style == .inline ? 0 : NookTheme.Spacing.md)
        .frame(height: height)
        .background {
            if style == .panel {
                RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous).fill(NookTheme.field)
            }
        }
    }

    private var height: CGFloat? {
        switch style {
        case .panel: return 30
        case .inline: return nil
        case .large: return 44
        }
    }

    @ViewBuilder
    private var field: some View {
        let base = TextField("", text: $text, prompt: Text(prompt).foregroundStyle(NookTheme.textTertiary))
            .textFieldStyle(.plain)
            .font(style == .large ? NookTheme.font(14) : NookTheme.TextStyle.body)
            .foregroundStyle(NookTheme.paper)
            .onSubmit { onSubmit?() }
            .onExitCommand {
                if text.isEmpty { onEscape?() } else { text = "" }
            }
            .accessibilityLabel(prompt)
        if let focus {
            base.focused(focus)
        } else {
            base
        }
    }
}

/// How many things wait for you: a small amber count (a tab, a list's title). Zero shows nothing.
struct NookCountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(NookTheme.rounded(10, .semibold))
                .foregroundStyle(NookTheme.ink)
                .padding(.horizontal, NookTheme.Spacing.xs)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(NookTheme.amber))
        }
    }
}

/// The title row on top of a tab's list (Nook, Agents, Chats, Pull requests): the name, what waits, and the list's own
/// actions on the right. Every list starts with this same row, so the lists line up when you switch tabs.
struct PanelListHeader<Trailing: View>: View {
    let title: String
    var count: Int = 0
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, count: Int = 0, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.count = count
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Text(title)
                .font(NookTheme.TextStyle.title)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
            NookCountBadge(count: count)
            Spacer(minLength: NookTheme.Spacing.xs)
            HStack(spacing: NookTheme.Spacing.xxs) { trailing() }
        }
        .frame(height: 30)
        .padding(.leading, NookTheme.Spacing.lg)
    }
}

extension PanelListHeader where Trailing == EmptyView {
    init(_ title: String, count: Int = 0) {
        self.init(title, count: count) { EmptyView() }
    }
}

/// "New" in a list's title row (a new Nook, a new session): lit while the new one is what is open.
struct PanelNewButton: View {
    let label: String
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.pencil")
                .font(NookTheme.font(13, .medium))
                .foregroundStyle(active || hovering ? NookTheme.paper : NookTheme.textSecondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
                    .fill(active || hovering ? NookTheme.smoke : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A group's name inside a list or a page ("Pinned", "For you"): small, quiet, never uppercase.
struct NookSectionLabel: View {
    let title: String
    /// Lines the label up with the text of the rows under it: a list's rows by default, a page's own edge with less.
    var inset: CGFloat = NookTheme.Spacing.lg

    init(_ title: String, inset: CGFloat = NookTheme.Spacing.lg) {
        self.title = title
        self.inset = inset
    }

    var body: some View {
        Text(title)
            .font(NookTheme.TextStyle.label)
            .foregroundStyle(NookTheme.textTertiary)
            .lineLimit(1)
            .padding(.horizontal, inset)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A filter chip in a row of them ("All", "Sessions 4"): a quiet capsule, filled with the accent when chosen, with an
/// optional count after the title.
struct NookFilterChip: View {
    let title: String
    var count: Int? = nil
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.xs) {
                Text(title).font(NookTheme.TextStyle.label)
                if let count {
                    Text("\(count)").font(NookTheme.rounded(11, .medium)).opacity(0.7)
                }
            }
            .foregroundStyle(selected ? NookTheme.onIris : (hovering ? NookTheme.paper : NookTheme.textStrong))
            .padding(.horizontal, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
            .padding(.vertical, NookTheme.Spacing.xs + 1)
            .background(Capsule().fill(selected ? NookTheme.iris : NookTheme.smoke))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The one hairline between rows or regions. `inset` leaves room on the leading side (under a row's icon).
struct NookDivider: View {
    var vertical = false
    var inset: CGFloat = 0

    var body: some View {
        if vertical {
            Rectangle().fill(NookTheme.line2).frame(width: 1)
        } else {
            Rectangle().fill(NookTheme.line2).frame(height: 1).padding(.leading, inset)
        }
    }
}

/// The line between two items of a list (a Nook chat, an agent session, a chat): clearer than a `NookDivider`, inset
/// to the rows' text, with a little room above and below. Put it before every item but the first.
struct NookRowSeparator: View {
    var body: some View {
        Rectangle().fill(NookTheme.separator)
            .frame(height: 1)
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.xxs)
            .accessibilityHidden(true)
    }
}

/// A notice that comes in while the panel is open (a permission request, an agent's question, a short note): one quiet
/// bar under the tabs with an optional symbol, a title and a line under it, and its actions on the right. `tone` tints
/// the edge for something risky.
struct PanelNoticeBar<Actions: View>: View {
    let title: String
    var detail: String? = nil
    var symbol: String? = nil
    var tone: Color? = nil
    var help: String? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            if let symbol {
                Image(systemName: symbol)
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(tone ?? NookTheme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            .help(help ?? title)
            Spacer(minLength: NookTheme.Spacing.sm)
            actions()
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.vertical, NookTheme.Spacing.md)
        .cardBackground(NookTheme.surface, stroke: (tone ?? NookTheme.line2).opacity(tone == nil ? 1 : 0.35),
                        radius: NookTheme.Radius.panel, style: .continuous)
        .padding(.top, NookTheme.Spacing.md)
        .transition(.opacity.combined(with: .offset(y: -4)))
    }
}

extension View {
    /// The quiet card that groups rows (home's "For you", a list of results): the field fill, the panel's corners, no
    /// stroke. Rows inside are split with `NookDivider`.
    func panelCard() -> some View {
        background(NookTheme.field)
            .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous))
    }
}
