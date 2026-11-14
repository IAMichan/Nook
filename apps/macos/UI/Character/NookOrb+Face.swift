import SwiftUI

/// The parts of Nook's face that depend on the chosen look: round and dot eyes, and the mouth. The original bar eyes
/// stay in `NookOrb.swift`.
extension NookOrb {
    // MARK: Round and dot eyes

    /// Both eyes in one canvas, placed the way the bar eyes are: side by side around the center, moved by the pose.
    func roundEyes(_ p: Pose, turn: CGFloat) -> some View {
        let dots = style.eyes == .dots
        let gloss = style.gloss
        let tint = Self.eyeTint(for: mood)
        let size = self.size
        return Canvas { context, canvas in
            var ctx = context
            ctx.translateBy(x: canvas.width / 2, y: canvas.height / 2)
            let spacing = size * (dots ? 0.15 : 0.12) * (1 - 0.18 * turn)
            for e in p.eyes {
                var eye = ctx
                eye.translateBy(x: e.side * (spacing / 2 + e.width / 2) + e.dx, y: e.dy)
                eye.rotate(by: .degrees(e.rotation))
                eye.scaleBy(x: 1 - 0.28 * turn, y: 1)
                Self.drawRoundEye(&eye, e, size: size, dots: dots, gloss: gloss, gaze: p.gaze, tint: tint)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }

    /// A faint glow inside the eyes, in a darker shade of the mood's color.
    static func eyeTint(for mood: NookMood) -> Color {
        switch mood {
        case .rest, .seen, .think, .curious, .focus, .surprised, .sleepy: return Color(hex: 0x6C63FF)
        case .listen, .done, .proud, .celebrate, .breathe: return Color(hex: 0x14B37D)
        case .waiting, .remind, .cozy: return Color(hex: 0xE08A2C)
        case .worry: return Color(hex: 0xE0475A)
        case .caring: return Color(hex: 0xE05A7A)
        }
    }

    nonisolated static func drawRoundEye(_ ctx: inout GraphicsContext, _ e: EyePose, size: CGFloat, dots: Bool, gloss: Bool,
                             gaze: CGPoint, tint: Color) {
        let w = e.width, h = e.height
        let ink = Color(hex: 0x0B0A12)
        let line = StrokeStyle(lineWidth: max(1.4, size * (dots ? 0.034 : 0.042)), lineCap: .round, lineJoin: .round)

        if e.giggle > 0.4 {
            // > <
            let d = -e.side, a = w * 0.42, b = h * 0.34
            var path = Path()
            path.move(to: CGPoint(x: -d * a, y: -b))
            path.addLine(to: CGPoint(x: d * a, y: 0))
            path.addLine(to: CGPoint(x: -d * a, y: b))
            ctx.stroke(path, with: .color(ink), style: line)
            return
        }
        if e.happy {
            // ^ ^, built from points so the direction does not depend on how arcs are flipped
            var path = Path()
            let r = w * 0.5
            for i in 0...16 {
                let angle = Double.pi * (1.12 + 0.76 * Double(i) / 16)
                let point = CGPoint(x: r * CGFloat(cos(angle)), y: h * 0.45 + r * CGFloat(sin(angle)))
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            ctx.stroke(path, with: .color(ink), style: line)
            return
        }
        if e.squash < 0.24 {
            // Closed: a soft curve, like a sleeping smile.
            var path = Path()
            path.move(to: CGPoint(x: -w * 0.46, y: 0))
            path.addQuadCurve(to: CGPoint(x: w * 0.46, y: 0), control: CGPoint(x: 0, y: h * 0.22))
            ctx.stroke(path, with: .color(ink), style: line)
            return
        }

        var eye = ctx
        eye.scaleBy(x: 1, y: e.squash)
        if e.lid > 0.01 {
            // Worried: the outer side of the lid droops.
            let lid = Path(CGRect(x: -w * 2, y: -h / 2 + h * 0.26 * e.lid, width: w * 4, height: h * 2))
                .applying(CGAffineTransform(rotationAngle: e.side * 0.38 * e.lid))
            eye.clip(to: lid)
        }
        let oval = Path(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        eye.fill(oval, with: .linearGradient(
            Gradient(colors: [Color(hex: dots ? 0x0B0A12 : 0x1C1B26), NookTheme.eyeInk]),
            startPoint: CGPoint(x: 0, y: -h / 2), endPoint: CGPoint(x: 0, y: h / 2)))
        guard !dots else { return }

        if gloss, size >= 30 {
            // The iris glows up from below; the catchlights stay with the light (top left) while the eye moves.
            eye.fill(oval, with: .radialGradient(
                Gradient(colors: [tint.opacity(0.7), tint.opacity(0)]),
                center: CGPoint(x: 0, y: h * 0.34), startRadius: 0, endRadius: w * 0.62))
            let sx = -gaze.x * w * 0.1, sy = -gaze.y * h * 0.08
            let big = Path(ellipseIn: CGRect(x: -w * 0.19, y: -h * 0.17, width: w * 0.38, height: h * 0.34))
                .applying(CGAffineTransform(rotationAngle: -0.3))
                .offsetBy(dx: -w * 0.17 + sx, dy: -h * 0.17 + sy)
            eye.fill(big, with: .color(.white.opacity(0.96)))
            let r = w * 0.075
            eye.fill(Path(ellipseIn: CGRect(x: w * 0.19 + sx - r, y: h * 0.16 + sy - r, width: r * 2, height: r * 2)),
                     with: .color(.white.opacity(0.75)))
        } else if gloss || size < 30 {
            let r = max(0.6, w * 0.2)
            eye.fill(Path(ellipseIn: CGRect(x: -w * 0.15 - r, y: -h * 0.15 - r, width: r * 2, height: r * 2)),
                     with: .color(.white.opacity(0.9)))
        }
    }

    // MARK: Mouth

    /// The mouth below the eyes: it slides with the gaze and narrows when Nook turns.
    func mouthLayer(_ m: MouthPose, gaze: CGPoint, turn: CGFloat) -> some View {
        let lineOnly = style.mouth == .line
        let size = self.size
        return Canvas { context, canvas in
            var ctx = context
            ctx.translateBy(x: canvas.width / 2 + (gaze.x * 0.08 + m.shift) * size,
                            y: canvas.height / 2 + (0.19 + gaze.y * 0.06) * size)
            ctx.scaleBy(x: 1 - 0.3 * turn, y: 1)
            Self.drawMouth(&ctx, m, size: size, lineOnly: lineOnly)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }

    nonisolated static func drawMouth(_ ctx: inout GraphicsContext, _ m: MouthPose, size: CGFloat, lineOnly: Bool) {
        let w = (lineOnly ? min(m.width, 0.17) : m.width) * size
        let h = lineOnly ? 0 : m.open * size
        let c = m.curve
        let lift = -c * size * 0.035   // smiling lifts the corners
        let mid = c * size * 0.012
        let small = size < 30

        if small || h < size * 0.012 {
            // Closed, or too small to show an opening: one stroke reads best.
            var path = Path()
            path.move(to: CGPoint(x: -w / 2, y: lift))
            path.addQuadCurve(to: CGPoint(x: w / 2, y: lift),
                              control: CGPoint(x: 0, y: mid + c * size * 0.03 + (small ? h * 0.5 : 0)))
            let width = small ? max(1.1, size * 0.07) : max(1.2, size * 0.032)
            ctx.stroke(path, with: .color(Color(hex: 0x08080B)), style: StrokeStyle(lineWidth: width, lineCap: .round))
            return
        }

        // Open: a blend between lips and an ellipse (round vowels).
        let round = m.round, steps = 24, y0 = h * 0.35
        func point(_ s: CGFloat, top: Bool) -> CGPoint {
            let x = -w / 2 + s * w
            let nx = 2 * s - 1
            let bend = 1 - nx * nx
            let half = sqrt(max(bend, 0))
            let corner = lift * (1 - bend)
            let lip = top ? corner + (mid - h * 0.15) * bend : corner + (mid + c * size * 0.03) * bend + h * half
            let oval = top ? y0 - h / 2 * half : y0 + h / 2 * half
            return CGPoint(x: x, y: lip * (1 - round) + oval * round)
        }
        var shape = Path()
        for k in 0...steps {
            let pt = point(CGFloat(k) / CGFloat(steps), top: true)
            if k == 0 { shape.move(to: pt) } else { shape.addLine(to: pt) }
        }
        for k in stride(from: steps, through: 0, by: -1) {
            shape.addLine(to: point(CGFloat(k) / CGFloat(steps), top: false))
        }
        shape.closeSubpath()
        ctx.fill(shape, with: .linearGradient(
            Gradient(colors: [Color(hex: 0x1D1D25), NookTheme.eyeInk]),
            startPoint: CGPoint(x: 0, y: -h / 2), endPoint: CGPoint(x: 0, y: h * 0.2)))
        ctx.stroke(shape, with: .color(NookTheme.eyeInk), style: StrokeStyle(lineWidth: max(0.6, size * 0.016), lineJoin: .round))

        var inside = ctx
        inside.clip(to: shape)
        if h > size * 0.055 {
            inside.fill(Path(ellipseIn: CGRect(x: -w * 0.32, y: h * 0.92 + mid - h * 0.38, width: w * 0.64, height: h * 0.76)),
                        with: .color(Color(hex: 0xE5677F)))
        }
        if m.teeth {
            inside.fill(Path(CGRect(x: -w * 0.28, y: mid - h, width: w * 0.56, height: h * 1.05)),
                        with: .color(NookTheme.paper.opacity(0.92)))
        }
    }
}
