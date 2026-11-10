import Foundation

// Getting around the Agents list by keyboard: back and forward through the sessions you opened (⌘[ / ⌘]), ⌘1–⌘9 to the
// first nine rows, and the order the command palette lists sessions in (the ones you open often and lately first).
// Pure logic; the views keep the state (`SessionHistory`).

/// The sessions you opened, in order, for back and forward. Opening a session by stepping back or forward does not
/// count as a visit, so a step back and a step forward return to where you were.
struct SessionTrail: Equatable, Sendable {
    private(set) var back: [String] = []
    private(set) var forward: [String] = []
    private(set) var current: String?
    /// At most this many sessions to go back to.
    static let limit = 50

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// You opened `id` (a click, a search, a key): what you came from goes on the back stack and forward is cleared.
    mutating func visit(_ id: String) {
        guard !id.isEmpty, id != current else { return }
        if let current {
            back.append(current)
            if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        }
        forward.removeAll()
        current = id
    }

    /// The session before this one, skipping any that are gone (`exists` false); nil when there is none.
    mutating func goBack(exists: (String) -> Bool = { _ in true }) -> String? {
        while let previous = back.popLast() {
            guard exists(previous), previous != current else { continue }
            if let current { forward.append(current) }
            current = previous
            return previous
        }
        return nil
    }

    /// The session you stepped back from, skipping any that are gone; nil when there is none.
    mutating func goForward(exists: (String) -> Bool = { _ in true }) -> String? {
        while let next = forward.popLast() {
            guard exists(next), next != current else { continue }
            if let current { back.append(current) }
            current = next
            return next
        }
        return nil
    }
}

