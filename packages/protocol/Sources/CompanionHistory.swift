import Foundation

// Older sessions on the phone (docs/COMPANION.md, "Older sessions and search"). The live list holds the newest
// `liveCount` sessions; `CompanionOp.history` pages through the ones after them, newest first, and searches all of them
// by words. A page ends at a cursor (the last session's time and id), so a session that moves to the top in between
// shifts no page. Foundation only, tested on its own.

enum CompanionHistory {
    /// The newest sessions the live list (`list`, `subscribe`) holds.
    static let liveCount = 25
    /// Sessions in one page of `history`.
    static let pageSize = 25
    /// The longest search the Mac takes; anything longer is cut.
    static let maxQuery = 200

    /// Where a page ends: the last session's time (seconds since 1970) and id.
    struct Cursor: Equatable, Sendable {
        var updated: Double
        var id: String

        var text: String { String(format: "%.6f", updated) + "|" + id }

        init(updated: Double, id: String) { self.updated = updated; self.id = id }

        init?(_ text: String?) {
            guard let text, let bar = text.firstIndex(of: "|"), let updated = Double(text[..<bar]), updated.isFinite else { return nil }
            self.updated = updated
            self.id = String(text[text.index(after: bar)...])
        }

        /// Whether a session with `updated` and `id` comes after this one, newest first.
        func precedes(updated other: Double, id otherID: String) -> Bool {
            other < updated || (other == updated && otherID > id)
        }
    }

    /// The words of a search, cleaned: no control characters, at most `maxQuery` characters; empty for none.
    static func clean(_ query: String?) -> String {
        let kept = (query ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQuery))
    }

    /// Whether every word of `query` is found in one of `fields`, ignoring case and accents; true for no words.
    static func matches(_ query: String, _ fields: [String]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { word in
            fields.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// One page of `items` (newest first, by `updated`, then by `id`), after `cursor` (nil: from the start): at most
    /// `limit` items, and the cursor of the next page while there are more.
    static func page<Item>(_ items: [Item], updated: (Item) -> Double, id: (Item) -> String, after cursor: String?,
                           limit: Int = pageSize) -> (items: [Item], cursor: String?) {
        let sorted = items.sorted { a, b in
            let (ua, ub) = (updated(a), updated(b))
            return ua != ub ? ua > ub : id(a) < id(b)
        }
        let start = Cursor(cursor)
        let rest = start.map { start in sorted.filter { start.precedes(updated: updated($0), id: id($0)) } } ?? sorted
        let page = Array(rest.prefix(max(1, limit)))
        guard rest.count > page.count, let last = page.last else { return (page, nil) }
        return (page, Cursor(updated: updated(last), id: id(last)).text)
    }

    /// Older sessions as the phone shows them under the live list: without the ones the live list has (it is newer),
    /// each once, newest first.
    static func merge(live: [SessionDigest], older: [SessionDigest]) -> [SessionDigest] {
        var seen = Set(live.map(\.id))
        return older.filter { seen.insert($0.id).inserted }.sorted { $0.updated > $1.updated }
    }
}
