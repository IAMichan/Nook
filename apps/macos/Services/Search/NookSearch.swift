import Foundation

// Search everything: one query over Nook's conversations, agent sessions, chats, call notes, memories, notices, settings
// and actions. Foundation-only, so it is tested on its own (NookSearchTests); `AppModel+Search` hands it the documents and
// `SearchPanel` shows the hits.
//
// The query language, on top of plain words (all must match, typos and word starts allowed):
//   "exact phrase"            the words in this order
//   -word, -"phrase"          leaves out what contains it
//   a OR b, a | b             either one
//   in:agents, in:chats       only these kinds (nook, agents, chats, notes, memory, notices, settings, actions); -in: leaves one out
//   from:me, from:lisa        only what this person (or Nook, or an agent) wrote
//   app:telegram, project:nook, branch:main, agent:codex
//   is:unread, is:pinned, is:archived, is:running, is:failed; -is: inverts
//   after:2026-10-01, before:7d, on:yesterday, date:week
//   /regex/                   a regular expression, ignoring case
// Matching ignores case and accents. Ranking is BM25-like (rare words weigh more, repeats count less and less), with a
// title weighing most and a recent document a little more.

/// What a hit is.
enum SearchKind: String, CaseIterable, Codable, Sendable {
    case action, setting, conversation, session, chat, note, memory, notice

    /// Words `in:` accepts for it, in every language Nook speaks.
    var aliases: [String] {
        switch self {
        case .action: return ["action", "actions", "command", "commands", "actie", "acties", "aktion", "commande", "accion"]
        case .setting: return ["setting", "settings", "instelling", "instellingen", "einstellung", "reglage", "ajuste", "prefs"]
        case .conversation: return ["nook", "nooks", "conversation", "conversations", "gesprek", "gesprekken", "gesprach", "conversacion", "ask"]
        case .session: return ["agent", "agents", "session", "sessions", "sessie", "sessies", "sitzung", "sesion", "run", "runs", "code"]
        case .chat: return ["chat", "chats", "message", "messages", "bericht", "berichten", "nachricht", "mensaje"]
        case .note: return ["note", "notes", "notitie", "notities", "call", "calls", "meeting", "meetings", "notiz", "nota"]
        case .memory: return ["memory", "memories", "geheugen", "herinnering", "herinneringen", "gedachtnis", "memoire", "memoria"]
        case .notice: return ["notice", "notices", "notification", "notifications", "melding", "meldingen", "mitteilung", "aviso"]
        }
    }

    /// The kind `in:value` names: an alias, or the start of exactly one kind's alias ("sess", "mem").
    static func named(_ value: String) -> SearchKind? {
        let wanted = SearchText.fold(value)
        guard !wanted.isEmpty else { return nil }
        if let exact = allCases.first(where: { $0.aliases.contains(wanted) }) { return exact }
        guard wanted.count >= 2 else { return nil }
        let started = allCases.filter { kind in kind.aliases.contains { $0.hasPrefix(wanted) } }
        return started.count == 1 ? started.first : nil
    }
}

/// One piece of a document's text: a message, an answer, a line of a call.
struct SearchPassage: Equatable, Sendable {
    var text: String
    /// Who wrote it: "me" for you, "nook", an agent's or a person's name; empty when nobody in particular.
    var author: String = ""
    var date: Date? = nil
    /// What to jump to inside the document (a message id), when the passage has its own place.
    var anchor: String? = nil
}

/// One thing search can find.
struct SearchDocument: Identifiable, Equatable, Sendable {
    /// Unique over every kind ("run:<uuid>", "chat:telegram|anna").
    var id: String
    var kind: SearchKind
    var title: String
    /// One quiet line under the title: where it lives, whose it is.
    var subtitle: String = ""
    /// The newest thing in it.
    var date: Date? = nil
    /// Named values `key:value` filters on ("app": "Telegram", "project": "nook"). Their values count as text too.
    var facets: [String: String] = [:]
    /// What `is:` filters on: "unread", "pinned", "archived", "running", "failed" …
    var flags: Set<String> = []
    var passages: [SearchPassage] = []
    /// Added to the score: a pinned conversation, an unread chat.
    var boost: Double = 0
}

// MARK: - The query

struct SearchQuery: Equatable, Sendable {
    /// One word or phrase, folded (lowercase, no accents, words separated by one space).
    struct Term: Hashable, Sendable {
        var text: String
        var phrase: Bool

        var words: [String] { text.split(separator: " ").map(String.init) }
    }

