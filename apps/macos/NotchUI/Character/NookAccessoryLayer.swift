import SwiftUI

/// What Nook wears (`NookAccessory`), drawn around his round head and lit the way he is: light from the top left,
/// shade towards the bottom right, a soft shadow where a hat or a frame sits on him.
///
/// Like the headphones, his gaze becomes a head turn (yaw) and a nod (pitch). A hat rides on the top of his head and
/// its decorations (stripes, gems, ribs) slide around the front as he turns; glasses sit on his eyes and follow them.
/// The `.back` layer is drawn behind the orb (the back rim of a crown, the far side of a scarf), the `.front` layer on
/// top of his face. The orb draws both inside its own stack, so everything hops, squashes and tilts with him.
///
/// Sizes are fractions of the head's radius `R`, so the same drawing works from the 20-point orb in the notch to the
/// 88-point preview in Settings; fine detail (knit, stitches, fuzz) fades out on small orbs where it would only blur.
struct NookAccessoryLayer: View {
    enum Layer { case back, front }

    var items: [NookAccessory]
    var size: CGFloat
    /// Where Nook looks, -1…1 on both axes (y pointing down), as in the orb's pose.
    var gaze: CGPoint
    /// The eye line relative to the orb's center (negative is up).
    var eyeY: CGFloat
    /// From the center to the middle of each eye.
    var eyeReach: CGFloat
    var layer: Layer

    /// Room around the orb for what sticks out: the tip of a party hat, the tails of a scarf.
    static let canvasScale: CGFloat = 2.6

    var body: some View {
        let head = NookAccessoryArt.Head(size: size, gaze: gaze, eyeY: eyeY, eyeReach: eyeReach)
        let ordered = items.sorted { NookAccessoryArt.order($0) < NookAccessoryArt.order($1) }
        let back = layer == .back
        return Canvas { context, canvas in
            var ctx = context
            ctx.translateBy(x: canvas.width / 2, y: canvas.height / 2)
            for item in ordered {
                NookAccessoryArt.draw(item, in: ctx, head: head, back: back)
            }
        }
        .frame(width: size * Self.canvasScale, height: size * Self.canvasScale)
        .allowsHitTesting(false)
    }
}

/// The drawings themselves, apart from the view: plain functions on a graphics context, usable from any context.
enum NookAccessoryArt {
    /// Scarf first, then glasses, then the hat: a brim's shadow falls over the top of a frame.
    static func order(_ item: NookAccessory) -> Int {
        switch item.slot {
        case .neck: return 0
        case .eyes: return 1
        case .head: return 2
        }
    }

    /// Draws one item's part in the back layer (behind the orb) or the front layer (over his face).
    static func draw(_ item: NookAccessory, in ctx: GraphicsContext, head: Head, back: Bool) {
        switch (item, back) {
        case (.beanie, false): drawBeanie(ctx, head)
        case (.nightcap, false): drawFloppyHat(ctx, head, style: .nightcap)
        case (.santaHat, false): drawFloppyHat(ctx, head, style: .santa)
        case (.partyHat, false): drawPartyHat(ctx, head)
        case (.crown, true): drawCrownBack(ctx, head)
        case (.crown, false): drawCrown(ctx, head)
        case (.hardHat, false): drawHardHat(ctx, head)
        case (.beret, false): drawBeret(ctx, head)
        case (.roundGlasses, false): drawRoundGlasses(ctx, head)
        case (.sunglasses, false): drawSunglasses(ctx, head)
        case (.scarf, true): drawScarfBack(ctx, head)
        case (.scarf, false): drawScarf(ctx, head)
        default: break
        }
    }

    // MARK: Head

    /// Nook's head: a sphere of radius `R` at the origin (x right, y down, z towards the viewer), turned by his gaze.
    struct Head {
        let R: CGFloat
        let size: CGFloat
        let yaw: CGFloat
        let pitch: CGFloat
        let gaze: CGPoint
        let eyeY: CGFloat
        let eyeReach: CGFloat

        init(size: CGFloat, gaze: CGPoint, eyeY: CGFloat, eyeReach: CGFloat) {
            self.size = size
            R = size / 2
            let gx = max(-1, min(gaze.x, 1)), gy = max(-1, min(gaze.y, 1))
            self.gaze = CGPoint(x: gx, y: gy)
            yaw = gx * 0.38
            pitch = gy * 0.3
            self.eyeY = eyeY
            self.eyeReach = eyeReach
        }

        /// Rotates a point on or around the head: first the nod, then the turn (as `NookHeadphones` does).
        func rotate(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint {
            let y1 = y * cos(pitch) + z * sin(pitch)
            let z1 = -y * sin(pitch) + z * cos(pitch)
            return CGPoint(x: x * cos(yaw) + z1 * sin(yaw), y: y1)
        }

        /// Where the top of the head moved to, relative to where it is when Nook looks straight ahead.
        var hatShift: CGSize {
            let top = rotate(0, -R, 0)
            return CGSize(width: top.x, height: top.y + R)
        }

        /// The middle of the head's front at height `y` (in hat space): where a gem or a stripe centered on the front sits.
        func front(_ y: CGFloat) -> CGFloat {
            let z = sqrt(max(R * R - y * y, 0))
            return z * sin(yaw)
        }

        /// How much a decoration on the front narrows as the head turns.
        var foreshortening: CGFloat { cos(yaw) }

        /// Fine detail (knit, stitches, fuzz) only where it can be seen.
        var detailed: Bool { size >= 30 }

        /// A line width that stays visible on the small orb in the notch.
        func line(_ fraction: CGFloat, minimum: CGFloat = 0.5) -> CGFloat { max(minimum, R * fraction) }

        var outline: Path { Path(ellipseIn: CGRect(x: -R, y: -R, width: 2 * R, height: 2 * R)) }

        /// The middle of each eye, moved with the gaze as the orb moves them.
        func eye(_ side: CGFloat) -> CGPoint {
            CGPoint(x: side * eyeReach * (1 - 0.18 * abs(gaze.x)) + gaze.x * size * 0.09, y: eyeY + gaze.y * size * 0.07)
        }
    }

    // MARK: Shared pieces

    /// A soft shadow on Nook's face under something he wears: blurred, and only where his head is.
    private static func castShadow(_ ctx: GraphicsContext, _ head: Head, _ path: Path, opacity: Double, blur: CGFloat) {
        var shade = ctx
        shade.clip(to: head.outline)
        shade.drawLayer { layer in
            layer.addFilter(.blur(radius: max(0.4, head.R * blur)))
            layer.fill(path, with: .color(Color.black.opacity(opacity)))
        }
    }

    /// Light from the top left over a shape: a broad sheen and a darker side away from the light.
    private static func roundShading(_ ctx: inout GraphicsContext, _ path: Path, in rect: CGRect, sheen: Double, shade: Double) {
        let light = CGPoint(x: rect.minX + rect.width * 0.3, y: rect.minY + rect.height * 0.22)
        ctx.fill(path, with: .radialGradient(
            Gradient(stops: [
                .init(color: .white.opacity(sheen), location: 0),
                .init(color: .white.opacity(0), location: 0.45),
                .init(color: .black.opacity(0), location: 0.6),
                .init(color: .black.opacity(shade), location: 1)
            ]),
            center: light, startRadius: 0, endRadius: max(rect.width, rect.height) * 0.95))
    }

