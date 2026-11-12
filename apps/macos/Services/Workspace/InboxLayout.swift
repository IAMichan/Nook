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
    /// A usage limit stopped it at this moment (a snooze made after it stays, see `SnoozePolicy`).
    var limitedAt: Date? = nil
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
    /// The session this one was started from (a delegated or forked session, a task another session spawned).
    var parentID: String? = nil
    /// When you last brought it back from Settled (Reopen, or undoing a settle): until it has new activity after that, it
    /// does not settle by itself again (`AutoSettlePolicy`).
    var unsettledAt: Date? = nil

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
    /// When you gave each row of `order` its place. As in t3code, a place holds only until the session comes back with
    /// something new (`InboxRow.lastActivity` after it): then it is unordered again and comes up on top of the list.
    /// A row in `order` without a time keeps its place.
    var orderedAt: [String: Date] = [:]
    var settled: Set<String> = []
    var dismissedWoke: Set<String> = []

    init(pinned: [String] = [], order: [String] = [], orderedAt: [String: Date] = [:], settled: Set<String> = [],
         dismissedWoke: Set<String> = []) {
        self.pinned = pinned
        self.order = order
        self.orderedAt = orderedAt
        self.settled = settled
        self.dismissedWoke = dismissedWoke
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pinned = (try? c.decode([String].self, forKey: .pinned)) ?? []
        // An order saved before the places had times was the old fixed order: it is let go, so sessions that come back
        // rise to the top as they do now.
        let times = try? c.decode([String: Date].self, forKey: .orderedAt)
        order = times == nil ? [] : (try? c.decode([String].self, forKey: .order)) ?? []
        orderedAt = times ?? [:]
        settled = (try? c.decode(Set<String>.self, forKey: .settled)) ?? []
        dismissedWoke = (try? c.decode(Set<String>.self, forKey: .dismissedWoke)) ?? []
    }

    /// The manual place of a row in Active, or nil when it has none: never placed, or back with something new since.
    func activeRank(_ row: InboxRow, ranks: [String: Int]) -> Int? {
        guard let rank = ranks[row.id] else { return nil }
        if let placed = orderedAt[row.id], row.lastActivity > placed { return nil }
        return rank
    }

    /// Pins `id` at `index` (default: on top). Pinning removes nothing else; the layout lets a pin win over settled.
    mutating func pin(_ id: String, at index: Int? = nil) {
        pinned.removeAll { $0 == id }
        pinned.insert(id, at: min(max(index ?? 0, 0), pinned.count))
    }

    /// Unpins; `index` places it in the manual Active order where it was dropped.
    mutating func unpin(_ id: String, at index: Int? = nil, now: Date = Date()) {
        pinned.removeAll { $0 == id }
        guard let index else { return }
        order.removeAll { $0 == id }
        order.insert(id, at: min(max(index, 0), order.count))
        orderedAt[id] = now
    }

    /// Settling a pinned thread unpins it.
    mutating func settle(_ id: String) {
        settled.insert(id)
        pinned.removeAll { $0 == id }
    }

    mutating func unsettle(_ id: String) { settled.remove(id) }

    mutating func dismissWoke(_ id: String) { dismissedWoke.insert(id) }

    /// Moves `id` to `toIndex` (a final index) inside the section as it is shown.
    /// Only Pinned and Active have a manual order. Ids hidden from the section keep their relative place after it.
    mutating func reorder(_ id: String, toIndex: Int, within section: InboxSection, now: Date = Date()) {
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
            // Every row shown now has the place you see it in.
            for id in ids { orderedAt[id] = now }
            orderedAt = orderedAt.filter { order.contains($0.key) }
        }
    }
}

struct InboxEntry: Identifiable, Equatable, Sendable {
    var row: InboxRow
    /// Drawn quieter: nothing here asks for you.
    var receded: Bool
    /// Came back from a snooze and the user has not looked yet.
    var woke: Bool
    /// How far the row sits in under the session that started it: 0 for a session of its own.
    var depth = 0
    /// The sessions it sits under in the list, nearest first: folding any of them hides this row.
    var ancestors: [String] = []
    /// How many sessions sit under it in the list, at every level (its sub-threads).
    var subThreads = 0
    /// One of those waits for you, or works: a folded row still says so.
    var subThreadNeedsYou = false
    var subThreadActive = false
    var id: String { row.id }
}

/// The sessions of one project (a repository: an agent's worktree counts as the repository it was made from), drawn as a
/// dropdown when the list is grouped by project. The project "" holds the sessions without one (`InboxProject`).
struct InboxProjectGroup: Identifiable, Equatable, Sendable {
    /// What a folded project's dot says about the sessions in it, the most urgent first.
    enum Dot: Equatable, Sendable { case needsYou, failed, done, working }

