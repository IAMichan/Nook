import SwiftUI

/// Nook: a light with two eyes. Breathes, blinks, and adapts its eyes to its mood.
struct NookOrb: View {
    var mood: NookMood
    var size: CGFloat = 46
    /// Disabled when idle: keeps Nook static and conserves processing power.
    var animated: Bool = true

    var body: some View {
        TimelineView(.animation(paused: !animated)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            orb(at: t)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func orb(at t: Double) -> some View {
        let isThinking = mood == .think
        let breathRate = isThinking ? 1.4 : 3.4
        let breathAmp = isThinking ? 0.025 : 0.05
        let breath = 1 + breathAmp * sin(t * 2 * Double.pi / breathRate)

        let glowRadius: CGFloat
        let glowOpacity: Double
        if isThinking {
            let glowWave = (1.0 + sin(t * 2 * Double.pi / 1.4)) / 2.0
            glowRadius = size * (0.40 + 0.08 * glowWave)
            glowOpacity = 0.50 + 0.14 * glowWave
        } else {
            glowRadius = size * 0.42
            glowOpacity = 0.55
        }

        return ZStack {
            Circle()
                .fill(mood.color)
                .shadow(color: mood.color.opacity(glowOpacity), radius: glowRadius)
            HStack(spacing: size * 0.18) {
                eye(index: 0, t: t)
                eye(index: 1, t: t)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(CGFloat(breath))
        .animation(.easeInOut(duration: 0.3), value: mood)
    }

    // MARK: Eyes

    private var eyeSize: CGSize {
        switch mood {
        case .rest, .seen, .remind:
            return CGSize(width: size * 0.11, height: size * 0.30)
        case .listen:
            return CGSize(width: size * 0.11, height: size * 0.40)
        case .waiting, .worry:
            return CGSize(width: size * 0.13, height: size * 0.34)
        case .think:
            return CGSize(width: size * 0.125, height: size * 0.125)
        case .done:
            return CGSize(width: size * 0.20, height: size * 0.09)
        }
    }

    private var eyeShape: AnyShape {
        switch mood {
        case .done:
            let r = eyeSize.width / 2
            return AnyShape(UnevenRoundedRectangle(
                topLeadingRadius: r,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: r
            ))
        default:
            return AnyShape(Capsule())
        }
    }

    private func thinkingOffset(index: Int, t: Double) -> CGSize {
        guard mood == .think else { return .zero }
        let cycleDuration: Double = 1.4
        let angle = (t * 2 * Double.pi) / cycleDuration - Double(index) * 0.38
        // Hann window lift: completely smooth at baseline and apex (zero velocity, continuous acceleration)
        let lift = (1.0 - cos(angle)) / 2.0
        let y = -lift * size * 0.08
        // Subtle gaze sway in harmonic resonance with the vertical cycle (half-frequency)
        let gazeAngle = (t * 2 * Double.pi) / (cycleDuration * 2)
        let x = sin(gazeAngle) * size * 0.02
        return CGSize(width: x, height: y)
    }

    private func eye(index: Int, t: Double) -> some View {
        let s = eyeSize
        let offset = thinkingOffset(index: index, t: t)
        return eyeShape
            .fill(NookTheme.eyeInk)
            .frame(width: s.width, height: s.height)
            .scaleEffect(x: 1, y: blinkScale(t))
            .offset(x: offset.width, y: offset.height)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: mood)
    }

    /// Blinks every 5 seconds, except when content or thinking.
    private func blinkScale(_ t: Double) -> CGFloat {
        if mood == .done || mood == .think { return 1 }
        let phase = t.truncatingRemainder(dividingBy: 5.0)
        guard phase > 4.7 else { return 1 }
        let p = (phase - 4.7) / 0.3
        return CGFloat(1 - 0.9 * sin(p * Double.pi))
    }
}