    /// Every group must match; a group matches when one of its terms does (`a OR b`).
    var groups: [[Term]] = []
    var excluded: [Term] = []
    var kinds: Set<SearchKind> = []
    var excludedKinds: Set<SearchKind> = []
    /// `key:value` pairs, both folded.
    var facets: [String: [String]] = [:]
    /// `from:` values, folded; "me" for you in any language.
    var authors: [String] = []
    var flags: Set<String> = []
    var excludedFlags: Set<String> = []
    var after: Date? = nil
    var before: Date? = nil
    var pattern: String? = nil

    static let maxLength = 500

    /// Filter keys, with the facet each one reads. `in`, `from`, `is` and the dates are handled on their own.
    static let facetKeys: [String: String] = [
        "app": "app", "via": "app",
        "project": "project", "folder": "project", "repo": "project", "map": "project",
        "branch": "branch", "tak": "branch",
        "agent": "agent", "provider": "agent", "model": "agent",
        "section": "section", "sectie": "section",
        "type": "type", "soort": "type",
        "speaker": "speaker", "spreker": "speaker",
    ]

    /// What "me" is called in `from:`.
    static let me: Set<String> = ["me", "i", "ik", "mij", "mezelf", "ich", "mich", "moi", "je", "yo", "mi", "you", "jij"]

    /// No words, phrases or pattern: the query only filters (or is empty).
    var hasText: Bool { !groups.isEmpty || pattern != nil }

    var hasFilters: Bool {
        !kinds.isEmpty || !excludedKinds.isEmpty || !facets.isEmpty || !authors.isEmpty || !flags.isEmpty
            || !excludedFlags.isEmpty || after != nil || before != nil
    }

    var isEmpty: Bool { !hasText && !hasFilters && excluded.isEmpty }

    /// Every word the query looks for, for highlighting.
    var words: [String] { groups.flatMap { $0.flatMap(\.words) } }

    static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> SearchQuery {
        var query = SearchQuery()
        guard raw.utf16.count <= maxLength else { return query }
        var joinNext = false
        for token in tokens(raw) {
            if !token.quoted, !token.negated, token.text == "OR" || token.text == "|" {
                joinNext = !query.groups.isEmpty
                continue
            }
            if !token.quoted, token.text.count > 2, token.text.hasPrefix("/"), token.text.hasSuffix("/") {
                query.pattern = String(token.text.dropFirst().dropLast())
                joinNext = false
                continue
            }
            if !token.quoted, query.applyFilter(token, now: now, calendar: calendar) {
                joinNext = false
                continue
            }
            let folded = SearchText.fold(token.text)
            guard !folded.isEmpty else { continue }
            let term = Term(text: folded, phrase: token.quoted || folded.contains(" "))
            if token.negated {
                query.excluded.append(term)
            } else if joinNext, !query.groups.isEmpty {
                query.groups[query.groups.count - 1].append(term)
            } else {
                query.groups.append([term])
            }
            joinNext = false
        }
        return query
    }

    /// `key:value`: true when the token was a filter this query understands.
    private mutating func applyFilter(_ token: RawToken, now: Date, calendar: Calendar) -> Bool {
        guard let colon = token.text.firstIndex(of: ":"), colon != token.text.startIndex else { return false }
        let key = SearchText.fold(String(token.text[..<colon]))
        let rawValue = String(token.text[token.text.index(after: colon)...])
        let value = SearchText.fold(rawValue)
        guard !value.isEmpty else { return false }
        switch key {
        case "in", "within", "binnen", "kind":
            guard let kind = SearchKind.named(value) else {
                // `kind:fact` is the memory's own kind, not one of search's.
                guard key == "kind" else { return false }
                facets["type", default: []].append(value)
                return true
            }
            if token.negated { excludedKinds.insert(kind) } else { kinds.insert(kind) }
        case "from", "van", "by", "door", "von", "de":
            authors.append(Self.me.contains(value) ? "me" : value)
        case "is", "has":
            let flag = Self.flag(value)
            if token.negated { excludedFlags.insert(flag) } else { flags.insert(flag) }
        case "after", "since", "na", "sinds", "nach", "apres", "desde":
            guard let range = Self.dateRange(rawValue, now: now, calendar: calendar) else { return false }
            after = max(after ?? .distantPast, range.start)
        case "before", "until", "voor", "tot", "vor", "avant", "antes":
            guard let range = Self.dateRange(rawValue, now: now, calendar: calendar) else { return false }
            before = min(before ?? .distantFuture, range.start)
        case "on", "date", "op", "datum", "am", "le", "el", "during":
            guard let range = Self.dateRange(rawValue, now: now, calendar: calendar) else { return false }
            after = max(after ?? .distantPast, range.start)
            before = min(before ?? .distantFuture, range.end)
        default:
            guard let facet = Self.facetKeys[key] else { return false }
            facets[facet, default: []].append(value)
        }
        return true
    }

