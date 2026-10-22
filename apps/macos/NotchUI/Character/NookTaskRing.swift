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
    /// Where Nook is pushed from his place, written by his `NookOrb`; the ring follows it.
    @ObservedObject private var motion: NookMotion

    init(items: [TaskRingItem], style: Style = .panel, orbSize: CGFloat = 46, maxSide: CGFloat = .infinity,
         hovered: String? = nil, pointer: TaskRingPointer? = nil, motion: NookMotion? = nil,
         onOpen: @escaping (TaskRingItem) -> Void = { _ in }) {
        self.items = items
        self.style = style
        self.orbSize = orbSize
        self.maxSide = maxSide
        self.hovered = hovered
        self.pointer = pointer
        _motion = ObservedObject(wrappedValue: motion ?? NookMotion())
        self.onOpen = onOpen
    }

    @State private var shown = false
    @State private var appeared = Date()
    @StateObject private var spring = RingSpring()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Published only when the plan changes: sets how often the ring redraws.
    @ObservedObject private var energy = EnergyMonitor.shared

    private var compact: Bool { style == .compact }
    private var lineWidth: CGFloat { compact ? 2 : 3.6 }
    private var radius: CGFloat { compact ? min(orbSize / 2 + 3.5, (maxSide - lineWidth) / 2 - 1) : Self.radius(orbSize: orbSize) }
    private var side: CGFloat { compact ? radius * 2 + lineWidth : radius * 2 + 14 }
    /// Room between two pieces, as a fraction of the circle.
    private var gap: CGFloat { items.count > 1 ? (compact ? 4 : 8) / (2 * .pi * radius) : 0 }

    static func radius(orbSize: CGFloat) -> CGFloat { orbSize / 2 + 12 }

    var body: some View {
        let moving = !reduceMotion && items.contains { $0.state == .running || $0.state == .waiting }
        // Keeps drawing while the ring still catches up with Nook; once it rests, the spring asks for one more redraw
        // so the timeline can pause again.
        let following = !reduceMotion && !spring.settled(at: motion.offset)
        // Possibly for hours in the closed notch: the ambient rate keeps the light fluid there at a fraction of the
        // redraws; in the open panel, where you look at it and point at it, it runs at the interactive rate.
        let rate = compact ? energy.plan.ambientFrameRate : energy.plan.interactiveFrameRate
        TimelineView(.animation(minimumInterval: 1.0 / rate, paused: !moving && !following)) { context in
            ring(at: context.date)
        }
        .frame(width: side, height: side)
        .contentShape(RingBand(radius: radius, width: 16), eoFill: true)
        .onContinuousHover { phase in
            guard !compact else { return }
            switch phase {
            case .active(let point): hover(index(at: point))
            case .ended: hover(nil)
            }
        }
        .onTapGesture { point in
            guard !compact, let i = index(at: point) else { return }
            pointer?.clear()
            onOpen(items[i])
        }
        .allowsHitTesting(!compact)
        .onAppear {
            appeared = Date()
            shown = true
        }
        .onDisappear { if !compact { pointer?.clear() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("notch.taskRing"))
        .accessibilityValue(items.map { "\($0.title), \($0.detail)" }.joined(separator: "; "))
    }

    private func ring(at date: Date) -> some View {
        let t = date.timeIntervalSinceReferenceDate
        // The closed notch comes and goes all day: there the ring is simply there, without drawing itself in.
        let settled = compact || date.timeIntervalSince(appeared) > 0.9
        let stretch = elastic()
        return ZStack {
            Circle()
                .stroke(Color(hex: 0x141419), lineWidth: lineWidth + 0.9)
                .opacity(shown || compact ? 1 : 0)
                .animation(compact ? nil : .easeOut(duration: 0.5).delay(0.25), value: shown)
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                piece(item, index: i, t: t, settled: settled)
            }
        }
        .frame(width: radius * 2, height: radius * 2)
        .rotationEffect(.degrees(-90))
        // Stretched along the line towards Nook, a little narrower across it, like a band that is pulled.
        .rotationEffect(.radians(-stretch.direction))
        .scaleEffect(x: 1 + stretch.amount, y: 1 - stretch.amount * 0.6)
        .rotationEffect(.radians(stretch.direction))
        .offset(spring.position)
        .frame(width: side, height: side)
    }

    /// Moves the ring on towards Nook and says how far, and in which direction, it is pulled out of round.
    private func elastic() -> (amount: CGFloat, direction: Double) {
        guard !reduceMotion else { return (0, 0) }
        let target = motion.offset
        spring.advance(towards: target, at: Date().timeIntervalSinceReferenceDate)
        let dx = target.width - spring.position.width
        let dy = target.height - spring.position.height
        let pull = hypot(dx, dy)
        guard pull > 0.05 else { return (0, 0) }
        return (min(pull / radius * 0.9, 0.12), atan2(dy, dx))
    }

    private func piece(_ item: TaskRingItem, index i: Int, t: Double, settled: Bool) -> some View {
        let span = self.span(i)
        let hot = hovered == item.id
        let width = hot ? lineWidth * 1.5 : lineWidth
        let pulse = item.state == .waiting && !reduceMotion ? 0.5 + 0.5 * abs(cos(t * 2)) : 1
        return ZStack {
            Circle()
                .trim(from: span.start, to: shown || compact ? span.end : span.start)
                .stroke(item.color.opacity(item.state == .running ? 0.28 : pulse), style: StrokeStyle(lineWidth: width, lineCap: .round))
                .animation(compact ? nil : .spring(duration: 0.7, bounce: 0.15).delay(0.3 + Double(i) * 0.08), value: shown)
            if item.state == .running, settled {
                let light = comet(span, t: t)
                Circle()
                    .trim(from: light.start, to: light.end)
                    .stroke(item.color, style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }
        .shadow(color: item.color.opacity(0.55), radius: compact ? 1 : 2)
        .animation(.easeOut(duration: 0.15), value: hot)
    }

    /// A short light that sweeps through a running piece and back, so you see something is happening.
    private func comet(_ span: (start: CGFloat, end: CGFloat), t: Double) -> (start: CGFloat, end: CGFloat) {
        let length = min((compact ? 7 : 10) / (2 * .pi * radius), (span.end - span.start) * 0.35)
        let phase = reduceMotion ? 0.5 : (1 - cos((t * 0.45 + Double(span.start)) * 2 * .pi)) / 2
        let start = span.start + (span.end - span.start - length) * CGFloat(phase)
        return (start, start + length)
    }

    /// Where piece `i` starts and ends, as fractions of the circle measured clockwise from the top.
    private func span(_ i: Int) -> (start: CGFloat, end: CGFloat) {
        let slot = 1 / CGFloat(max(items.count, 1))
        let start = CGFloat(i) * slot + gap / 2
        return (start, start + max(0.001, slot - gap))
    }

    /// The direction of the middle of piece `i` from the center: 0 is right, clockwise, y pointing down.
    private func angle(_ i: Int) -> Double { Self.angle(i, count: items.count, radius: radius) }

    static func angle(_ i: Int, count: Int, radius: CGFloat) -> Double {
        let gap: CGFloat = count > 1 ? 8 / (2 * .pi * radius) : 0
        let slot = 1 / CGFloat(max(count, 1))
        let start = CGFloat(i) * slot + gap / 2
        let end = start + max(0.001, slot - gap)
        return Double((start + end) / 2) * 2 * .pi - .pi / 2
    }

    private func index(at point: CGPoint) -> Int? {
        guard !items.isEmpty else { return nil }
        let dx = point.x - side / 2 - spring.position.width
        let dy = point.y - side / 2 - spring.position.height
        guard abs(hypot(dx, dy) - radius) < 9 else { return nil }
        var fraction = (atan2(dy, dx) + .pi / 2) / (2 * .pi)
        if fraction < 0 { fraction += 1 }
        return min(Int(fraction * CGFloat(items.count)), items.count - 1)
    }

    private func hover(_ index: Int?) {
        pointer?.onRing(index.map { items[$0].id }, angle: index.map { angle($0) })
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
