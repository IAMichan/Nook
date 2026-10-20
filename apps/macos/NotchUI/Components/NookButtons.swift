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
                .hoverLift(hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Compact white button for use in chat.
struct SmallPrimaryButton: View {
    let title: String
    var systemName: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemName { Image(systemName: systemName).font(NookTheme.font(11, .semibold)) }
                Text(title).font(NookTheme.font(13, .semibold))
            }
            .foregroundStyle(NookTheme.ink)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule().fill(hovering ? Color.white : NookTheme.paper))
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
                .hoverLift(hovering)
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
                .font(NookTheme.font(size * 0.42, .semibold))
                .foregroundStyle(filled ? NookTheme.ink : (hovering ? NookTheme.paper : NookTheme.textSecondary))
                .frame(width: size, height: size)
                .background(
                    Circle().fill(filled ? NookTheme.paper : (hovering ? NookTheme.smoke : Color.clear))
                )
                .hoverLift(hovering, scale: 1.06)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}

/// A small borderless symbol button for a panel header or a message's actions (copy, retry, close). The label is the
/// tooltip and what VoiceOver reads.
struct ToolbarIconButton: View {
    let symbol: String
    let label: String
    var height: CGFloat = 24
    let action: () -> Void

    init(_ symbol: String, _ label: String, height: CGFloat = 24, _ action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.height = height
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(NookTheme.font(11, .medium))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 24, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
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
