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

/// The ring around Nook in the open panel: one piece for everything he and your agents are working on. It is never shown
/// in the closed notch; it draws itself in, piece by piece, when the panel opens.
///
/// Running work is a faint piece with a light running through it, something that waits for you pulses amber, a failure
/// is coral and what is finished is mint. Point at a piece and Nook looks at it, with its name beside the ring; click it
/// to go there.
struct NookTaskRing: View {
    let items: [TaskRingItem]
    /// Size of Nook inside the ring.
    var orbSize: CGFloat = 46
    /// The piece Nook looks at (shared with `NookTaskRingLabel`).
    @Binding var hovered: String?
    /// Last, so a call can pass it as a trailing closure.
    let onOpen: (TaskRingItem) -> Void

    @State private var shown = false
    @State private var appeared = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var radius: CGFloat { orbSize / 2 + 12 }
    private var side: CGFloat { radius * 2 + 14 }
    private var lineWidth: CGFloat { 3.6 }
    /// Room between two pieces, as a fraction of the circle.
    private var gap: CGFloat { items.count > 1 ? 8 / (2 * .pi * radius) : 0 }

    var body: some View {
        let moving = !reduceMotion && items.contains { $0.state == .running || $0.state == .waiting }
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !moving)) { context in
            ring(at: context.date)
        }
        .frame(width: side, height: side)
        .contentShape(RingBand(radius: radius, width: 16), eoFill: true)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hover(index(at: point))
            case .ended: hover(nil)
            }
        }
        .onTapGesture { point in
            guard let i = index(at: point) else { return }
            hover(nil)
            onOpen(items[i])
        }
        .onAppear {
            appeared = Date()
            shown = true
        }
        .onDisappear { NookPresence.shared.lookAngle = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("notch.taskRing"))
        .accessibilityValue(items.map { "\($0.title), \($0.detail)" }.joined(separator: "; "))
    }

    private func ring(at date: Date) -> some View {
        let t = date.timeIntervalSinceReferenceDate
        let settled = date.timeIntervalSince(appeared) > 0.9
        return ZStack {
            Circle()
                .stroke(Color(hex: 0x141419), lineWidth: 4.5)
                .opacity(shown ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.25), value: shown)
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
        return ZStack {
            Circle()
                .trim(from: span.start, to: shown ? span.end : span.start)
                .stroke(item.color.opacity(item.state == .running ? 0.28 : pulse), style: StrokeStyle(lineWidth: width, lineCap: .round))
                .animation(.spring(duration: 0.7, bounce: 0.15).delay(0.3 + Double(i) * 0.08), value: shown)
            if item.state == .running, settled {
                let light = comet(span, t: t)
                Circle()
                    .trim(from: light.start, to: light.end)
                    .stroke(item.color, style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }
        .shadow(color: item.color.opacity(0.55), radius: 2)
        .animation(.easeOut(duration: 0.15), value: hot)
    }

    /// A short light that sweeps through a running piece and back, so you see something is happening.
    private func comet(_ span: (start: CGFloat, end: CGFloat), t: Double) -> (start: CGFloat, end: CGFloat) {
        let length = min(10 / (2 * .pi * radius), (span.end - span.start) * 0.35)
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

    private var radius: CGFloat { orbSize / 2 + 12 }
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