    var project: String
    /// Each row with the section it comes from, so a drag and the row's actions keep working as in that section.
    var rows: [(kind: InboxSection.Kind, entry: InboxEntry)]
    /// Pinned by you: on top of the projects, and kept as a folder also when nothing in it is active.
    var pinned = false
    /// Archived (Settings › Projects): listed after the others, and only while something in it is active.
    var archived = false
    var id: String { project }
    /// Something in it waits for you: its folded header says so.
    var needsYou: Bool { rows.contains { $0.entry.row.needsYou } }

    /// Waits for you, else failed or stopped by a limit, else finished since you looked, else works; nil when all is quiet.
    var dot: Dot? {
        let rows = rows.map(\.entry.row)
        if rows.contains(where: \.needsYou) { return .needsYou }
        if rows.contains(where: { $0.attention == .failed || $0.attention == .limited }) { return .failed }
        if rows.contains(where: { $0.attention == .ready }) { return .done }
        if rows.contains(where: { $0.attention == .working || $0.isActive }) { return .working }
        return nil
    }

    static func == (a: Self, b: Self) -> Bool {
        a.project == b.project && a.pinned == b.pinned && a.archived == b.archived && a.rows.map(\.kind) == b.rows.map(\.kind)
            && a.rows.map(\.entry) == b.rows.map(\.entry)
    }
}

/// The project a session is listed under when the list is grouped by project. A session without a real project, one in
/// a folder Nook made for "No project" (`ScratchProjects`), in your home folder or without a folder, goes under "", one
/// group for all of them, instead of a folder of its own per session. Text only: it runs for every row on every redraw.
enum InboxProject {
    static let none = ""

    /// `folder` is the row's folder name (a worktree already named after its repository), `path` the folder it works in.
    static func key(folder: String, path: String, scratchRoot: String = NookPaths.scratchDirectory.path,
                    home: String = NSHomeDirectory()) -> String {
        if folder.isEmpty || folder == "no folder" { return none }
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !trimmed.isEmpty, trimmed != "/" else { return folder }
        let root = scratchRoot.hasSuffix("/") ? String(scratchRoot.dropLast()) : scratchRoot
        if trimmed == home || trimmed == root || trimmed.hasPrefix(root + "/") { return none }
        return folder
    }
}

struct InboxSection: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable, Codable { case pinned, active, working, snoozed, settled }
    var kind: Kind
    var rows: [InboxEntry]
    /// Settled paging: how many more rows "Show 10 more" would reveal.
    var hiddenCount = 0
}

enum InboxLayout {
    static let settledPage = 10

    typealias Kind = InboxSection.Kind

    /// Rows with each session's children right under it, in their own order, one step further in (at most two). A row whose
    /// parent is not in the list stays where it is, as a session of its own.
    static func nest(_ entries: [InboxEntry]) -> [InboxEntry] {
        let ids = Set(entries.map(\.id))
        var children: [String: [InboxEntry]] = [:]
        var roots: [InboxEntry] = []
        for entry in entries {
            if let parent = entry.row.parentID, parent != entry.id, ids.contains(parent) {
                children[parent, default: []].append(entry)
            } else {
                roots.append(entry)
            }
        }
        guard !children.isEmpty else { return entries }
        var result: [InboxEntry] = []
        var placed: Set<String> = []
        func place(_ entry: InboxEntry, depth: Int, ancestors: [String]) {
            guard placed.insert(entry.id).inserted else { return }
            var entry = entry
            // Deeper threads stay at the second step, so a long chain keeps the name readable; `ancestors` keeps the real tree.
            entry.depth = min(depth, 2)
            entry.ancestors = ancestors
            result.append(entry)
            for child in children[entry.id] ?? [] { place(child, depth: depth + 1, ancestors: [entry.id] + ancestors) }
        }
        for root in roots { place(root, depth: 0, ancestors: []) }
        // A loop of parents has no root: its rows keep their place.
        for entry in entries where !placed.contains(entry.id) { place(entry, depth: 0, ancestors: []) }
        // What each session holds under it: the count on its fold, and whether something in there works or waits for you.
        let index = Dictionary(result.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in result {
            let active = entry.row.isActive || entry.row.attention == .working
            for ancestor in entry.ancestors {
                guard let at = index[ancestor] else { continue }
                result[at].subThreads += 1
                result[at].subThreadNeedsYou = result[at].subThreadNeedsYou || entry.row.needsYou
                result[at].subThreadActive = result[at].subThreadActive || active
            }
        }
        return result
    }

    /// Whether a session's sub-threads show under it. What you chose wins; otherwise they show while one of them works or
    /// waits for you, and fold away once they are all quiet.
    static func threadOpen(_ entry: InboxEntry, opened: Set<String>, folded: Set<String>) -> Bool {
        if folded.contains(entry.id) { return false }
        if opened.contains(entry.id) { return true }
        return entry.subThreadActive || entry.subThreadNeedsYou
    }

    /// The rows left once folded threads are put away: a row under a folded session is hidden, except the one that is
    /// open on the right, so the session you look at never vanishes from the list.
    static func foldThreads(_ entries: [InboxEntry], isOpen: (InboxEntry) -> Bool, selectedID: String?) -> [InboxEntry] {
        let folded = Set(entries.filter { $0.subThreads > 0 && !isOpen($0) }.map(\.id))
        guard !folded.isEmpty else { return entries }
        return entries.filter { entry in entry.id == selectedID || !entry.ancestors.contains(where: folded.contains) }
    }

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
                                                finishedAt: row.lastActivity, limitedAt: row.limitedAt, now: now)
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

