import Foundation

/// What the user wrote, so suggestions sound like them. Only on this Mac, secrets taken out first, deletable in Settings.
struct CompletionSamples: Codable, Equatable {
    struct Sample: Codable, Equatable {
        var app: String
        var text: String
        var date: Date
    }

    private(set) var samples: [Sample] = []
    var capacity = 400
    var maxLength = 2_000
    /// Short chat messages ("Thanks, see you tomorrow!") count too: they hold the phrases written most often.
    var minLength = 12
    /// Shorter samples teach phrases (see `CompletionPhrases`) but say little about style in the prompt.
    var minPromptLength = 40

    /// Text that only extends the last sample of the same app (still typing in that field) replaces it.
    mutating func add(_ text: String, app: String, date: Date = Date()) {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(maxLength))
        guard trimmed.count >= minLength else { return }
        if let index = samples.lastIndex(where: { $0.app == app }),
           trimmed.hasPrefix(samples[index].text) || samples[index].text.hasPrefix(trimmed) {
            if trimmed.count >= samples[index].text.count { samples[index] = Sample(app: app, text: trimmed, date: date) }
            return
        }
        samples.append(Sample(app: app, text: trimmed, date: date))
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    mutating func removeAll() { samples.removeAll() }

    var count: Int { samples.count }

    /// The newest samples long enough to show a style, from this app first.
    func relevant(for app: String, limit: Int = 3) -> [String] {
        let long = samples.reversed().filter { $0.text.count >= minPromptLength }
        let same = long.filter { $0.app == app }
        let others = long.filter { $0.app != app }
        return (same + others).prefix(limit).map(\.text)
    }

    /// Words the user writes often, weighted 0…1. Short common words are left out: the model knows those.
    func vocabulary(limit: Int = 400) -> [String: Double] {
        var counts: [String: Int] = [:]
        for sample in samples {
            for word in sample.text.split(whereSeparator: { !($0.isLetter || $0 == "'" || $0 == "’") }) where word.count >= 4 {
                counts[String(word), default: 0] += 1
            }
        }
        let frequent = counts.filter { $0.value >= 2 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(limit)
        guard let top = frequent.first?.value else { return [:] }
        let scale = log(Double(top) + 1)
        return Dictionary(uniqueKeysWithValues: frequent.map { ($0.key, log(Double($0.value) + 1) / scale) })
    }
}

/// The phrases the user writes again and again, learned from their own writing (`CompletionSamples`): after "met vriendelijke"
/// comes "groet", after "ik hoop dat" comes "het goed met je gaat". It counts which word follows the one to three words before
/// it, newer writing counting more, and suggests the words that nearly always follow at once, without the model. A phrase
/// turned down with Escape counts less from then on.
struct CompletionPhrases: Sendable {
    /// The words before (up to `order`, normalized, joined by spaces) → the word that came next, as written → weight.
    private(set) var next: [String: [String: Double]] = [:]
    /// `rejectionKey` → times turned down.
    private(set) var rejected: [String: Int] = [:]

    /// Words before the next one that are looked at.
    static let order = 3
    /// Words before a turned-down word that its rejection is kept for: "met vriendelijke" counts less after any greeting.
    static let rejectionContext = 2
    /// Writing this old counts half.
    static let halfLife: TimeInterval = 60 * 24 * 3600
    /// What one rejection takes off a word's weight (a fresh occurrence weighs 1).
    static let rejectionWeight = 2.0

    init() {}

    init(samples: [CompletionSamples.Sample], rejected: [String: Int] = [:], now: Date = Date()) {
        self.rejected = rejected
        for sample in samples {
            let weight = pow(0.5, max(0, now.timeIntervalSince(sample.date)) / Self.halfLife)
            // Suggestions stay on one line: phrases are learned within a line.
            for line in sample.text.split(whereSeparator: \.isNewline) {
                let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard words.count >= 2 else { continue }
                let keys = words.map(Self.normalized)
                for index in 1..<words.count where !keys[index].isEmpty {
                    for length in 1...min(Self.order, index) {
                        let context = keys[(index - length)..<index]
                        // A dash or a lone symbol breaks the phrase.
                        if context.contains("") { break }
                        next[context.joined(separator: " "), default: [:]][words[index], default: 0] += weight
                    }
                }
            }
        }
    }

    var isEmpty: Bool { next.isEmpty }

    mutating func reject(_ key: String) { rejected[key, default: 0] += 1 }

