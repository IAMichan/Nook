import SwiftUI

// How a status looks, from one source (`AgentStatusStyle`): the same word, symbol and color in the list, the notch ring,
// the project row and the notifications. Color is never the only difference: every status has its own symbol and word.

extension StatusTone {
    var color: Color {
        switch self {
        case .amber: return NookTheme.amber
        case .coral: return NookTheme.coral
        case .mint: return NookTheme.mint
        case .iris: return NookTheme.blue
        case .white: return NookTheme.paper
        case .muted: return NookTheme.textTertiary
        case .slate: return NookTheme.textSecondary
        }
    }
}

extension AgentDisplayState {
    var word: String { tr(AgentStatusStyle.shortKey(self)) }
    var longWord: String { tr(AgentStatusStyle.longKey(self)) }
    var symbol: String { AgentStatusStyle.symbol(self) }
    var tone: StatusTone { AgentStatusStyle.tone(self) }
}

/// A status as a small neutral badge that sits in a row's 12pt meta line, where the "55 min" would otherwise be.
/// Only the symbol (or the live dot) carries the status color; the word stays in the row's own greys, and turns
/// paper-white when the agent waits on you. That keeps a list of badges calm instead of a row of colored blocks.
/// It wears `RowBadgeBackground`, like `PullRequestPill`, so a row with a badge is as tall as one without.
/// `detail` follows a middle dot in tabular digits, such as "3m" or "tot 9:00".
struct AgentStatusBadge: View {
    let state: AgentDisplayState
    var detail: String? = nil
    var long = false

    /// Approval, input and failure: the ones you have to act on.
    private var needsYou: Bool { AgentStatusStyle.priority(state) >= AgentStatusStyle.priority(.failed) }

    var body: some View {
        let tint = state.tone.color
        HStack(spacing: NookTheme.Spacing.xs) {
            Group {
                if AgentStatusStyle.pulses(state) {
                    SteppedPulseDot(color: tint, size: 6)
                } else {
                    Image(systemName: state.symbol).font(NookTheme.font(9.5, .semibold))
                }
            }
            .foregroundStyle(tint)
            .frame(width: 10, height: 10)
            Text(long ? state.longWord : state.word)
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(needsYou ? NookTheme.paper : NookTheme.textSecondary)
                .lineLimit(1)
            if let detail {
                Text("· \(detail)")
                    .font(NookTheme.TextStyle.caption.monospacedDigit())
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
            }
        }
        .modifier(RowBadgeBackground())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([state.longWord, detail].compactMap { $0 }.joined(separator: " "))
    }
}

/// The ground every small badge in a row stands on (status, pull request): no fill and no edge, so a row shows
/// a status as a mark and a word only, 18pt high so it fits a 12pt text line without making the row taller.
struct RowBadgeBackground: ViewModifier {
    var horizontal: CGFloat = NookTheme.Spacing.xs

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontal)
            .frame(height: 18)
            .fixedSize()
    }
}

/// The "working" dot: a steady core with a soft halo that breathes. Its body steps through a few values instead of
/// being evaluated every frame; the renderer glides from one step to the next, so the halo grows smoothly. It stands
/// still when it is not on screen or when you asked for less motion.
struct SteppedPulseDot: View {
    let color: Color
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    private static let steps: [(halo: Double, scale: CGFloat)] = [
        (0.55, 1.0), (0.45, 1.25), (0.32, 1.5), (0.2, 1.75), (0.1, 1.95), (0, 2.1),
    ]

    var body: some View {
        Group {
            if visible && !reduceMotion {
                TimelineView(.periodic(from: .now, by: 1.0 / 4.0)) { context in
                    let step = Int(context.date.timeIntervalSinceReferenceDate * 4) % Self.steps.count
                    // Back to the first step the halo starts over at once: a new ring, not one shrinking back.
                    dot(halo: Self.steps[step].halo, scale: Self.steps[step].scale)
                        .animation(step == 0 ? nil : .linear(duration: 0.25), value: step)
                }
            } else {
                dot(halo: 0, scale: 1)
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }

    private func dot(halo: Double, scale: CGFloat) -> some View {
        Circle().fill(color).frame(width: size, height: size)
            .background(Circle().fill(color.opacity(halo)).frame(width: size, height: size).scaleEffect(scale))
            .frame(width: size, height: size)
    }
}
