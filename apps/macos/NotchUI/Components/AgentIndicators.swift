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
                // Run by Core Animation (`LayerLoop`): the main thread draws nothing per frame, so a list with many
                // working sessions costs no more than one without. The ring grows past the dot, so its view is larger
                // than the dot and laid out at the dot's size.
                LayerLoop(shape: .ring(diameter: 8, lineWidth: 1.5, growth: 1.3, opacity: 0.7, period: 1.4),
                          color: color, fps: energy.plan.progressFrameRate(attended: attended))
                    .frame(width: 24, height: 24)
                    .allowsHitTesting(false)
                    .frame(width: 16, height: 16)
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
    // The light's shape is drawn apart from the text beneath it and does not inherit these: passed on, so it is laid out
    // just like that text.
    @Environment(\.font) private var font
    @Environment(\.lineLimit) private var lineLimit
    @Environment(\.truncationMode) private var truncationMode
    @Environment(\.multilineTextAlignment) private var alignment

    var body: some View {
        // The text itself stands still; only the light moves, run by Core Animation (`ShimmerLayer`) and cut to the text's
        // shape, which is drawn once per text. A timeline drew the light on the main thread on every frame and laid out
        // the window around it, for as long as an agent works.
        Text(text)
            .foregroundStyle(NookTheme.textMuted)
            .overlay {
                ShimmerLayer(mask: AnyView(shape), maskKey: "\(text)|\(String(describing: font))|\(String(describing: lineLimit))|\(truncationMode)|\(alignment)",
                             color: NookTheme.paper, fps: energy.plan.progressFrameRate(attended: attended))
                    .allowsHitTesting(false)
            }
    }

    private var shape: some View {
        Text(text)
            .font(font)
            .lineLimit(lineLimit)
            .truncationMode(truncationMode)
            .multilineTextAlignment(alignment)
    }
}

/// "#12" with the state of the pull request as its icon and color (`PullRequestStateIcon`). `compact` shows the icon
/// alone, for a slim row.
struct PullRequestPill: View {
    let badge: PullRequestBadge
    var compact = false
    /// Off where the pill opens a hover card of its own, so the system tooltip does not cover it.
    var tooltip = true

    private var status: String { tr("inbox.pr.state." + badge.glyph.rawValue) }

    var body: some View {
        HStack(spacing: 3) {
            PullRequestStateIcon(glyph: badge.glyph)
            if let shown = compact ? progress : label {
                Text(shown).font(NookTheme.font(11, .medium).monospacedDigit())
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
            }
        }
        .modifier(RowBadgeBackground(horizontal: compact ? 3 : 5))
        .help(tooltip ? (label.isEmpty ? status : "\(label) · \(status)") : "")
        .accessibilityLabel(label.isEmpty ? status : "\(label), \(status)")
    }

    private var label: String {
        if case .stack(let count, let merged) = badge.label {
            return merged > 0 ? tr("inbox.pr.stack.merged", merged, count) : tr("inbox.pr.stack", count)
        }
        return badge.text ?? ""
    }

    /// "1/3": how far a stack has merged, which even a compact pill says. The mark alone cannot.
    private var progress: String? {
        guard case .stack(let count, let merged) = badge.label, merged > 0 else { return nil }
        return "\(merged)/\(count)"
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

/// A pull request's state badge as it is now: read from `PullRequestStatusStore`, the one status every place in Nook
/// shares, and read again while it shows, so it never lags behind the row badge or the pull request page.
struct PullRequestLiveStateBadge: View {
    let url: URL
    /// What to show before any read has said (a watch's last look, say).
    var fallback: PullRequestBadge.Glyph = .open
    @ObservedObject private var statuses = PullRequestStatusStore.shared

    var body: some View {
        PullRequestStateBadge(glyph: statuses.status(url)?.glyph ?? fallback, number: Int(url.lastPathComponent))
            .task(id: url) { await PullRequestStatusStore.follow(url) }
    }
}

