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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if animated && !reduceMotion {
                Circle()
                    .stroke(color.opacity(pulse ? 0 : 0.7), lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 2.3 : 1)
            }
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .frame(width: 16, height: 16)
        .onAppear {
            guard animated, !reduceMotion else { return }
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
                            .init(color: NookTheme.textMuted, location: 0),
                            .init(color: NookTheme.textMuted, location: max(0, phase - 0.15)),
                            .init(color: NookTheme.paper, location: phase),
                            .init(color: NookTheme.textMuted, location: min(1, phase + 0.15)),
                            .init(color: NookTheme.textMuted, location: 1)
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

/// A pull request's state as a tinted capsule: GitHub's mark and the word ("Open", "Merged"), optionally after its
/// number. The pull request page and the watched pull request above the composer both wear it.
struct PullRequestStateBadge: View {
    let glyph: PullRequestBadge.Glyph
    var number: Int? = nil

    private var tint: Color {
        switch glyph {
        case .open: return NookTheme.mint
        case .draft: return NookTheme.textSecondary
        case .conflict, .closed: return NookTheme.coral
        case .merged: return NookTheme.violet
        case .stack: return NookTheme.amber
        }
    }

    private var state: String {
        switch glyph {
        case .open, .draft, .merged, .closed: return tr("agents.pr.state." + glyph.rawValue)
        case .conflict, .stack: return tr("inbox.pr.state." + glyph.rawValue)
        }
    }

    private var label: String { number.map { "#\($0) · \(state)" } ?? state }

    var body: some View {
        HStack(spacing: 3) {
            PullRequestStateGlyph(glyph: glyph, size: 12, lineWidth: 1.6, nodeRadius: 1.8)
            Text(label).lineLimit(1)
        }
        .font(NookTheme.font(11, .semibold).monospacedDigit())
        .foregroundStyle(tint)
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.14)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// The outcome of a CI check or one of its steps: a mint tick, a coral cross, an amber dot while it runs, a grey dash
/// when skipped. The pull request page and the CI of a watched pull request both use it.
struct CheckOutcomeGlyph: View {
    let outcome: PullRequestCheck.Outcome

    var body: some View {
        switch outcome {
        case .passing: Image(systemName: "checkmark.circle.fill").font(NookTheme.font(12)).foregroundStyle(NookTheme.mint)
        case .failing: Image(systemName: "xmark.circle.fill").font(NookTheme.font(12)).foregroundStyle(NookTheme.coral)
        case .pending: Circle().fill(NookTheme.amber).frame(width: 7, height: 7)
        case .skipped: Image(systemName: "minus.circle").font(NookTheme.font(12)).foregroundStyle(NookTheme.textTertiary)
        }
    }
}