        // A thread that waits for you sits in Active as a whole: a session at work on the Working shelf comes up with the
        // sub-thread that asks, so that one can sit under it instead of on its own.
        let parentOf = Dictionary(rows.compactMap { row in row.parentID.map { (row.id, $0) } }, uniquingKeysWith: { first, _ in first })
        let workingIDs = Set(working.map(\.id))
        var lifted: Set<String> = []
        for entry in active where entry.row.needsYou {
            var seen: Set<String> = [entry.id]
            var parent = entry.row.parentID
            while let id = parent, workingIDs.contains(id), seen.insert(id).inserted {
                lifted.insert(id)
                parent = parentOf[id]
            }
        }
        if !lifted.isEmpty {
            active += working.filter { lifted.contains($0.id) }
            working.removeAll { lifted.contains($0.id) }
        }

        pinned.sort { (pinRank[$0.id] ?? Int.max, $1.row.lastActivity, $0.id) < (pinRank[$1.id] ?? Int.max, $0.row.lastActivity, $1.id) }
        // As t3code's inbox: what needs you first, then the sessions that came back (finished, failed, a new message) with
        // the newest on top, then the ones you gave a place, in that order. A placed session that comes back with something
        // new loses its place and rises to the top again.
        active.sort {
            let (needsA, needsB) = ($0.row.needsYou, $1.row.needsYou)
            if needsA != needsB { return needsA }
            switch (state.activeRank($0.row, ranks: orderRank), state.activeRank($1.row, ranks: orderRank)) {
            case (nil, _?): return true
            case (_?, nil): return false
            case let (a?, b?) where a != b: return a < b
            default: break
            }
            if $0.row.lastActivity != $1.row.lastActivity { return $0.row.lastActivity > $1.row.lastActivity }
            return $0.id < $1.id
        }
        working.sort(by: newestFirst)
        snoozed.sort {
            let (a, b) = ($0.row.snoozedUntil ?? .distantFuture, $1.row.snoozedUntil ?? .distantFuture)
            return a != b ? a < b : $0.id < $1.id
        }
        settled.sort(by: newestFirst)

        // A session started from another one that is running or open follows it into its section, so it sits under it and
        // never also as a session of its own; one that is pinned, snoozed or settled stays where it is. One that needs you
        // never goes onto the Working shelf (its parent came up to Active above), and a pinned parent is always in view.
        var home: [String: Kind] = [:]
        for entry in active { home[entry.id] = .active }
        for entry in working { home[entry.id] = .working }
        for entry in pinned { home[entry.id] = .pinned }
        // Settled a step at a time, so a sub-thread of a sub-thread follows too, wherever the chain ends up.
        let candidates = working + active
        var moved: [String: Kind] = [:]
        for _ in 0..<candidates.count {
            var changed = false
            for entry in candidates {
                guard let parent = entry.row.parentID, parent != entry.id, let target = home[parent], target != home[entry.id],
                      !(entry.row.needsYou && target == .working) else { continue }
                home[entry.id] = target
                moved[entry.id] = target
                changed = true
            }
            if !changed { break }
        }
        if !moved.isEmpty {
            working.removeAll { moved[$0.id] != nil }
            active.removeAll { moved[$0.id] != nil }
            for entry in candidates {
                switch moved[entry.id] {
                case .pinned?: pinned.append(entry)
                case .working?: working.append(entry)
                case .active?: active.append(entry)
                default: break
                }
            }
        }
        pinned = nest(pinned)
        working = nest(working)
        active = nest(active)
        snoozed = nest(snoozed)
        settled = nest(settled)

