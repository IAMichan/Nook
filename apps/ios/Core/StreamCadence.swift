import Foundation

/// When a light tick may play while an agent's answer streams in on the phone: a
/// texture you feel, never a buzz. At most one tick per `interval`, none during the first `settle` after a session
/// opened (opening one that already streams would otherwise tick at once), and none while the agent does not work.
/// Foundation-only, so it is tested on the Mac (NookTests).
struct StreamCadence: Equatable {
    static let interval: TimeInterval = 0.32
    static let settle: TimeInterval = 1

    private let openedAt: Date
    private var lastTick: Date?

    init(openedAt: Date) { self.openedAt = openedAt }

    /// Whether a change of the conversation at `now` ticks; remembers it when it does.
    mutating func tick(working: Bool, now: Date) -> Bool {
        guard working, now.timeIntervalSince(openedAt) >= Self.settle else { return false }
        if let lastTick, now.timeIntervalSince(lastTick) < Self.interval { return false }
        lastTick = now
        return true
    }
}
