import Foundation

/// Sessions working at once (`SessionCapacity`): a turn past the limit waits for a free place and starts, oldest first,
/// once another session's turn ends.
extension WorkspaceManager {
    /// Sessions working now, apart from `id` and from the turns that wait for a free place themselves.
    private func othersWorking(than id: UUID) -> Int {
        runs.filter { $0.id != id && $0.status.isActive && !capacity.isWaiting($0.id) }.count
    }

    /// A new turn past the limit waits for a free place: your message shows at once and the session says why it waits.
    /// True when it waits. A turn of a session that already works (a fallback to another transport) never waits.
    func waitForCapacity(_ id: UUID, prompt: String, executable: String, showPrompt: Bool) -> Bool {
        let limit = settings.maxWorkingSessions
        guard !capacity.isWaiting(id), let run = run(id), !(run.status.isActive && run.status != .preparing),
              SessionCapacity.mustWait(limit: limit, othersWorking: othersWorking(than: id)) else { return false }
        loadTimeline(id)
        if showPrompt { append(id, RunEvent(kind: .user, text: shownPrompt(id, prompt))) }
        capacity.add(id, prompt: prompt, executable: executable)
        update(id) { $0.move(to: .preparing, detail: tr("ws.capacity.waiting", limit)) }
        append(id, RunEvent(kind: .system, text: tr("ws.capacity.waiting", limit)))
        return true
    }

    /// Starts the turns that waited, oldest first, as far as there is room now. Called when a turn ends, when a waiting
    /// one is stopped, and when the limit changes.
    func startWaitingTurns() {
        capacity.prune { run($0) != nil }
        let working = runs.filter { $0.status.isActive && !capacity.isWaiting($0.id) }.count
        let count = SessionCapacity.startable(limit: settings.maxWorkingSessions, working: working, waiting: capacity.count)
        for id in capacity.first(count) {
            guard let waiting = capacity.remove(id) else { continue }
            launchTurn(id, prompt: waiting.prompt, executable: waiting.executable, showPrompt: false)
        }
    }

    /// Stop on a turn that still waits for a free place: it never starts.
    func cancelWaitingTurn(_ id: UUID) -> Bool {
        guard capacity.remove(id) != nil else { return false }
        update(id) { $0.move(to: .stopped) }
        append(id, RunEvent(kind: .system, text: tr("ws.event.stopped")))
        return true
    }
}

/// The turns that wait for a free place, with what each starts with, in the order they came.
struct CapacityScheduler {
    private var waiting: [UUID: (prompt: String, executable: String)] = [:]
    private var order: [UUID] = []

    var isEmpty: Bool { order.isEmpty }
    var count: Int { order.count }

    func isWaiting(_ id: UUID) -> Bool { waiting[id] != nil }

    mutating func add(_ id: UUID, prompt: String, executable: String) {
        waiting[id] = (prompt, executable)
        order.append(id)
    }

    /// Takes a waiting turn out; nil when it was not waiting.
    mutating func remove(_ id: UUID) -> (prompt: String, executable: String)? {
        guard let entry = waiting.removeValue(forKey: id) else { return nil }
        order.removeAll { $0 == id }
        return entry
    }

    /// Keeps the order to turns still waiting whose session `exists`.
    mutating func prune(_ exists: (UUID) -> Bool) {
        order.removeAll { waiting[$0] == nil || !exists($0) }
    }

    /// The oldest `count` waiting turns.
    func first(_ count: Int) -> [UUID] { Array(order.prefix(count)) }

    /// A deleted session waits no more.
    mutating func forget(_ id: UUID) {
        waiting[id] = nil
        order.removeAll { $0 == id }
    }
}
