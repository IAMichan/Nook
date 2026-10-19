import SwiftUI

// How a status looks, from one source (`AgentStatusStyle`): the same word, symbol and color in the list, the notch ring,
// the project row and the notifications. Color is never the only difference: every status has its own symbol and word.

extension StatusTone {
    var color: Color {
        switch self {
        case .amber: return NookTheme.amber
        case .coral: return NookTheme.coral
        case .mint: return NookTheme.mint
        case .iris: return Color(hex: 0x8CA2FF)
        case .white: return NookTheme.paper
        case .muted: return NookTheme.textTertiary
        case .slate: return Color(hex: 0x7C8AA5)
        }
    }
}

extension AgentDisplayState {
    var word: String { tr(AgentStatusStyle.shortKey(self)) }
    var longWord: String { tr(AgentStatusStyle.longKey(self)) }
    var symbol: String { AgentStatusStyle.symbol(self) }
    var tone: StatusTone { AgentStatusStyle.tone(self) }
}

/// A status as a quiet tinted badge: a light wash of its color behind the symbol and word,
/// never a solid chip. `detail` adds a tail such as "3m" or "tot 9:00".
struct AgentStatusBadge: View {
    let state: AgentDisplayState
    var detail: String? = nil
    var long = false

    var body: some View {
        let tint = state.tone.color
        HStack(spacing: 4) {
            if AgentStatusStyle.pulses(state) {
                SteppedPulseDot(color: tint)
            } else {
                Image(systemName: state.symbol).font(.system(size: 10, weight: .semibold))
            }
            Text([long ? state.longWord : state.word, detail].compactMap { $0 }.joined(separator: " "))
                .font(NookTheme.font(11.5, .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(tint.opacity(0.14)))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([state.longWord, detail].compactMap { $0 }.joined(separator: " "))
    }
}

/// The "working" dot: it steps through a few opacities instead of
/// repainting every frame, and stands still when it is not on screen or when you asked for less motion.
struct SteppedPulseDot: View {
    let color: Color
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    private static let steps: [Double] = [1, 1, 0.8, 0.55, 0.55, 0.8]

    var body: some View {
        Group {
            if visible && !reduceMotion {
                TimelineView(.periodic(from: .now, by: 1.0 / 3.0)) { context in
                    let step = Int(context.date.timeIntervalSinceReferenceDate * 3) % Self.steps.count
                    dot.opacity(Self.steps[step])
                }
            } else {
                dot
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }

    private var dot: some View { Circle().fill(color).frame(width: size, height: size) }
}
