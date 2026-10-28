import SwiftUI

/// One piece of the ring around Nook: an agent session or a Nook that works for you.
struct TaskRingItem: Identifiable, Equatable {
    enum Kind: Equatable { case running, waiting, failed, done }
    enum Target: Equatable { case agent(String), nook(UUID) }

    let id: String
    let title: String
    let detail: String
    let state: Kind
    let target: Target

    var color: Color {
        switch state {
        case .running: return NookTheme.iris
        case .waiting: return NookTheme.amber
        case .failed: return NookTheme.coral
        case .done: return NookTheme.mint
        }
    }
}

/// The ring around Nook: one piece for everything he and your agents are working on. The same component, with the same
/// pieces and colors, circles him in the open panel and in the closed notch; only its size and what it reacts to differ.
///
/// Running work is a faint piece with a light running through it, something that waits for you pulses amber, a failure
/// is coral and what is finished is mint. In the panel it draws itself in, piece by piece, when it appears; point at a
/// piece and Nook looks at it, with its name beside the ring; click it to go there. In the closed notch it is thin and
/// close around Nook and only shows: a click on the notch opens the panel.
///
/// Given Nook's `motion`, the ring follows him like elastic, closed or open: when he hops, nods or leans towards you
/// it trails behind on a spring, stretches towards him while he pulls away and overshoots a little before it settles.
struct NookTaskRing: View {
    enum Style { case panel, compact }

    let items: [TaskRingItem]
    var style: Style = .panel
    /// Size of Nook inside the ring.
    var orbSize: CGFloat = 46
    /// The room the ring may take; the closed notch is not much taller than Nook.
    var maxSide: CGFloat = .infinity
    /// The piece Nook looks at (`pointer.hovered`, passed as a value so the ring redraws when it changes).
    var hovered: String?
    /// Where the pointer is, shared with `NookTaskRingLabel`; nil where the ring only shows.
    var pointer: TaskRingPointer?
    let onOpen: (TaskRingItem) -> Void
    /// Where Nook is pushed from his place, written by his `NookOrb`. Only the drawing observes it: observed here, every
    /// move of Nook would update the notch or window the ring sits in.
    private let motion: NookMotion

    init(items: [TaskRingItem], style: Style = .panel, orbSize: CGFloat = 46, maxSide: CGFloat = .infinity,
         hovered: String? = nil, pointer: TaskRingPointer? = nil, motion: NookMotion? = nil,
         onOpen: @escaping (TaskRingItem) -> Void = { _ in }) {
        self.items = items
        self.style = style
        self.orbSize = orbSize
        self.maxSide = maxSide
        self.hovered = hovered
        self.pointer = pointer
        self.motion = motion ?? NookMotion()
        self.onOpen = onOpen
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nookAttended) private var attended

    private var metrics: TaskRingMetrics { TaskRingMetrics(compact: style == .compact, orbSize: orbSize, maxSide: maxSide, count: items.count) }

    static func radius(orbSize: CGFloat) -> CGFloat { orbSize / 2 + 12 }

