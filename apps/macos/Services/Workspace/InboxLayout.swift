import Foundation

// The Agents list as sections: pure decisions about which row sits where,
// what a drag does, and what the search matches. The view only draws what comes back. Foundation only.

/// One session as the list needs to see it; the lead builds it from WorkspaceRun + attention.
struct InboxRow: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var project: String
    var attention: AgentAttention
    var pinned = false
    var settled = false
    var snoozedUntil: Date?
    var snoozedAt: Date?
    /// The user already saw (and dismissed) the "woke up" marker.
    var wokeDismissed = false
    var lastActivity: Date
    /// An approval or question waits: such a row is never hidden, whatever its flags say.
    var hasOpenRequest = false
    var hasBackgroundWork = false
    var hasQueued = false
    /// A turn is running.
    var isActive = false
    /// Changed since the user last looked. Defaults to true so nothing recedes by accident.
    var unread = true

    /// Needs you, from either source: the derived attention or a raw request flag.
    var needsYou: Bool { hasOpenRequest || attention.needsYou }

    /// A raw open request counts as approval even when the derived attention lags behind.
    var effectiveAttention: AgentAttention { hasOpenRequest && !attention.needsYou ? .approval : attention }
}

/// What the user decided about the list: stored, so it survives a restart. Every field is optional on decode.
struct InboxState: Codable, Equatable, Sendable {
    /// Pinned ids; the array order is the user's order.
    var pinned: [String] = []
    /// Manual order of the Active section (ids that are gone are harmless).
    var order: [String] = []
    var settled: Set<String> = []
    var dismissedWoke: Set<String> = []

    init(pinned: [String] = [], order: [String] = [], settled: Set<String> = [], dismissedWoke: Set<String> = []) {
        self.pinned = pinned
        self.order = order
        self.settled = settled
        self.dismissedWoke = dismissedWoke
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pinned = (try? c.decode([String].self, forKey: .pinned)) ?? []
        order = (try? c.decode([String].self, forKey: .order)) ?? []
        settled = (try? c.decode(Set<String>.self, forKey: .settled)) ?? []
        dismissedWoke = (try? c.decode(Set<String>.self, forKey: .dismissedWoke)) ?? []
    }

    /// Pins `id` at `index` (default: on top). Pinning removes nothing else; the layout lets a pin win over settled.
    mutating func pin(_ id: String, at index: Int? = nil) {
        pinned.removeAll { $0 == id }
        pinned.insert(id, at: min(max(index ?? 0, 0), pinned.count))
    }

    /// Unpins; `index` places it in the manual Active order where it was dropped.
    mutating func unpin(_ id: String, at index: Int? = nil) {
        pinned.removeAll { $0 == id }
        guard let index else { return }
        order.removeAll { $0 == id }
        order.insert(id, at: min(max(index, 0), order.count))
    }

    /// Settling a pinned thread unpins it.
    mutating func settle(_ id: String) {
        settled.insert(id)
        pinned.removeAll { $0 == id }
    }

    mutating func unsettle(_ id: String) { settled.remove(id) }

    mutating func dismissWoke(_ id: String) { dismissedWoke.insert(id) }

    /// Moves `id` to `toIndex` (a final index, see `InboxDrop.reorderTarget`) inside the section as it is shown.
    /// Only Pinned and Active have a manual order. Ids hidden from the section keep their relative place after it.
    mutating func reorder(_ id: String, toIndex: Int, within section: InboxSection) {
        guard section.kind == .pinned || section.kind == .active else { return }
        var ids = section.rows.map(\.row.id)
        guard let from = ids.firstIndex(of: id) else { return }
        ids.remove(at: from)
        ids.insert(id, at: min(max(toIndex, 0), ids.count))
        let rest: [String]
        switch section.kind {
        case .pinned:
            rest = pinned.filter { !ids.contains($0) }
            pinned = ids + rest
        default:
            rest = order.filter { !ids.contains($0) }
            order = ids + rest
        }
    }
}

struct InboxEntry: Identifiable, Equatable, Sendable {
    var row: InboxRow
    /// Drawn quieter: nothing here asks for you.
    var receded: Bool
    /// Came back from a snooze and the user has not looked yet.
    var woke: Bool
    var id: String { row.id }
}

struct InboxSection: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case pinned, active, working, snoozed, settled }
    var kind: Kind
    var rows: [InboxEntry]
    /// Settled paging: how many more rows "Show 10 more" would reveal.
    var hiddenCount = 0
}

enum InboxLayout {
    static let settledPage = 10

