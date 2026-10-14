import SwiftUI

/// Nook: a light with two eyes. Breathes, blinks, and adapts its eyes to its mood.
struct NookOrb: View {
    var mood: NookMood
    var size: CGFloat = 46
    /// Disabled when idle: keeps Nook static and conserves processing power.
    var animated: Bool = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !animated)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            orb(at: t)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func orb(at t: Double) -> some View {
        let breath = 1 + 0.05 * sin(t * 2 * Double.pi / 3.4)
        return ZStack {
            Circle()
                .fill(mood.color)
                .shadow(color: mood.color.opacity(0.55), radius: size * 0.42)
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
            return CGSize(width: size * 0.12, height: size * 0.12)
        case .done:
            return CGSize(width: size * 0.20, height: size * 0.09)
        }
    }

    private var eyeShape: AnyShape {
        switch mood {
        case .think:
            return AnyShape(Circle())
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

    private func eye(index: Int, t: Double) -> some View {
        let s = eyeSize
        let bounce: CGFloat = mood == .think
            ? CGFloat(-abs(sin(t * 2 * Double.pi + Double(index) * 0.8))) * size * 0.10
            : 0
        return eyeShape
            .fill(NookTheme.eyeInk)
            .frame(width: s.width, height: s.height)
            .scaleEffect(x: 1, y: blinkScale(t))
            .offset(y: bounce)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: mood)
    }

    /// Blinks every 5 seconds, except when content.
    private func blinkScale(_ t: Double) -> CGFloat {
        if mood == .done { return 1 }
        let phase = t.truncatingRemainder(dividingBy: 5.0)
        guard phase > 4.7 else { return 1 }
        let p = (phase - 4.7) / 0.3
        return CGFloat(1 - 0.9 * sin(p * Double.pi))
    }
}
