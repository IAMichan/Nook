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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Published only when the plan changes: sets how often the ring redraws.
    @ObservedObject private var energy = EnergyMonitor.shared
    @Environment(\.nookAttended) private var attended

    var body: some View {
        ZStack {
            if animated && !reduceMotion {
                // A timeline at the ambient rate, not a `repeatForever` animation: that runs at the display's own rate (up to
                // 120 times a second) for as long as the dot is there, and every frame redraws the whole window it is in.
                TimelineView(.nookFrames(fps: energy.plan.frameRate(energy.plan.ambientFrameRate, attended: attended), paused: energy.plan.pace == .paused)) { context in
                    // An ease-out over 1.4 s, starting over: the ring grows and fades.
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                    let eased = 1 - (1 - phase) * (1 - phase)
                    Circle()
                        .stroke(color.opacity(0.7 * (1 - eased)), lineWidth: 1.5)
                        .frame(width: 8, height: 8)
                        .scaleEffect(1 + 1.3 * eased)
                }
            }
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .frame(width: 16, height: 16)
    }
}

/// The step currently being executed: a shimmer effect traversing the text.
struct ShimmerText: View {
    let text: String
    /// Published only when the plan changes: sets how often the shimmer redraws.
    @ObservedObject private var energy = EnergyMonitor.shared
    @Environment(\.nookAttended) private var attended

    var body: some View {
        TimelineView(.nookFrames(fps: energy.plan.frameRate(energy.plan.ambientFrameRate, attended: attended), paused: energy.plan.pace == .paused)) { context in
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

/// "#12" with the state of the pull request as its icon and color (`PullRequestStateIcon`). `compact` shows the icon
/// alone, for a slim row.
struct PullRequestPill: View {
    let badge: PullRequestBadge
    var compact = false

    private var status: String { tr("inbox.pr.state." + badge.glyph.rawValue) }

    var body: some View {
        HStack(spacing: 3) {
            PullRequestStateIcon(glyph: badge.glyph)
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

    private var tint: Color { PullRequestIcon.tint(glyph) }

    private var state: String {
        switch glyph {
        case .open, .draft, .merged, .closed: return tr("agents.pr.state." + glyph.rawValue)
        case .conflict, .stack: return tr("inbox.pr.state." + glyph.rawValue)
        }
    }

    private var label: String { number.map { "#\($0) · \(state)" } ?? state }

    var body: some View {
        HStack(spacing: 3) {
            PullRequestStateIcon(glyph: glyph, tinted: false)
            Text(label).lineLimit(1)
        }
        .font(NookTheme.TextStyle.label.monospacedDigit())
        .foregroundStyle(tint)
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .padding(.vertical, NookTheme.Spacing.xxs)
        .background(Capsule().fill(tint.opacity(0.14)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