    var body: some View {
        let metrics = metrics
        // In a graph of its own (`SeparateGraph`), so its frames do not update the window it is in; hover and clicks stay
        // on the band below. Environment values do not reach into that graph, so they go in as values.
        SeparateGraph {
            TaskRingDrawing(items: items, metrics: metrics, hovered: hovered, motion: motion,
                            reduceMotion: reduceMotion, attended: attended)
        }
        // Twice its size, so the ring trailing behind Nook and stretching is not cut off.
        .frame(width: metrics.side * 2, height: metrics.side * 2)
        .allowsHitTesting(false)
        .frame(width: metrics.side, height: metrics.side)
        .contentShape(RingBand(radius: metrics.radius, width: 16), eoFill: true)
        .onContinuousHover { phase in
            guard style == .panel else { return }
            switch phase {
            case .active(let point): hover(index(at: point))
            case .ended: hover(nil)
            }
        }
        .onTapGesture { point in
            guard style == .panel, let i = index(at: point) else { return }
            pointer?.clear()
            onOpen(items[i])
        }
        .allowsHitTesting(style == .panel)
        .onDisappear { if style == .panel { pointer?.clear() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("notch.taskRing"))
        .accessibilityValue(items.map { "\($0.title), \($0.detail)" }.joined(separator: "; "))
    }

    static func angle(_ i: Int, count: Int, radius: CGFloat) -> Double {
        let gap: CGFloat = count > 1 ? 8 / (2 * .pi * radius) : 0
        let slot = 1 / CGFloat(max(count, 1))
        let start = CGFloat(i) * slot + gap / 2
        let end = start + max(0.001, slot - gap)
        return Double((start + end) / 2) * 2 * .pi - .pi / 2
    }

    /// The piece under `point`, measured on the ring at rest: it trails Nook by a few points at most.
    private func index(at point: CGPoint) -> Int? {
        guard !items.isEmpty else { return nil }
        let side = metrics.side
        let dx = point.x - side / 2
        let dy = point.y - side / 2
        guard abs(hypot(dx, dy) - metrics.radius) < 9 else { return nil }
        var fraction = (atan2(dy, dx) + .pi / 2) / (2 * .pi)
        if fraction < 0 { fraction += 1 }
        return min(Int(fraction * CGFloat(items.count)), items.count - 1)
    }

    private func hover(_ index: Int?) {
        pointer?.onRing(index.map { items[$0].id }, angle: index.map { Self.angle($0, count: items.count, radius: metrics.radius) })
    }
}

/// The ring's sizes for one style, Nook's size and number of pieces.
private struct TaskRingMetrics: Equatable {
    let compact: Bool
    let orbSize: CGFloat
    let maxSide: CGFloat
    let count: Int

    var lineWidth: CGFloat { compact ? 2 : 3.6 }
    var radius: CGFloat { compact ? min(orbSize / 2 + 3.5, (maxSide - lineWidth) / 2 - 1) : NookTaskRing.radius(orbSize: orbSize) }
    var side: CGFloat { compact ? radius * 2 + lineWidth : radius * 2 + 14 }
    /// Room between two pieces, as a fraction of the circle.
    var gap: CGFloat { count > 1 ? (compact ? 4 : 8) / (2 * .pi * radius) : 0 }

    /// Where piece `i` starts and ends, as fractions of the circle measured clockwise from the top.
    func span(_ i: Int) -> (start: CGFloat, end: CGFloat) {
        let slot = 1 / CGFloat(max(count, 1))
        let start = CGFloat(i) * slot + gap / 2
        return (start, start + max(0.001, slot - gap))
    }
}

/// What the ring draws, in its own graph: one `Canvas` per frame, rendered off the main thread, instead of a view tree
/// of trimmed circles and a shadow per piece that SwiftUI compared and blurred on the main thread every frame.
///
/// It runs at the ambient rate while only the light moves through running pieces (slow, it stays fluid), at the
/// interactive rate while the ring trails Nook, draws itself in or a piece grows under the pointer, so motion stays
/// smooth, and not at all once everything holds still.
private struct TaskRingDrawing: View {
    let items: [TaskRingItem]
    let metrics: TaskRingMetrics
    let hovered: String?
    @ObservedObject var motion: NookMotion
    let reduceMotion: Bool
    let attended: ViewAttention

    @StateObject private var spring = RingSpring()
    /// Published only when the plan changes: sets how often the ring redraws.
    @ObservedObject private var energy = EnergyMonitor.shared
    @State private var appeared = Date()
    /// The last change of the piece under the pointer: the one it went to, the one it left, and when.
    @State private var hoverChange = (id: String?.none, previous: String?.none, at: Date.distantPast)
    /// Until when a transition (drawing in, a piece growing or shrinking) runs; flipped once it ends, to let the
    /// timeline pause.
    @State private var transitionUntil = Date.distantPast
    @State private var transitionEnd: Task<Void, Never>?

    private static let drawIn = 1.3
    private static let hoverGrow = 0.15
    private static let track = Color(hex: 0x141419)

