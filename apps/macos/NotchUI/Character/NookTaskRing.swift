import Combine
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
/// Given Nook's `motion`, the ring moves with him, closed or open, so he always stays in its middle; it reacts like
/// elastic: when he hops, nods or leans towards you it stretches along his move on a spring and overshoots a little
/// before it settles round again.
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
    /// Published only when the plan changes: sets how fast the ring moves.
    @ObservedObject private var energy = EnergyMonitor.shared

    private var metrics: TaskRingMetrics { TaskRingMetrics(compact: style == .compact, orbSize: orbSize, maxSide: maxSide, count: items.count) }

    static func radius(orbSize: CGFloat) -> CGFloat { orbSize / 2 + 12 }

    var body: some View {
        let metrics = metrics
        // Layers of its own (`TaskRingLayers`), so its frames neither update the window it is in nor wait for the main
        // thread; hover and clicks stay on the band below. Its loops cost the render server only, so they run at the
        // interactive rate: the light stays fluid where you look.
        let plan = energy.plan
        TaskRingLayers(config: .init(items: items, metrics: metrics, hovered: hovered, reduceMotion: reduceMotion,
                                     frameRate: plan.frameRate(plan.interactiveFrameRate, attended: attended)),
                       motion: motion)
        // Twice its size, so the ring moving with Nook and stretching is not cut off.
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

    /// The piece under `point`, measured on the ring at rest: it moves with Nook by a few points at most.
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

/// What the ring draws: Core Animation layers in a view of their own, which neither SwiftUI nor the main thread redraws.
///
/// The light through a running piece and the amber pulse are animations the render server runs on its own, so they stay
/// fluid however busy the main thread is with many agents at once (a frame worked out there in time for every display
/// frame is what made the ring stutter). A change (a piece more or less, the pointer on a piece, drawing itself in) is
/// one animation from where the ring is now to where it should be, so pieces slide to their new place instead of
/// jumping. Only following Nook runs on the main thread, on a display link while the ring catches up with him.
private struct TaskRingLayers: NSViewRepresentable {
    let config: TaskRingLayerView.Config
    let motion: NookMotion

    func makeNSView(context: Context) -> TaskRingLayerView { TaskRingLayerView() }

    func updateNSView(_ view: TaskRingLayerView, context: Context) {
        view.follow(motion)
        view.update(config)
    }
}

@MainActor
private final class TaskRingLayerView: NSView {
    struct Config: Equatable {
        var items: [TaskRingItem]
        var metrics: TaskRingMetrics
        var hovered: String?
        var reduceMotion: Bool
        /// Frames per second of the light and the pulse, and of following Nook; 0 holds the ring still.
        var frameRate: Double
    }

    /// The parts of a piece's loop (light or pulse) that, when they change, start it again.
    private struct Loop: Equatable {
        var state: TaskRingItem.Kind
        var sweep: CGFloat
        var frameRate: Double
    }

    private final class Piece {
        let line = CAShapeLayer()
        /// The light that sweeps through a running piece.
        let light = CAShapeLayer()
        var loop: Loop?
    }

    private static let drawIn = 1.3
    private static let hoverGrow = 0.15
    /// How long a piece takes to slide to its new place when one comes or goes.
    private static let reflow = 0.35
    private static let track = Color(hex: 0x141419)

    /// Centered in the view and turned upside down, so the drawing below is y-down like SwiftUI's.
    private let ring = CALayer()
    /// Follows Nook: moved with him and stretched along his move.
    private let body = CALayer()
    private let trackLayer = CAShapeLayer()
    private var pieces: [String: Piece] = [:]
    private var config: Config?

    private weak var motion: NookMotion?
    private var following: AnyCancellable?
    private var target = CGSize.zero
    /// Where the ring's stretch trails Nook: how far the band is pulled out of round, and in which direction.
    private var spring = RingSpring()
    private var stretch: (amount: CGFloat, direction: Double) = (0, 0)
    private var link: CADisplayLink?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        ring.transform = CATransform3DMakeScale(1, -1, 1)
        ring.addSublayer(body)
        body.addSublayer(trackLayer)
        trackLayer.fillColor = nil
        layer?.addSublayer(ring)
        disableActions(on: ring)
        disableActions(on: body)
        style(trackLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        trackLayer.contentsScale = scale
        for piece in pieces.values {
            piece.line.contentsScale = scale
            piece.light.contentsScale = scale
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopFollowing() } else { viewDidChangeBackingProperties() }
    }

    // MARK: Pieces

    func update(_ new: Config) {
        guard new != config else { return }
        let old = config
        config = new
        let metrics = new.metrics
        let moving = !new.reduceMotion && new.frameRate > 0
        // The closed notch comes and goes all day: there the ring is simply there, without drawing itself in.
        let drawingIn = old == nil && moving && !metrics.compact
        let now = CACurrentMediaTime()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Every piece is the whole circle, drawn from its `strokeStart` to its `strokeEnd`: made again only for a new size.
        let circle = old?.metrics.radius == metrics.radius ? nil : Self.circle(radius: metrics.radius)
        if let circle { trackLayer.path = circle }
        trackLayer.lineWidth = metrics.lineWidth + 0.9
        trackLayer.strokeColor = NSColor(Self.track).cgColor
        if drawingIn {
            add(Self.fade(from: 0, to: 1, duration: 0.5, delay: 0.25, at: now), to: trackLayer, key: "drawIn", rate: new.frameRate)
        }

        let ids = Set(new.items.map(\.id))
        for (id, piece) in pieces where !ids.contains(id) {
            pieces[id] = nil
            remove(piece, animated: moving)
        }

        for (i, item) in new.items.enumerated() {
            let span = metrics.span(i)
            let piece: Piece
            let isNew: Bool
            if let existing = pieces[item.id] {
                piece = existing
                isNew = false
            } else {
                piece = Piece()
                style(piece.line)
                style(piece.light)
                body.addSublayer(piece.line)
                body.addSublayer(piece.light)
                pieces[item.id] = piece
                isNew = true
            }
            // Kept in the order of the items, so a later piece's glow lies over an earlier one as before.
            body.insertSublayer(piece.line, at: UInt32(1 + 2 * i))
            body.insertSublayer(piece.light, at: UInt32(2 + 2 * i))

            let color = NSColor(item.color)
            let running = item.state == .running
            let width = metrics.lineWidth * (new.hovered == item.id ? 1.5 : 1)
            let length = min((metrics.compact ? 7 : 10) / (2 * .pi * metrics.radius), (span.end - span.start) * 0.35)
            for layer in [piece.line, piece.light] {
                if isNew || circle != nil { layer.path = circle ?? Self.circle(radius: metrics.radius) }
                layer.shadowColor = color.cgColor
                layer.shadowRadius = metrics.compact ? 1 : 2
            }
            piece.line.strokeColor = color.withAlphaComponent(color.alphaComponent * (running ? 0.28 : 1)).cgColor
            piece.light.strokeColor = color.cgColor
            piece.light.isHidden = !running

            // Where the light rests without motion: halfway, as the sweep would show it.
            let lightStart = span.start + (moving ? 0 : (span.end - span.start - length) / 2)
            if isNew {
                piece.line.strokeStart = span.start
                piece.line.strokeEnd = span.end
                piece.line.lineWidth = width
                piece.light.strokeStart = lightStart
                piece.light.strokeEnd = lightStart + length
                piece.light.lineWidth = width
                if drawingIn {
                    add(Self.grow(from: span.start, to: span.end, delay: 0.3 + Double(i) * 0.08, at: now),
                        to: piece.line, key: "strokeEnd", rate: new.frameRate)
                    add(Self.fade(from: 0, to: 1, duration: 0.2, delay: 0.9, at: now), to: piece.light, key: "drawIn", rate: new.frameRate)
                } else if old != nil, moving {
                    // A piece that comes later grows in from its start, like the others once did.
                    add(Self.ease("strokeEnd", from: span.start, to: span.end, duration: Self.reflow), to: piece.line, key: "strokeEnd", rate: new.frameRate)
                    add(Self.fade(from: 0, to: 1, duration: Self.reflow, delay: 0, at: now), to: piece.light, key: "drawIn", rate: new.frameRate)
                }
            } else {
                let rate = moving ? new.frameRate : 0
                slide(piece.line, "strokeStart", to: span.start, duration: Self.reflow, rate: rate)
                slide(piece.line, "strokeEnd", to: span.end, duration: Self.reflow, rate: rate)
                slide(piece.light, "strokeStart", to: lightStart, duration: Self.reflow, rate: rate)
                slide(piece.light, "strokeEnd", to: lightStart + length, duration: Self.reflow, rate: rate)
                slide(piece.line, "lineWidth", to: width, duration: Self.hoverGrow, rate: rate)
                slide(piece.light, "lineWidth", to: width, duration: Self.hoverGrow, rate: rate)
            }

            let loop = Loop(state: item.state, sweep: span.end - span.start - length, frameRate: moving ? new.frameRate : 0)
            if loop != piece.loop {
                piece.loop = loop
                startLoop(piece, loop, seed: Self.seed(item.id), now: now)
            }
        }
    }

    /// The light sweeping through a running piece and back, or the pulse of one that waits for you: run by the render
    /// server, in step with the clock, so starting it again (a piece that moved, another frame rate) does not jump.
    private func startLoop(_ piece: Piece, _ loop: Loop, seed: Double, now: CFTimeInterval) {
        piece.light.removeAnimation(forKey: "sweep")
        piece.line.removeAnimation(forKey: "pulse")
        guard loop.frameRate > 0 else { return }
        switch loop.state {
        case .running:
            // There and back in 1/0.45 s; added on top of where the light rests, so it slides along with its piece.
            let half = 1 / 0.45 / 2
            let group = CAAnimationGroup()
            group.animations = ["strokeStart", "strokeEnd"].map { key in
                let sweep = CABasicAnimation(keyPath: key)
                sweep.fromValue = 0
                sweep.toValue = loop.sweep
                sweep.isAdditive = true
                return sweep
            }
            group.duration = half
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            group.timeOffset = (now * 0.45 + seed).truncatingRemainder(dividingBy: 1) * half * 2
            add(group, to: piece.light, key: "sweep", rate: loop.frameRate)
        case .waiting:
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.5
            pulse.duration = .pi / 4
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.timeOffset = now.truncatingRemainder(dividingBy: .pi / 2)
            add(pulse, to: piece.line, key: "pulse", rate: loop.frameRate)
        case .failed, .done:
            break
        }
    }

    private func remove(_ piece: Piece, animated: Bool) {
        guard animated else {
            piece.line.removeFromSuperlayer()
            piece.light.removeFromSuperlayer()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            piece.line.removeFromSuperlayer()
            piece.light.removeFromSuperlayer()
        }
        for layer in [piece.line, piece.light] {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
            fade.toValue = 0
            fade.duration = Self.reflow * 0.7
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            layer.removeAnimation(forKey: "pulse")
            layer.add(fade, forKey: "remove")
        }
        CATransaction.commit()
    }

    /// Sets `key` to `value`, sliding there from where it shows now when `rate` is above 0.
    private func slide(_ layer: CAShapeLayer, _ key: String, to value: CGFloat, duration: Double, rate: Double) {
        let current = ((layer.presentation() ?? layer).value(forKeyPath: key) as? CGFloat) ?? value
        let model = (layer.value(forKeyPath: key) as? CGFloat) ?? value
        guard model != value else { return }
        layer.setValue(value, forKeyPath: key)
        guard rate > 0 else { return layer.removeAnimation(forKey: key) }
        add(Self.ease(key, from: current, to: value, duration: duration), to: layer, key: key, rate: rate)
    }

    private func add(_ animation: CAAnimation, to layer: CALayer, key: String, rate: Double) {
        let fps = Float(rate)
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: min(fps, 15), maximum: fps, preferred: fps)
        layer.add(animation, forKey: key)
    }

    private func style(_ layer: CAShapeLayer) {
        layer.fillColor = nil
        layer.lineCap = .round
        layer.shadowOffset = .zero
        layer.shadowOpacity = 0.55
        layer.contentsScale = window?.backingScaleFactor ?? 2
        disableActions(on: layer)
    }

    private func disableActions(on layer: CALayer) {
        layer.actions = ["position": NSNull(), "transform": NSNull(), "path": NSNull(), "strokeStart": NSNull(),
                         "strokeEnd": NSNull(), "lineWidth": NSNull(), "strokeColor": NSNull(), "opacity": NSNull(),
                         "hidden": NSNull(), "sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull()]
    }

    /// The whole circle, clockwise from the top (in the y-down drawing): a piece is the part from its `strokeStart` to its
    /// `strokeEnd`.
    private static func circle(radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addArc(center: .zero, radius: radius, startAngle: -.pi / 2, endAngle: .pi * 3 / 2, clockwise: false)
        return path
    }

    private static func ease(_ keyPath: String, from: CGFloat, to: CGFloat, duration: Double) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return animation
    }

    private static func fade(from: Float, to: Float, duration: Double, delay: Double, at now: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.beginTime = now + delay
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return animation
    }

    /// A spring with a little bounce, past the end and back, after `delay`.
    private static func grow(from: CGFloat, to: CGFloat, delay: Double, at now: CFTimeInterval) -> CASpringAnimation {
        let animation = CASpringAnimation(perceptualDuration: 0.7, bounce: 0.15)
        animation.keyPath = "strokeEnd"
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        animation.beginTime = now + delay
        animation.fillMode = .backwards
        return animation
    }

    /// Where in its loop a piece's light starts, the same for a piece every time, so lights of neighbours differ.
    private static func seed(_ id: String) -> Double {
        let hash = id.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return Double(hash % 1000) / 1000
    }

    // MARK: Following Nook

    /// Moves with `motion` at once, so Nook always stays in the middle of the ring; only its stretch trails him on a
    /// spring, on a display link that runs while the spring catches up and stops once it rests.
    func follow(_ motion: NookMotion) {
        guard motion !== self.motion else { return }
        self.motion = motion
        target = motion.offset
        following = motion.$offset.removeDuplicates().sink { [weak self] offset in
            MainActor.assumeIsolated { self?.moved(to: offset) }
        }
    }

    private func moved(to offset: CGSize) {
        target = offset
        guard let config, !config.reduceMotion, config.frameRate > 0, window != nil else {
            spring = RingSpring(position: offset)
            stretch = (0, 0)
            return applyFollow()
        }
        // In the same transaction as Nook's own move, not a display frame later.
        applyFollow()
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(step))
        let fps = Float(config.frameRate)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(fps, 15), maximum: fps, preferred: fps)
        link.add(to: .main, forMode: .common)
        self.link = link
        spring.lastTime = 0
    }

    @objc private func step(_ link: CADisplayLink) {
        spring.advance(towards: target, at: CACurrentMediaTime())
        let dx = target.width - spring.position.width
        let dy = target.height - spring.position.height
        let pull = hypot(dx, dy)
        let radius = config?.metrics.radius ?? 1
        stretch = pull > 0.05 ? (min(pull / radius * 0.9, 0.12), atan2(dy, dx)) : (0, 0)
        applyFollow()
        if spring.settled(at: target) { stopFollowing() }
    }

    private func stopFollowing() {
        link?.invalidate()
        link = nil
    }

    /// Centers the ring on Nook and stretches it along the line he moves in, a little narrower across it, like a band
    /// that is pulled.
    private func applyFollow() {
        var transform = CATransform3DMakeRotation(-stretch.direction, 0, 0, 1)
        transform = CATransform3DConcat(transform, CATransform3DMakeScale(1 + stretch.amount, 1 - stretch.amount * 0.6, 1))
        transform = CATransform3DConcat(transform, CATransform3DMakeRotation(stretch.direction, 0, 0, 1))
        transform = CATransform3DConcat(transform, CATransform3DMakeTranslation(target.width, target.height, 0))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.transform = transform
        CATransaction.commit()
    }
}

/// A soft, slightly bouncy spring pulled towards Nook: how far it lags behind him is how far the ring stretches, so the
/// band pulls when he moves, overshoots a little and settles round again.
private struct RingSpring {
    private(set) var position = CGSize.zero
    private var velocity = CGSize.zero
    var lastTime: TimeInterval = 0

    private static let stiffness: CGFloat = 180
    private static let damping: CGFloat = 13

    init(position: CGSize = .zero) {
        self.position = position
    }

    func settled(at target: CGSize) -> Bool {
        abs(target.width - position.width) < 0.05 && abs(target.height - position.height) < 0.05
            && abs(velocity.width) < 0.5 && abs(velocity.height) < 0.5
    }

    mutating func advance(towards target: CGSize, at t: TimeInterval) {
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
        if settled(at: target) {
            position = target
            velocity = .zero
        }
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
