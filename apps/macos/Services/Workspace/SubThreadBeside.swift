import Foundation

/// Where a sub-thread (a task its session delegated) opens from the strip above that session's composer: beside the
/// main thread in the session's side panel, so you can follow it and answer its questions without losing the main
/// thread. Foundation only; `SubThreadStrip` and `SessionWorkbench` act on what comes back.
enum SubThreadBeside {
    enum Action: Equatable {
        /// Show this sub-thread in the side panel (in place of the one shown there, if any).
        case beside(UUID)
        /// Close the sub-thread tab of the side panel: its row was clicked again.
        case close
        /// Open the sub-thread in place of the main thread, as its own session.
        case here(UUID)
    }

    /// What a click on a sub-thread's row does. `shown` is the sub-thread the side panel shows now, `hasRoom` whether
    /// the conversation keeps its place beside the side panel (a narrow notch has none), and `here` a request to open
    /// it as the main view (⌘-click, the row's menu).
    static func action(for id: UUID, shown: UUID?, hasRoom: Bool, here: Bool) -> Action {
        if here || !hasRoom { return .here(id) }
        return shown == id ? .close : .beside(id)
    }

    /// Whether the sub-thread tab still belongs to the session on screen: one that session delegated. A tab left over
    /// from another session (or a sub-thread that is gone) is put away instead of showing beside the wrong thread.
    static func belongs(_ shown: UUID?, to parent: UUID?, children: [UUID]) -> Bool {
        guard let shown, parent != nil else { return false }
        return children.contains(shown)
    }
}

/// What a sub-thread's row says of its work, beside its title: how long it has worked, counting up while it works and
/// its total once it ended. Foundation only.
enum SubThreadStats {
    /// Under this width the strip leaves out the agent's name, so the title and the stats keep their room.
    static let providerWidth: Double = 460

    /// How long it has been at it: from its start to now while it works, else to its last step.
    static func worked(started: Date, lastStep: Date?, active: Bool, now: Date = Date()) -> TimeInterval {
        let end = active ? now : (lastStep ?? started)
        return max(0, end.timeIntervalSince(started))
    }

    /// The `tr` key and numbers for a duration: "42s", "4m 12s", "1h 05m" (seconds drop off after an hour).
    static func clock(_ interval: TimeInterval) -> (key: String, values: [Int]) {
        let total = max(0, Int(interval))
        let hours = total / 3600, minutes = total % 3600 / 60, seconds = total % 60
        if hours > 0 { return ("ws.subthread.clock.hours", [hours, minutes]) }
        if minutes > 0 { return ("ws.subthread.clock.minutes", [minutes, seconds]) }
        return ("ws.subthread.clock.seconds", [seconds])
    }

    /// The duration as the row shows it, in the app's language.
    static func clockText(_ interval: TimeInterval) -> String {
        let parts = clock(interval)
        switch parts.values.count {
        case 2: return tr(parts.key, parts.values[0], parts.values[1])
        default: return tr(parts.key, parts.values.first ?? 0)
        }
    }
}
