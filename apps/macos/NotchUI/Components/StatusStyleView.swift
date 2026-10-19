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

/// A status as a small tinted capsule that sits in a row's 12pt meta line, where the "55 min" would otherwise be.
/// It shares its height, type and wash with `PullRequestPill`, so the two read as one family and a row with a badge
/// is exactly as tall as one without. `detail` follows a middle dot in tabular digits, such as "3m" or "tot 9:00".
struct AgentStatusBadge: View {
    let state: AgentDisplayState
    var detail: String? = nil
    var long = false

    var body: some View {
        let tint = state.tone.color
        HStack(spacing: 4) {
            if AgentStatusStyle.pulses(state) {
                SteppedPulseDot(color: tint, size: 6)
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: state.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .frame(width: 10, height: 10)
            }
            Text(long ? state.longWord : state.word)
                .font(NookTheme.font(11, .medium))
                .lineLimit(1)
            if let detail {
                Text("·").font(NookTheme.font(11, .medium)).opacity(0.5)
                Text(detail)
                    .font(NookTheme.font(11).monospacedDigit())
                    .opacity(0.7)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .frame(height: 16)
        .background(Capsule().fill(tint.opacity(0.13)))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([state.longWord, detail].compactMap { $0 }.joined(separator: " "))
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
