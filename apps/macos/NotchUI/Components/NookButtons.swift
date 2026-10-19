import SwiftUI

/// Primary white button for a card.
struct NookPrimaryButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(NookTheme.font(14, .semibold))
                .foregroundStyle(NookTheme.ink)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 18)
                .frame(height: 38)
                .background(Capsule().fill(hovering ? Color.white : NookTheme.paper))
                .scaleEffect(hovering ? 1.02 : 1)
                .animation(.spring(duration: 0.2, bounce: 0.1), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Subtle secondary button alongside the primary button.
struct NookGhostButton: View {
    let title: String
    /// Smaller text and padding, for a row with many buttons.
    var compact: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(NookTheme.font(compact ? 13 : 14, .semibold))
                .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, compact ? 8 : 12)
                .frame(height: 38)
                .contentShape(Rectangle())
                .scaleEffect(hovering ? 1.02 : 1)
                .animation(.spring(duration: 0.2, bounce: 0.1), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Circular icon button (mic, close, play, etc.).
struct NookIconButton: View {
    let systemName: String
    let label: String
    var filled: Bool = false
    var size: CGFloat = 34
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(filled ? NookTheme.ink : (hovering ? NookTheme.paper : NookTheme.textSecondary))
                .frame(width: size, height: size)
                .background(
                    Circle().fill(filled ? NookTheme.paper : (hovering ? NookTheme.smoke : Color.clear))
                )
                .scaleEffect(hovering ? 1.06 : 1)
                .animation(.spring(duration: 0.2, bounce: 0.1), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}

/// Compact subtle button for use in chat.
struct SmallGhostButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(NookTheme.font(13, .semibold))
                .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Capsule().fill(hovering ? NookTheme.smoke : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