    /// Sections in display order; empty ones are left out. Every row lands in exactly one section.
    static func sections(rows: [InboxRow], state: InboxState, showWorking: Bool, now: Date,
                         settledLimit: Int = settledPage, selectedID: String? = nil) -> [InboxSection] {
        var pinned: [InboxEntry] = [], active: [InboxEntry] = [], working: [InboxEntry] = []
        var snoozed: [InboxEntry] = [], settled: [InboxEntry] = []
        let pinRank = Dictionary(state.pinned.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let orderRank = Dictionary(state.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

        for row in rows {
            let isPinned = row.pinned || pinRank[row.id] != nil
            let isSettled = row.settled || state.settled.contains(row.id)
            let dismissed = row.wokeDismissed || state.dismissedWoke.contains(row.id)
            let attention = row.effectiveAttention
            let hidden = SnoozePolicy.isSnoozed(until: row.snoozedUntil, since: row.snoozedAt, attention: attention,
                                                finishedAt: row.lastActivity, now: now)
            let woke = row.snoozedUntil != nil && !hidden && !dismissed

            func entry(_ woke: Bool = false) -> InboxEntry {
                InboxEntry(row: row, receded: receded(row, woke: woke, selected: row.id == selectedID), woke: woke)
            }

            if isPinned {
                pinned.append(entry(woke))
            } else if isSettled && !row.needsYou {
                // What waits for you is never hidden (AgentAttention.resolve), settled or not.
                settled.append(entry())
            } else if hidden {
                snoozed.append(entry())
            } else if showWorking && !row.needsYou && isWorking(row) {
                working.append(entry())
            } else {
                active.append(entry(woke))
            }
        }

        pinned.sort { (pinRank[$0.id] ?? Int.max, $1.row.lastActivity, $0.id) < (pinRank[$1.id] ?? Int.max, $0.row.lastActivity, $1.id) }
        active.sort {
            if $0.row.effectiveAttention != $1.row.effectiveAttention { return $0.row.effectiveAttention < $1.row.effectiveAttention }
            let (a, b) = (orderRank[$0.id] ?? Int.max, orderRank[$1.id] ?? Int.max)
            if a != b { return a < b }
            if $0.row.lastActivity != $1.row.lastActivity { return $0.row.lastActivity > $1.row.lastActivity }
            return $0.id < $1.id
        }
        working.sort(by: newestFirst)
        snoozed.sort {
            let (a, b) = ($0.row.snoozedUntil ?? .distantFuture, $1.row.snoozedUntil ?? .distantFuture)
            return a != b ? a < b : $0.id < $1.id
        }
        settled.sort(by: newestFirst)

        let limit = max(0, settledLimit)
        var result: [InboxSection] = [
            // Running agents come first: they are the ones you usually want to open.
            InboxSection(kind: .working, rows: working),
            InboxSection(kind: .pinned, rows: pinned),
            InboxSection(kind: .active, rows: active),
            InboxSection(kind: .snoozed, rows: snoozed),
            InboxSection(kind: .settled, rows: Array(settled.prefix(limit)), hiddenCount: max(0, settled.count - limit)),
        ]
        result.removeAll { $0.rows.isEmpty }
        return result
    }

    /// A row on the Working shelf: busy, or waiting on background work, without needing a person.
    private static func isWorking(_ row: InboxRow) -> Bool {
        switch row.attention {
        case .working: return true
        case .failed, .limited: return false
        default: return row.hasBackgroundWork
        }
    }

    private static func newestFirst(_ a: InboxEntry, _ b: InboxEntry) -> Bool {
        a.row.lastActivity != b.row.lastActivity ? a.row.lastActivity > b.row.lastActivity : a.id < b.id
    }

    /// The selected row and a question never recede; work in progress always does;
    /// a finished or approval row only once it was read and did not just wake from a snooze.
    static func receded(_ row: InboxRow, woke: Bool, selected: Bool) -> Bool {
        if selected || row.attention == .input { return false }
        if row.attention == .working || (row.hasBackgroundWork && !row.needsYou) { return true }
        if row.attention == .ready || row.attention == .approval { return !row.unread && !woke }
        return false
    }
}

/// What dropping a row on a section does (docs/user/thread-sidebar.md).
enum InboxDrop {
    enum Reason: String, Equatable, Sendable {
        /// Snoozing needs a wake time, so a drop cannot do it.
        case needsTime
        /// The Working shelf is derived from what the agent is doing.
        case automatic
        case notReorderable
    }

    enum DropResult: Equatable, Sendable {
        case pin, unpin, settle, unsettle, wake
        /// Same section, Pinned or Active: only the order changes.
        case reorder
        case rejected(Reason)

        /// Drag-ghost label (i18n key); nil when the drop shows no badge.
        var labelKey: String? {
            switch self {
            case .pin: return "inbox.drop.pin"
            case .unpin: return "inbox.drop.unpin"
            case .settle: return "inbox.drop.settle"
            case .unsettle: return "inbox.drop.unsettle"
            case .wake: return "inbox.drop.wake"
            case .reorder: return nil
            case .rejected(let reason): return "inbox.drop.\(reason.rawValue)"
            }
        }
    }

    static func decide(row: InboxRow, from: InboxSection.Kind, to: InboxSection.Kind) -> DropResult {
        if from == to {
            return from == .pinned || from == .active ? .reorder : .rejected(from == .snoozed ? .needsTime : .notReorderable)
        }
        switch to {
        case .snoozed: return .rejected(.needsTime)
        case .working: return .rejected(.automatic)
        case .pinned: return row.pinned && from != .pinned ? .reorder : .pin
        case .settled: return .settle
        case .active:
            switch from {
            case .pinned: return .unpin
            case .settled: return .unsettle
            case .snoozed: return .wake
            case .working: return .rejected(.automatic)
            case .active: return .reorder
            }
        }
    }

    /// Insertion gap (0...count, before the dragged row is taken out) to the final index; nil when nothing moves.
    static func reorderTarget(ids: [String], dragged: String, gap: Int) -> Int? {
        guard let from = ids.firstIndex(of: dragged) else { return nil }
        let clamped = min(max(gap, 0), ids.count)
        let to = clamped > from ? clamped - 1 : clamped
        return to == from ? nil : to
    }
}

enum InboxSearch {
    /// Message search starts at this many characters; titles match from the first.
    static let minimumMessageQueryLength = 2

    static func searchesMessages(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumMessageQueryLength
    }

    /// Every whitespace-separated token must occur in title or project, ignoring case and diacritics.
    static func filter(rows: [InboxRow], query: String) -> [InboxRow] {
        let tokens = fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return rows }
        return rows.filter { row in
            let haystack = fold(row.title + " " + row.project)
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