/// How often and how lately each session was opened, for the order of the command palette's recent sessions.
struct SessionUsage: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var count: Int
        var last: Date
    }

    private(set) var entries: [String: Entry] = [:]
    /// The sessions kept; the least used fall away first.
    static let limit = 200

    mutating func record(_ id: String, at date: Date = Date()) {
        guard !id.isEmpty else { return }
        var entry = entries[id] ?? Entry(count: 0, last: date)
        entry.count += 1
        entry.last = max(entry.last, date)
        entries[id] = entry
        if entries.count > Self.limit {
            let keep = entries.sorted { score($0.key, now: date) > score($1.key, now: date) }.prefix(Self.limit)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    /// Frequency and recency in one number: every visit counts, a visit loses half its weight every day.
    /// A session never opened scores 0.
    func score(_ id: String, now: Date = Date()) -> Double {
        guard let entry = entries[id] else { return 0 }
        let days = max(0, now.timeIntervalSince(entry.last)) / 86_400
        return (1 + log2(Double(entry.count))) * pow(0.5, days)
    }
}

/// ⌘1–⌘9 on the Agents tab: the first nine rows of the list as it is shown (folded shelves and projects left out).
enum SessionJump {
    static let count = 9

    /// The session `number` (1–9) opens; nil past the end of the list or outside 1–9.
    static func target(_ number: Int, in shown: [String]) -> String? {
        guard (1...count).contains(number), shown.indices.contains(number - 1) else { return nil }
        return shown[number - 1]
    }

    /// The number each of the first nine rows answers to, for the ⌘n hints while ⌘ is held.
    static func hints(_ shown: [String]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (index, id) in shown.prefix(count).enumerated() where out[id] == nil { out[id] = index + 1 }
        return out
    }

    /// The command id of ⌘`number`: `session.jump1` … `session.jump9`.
    static func command(_ number: Int) -> String { "session.jump\(number)" }

    /// The number a jump command stands for; nil for any other command.
    static func number(of command: String) -> Int? {
        guard command.hasPrefix("session.jump"), let n = Int(command.dropFirst("session.jump".count)), (1...count).contains(n)
        else { return nil }
        return n
    }
}

/// The open model picker's keys (as t3code): ⌘1–⌘9 pick the nth model the shown place lists, ⇧⌘↑ and ⇧⌘↓ show the
/// place before or after it in the rail.
enum ModelPickerKeys {
    static let count = 9
    static let previousPlace = "modelPicker.previousPlace"
    static let nextPlace = "modelPicker.nextPlace"

    /// The command id of ⌘`number` in the picker: `modelPicker.pick1` … `modelPicker.pick9`.
    static func command(_ number: Int) -> String { "modelPicker.pick\(number)" }

    /// The number a pick command stands for; nil for any other command.
    static func number(of command: String) -> Int? {
        guard command.hasPrefix("modelPicker.pick"), let n = Int(command.dropFirst("modelPicker.pick".count)), (1...count).contains(n)
        else { return nil }
        return n
    }

    /// The row ⌘`number` picks: the nth model that can be picked, counted over the rows as shown (a disabled one keeps
    /// its number, so the numbers do not shift); nil past the end or on a disabled row.
    static func row(_ number: Int, enabled: [Bool]) -> Int? {
        guard (1...count).contains(number), enabled.indices.contains(number - 1), enabled[number - 1] else { return nil }
        return number - 1
    }

    /// The place `offset` steps from `current` (1 next, -1 previous), wrapping around the ends; nil with fewer than two.
    static func step<Place: Equatable>(from current: Place, by offset: Int, in places: [Place]) -> Place? {
        guard places.count > 1 else { return nil }
        guard let index = places.firstIndex(of: current) else { return places.first }
        let next = ((index + offset) % places.count + places.count) % places.count
        return places[next]
    }
}

/// The row the arrow keys are on in a list where some rows cannot be picked (the model picker's disabled models).
enum ListHighlight {
    /// `index` if that row can be picked, else the first row from there on that can, else the last one before it; nil
    /// when no row can be picked.
    static func clamped(_ index: Int, in enabled: [Bool]) -> Int? {
        guard enabled.contains(true) else { return nil }
        let start = min(max(index, 0), enabled.count - 1)
        if let after = enabled[start...].firstIndex(of: true) { return after }
        return enabled[..<start].lastIndex(of: true)
    }

    /// The next row that can be picked `offset` rows on (1 down, -1 up), staying at the ends; nil when none can.
    static func step(_ index: Int?, by offset: Int, in enabled: [Bool]) -> Int? {
        guard let index else { return clamped(0, in: enabled) }
        var next = index + offset
        while enabled.indices.contains(next) {
            if enabled[next] { return next }
            next += offset
        }
        return index
    }
}

/// ⇧⌘C: what a session is, to paste into a message, an issue or another agent: its folder and its branch.
enum SessionReference {
    /// `/Users/me/code/app (feature/calm-ui)`; the folder alone without a branch, the branch alone without a folder.
    static func text(path: String, branch: String?) -> String? {
        let branch = branch?.trimmingCharacters(in: .whitespaces) ?? ""
        switch (path.isEmpty, branch.isEmpty) {
        case (true, true): return nil
        case (false, true): return path
        case (true, false): return branch
        case (false, false): return "\(path) (\(branch))"
        }
    }
}

/// What is typed in the command palette: `>` first limits it to actions, the rest are words that must all match.
struct PaletteQuery: Equatable, Sendable {
    var actionsOnly: Bool
    var words: [String]

    init(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        actionsOnly = rest.hasPrefix(">")
        if actionsOnly { rest = rest.dropFirst() }
        words = rest.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var isEmpty: Bool { words.isEmpty }

    /// How well `title` and `detail` match: nil when a word is in neither. A title that starts with the first word ranks
    /// above one that has it in the middle, and that above a match in the detail only.
    func match(title: String, detail: String) -> Int? {
        guard !words.isEmpty else { return 0 }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var score = 0
        for (index, word) in words.enumerated() {
            if let range = title.range(of: word, options: options) {
                score += range.lowerBound == title.startIndex ? (index == 0 ? 4 : 2) : 1
            } else if detail.range(of: word, options: options) == nil {
                return nil
            }
        }
        return score
    }
}

/// The command palette's order of things.
enum PaletteRanking {
    struct Candidate: Equatable, Sendable {
        var id: String
        var title: String
        var detail: String
        /// When it last changed (its last turn), for sessions you never opened in Nook.
        var updated: Date
    }

    /// Sessions for the palette: without words the ones you open often and lately first, then the newest; with words the
    /// ones that match, the best match first and among equals the same order. At most `limit`.
    static func sessions(_ candidates: [Candidate], query: PaletteQuery, usage: SessionUsage, now: Date = Date(),
                         limit: Int = 12) -> [Candidate] {
        let scored: [(candidate: Candidate, match: Int, use: Double)] = candidates.compactMap { candidate in
            guard let match = query.match(title: candidate.title, detail: candidate.detail) else { return nil }
            return (candidate, match, usage.score(candidate.id, now: now))
        }
        return scored.sorted { a, b in
            if a.match != b.match { return a.match > b.match }
            if a.use != b.use { return a.use > b.use }
            return a.candidate.updated > b.candidate.updated
        }.prefix(limit).map(\.candidate)
    }
}

/// The trail and the use of the Agents list's sessions on this Mac: the trail for this run of Nook, the use in
/// UserDefaults. Not observed: nothing redraws when you open a session; the keys and the palette read it when asked.
@MainActor
final class SessionHistory {
    static let shared = SessionHistory()
    private static let usageKey = "agents.sessionUsage"
    private let defaults: UserDefaults
    private(set) var trail = SessionTrail()
    private(set) var usage: SessionUsage

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        usage = defaults.data(forKey: Self.usageKey).flatMap { try? JSONDecoder().decode(SessionUsage.self, from: $0) }
            ?? SessionUsage()
    }

    /// You opened a session: it goes on the trail and counts for the palette's order.
    func opened(_ id: String, at date: Date = Date()) {
        guard !id.isEmpty, id != trail.current else { return }
        trail.visit(id)
        usage.record(id, at: date)
        if let data = try? JSONEncoder().encode(usage) { defaults.set(data, forKey: Self.usageKey) }
    }

    /// The session to go back or forward to, skipping the ones that are gone. Opening it does not count as a visit.
    func back(exists: (String) -> Bool) -> String? { trail.goBack(exists: exists) }
    func forward(exists: (String) -> Bool) -> String? { trail.goForward(exists: exists) }
}