    /// A woolly ball: tufts around the edge, lit from the top left, with a few loose strands on larger orbs.
    private static func fuzzyBall(_ ctx: GraphicsContext, _ head: Head, center c: CGPoint, radius r: CGFloat,
                                  light: Color, base: Color, dark: Color) {
        let shading = GraphicsContext.Shading.radialGradient(
            Gradient(stops: [.init(color: light, location: 0), .init(color: base, location: 0.5), .init(color: dark, location: 1)]),
            center: CGPoint(x: c.x - r * 0.4, y: c.y - r * 0.45), startRadius: 0, endRadius: r * 1.55)
        let tufts = head.detailed ? 22 : 12
        for i in 0..<tufts {
            let a = CGFloat(i) / CGFloat(tufts) * 2 * .pi + 0.25 * CGFloat(noise(i, 1))
            let reach = r * (0.86 + 0.1 * CGFloat(noise(i, 2)))
            let tuft = r * (0.26 + 0.08 * CGFloat(noise(i, 3)))
            let p = CGPoint(x: c.x + cos(a) * reach, y: c.y + sin(a) * reach)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - tuft, y: p.y - tuft, width: tuft * 2, height: tuft * 2)), with: shading)
        }
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: shading)
        guard head.detailed else { return }
        for i in 0..<14 {
            let a = CGFloat(i) / 14 * 2 * .pi + CGFloat(noise(i, 4))
            var strand = Path()
            strand.move(to: CGPoint(x: c.x + cos(a) * r * 0.55, y: c.y + sin(a) * r * 0.55))
            strand.addLine(to: CGPoint(x: c.x + cos(a + 0.15) * r * 1.08, y: c.y + sin(a + 0.15) * r * 1.08))
            let lit = sin(a) < 0 && cos(a) < 0.3
            ctx.stroke(strand, with: .color((lit ? Color.white : dark).opacity(lit ? 0.45 : 0.35)),
                       style: StrokeStyle(lineWidth: head.line(0.018, minimum: 0.4), lineCap: .round))
        }
    }

    /// A deterministic "random" number in -1…1, so fuzz and texture stay put from frame to frame.
    private static func noise(_ i: Int, _ seed: Int) -> Double {
        let v = sin(Double(i) * 12.9898 + Double(seed) * 78.233) * 43758.5453
        return (v - v.rounded(.down)) * 2 - 1
    }

    /// The bottom edge of a hat that wraps the head at height `y`: across the head, sagging a little in the middle
    /// because you look at it from slightly above.
    private static func rimCurve(_ path: inout Path, from x0: CGFloat, to x1: CGFloat, y: CGFloat, sag: CGFloat) {
        path.addQuadCurve(to: CGPoint(x: x1, y: y), control: CGPoint(x: (x0 + x1) / 2, y: y + sag * 2))
    }

    // MARK: Beanie

    /// A knitted beanie with a folded, ribbed cuff and a pom-pom.
    private static func drawBeanie(_ base: GraphicsContext, _ head: Head) {
        let R = head.R
        let shift = head.hatShift
        // Its shadow on the forehead, under the cuff.
        var shadowPath = Path()
        shadowPath.addEllipse(in: CGRect(x: -R * 0.98 + shift.width, y: -R * 0.42 + shift.height, width: R * 1.96, height: R * 0.26))
        castShadow(base, head, shadowPath, opacity: 0.38, blur: 0.07)

        var ctx = base
        ctx.translateBy(x: shift.width, y: shift.height)
        ctx.rotate(by: .radians(Double(head.yaw) * 0.1))

        let wool = Color(hex: 0xD9474F), woolLight = Color(hex: 0xF27A73), woolDark = Color(hex: 0x8C2234)

        // The crown of the hat, from the cuff up over the top of the head.
        var crown = Path()
        crown.move(to: CGPoint(x: -R * 0.92, y: -R * 0.56))
        crown.addCurve(to: CGPoint(x: 0, y: -R * 1.36), control1: CGPoint(x: -R * 0.98, y: -R * 1.12), control2: CGPoint(x: -R * 0.52, y: -R * 1.38))
        crown.addCurve(to: CGPoint(x: R * 0.92, y: -R * 0.56), control1: CGPoint(x: R * 0.52, y: -R * 1.38), control2: CGPoint(x: R * 0.98, y: -R * 1.12))
        rimCurve(&crown, from: R * 0.92, to: -R * 0.92, y: -R * 0.56, sag: R * 0.05)
        crown.closeSubpath()
        let crownRect = CGRect(x: -R * 0.95, y: -R * 1.38, width: R * 1.9, height: R * 0.84)
        ctx.fill(crown, with: .linearGradient(Gradient(colors: [woolLight, wool, woolDark]),
                                              startPoint: CGPoint(x: -R * 0.5, y: -R * 1.35), endPoint: CGPoint(x: R * 0.6, y: -R * 0.5)))
        // Knit: ribs running up the crown (they slide round as he turns), each a row of small V stitches.
        var knit = ctx
        knit.clip(to: crown)
        let ribs = head.detailed ? 9 : 5
        for i in 0...ribs {
            let u = CGFloat(i) / CGFloat(ribs) * 2 - 1
            let bottom = u * R * 0.9 + head.front(-R * 0.6) * 0.6
            var rib = Path()
            rib.move(to: CGPoint(x: bottom, y: -R * 0.55))
            rib.addQuadCurve(to: CGPoint(x: bottom * 0.15, y: -R * 1.34), control: CGPoint(x: bottom * 1.02, y: -R * 1.12))
            knit.stroke(rib, with: .color(woolDark.opacity(0.35)), style: StrokeStyle(lineWidth: head.line(0.045)))
            if head.detailed {
                knit.stroke(rib.offsetBy(dx: R * 0.04, dy: 0), with: .color(woolLight.opacity(0.28)),
                            style: StrokeStyle(lineWidth: head.line(0.02, minimum: 0.3)))
            }
        }
        roundShading(&knit, crown, in: crownRect, sheen: 0.16, shade: 0.42)
        ctx.stroke(crown, with: .color(woolDark.opacity(0.5)), lineWidth: head.line(0.02, minimum: 0.35))

        // The folded cuff: a thick ribbed band, a shade darker, its top edge catching the light.
        var cuff = Path()
        cuff.move(to: CGPoint(x: -R * 0.97, y: -R * 0.66))
        rimCurve(&cuff, from: -R * 0.97, to: R * 0.97, y: -R * 0.66, sag: R * 0.06)
        cuff.addQuadCurve(to: CGPoint(x: R * 1.02, y: -R * 0.38), control: CGPoint(x: R * 1.08, y: -R * 0.52))
        rimCurve(&cuff, from: R * 1.02, to: -R * 1.02, y: -R * 0.38, sag: R * 0.08)
        cuff.addQuadCurve(to: CGPoint(x: -R * 0.97, y: -R * 0.66), control: CGPoint(x: -R * 1.08, y: -R * 0.52))
        cuff.closeSubpath()
        ctx.fill(cuff, with: .linearGradient(Gradient(colors: [wool, woolDark]),
                                             startPoint: CGPoint(x: 0, y: -R * 0.66), endPoint: CGPoint(x: 0, y: -R * 0.3)))
        var band = ctx
        band.clip(to: cuff)
        let stitches = head.detailed ? 22 : 12
        for i in 0...stitches {
            let u = CGFloat(i) / CGFloat(stitches) * 2 - 1
            // Ribs bunch up towards the sides of the head, where the band turns away.
            let x = sin(u * .pi / 2) * R * 1.02 + head.front(-R * 0.5) * 0.5
            var rib = Path()
            rib.move(to: CGPoint(x: x, y: -R * 0.7))
            rib.addLine(to: CGPoint(x: x * 1.02, y: -R * 0.28))
            band.stroke(rib, with: .color(woolDark.opacity(0.55)), style: StrokeStyle(lineWidth: head.line(0.03, minimum: 0.35)))
        }
        roundShading(&band, cuff, in: CGRect(x: -R, y: -R * 0.7, width: R * 2, height: R * 0.4), sheen: 0.12, shade: 0.35)
        var fold = Path()
        fold.move(to: CGPoint(x: -R * 0.9, y: -R * 0.63))
        rimCurve(&fold, from: -R * 0.9, to: R * 0.9, y: -R * 0.63, sag: R * 0.06)
        ctx.stroke(fold, with: .color(woolLight.opacity(0.7)), style: StrokeStyle(lineWidth: head.line(0.035), lineCap: .round))

        fuzzyBall(ctx, head, center: CGPoint(x: head.front(-R) * 0.15, y: -R * 1.42), radius: R * 0.24,
                  light: Color(hex: 0xFFF6EE), base: Color(hex: 0xF1E3D3), dark: Color(hex: 0xB9A48E))
    }

    // MARK: Nightcap and Santa hat

    private enum FloppyStyle { case nightcap, santa }

    /// A soft, long cap whose tip flops over to his right, with a fur band and a pom-pom.
    private static func drawFloppyHat(_ base: GraphicsContext, _ head: Head, style: FloppyStyle) {
        let R = head.R
        let shift = head.hatShift
        var shadowPath = Path()
        shadowPath.addEllipse(in: CGRect(x: -R * 0.96 + shift.width, y: -R * 0.44 + shift.height, width: R * 1.92, height: R * 0.24))
        castShadow(base, head, shadowPath, opacity: 0.34, blur: 0.08)

        var ctx = base
        ctx.translateBy(x: shift.width, y: shift.height)
        // The tip swings a little against the turn of his head, as cloth does.
        let swing = -head.yaw * R * 0.25

        let colors: (Color, Color, Color) = style == .nightcap
            ? (Color(hex: 0x4A4FC4), Color(hex: 0x7C82F0), Color(hex: 0x23256B))
            : (Color(hex: 0xC8102E), Color(hex: 0xF0434F), Color(hex: 0x6E0717))
        let (cloth, light, dark) = colors
        let tip = CGPoint(x: R * 1.18 + swing, y: -R * 0.72)

        var cap = Path()
        cap.move(to: CGPoint(x: -R * 0.94, y: -R * 0.55))
        cap.addCurve(to: CGPoint(x: R * 0.05, y: -R * 1.42), control1: CGPoint(x: -R * 1.0, y: -R * 1.1), control2: CGPoint(x: -R * 0.55, y: -R * 1.45))
        cap.addCurve(to: tip, control1: CGPoint(x: R * 0.7, y: -R * 1.4), control2: CGPoint(x: R * 1.12 + swing, y: -R * 1.18))
        cap.addCurve(to: CGPoint(x: R * 0.58, y: -R * 1.0), control1: CGPoint(x: R * 1.02 + swing, y: -R * 0.98), control2: CGPoint(x: R * 0.8, y: -R * 0.98))
        cap.addQuadCurve(to: CGPoint(x: R * 0.94, y: -R * 0.55), control: CGPoint(x: R * 0.9, y: -R * 0.82))
        rimCurve(&cap, from: R * 0.94, to: -R * 0.94, y: -R * 0.55, sag: R * 0.05)
        cap.closeSubpath()
        let capRect = CGRect(x: -R, y: -R * 1.45, width: R * 2.2, height: R * 0.95)
        ctx.fill(cap, with: .linearGradient(Gradient(colors: [light, cloth, dark]),
                                            startPoint: CGPoint(x: -R * 0.6, y: -R * 1.4), endPoint: CGPoint(x: R * 0.9, y: -R * 0.6)))
        var inside = ctx
        inside.clip(to: cap)
        // The fold where the tip flops over: a dark crease and a lit ridge above it.
        var crease = Path()
        crease.move(to: CGPoint(x: R * 0.2, y: -R * 1.3))
        crease.addQuadCurve(to: CGPoint(x: R * 0.62, y: -R * 0.98), control: CGPoint(x: R * 0.55, y: -R * 1.28))
        inside.stroke(crease, with: .color(dark.opacity(0.7)), style: StrokeStyle(lineWidth: head.line(0.09), lineCap: .round))
        inside.stroke(crease.offsetBy(dx: -R * 0.05, dy: -R * 0.06), with: .color(light.opacity(0.45)),
                      style: StrokeStyle(lineWidth: head.line(0.04), lineCap: .round))
        switch style {
        case .nightcap:
            // Little stars on the cloth.
            let stars: [(CGFloat, CGFloat, CGFloat)] = [(-0.55, -0.85, 0.07), (-0.1, -1.1, 0.055), (0.32, -0.78, 0.06), (-0.35, -1.25, 0.045), (0.75, -1.18, 0.05)]
            for (x, y, r) in stars {
                star(&inside, center: CGPoint(x: (x + head.front(y * R) / R * 0.4) * R, y: y * R), radius: R * r,
                     color: Color(hex: 0xFFE7A0).opacity(0.85))
            }
        case .santa:
            // Velvet: a soft sheen along the lit side.
            var sheen = Path()
            sheen.move(to: CGPoint(x: -R * 0.75, y: -R * 0.65))
            sheen.addQuadCurve(to: CGPoint(x: -R * 0.1, y: -R * 1.32), control: CGPoint(x: -R * 0.78, y: -R * 1.2))
            inside.stroke(sheen, with: .color(Color.white.opacity(0.22)), style: StrokeStyle(lineWidth: head.line(0.14), lineCap: .round))
        }
        roundShading(&inside, cap, in: capRect, sheen: 0.12, shade: 0.4)
        ctx.stroke(cap, with: .color(dark.opacity(0.55)), lineWidth: head.line(0.02, minimum: 0.35))

        // The fur band around the head.
        fur(ctx, head, from: -R * 1.02, to: R * 1.02, y: -R * 0.5, height: R * 0.26)
        fuzzyBall(ctx, head, center: CGPoint(x: tip.x + R * 0.04, y: tip.y + R * 0.12), radius: R * 0.19,
                  light: Color.white, base: Color(hex: 0xF3F0EA), dark: Color(hex: 0xB8B2A8))
    }

    /// A fluffy white band: a row of overlapping tufts, lit from above.
    private static func fur(_ ctx: GraphicsContext, _ head: Head, from x0: CGFloat, to x1: CGFloat, y: CGFloat, height: CGFloat) {
        let R = head.R
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [Color.white, Color(hex: 0xF1EDE6), Color(hex: 0xBDB6AB)]),
            startPoint: CGPoint(x: 0, y: y - height / 2), endPoint: CGPoint(x: 0, y: y + height / 2))
        var band = Path()
        band.move(to: CGPoint(x: x0, y: y - height * 0.3))
        rimCurve(&band, from: x0, to: x1, y: y - height * 0.3, sag: R * 0.06)
        band.addQuadCurve(to: CGPoint(x: x1, y: y + height * 0.4), control: CGPoint(x: x1 + height * 0.3, y: y))
        rimCurve(&band, from: x1, to: x0, y: y + height * 0.4, sag: R * 0.08)
        band.addQuadCurve(to: CGPoint(x: x0, y: y - height * 0.3), control: CGPoint(x: x0 - height * 0.3, y: y))
        band.closeSubpath()
        ctx.fill(band, with: shading)
        let tufts = head.detailed ? 16 : 9
        for i in 0...tufts {
            let u = CGFloat(i) / CGFloat(tufts)
            let x = x0 + (x1 - x0) * u
            let sag = R * 0.24 * (1 - pow(2 * u - 1, 2)) * 0.5
            for edge in [-1, 1] as [CGFloat] {
                let r = height * (0.24 + 0.06 * CGFloat(noise(i, edge > 0 ? 5 : 6)))
                let c = CGPoint(x: x, y: y + edge * height * 0.36 + sag)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: shading)
            }
        }
    }

    // MARK: Party hat

    /// A striped cardboard cone with a gold rim and a tinsel pom-pom.
    private static func drawPartyHat(_ base: GraphicsContext, _ head: Head) {
        let R = head.R
        let shift = head.hatShift
        var shadowPath = Path()
        shadowPath.addEllipse(in: CGRect(x: -R * 0.62 + shift.width, y: -R * 0.82 + shift.height, width: R * 1.3, height: R * 0.24))
        castShadow(base, head, shadowPath, opacity: 0.35, blur: 0.06)

        var ctx = base
        ctx.translateBy(x: shift.width, y: shift.height)
        ctx.rotate(by: .radians(0.12 + Double(head.yaw) * 0.15))
        let apex = CGPoint(x: R * 0.04, y: -R * 2.02)
        let baseY = -R * 0.74, half = R * 0.6

        var cone = Path()
        cone.move(to: CGPoint(x: -half, y: baseY))
        cone.addLine(to: apex)
        cone.addLine(to: CGPoint(x: half, y: baseY))
        cone.addQuadCurve(to: CGPoint(x: -half, y: baseY), control: CGPoint(x: 0, y: baseY + R * 0.3))
        cone.closeSubpath()
        ctx.fill(cone, with: .color(Color(hex: 0x7B61FF)))
        var paper = ctx
        paper.clip(to: cone)
        // Diagonal stripes that wind round the cone and slide as he turns.
        let turn = head.front(-R * 0.9) * 0.9
        for i in -6...6 {
            let y = CGFloat(i) * R * 0.28
            var stripe = Path()
            stripe.move(to: CGPoint(x: -R * 1.2 + turn, y: baseY + y))
            stripe.addLine(to: CGPoint(x: R * 1.2 + turn, y: baseY + y - R * 0.55))
            paper.stroke(stripe, with: .color(Color(hex: 0xFFC83D)), style: StrokeStyle(lineWidth: R * 0.11))
        }
        // Confetti dots printed on the paper.
        if head.detailed {
            for i in 0..<9 {
                let x = CGFloat(noise(i, 7)) * R * 0.45 + turn * 0.5
                let y = baseY - R * 0.1 - CGFloat(noise(i, 8) * 0.5 + 0.5) * R * 1.0
                let colors: [Color] = [Color(hex: 0x46E0A6), Color(hex: 0xFF6B6B), Color.white]
                paper.fill(Path(ellipseIn: CGRect(x: x - R * 0.035, y: y - R * 0.035, width: R * 0.07, height: R * 0.07)),
                           with: .color(colors[i % 3]))
            }
        }
        // A cone is lit on one side and dark on the other.
        paper.fill(cone, with: .linearGradient(
            Gradient(stops: [
                .init(color: .white.opacity(0.32), location: 0),
                .init(color: .white.opacity(0), location: 0.35),
                .init(color: .black.opacity(0), location: 0.55),
                .init(color: .black.opacity(0.42), location: 1)
            ]),
            startPoint: CGPoint(x: -half, y: 0), endPoint: CGPoint(x: half, y: 0)))
        ctx.stroke(cone, with: .color(Color.black.opacity(0.25)), lineWidth: head.line(0.02, minimum: 0.35))

        // Gold rim along the front of the base.
        var rim = Path()
        rim.move(to: CGPoint(x: -half, y: baseY))
        rim.addQuadCurve(to: CGPoint(x: half, y: baseY), control: CGPoint(x: 0, y: baseY + R * 0.3))
        ctx.stroke(rim, with: .linearGradient(Gradient(colors: [Color(hex: 0xFFF1A8), Color(hex: 0xE0A82E), Color(hex: 0x9A6A12)]),
                                              startPoint: CGPoint(x: -half, y: baseY), endPoint: CGPoint(x: half, y: baseY)),
                   style: StrokeStyle(lineWidth: head.line(0.09), lineCap: .round))

        fuzzyBall(ctx, head, center: CGPoint(x: apex.x, y: apex.y - R * 0.06), radius: R * 0.17,
                  light: Color(hex: 0xFFC2C2), base: Color(hex: 0xFF5C6C), dark: Color(hex: 0xA3182B))
    }

    // MARK: Crown

    private static let gold = Gradient(stops: [
        .init(color: Color(hex: 0xFFF6C4), location: 0),
        .init(color: Color(hex: 0xF4C542), location: 0.3),
        .init(color: Color(hex: 0xB07B12), location: 0.55),
        .init(color: Color(hex: 0xF1BF3C), location: 0.75),
        .init(color: Color(hex: 0x7A5306), location: 1)
    ])

    /// The far side of the crown's ring, seen between the points at the front.
    private static func drawCrownBack(_ base: GraphicsContext, _ head: Head) {
        let R = head.R
        var ctx = base
        ctx.translateBy(x: head.hatShift.width, y: head.hatShift.height)
        let half = R * 0.66, top = -R * 1.02
        var ring = Path()
        ring.move(to: CGPoint(x: -half, y: top))
        ring.addQuadCurve(to: CGPoint(x: half, y: top), control: CGPoint(x: 0, y: top - R * 0.24))
        ctx.stroke(ring, with: .color(Color(hex: 0x8A5F0A)), style: StrokeStyle(lineWidth: R * 0.16, lineCap: .round))
        // The points at the back, darker: they face away from the light.
        for i in 0..<3 {
            let x = (CGFloat(i) - 1) * R * 0.42 - head.front(top) * 0.5
            var point = Path()
            point.move(to: CGPoint(x: x - R * 0.13, y: top - R * 0.08))
            point.addLine(to: CGPoint(x: x, y: top - R * 0.48))
            point.addLine(to: CGPoint(x: x + R * 0.13, y: top - R * 0.08))
            point.closeSubpath()
            ctx.fill(point, with: .color(Color(hex: 0x7A5306)))
        }
    }

    /// A small gold crown: a band with gems, five points with pearls, and red velvet inside.
    private static func drawCrown(_ base: GraphicsContext, _ head: Head) {
        let R = head.R
        let shift = head.hatShift
        var shadowPath = Path()
        shadowPath.addEllipse(in: CGRect(x: -R * 0.7 + shift.width, y: -R * 0.82 + shift.height, width: R * 1.4, height: R * 0.2))
        castShadow(base, head, shadowPath, opacity: 0.35, blur: 0.06)

        var ctx = base
        ctx.translateBy(x: shift.width, y: shift.height)
        let half = R * 0.7, bottom = -R * 0.76, top = -R * 1.02

        // Velvet cap inside the ring.
        var velvet = Path()
        velvet.move(to: CGPoint(x: -half * 0.92, y: top))
        velvet.addCurve(to: CGPoint(x: half * 0.92, y: top), control1: CGPoint(x: -half * 0.8, y: top - R * 0.5), control2: CGPoint(x: half * 0.8, y: top - R * 0.5))
        velvet.closeSubpath()
        ctx.fill(velvet, with: .radialGradient(Gradient(colors: [Color(hex: 0xD3324A), Color(hex: 0x6E0B1C)]),
                                               center: CGPoint(x: -R * 0.2, y: top - R * 0.3), startRadius: 0, endRadius: R * 0.8))

        // The points: three at the front, two half-turned at the sides.
        let points: [(x: CGFloat, height: CGFloat, width: CGFloat)] = [(-0.62, 0.36, 0.1), (-0.33, 0.5, 0.15), (0, 0.6, 0.17), (0.33, 0.5, 0.15), (0.62, 0.36, 0.1)]
        let slide = head.front(top) * 0.35
        var crown = Path()
        crown.move(to: CGPoint(x: -half, y: bottom))
        crown.addLine(to: CGPoint(x: -half, y: top))
        for p in points {
            let x = p.x * R + slide * (1 - abs(p.x))
            crown.addLine(to: CGPoint(x: x - p.width * R, y: top - R * 0.02))
            crown.addLine(to: CGPoint(x: x, y: top - p.height * R))
            crown.addLine(to: CGPoint(x: x + p.width * R, y: top - R * 0.02))
        }
        crown.addLine(to: CGPoint(x: half, y: top))
        crown.addLine(to: CGPoint(x: half, y: bottom))
        crown.addQuadCurve(to: CGPoint(x: -half, y: bottom), control: CGPoint(x: 0, y: bottom + R * 0.2))
        crown.closeSubpath()
        ctx.fill(crown, with: .linearGradient(gold, startPoint: CGPoint(x: 0, y: top - R * 0.6), endPoint: CGPoint(x: 0, y: bottom + R * 0.1)))
        var metal = ctx
        metal.clip(to: crown)
        // Polished metal: a bright vertical streak on the lit side, dark on the far side.
        metal.fill(crown, with: .linearGradient(
            Gradient(stops: [
                .init(color: .black.opacity(0.1), location: 0),
                .init(color: .white.opacity(0.5), location: 0.28),
                .init(color: .white.opacity(0), location: 0.4),
                .init(color: .black.opacity(0), location: 0.6),
                .init(color: .black.opacity(0.45), location: 1)
            ]),
            startPoint: CGPoint(x: -half + slide, y: 0), endPoint: CGPoint(x: half + slide, y: 0)))
        // The band's raised edges.
        for (y, sag) in [(top, R * 0.06), (bottom - R * 0.02, R * 0.1)] {
            var edge = Path()
            edge.move(to: CGPoint(x: -half, y: y))
            rimCurve(&edge, from: -half, to: half, y: y, sag: sag)
            metal.stroke(edge, with: .color(Color(hex: 0xFFF3B8).opacity(0.85)), style: StrokeStyle(lineWidth: head.line(0.035, minimum: 0.35)))
        }
        ctx.stroke(crown, with: .color(Color(hex: 0x5C3D04).opacity(0.7)), lineWidth: head.line(0.02, minimum: 0.35))

        // Pearls on the tips.
        for p in points {
            let x = p.x * R + slide * (1 - abs(p.x))
            let r = R * (p.height > 0.45 ? 0.07 : 0.055)
            let c = CGPoint(x: x, y: top - p.height * R - r * 0.6)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                     with: .radialGradient(Gradient(colors: [Color.white, Color(hex: 0xEDE6F3), Color(hex: 0x9C90A8)]),
                                           center: CGPoint(x: c.x - r * 0.35, y: c.y - r * 0.4), startRadius: 0, endRadius: r * 1.4))
        }
        // Gems on the band: a ruby in the middle, sapphires beside it.
        let gemY = (top + bottom) / 2 + R * 0.04
        let gems: [(x: CGFloat, r: CGFloat, light: UInt32, deep: UInt32)] = [(-0.38, 0.07, 0x7FB2FF, 0x0B2E8A), (0, 0.1, 0xFF7A8E, 0x8A0020), (0.38, 0.07, 0x7FB2FF, 0x0B2E8A)]
        for g in gems {
            let x = g.x * R * head.foreshortening + head.front(gemY) * 0.8
            let rx = g.r * R * head.foreshortening, ry = g.r * R * 1.1
            let rect = CGRect(x: x - rx, y: gemY - ry, width: rx * 2, height: ry * 2)
            ctx.fill(Path(ellipseIn: rect.insetBy(dx: -R * 0.02, dy: -R * 0.02)), with: .color(Color(hex: 0x6B4706)))
            ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
                Gradient(colors: [Color(hex: g.light), Color(hex: g.deep)]),
                center: CGPoint(x: x - rx * 0.3, y: gemY - ry * 0.35), startRadius: 0, endRadius: max(rx, ry) * 1.3))
            let glint = max(0.5, ry * 0.32)
            ctx.fill(Path(ellipseIn: CGRect(x: x - rx * 0.45, y: gemY - ry * 0.6, width: glint, height: glint)), with: .color(Color.white.opacity(0.9)))
        }
        if head.detailed {
            star(&ctx, center: CGPoint(x: -R * 0.48 + slide, y: top - R * 0.28), radius: R * 0.08, color: .white.opacity(0.9))
        }
    }

    // MARK: Hard hat

    /// A glossy yellow safety helmet with a ridge over the top and a brim that shades his eyes a little.
    private static func drawHardHat(_ base: GraphicsContext, _ head: Head) {
        let R = head.R
        let shift = head.hatShift
        var shadowPath = Path()
        shadowPath.addEllipse(in: CGRect(x: -R * 1.05 + shift.width, y: -R * 0.48 + shift.height, width: R * 2.1, height: R * 0.36))
        castShadow(base, head, shadowPath, opacity: 0.45, blur: 0.09)

        var ctx = base
        ctx.translateBy(x: shift.width, y: shift.height)
        let yellow = Color(hex: 0xFFC61A), light = Color(hex: 0xFFE68A), deep = Color(hex: 0xC27F00)

        var dome = Path()
        dome.move(to: CGPoint(x: -R * 0.98, y: -R * 0.52))
        dome.addCurve(to: CGPoint(x: 0, y: -R * 1.36), control1: CGPoint(x: -R * 1.02, y: -R * 1.08), control2: CGPoint(x: -R * 0.58, y: -R * 1.38))
        dome.addCurve(to: CGPoint(x: R * 0.98, y: -R * 0.52), control1: CGPoint(x: R * 0.58, y: -R * 1.38), control2: CGPoint(x: R * 1.02, y: -R * 1.08))
        rimCurve(&dome, from: R * 0.98, to: -R * 0.98, y: -R * 0.52, sag: R * 0.05)
        dome.closeSubpath()
        let domeRect = CGRect(x: -R, y: -R * 1.38, width: R * 2, height: R * 0.86)
        ctx.fill(dome, with: .linearGradient(Gradient(colors: [light, yellow, deep]),
                                             startPoint: CGPoint(x: -R * 0.5, y: -R * 1.3), endPoint: CGPoint(x: R * 0.7, y: -R * 0.5)))
        var shell = ctx
        shell.clip(to: dome)
        // Ribs over the top: the middle one raised and lit, two fainter ones beside it.
        for (offset, strength) in [(-0.45, 0.5), (0, 1), (0.45, 0.5)] as [(CGFloat, Double)] {
            let x = offset * R + head.front(-R * 0.9) * 0.9
            var rib = Path()
            rib.move(to: CGPoint(x: x * 1.15, y: -R * 0.5))
            rib.addQuadCurve(to: CGPoint(x: x * 0.3, y: -R * 1.36), control: CGPoint(x: x * 1.1, y: -R * 1.2))
            shell.stroke(rib, with: .color(deep.opacity(0.6 * strength)), style: StrokeStyle(lineWidth: head.line(0.13 * CGFloat(strength))))
            shell.stroke(rib.offsetBy(dx: -R * 0.05, dy: 0), with: .color(Color.white.opacity(0.55 * strength)),
                         style: StrokeStyle(lineWidth: head.line(0.045 * CGFloat(strength), minimum: 0.3)))
        }
        roundShading(&shell, dome, in: domeRect, sheen: 0.2, shade: 0.35)
        // A glossy highlight, as on hard plastic.
        shell.drawLayer { gloss in
            gloss.addFilter(.blur(radius: max(0.3, R * 0.05)))
            let spot = Path(ellipseIn: CGRect(x: -R * 0.25, y: -R * 0.14, width: R * 0.5, height: R * 0.28))
                .applying(CGAffineTransform(rotationAngle: -0.35))
                .offsetBy(dx: -R * 0.47, dy: -R * 1.08)
            gloss.fill(spot, with: .color(Color.white.opacity(0.85)))
        }
        ctx.stroke(dome, with: .color(deep.opacity(0.6)), lineWidth: head.line(0.02, minimum: 0.35))

        // The brim, wider at the front.
        var brim = Path()
        brim.move(to: CGPoint(x: -R * 1.14, y: -R * 0.56))
        rimCurve(&brim, from: -R * 1.14, to: R * 1.14, y: -R * 0.56, sag: R * 0.08)
        brim.addQuadCurve(to: CGPoint(x: R * 1.1, y: -R * 0.44), control: CGPoint(x: R * 1.2, y: -R * 0.5))
        rimCurve(&brim, from: R * 1.1, to: -R * 1.1, y: -R * 0.44, sag: R * 0.12)
        brim.addQuadCurve(to: CGPoint(x: -R * 1.14, y: -R * 0.56), control: CGPoint(x: -R * 1.2, y: -R * 0.5))
        brim.closeSubpath()
        ctx.fill(brim, with: .linearGradient(Gradient(colors: [light, yellow, deep]),
                                             startPoint: CGPoint(x: 0, y: -R * 0.6), endPoint: CGPoint(x: 0, y: -R * 0.32)))
        ctx.stroke(brim, with: .color(deep.opacity(0.7)), lineWidth: head.line(0.02, minimum: 0.35))
    }

    // MARK: Beret

    /// A felt beret, slouched over to one side, with the little stalk on top.
    private static func drawBeret(_ base: GraphicsContext, _ head: Head) {
        let R = head.R
        let shift = head.hatShift
        var shadowPath = Path()
        shadowPath.addEllipse(in: CGRect(x: -R * 0.9 + shift.width, y: -R * 0.66 + shift.height, width: R * 1.95, height: R * 0.26))
        castShadow(base, head, shadowPath, opacity: 0.4, blur: 0.08)

        var ctx = base
        ctx.translateBy(x: shift.width + R * 0.1, y: shift.height - R * 0.8)
        ctx.rotate(by: .radians(-0.2 + Double(head.yaw) * 0.12))
        let felt = Color(hex: 0xB32B45), light = Color(hex: 0xE05A70), deep = Color(hex: 0x5E1020)

        // The headband where it meets his head.
        let band = Path(ellipseIn: CGRect(x: -R * 0.82, y: R * 0.12, width: R * 1.64, height: R * 0.2))
        ctx.fill(band, with: .color(deep))

        let disc = Path(ellipseIn: CGRect(x: -R * 1.08, y: -R * 0.38, width: R * 2.16, height: R * 0.66))
        ctx.fill(disc, with: .radialGradient(Gradient(colors: [light, felt, deep]),
                                             center: CGPoint(x: -R * 0.45, y: -R * 0.25), startRadius: 0, endRadius: R * 1.5))
        var cloth = ctx
        cloth.clip(to: disc)
        // The underside curling in at the bottom edge.
        cloth.fill(Path(ellipseIn: CGRect(x: -R * 1.0, y: R * 0.02, width: R * 2.0, height: R * 0.46)), with: .color(deep.opacity(0.55)))
        // Felt: fine speckle on larger orbs.
        if head.detailed {
            for i in 0..<40 {
                let x = CGFloat(noise(i, 9)) * R
                let y = CGFloat(noise(i, 10)) * R * 0.3 - R * 0.05
                let r = R * 0.012
                cloth.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                           with: .color((i % 2 == 0 ? Color.white : Color.black).opacity(0.12)))
            }
        }
        ctx.stroke(disc, with: .color(deep.opacity(0.6)), lineWidth: head.line(0.02, minimum: 0.35))

        var stalk = Path()
        stalk.move(to: CGPoint(x: -R * 0.02, y: -R * 0.3))
        stalk.addQuadCurve(to: CGPoint(x: R * 0.08, y: -R * 0.5), control: CGPoint(x: -R * 0.04, y: -R * 0.45))
        ctx.stroke(stalk, with: .color(deep), style: StrokeStyle(lineWidth: head.line(0.07), lineCap: .round))
    }

    // MARK: Glasses

    /// Thin gold round glasses: lenses with a faint reflection, a keyhole bridge, and a shadow of the frame on his face.
    private static func drawRoundGlasses(_ ctx: GraphicsContext, _ head: Head) {
        let R = head.R
        let r = head.size * 0.135
        let squeeze = 1 - 0.28 * abs(head.gaze.x)
        let left = head.eye(-1), right = head.eye(1)
        func lens(_ c: CGPoint) -> Path {
            Path(ellipseIn: CGRect(x: c.x - r * squeeze, y: c.y - r, width: 2 * r * squeeze, height: 2 * r))
        }
        var frame = Path()
        frame.addPath(lens(left))
        frame.addPath(lens(right))
        var bridge = Path()
        bridge.move(to: CGPoint(x: left.x + r * squeeze, y: left.y - r * 0.15))
        bridge.addQuadCurve(to: CGPoint(x: right.x - r * squeeze, y: right.y - r * 0.15),
                            control: CGPoint(x: (left.x + right.x) / 2, y: left.y - r * 0.7))
        frame.addPath(bridge)
        // Temples running back towards his ears, to the edge of his head.
        var temples = Path()
        for (c, side) in [(left, CGFloat(-1)), (right, CGFloat(1))] {
            temples.move(to: CGPoint(x: c.x + side * r * squeeze, y: c.y - r * 0.2))
            temples.addLine(to: CGPoint(x: side * R * 0.97 * head.foreshortening + head.gaze.x * R * 0.1, y: c.y - r * 0.35))
        }
        let width = head.line(0.045, minimum: 0.7)

        // The frame's shadow, down and to the right of it.
        var shadowPath = frame
        shadowPath.addPath(temples)
        castShadow(ctx, head, shadowPath.strokedPath(StrokeStyle(lineWidth: width)).offsetBy(dx: R * 0.03, dy: R * 0.05), opacity: 0.3, blur: 0.03)

        var glass = ctx
        for c in [left, right] {
            let l = lens(c)
            glass.fill(l, with: .color(Color(hex: 0xBFD8FF).opacity(0.1)))
            var reflect = glass
            reflect.clip(to: l)
            // Two slanted streaks of light across each lens.
            for (offset, w) in [(-0.35, 0.28), (0.12, 0.12)] as [(CGFloat, CGFloat)] {
                var streak = Path()
                streak.move(to: CGPoint(x: c.x + (offset - 0.6) * r, y: c.y + r))
                streak.addLine(to: CGPoint(x: c.x + (offset + 0.6) * r, y: c.y - r))
                reflect.stroke(streak, with: .color(Color.white.opacity(0.16)), style: StrokeStyle(lineWidth: w * r))
            }
        }
        let metal = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [Color(hex: 0xFFF0B8), Color(hex: 0xD9A441), Color(hex: 0x8A5C14)]),
            startPoint: CGPoint(x: left.x - r, y: left.y - r), endPoint: CGPoint(x: right.x + r, y: right.y + r))
        glass.stroke(temples, with: metal, style: StrokeStyle(lineWidth: width * 0.8, lineCap: .round))
        glass.stroke(frame, with: metal, style: StrokeStyle(lineWidth: width, lineCap: .round))
        if head.detailed {
            // A thin dark inner edge gives the frame its thickness.
            for c in [left, right] {
                glass.stroke(Path(ellipseIn: CGRect(x: c.x - (r - width * 0.6) * squeeze, y: c.y - r + width * 0.6,
                                                    width: 2 * (r - width * 0.6) * squeeze, height: 2 * (r - width * 0.6))),
                             with: .color(Color(hex: 0x5A3A08).opacity(0.5)), lineWidth: width * 0.3)
            }
        }
    }

    /// Aviator sunglasses: dark gradient lenses with a sky reflection, a gold frame and a double bridge.
    private static func drawSunglasses(_ ctx: GraphicsContext, _ head: Head) {
        let R = head.R
        let squeeze = 1 - 0.28 * abs(head.gaze.x)
        let w = head.size * 0.16 * squeeze, h = head.size * 0.13
        let left = head.eye(-1), right = head.eye(1)
        /// A teardrop lens, the low point towards the outside.
        func lens(_ c: CGPoint, side: CGFloat) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: c.x - side * w, y: c.y - h * 0.75))
            p.addCurve(to: CGPoint(x: c.x + side * w * 1.02, y: c.y - h * 0.55),
                       control1: CGPoint(x: c.x - side * w * 0.2, y: c.y - h * 0.95), control2: CGPoint(x: c.x + side * w * 0.8, y: c.y - h * 0.95))
            p.addCurve(to: CGPoint(x: c.x + side * w * 0.2, y: c.y + h * 0.95),
                       control1: CGPoint(x: c.x + side * w * 1.2, y: c.y + h * 0.2), control2: CGPoint(x: c.x + side * w * 0.85, y: c.y + h * 0.95))
            p.addCurve(to: CGPoint(x: c.x - side * w, y: c.y - h * 0.75),
                       control1: CGPoint(x: c.x - side * w * 0.6, y: c.y + h * 0.95), control2: CGPoint(x: c.x - side * w * 1.05, y: c.y + h * 0.1))
            p.closeSubpath()
            return p
        }
        let lenses = [lens(left, side: -1), lens(right, side: 1)]
        var all = Path()
        for l in lenses { all.addPath(l) }
        castShadow(ctx, head, all.offsetBy(dx: R * 0.04, dy: R * 0.08), opacity: 0.4, blur: 0.08)

        var glass = ctx
        for (l, c) in zip(lenses, [left, right]) {
            glass.fill(l, with: .linearGradient(Gradient(colors: [Color(hex: 0x1A1B26), Color(hex: 0x2E2A44), Color(hex: 0x4B3A5E)]),
                                                startPoint: CGPoint(x: c.x, y: c.y - h), endPoint: CGPoint(x: c.x, y: c.y + h)))
            var sky = glass
            sky.clip(to: l)
            // The sky and the horizon reflected in the top half, and a glint.
            sky.fill(Path(CGRect(x: c.x - w * 1.3, y: c.y - h, width: w * 2.6, height: h * 0.8)),
                     with: .linearGradient(Gradient(colors: [Color(hex: 0x9CC8FF).opacity(0.55), Color(hex: 0xFFB3C7).opacity(0.25), Color.clear]),
                                           startPoint: CGPoint(x: c.x, y: c.y - h), endPoint: CGPoint(x: c.x, y: c.y - h * 0.1)))
            var glint = Path()
            glint.move(to: CGPoint(x: c.x - w * 0.7, y: c.y + h * 0.4))
            glint.addLine(to: CGPoint(x: c.x + w * 0.1, y: c.y - h * 0.8))
            sky.stroke(glint, with: .color(Color.white.opacity(0.4)), style: StrokeStyle(lineWidth: w * 0.16, lineCap: .round))
        }
        let metal = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [Color(hex: 0xFFF0B8), Color(hex: 0xD9A441), Color(hex: 0x8A5C14)]),
            startPoint: CGPoint(x: left.x - w, y: left.y - h), endPoint: CGPoint(x: right.x + w, y: right.y + h))
        let line = head.line(0.035, minimum: 0.55)
        for l in lenses { glass.stroke(l, with: metal, lineWidth: line) }
        var bridge = Path()
        for dy in [-0.62, -0.3] as [CGFloat] {
            bridge.move(to: CGPoint(x: left.x + w * 0.95, y: left.y + h * dy))
            bridge.addQuadCurve(to: CGPoint(x: right.x - w * 0.95, y: right.y + h * dy),
                                control: CGPoint(x: (left.x + right.x) / 2, y: left.y + h * (dy - 0.2)))
        }
        glass.stroke(bridge, with: metal, style: StrokeStyle(lineWidth: line, lineCap: .round))
        var temples = Path()
        for (c, side) in [(left, CGFloat(-1)), (right, CGFloat(1))] {
            temples.move(to: CGPoint(x: c.x + side * w, y: c.y - h * 0.65))
            temples.addLine(to: CGPoint(x: side * R * 0.97 * head.foreshortening + head.gaze.x * R * 0.1, y: c.y - h * 0.75))
        }
        glass.stroke(temples, with: metal, style: StrokeStyle(lineWidth: line * 0.9, lineCap: .round))
    }

    // MARK: Scarf

    private static let scarfWool = Color(hex: 0xE4572E)
    private static let scarfLight = Color(hex: 0xFF8A5C)
    private static let scarfDeep = Color(hex: 0x8F2A12)
    private static let scarfStripe = Color(hex: 0xF6E7CB)

    /// The scarf's band under his head, from one side round the bottom to the other.
    private static func scarfBand(_ R: CGFloat, outset: CGFloat = 0) -> Path {
        var band = Path()
        band.move(to: CGPoint(x: -R * (1.04 + outset), y: R * 0.36))
        band.addCurve(to: CGPoint(x: R * (1.04 + outset), y: R * 0.36),
                      control1: CGPoint(x: -R * (1.0 + outset), y: R * (1.24 + outset)), control2: CGPoint(x: R * (1.0 + outset), y: R * (1.24 + outset)))
        band.addQuadCurve(to: CGPoint(x: R * 0.9, y: R * 0.32), control: CGPoint(x: R * 0.98, y: R * 0.26))
        band.addCurve(to: CGPoint(x: -R * 0.9, y: R * 0.32),
                      control1: CGPoint(x: R * 0.72, y: R * 0.86), control2: CGPoint(x: -R * 0.72, y: R * 0.86))
        band.addQuadCurve(to: CGPoint(x: -R * (1.04 + outset), y: R * 0.36), control: CGPoint(x: -R * 0.98, y: R * 0.26))
        band.closeSubpath()
        return band
    }

    /// The far side of the wrap, peeking out a little around his head: it gives the scarf its thickness.
    private static func drawScarfBack(_ ctx: GraphicsContext, _ head: Head) {
        let R = head.R
        let band = scarfBand(R, outset: 0.06)
        ctx.fill(band, with: .linearGradient(Gradient(colors: [scarfDeep, Color(hex: 0x5C1A0A)]),
                                             startPoint: CGPoint(x: 0, y: R * 0.3), endPoint: CGPoint(x: 0, y: R * 1.3)))
    }

    /// A striped knitted scarf wrapped snugly under his face, knotted at the front with two fringed tails.
    private static func drawScarf(_ base: GraphicsContext, _ head: Head) {
        let R = head.R
        var ctx = base
        ctx.translateBy(x: head.gaze.x * R * 0.06, y: 0)
        let turn = head.front(R * 0.7) * 0.6

        // His head casts a soft shadow onto the top of the scarf.
        let band = scarfBand(R)
        ctx.fill(band, with: .linearGradient(Gradient(colors: [scarfLight, scarfWool, scarfDeep]),
                                             startPoint: CGPoint(x: -R * 0.6, y: R * 0.35), endPoint: CGPoint(x: R * 0.7, y: R * 1.2)))
        var knit = ctx
        knit.clip(to: band)
        // Stripes that follow the curve of the wrap.
        for (offset, width) in [(0.0, 0.07), (0.22, 0.07)] as [(CGFloat, CGFloat)] {
            var stripe = Path()
            stripe.move(to: CGPoint(x: -R * 1.1, y: R * (0.44 + offset)))
            stripe.addCurve(to: CGPoint(x: R * 1.1, y: R * (0.44 + offset)),
                            control1: CGPoint(x: -R * 0.9 + turn, y: R * (1.02 + offset)), control2: CGPoint(x: R * 0.9 + turn, y: R * (1.02 + offset)))
            knit.stroke(stripe, with: .color(scarfStripe.opacity(0.92)), style: StrokeStyle(lineWidth: R * width))
        }
        if head.detailed {
            // Knit rows: short slanted stitches across the band.
            for i in 0..<26 {
                let u = CGFloat(i) / 25 * 2 - 1
                let x = u * R * 0.98 + turn * 0.5
                let y = R * (0.62 + 0.32 * (1 - u * u))
                var stitch = Path()
                stitch.move(to: CGPoint(x: x - R * 0.03, y: y - R * 0.12))
                stitch.addLine(to: CGPoint(x: x + R * 0.03, y: y + R * 0.12))
                knit.stroke(stitch, with: .color(scarfDeep.opacity(0.28)), style: StrokeStyle(lineWidth: R * 0.025, lineCap: .round))
            }
        }
        knit.drawLayer { shade in
            shade.addFilter(.blur(radius: max(0.4, R * 0.06)))
            shade.fill(Path(ellipseIn: CGRect(x: -R * 0.7, y: R * 0.5, width: R * 1.4, height: R * 0.3)), with: .color(Color.black.opacity(0.28)))
        }
        roundShading(&knit, band, in: CGRect(x: -R * 1.05, y: R * 0.3, width: R * 2.1, height: R * 0.95), sheen: 0.12, shade: 0.4)
        ctx.stroke(band, with: .color(scarfDeep.opacity(0.6)), lineWidth: head.line(0.02, minimum: 0.35))

        // The knot and the two tails hanging from it, on his left.
        let knot = CGPoint(x: -R * 0.42 + turn, y: R * 0.93)
        for (angle, length, delay) in [(0.18, 0.62, 0.0), (-0.08, 0.5, 0.1)] as [(Double, CGFloat, CGFloat)] {
            var tail = ctx
            tail.translateBy(x: knot.x + R * delay, y: knot.y)
            tail.rotate(by: .radians(angle + Double(head.gaze.x) * -0.1))
            let rect = CGRect(x: -R * 0.15, y: 0, width: R * 0.3, height: R * length)
            let piece = Path(roundedRect: rect, cornerRadius: R * 0.06)
            tail.fill(piece, with: .linearGradient(Gradient(colors: [scarfWool, scarfDeep]),
                                                   startPoint: CGPoint(x: -R * 0.15, y: 0), endPoint: CGPoint(x: R * 0.15, y: 0)))
            var inside = tail
            inside.clip(to: piece)
            for k in 0..<3 {
                let y = R * (0.1 + 0.16 * CGFloat(k))
                inside.fill(Path(CGRect(x: -R * 0.2, y: y, width: R * 0.4, height: R * 0.06)), with: .color(scarfStripe.opacity(0.9)))
            }
            inside.fill(piece, with: .linearGradient(Gradient(colors: [Color.white.opacity(0.18), Color.clear, Color.black.opacity(0.3)]),
                                                     startPoint: CGPoint(x: -R * 0.15, y: 0), endPoint: CGPoint(x: R * 0.15, y: 0)))
            tail.stroke(piece, with: .color(scarfDeep.opacity(0.6)), lineWidth: head.line(0.02, minimum: 0.35))
            // Fringe.
            var fringe = Path()
            for k in 0...5 {
                let x = -R * 0.13 + R * 0.26 * CGFloat(k) / 5
                fringe.move(to: CGPoint(x: x, y: R * length))
                fringe.addLine(to: CGPoint(x: x + R * 0.01, y: R * (length + 0.1)))
            }
            tail.stroke(fringe, with: .color(scarfWool), style: StrokeStyle(lineWidth: head.line(0.035, minimum: 0.4), lineCap: .round))
        }
        let knotPath = Path(ellipseIn: CGRect(x: knot.x - R * 0.18, y: knot.y - R * 0.14, width: R * 0.36, height: R * 0.28))
        ctx.fill(knotPath, with: .radialGradient(Gradient(colors: [scarfLight, scarfWool, scarfDeep]),
                                                 center: CGPoint(x: knot.x - R * 0.06, y: knot.y - R * 0.06), startRadius: 0, endRadius: R * 0.24))
        ctx.stroke(knotPath, with: .color(scarfDeep.opacity(0.6)), lineWidth: head.line(0.02, minimum: 0.35))
    }

    // MARK: Small shapes

    /// A four-pointed sparkle.
    private static func star(_ ctx: inout GraphicsContext, center c: CGPoint, radius r: CGFloat, color: Color) {
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + r * 0.18, y: c.y - r * 0.18))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + r * 0.18, y: c.y + r * 0.18))
        p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - r * 0.18, y: c.y + r * 0.18))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - r * 0.18, y: c.y - r * 0.18))
        p.closeSubpath()
        ctx.fill(p, with: .color(color))
    }
}
