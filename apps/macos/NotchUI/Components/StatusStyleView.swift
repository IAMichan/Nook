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

/// A status as a small glass pill: a soft vertical wash of its color, a hairline rim that catches the light at the top,
/// and a leading beacon (the symbol in its own little disc, or the live dot while working). `detail` sits behind a thin
/// divider in tabular digits, such as "3m" or "tot 9:00". States that need you (approval, input, failure) glow faintly.
struct AgentStatusBadge: View {
    let state: AgentDisplayState
    var detail: String? = nil
    var long = false

    /// Approval, input and failure: the ones you have to act on.
    private var needsYou: Bool { AgentStatusStyle.priority(state) >= AgentStatusStyle.priority(.failed) }

    var body: some View {
        let tint = state.tone.color
        HStack(spacing: 5) {
            beacon(tint)
            Text(long ? state.longWord : state.word)
                .font(NookTheme.font(11, .semibold))
                .lineLimit(1)
            if let detail {
                Capsule().fill(tint.opacity(0.35)).frame(width: 1, height: 9)
                Text(detail)
                    .font(NookTheme.font(11, .medium).monospacedDigit())
                    .foregroundStyle(tint.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(tint)
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .frame(height: 20)
        .background(
            Capsule().fill(LinearGradient(colors: [tint.opacity(0.24), tint.opacity(0.10)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            Capsule().strokeBorder(
                LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.12)], startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75
            )
        )
        .shadow(color: needsYou ? tint.opacity(0.35) : .clear, radius: 5)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([state.longWord, detail].compactMap { $0 }.joined(separator: " "))
    }

    /// A 14pt disc that holds the symbol, so every status starts with the same shape and the words line up in a list.
    private func beacon(_ tint: Color) -> some View {
        ZStack {
            Circle().fill(tint.opacity(0.22))
            if AgentStatusStyle.pulses(state) {
                SteppedPulseDot(color: tint, size: 6)
            } else {
                Image(systemName: state.symbol).font(.system(size: 8.5, weight: .bold))
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// The "working" dot: a steady core with a soft halo that breathes. It steps through a few values instead of
/// repainting every frame, and stands still when it is not on screen or when you asked for less motion.
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
                    dot(halo: Self.steps[step].halo, scale: Self.steps[step].scale)
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
