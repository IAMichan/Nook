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
    /// Drawn in place from the start, without the draw-in animation (a chat you marked as finished).
    var instant = false

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
struct NookTaskRing: View {
    enum Style { case panel, compact }

    let items: [TaskRingItem]
    var style: Style = .panel
    /// Size of Nook inside the ring.
    var orbSize: CGFloat = 46
    /// The room the ring may take; the closed notch is not much taller than Nook.
    var maxSide: CGFloat = .infinity
    /// The piece Nook looks at (shared with `NookTaskRingLabel`).
    @Binding var hovered: String?
    let onOpen: (TaskRingItem) -> Void

    init(items: [TaskRingItem], style: Style = .panel, orbSize: CGFloat = 46, maxSide: CGFloat = .infinity,
         hovered: Binding<String?> = .constant(nil), onOpen: @escaping (TaskRingItem) -> Void = { _ in }) {
        self.items = items
        self.style = style
        self.orbSize = orbSize
        self.maxSide = maxSide
        self._hovered = hovered
        self.onOpen = onOpen
    }

    @State private var shown = false
    @State private var appeared = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var compact: Bool { style == .compact }
    private var lineWidth: CGFloat { compact ? 2 : 3.6 }
    private var radius: CGFloat { compact ? min(orbSize / 2 + 3.5, (maxSide - lineWidth) / 2 - 1) : Self.radius(orbSize: orbSize) }
    private var side: CGFloat { compact ? radius * 2 + lineWidth : radius * 2 + 14 }
    /// Room between two pieces, as a fraction of the circle.
    private var gap: CGFloat { items.count > 1 ? (compact ? 4 : 8) / (2 * .pi * radius) : 0 }

    static func radius(orbSize: CGFloat) -> CGFloat { orbSize / 2 + 12 }

    var body: some View {
        let moving = !reduceMotion && items.contains { $0.state == .running || $0.state == .waiting }
        // Possibly for hours in the closed notch: fifteen frames a second keep the light smooth enough there.
        TimelineView(.animation(minimumInterval: 1.0 / (compact ? 15.0 : 30.0), paused: !moving)) { context in
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
            hover(nil)
            onOpen(items[i])
        }
        .allowsHitTesting(!compact)
        .onAppear {
            appeared = Date()
            shown = true
        }
        .onDisappear { if !compact { NookPresence.shared.lookAngle = nil } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("notch.taskRing"))
        .accessibilityValue(items.map { "\($0.title), \($0.detail)" }.joined(separator: "; "))
    }

    private func ring(at date: Date) -> some View {
        let t = date.timeIntervalSinceReferenceDate
        // The closed notch comes and goes all day: there the ring is simply there, without drawing itself in.
        let settled = compact || date.timeIntervalSince(appeared) > 0.9
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
        .frame(width: side, height: side)
    }

    private func piece(_ item: TaskRingItem, index i: Int, t: Double, settled: Bool) -> some View {
        let span = self.span(i)
        let hot = hovered == item.id
        let width = hot ? lineWidth * 1.5 : lineWidth
        let pulse = item.state == .waiting && !reduceMotion ? 0.5 + 0.5 * abs(cos(t * 2)) : 1
        let instant = compact || item.instant
        return ZStack {
            Circle()
                .trim(from: span.start, to: shown || instant ? span.end : span.start)
                .stroke(item.color.opacity(item.state == .running ? 0.28 : pulse), style: StrokeStyle(lineWidth: width, lineCap: .round))
                .animation(instant ? nil : .spring(duration: 0.7, bounce: 0.15).delay(0.3 + Double(i) * 0.08), value: shown)
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
        let dx = point.x - side / 2
        let dy = point.y - side / 2
        guard abs(hypot(dx, dy) - radius) < 9 else { return nil }
        var fraction = (atan2(dy, dx) + .pi / 2) / (2 * .pi)
        if fraction < 0 { fraction += 1 }
        return min(Int(fraction * CGFloat(items.count)), items.count - 1)
    }

    private func hover(_ index: Int?) {
        let id = index.map { items[$0].id }
        guard id != hovered else { return }
        hovered = id
        NookPresence.shared.lookAngle = index.map { angle($0) }
        NookPresence.shared.noteActivity()
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
/// Nook and the content beside him instead of behind them.
struct NookTaskRingLabel: View {
    let items: [TaskRingItem]
    let hovered: String?
    var orbSize: CGFloat = 46

    private var radius: CGFloat { NookTaskRing.radius(orbSize: orbSize) }
    private var side: CGFloat { radius * 2 + 14 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let id = hovered, let i = items.firstIndex(where: { $0.id == id }) {
                let a = NookTaskRing.angle(i, count: items.count, radius: radius)
                HStack(spacing: 5) {
                    Text(items[i].title)
                        .foregroundStyle(NookTheme.paper)
                    Text(items[i].detail)
                        .foregroundStyle(NookTheme.textSecondary)
                }
                .font(NookTheme.font(12, .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color(hex: 0x17171D)))
                .overlay(Capsule().stroke(NookTheme.line2, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 9, y: 4)
                .offset(x: side / 2 + CGFloat(cos(a)) * (radius + 10) + 6, y: side / 2 + CGFloat(sin(a)) * (radius + 10) - 12)
                .transition(.opacity)
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}