    /// `is:` values in other words and languages, as the flag documents carry.
    static func flag(_ value: String) -> String {
        switch value {
        case "new", "ongelezen", "nieuw", "ungelesen", "nonlu", "noleido": return "unread"
        case "pin", "vast", "vastgezet", "angeheftet", "epingle", "fijado": return "pinned"
        case "archive", "gearchiveerd", "archief", "archiviert", "archivado": return "archived"
        case "active", "busy", "bezig", "actief", "working", "aktiv", "actif", "activo": return "running"
        case "error", "failed", "fout", "mislukt", "fehler", "erreur", "fallido": return "failed"
        case "waiting", "wacht", "approval", "wartet", "attente", "esperando": return "waiting"
        case "done", "klaar", "completed", "fertig", "termine", "hecho": return "done"
        case "group", "groep", "gruppe", "groupe", "grupo": return "group"
        default: return value
        }
    }

    /// The span a date word names: "today", "yesterday", "week", "month", "year", "3d", "2w", "6m", "1y", "2026-10-01",
    /// "2026-10", "2026". A relative one runs from then until now.
    static func dateRange(_ raw: String, now: Date, calendar: Calendar) -> DateInterval? {
        let value = raw.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let today = calendar.startOfDay(for: now)
        func back(_ component: Calendar.Component, _ count: Int) -> DateInterval? {
            calendar.date(byAdding: component, value: -count, to: now).map { DateInterval(start: $0, end: now) }
        }
        switch value {
        case "today", "vandaag", "heute", "aujourdhui", "hoy":
            return calendar.date(byAdding: .day, value: 1, to: today).map { DateInterval(start: today, end: $0) }
        case "yesterday", "gisteren", "gestern", "hier", "ayer":
            return calendar.date(byAdding: .day, value: -1, to: today).map { DateInterval(start: $0, end: today) }
        case "week", "thisweek", "deze-week", "woche", "semaine", "semana": return back(.day, 7)
        case "month", "maand", "monat", "mois", "mes": return back(.month, 1)
        case "year", "jaar", "jahr", "annee", "ano": return back(.year, 1)
        default: break
        }
        if let unit = value.last, let count = Int(value.dropLast()), count >= 0, count < 10_000 {
            switch unit {
            case "h", "u": return back(.hour, count)
            case "d": return back(.day, count)
            case "w": return back(.weekOfYear, count)
            case "m": return back(.month, count)
            case "y", "j": return back(.year, count)
            default: break
            }
        }
        let parts = value.split(separator: "-").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }), let year = parts[0], (1970...2999).contains(year)
        else { return nil }
        var components = DateComponents(year: year, month: 1, day: 1)
        let span: Calendar.Component
        switch parts.count {
        case 1: span = .year
        case 2: components.month = parts[1]; span = .month
        default: components.month = parts[1]; components.day = parts[2]; span = .day
        }
        guard let start = calendar.date(from: components), let end = calendar.date(byAdding: span, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    struct RawToken: Equatable {
        var text: String
        var quoted = false
        var negated = false
    }

    /// Splits on spaces, keeping "quoted phrases" and /patterns with spaces/ whole; a leading - negates.
    static func tokens(_ raw: String) -> [RawToken] {
        var tokens: [RawToken] = []
        var current = ""
        var negated = false
        var inQuote = false
        /// The quote opened right after `key:` (from:"Anna de Vries"): the token stays a filter.
        var keyedQuote = false
        var inPattern = false
        func flush(quoted: Bool = false) {
            if !current.isEmpty || quoted { tokens.append(RawToken(text: current, quoted: quoted, negated: negated)) }
            current = ""
            negated = false
        }
        for character in raw {
            if inQuote {
                if character == "\"" || character == "”" {
                    inQuote = false
                    flush(quoted: !keyedQuote)
                    keyedQuote = false
                } else {
                    current.append(character)
                }
                continue
            }
            if inPattern {
                current.append(character)
                if character == "/" { inPattern = false; flush() }
                continue
            }
            if character.isWhitespace { flush(); continue }
            if current.isEmpty, character == "-", !negated { negated = true; continue }
            if current.isEmpty, character == "\"" || character == "“" { inQuote = true; continue }
            if character == "\"", current.hasSuffix(":") { inQuote = true; keyedQuote = true; continue }
            if current.isEmpty, character == "/" { inPattern = true; current.append(character); continue }
            current.append(character)
        }
        if inQuote, !current.isEmpty { flush(quoted: !keyedQuote) } else { flush() }
        return tokens.filter { !$0.text.isEmpty }
    }
}

