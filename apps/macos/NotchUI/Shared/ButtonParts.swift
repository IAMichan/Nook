import SwiftUI

// The buttons both apps draw (apps/ios/project.yml compiles this file too), as t3code draws them: the filled accent main
// action (`NookTheme.primary`), the quiet one beside it, and the symbol button, all on the control radius. On the Mac they light under the pointer; on the phone they are a finger's height
// (`SharedMetrics.buttonHeight`) and dim while pressed.

/// The main action of a card: filled with the accent (t3code's blue by default).
struct NookPrimaryButton: View {
    let title: String
    /// An SF Symbol before the title, or nil for text only.
    var symbol: String? = nil
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol { Image(icon: symbol).font(NookTheme.font(12, .bold)) }
                Text(title).font(NookTheme.textFont(14, .semibold))
            }
            .foregroundStyle(NookTheme.onPrimary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, symbol == nil ? 16 : 14)
            .frame(height: SharedMetrics.buttonHeight)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous).fill(hovering ? NookTheme.primaryHover : NookTheme.primary))
            .hoverLift(hovering)
        }
        .buttonStyle(.plain)
        // A disabled button dims, so it does not look like one that ignores the click.
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}

/// Subtle secondary button alongside the primary button.
struct NookGhostButton: View {
    let title: String
    /// An SF Symbol before the title, or nil for text only.
    var symbol: String? = nil
    /// Smaller text and padding, for a row with many buttons.
    var compact: Bool = false
    var height: CGFloat = SharedMetrics.buttonHeight
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(icon: symbol).font(NookTheme.font(compact ? 11 : 12, .semibold)) }
                Text(title).font(NookTheme.textFont(compact ? 13 : 14, .semibold))
            }
            .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, compact ? 8 : 12)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous).fill(hovering ? NookTheme.graphite : Color.clear))
            .contentShape(Rectangle())
            .hoverLift(hovering)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}

/// Symbol button (mic, close, play, etc.): a ghost, or filled with the accent for the main one.
struct NookIconButton: View {
    let systemName: String
    let label: String
    var filled: Bool = false
    var size: CGFloat = SharedMetrics.iconButton
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(icon: systemName)
                .font(NookTheme.font(size * 0.42, .semibold))
                .foregroundStyle(filled ? NookTheme.onPrimary : (hovering ? NookTheme.paper : NookTheme.textSecondary))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
                        .fill(filled ? (hovering ? NookTheme.primaryHover : NookTheme.primary)
                              : (hovering ? NookTheme.graphite : Color.clear))
                )
                .hoverLift(hovering, scale: 1.03)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
