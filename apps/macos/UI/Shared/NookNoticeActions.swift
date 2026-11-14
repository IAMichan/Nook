import SwiftUI

/// One button at the bottom of a notification: its label, an optional SF Symbol, and what it does.
struct NookNoticeAction {
    var label: String
    var symbol: String? = nil
    var perform: () -> Void

    init(_ label: String, symbol: String? = nil, perform: @escaping () -> Void) {
        self.label = label
        self.symbol = symbol
        self.perform = perform
    }
}

/// The button row at the bottom of every notification (cards, approvals, questions), so they all read the same:
/// the main action and its "not now" in one pill, a few muted extra actions, and the rarer ones in a "…" menu next
/// to the optional mic. When the row does not fit, it tightens up instead of wrapping.
struct NookNoticeActions: View {
    let primary: NookNoticeAction
    var secondary: NookNoticeAction? = nil
    var extra: [NookNoticeAction] = []
    var more: [NookNoticeAction] = []
    /// Adjusting by voice: shows the mic at the end of the row.
    var onVoice: (() -> Void)? = nil

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
        }
    }

    private var hasTrailing: Bool { !more.isEmpty || onVoice != nil }

    private func row(compact: Bool) -> some View {
        HStack(spacing: compact ? 0 : NookTheme.Spacing.xs) {
            Group {
                if let secondary {
                    NookSplitButton(primary: primary, secondary: secondary, compact: compact)
                } else {
                    NookPrimaryButton(title: primary.label, symbol: primary.symbol, action: primary.perform)
                }
            }
            .padding(.trailing, compact ? NookTheme.Spacing.xs : 0)
            ForEach(Array(extra.enumerated()), id: \.offset) { _, action in
                NookGhostButton(title: action.label, symbol: action.symbol, compact: compact, action: action.perform)
            }
            if hasTrailing {
                Spacer(minLength: NookTheme.Spacing.xs)
                if !more.isEmpty { NookMoreMenu(actions: more) }
                if let onVoice { NookIconButton(systemName: "mic", label: sharedText("card.voiceAdjust", "Adjust with your voice"), action: onVoice) }
            }
        }
    }
}

/// A notification's main action and its secondary one in a single pill: the main half is the white button, the
/// secondary half sits plain on the pill's dark fill.
struct NookSplitButton: View {
    let primary: NookNoticeAction
    let secondary: NookNoticeAction
    var compact: Bool = false
    @State private var hoveringPrimary = false
    @State private var hoveringSecondary = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: primary.perform) {
                HStack(spacing: 7) {
                    if let symbol = primary.symbol { Image(icon: symbol).font(NookTheme.font(12, .bold)) }
                    Text(primary.label).font(NookTheme.textFont(14, .semibold))
                }
                .foregroundStyle(NookTheme.onPrimary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, primary.symbol == nil ? 18 : 16)
                .frame(maxHeight: .infinity)
                .roundedBackground(hoveringPrimary ? NookTheme.primaryHover : NookTheme.primary, radius: NookTheme.Radius.chip)
                .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            .onHover { hoveringPrimary = $0 }

            Button(action: secondary.perform) {
                HStack(spacing: 6) {
                    if let symbol = secondary.symbol { Image(icon: symbol).font(NookTheme.font(compact ? 11 : 12, .semibold)) }
                    Text(secondary.label).font(NookTheme.textFont(compact ? 13 : 14, .semibold))
                }
                .foregroundStyle(hoveringSecondary ? NookTheme.paper : NookTheme.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, compact ? 10 : 14)
                .padding(.trailing, compact ? 14 : 18)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            .onHover { hoveringSecondary = $0 }
        }
        .padding(3)
        .frame(height: SharedMetrics.buttonHeight)
        .roundedBackground(NookTheme.smoke, radius: NookTheme.Radius.control)
        .hoverLift(hoveringPrimary || hoveringSecondary)
    }
}

/// A round "…" that opens a notification's less common actions as a menu, each with its symbol.
struct NookMoreMenu: View {
    let actions: [NookNoticeAction]
    var size: CGFloat = SharedMetrics.iconButton
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                Button(action: action.perform) {
                    if let symbol = action.symbol { Label(action.label, icon: symbol) } else { Text(action.label) }
                }
            }
        } label: {
            Image(icon: "ellipsis")
                .font(NookTheme.font(size * 0.42, .semibold))
                .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                .frame(width: size, height: size)
                .background(Circle().fill(hovering ? NookTheme.smoke : Color.clear))
                .contentShape(Circle())
                .hoverLift(hovering, scale: 1.03)
        }
        .menuStyle(.nookButton)
        .buttonStyle(.nookPlain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(sharedText("card.more", "More"))
        .accessibilityLabel(sharedText("card.more", "More"))
    }
}