    var body: some View {
        let moving = !reduceMotion && items.contains { $0.state == .running || $0.state == .waiting }
        // Keeps drawing while the ring still catches up with Nook; once it rests, the spring asks for one more redraw so
        // the timeline can pause again.
        let following = !reduceMotion && !spring.settled(at: motion.offset)
        let transition = transitionUntil > Date()
        let plan = energy.plan
        let rate = plan.frameRate(following || transition ? plan.interactiveFrameRate : plan.ambientFrameRate, attended: attended)
        // perf: this view is the root of the ring's SeparateGraph (see NookTaskRing.body).
        TimelineView(.nookFrames(fps: rate, paused: !moving && !following && !transition)) { context in
            // Worked out here, on the main thread: the spring and the state belong to it. The canvas only gets values, so
            // it can draw on a thread of its own.
            let frame = frame(at: context.date)
            Canvas(rendersAsynchronously: true) { canvas, size in
                Self.draw(frame, in: &canvas, size: size)
            }
        }
        .onAppear {
            appeared = Date()
            if !metrics.compact { startTransition(Self.drawIn) }
        }
        .onChange(of: hovered) { previous, id in
            hoverChange = (id, previous, Date())
            startTransition(Self.hoverGrow)
        }
        .onDisappear { transitionEnd?.cancel() }
    }

    /// Runs the timeline for `duration` at the interactive rate, then lets it pause again.
    private func startTransition(_ duration: TimeInterval) {
        guard !reduceMotion else { return }
        let until = Date().addingTimeInterval(duration)
        guard until > transitionUntil else { return }
        transitionUntil = until
        transitionEnd?.cancel()
        transitionEnd = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000) + 20_000_000)
            guard !Task.isCancelled else { return }
            transitionUntil = .distantPast
        }
    }

    /// One frame of the ring, as plain values.
    private struct Frame {
        var offset = CGSize.zero
        var stretch: (amount: CGFloat, direction: Double) = (0, 0)
        var radius: CGFloat = 0
        var trackWidth: CGFloat = 0
        var trackOpacity: Double = 1
        var glowRadius: CGFloat = 2
        var lines: [(path: Path, color: Color, width: CGFloat)] = []
    }

    private func frame(at date: Date) -> Frame {
        let t = date.timeIntervalSinceReferenceDate
        let since = date.timeIntervalSince(appeared)
        let radius = metrics.radius
        let width = metrics.lineWidth
        // The closed notch comes and goes all day: there the ring is simply there, without drawing itself in.
        let drawn = metrics.compact || reduceMotion
        var frame = Frame()
        frame.stretch = elastic(at: t)
        frame.offset = spring.position
        frame.radius = radius
        frame.trackWidth = width + 0.9
        frame.trackOpacity = drawn ? 1 : Double(Self.easeOut(Self.progress(since, delay: 0.25, duration: 0.5)))
        frame.glowRadius = metrics.compact ? 1 : 2
        for (i, item) in items.enumerated() {
            let span = metrics.span(i)
            let grown = drawn ? 1 : Self.springOut(Self.progress(since, delay: 0.3 + Double(i) * 0.08, duration: 0.7))
            guard grown > 0 else { continue }
            let end = span.start + (span.end - span.start) * grown
            let lineWidth = width * (1 + 0.5 * hot(item.id, at: date))
            let pulse = item.state == .waiting && !reduceMotion ? 0.5 + 0.5 * abs(cos(t * 2)) : 1
            frame.lines.append((Self.arc(span.start, end, radius: radius),
                                item.color.opacity(item.state == .running ? 0.28 : pulse), lineWidth))
            if item.state == .running, drawn || since > 0.9 {
                let light = comet(span, t: t)
                frame.lines.append((Self.arc(light.start, light.end, radius: radius), item.color, lineWidth))
            }
        }
        return frame
    }

    private static func draw(_ frame: Frame, in canvas: inout GraphicsContext, size: CGSize) {
        // Centered, moved with the spring and stretched along the line towards Nook, a little narrower across it, like a
        // band that is pulled; then turned so a piece's 0 is at the top.
        canvas.translateBy(x: size.width / 2 + frame.offset.width, y: size.height / 2 + frame.offset.height)
        canvas.rotate(by: .radians(frame.stretch.direction))
        canvas.scaleBy(x: 1 + frame.stretch.amount, y: 1 - frame.stretch.amount * 0.6)
        canvas.rotate(by: .radians(-frame.stretch.direction - .pi / 2))
        if frame.trackOpacity > 0 {
            canvas.stroke(arc(0, 1, radius: frame.radius), with: .color(track.opacity(frame.trackOpacity)), lineWidth: frame.trackWidth)
        }
        // The glow: the pieces once more, blurred together in one layer, instead of a shadow per piece.
        canvas.drawLayer { glow in
            glow.addFilter(.blur(radius: frame.glowRadius))
            glow.opacity = 0.55
            for line in frame.lines {
                glow.stroke(line.path, with: .color(line.color), style: StrokeStyle(lineWidth: line.width, lineCap: .round))
            }
        }
        for line in frame.lines {
            canvas.stroke(line.path, with: .color(line.color), style: StrokeStyle(lineWidth: line.width, lineCap: .round))
        }
    }

    /// How far piece `id` has grown under the pointer, 0 to 1, easing over `hoverGrow`.
    private func hot(_ id: String, at date: Date) -> CGFloat {
        let p = reduceMotion ? 1 : Self.easeOut(Self.progress(date.timeIntervalSince(hoverChange.at), delay: 0, duration: Self.hoverGrow))
        if hoverChange.id == id { return p }
        // The piece the pointer just left shrinks back.
        return hoverChange.previous == id ? 1 - p : 0
    }

    /// Moves the ring on towards Nook and says how far, and in which direction, it is pulled out of round.
    private func elastic(at t: TimeInterval) -> (amount: CGFloat, direction: Double) {
        guard !reduceMotion else { return (0, 0) }
        let target = motion.offset
        spring.advance(towards: target, at: t)
        let dx = target.width - spring.position.width
        let dy = target.height - spring.position.height
        let pull = hypot(dx, dy)
        guard pull > 0.05 else { return (0, 0) }
        return (min(pull / metrics.radius * 0.9, 0.12), atan2(dy, dx))
    }

    /// A short light that sweeps through a running piece and back, so you see something is happening.
    private func comet(_ span: (start: CGFloat, end: CGFloat), t: Double) -> (start: CGFloat, end: CGFloat) {
        let length = min((metrics.compact ? 7 : 10) / (2 * .pi * metrics.radius), (span.end - span.start) * 0.35)
        let phase = reduceMotion ? 0.5 : (1 - cos((t * 0.45 + Double(span.start)) * 2 * .pi)) / 2
        let start = span.start + (span.end - span.start - length) * CGFloat(phase)
        return (start, start + length)
    }

    /// An arc from fraction `start` to `end` of the circle, clockwise, starting at the drawing's 0 (turned to the top).
    private static func arc(_ start: CGFloat, _ end: CGFloat, radius: CGFloat) -> Path {
        var path = Path()
        path.addArc(center: .zero, radius: radius, startAngle: .radians(Double(start) * 2 * .pi),
                    endAngle: .radians(Double(end) * 2 * .pi), clockwise: false)
        return path
    }

    private static func progress(_ elapsed: TimeInterval, delay: Double, duration: Double) -> CGFloat {
        CGFloat(min(max((elapsed - delay) / duration, 0), 1))
    }

    private static func easeOut(_ p: CGFloat) -> CGFloat { 1 - (1 - p) * (1 - p) }

    /// A spring with a little bounce, like `.spring(duration: 0.7, bounce: 0.15)`: past the end and back.
    private static func springOut(_ p: CGFloat) -> CGFloat {
        guard p < 1 else { return 1 }
        let overshoot: CGFloat = 1.2
        let q = p - 1
        return 1 + q * q * ((overshoot + 1) * q + overshoot)
    }
}