// MARK: - A hit

struct SearchHit: Identifiable, Equatable, Sendable {
    var document: SearchDocument
    var score: Double
    /// UTF-16 ranges in `document.title` to highlight.
    var titleRanges: [Range<Int>]
    /// The best place it matched, cut to a line, and the ranges in it to highlight.
    var snippet: String
    var snippetRanges: [Range<Int>]
    /// The passage the snippet comes from.
    var passage: SearchPassage?
    /// How many passages matched.
    var matches: Int

    var id: String { document.id }
}

// MARK: - Words

/// How search sees text: lowercase words without accents, split on everything that is not a letter or digit. The query
/// and the index fold the same way, so "Résumé", "resume" and "RESUME" are one word. Plain ASCII, by far the most text,
/// takes a fast path.
enum SearchText {
    static func fold(_ text: String) -> String { words(text).joined(separator: " ") }

    static func words(_ text: String) -> [String] {
        let source = text.utf8.allSatisfy { $0 < 0x80 } ? text : text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var words: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            if !current.isEmpty { words.append(String(current)); current = String.UnicodeScalarView() }
        }
        for scalar in source.unicodeScalars {
            let value = scalar.value
            if value < 0x80 {
                if (0x61...0x7A).contains(value) || (0x30...0x39).contains(value) {
                    current.append(scalar)
                } else if (0x41...0x5A).contains(value), let lower = Unicode.Scalar(value + 32) {
                    current.append(lower)
                } else {
                    flush()
                }
            } else {
                let properties = scalar.properties
                switch properties.generalCategory {
                case .nonspacingMark, .spacingMark, .enclosingMark:
                    if !current.isEmpty { current.append(scalar) }
                default:
                    if properties.isAlphabetic || properties.numericType != nil { current.append(scalar) } else { flush() }
                }
            }
        }
        flush()
        return words
    }

    /// Whether folded text contains a folded needle, compared as bytes: folded text is whole words and single spaces, so
    /// this equals `String.contains` there, without its cost per character.
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        var haystack = haystack, needle = needle
        return haystack.withUTF8 { text in
            needle.withUTF8 { wanted in
                guard let first = wanted.first else { return true }
                guard wanted.count <= text.count else { return false }
                var index = 0
                let last = text.count - wanted.count
                while index <= last {
                    if text[index] == first {
                        var offset = 1
                        while offset < wanted.count, text[index + offset] == wanted[offset] { offset += 1 }
                        if offset == wanted.count { return true }
                    }
                    index += 1
                }
                return false
            }
        }
    }
}

// MARK: - The index

/// The documents, tokenized once into an inverted index (every word → where it is), so a search only visits the places
/// its words are, however much history there is.
struct SearchIndex: Sendable {
    /// One place a word is: a document, a field in it, and how often.
    struct Posting: Sendable {
        let entry: Int32
        /// `title`, `meta`, or a passage's index.
        let field: Int32
        let count: Int32
    }

    static let title: Int32 = -2
    /// The subtitle and the facet values.
    static let meta: Int32 = -1

    struct Entry: Sendable {
        let document: SearchDocument
        /// Folded fields with a space before and after, for phrases and word starts.
        let title: String
        let meta: String
        let passages: [String]
        let foldedFacets: [String: String]
        let foldedAuthors: [String]

        func folded(_ field: Int32) -> String {
            switch field {
            case SearchIndex.title: return title
            case SearchIndex.meta: return meta
            default: return passages[Int(field)]
            }
        }
    }

    /// Longest text of one passage that is indexed; the rest of a very long tool output adds little.
    static let passageLimit = 4_000
    /// Most passages indexed per document (the newest are kept).
    static let passagesPerDocument = 600

    let entries: [Entry]
    let postings: [String: [Posting]]
    /// Every word, sorted, for word starts, parts and typos.
    let vocabulary: [String]
    /// In how many documents each word is.
    let frequency: [String: Int]

