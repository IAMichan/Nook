import SwiftUI

// The buttons both apps draw (apps/ios/project.yml compiles this file too): the white main action, the quiet one beside
// it, and the round symbol button. On the Mac they light under the pointer; on the phone they are a finger's height
// (`SharedMetrics.buttonHeight`) and dim while pressed.

/// Primary white button for a card.
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
                if let symbol { Image(systemName: symbol).font(NookTheme.font(12, .bold)) }
                Text(title).font(NookTheme.textFont(14, .semibold))
            }
            .foregroundStyle(NookTheme.ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, symbol == nil ? 18 : 16)
            .frame(height: SharedMetrics.buttonHeight)
            .background(Capsule().fill(hovering ? Color.white : NookTheme.paper))
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
                if let symbol { Image(systemName: symbol).font(NookTheme.font(compact ? 11 : 12, .semibold)) }
                Text(title).font(NookTheme.textFont(compact ? 13 : 14, .semibold))
            }
            .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, compact ? 8 : 12)
            .frame(height: height)
            .contentShape(Rectangle())
            .hoverLift(hovering)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}

/// Circular icon button (mic, close, play, etc.).
struct NookIconButton: View {
    let systemName: String
    let label: String
    var filled: Bool = false
    var size: CGFloat = SharedMetrics.iconButton
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(NookTheme.font(size * 0.42, .semibold))
                .foregroundStyle(filled ? NookTheme.ink : (hovering ? NookTheme.paper : NookTheme.textSecondary))
                .frame(width: size, height: size)
                .background(
                    Circle().fill(filled ? NookTheme.paper : (hovering ? NookTheme.smoke : Color.clear))
                )
                .hoverLift(hovering, scale: 1.03)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