/// Where Nook is pushed from his place right now (hops, nods, leaning towards you), shared by his orb and the task ring
/// around him. It only publishes moves of more than a hair, so a Nook that holds still does not redraw the ring.
@MainActor
final class NookMotion: ObservableObject {
    @Published private(set) var offset = CGSize.zero

    func follow(_ new: CGSize) {
        guard abs(new.width - offset.width) > 0.05 || abs(new.height - offset.height) > 0.05 else { return }
        offset = new
    }
}

/// The ring's own place: a soft, slightly bouncy spring pulled towards Nook, so it trails behind him, overshoots a
/// little and settles. Advanced while the ring draws; publishes only once it comes to rest, to let the ring pause.
@MainActor
private final class RingSpring: ObservableObject {
    private(set) var position = CGSize.zero
    private var velocity = CGSize.zero
    private var lastTime: TimeInterval = 0
    private var resting = true

    private static let stiffness: CGFloat = 180
    private static let damping: CGFloat = 13

    func settled(at target: CGSize) -> Bool {
        abs(target.width - position.width) < 0.05 && abs(target.height - position.height) < 0.05
            && abs(velocity.width) < 0.5 && abs(velocity.height) < 0.5
    }

    func advance(towards target: CGSize, at t: TimeInterval) {
        // Capped, so a ring that waited does not leap when it wakes.
        var left = lastTime > 0 ? CGFloat(min(max(t - lastTime, 0), 0.1)) : 0
        lastTime = t
        while left > 0 {
            let dt = min(left, 1.0 / 120)
            velocity.width += (Self.stiffness * (target.width - position.width) - Self.damping * velocity.width) * dt
            velocity.height += (Self.stiffness * (target.height - position.height) - Self.damping * velocity.height) * dt
            position.width += velocity.width * dt
            position.height += velocity.height * dt
            left -= dt
        }
        let rests = settled(at: target)
        if rests {
            position = target
            velocity = .zero
        }
        guard rests != resting else { return }
        resting = rests
        // Coming to rest: one redraw after this frame lets the ring's timeline pause. Not from inside the draw itself.
        if rests { Task { @MainActor [weak self] in self?.objectWillChange.send() } }
    }
}

