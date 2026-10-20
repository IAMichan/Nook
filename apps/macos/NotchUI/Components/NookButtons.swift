import SwiftUI

/// Primary white button for a card.
struct NookPrimaryButton: View {
    let title: String
    /// An SF Symbol before the title, or nil for text only.
    var symbol: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol).font(NookTheme.font(12, .bold)) }
                Text(title).font(NookTheme.font(14, .semibold))
            }
            .foregroundStyle(NookTheme.ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, symbol == nil ? 18 : 16)
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
                Text(title).font(NookTheme.TextStyle.strong)
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
    /// An SF Symbol before the title, or nil for text only.
    var symbol: String? = nil
    /// Smaller text and padding, for a row with many buttons.
    var compact: Bool = false
    var height: CGFloat = 38
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(NookTheme.font(compact ? 11 : 12, .semibold)) }
                Text(title).font(NookTheme.font(compact ? 13 : 14, .semibold))
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
        .onHover { hovering = $0 }
    }
}

/// The "OK" that closes a notice at once: the white main button of a notice. With `countdown` set, a ring in it runs
/// out in that many seconds, as the notice closes by itself; it stands still while `paused` (the pointer is on the notch).
struct NookAcknowledgeButton: View {
    let title: String
    var compact: Bool = false
    var countdown: TimeInterval? = nil
    var paused: Bool = false
    /// A fixed height, e.g. to fit inside the notch's own row; nil follows `compact`.
    var height: CGFloat? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let countdown { CountdownRing(duration: countdown, paused: paused, size: compact ? 16 : 18) }
                Text(title).font(NookTheme.font(compact ? 13 : 14, .semibold))
            }
            .foregroundStyle(NookTheme.ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, countdown == nil ? (compact ? 14 : 18) : (compact ? 7 : 9))
            .padding(.trailing, compact ? 14 : 18)
            .frame(height: height ?? (compact ? 30 : 38))
            .background(Capsule().fill(hovering ? Color.white : NookTheme.paper))
            .contentShape(Capsule())
            .hoverLift(hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A small ring that empties over `duration` seconds and holds while `paused`. Starts when it appears; give it a new
/// `.id` to start over. The ring runs as one linear animation instead of a per-frame clock, so it keeps moving in the
/// notch panel and costs nothing between frames; holding snaps it to where it is, resuming animates the rest.
struct CountdownRing: View {
    let duration: TimeInterval
    var paused: Bool = false
    var size: CGFloat = 18
    /// The part of the ring still left, 1 = full.
    @State private var left: CGFloat = 1
    /// What was left when the ring last started running, and when that was; nil while held.
    @State private var runFrom: CGFloat = 1
    @State private var runningSince: Date?

    var body: some View {
        ZStack {
            Circle().stroke(NookTheme.ink.opacity(0.14), lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: left)
                .stroke(NookTheme.ink, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1.5)
        .frame(width: size, height: size)
        .onAppear {
            // A turn later, so the run does not merge into the notice's own opening animation.
            DispatchQueue.main.async { if !paused { run() } }
        }
        .onChange(of: paused) { _, now in now ? hold() : run() }
        .accessibilityHidden(true)
    }

    private func run() {
        guard runningSince == nil, left > 0 else { return }
        runFrom = left
        runningSince = Date()
        withAnimation(.linear(duration: max(duration, 0.1) * Double(left))) { left = 0 }
    }

    private func hold() {
        guard let since = runningSince else { return }
        runningSince = nil
        let now = max(0, runFrom - CGFloat(Date().timeIntervalSince(since) / max(duration, 0.1)))
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { left = now }
    }
}

/// A notice's other actions side by side in one dark bar, split by thin lines: the first reads brightest. Pairs with
/// `NookAcknowledgeButton` next to it.
struct NookActionBar: View {
    let actions: [CardAction]
    var compact: Bool = false
    let onAction: (CardAction) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                if index > 0 {
                    Rectangle().fill(NookTheme.line2).frame(width: 1, height: 18)
                }
                NookActionBarItem(action: action, bright: index == 0, compact: compact) { onAction(action) }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: compact ? 34 : 40)
        .background(
            Capsule().fill(NookTheme.graphite)
                .overlay(Capsule().strokeBorder(NookTheme.line2, lineWidth: 1))
        )
    }
}

private struct NookActionBarItem: View {
    let action: CardAction
    let bright: Bool
    let compact: Bool
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 6) {
                if let symbol = action.symbol {
                    Image(systemName: symbol).font(NookTheme.font(compact ? 11 : 12, .semibold))
                }
                Text(action.label).font(NookTheme.font(compact ? 13 : 13.5, .semibold))
            }
            .foregroundStyle(bright || hovering ? NookTheme.paper : NookTheme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, compact ? 10 : 14)
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 28 : 32)
            .background(Capsule().fill(hovering ? NookTheme.smoke : Color.clear))
            .contentShape(Capsule())
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
                .font(NookTheme.TextStyle.strong)
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
