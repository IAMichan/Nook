import Foundation

/// How many sessions may work at once (Settings › Agents › Sessions › Behavior). Every working session is an agent
/// process with its own model calls; past the limit a new turn waits its turn instead of starting, first come first
/// served, and goes out as soon as another session's turn ends. Off (0) by default. Foundation only, tested on its own.
enum SessionCapacity {
    /// The choices in Settings; 0 is no limit.
    static let choices = [0, 2, 3, 4, 6, 8]

    /// Whether a new turn has to wait: `othersWorking` counts the sessions working now, without this one and without
    /// the ones that are themselves waiting for a free place.
    static func mustWait(limit: Int, othersWorking: Int) -> Bool {
        limit > 0 && othersWorking >= limit
    }

    /// How many waiting turns may start now, oldest first.
    static func startable(limit: Int, working: Int, waiting: Int) -> Int {
        guard waiting > 0 else { return 0 }
        guard limit > 0 else { return waiting }
        return min(waiting, max(0, limit - working))
    }
}