    init(_ documents: [SearchDocument]) {
        var postings: [String: [Posting]] = [:]
        var frequency: [String: Int] = [:]
        var entries: [Entry] = []
        entries.reserveCapacity(documents.count)
        for (number, original) in documents.enumerated() {
            var document = original
            if document.passages.count > SearchIndex.passagesPerDocument {
                document.passages = Array(document.passages.suffix(SearchIndex.passagesPerDocument))
            }
            for index in document.passages.indices where document.passages[index].text.utf16.count > SearchIndex.passageLimit {
                document.passages[index].text = String(document.passages[index].text.prefix(SearchIndex.passageLimit))
            }
            let entry = Int32(number)
            var seen = Set<String>()
            func add(_ text: String, field: Int32) -> String {
                let words = SearchText.words(text)
                var counts: [String: Int32] = [:]
                for word in words { counts[word, default: 0] += 1 }
                for (word, count) in counts {
                    postings[word, default: []].append(Posting(entry: entry, field: field, count: count))
                    if seen.insert(word).inserted { frequency[word, default: 0] += 1 }
                }
                return " " + words.joined(separator: " ") + " "
            }
            let title = add(document.title, field: SearchIndex.title)
            let facets = document.facets.keys.sorted().compactMap { document.facets[$0] }
            let meta = add(([document.subtitle] + facets).joined(separator: " "), field: SearchIndex.meta)
            let passages = document.passages.enumerated().map { add($0.element.text, field: Int32($0.offset)) }
            entries.append(Entry(document: document, title: title, meta: meta, passages: passages,
                                 foldedFacets: document.facets.mapValues(SearchText.fold),
                                 foldedAuthors: document.passages.map { SearchText.fold($0.author) }))
        }
        self.entries = entries
        self.postings = postings
        self.frequency = frequency
        vocabulary = frequency.keys.sorted()
    }

    var isEmpty: Bool { entries.isEmpty }

    // MARK: Words

    /// Which indexed words a query word stands for, and how much each counts: itself 1, a word it starts 0.75, one with a
    /// typo 0.5 (two in a long word 0.3), one it is part of 0.4.
    func expansions(_ word: String) -> [String: Double] {
        var out: [String: Double] = [word: 1]
        let length = word.count
        // Word starts: a binary search to the first word ≥ `word`, then on while they start with it.
        if length >= 2 {
            var low = 0, high = vocabulary.count
            while low < high {
                let middle = (low + high) / 2
                if vocabulary[middle] < word { low = middle + 1 } else { high = middle }
            }
            var index = low
            var taken = 0
            while index < vocabulary.count, vocabulary[index].hasPrefix(word), taken < 150 {
                if vocabulary[index] != word { out[vocabulary[index]] = 0.75 }
                index += 1
                taken += 1
            }
        }
        guard length >= 3 else { return out }
        let allowed = length >= 7 ? 2 : 1
        let wanted = Array(word.unicodeScalars)
        var parts = 0
        for candidate in vocabulary where out[candidate] == nil {
            let scalars = candidate.unicodeScalars
            let size = scalars.count
            if size > length, parts < 60, candidate.contains(word) {
                out[candidate] = 0.4
                parts += 1
            } else if length >= 4, abs(size - length) <= allowed {
                let distance = Self.distance(wanted, Array(scalars), limit: allowed)
                if distance <= allowed { out[candidate] = distance == 1 ? 0.5 : 0.3 }
            }
        }
        return out
    }

    /// Levenshtein distance, giving up (returning `limit + 1`) once it cannot stay within `limit`.
    static func distance(_ a: String, _ b: String, limit: Int) -> Int {
        distance(Array(a.unicodeScalars), Array(b.unicodeScalars), limit: limit)
    }

    static func distance(_ x: [Unicode.Scalar], _ y: [Unicode.Scalar], limit: Int) -> Int {
        if abs(x.count - y.count) > limit { return limit + 1 }
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            var best = current[0]
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
                best = min(best, current[j])
            }
            if best > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    /// Rare words weigh more (BM25's inverse document frequency).
    func weight(_ word: String) -> Double {
        let count = Double(entries.count)
        let found = Double(frequency[word] ?? 0)
        return log(1 + (count - found + 0.5) / (found + 0.5))
    }

    // MARK: Search

    /// Where one term or group matched: per document, per field, the best score and the indexed word that gave it.
    private typealias Matches = [Int32: [Int32: (score: Double, word: String)]]