/// Which piece of the ring the pointer is on, shared by the ring and its label. Leaving the ring does not clear it at
/// once: the label beside the ring stays while you move onto it, so you can click it there to go to that piece.
@MainActor
final class TaskRingPointer: ObservableObject {
    @Published private(set) var hovered: String?
    private var inRing = false
    private var inLabel = false
    private var leaving: Task<Void, Never>?

    /// The pointer moved over the ring: on piece `id` (looked at from `angle`), or off it (nil).
    func onRing(_ id: String?, angle: Double?) {
        inRing = id != nil
        guard let id else { return leaveSoon() }
        leaving?.cancel()
        guard id != hovered else { return }
        hovered = id
        NookPresence.shared.lookAngle = angle
        NookPresence.shared.noteActivity()
    }

    func onLabel(_ inside: Bool) {
        inLabel = inside
        if inside { leaving?.cancel() } else { leaveSoon() }
    }

    func clear() {
        leaving?.cancel()
        inRing = false
        inLabel = false
        hovered = nil
        NookPresence.shared.lookAngle = nil
    }

    private func leaveSoon() {
        leaving?.cancel()
        leaving = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled, !self.inRing, !self.inLabel else { return }
            self.clear()
        }
    }
}

/// The band the ring takes clicks and hovers in; the middle stays free for Nook himself.
private struct RingBand: Shape {
    let radius: CGFloat
    let width: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.addEllipse(in: CGRect(x: center.x - radius - width / 2, y: center.y - radius - width / 2, width: 2 * radius + width, height: 2 * radius + width))
        path.addEllipse(in: CGRect(x: center.x - radius + width / 2, y: center.y - radius + width / 2, width: 2 * radius - width, height: 2 * radius - width))
        return path
    }
}
/// The name of the piece under the pointer, just outside the ring. Lives apart from the ring so it can be drawn above
/// Nook and the content beside him instead of behind them. Click it to go to that piece, like the piece itself.
struct NookTaskRingLabel: View {
    let items: [TaskRingItem]
    let hovered: String?
    var orbSize: CGFloat = 46
    var pointer: TaskRingPointer?
    var onOpen: (TaskRingItem) -> Void = { _ in }

    private var radius: CGFloat { NookTaskRing.radius(orbSize: orbSize) }
    private var side: CGFloat { radius * 2 + 14 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let id = hovered, let i = items.firstIndex(where: { $0.id == id }) {
                let a = NookTaskRing.angle(i, count: items.count, radius: radius)
                let item = items[i]
                Button {
                    pointer?.clear()
                    onOpen(item)
                } label: {
                    HStack(spacing: 5) {
                        Text(item.title)
                            .foregroundStyle(NookTheme.paper)
                        Text(item.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                        Image(systemName: "arrow.up.right")
                            .font(NookTheme.font(10, .semibold))
                            .foregroundStyle(NookTheme.textSecondary)
                    }
                    .font(NookTheme.font(12, .medium))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color(hex: 0x17171D)))
                    .overlay(Capsule().stroke(NookTheme.line2, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { pointer?.onLabel($0) }
                .help(tr("notch.taskRing.open"))
                .shadow(color: .black.opacity(0.5), radius: 9, y: 4)
                .offset(x: side / 2 + CGFloat(cos(a)) * (radius + 10) + 6, y: side / 2 + CGFloat(sin(a)) * (radius + 10) - 12)
                .transition(.opacity)
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
    }
}
