import SwiftUI
import AppKit

/// Nook: a round light with two eyes. Breathes, blinks, and adapts its eyes to its mood.
///
/// Nook is lit like a ball: a highlight top left, shade towards the edge and a little light bouncing back from below.
/// When he turns towards something the highlight slides the other way and his eyes narrow a little, so he reads as round.
///
/// While awake (`animated`) Nook also reacts to you: its eyes follow the pointer, it says hello when you come near,
/// squishes when clicked and giggles after three quick clicks, blushes when the pointer rests on him, hops when you send
/// something, nods when something is finished, reads along while you type, winks when something is done and shakes
/// when something failed. Each frame is one pose computed from the time and the shared moments in `NookPresence`.
/// With Reduce Motion on, only breathing and blinking remain.
struct NookOrb: View {
    var mood: NookMood
    var size: CGFloat = 46
    /// Disabled when idle: keeps Nook static and conserves processing power.
    var animated: Bool = true
    /// Noticed something it can help with: tilts its head and raises one eye, as if lifting an eyebrow.
    var curious: Bool = false
    /// Soft light around the orb. Off when docked in the notch, where the glow only smudges the black.
    var glow: Bool = true
    /// Frames per second while awake. The closed notch thinks along at a lower rate for hours on end (an agent working
    /// or waiting), where its slow breathing looks the same and costs a fraction of the redraws.
    var frameRate: Double = 30
    /// Draws this look instead of the one chosen in Settings: the previews in Settings › Appearance.
    var look: NookLook?
    /// Wears this instead of what Nook wears right now (`NookAppearance.outfit`): previews and moments.
    var outfit: [NookAccessory]?

    @ObservedObject private var presence = NookPresence.shared
    @ObservedObject private var appearance = NookAppearance.shared
    /// Published only when the plan changes: lets a dozing orb stop drawing while no one can see it.
    @ObservedObject private var energy = EnergyMonitor.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tracker = OrbTracker()
    @State private var moodSince = Date()

    var body: some View {
        // A dozing Nook keeps animating on every screen, so all orbs nod off together; its slow breathing and nodding
        // need only a few frames a second, and it can doze for hours. While you are away or the display sleeps (the
        // energy plan pauses) nobody sees it breathe, so it holds still instead of drawing all night.
        TimelineView(.animation(minimumInterval: animated ? 1.0 / max(1, frameRate) : 1.0 / Self.dozingFrameRate,
                                paused: !(animated || (dozing && energy.plan.pace != .paused)))) { context in
            orb(pose(at: context.date))
        }
        .frame(width: size, height: size)
        .background(PointerProbe(tracker: tracker))
        .onChange(of: mood) { _, _ in moodSince = Date() }
        .accessibilityHidden(true)
    }

    private static let dozingFrameRate: Double = 8

    /// The look this orb draws: eyes, mouth, gloss, glow and blush.
    var style: NookLook { look ?? appearance.look }

    /// Drowsiness is shared by every screen: the pointer being on one screen (`.seen`) must not keep the others awake.
    private var dozing: Bool { presence.drowsy && (mood == .rest || mood == .seen) }

    /// What Nook wears in this orb. His own hats come off while the headphones are on (the band runs over his head);
    /// a hat this orb is asked to wear (a preview, a party) takes the headphones' place instead.
    private var worn: [NookAccessory] {
        if let outfit { return outfit }
        return presence.listeningToMusic ? appearance.outfit.filter { $0.slot != .head } : appearance.outfit
    }

    private var wearsHeadphones: Bool {
        presence.listeningToMusic && !(outfit?.contains { $0.slot == .head } ?? false)
    }

    /// From the center to the middle of each eye, as the eye style places them; the glasses sit there.
    private var eyeReach: CGFloat {
        switch style.eyes {
        case .bars: return size * 0.145
        case .round: return size * 0.141
        case .dots: return size * 0.125
        }
    }