    /// Every place a term matches.
    private func matches(_ term: SearchQuery.Term) -> Matches {
        var found: Matches = [:]
        if term.phrase {
            // The phrase's rarest word says where to look; the folded field says whether the words are side by side.
            let words = term.words
            guard let rarest = words.min(by: { (postings[$0]?.count ?? 0) < (postings[$1]?.count ?? 0) }),
                  let candidates = postings[rarest] else { return [:] }
            let score = 1.3 * max(words.map(weight).reduce(0, +), 0.5)
            // Its last word may be the start of a word, as while typing.
            let needle = " " + term.text
            for posting in candidates {
                guard SearchText.contains(entries[Int(posting.entry)].folded(posting.field), needle) else { continue }
                found[posting.entry, default: [:]][posting.field] = (score, term.text)
            }
            return found
        }
        for (word, factor) in expansions(term.text) {
            guard let list = postings[word] else { continue }
            let base = factor * weight(word)
            for posting in list {
                let count = Double(posting.count)
                let value = base * count * 2.2 / (count + 1.2)
                if let place = found[posting.entry]?[posting.field], place.score >= value { continue }
                found[posting.entry, default: [:]][posting.field] = (value, word)
            }
        }
        return found
    }

    /// The documents that contain a term anywhere (for `-word`).
    private func containing(_ term: SearchQuery.Term) -> Set<Int32> {
        if term.phrase { return Set(matches(term).keys) }
        return Set(postings[term.text]?.map(\.entry) ?? [])
    }

