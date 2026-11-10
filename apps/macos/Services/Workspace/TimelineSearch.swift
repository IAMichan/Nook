import Foundation

// "Find in session" over the timeline. Matching is case- and diacritic-insensitive and the
// query is literal text, never a pattern. Ranges are UTF-16 offsets so SwiftUI/NSString highlighting can use them.

struct TimelineSearchResult: Equatable, Sendable {
    enum State: Equatable, Sendable { case idle, searching, results, noResults, failed }
    enum Field: String, Equatable, Sendable { case text, detail, output }

    struct Match: Equatable, Sendable {
        var eventID: UUID
        var field: Field
        var range: Range<Int>
    }

    var state: State
    var matches: [Match]

    static let idle = TimelineSearchResult(state: .idle, matches: [])
    static let searching = TimelineSearchResult(state: .searching, matches: [])
    static let failed = TimelineSearchResult(state: .failed, matches: [])

    /// "3/12" with `current` as the 0-based index of the selected match.
    func countLabel(current: Int?) -> String {
        guard !matches.isEmpty else { return "0/0" }
        guard let current, matches.indices.contains(current) else { return "0/\(matches.count)" }
        return "\(current + 1)/\(matches.count)"
    }

    func next(after index: Int?, wrap: Bool = true) -> Int? {
        guard !matches.isEmpty else { return nil }
        guard let index else { return 0 }
        if index + 1 < matches.count { return index + 1 }
        return wrap ? 0 : nil
    }

    func previous(before index: Int?, wrap: Bool = true) -> Int? {
        guard !matches.isEmpty else { return nil }
        guard let index else { return matches.count - 1 }
        if index > 0 { return index - 1 }
        return wrap ? matches.count - 1 : nil
    }

    /// Containers (group, plan, fold) that must open so the matches are visible. `containers` maps an event id to the
    /// id of what hides it; events not in it are always visible.
    func revealTargets(containers: [UUID: UUID]) -> Set<UUID> {
        Set(matches.compactMap { containers[$0.eventID] })
    }
}

enum TimelineSearch {
    static let maxQueryLength = 500

    static func search(_ events: [RunEvent], query: String, includeThinking: Bool = false) -> TimelineSearchResult {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .idle }
        guard query.utf16.count <= maxQueryLength else { return .failed }
        var matches: [TimelineSearchResult.Match] = []
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        for event in events where includeThinking || event.kind != .thinking {
            let fields: [(TimelineSearchResult.Field, String?)] = [(.text, event.text), (.detail, event.detail), (.output, event.output)]
            for (field, value) in fields {
                guard let value, !value.isEmpty else { continue }
                let ns = value as NSString
                var from = 0
                while from < ns.length {
                    let found = ns.range(of: query, options: options, range: NSRange(location: from, length: ns.length - from))
                    guard found.location != NSNotFound, found.length > 0 else { break }
                    matches.append(.init(eventID: event.id, field: field, range: found.location..<(found.location + found.length)))
                    from = found.location + found.length
                }
            }
        }
        return TimelineSearchResult(state: matches.isEmpty ? .noResults : .results, matches: matches)
    }
}

/// "Find in conversation" (⌘F) over a transcript read from the agent's own files (`TranscriptConversation`, a session
/// that runs outside Nook). Searches what was said: your messages, the agent's answers and notices
/// find does; not the steps between them. Matching is the same as `TimelineSearch`: literal, case- and
/// diacritic-insensitive.
enum TranscriptSearch {
    struct Match: Equatable, Sendable {
        /// The row the match is in, also when it sits inside a fold: that is where the view scrolls to.
        var rowID: String
        /// The folds around the row, outermost first, which open so the match can be seen (their row ids).
        var containers: [String]
    }

    struct Result: Equatable, Sendable {
        var state: TimelineSearchResult.State
        var matches: [Match]

        static let idle = Result(state: .idle, matches: [])

        /// The match after `index` (the first when none is chosen), round to the first after the last.
        func next(after index: Int?) -> Int? {
            guard !matches.isEmpty else { return nil }
            return index.map { ($0 + 1) % matches.count } ?? 0
        }

        /// The match before `index` (the last when none is chosen), round to the last before the first.
        func previous(before index: Int?) -> Int? {
            guard !matches.isEmpty else { return nil }
            return index.map { ($0 + matches.count - 1) % matches.count } ?? matches.count - 1
        }
    }

    static func search(_ rows: [TranscriptRow], query: String) -> Result {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .idle }
        guard query.utf16.count <= TimelineSearch.maxQueryLength else { return Result(state: .failed, matches: []) }
        var matches: [Match] = []
        func walk(_ rows: [TranscriptRow], inside: [String]) {
            for row in rows {
                switch row {
                case .user(let message), .assistant(let message, _), .notice(let message):
                    let count = occurrences(of: query, in: message.text)
                    matches += Array(repeating: Match(rowID: row.id, containers: inside), count: count)
                case .fold(_, _, let inner), .continued(_, _, let inner), .superseded(_, let inner):
                    walk(inner, inside: inside + [row.id])
                case .thinking, .step, .group, .working, .live, .interrupted:
                    break
                }
            }
        }
        walk(rows, inside: [])
        return Result(state: matches.isEmpty ? .noResults : .results, matches: matches)
    }

    /// How often `query` occurs in `text`, without overlaps.
    static func occurrences(of query: String, in text: String) -> Int {
        let ns = text as NSString
        var from = 0, count = 0
        while from < ns.length {
            let found = ns.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                 range: NSRange(location: from, length: ns.length - from))
            guard found.location != NSNotFound, found.length > 0 else { break }
            count += 1
            from = found.location + found.length
        }
        return count
    }
}