        let limit = max(0, settledLimit)
        // The open session stays on the settled page even when it is further down than the page reaches.
        var settledPage = Array(settled.prefix(limit))
        if let open = settled.dropFirst(limit).first(where: { $0.id == selectedID }) { settledPage.append(open) }
        var result: [InboxSection] = [
            InboxSection(kind: .pinned, rows: pinned),
            InboxSection(kind: .active, rows: active),
            // As in t3code: what works and needs nothing from you sits at the foot of the list, above Snoozed and Settled.
            // A session that finishes leaves it and comes up on top of Active.
            InboxSection(kind: .working, rows: working),
            InboxSection(kind: .snoozed, rows: snoozed),
            InboxSection(kind: .settled, rows: settledPage, hiddenCount: settled.count - settledPage.count),
        ]
        result.removeAll { $0.rows.isEmpty }
        return result
    }

    /// Where "Move Up" or "Move Down" puts a row of Pinned or Active: the final index (for `InboxState.reorder`) of the
    /// nearest row in that direction it can trade places with, or nil when there is none. Only top-level rows move,
    /// since a nested one follows its parent; in Active what needs you sorts first, so a row only moves among rows that
    /// need you, or among rows that do not.
    static func moveTarget(_ id: String, up: Bool, in section: InboxSection) -> Int? {
        guard section.kind == .pinned || section.kind == .active,
              let from = section.rows.firstIndex(where: { $0.id == id }), section.rows[from].depth == 0 else { return nil }
        let row = section.rows[from].row
        let candidates = up ? Array((0..<from).reversed()) : Array((from + 1)..<section.rows.count)
        return candidates.first { index in
            let other = section.rows[index]
            return other.depth == 0 && (section.kind == .pinned || other.row.needsYou == row.needsYou)
        }
    }

    /// The Active rows per project. Pinned projects come first, in the order you pinned them, and keep their folder also
    /// when nothing in them is active; the rest keep a fixed place (by name), so activity in one never moves the whole
    /// folder, with the sessions without a project and then the archived projects last. Inside a project the session with the newest activity comes first, with the sessions it started still
    /// right under it. Pinned sessions, the Working shelf (when it is on) and snoozed and settled sessions keep their own
    /// sections; with the Working shelf off, working sessions are Active and sit in their project.
    static func projectGroups(_ sections: [InboxSection], pinned: [String] = [],
                              archived: Set<String> = []) -> [InboxProjectGroup] {
        var groups: [String: InboxProjectGroup] = [:]
        var order: [String] = []
        for project in pinned where groups[project] == nil && !archived.contains(project) {
            groups[project] = InboxProjectGroup(project: project, rows: [], pinned: true)
            order.append(project)
        }
        for section in sections where section.kind == .active {
            for entry in section.rows {
                let project = entry.row.project
                if groups[project] == nil {
                    groups[project] = InboxProjectGroup(project: project, rows: [])
                    order.append(project)
                }
                groups[project]?.rows.append((section.kind, entry))
            }
        }
        return order.compactMap { groups[$0] }
            .map { group in
                var group = group
                group.rows = newestOnTop(group.rows)
                group.archived = !group.pinned && archived.contains(group.project)
                return group
            }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                if a.archived != b.archived { return b.archived }
                if a.pinned { return pinned.firstIndex(of: a.project) ?? 0 < pinned.firstIndex(of: b.project) ?? 0 }
                // Sessions without a project come after the named projects.
                if (a.project == InboxProject.none) != (b.project == InboxProject.none) { return b.project == InboxProject.none }
                let compared = a.project.localizedStandardCompare(b.project)
                return compared != .orderedSame ? compared == .orderedAscending : a.project < b.project
            }
    }

    /// A project's rows with the most recently active session on top. A session and the ones nested under it move as
    /// one block, ordered by the newest activity in it; blocks with the same time keep their order.
    private static func newestOnTop(_ rows: [(kind: Kind, entry: InboxEntry)]) -> [(kind: Kind, entry: InboxEntry)] {
        var blocks: [[(kind: Kind, entry: InboxEntry)]] = []
        for row in rows {
            if row.entry.depth > 0, !blocks.isEmpty { blocks[blocks.count - 1].append(row) } else { blocks.append([row]) }
        }
        func newest(_ block: [(kind: Kind, entry: InboxEntry)]) -> Date {
            block.map(\.entry.row.lastActivity).max() ?? .distantPast
        }
        return blocks.enumerated()
            .sorted { a, b in
                let (na, nb) = (newest(a.element), newest(b.element))
                return na != nb ? na > nb : a.offset < b.offset
            }
            .flatMap(\.element)
    }

    /// The rows a shelf draws: all of them while it is open. Folded, a shelf shows only the session that is open on the
    /// right, so the session you look at never vanishes from the list; the settled shelf shows none, since a settled
    /// row would otherwise float above its closed header.
    static func shownRows(_ section: InboxSection, folded: Bool, selectedID: String?) -> [InboxEntry] {
        guard folded else { return section.rows }
        return section.kind == .settled ? [] : section.rows.filter { $0.id == selectedID }
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