    func search(_ query: SearchQuery, limit: Int = 80, now: Date = Date()) -> [SearchHit] {
        guard !query.isEmpty else { return [] }
        // Each group: where any of its terms matched, the best score per field.
        let groups: [Matches] = query.groups.map { group in
            var merged: Matches = [:]
            for term in group {
                for (entry, fields) in matches(term) {
                    for (field, place) in fields {
                        if let current = merged[entry]?[field], current.score >= place.score { continue }
                        merged[entry, default: [:]][field] = place
                    }
                }
            }
            return merged
        }
        let regex = query.pattern.flatMap { pattern -> NSRegularExpression? in
            guard pattern.utf16.count <= 200 else { return nil }
            return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
        if query.pattern != nil, regex == nil, query.groups.isEmpty { return [] }
        let excluded = query.excluded.reduce(into: Set<Int32>()) { $0.formUnion(containing($1)) }
        let plainWords: String? = query.groups.count >= 2 && query.groups.allSatisfy { $0.count == 1 && !$0[0].phrase }
            ? query.groups.map { $0[0].text }.joined(separator: " ") : nil
        let typed = query.groups.map { $0[0].text }.joined(separator: " ")

        // The documents every group matched in, smallest group first; all of them for a query without words.
        var candidates: [Int32]
        if let smallest = groups.min(by: { $0.count < $1.count }) {
            candidates = smallest.keys.filter { entry in groups.allSatisfy { $0[entry] != nil } }
        } else {
            candidates = entries.indices.map { Int32($0) }
        }
        candidates.sort()

        let restricted = !query.authors.isEmpty || query.after != nil || query.before != nil
        // With `from:` only what that person wrote counts, not the title.
        let titleCounts = query.authors.isEmpty
        /// A document that passed, with what the snippet needs; snippets are only cut for the hits that are shown.
        struct Scored {
            let number: Int32
            let score: Double
            let titleWords: Set<String>
            let passageScores: [Int: Double]
            let passageWords: [Int: Set<String>]
            let regexRanges: [Int: [Range<Int>]]
            let titleRegexRanges: [Range<Int>]
            let fallback: Int?
        }
        var scored: [Scored] = []
        for number in candidates where !excluded.contains(number) {
            let entry = entries[Int(number)]
            let document = entry.document
            if !query.kinds.isEmpty, !query.kinds.contains(document.kind) { continue }
            if query.excludedKinds.contains(document.kind) { continue }
            if !query.flags.isSubset(of: document.flags) || !query.excludedFlags.isDisjoint(with: document.flags) { continue }
            let facetsMatch = query.facets.allSatisfy { key, values in
                guard let value = entry.foldedFacets[key] else { return false }
                return values.allSatisfy { value.contains($0) }
            }
            if !facetsMatch { continue }

            // The passages that may match: by who wrote them and when.
            func allowed(_ index: Int) -> Bool {
                guard restricted else { return true }
                if !query.authors.isEmpty {
                    let author = entry.foldedAuthors[index]
                    guard query.authors.contains(where: { author == $0 || (!author.isEmpty && author.contains($0)) }) else { return false }
                }
                guard let date = document.passages[index].date ?? document.date else { return query.after == nil && query.before == nil }
                if let after = query.after, date < after { return false }
                if let before = query.before, date >= before { return false }
                return true
            }
            if restricted {
                let any = document.passages.indices.contains(where: allowed)
                if !any {
                    // A document without passages can still pass a date filter on its own date.
                    guard query.authors.isEmpty, document.passages.isEmpty, let date = document.date,
                          query.after.map({ date >= $0 }) ?? true, query.before.map({ date < $0 }) ?? true else { continue }
                }
            }

            var total = 0.0
            var titleWords: Set<String> = []
            var passageScores: [Int: Double] = [:]
            var passageWords: [Int: Set<String>] = [:]
            var titleGroups = 0
            var missing = false
            for group in groups {
                var best = 0.0
                var inPassages = 0
                for (field, place) in group[number] ?? [:] {
                    switch field {
                    case SearchIndex.title:
                        guard titleCounts else { continue }
                        best = max(best, 3 * place.score)
                        titleWords.formUnion(place.word.split(separator: " ").map(String.init))
                        titleGroups += 1
                    case SearchIndex.meta:
                        guard titleCounts else { continue }
                        best = max(best, 1.5 * place.score)
                    default:
                        let index = Int(field)
                        guard allowed(index) else { continue }
                        inPassages += 1
                        passageScores[index, default: 0] += place.score
                        passageWords[index, default: []].formUnion(place.word.split(separator: " ").map(String.init))
                        best = max(best, place.score)
                    }
                }
                // Found in many passages: a little more, but far less than in the title.
                if inPassages > 1 { best += min(1, log(Double(inPassages)) * 0.25) }
                if best <= 0 { missing = true; break }
                total += best
            }
            if missing { continue }

            var regexRanges: [Int: [Range<Int>]] = [:]
            var titleRegexRanges: [Range<Int>] = []
            if let regex {
                if titleCounts { titleRegexRanges = Self.ranges(of: regex, in: document.title) }
                for index in document.passages.indices where allowed(index) {
                    let found = Self.ranges(of: regex, in: document.passages[index].text)
                    if !found.isEmpty {
                        regexRanges[index] = found
                        passageScores[index, default: 0] += 1
                    }
                }
                if titleRegexRanges.isEmpty, regexRanges.isEmpty { continue }
                total += titleRegexRanges.isEmpty ? 1 : 3
            }

            // Bonuses: every word in the title, the title starting with what you typed, the words side by side.
            if titleCounts, !groups.isEmpty {
                if titleGroups == groups.count { total += 1.5 }
                if entry.title == " " + typed + " " { total += 4 } else if entry.title.hasPrefix(" " + typed) { total += 2 }
            }
            if let plainWords {
                let fields = (titleCounts ? [entry.title, entry.meta] : []) + passageScores.keys.map { entry.passages[$0] }
                let needle = " " + plainWords
                if fields.contains(where: { SearchText.contains($0, needle) }) { total += 1.5 }
            }
            if !query.hasText { total = 1 }
            total += document.boost
            // Recent things first among equals: up to a third more for today, fading over a couple of weeks.
            if let date = document.date {
                let days = max(0, now.timeIntervalSince(date) / 86_400)
                total *= 1 + 0.35 * exp(-days / 14)
            }

            scored.append(Scored(number: number, score: total, titleWords: titleWords, passageScores: passageScores,
                                 passageWords: passageWords, regexRanges: regexRanges, titleRegexRanges: titleRegexRanges,
                                 fallback: query.hasText ? nil : document.passages.indices.last(where: allowed)))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let first = entries[Int(a.number)].document.date ?? .distantPast, second = entries[Int(b.number)].document.date ?? .distantPast
            return first != second ? first > second : entries[Int(a.number)].document.id < entries[Int(b.number)].document.id
        }
        return scored.prefix(limit).map { found in
            let document = entries[Int(found.number)].document
            let titleWords = found.titleWords, passageWords = found.passageWords, regexRanges = found.regexRanges
            // The snippet: the passage that matched best, else the newest one a filter kept, else the subtitle.
            let bestPassage = found.passageScores.max { a, b in a.value != b.value ? a.value < b.value : a.key < b.key }?.key
                ?? found.fallback
            let needles = Array(titleWords.union(bestPassage.flatMap { passageWords[$0] } ?? [])) + query.words
            var hit = SearchHit(document: document, score: found.score,
                                titleRanges: SearchHighlight.merge(SearchHighlight.ranges(of: needles, in: document.title) + found.titleRegexRanges),
                                snippet: "", snippetRanges: [], passage: nil, matches: found.passageScores.count)
            if let bestPassage {
                let passage = document.passages[bestPassage]
                let cut = SearchHighlight.snippet(passage.text, needles: needles, regexRanges: regexRanges[bestPassage] ?? [])
                hit.snippet = cut.text
                hit.snippetRanges = cut.ranges
                hit.passage = passage
            } else {
                let cut = SearchHighlight.snippet(document.subtitle, needles: needles, regexRanges: [])
                hit.snippet = cut.text
                hit.snippetRanges = cut.ranges
            }
            return hit
        }
    }

    private static func ranges(of regex: NSRegularExpression, in text: String) -> [Range<Int>] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).prefix(50).compactMap { match in
            match.range.length > 0 ? match.range.location..<(match.range.location + match.range.length) : nil
        }
    }
}