    private func orb(_ p: Pose) -> some View {
        // The light stays where it is while Nook turns: the highlight moves against his gaze.
        let light = UnitPoint(x: 0.34 - p.gaze.x * 0.09, y: 0.26 - p.gaze.y * 0.07)
        let shadeCenter = UnitPoint(x: light.x + 0.08, y: light.y + 0.1)
        let turn = min(abs(p.gaze.x), 1)
        let worn = self.worn
        return ZStack {
            let glowing = glow && style.glow
            Circle()
                .fill(mood.color)
                .frame(width: size, height: size)
                // Without glow the radius is 0 as well: an invisible shadow is still blurred every frame otherwise.
                .shadow(color: mood.color.opacity(glowing ? p.glowOpacity : 0), radius: glowing ? p.glowRadius : 0)
            if style.gloss { shading(light: light, shadeCenter: shadeCenter).frame(width: size, height: size) }
            eyes(p, turn: turn)
                .offset(y: -eyeLift)
            if style.cheeks, p.cheeks > 0.01 {
                HStack(spacing: size * 0.44) {
                    cheek
                    cheek
                }
                .offset(y: size * 0.14)
                .opacity(p.cheeks)
            }
            if style.mouth != .none { mouthLayer(p.mouth, gaze: p.gaze, turn: turn) }
        }
        .frame(width: size, height: size)
        // What he wears is drawn behind and over the orb, never in its stack: the accessory canvas is larger than the
        // orb (room for a party hat), and in the stack it made the orb and its shading grow to the canvas size.
        // Before the scale and tilt, so headphones and hats hop, squash and tilt with Nook.
        .background {
            if wearsHeadphones { NookHeadphones(size: size, gaze: p.gaze, layer: .back) }
            if !worn.isEmpty {
                NookAccessoryLayer(items: worn, size: size, gaze: p.gaze, eyeY: -eyeLift, eyeReach: eyeReach, layer: .back)
            }
        }
        .overlay {
            if !worn.isEmpty {
                NookAccessoryLayer(items: worn, size: size, gaze: p.gaze, eyeY: -eyeLift, eyeReach: eyeReach, layer: .front)
            }
            if wearsHeadphones { NookHeadphones(size: size, gaze: p.gaze, layer: .front) }
        }
        .scaleEffect(x: p.scale * p.stretch.width, y: p.scale * p.stretch.height)
        .rotationEffect(.degrees(p.rotation))
        .offset(p.offset)
        .overlay {
            if let progress = p.sparks { sparks(progress) }
        }
        .overlay(alignment: .topTrailing) {
            if p.drowsy {
                Text(verbatim: "z")
                    .font(NookTheme.rounded(max(7, size * 0.32), .bold))
                    .foregroundStyle(NookTheme.textTertiary)
                    .offset(x: size * 0.3, y: -size * 0.18)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: mood)
    }

    /// Ball lighting: shade towards the edge, a little light bouncing back from below, and the highlight.
    private func shading(light: UnitPoint, shadeCenter: UnitPoint) -> some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: .black.opacity(0), location: 0),
                        .init(color: .black.opacity(0.12), location: 0.42),
                        .init(color: .black.opacity(0.4), location: 0.78),
                        .init(color: .black.opacity(0.58), location: 1)
                    ]),
                    center: shadeCenter, startRadius: 0, endRadius: size * 0.66
                ))
            Circle()
                .fill(RadialGradient(
                    colors: [Color.white.opacity(0.26), Color.white.opacity(0)],
                    center: UnitPoint(x: 0.72, y: 0.86), startRadius: 0, endRadius: size * 0.3
                ))
            Circle()
                .fill(RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: .white.opacity(0.95), location: 0),
                        .init(color: .white.opacity(0.36), location: 0.33),
                        .init(color: .white.opacity(0), location: 1)
                    ]),
                    center: light, startRadius: 0, endRadius: size * 0.24
                ))
        }
    }

    /// With a mouth the eyes sit a little higher, so the face stays centered on the orb.
    private var eyeLift: CGFloat {
        style.mouth == .none ? 0 : size * (style.eyes == .bars ? 0.04 : 0.05)
    }

    @ViewBuilder
    private func eyes(_ p: Pose, turn: CGFloat) -> some View {
        if style.eyes == .bars {
            HStack(spacing: size * 0.18 * (1 - 0.18 * turn)) {
                eye(p.eyes[0], turn: turn)
                eye(p.eyes[1], turn: turn)
            }
        } else {
            roundEyes(p, turn: turn)
        }
    }

    /// The original bar-shaped eye.
    private func eye(_ e: EyePose, turn: CGFloat) -> some View {
        // A catchlight on larger eyes, gone when they close or smile.
        let shine = style.gloss && size >= 30 && !e.happy && e.height > size * 0.12 && e.squash > 0.4
        return eyeShape(happy: e.happy, width: e.width)
            .fill(LinearGradient(
                colors: [Color(hex: 0x1D1D25), NookTheme.eyeInk],
                startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.7)
            ))
            .overlay(alignment: .topLeading) {
                if shine {
                    Ellipse()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: e.width * 0.38, height: e.height * 0.16)
                        .offset(x: e.width * 0.2, y: e.height * 0.14)
                }
            }
            .frame(width: e.width, height: e.height)
            .scaleEffect(x: 1 - 0.28 * turn, y: e.squash)
            .rotationEffect(.degrees(e.rotation))
            .offset(x: e.dx, y: e.dy)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: mood)
    }

    private var cheek: some View {
        Ellipse()
            .fill(Color(hex: 0xFF8FA3))
            .frame(width: size * 0.17, height: size * 0.08)
            .blur(radius: max(1, size * 0.03))
    }

    private func eyeShape(happy: Bool, width: CGFloat) -> AnyShape {
        guard happy else { return AnyShape(Capsule()) }
        let r = width / 2
        return AnyShape(UnevenRoundedRectangle(
            topLeadingRadius: r,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: r
        ))
    }

    /// A small burst of mint and white sparks flying outward and fading.
    private func sparks(_ progress: Double) -> some View {
        let k = unit((progress - 0.05) / 0.7)
        let u = size / 72
        let dot = max(2.5, 5 * u)
        return ZStack {
            ForEach(0..<8, id: \.self) { i in
                let angle = Double(i) / 8 * 2 * Double.pi + 0.3
                let r = (38 + 34 * ease(k)) * Double(u)
                Circle()
                    .fill(i.isMultiple(of: 2) ? NookTheme.paper : NookTheme.mint)
                    .frame(width: dot, height: dot)
                    .scaleEffect(1 - 0.5 * k)
                    .offset(x: cos(angle) * r, y: sin(angle) * r)
                    .opacity(progress > 0.05 && k < 1 ? 1 - k : 0)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Pose

    struct EyePose {
        var width: CGFloat
        var height: CGFloat
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var squash: CGFloat = 1
        var rotation: Double = 0
        var happy = false
        /// Round and dot eyes squeeze into > < while giggling, 0…1.
        var giggle: CGFloat = 0
        /// Round and dot eyes: the outer side of the lid droops when worried, 0…1.
        var lid: CGFloat = 0
        /// -1 for the left eye, 1 for the right one.
        var side: CGFloat = -1
    }

    /// The mouth, as fractions of the orb: width, how far it is open, curve (1 smiles, -1 frowns), roundness (1 is an
    /// "o"), a sideways shift, and teeth showing (f, v).
    struct MouthPose {
        var width: CGFloat = 0.19
        var open: CGFloat = 0
        var curve: CGFloat = 0.55
        var round: CGFloat = 0
        var shift: CGFloat = 0
        var teeth = false
    }

    struct Pose {
        var eyes: [EyePose]
        var mouth = MouthPose()
        var scale: CGFloat = 1
        var stretch = CGSize(width: 1, height: 1)
        var rotation: Double = 0
        var offset = CGSize.zero
        var glowRadius: CGFloat = 0
        var glowOpacity: Double = 0.55
        /// Progress of the celebration burst in seconds, nil when there is none.
        var sparks: Double?
        var drowsy = false
        /// Where the eyes look, -1…1 on both axes; moves the highlight and narrows the eyes.
        var gaze = CGPoint.zero
        /// Blush, 0…1.
        var cheeks: Double = 0

        mutating func eachEye(_ change: (inout EyePose) -> Void) {
            for i in eyes.indices { change(&eyes[i]) }
        }

        /// Blends the eyes towards happy arcs (^ ^) of the given size; k = 1 is fully happy.
        mutating func happy(_ k: Double, to target: CGSize) {
            guard k > 0 else { return }
            let amount = CGFloat(min(k, 1))
            eachEye { e in
                e.width += (target.width - e.width) * amount
                e.height += (target.height - e.height) * amount
                e.happy = amount > 0.5
            }
        }
    }

    private func pose(at date: Date) -> Pose {
        let t = date.timeIntervalSinceReferenceDate
        let u = size / 72   // the motions were designed on a 72-point orb
        let dt = tracker.advance(to: t)
        let lively = animated && !reduceMotion
        let drowsy = dozing || mood == .sleepy
        let since = { (moment: Date) -> Double in date.timeIntervalSince(moment) }

        // Breathing: faster and shallower while thinking, slow when drowsy.
        let isThinking = mood == .think
        let breathRate = isThinking ? 1.4 : (drowsy ? 6.0 : 3.4)
        let breathAmp = isThinking ? 0.025 : 0.05
        var p = Pose(eyes: [baseEye(index: 0, t: t, lively: lively), baseEye(index: 1, t: t, lively: lively)])
        p.scale = CGFloat(1 + breathAmp * sin(t * 2 * Double.pi / breathRate))
        if isThinking {
            let glowWave = (1.0 + sin(t * 2 * Double.pi / 1.4)) / 2.0
            p.glowRadius = size * (0.40 + 0.08 * glowWave)
            p.glowOpacity = 0.50 + 0.14 * glowWave
        } else {
            p.glowRadius = size * 0.42
        }

        if drowsy {
            // Eyes half shut; awake, it nods off now and then and catches itself.
            let c = t.truncatingRemainder(dividingBy: 9)
            let nod = reduceMotion ? 0 : bump((c - 4.2) / 1.6)
            let jerk = reduceMotion ? 0 : bump((c - 7) / 0.4)
            p.eachEye { e in
                e.squash *= CGFloat(max(0.08, 0.35 - 0.25 * nod + 0.15 * jerk))
                e.dy += 2 * u
            }
            p.offset.height += CGFloat(4 * nod - 3 * jerk) * u
            p.rotation -= 5 * nod
            p.glowOpacity *= 0.7
            p.drowsy = true
        }

        p.mouth = moodMouth(drowsy: drowsy)
        guard lively else {
            tracker.mouth = p.mouth
            return p
        }

        // Woken after a long rest: wide eyes and a little jump.
        let woke = since(presence.wokeAt)
        if woke < 1.6 {
            let k = bump(woke / 0.5)
            p.eachEye { $0.height *= CGFloat(1 + 0.3 * k) }
            p.offset.height -= 5 * u * CGFloat(k)
        }

        // Hello: a small hop with happy eyes.
        let hello = since(presence.greetedAt)
        if hello < 1.2 {
            let hop = bump(hello / 0.45)
            p.offset.height += CGFloat(-9 * hop + 2 * bump((hello - 0.45) / 0.25)) * u
            p.stretch.width *= CGFloat(1 - 0.03 * hop)
            p.stretch.height *= CGFloat(1 + 0.05 * hop)
            p.happy(hello < 0.15 ? ease(hello / 0.15) : 1 - ease((hello - 0.75) / 0.2), to: eyeSize(for: .done))
        }

        // Clicked: squash, then spring back with the eyes briefly squeezed shut.
        let poke = since(presence.pokedAt)
        if poke >= 0, poke < 1.2 {
            let wobble = 0.2 * exp(-5.5 * poke) * cos(poke * 19)
            p.stretch.width *= CGFloat(1 + wobble)
            p.stretch.height *= CGFloat(1 - wobble)
            p.offset.height += CGFloat(wobble * 10) * u
            if poke < 0.28 { p.eachEye { $0.squash *= CGFloat(1 - 0.65 * bump(poke / 0.28)) } }
        }

        // You sent something: squash, hop up with wide eyes, land.
        let heard = since(presence.heardAt)
        if heard >= 0, heard < 0.9 {
            let squash = bump(heard / 0.18)
            let up = bump((heard - 0.12) / 0.45)
            p.stretch.width *= CGFloat(1 + 0.08 * squash - 0.04 * up)
            p.stretch.height *= CGFloat(1 - 0.1 * squash + 0.07 * up)
            p.offset.height += CGFloat(3 * squash - 12 * up) * u
            p.eachEye { $0.height *= CGFloat(1 + 0.25 * up) }
        }

        // Tickled by three quick clicks: squeezed eyes, blush, wobbling from side to side.
        let giggle = since(presence.giggledAt)
        if giggle >= 0, giggle < 1.8 {
            let k = 1 - ease((giggle - 1.4) / 0.4)
            p.rotation += 10 * sin(giggle * 18) * k
            p.offset.height -= CGFloat(abs(sin(giggle * 18)) * 4 * k) * u
            for i in p.eyes.indices {
                p.eyes[i].happy = false
                p.eyes[i].squash = 1
                guard style.eyes == .bars else {
                    p.eyes[i].giggle = CGFloat(k)
                    continue
                }
                p.eyes[i].width += (size * 0.17 - p.eyes[i].width) * CGFloat(k)
                p.eyes[i].height += (size * 0.045 - p.eyes[i].height) * CGFloat(k)
                p.eyes[i].rotation = (i == 0 ? 22 : -22) * k
            }
            p.cheeks = max(p.cheeks, 0.75 * k)
        }

        // Something finished: a content nod.
        let nod = since(presence.noddedAt)
        if nod >= 0, nod < 1.1 {
            let k = bump(nod / 0.5)
            p.offset.height += CGFloat(5 * k) * u
            p.rotation -= 6 * k
            p.happy(bump(nod / 1.1) * 1.4, to: eyeSize(for: .done))
        }

        let inMood = since(moodSince)
        switch mood {
        case .done where inMood < 1.3:
            // A wink with one eye and a little tilt, then settle into the content arcs.
            let wink = bump((inMood - 0.35) / 0.45)
            let open = eyeSize(for: .rest)
            p.eachEye { e in
                e.width = open.width
                e.height = open.height
                e.happy = false
            }
            p.eyes[0].squash = CGFloat(1 - 0.92 * wink)
            p.eyes[0].dy += 2 * u * CGFloat(wink)
            p.rotation -= 7 * wink
            p.offset.height -= 2 * u * CGFloat(wink)
            p.happy(ease((inMood - 1.05) / 0.25), to: eyeSize(for: .done))
        case .worry:
            // A quick shake of the head, eyes slanted with concern.
            if inMood < 1 { p.offset.width += 6 * u * CGFloat(sin(inMood * 34) * exp(-5 * inMood)) }
            let k = ease(inMood / 0.2)
            if style.eyes == .bars {
                p.eyes[0].rotation += 14 * k
                p.eyes[1].rotation -= 14 * k
            } else {
                p.eachEye { $0.lid = CGFloat(k) }
            }
            p.eachEye { $0.dy += 1.5 * u * CGFloat(k) }
            p.offset.height += 1.5 * u * CGFloat(k)
        case .waiting:
            // Glances at what waits on the right and taps twice, like a tap on the shoulder.
            let c = t.truncatingRemainder(dividingBy: 3.6)
            let look = ease(c / 0.25) * (1 - ease((c - 1.4) / 0.3))
            p.eachEye { $0.dx += self.size * 0.09 * CGFloat(look) }
            p.offset.width += 3 * u * CGFloat(look)
            p.offset.height -= 4 * u * CGFloat(bump((c - 0.35) / 0.2) + bump((c - 0.65) / 0.2))
        case .listen:
            // Eyes and glow move with the loudness of your voice.
            tracker.voice = OrbTracker.approach(tracker.voice, CGFloat(VoiceLevel.shared.current), rate: 14, dt: dt)
            let v = tracker.voice
            p.eachEye { $0.height *= 0.82 + 0.42 * v }
            p.glowRadius *= 1 + 0.9 * v
            p.glowOpacity = min(0.9, p.glowOpacity * (1 + 0.6 * Double(v)))
            p.scale += 0.045 * v
        case .proud:
            // Chin up, a little bounce now and then, and a few sparks when it starts.
            let hop = bump(t.truncatingRemainder(dividingBy: 2.4) / 0.4)
            p.offset.height -= CGFloat(1.5 + 4 * hop) * u
            p.stretch.height *= CGFloat(1 + 0.03 * hop)
            p.eachEye { $0.dy -= self.size * 0.025 }
            p.cheeks = max(p.cheeks, 0.35)
            if inMood < 1 { p.sparks = inMood }
        case .celebrate:
            // Hops with squash and stretch, and a burst of sparks every other hop.
            let c = t.truncatingRemainder(dividingBy: 1.1)
            let squash = bump(c / 0.14)
            let up = bump((c - 0.1) / 0.5)
            p.stretch.width *= CGFloat(1 + 0.07 * squash - 0.04 * up)
            p.stretch.height *= CGFloat(1 - 0.08 * squash + 0.06 * up)
            p.offset.height += CGFloat(2 * squash - 9 * up) * u
            p.cheeks = max(p.cheeks, 0.55)
            let burst = t.truncatingRemainder(dividingBy: 2.2)
            if burst < 1 { p.sparks = burst }
        case .cozy:
            // Snug: soft eyes, a warm blush and a slow sway.
            p.rotation += 4 * sin(t * 1.3)
            p.cheeks = max(p.cheeks, 0.6)
            p.eachEye { $0.height *= 0.8 }
        case .focus:
            // Narrow, steady eyes and a slight lean forward.
            p.eachEye { $0.height *= 0.85 }
            p.offset.height += 1.5 * u
        case .surprised:
            // A start: a jump with wide eyes, then still a little wide-eyed.
            let jump = bump(inMood / 0.5)
            p.offset.height -= CGFloat(8 * jump) * u
            p.stretch.height *= CGFloat(1 + 0.06 * jump)
            p.eachEye { $0.height *= CGFloat(1 + 0.25 * jump) }
        case .caring:
            // Soft, sympathetic eyes and a tilt of the head, as if listening.
            let k = ease(inMood / 0.4)
            if style.eyes == .bars {
                p.eyes[0].rotation -= 9 * k
                p.eyes[1].rotation += 9 * k
            } else {
                p.eachEye { $0.lid = CGFloat(0.45 * k) }
            }
            p.rotation += 6 * k
            p.cheeks = max(p.cheeks, 0.25 * k)
        case .breathe:
            // 4 seconds in, 4 holding, 6 out: he swells and shrinks so you can follow along.
            let c = inMood.truncatingRemainder(dividingBy: 14)
            let k = c < 4 ? ease(c / 4) : (c < 8 ? 1 : 1 - ease((c - 8) / 6))
            p.scale = CGFloat(0.94 + 0.16 * k)
            p.glowRadius = size * CGFloat(0.3 + 0.35 * k)
            p.glowOpacity = 0.35 + 0.35 * k
        default:
            break
        }

        if curious || mood == .curious {
            let c = t.truncatingRemainder(dividingBy: 4.4)
            let k = ease(c / 0.5) * (1 - ease((c - 3.2) / 0.5))
            p.rotation += 11 * k
            p.eyes[1].height *= CGFloat(1 + 0.18 * k)
            p.eyes[0].height *= CGFloat(1 - 0.08 * k)
            p.eachEye { e in
                e.dx += self.size * 0.045 * CGFloat(k)
                e.dy -= self.size * 0.03 * CGFloat(k)
            }
            p.offset.width += 3 * u * CGFloat(k)
        }

        // Reading along while you type: eyes down, following the text; a small nod when you stop.
        let typed = since(presence.typedAt)
        let canRead = mood != .think && mood != .done && !mood.eyesShut && !drowsy
        tracker.reading = OrbTracker.approach(tracker.reading, canRead && typed < 0.9 ? 1 : 0, rate: 9, dt: dt)
        let reading = tracker.reading
        if reading > 0.01 || (canRead && typed < 1.6) {
            let progress = CGFloat(presence.typedCount % 28) / 28 * 2 - 1
            p.eachEye { e in
                e.dy += reading * self.size * 0.08
                e.dx += reading * progress * self.size * 0.06
                e.height *= 1 - 0.2 * reading
            }
            p.offset.height += (reading * 3 + 4 * CGFloat(bump((typed - 1) / 0.5))) * u
            p.rotation += Double(reading * progress * 3)
        }

        // Petted: the pointer rests on Nook (the big one in the panel). Blush, happy eyes, leaning into it.
        let pointer = tracker.pointerOffset()
        let onOrb = size >= 30 && pointer.map { hypot($0.x, $0.y) < size / 2 } ?? false
        tracker.notePointer(pointer, at: date.timeIntervalSinceReferenceDate)
        let petting = onOrb && tracker.stillFor(at: date.timeIntervalSinceReferenceDate) > 0.7 && since(presence.pokedAt) > 0.8 && !drowsy
        tracker.pet = OrbTracker.approach(tracker.pet, petting ? 1 : 0, rate: 5, dt: dt)
        let pet = tracker.pet
        if pet > 0.01 {
            p.happy(Double(pet), to: eyeSize(for: .done))
            p.cheeks = max(p.cheeks, 0.7 * Double(pet))
            p.rotation += sin(t * 2.2) * 6 * Double(pet)
            p.stretch.width *= 1 + 0.04 * pet
            p.stretch.height *= 1 - 0.035 * pet
        }

        // Looking at a piece of the task ring under the pointer, else following the pointer when it is near.
        var target = CGPoint.zero
        let track = since(presence.trackChangedAt)
        if track >= 0, track < 4 {
            // A new track: glance at the cover beside him, then back.
            let k = ease(track / 0.25) * (1 - ease((track - 3.4) / 0.4))
            target = CGPoint(x: 0.95 * k, y: 0.1 * k)
        } else if size >= 30, let angle = presence.lookAngle {
            target = CGPoint(x: cos(angle) * 0.95, y: sin(angle) * 0.95)
        } else if mood != .think, mood != .done, !mood.eyesShut, !drowsy, reading < 0.5, !onOrb, let pointer {
            let distance = hypot(pointer.x, pointer.y)
            if distance > 1, distance < max(260, size * 6) {
                let reach = min(distance / (size * 1.6), 1)
                target = CGPoint(x: pointer.x / distance * reach, y: pointer.y / distance * reach)
            }
        }
        tracker.gaze.x = OrbTracker.approach(tracker.gaze.x, target.x, rate: 8, dt: dt)
        tracker.gaze.y = OrbTracker.approach(tracker.gaze.y, target.y, rate: 8, dt: dt)
        let gaze = tracker.gaze
        p.eachEye { e in
            e.dx += gaze.x * self.size * 0.09
            e.dy += gaze.y * self.size * 0.07
        }
        p.offset.width += gaze.x * 3 * u
        p.offset.height += gaze.y * 2 * u
        p.gaze = gaze

        // Something bigger finished: a little jump and sparks.
        let party = since(presence.celebratedAt)
        if party >= 0, party < 1 {
            p.scale += CGFloat(0.14 * exp(-6 * party) * cos(party * 14))
            p.offset.height -= 6 * u * CGFloat(bump(party / 0.35))
            p.glowOpacity = min(0.9, p.glowOpacity * (1 + 0.8 * exp(-4 * party)))
            p.sparks = party
        }

        // The mouth: the mood's shape, changed by what just happened, and moving along while Nook reads aloud.
        var mouth = p.mouth
        if hello < 1.2 { mouth = MouthPose(width: 0.22, open: 0.08, curve: 0.9) }
        if pet > 0.5 { mouth = MouthPose(width: 0.2, open: 0.04, curve: 0.9) }
        if poke >= 0, poke < 0.45 { mouth = MouthPose(width: 0.08, open: 0.07, curve: 0, round: 1) }
        if giggle >= 0, giggle < 1.6 { mouth = MouthPose(width: 0.2, open: 0.09 + 0.04 * abs(CGFloat(sin(giggle * 18))), curve: 1) }
        var speaking = false
        if style.mouth == .expressive, let word = presence.spokenWord, since(presence.spokenWordAt) < 3 {
            let viseme = NookViseme.during(word, elapsed: since(presence.spokenWordAt)) ?? .rest
            let shape = viseme.shape
            mouth = MouthPose(width: shape.width, open: shape.open, curve: max(-0.4, mouth.curve * 0.6), round: shape.round,
                              teeth: viseme == .teeth)
            speaking = true
            // The head lifts a little on open vowels.
            p.offset.height -= CGFloat(shape.open) * size * 0.12
        }
        p.mouth = tracker.smoothMouth(mouth, rate: speaking ? 26 : 10, dt: dt)

        return p
    }

    private func moodMouth(drowsy: Bool) -> MouthPose {
        if drowsy { return MouthPose(width: 0.06, open: 0.04, curve: 0, round: 1) }
        switch mood {
        case .rest: return MouthPose()
        case .seen: return MouthPose(width: 0.07, open: 0.07, curve: 0, round: 1)
        case .listen: return MouthPose(width: 0.09, open: 0.045, curve: 0.2, round: 0.8)
        case .think: return MouthPose(width: 0.09, open: 0, curve: -0.15, shift: 0.05)
        case .waiting: return MouthPose(width: 0.13, open: 0, curve: 0.08)
        case .remind: return MouthPose(width: 0.17, open: 0.045, curve: 0.6)
        case .worry: return MouthPose(width: 0.15, open: 0.02, curve: -0.7)
        case .done: return MouthPose(width: 0.25, open: 0.12, curve: 1)
        case .proud: return MouthPose(width: 0.24, open: 0.06, curve: 1)
        case .curious: return MouthPose(width: 0.07, open: 0.06, curve: 0, round: 1)
        case .cozy: return MouthPose(width: 0.16, open: 0.02, curve: 0.8)
        case .focus: return MouthPose(width: 0.1, open: 0, curve: 0.05)
        case .surprised: return MouthPose(width: 0.09, open: 0.11, curve: 0, round: 1)
        case .caring: return MouthPose(width: 0.14, open: 0, curve: 0.35)
        case .sleepy: return MouthPose(width: 0.06, open: 0.04, curve: 0, round: 1)
        case .celebrate: return MouthPose(width: 0.26, open: 0.14, curve: 1)
        case .breathe: return MouthPose(width: 0.08, open: 0.02, curve: 0.3, round: 0.6)
        }
    }

    // MARK: Eyes

    private func eyeSize(for mood: NookMood) -> CGSize {
        switch style.eyes {
        case .bars: return barEyeSize(for: mood)
        case .round:
            switch mood {
            case .seen: return CGSize(width: size * 0.165, height: size * 0.195)
            case .listen: return CGSize(width: size * 0.155, height: size * 0.205)
            case .think: return CGSize(width: size * 0.13, height: size * 0.13)
            case .done, .proud, .celebrate, .cozy: return CGSize(width: size * 0.17, height: size * 0.10)
            case .focus: return CGSize(width: size * 0.165, height: size * 0.12)
            case .surprised: return CGSize(width: size * 0.185, height: size * 0.235)
            default: return CGSize(width: size * 0.162, height: size * 0.186)
            }
        case .dots:
            switch mood {
            case .seen: return CGSize(width: size * 0.12, height: size * 0.12)
            case .listen: return CGSize(width: size * 0.10, height: size * 0.125)
            case .think: return CGSize(width: size * 0.085, height: size * 0.085)
            case .done, .proud, .celebrate, .cozy: return CGSize(width: size * 0.15, height: size * 0.08)
            case .focus: return CGSize(width: size * 0.11, height: size * 0.07)
            case .surprised: return CGSize(width: size * 0.135, height: size * 0.135)
            default: return CGSize(width: size * 0.10, height: size * 0.10)
            }
        }
    }

    /// The original tall capsules.
    private func barEyeSize(for mood: NookMood) -> CGSize {
        switch mood {
        case .rest, .seen, .remind, .curious, .caring, .sleepy, .breathe:
            return CGSize(width: size * 0.11, height: size * 0.30)
        case .listen:
            return CGSize(width: size * 0.11, height: size * 0.40)
        case .waiting, .worry:
            return CGSize(width: size * 0.13, height: size * 0.34)
        case .think:
            return CGSize(width: size * 0.125, height: size * 0.125)
        case .done, .proud, .celebrate, .cozy:
            return CGSize(width: size * 0.20, height: size * 0.09)
        case .focus:
            return CGSize(width: size * 0.12, height: size * 0.17)
        case .surprised:
            return CGSize(width: size * 0.13, height: size * 0.40)
        }
    }

    private func baseEye(index: Int, t: Double, lively: Bool) -> EyePose {
        let s = eyeSize(for: mood)
        let offset = thinkingOffset(index: index, t: t)
        // Shut eyes (asleep, breathing) draw as a soft closed curve.
        var eye = EyePose(width: s.width, height: s.height, dx: offset.width, dy: offset.height,
                          squash: mood.eyesShut ? 0.15 : blinkScale(t), side: index == 0 ? -1 : 1)
        eye.happy = mood.smiles
        if lively { eye.dx += glance(t) }
        return eye
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

    // MARK: Blinking

    /// Seconds between blinks. Irregular, like a living thing; the pattern repeats only after a minute.
    private static let blinkGaps: [Double] = [3.2, 5.8, 2.6, 6.6, 4.1, 3.5, 7.0, 2.9, 5.2, 4.4, 3.8, 6.1]
    private static let blinkStarts: [Double] = blinkGaps.reduce(into: [0]) { starts, gap in starts.append(starts[starts.count - 1] + gap) }
    /// Intervals that open with two quick blinks.
    private static let doubleBlinks: Set<Int> = [2, 7, 10]
    /// A small sideways eye movement after each blink, as a fraction of the orb size.
    private static let glances: [Double] = [0, 0.025, -0.015, 0.03, 0, -0.03, 0.012, -0.02, 0.02, 0, -0.012, 0.028]

    private static func blinkSlot(_ t: Double) -> (index: Int, phase: Double) {
        let cycle = blinkStarts[blinkStarts.count - 1]
        let p = t.truncatingRemainder(dividingBy: cycle)
        let found = blinkStarts.lastIndex(where: { $0 <= p }) ?? 0
        let i = min(found, blinkGaps.count - 1)
        return (i, p - blinkStarts[i])
    }

    /// Blinks at irregular moments, sometimes twice; not when content or thinking.
    private func blinkScale(_ t: Double) -> CGFloat {
        if mood == .think || mood.smiles || mood.eyesShut { return 1 }
        let (index, phase) = Self.blinkSlot(t)
        func closed(_ d: Double) -> Double {
            guard d >= 0, d < 0.24 else { return 1 }
            return 1 - 0.92 * sin(d / 0.24 * Double.pi)
        }
        var value = closed(phase)
        if Self.doubleBlinks.contains(index) { value = min(value, closed(phase - 0.32)) }
        return CGFloat(value)
    }

    /// The eyes shift a little right after each blink and stay there until the next one.
    private func glance(_ t: Double) -> CGFloat {
        let (index, phase) = Self.blinkSlot(t)
        let previous = (index + Self.glances.count - 1) % Self.glances.count
        let k = ease(phase / 0.1)
        return size * CGFloat(Self.glances[index] * k + Self.glances[previous] * (1 - k))
    }
}

// MARK: Easing

private func unit(_ v: Double) -> Double { min(max(v, 0), 1) }
/// 0 → 1 with zero velocity at both ends.
private func ease(_ p: Double) -> Double { (1 - cos(unit(p) * Double.pi)) / 2 }
/// 0 → 1 → 0 over p in 0…1; zero outside.
private func bump(_ p: Double) -> Double { p <= 0 || p >= 1 ? 0 : sin(p * Double.pi) }

// MARK: Pointer

/// Per-orb motion that carries over between frames: smoothed gaze, reading and voice level.
@MainActor
private final class OrbTracker {
    weak var view: NSView?
    var gaze = CGPoint.zero
    var reading: CGFloat = 0
    var voice: CGFloat = 0
    var pet: CGFloat = 0
    /// The mouth as last drawn, eased towards each new shape; nil until the first frame.
    var mouth: NookOrb.MouthPose?
    private var lastTime: TimeInterval = 0
    private var lastPointer: CGPoint?
    private var stillSince: TimeInterval = 0

    /// Remembers when the pointer last moved more than a hair, to tell resting from passing by.
    func notePointer(_ point: CGPoint?, at t: TimeInterval) {
        guard let point else { lastPointer = nil; return }
        if let last = lastPointer, hypot(point.x - last.x, point.y - last.y) < 2 { return }
        lastPointer = point
        stillSince = t
    }

    /// Seconds the pointer has rested in the same spot.
    func stillFor(at t: TimeInterval) -> TimeInterval {
        lastPointer == nil ? 0 : t - stillSince
    }

    /// Seconds since the previous frame, capped so a paused orb does not jump when it wakes.
    func advance(to t: TimeInterval) -> CGFloat {
        defer { lastTime = t }
        guard lastTime > 0 else { return 1.0 / 60 }
        return CGFloat(min(max(t - lastTime, 0), 0.1))
    }

    /// Eases the mouth towards `target`: quickly while talking, more softly between moods.
    func smoothMouth(_ target: NookOrb.MouthPose, rate: CGFloat, dt: CGFloat) -> NookOrb.MouthPose {
        guard var m = mouth else {
            mouth = target
            return target
        }
        m.width = Self.approach(m.width, target.width, rate: rate, dt: dt)
        m.open = Self.approach(m.open, target.open, rate: rate, dt: dt)
        m.curve = Self.approach(m.curve, target.curve, rate: rate, dt: dt)
        m.round = Self.approach(m.round, target.round, rate: rate, dt: dt)
        m.shift = Self.approach(m.shift, target.shift, rate: rate, dt: dt)
        m.teeth = target.teeth
        mouth = m
        return m
    }

    /// Moves towards `target` at the same speed whatever the frame rate.
    static func approach(_ value: CGFloat, _ target: CGFloat, rate: CGFloat, dt: CGFloat) -> CGFloat {
        value + (target - value) * (1 - exp(-rate * dt))
    }

    /// The pointer relative to the orb's center, in points, y pointing down.
    func pointerOffset() -> CGPoint? {
        guard let view, let window = view.window else { return nil }
        let p = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let b = view.bounds
        return CGPoint(x: p.x - b.midX, y: view.isFlipped ? p.y - b.midY : b.midY - p.y)
    }
}

/// An invisible view behind the orb that tells it where it is on screen. It never takes clicks.
private struct PointerProbe: NSViewRepresentable {
    let tracker: OrbTracker

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        tracker.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        tracker.view = nsView
    }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
