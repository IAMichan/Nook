import Foundation

/// What you arranged in the Agents list: pins and their order, what the list folds away, the auto-settle rules and the
/// one-line undo. The decisions are in `InboxLayout`, `UndoLog` and `AutoSettlePolicy`; this
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
    /// The sessions that work or wait sit in a dropdown per project instead of one list. Off by default: as in t3code,
    /// the list is one inbox with the newest on top and every row names its project (folders are its "boring mode").
    @Published var groupByProject: Bool { didSet { save() } }
    /// The projects you folded in that view.
    @Published var collapsedProjects: Set<String> { didSet { save() } }
    /// The shelves folded at the foot of the list.
    @Published private(set) var collapsedShelves: Set<InboxSection.Kind>
    /// Sessions whose sub-threads you folded or opened yourself; the rest follow `InboxLayout.threadOpen`.
    @Published private(set) var foldedThreads: Set<String>
    @Published private(set) var openedThreads: Set<String>
    /// The choices of the snooze menus (Settings › Sessions › Snooze options). Kept under a key of their own, so an option
    /// a later Nook adds and this one cannot read never costs the rest of the list's state.
    @Published var snoozeOptions: [SnoozeOption] {
        didSet {
            let cleaned = SnoozeOption.cleaned(snoozeOptions)
            if cleaned != snoozeOptions { snoozeOptions = cleaned; return }
            defaults.setEncoded(snoozeOptions, forKey: Self.snoozeOptionsKey)
        }
    }
    private static let snoozeOptionsKey = "agents.snoozeOptions.v1"

    /// Undo of what only the workspace can reverse: a snooze, an archive. They get the ids that were recorded.
    var undoSnooze: (([String]) -> Void)?
    var undoArchive: (([String]) -> Void)?
    /// Settling a session that still reads as busy also ends that turn where the session lives; it gets the ids.
    var settleBusy: (([String]) -> Void)?
    /// After sessions settled: their terminals and project scripts get tidied (`AppModel.applySettleActions`).
    var settled: (([AgentListItem]) -> Void)?

    private let defaults: UserDefaults
    private static let key = "agents.inbox.v1"

    private struct Stored: Codable {
        var state: InboxState?
        var showWorking: Bool?
        var autoSettle: AutoSettlePolicy.Settings?
        var groupByProject: Bool?
        var collapsedProjects: Set<String>?
        var collapsedShelves: Set<InboxSection.Kind>?
        var foldedThreads: [String]?
        var openedThreads: [String]?
        /// Fields that were there but could not be read (not stored).
        var skipped = 0

        /// `groupByProject` is stored as "projectFolders": the old key held a default of on, from before the list became one
        /// inbox, and is not read again.
        private enum CodingKeys: String, CodingKey {
            case state, showWorking, autoSettle, collapsedProjects, collapsedShelves, foldedThreads, openedThreads
            case groupByProject = "projectFolders"
        }

        init(state: InboxState?, showWorking: Bool?, autoSettle: AutoSettlePolicy.Settings?, groupByProject: Bool?,
             collapsedProjects: Set<String>?, collapsedShelves: Set<InboxSection.Kind>?, foldedThreads: [String]?,
             openedThreads: [String]?) {
            self.state = state
            self.showWorking = showWorking
            self.autoSettle = autoSettle
            self.groupByProject = groupByProject
            self.collapsedProjects = collapsedProjects
            self.collapsedShelves = collapsedShelves
            self.foldedThreads = foldedThreads
            self.openedThreads = openedThreads
        }

        /// Field by field: one a later Nook wrote differently falls back to its default instead of taking the rest along.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var skipped = 0
            func field<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
                guard container.contains(key) else { return nil }
                do { return try container.decodeIfPresent(type, forKey: key) } catch { skipped += 1; return nil }
            }
            state = field(InboxState.self, .state)
            showWorking = field(Bool.self, .showWorking)
            autoSettle = field(AutoSettlePolicy.Settings.self, .autoSettle)
            groupByProject = field(Bool.self, .groupByProject)
            collapsedProjects = field(Set<String>.self, .collapsedProjects)
            collapsedShelves = field(Set<InboxSection.Kind>.self, .collapsedShelves)
            foldedThreads = field([String].self, .foldedThreads)
            openedThreads = field([String].self, .openedThreads)
            self.skipped = skipped
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Kept aside first when something in it cannot be read (`SafeStorage`), so a later save never loses it for good.
        let outcome = SafeStorage.decode(Stored.self, defaults: defaults, key: Self.key, skipped: { $0.skipped })
        let stored = outcome.value
        state = stored?.state ?? InboxState()
        showWorking = stored?.showWorking ?? true
        // The first trace an earlier Nook left (`FinishedSessions` writes it on its first launch): an install that has it
        // keeps auto-settle as it was, a new one starts with it on.
        let usedSince = defaults.object(forKey: Self.usedSinceKey) as? Date
        autoSettle = AutoSettlePolicy.initial(stored: stored?.autoSettle, usedSince: usedSince)
        groupByProject = stored?.groupByProject ?? false
        collapsedProjects = stored?.collapsedProjects ?? []
        collapsedShelves = stored?.collapsedShelves ?? [.snoozed, .settled]
        foldedThreads = Set(stored?.foldedThreads ?? [])
        openedThreads = Set(stored?.openedThreads ?? [])
        let options = SafeStorage.decode(LossyArray<SnoozeOption>.self, defaults: defaults, key: Self.snoozeOptionsKey,
                                         skipped: { $0.skipped }).value?.elements
        snoozeOptions = SnoozeOption.cleaned(options ?? SnoozeOption.defaults)
        // The choice is kept, so a later launch reads it instead of guessing again. Never over a state that could not be
        // read at all: that one stays as it is until the user changes something.
        var unreadable = false
        if case .unreadable = outcome { unreadable = true }
        if stored?.autoSettle == nil, !unreadable { save() }
    }

    /// `FinishedSessions.keepsOpenSince`: when this Mac first ran a Nook with an Agents list.
    private static let usedSinceKey = "agents.keepsUnsettledSince"

    private func save() {
        let stored = Stored(state: state, showWorking: showWorking, autoSettle: autoSettle,
                            groupByProject: groupByProject, collapsedProjects: collapsedProjects,
                            collapsedShelves: collapsedShelves,
                            foldedThreads: Array(foldedThreads), openedThreads: Array(openedThreads))
        defaults.setEncoded(stored, forKey: Self.key)
    }

    /// Folds or opens a shelf of the list.
    func setShelf(_ kind: InboxSection.Kind, collapsed: Bool) {
        if collapsed { collapsedShelves.insert(kind) } else { collapsedShelves.remove(kind) }
        save()
    }

    /// The most thread choices kept; past it the oldest sessions' choices go (they long left the list).
    private static let threadChoices = 300

    /// Folds or opens the sub-threads under a session in the list, and keeps that choice.
    func setThread(_ id: String, open: Bool) {
        if open {
            foldedThreads.remove(id)
            openedThreads.insert(id)
        } else {
            openedThreads.remove(id)
            foldedThreads.insert(id)
        }
        // A set has no age: trimming drops arbitrary old choices, which only brings those sessions back to the default.
        if foldedThreads.count > Self.threadChoices { foldedThreads = Set(foldedThreads.prefix(Self.threadChoices / 2)) }
        if openedThreads.count > Self.threadChoices { openedThreads = Set(openedThreads.prefix(Self.threadChoices / 2)) }
        save()
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
        if !items.isEmpty { settled?(items) }
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
        case .settled, .autoSettled: for key in entry.ids { FinishedSessions.shared.reopenByUser(key) }
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
    func autoSettleCandidates(rows: [InboxRow], pullRequest: (String) -> AutoSettlePolicy.PullRequestState,
                              now: Date = Date()) -> [String] {
        guard autoSettle.enabled else { return [] }
        return rows.compactMap { row in
            if case .settle = AutoSettlePolicy.decide(row: row, pullRequest: pullRequest(row.id), settings: autoSettle, now: now) {
                return row.id
            }
            return nil
        }
    }
}