// MARK: - Highlighting

/// Where the words a search found are in a text, as UTF-16 ranges (like `TimelineSearch`), and the line around them.
enum SearchHighlight {
    /// Every place a needle occurs, ignoring case and accents; overlapping ranges merged.
    static func ranges(of needles: [String], in text: String) -> [Range<Int>] {
        let ns = text as NSString
        var found: [Range<Int>] = []
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        for needle in Set(needles) where needle.count >= 1 {
            var from = 0
            var count = 0
            while from < ns.length, count < 50 {
                let range = ns.range(of: needle, options: options, range: NSRange(location: from, length: ns.length - from))
                guard range.location != NSNotFound, range.length > 0 else { break }
                found.append(range.location..<(range.location + range.length))
                from = range.location + range.length
                count += 1
            }
        }
        return merge(found)
    }

    static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// One line of about `width` characters around the first match, with "…" where it was cut, and the ranges in it.
    static func snippet(_ text: String, needles: [String], regexRanges: [Range<Int>], width: Int = 160) -> (text: String, ranges: [Range<Int>]) {
        let flat = text.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
        let ns = flat as NSString
        guard ns.length > 0 else { return ("", []) }
        // Regex ranges were found on the original text; search the flattened one again for them.
        var regexNeedles: [String] = []
        let original = text as NSString
        for range in regexRanges.prefix(10) where range.upperBound <= original.length {
            regexNeedles.append(original.substring(with: NSRange(location: range.lowerBound, length: range.count)))
        }
        let all = ranges(of: needles + regexNeedles, in: flat)
        guard ns.length > width else { return (flat, all) }
        let first = all.first?.lowerBound ?? 0
        var start = max(0, first - width / 3)
        // Start at a word: back to the space before.
        if start > 0 {
            let space = ns.range(of: " ", options: .backwards, range: NSRange(location: 0, length: start))
            if space.location != NSNotFound, start - space.location < 20 { start = space.location + 1 }
        }
        start = min(start, max(0, ns.length - width))
        // Never cut a surrogate pair or a composed character in two.
        start = ns.rangeOfComposedCharacterSequence(at: start).location
        var end = min(ns.length, start + width)
        if end < ns.length { end = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: end - 1)) }
        let prefix = start > 0 ? "…" : ""
        let suffix = end < ns.length ? "…" : ""
        let body = ns.substring(with: NSRange(location: start, length: end - start))
        let shift = (prefix as NSString).length - start
        let shifted = all.compactMap { range -> Range<Int>? in
            let lower = max(range.lowerBound, start), upper = min(range.upperBound, end)
            return lower < upper ? (lower + shift)..<(upper + shift) : nil
        }
        return (prefix + body + suffix, shifted)
    }

    /// The text in pieces, each marked whether it is highlighted, for a view to draw.
    static func segments(_ text: String, ranges: [Range<Int>]) -> [(text: String, marked: Bool)] {
        let ns = text as NSString
        var pieces: [(String, Bool)] = []
        var cursor = 0
        for range in merge(ranges) where range.lowerBound >= cursor && range.upperBound <= ns.length {
            if range.lowerBound > cursor { pieces.append((ns.substring(with: NSRange(location: cursor, length: range.lowerBound - cursor)), false)) }
            pieces.append((ns.substring(with: NSRange(location: range.lowerBound, length: range.count)), true))
            cursor = range.upperBound
        }
        if cursor < ns.length { pieces.append((ns.substring(from: cursor), false)) }
        return pieces.map { (text: $0.0, marked: $0.1) }
    }
}
