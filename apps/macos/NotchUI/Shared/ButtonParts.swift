import SwiftUI

// The buttons both apps draw (apps/ios/project.yml compiles this file too): the filled accent main
// action (`NookTheme.primary`), the quiet one beside it, and the symbol button, all on the control radius. On the Mac they light under the pointer; on the phone they are a finger's height
// (`SharedMetrics.buttonHeight`) and dim while pressed.

/// The main action of a card: filled with the accent.
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
            .roundedBackground(hovering ? NookTheme.primaryHover : NookTheme.primary, radius: NookTheme.Radius.control)
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
            .roundedBackground(hovering ? NookTheme.graphite : Color.clear, radius: NookTheme.Radius.control)
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
    /// Shows its label as the composer's own tip (`composerTip`) instead of a system tooltip: a button under a composer.
    var inComposer = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(icon: systemName)
                .font(NookTheme.font(size * 0.42, .semibold))
                .foregroundStyle(filled ? NookTheme.onPrimary : (hovering ? NookTheme.paper : NookTheme.textSecondary))
                .frame(width: size, height: size)
                .roundedBackground(filled ? (hovering ? NookTheme.primaryHover : NookTheme.primary) : (hovering ? NookTheme.graphite : Color.clear),
                                   radius: NookTheme.Radius.control)
                .hoverLift(hovering, scale: 1.03)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .labelTip(label, inComposer: inComposer)
        .accessibilityLabel(label)
    }
}

private extension View {
    /// The button's label on hover. The composer's own tips (`composerTip`, in SessionComposer.swift) are Mac-only, so
    /// the iPhone app, which shares this file, falls back to `help`.
    @ViewBuilder
    func labelTip(_ label: String, inComposer: Bool) -> some View {
        #if os(macOS)
        composerTip(label, inComposer: inComposer)
        #else
        help(label)
        #endif
    }
}
