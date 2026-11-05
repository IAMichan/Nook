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

/// A status as a small badge that sits in a row's 12pt meta line, where the "55m" would otherwise be: the mark and the
/// word both in the status color, without a fill, so a status reads at a glance and a list of them stays free of blocks.
/// It wears `RowBadgeBackground`, like `PullRequestPill`, so a row with a badge is as tall as one without.
/// `detail` follows the word in tabular digits, such as "3m" or "tot 9:00".
struct AgentStatusBadge: View {
    let state: AgentDisplayState
    var detail: String? = nil
    var long = false
    /// Only the mark, for a row too narrow for the word: the word and the detail move to its tooltip.
    var markOnly = false

    var body: some View {
        let tint = state.tone.color
        StatusBadgeLabel(word: long ? state.longWord : state.word, detail: detail, tint: tint, markOnly: markOnly) {
            Group {
                if AgentStatusStyle.pulses(state) {
                    SteppedPulseDot(color: tint, size: 6)
                } else {
                    Image(systemName: state.symbol)
                }
            }
            .foregroundStyle(tint)
        }
        .help(markOnly ? [state.longWord, detail].compactMap { $0 }.joined(separator: " · ") : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([state.longWord, detail].compactMap { $0 }.joined(separator: " "))
    }
}

/// The "working" dot: a steady core with a soft halo that breathes, at the ambient rate. Not a SwiftUI animation between
/// steps: that is drawn at the display's own rate, and redraws the whole window on every frame for as long as an agent
/// works. It stands still when it is not on screen or when you asked for less motion.
struct SteppedPulseDot: View {
    let color: Color
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Published only when the plan changes: sets how often the halo redraws.
    @ObservedObject private var energy = EnergyMonitor.shared
    @Environment(\.nookAttended) private var attended
    @State private var visible = false

    /// One breath: the halo grows from the dot and fades out in this long, then a new one starts.
    private static let period = 1.5

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .background {
                if visible && !reduceMotion {
                    // Run by Core Animation (`LayerLoop`): the main thread draws nothing per frame, however many sessions
                    // work. The halo grows past the dot, so its view is larger than the dot and laid out at its size.
                    LayerLoop(shape: .halo(diameter: size, growth: 1.1, opacity: 0.55, period: Self.period),
                              color: color, fps: energy.plan.progressFrameRate(attended: attended))
                        .frame(width: size * 2.4, height: size * 2.4)
                        .allowsHitTesting(false)
                        .frame(width: size, height: size)
                }
            }
            .frame(width: size, height: size)
            .onAppear { visible = true }
            .onDisappear { visible = false }
    }
}