    /// How the text before the cursor goes on, as far as the user's own phrases are sure of it: the rest of the word being
    /// typed, then whole words, up to the end of a sentence. Starts with a space when it starts a new word. Nil when no phrase
    /// fits well enough.
    func predict(after before: String, maxWords: Int) -> String? {
        guard maxWords > 0, !next.isEmpty else { return nil }
        var (context, partial) = Self.split(before)
        var result = ""
        var count = 0
        while count < maxWords, let word = choose(after: context, startingWith: partial, penalized: count == 0) {
            result += partial.isEmpty ? " " + word : String(word.dropFirst(partial.count))
            partial = ""
            context.append(Self.normalized(word))
            count += 1
            if let last = word.last, ".!?".contains(last) { break }
        }
        return result.isEmpty ? nil : result
    }

    /// Identifies the first word of a learned suggestion after `before`, to count less once it is turned down.
    static func rejectionKey(before: String, suggestion: String) -> String? {
        let (context, partial) = split(before)
        let rest = partial.isEmpty ? suggestion.drop(while: \.isWhitespace) : Substring(suggestion)
        let word = normalized(partial + String(rest.prefix { !$0.isWhitespace }))
        guard !context.isEmpty, !word.isEmpty else { return nil }
        return context.suffix(rejectionContext).joined(separator: " ") + "|" + word
    }

    /// The phrases written most often, for the prompt: three words or more, the last one nearly always following the others.
    func frequent(limit: Int = 12) -> [String] {
        var found: [(weight: Double, phrase: String)] = []
        for (context, followers) in next where context.contains(" ") {
            let total = followers.values.reduce(0, +)
            guard let best = followers.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), best.value >= 3, best.value / total >= 0.6 else { continue }
            found.append((best.value, context + " " + best.key))
        }
        var result: [(phrase: String, words: String)] = []
        for entry in found.sorted(by: { ($0.weight, $1.phrase) > ($1.weight, $0.phrase) }) where result.count < limit {
            let words = entry.phrase.split(separator: " ").map { Self.normalized(String($0)) }.joined(separator: " ")
            // Not the same phrase again, one word shorter or longer.
            if result.contains(where: { $0.words.contains(words) || words.contains($0.words) }) { continue }
            result.append((entry.phrase, words))
        }
        return result.map(\.phrase)
    }

    /// The word that follows `context`, beginning with `partial` (the word being typed). The longest context with enough
    /// writing behind it decides; when it has enough but no clear winner, there is no suggestion.
    private func choose(after context: [String], startingWith partial: String, penalized: Bool) -> String? {
        let typed = partial.lowercased()
        let recent = context.suffix(Self.rejectionContext).joined(separator: " ")
        for length in stride(from: min(Self.order, context.count), through: 1, by: -1) {
            let key = context.suffix(length)
            if key.contains("") { continue }
            guard let followers = next[key.joined(separator: " ")] else { continue }
            // Grouped by the word itself; the form written most often is the one typed.
            var totals: [String: Double] = [:]
            var forms: [String: (weight: Double, word: String)] = [:]
            for (word, weight) in followers where word.count > partial.count && word.lowercased().hasPrefix(typed) {
                let normal = Self.normalized(word)
                totals[normal, default: 0] += weight
                if let form = forms[normal], (form.weight, word) >= (weight, form.word) { continue }
                forms[normal] = (weight, word)
            }
            let total = totals.values.reduce(0, +)
            let (minimum, share) = length == 1 ? (4.0, 0.75) : (2.5, 0.6)
            // Too little writing after these words to tell: fewer words before may know.
            guard total >= minimum else { continue }
            let scored = totals.map { entry -> (score: Double, normal: String) in
                let penalty = penalized ? Double(rejected[recent + "|" + entry.key] ?? 0) * Self.rejectionWeight : 0
                return (entry.value - penalty, entry.key)
            }
            guard let best = scored.max(by: { ($0.score, $1.normal) < ($1.score, $0.normal) }),
                  best.score >= minimum, best.score / total >= share else { return nil }
            return forms[best.normal]?.word
        }
        return nil
    }

    /// The words of the line the cursor is on, normalized, and the word the cursor is in (empty after a space). A word that
    /// ends in punctuation ("groet,") is finished: the next one starts after a space.
    private static func split(_ before: String) -> (context: [String], partial: String) {
        let line = before.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last.map(String.init) ?? ""
        var words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        var partial = ""
        if let last = line.last, !last.isWhitespace, let word = words.popLast() {
            if last.isLetter || last.isNumber { partial = word } else { words.append(word) }
        }
        return (words.map(normalized), partial)
    }

