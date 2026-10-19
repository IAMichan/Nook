import SwiftUI

/// Nook's headphones while music plays, modelled in 3D around his round head so they turn and tip with him.
///
/// The band is an arc over the top through both ears and each ear cup is a short, flattened cylinder on the ear axis.
/// Nook's gaze becomes a head turn (yaw) and a nod (pitch); every point is rotated and projected straight onto the
/// screen. Whatever turns away from the viewer is drawn in the `.back` layer, behind the orb, so the far cup and the
/// far half of the band slip behind his head; the rest is drawn in the `.front` layer. Near the edge a part fades
/// between the two layers instead of popping.
///
/// The orb draws both layers inside its own stack, so the headphones also hop, squash and tilt with him.
struct NookHeadphones: View {
    enum Layer { case back, front }

    var size: CGFloat
    /// Where Nook looks, -1…1 on both axes (y pointing down), as in the orb's pose.
    var gaze: CGPoint
    var layer: Layer

    private static let shell = Color(hex: 0x4A4A58)
    private static let cushion = Color(hex: 0x62627A)

    var body: some View {
        let rig = Rig(size: size, gaze: gaze)
        return ZStack {
            band(rig)
            cup(rig, ear: -1)
            cup(rig, ear: 1)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }

    // MARK: Band

    private func band(_ rig: Rig) -> some View {
        let width = max(1.5, size * 0.07)
        let segments = rig.bandSegments()
        return ZStack {
            switch layer {
            case .back:
                // The whole band, once: the orb in front hides what is behind his head.
                Path { path in
                    for (i, s) in segments.enumerated() {
                        if i == 0 { path.move(to: s.from) }
                        path.addLine(to: s.to)
                    }
                }
                .stroke(Self.shell, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            case .front:
                // Fully visible segments in one stroke; segments turning away fade out one by one.
                Path { path in
                    for s in segments where s.visibility >= 0.999 {
                        path.move(to: s.from)
                        path.addLine(to: s.to)
                    }
                }
                .stroke(Self.shell, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                ForEach(segments.indices, id: \.self) { i in
                    let s = segments[i]
                    if s.visibility > 0.001, s.visibility < 0.999 {
                        Path { path in
                            path.move(to: s.from)
                            path.addLine(to: s.to)
                        }
                        .stroke(Self.shell, style: StrokeStyle(lineWidth: width, lineCap: .butt))
                        .opacity(s.visibility)
                    }
                }
            }
        }
    }

    // MARK: Ear cups

    /// `ear` is -1 for the left cup and 1 for the right.
    private func cup(_ rig: Rig, ear: CGFloat) -> some View {
        let c = rig.cup(ear: ear)
        let opacity = layer == .back ? 1 : c.visibility
        return ZStack {
            RoundedRectangle(cornerRadius: min(c.width, c.height) * 0.5, style: .continuous)
                .fill(Self.shell)
                .overlay(
                    RoundedRectangle(cornerRadius: min(c.width, c.height) * 0.5, style: .continuous)
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.6)
                )
                .frame(width: c.width, height: c.height)
                .position(c.center)
            // The cushioned outside of the cup, seen when it turns towards you.
            if c.faceWidth > 0.5 {
                Ellipse()
                    .fill(Self.cushion)
                    .frame(width: c.faceWidth, height: c.height * 0.82)
                    .position(c.faceCenter)
            }
        }
        .opacity(opacity)
    }

    // MARK: Geometry

    /// The headphones in Nook's head space (x right, y down, z towards the viewer; the orb's center is the origin),
    /// rotated by his gaze and projected onto the orb's frame.
    private struct Rig {
        let size: CGFloat
        /// Head turn around the vertical axis; positive looks right.
        let yaw: CGFloat
        /// Nod around the ear axis; positive looks down.
        let pitch: CGFloat

        /// Over this depth a part fades from the front layer into the back layer.
        var fade: CGFloat { size * 0.05 }
        /// From the center to the middle of each cup along the ear axis.
        var reach: CGFloat { size * 0.455 }
        /// Thickness of a cup along the ear axis.
        var thickness: CGFloat { size * 0.17 }
        /// Half the depth of a cup, front to back.
        var depth: CGFloat { size * 0.12 }
        var cupHeight: CGFloat { size * 0.34 }

        init(size: CGFloat, gaze: CGPoint) {
            self.size = size
            yaw = max(-1, min(gaze.x, 1)) * 0.38
            pitch = max(-1, min(gaze.y, 1)) * 0.3
        }

        /// Rotates a point in head space: first the nod, then the turn.
        func rotate(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> (x: CGFloat, y: CGFloat, z: CGFloat) {
            // Nodding down brings the top of the head towards the viewer.
            let y1 = y * cos(pitch) + z * sin(pitch)
            let z1 = -y * sin(pitch) + z * cos(pitch)
            // Turning right brings the left side towards the viewer.
            let x2 = x * cos(yaw) + z1 * sin(yaw)
            let z2 = -x * sin(yaw) + z1 * cos(yaw)
            return (x2, y1, z2)
        }

        func screen(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: size / 2 + x, y: size / 2 + y)
        }

        /// How much of something at depth `z` belongs in front of the orb: 1 at or above the middle, 0 behind it.
        func visibility(_ z: CGFloat) -> Double {
            Double(min(max(1 + z / fade, 0), 1))
        }

        struct Segment {
            var from: CGPoint
            var to: CGPoint
            var visibility: Double
        }

        /// The band as short straight pieces from ear to ear over the top.
        func bandSegments(count: Int = 28) -> [Segment] {
            let radius = size * 0.51
            let points = (0...count).map { i -> (CGPoint, CGFloat) in
                let a = CGFloat.pi + CGFloat.pi * CGFloat(i) / CGFloat(count)
                let p = rotate(radius * cos(a), radius * sin(a) + size * 0.01, 0)
                return (screen(p.x, p.y), p.z)
            }
            return (0..<count).map { i in
                Segment(from: points[i].0, to: points[i + 1].0, visibility: visibility((points[i].1 + points[i + 1].1) / 2))
            }
        }

        struct Cup {
            var center: CGPoint
            var width: CGFloat
            var height: CGFloat
            var faceCenter: CGPoint
            var faceWidth: CGFloat
            var visibility: Double
        }

        func cup(ear: CGFloat) -> Cup {
            let middle = rotate(ear * reach, 0, 0)
            let outside = rotate(ear * (reach + thickness / 2), 0, 0)
            // Facing the viewer: how far the outward normal (ear, 0, 0) points towards z.
            let facing = rotate(ear, 0, 0).z
            let width = thickness * abs(cos(yaw)) + 2 * depth * abs(sin(yaw))
            return Cup(
                center: screen(middle.x, middle.y),
                width: width,
                height: cupHeight * (1 - 0.08 * abs(sin(pitch))),
                faceCenter: screen(outside.x, outside.y),
                faceWidth: facing > 0 ? 2 * depth * facing * 0.85 : 0,
                visibility: visibility(middle.z)
            )
        }
    }
}
