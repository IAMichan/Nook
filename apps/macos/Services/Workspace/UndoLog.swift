import Foundation

// The one-line "3 sessions settled · ⌘Z" notice. Here the
// decision lives in a value so the list and the composer line show the same entry. Foundation only.

struct UndoEntry: Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case settled, snoozed, unsettled, pinned, unpinned, archived, discarded }
    var kind: Kind
    var ids: [String]
    /// Time of the latest action merged into this entry: the 5 s window runs from it.
    var createdAt: Date

    var count: Int { ids.count }
    /// i18n key with the count as argument; `one`/`other` because the plural differs per language.
    var messageKey: String { "undo.\(kind.rawValue).\(count == 1 ? "one" : "other")" }
}

struct UndoLog: Equatable, Sendable {
    static let window: TimeInterval = 5

    private(set) var entries: [UndoEntry] = []

    /// Same kind as the live top entry merges into it, and restarts its window.
    mutating func record(_ kind: UndoEntry.Kind, ids: [String], now: Date) {
        prune(now)
        let ids = ids.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard !ids.isEmpty else { return }
        if var top = entries.last, top.kind == kind {
            top.ids += ids.filter { !top.ids.contains($0) }
            top.createdAt = now
            entries[entries.count - 1] = top
        } else {
            entries.append(UndoEntry(kind: kind, ids: ids, createdAt: now))
        }
    }

    /// The entry the notice shows; nil once it is 5 s old.
    func current(now: Date) -> UndoEntry? {
        entries.last { now.timeIntervalSince($0.createdAt) < Self.window }
    }

    /// Takes the current entry off the log. Nothing is undoable after expiry.
    mutating func undo(now: Date) -> UndoEntry? {
        prune(now)
        return entries.popLast()
    }

    private mutating func prune(_ now: Date) {
        entries.removeAll { now.timeIntervalSince($0.createdAt) >= Self.window }
    }
}
