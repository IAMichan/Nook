import SwiftUI

/// What a view's polling loop knows of its window: whether anybody can see it (`nookAttended`). A loop in a `.task` reads
/// the environment only once, when the task starts; this box follows it for as long as the view is there, so the loop
/// can skip its ticks while the window is covered, minimized or on another Space, and catch up the moment it shows again.
///
/// Hold one in `@State`, put `.attentionGate(gate)` on the view, and run the loop with `poll(every:_:)`.
@MainActor
final class AttentionGate {
    private(set) var attention: ViewAttention = .attended
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    var isHidden: Bool { attention == .hidden }

    func set(_ attention: ViewAttention) {
        guard attention != self.attention else { return }
        self.attention = attention
        guard attention != .hidden else { return }
        let waiting = waiters
        waiters = [:]
        waiting.values.forEach { $0.resume() }
    }

    /// Returns at once while the window can be seen, otherwise as soon as it can again (or the task is cancelled). Waits
    /// without a timer: nothing wakes while the window stays hidden.
    func waitUntilSeen() async {
        while isHidden, !Task.isCancelled {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if !isHidden || Task.isCancelled { continuation.resume() } else { waiters[id] = continuation }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: id)?.resume() }
            }
        }
    }

    /// Runs `tick` now and then every `interval()` seconds until the task ends, skipping the ticks while the window is
    /// hidden: the first one after it shows again runs at once. `interval` is asked after each tick, so it can follow the
    /// energy plan or what the tick found.
    func poll(every interval: () -> TimeInterval, _ tick: () async -> Void) async {
        while !Task.isCancelled {
            await waitUntilSeen()
            if Task.isCancelled { return }
            await tick()
            let seconds = interval()
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, seconds) * 1_000_000_000))
        }
    }
}

extension View {
    /// Keeps `gate` told whether this view's window can be seen (`nookAttended`), for its polling loop.
    func attentionGate(_ gate: AttentionGate) -> some View {
        modifier(AttentionGateFollower(gate: gate))
    }
}

private struct AttentionGateFollower: ViewModifier {
    let gate: AttentionGate
    @Environment(\.nookAttended) private var attended

    func body(content: Content) -> some View {
        content
            .onAppear { gate.set(attended) }
            .onChange(of: attended) { _, now in gate.set(now) }
    }
}
