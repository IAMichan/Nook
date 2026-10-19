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

    @ObservedObject private var presence = NookPresence.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tracker = OrbTracker()
    @State private var moodSince = Date()

    var body: some View {
        // A dozing Nook keeps animating on every screen, so all orbs nod off together.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !(animated || dozing))) { context in
            orb(pose(at: context.date))
        }
        .frame(width: size, height: size)
        .background(PointerProbe(tracker: tracker))
        .onChange(of: mood) { _, _ in moodSince = Date() }
        .accessibilityHidden(true)
    }

    /// Drowsiness is shared by every screen: the pointer being on one screen (`.seen`) must not keep the others awake.
    private var dozing: Bool { presence.drowsy && (mood == .rest || mood == .seen) }

    private func orb(_ p: Pose) -> some View {
        // The light stays where it is while Nook turns: the highlight moves against his gaze.
        let light = UnitPoint(x: 0.34 - p.gaze.x * 0.09, y: 0.26 - p.gaze.y * 0.07)
        let shadeCenter = UnitPoint(x: light.x + 0.08, y: light.y + 0.1)
        let turn = min(abs(p.gaze.x), 1)
        return ZStack {
            Circle()
                .fill(mood.color)
                .shadow(color: mood.color.opacity(glow ? p.glowOpacity : 0), radius: p.glowRadius)
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
            HStack(spacing: size * 0.18 * (1 - 0.18 * turn)) {
                eye(p.eyes[0], turn: turn)
                eye(p.eyes[1], turn: turn)
            }
            if p.cheeks > 0.01 {
                HStack(spacing: size * 0.44) {
                    cheek
                    cheek
                }
                .offset(y: size * 0.14)
                .opacity(p.cheeks)
            }
            // Inside the orb's stack, so the headphones hop, squash and tilt with Nook.
            if presence.listeningToMusic { headphones(gaze: p.gaze) }
        }
        .frame(width: size, height: size)
        .scaleEffect(x: p.scale * p.stretch.width, y: p.scale * p.stretch.height)
        .rotationEffect(.degrees(p.rotation))
        .offset(p.offset)
        .overlay {
            if let progress = p.sparks { sparks(progress) }
        }
        .overlay(alignment: .topTrailing) {
            if p.drowsy {
                Text(verbatim: "z")
                    .font(.system(size: max(7, size * 0.32), weight: .bold, design: .rounded))
                    .foregroundStyle(NookTheme.textTertiary)
                    .offset(x: size * 0.3, y: -size * 0.18)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: mood)
    }

    private func eye(_ e: EyePose, turn: CGFloat) -> some View {
        // A catchlight on larger eyes, gone when they close or smile.
        let shine = size >= 30 && !e.happy && e.height > size * 0.12 && e.squash > 0.4
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

    /// Headphones while music plays: a band over the top and an ear cup on each side.
    ///
    /// They turn with Nook's head: looking right, the band narrows and slides along, the left cup comes round towards
    /// you (wider) and the right cup turns away (narrower); looking down, the band tips forward a little.
    private func headphones(gaze: CGPoint) -> some View {
        let band = max(1.5, size * 0.07)
        let cupWidth = size * 0.17
        let cupHeight = size * 0.34
        let angle = Double(max(-1, min(gaze.x, 1))) * 0.5   // head turn in radians
        let across = CGFloat(cos(angle))
        let side = CGFloat(sin(angle))
        let reach = size * 0.455   // distance from the center to each cup
        return ZStack {
            Circle()
                .trim(from: 0.5, to: 1)
                .stroke(Color(hex: 0x4A4A58), style: StrokeStyle(lineWidth: band, lineCap: .round))
                .frame(width: size * 1.02, height: size * 1.02)
                .scaleEffect(x: across, y: 1 - 0.06 * abs(gaze.y))
                .offset(x: side * size * 0.06, y: size * 0.01 + gaze.y * size * 0.03)
            cup(width: cupWidth * (1 + 0.3 * side), height: cupHeight)
                .offset(x: -reach * across + side * size * 0.04, y: gaze.y * size * 0.02)
            cup(width: cupWidth * (1 - 0.3 * side), height: cupHeight)
                .offset(x: reach * across + side * size * 0.04, y: gaze.y * size * 0.02)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }

    private func cup(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: width * 0.5, style: .continuous)
            .fill(Color(hex: 0x4A4A58))
            .overlay(
                RoundedRectangle(cornerRadius: width * 0.5, style: .continuous)
                    .stroke(Color.white.opacity(0.35), lineWidth: 0.6)
            )
            .frame(width: width, height: height)
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

    private struct EyePose {
        var width: CGFloat
        var height: CGFloat
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var squash: CGFloat = 1
        var rotation: Double = 0
        var happy = false
    }

    private struct Pose {
        var eyes: [EyePose]
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

        /// Blends the eyes towards happy arcs (^ ^); k = 1 is fully happy.
        mutating func happy(_ k: Double, size: CGFloat) {
            guard k > 0 else { return }
            let amount = CGFloat(min(k, 1))
            eachEye { e in
                e.width += (size * 0.20 - e.width) * amount
                e.height += (size * 0.09 - e.height) * amount
                e.happy = amount > 0.5
            }
        }
    }

    private func pose(at date: Date) -> Pose {
        let t = date.timeIntervalSinceReferenceDate
        let u = size / 72   // the motions were designed on a 72-point orb
        let dt = tracker.advance(to: t)
        let lively = animated && !reduceMotion
        let drowsy = dozing
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

        guard lively else { return p }

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
            p.happy(hello < 0.15 ? ease(hello / 0.15) : 1 - ease((hello - 0.75) / 0.2), size: size)
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
                p.eyes[i].width += (size * 0.17 - p.eyes[i].width) * CGFloat(k)
                p.eyes[i].height += (size * 0.045 - p.eyes[i].height) * CGFloat(k)
                p.eyes[i].happy = false
                p.eyes[i].rotation = (i == 0 ? 22 : -22) * k
                p.eyes[i].squash = 1
            }
            p.cheeks = max(p.cheeks, 0.75 * k)
        }

        // Something finished: a content nod.
        let nod = since(presence.noddedAt)
        if nod >= 0, nod < 1.1 {
            let k = bump(nod / 0.5)
            p.offset.height += CGFloat(5 * k) * u
            p.rotation -= 6 * k
            p.happy(bump(nod / 1.1) * 1.4, size: size)
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
            p.happy(ease((inMood - 1.05) / 0.25), size: size)
        case .worry:
            // A quick shake of the head, eyes slanted with concern.
            if inMood < 1 { p.offset.width += 6 * u * CGFloat(sin(inMood * 34) * exp(-5 * inMood)) }
            let k = ease(inMood / 0.2)
            p.eyes[0].rotation += 14 * k
            p.eyes[1].rotation -= 14 * k
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
        default:
            break
        }

        if curious {
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
        let canRead = mood != .think && mood != .done
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
            p.happy(Double(pet), size: size)
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
        } else if mood != .think, mood != .done, reading < 0.5, !onOrb, let pointer {
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

        return p
    }

    // MARK: Eyes

    private func eyeSize(for mood: NookMood) -> CGSize {
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

    private func baseEye(index: Int, t: Double, lively: Bool) -> EyePose {
        let s = eyeSize(for: mood)
        let offset = thinkingOffset(index: index, t: t)
        var eye = EyePose(width: s.width, height: s.height, dx: offset.width, dy: offset.height, squash: blinkScale(t))
        eye.happy = mood == .done
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
        if mood == .done || mood == .think { return 1 }
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
