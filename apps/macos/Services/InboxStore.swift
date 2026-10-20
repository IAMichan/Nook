import Foundation

/// What you arranged in the Agents list: pins and their order, what the list folds away, the auto-settle rules and the
/// one-line undo. The decisions are in `InboxLayout`, `InboxDrop`, `UndoLog` and `AutoSettlePolicy`; this
/// keeps their state across launches and applies a drop or an undo to the places that hold the result: the pins here, the
/// "finished" marks in `FinishedSessions`, the snooze and archive on the sessions themselves.
@MainActor
final class InboxStore: ObservableObject {
    static let shared = InboxStore()

    @Published private(set) var state: InboxState
    @Published private(set) var undoLog = UndoLog()
    @Published var query = ""
    /// Sessions that work and need nothing from you fold into their own shelf; one that needs you jumps back up.
    @Published var showWorking: Bool { didSet { save() } }
    @Published var autoSettle: AutoSettlePolicy.Settings { didSet { save() } }

    /// Undo of what only the workspace can reverse: a snooze, an archive. They get the ids that were recorded.
    var undoSnooze: (([String]) -> Void)?
    var undoArchive: (([String]) -> Void)?
    /// Settling a session that still reads as busy also ends that turn where the session lives; it gets the ids.
    var settleBusy: (([String]) -> Void)?

    private let defaults: UserDefaults
    private static let key = "agents.inbox.v1"

    private struct Stored: Codable {
        var state: InboxState?
        var showWorking: Bool?
        var autoSettle: AutoSettlePolicy.Settings?
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        state = stored?.state ?? InboxState()
        showWorking = stored?.showWorking ?? true
        autoSettle = stored?.autoSettle ?? AutoSettlePolicy.Settings()
    }

    private func save() {
        let stored = Stored(state: state, showWorking: showWorking, autoSettle: autoSettle)
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
    }

    // MARK: Pins and order

    func pin(_ id: String, record: Bool = true, now: Date = Date()) {
        state.pin(id)
        if record { undoLog.record(.pinned, ids: [id], now: now) }
        save()
    }

    func unpin(_ id: String, record: Bool = true, now: Date = Date()) {
        state.unpin(id)
        if record { undoLog.record(.unpinned, ids: [id], now: now) }
        save()
    }

    /// Several at once, undone together.
    func pin(_ ids: [String], now: Date = Date()) {
        guard !ids.isEmpty else { return }
        for id in ids { state.pin(id) }
        undoLog.record(.pinned, ids: ids, now: now)
        save()
    }

    func unpin(_ ids: [String], now: Date = Date()) {
        guard !ids.isEmpty else { return }
        for id in ids { state.unpin(id) }
        undoLog.record(.unpinned, ids: ids, now: now)
        save()
    }

    func reorder(_ id: String, toIndex index: Int, within section: InboxSection) {
        state.reorder(id, toIndex: index, within: section)
        save()
    }

    func dismissWoke(_ id: String) {
        state.dismissWoke(id)
        save()
    }

    // MARK: Settled

    /// Settles sessions: they move to the shelf at the bottom, and a pin ends. A busy one settles too: it may hang.
    func settle(_ items: [AgentListItem], now: Date = Date(), record: Bool = true) {
        let keys = items.map(\.finishKey)
        for item in items {
            state.unpin(item.id)
            FinishedSessions.shared.mark(item.finishKey, busy: item.isBusy)
        }
        let busy = items.filter(\.isBusy).map(\.id)
        if !busy.isEmpty { settleBusy?(busy) }
        if record { undoLog.record(.settled, ids: keys, now: now) }
        save()
    }

    func unsettle(_ items: [AgentListItem], now: Date = Date(), record: Bool = true) {
        for item in items { FinishedSessions.shared.reopenByUser(item.finishKey) }
        if record { undoLog.record(.unsettled, ids: items.map(\.finishKey), now: now) }
    }

    /// Something the list did not do itself (a snooze, an archive) still gets its place in the undo line.
    func note(_ kind: UndoEntry.Kind, ids: [String], now: Date = Date()) {
        undoLog.record(kind, ids: ids, now: now)
    }

    // MARK: Undo

    var canUndo: Bool { undoLog.current(now: Date()) != nil }

    @discardableResult
    func undo(now: Date = Date()) -> Bool {
        guard let entry = undoLog.undo(now: now) else { return false }
        switch entry.kind {
        case .settled: for key in entry.ids { FinishedSessions.shared.reopenByUser(key) }
        case .unsettled: for key in entry.ids { FinishedSessions.shared.mark(key) }
        case .pinned: for id in entry.ids { state.unpin(id) }
        case .unpinned: for id in entry.ids { state.pin(id) }
        case .snoozed: undoSnooze?(entry.ids)
        case .archived: undoArchive?(entry.ids)
        case .discarded: break
        }
        save()
        return true
    }

    // MARK: Auto-settle

    /// The sessions that settle by themselves right now (never one that runs, waits for you, is pinned or snoozed).
    func autoSettleCandidates(rows: [InboxRow], prMerged: (String) -> Bool, now: Date = Date()) -> [String] {
        guard autoSettle.enabled else { return [] }
        return rows.compactMap { row in
            if case .settle = AutoSettlePolicy.decide(row: row, prMerged: prMerged(row.id), settings: autoSettle, now: now) { return row.id }
            return nil
        }
    }
}
