import SwiftUI

// The small parts every list and page repeats, in both apps (apps/ios/project.yml compiles this file too): a count, a
// group's name, a filter chip, the lines between rows, the quiet card that groups rows, an empty panel, and a status
// as a mark and a word. Never rebuild one of these inline.

/// How many things wait for you: a small amber count (a tab, a list's title). Zero shows nothing.
struct NookCountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            // Amber numerals on a faint wash, not a solid amber pill: it tells without shouting.
            Text("\(count)")
                .font(NookTheme.textFont(10, .semibold, design: .rounded))
                .foregroundStyle(NookTheme.amber)
                .padding(.horizontal, NookTheme.Spacing.xs)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(NookTheme.amber.opacity(0.14)))
        }
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
    /// The state of what the chip stands for (a workflow's newest run), shown only while it runs or when it failed; on
    /// the Mac from `init(title:count:selected:mark:action:)`.
    var mark: AnyView? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.xs) {
                if let mark { mark }
                Text(title).font(NookTheme.TextStyle.label)
                if let count {
                    Text("\(count)").font(NookTheme.textFont(11, .medium, design: .rounded)).opacity(0.7)
                }
            }
            .foregroundStyle(selected ? NookTheme.onIris : (hovering ? NookTheme.paper : NookTheme.textStrong))
            .padding(.horizontal, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
            .padding(.vertical, SharedMetrics.isPhone ? NookTheme.Spacing.sm + 1 : NookTheme.Spacing.xs + 1)
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
    /// A line that marks something (where the new messages start) takes that state's color.
    var tint: Color = NookTheme.border

    var body: some View {
        if vertical {
            Rectangle().fill(tint).frame(width: 1)
        } else {
            Rectangle().fill(tint).frame(height: 1).padding(.leading, inset)
        }
    }
}

/// The line between two items of a list (a chat in the Chats tab): clearer than a `NookDivider`, inset
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

extension View {
    /// The quiet card that groups rows (home's "For you", a list of results): the field fill, the panel's corners, no
    /// stroke. Rows inside are split with `NookDivider`.
    func panelCard() -> some View {
        background(NookTheme.field)
            .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous))
    }
}

/// What something says beside its buttons (a confirmation, a recovery card, a banner): the buttons on the right while
/// the text keeps a readable width (`readable`) beside them, and on a line of their own under it in a narrow tab, instead
/// of the text squeezed to a word per line next to buttons that never shrink.
struct AdaptiveActionRow<Message: View, Actions: View>: View {
    var spacing: CGFloat = NookTheme.Spacing.md
    var alignment: VerticalAlignment = .center
    /// The narrowest the message may get before the buttons move under it.
    var readable: CGFloat = 180
    @ViewBuilder let message: () -> Message
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: alignment, spacing: spacing) {
                message().frame(minWidth: 0, idealWidth: readable, maxWidth: .infinity, alignment: .leading)
                HStack(spacing: NookTheme.Spacing.sm) { actions() }.fixedSize()
            }
            VStack(alignment: .leading, spacing: spacing) {
                message().frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: NookTheme.Spacing.sm) {
                    Spacer(minLength: 0)
                    actions()
                }
            }
        }
    }
}

/// A whole panel or screen without content: its symbol, what it means, and at most one clear call to action.
struct WSEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(NookTheme.font(26, .light))
                .foregroundStyle(NookTheme.textTertiary)
            Text(title)
                .font(NookTheme.TextStyle.title)
                .foregroundStyle(NookTheme.paper)
                .multilineTextAlignment(.center)
            Text(message)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                NookPrimaryButton(title: action.title, action: action.run)
                    .padding(.top, NookTheme.Spacing.xs)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The ground every small badge in a row stands on (status, pull request): no fill and no edge, so a row shows
/// a status as a mark and a word only, 18pt high so it fits a 12pt text line without making the row taller.
struct RowBadgeBackground: ViewModifier {
    var horizontal: CGFloat = NookTheme.Spacing.xs

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontal)
            // 18 pt on the Mac; at least that on the phone, where the text follows Dynamic Type.
            .frame(minHeight: 18, maxHeight: SharedMetrics.isPhone ? nil : 18)
            .fixedSize()
    }
}

/// A status as a mark and a word in a row's meta line (`AgentStatusBadge` on the Mac, `StatusPill` on the phone): only
/// the mark carries the state's color; the word stays grey and turns paper-white when the state waits on you, so a list
/// of statuses stays calm. `detail` ("3m", "until 9:00") follows a middle dot.
struct StatusBadgeLabel<Mark: View>: View {
    let word: String
    var detail: String? = nil
    var needsYou = false
    /// Only the mark, for a row too narrow for the word.
    var markOnly = false
    @ViewBuilder var mark: () -> Mark

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            mark()
                .font(NookTheme.textFont(9.5, .semibold))
                .frame(width: SharedMetrics.isPhone ? 12 : 10, height: SharedMetrics.isPhone ? 12 : 10)
            if !markOnly {
                Text(word)
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(needsYou ? NookTheme.paper : NookTheme.textSecondary)
                    .lineLimit(1)
            }
            if let detail, !markOnly {
                Text("· \(detail)")
                    .font(NookTheme.TextStyle.caption.monospacedDigit())
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
            }
        }
        .modifier(RowBadgeBackground())
    }
}

/// The header of a shelf of rows that folds ("Working (3)", "Recent (12)"): its name, a line across the rest of the row
/// and a chevron. `accessory` sits before the chevron (what a drop here would do, on the Mac).
struct NookShelfHeader<Accessory: View>: View {
    let title: String
    let open: Bool
    /// A shelf that holds something set aside on purpose (snoozed): its name a step brighter.
    var emphasized = false
    let action: () -> Void
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.md) {
                Text(title)
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(emphasized ? NookTheme.textSecondary : NookTheme.textTertiary)
                NookDivider()
                accessory()
                Image(systemName: "chevron.down")
                    .font(NookTheme.textFont(8.5, .bold))
                    .rotationEffect(.degrees(open ? 0 : -90))
                    .foregroundStyle(NookTheme.textTertiary)
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .frame(minHeight: SharedMetrics.isPhone ? 36 : 28, maxHeight: SharedMetrics.isPhone ? nil : 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(open ? sharedText("compose.queue.expanded", "expanded") : "")
    }
}

extension NookShelfHeader where Accessory == EmptyView {
    init(title: String, open: Bool, emphasized: Bool = false, action: @escaping () -> Void) {
        self.init(title: title, open: open, emphasized: emphasized, action: action) { EmptyView() }
    }
}
