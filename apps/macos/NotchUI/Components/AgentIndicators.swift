import SwiftUI

// Small status indicators shared by the agent, workspace and inbox views.

/// A thin progress bar; `fraction` runs from 0 to 1.
struct Bar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(NookTheme.line2)
                Capsule().fill(color).frame(width: max(3, geo.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: 4)
    }
}

/// A dot that gently pulses while the agent is running.
struct PulseDot: View {
    let color: Color
    let animated: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if animated {
                Circle()
                    .stroke(color.opacity(pulse ? 0 : 0.7), lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 2.3 : 1)
            }
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .frame(width: 16, height: 16)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// The step currently being executed: a shimmer effect traversing the text.
struct ShimmerText: View {
    let text: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
            Text(text)
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: Color(hex: 0x8A8896), location: 0),
                            .init(color: Color(hex: 0x8A8896), location: max(0, phase - 0.15)),
                            .init(color: NookTheme.paper, location: phase),
                            .init(color: Color(hex: 0x8A8896), location: min(1, phase + 0.15)),
                            .init(color: Color(hex: 0x8A8896), location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
    }
}

/// "#12" with the state of the pull request as its icon (GitHub's marks, drawn) and colour: open (ready to merge) mint,
/// merge conflict coral, merged violet, draft and closed grey. `compact` shows the icon alone, for a slim row.
struct PullRequestPill: View {
    let badge: PullRequestBadge
    var compact = false

    private var tint: Color {
        switch badge.glyph {
        case .open: return NookTheme.mint
        case .conflict: return NookTheme.coral
        case .merged: return NookTheme.violet
        case .draft, .closed: return NookTheme.textTertiary
        case .stack: return NookTheme.amber
        }
    }

    private var status: String { tr("inbox.pr.state." + badge.glyph.rawValue) }

    var body: some View {
        HStack(spacing: 3) {
            PullRequestStateGlyph(glyph: badge.glyph, size: 12, lineWidth: 1.6, nodeRadius: 1.8)
                .foregroundStyle(tint)
            if !compact {
                Text(label).font(NookTheme.font(11, .medium).monospacedDigit())
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
            }
        }
        .modifier(RowBadgeBackground(horizontal: compact ? 3 : 5))
        .help(label.isEmpty ? status : "\(label) · \(status)")
        .accessibilityLabel(label.isEmpty ? status : "\(label), \(status)")
    }

    private var label: String {
        if case .stack(let count) = badge.label { return tr("inbox.pr.stack", count) }
        return badge.text ?? ""
    }
}