    /// Lowercased, without punctuation or symbols around it: "Groet," and "groet" are the same word.
    static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
    }
}

/// Counters per day and per app, for Settings › Autocomplete › Statistics. Files written by older versions (without `takes` or
/// `apps`) still read: missing counters start at zero.
struct CompletionStats: Codable, Equatable {
    struct Day: Codable, Equatable {
        /// Suggestions shown.
        var shown = 0
        /// Suggestions taken (at least one word of it).
        var accepted = 0
        /// Times a key took something: every word, every "all", every emoji or fix.
        var takes = 0
        var words = 0
        var characters = 0

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            shown = try c.decodeIfPresent(Int.self, forKey: .shown) ?? 0
            accepted = try c.decodeIfPresent(Int.self, forKey: .accepted) ?? 0
            takes = try c.decodeIfPresent(Int.self, forKey: .takes) ?? accepted
            words = try c.decodeIfPresent(Int.self, forKey: .words) ?? 0
            characters = try c.decodeIfPresent(Int.self, forKey: .characters) ?? 0
        }
    }

    /// One app's share.
    struct AppCount: Codable, Equatable {
        var takes = 0
        var words = 0
    }

    /// By day, "2026-10-19".
    var days: [String: Day] = [:]
    /// By bundle id.
    var apps: [String: AppCount] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = try c.decodeIfPresent([String: Day].self, forKey: .days) ?? [:]
        apps = try c.decodeIfPresent([String: AppCount].self, forKey: .apps) ?? [:]
    }

    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func day(_ date: Date = Date()) -> Day { days[Self.key(for: date)] ?? Day() }

    mutating func recordShown(on date: Date = Date()) { days[Self.key(for: date), default: Day()].shown += 1 }

    /// - Parameters:
    ///   - first: false for the second, third… word taken from the same suggestion.
    ///   - app: the bundle id of the app it was typed in.
    mutating func recordAccepted(_ text: String, first: Bool, app: String? = nil, on date: Date = Date()) {
        var day = days[Self.key(for: date), default: Day()]
        let words = text.completionWordCount
        if first { day.accepted += 1 }
        day.takes += 1
        day.words += words
        day.characters += text.count
        days[Self.key(for: date)] = day
        if let app, !app.isEmpty {
            apps[app, default: AppCount()].takes += 1
            apps[app, default: AppCount()].words += words
        }
    }

    var totalWords: Int { days.values.reduce(0) { $0 + $1.words } }
    var totalShown: Int { days.values.reduce(0) { $0 + $1.shown } }
    var totalAccepted: Int { days.values.reduce(0) { $0 + $1.accepted } }
    var totalTakes: Int { days.values.reduce(0) { $0 + $1.takes } }
    var totalCharacters: Int { days.values.reduce(0) { $0 + $1.characters } }

    /// Share of shown suggestions taken, 0…1.
    var acceptance: Double { totalShown == 0 ? 0 : min(1, Double(totalAccepted) / Double(totalShown)) }

    /// Typing at about 40 words a minute: the minutes this saved.
    var minutesSaved: Double { Double(totalWords) / 40 }

    /// The last `count` days, oldest first, days without use included.
    func recent(_ count: Int, endingAt end: Date = Date(), calendar: Calendar = .current) -> [(date: Date, day: Day)] {
        (0..<count).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: end).map { ($0, day($0)) }
        }
    }

    /// The last seven days added up, today included.
    func week(endingAt end: Date = Date(), calendar: Calendar = .current) -> Day {
        recent(7, endingAt: end, calendar: calendar).reduce(into: Day()) { total, entry in
            total.shown += entry.day.shown
            total.accepted += entry.day.accepted
            total.takes += entry.day.takes
            total.words += entry.day.words
            total.characters += entry.day.characters
        }
    }

    /// Days in a row, up to today (or yesterday, when today has nothing yet), on which something was taken.
    func streak(endingAt end: Date = Date(), calendar: Calendar = .current) -> Int {
        var date = end
        if day(date).takes == 0, let yesterday = calendar.date(byAdding: .day, value: -1, to: date) { date = yesterday }
        var count = 0
        while day(date).takes > 0 {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = previous
        }
        return count
    }

    /// The apps used most, by times taken.
    func topApps(_ limit: Int = 5) -> [(bundleID: String, count: AppCount)] {
        apps.sorted { ($0.value.takes, $1.key) > ($1.value.takes, $0.key) }.prefix(limit).map { ($0.key, $0.value) }
    }
}
