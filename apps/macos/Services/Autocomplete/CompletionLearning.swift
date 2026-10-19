import Foundation

/// What the user wrote, so suggestions sound like them. Only on this Mac, secrets taken out first, deletable in Settings.
/// After Typist (MIT, © 2026 Brody Salvucci).
struct CompletionSamples: Codable, Equatable {
    struct Sample: Codable, Equatable {
        var app: String
        var text: String
        var date: Date
    }

    private(set) var samples: [Sample] = []
    var capacity = 400
    var maxLength = 2_000
    var minLength = 40

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

    /// The newest samples, from this app first.
    func relevant(for app: String, limit: Int = 3) -> [String] {
        let same = samples.reversed().filter { $0.app == app }
        let others = samples.reversed().filter { $0.app != app }
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

/// Counters per day, for Settings.
struct CompletionStats: Codable, Equatable {
    struct Day: Codable, Equatable {
        var shown = 0
        var accepted = 0
        var words = 0
        var characters = 0
    }

    /// By day, "2026-10-19".
    var days: [String: Day] = [:]

    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func day(_ date: Date = Date()) -> Day { days[Self.key(for: date)] ?? Day() }

    mutating func recordShown(on date: Date = Date()) { days[Self.key(for: date), default: Day()].shown += 1 }

    /// - Parameter first: false for the second, third… word taken from the same suggestion.
    mutating func recordAccepted(_ text: String, first: Bool, on date: Date = Date()) {
        var day = days[Self.key(for: date), default: Day()]
        if first { day.accepted += 1 }
        day.words += text.completionWordCount
        day.characters += text.count
        days[Self.key(for: date)] = day
    }

    var totalWords: Int { days.values.reduce(0) { $0 + $1.words } }
    var totalShown: Int { days.values.reduce(0) { $0 + $1.shown } }
    var totalAccepted: Int { days.values.reduce(0) { $0 + $1.accepted } }
    var totalCharacters: Int { days.values.reduce(0) { $0 + $1.characters } }

    /// Share of shown suggestions taken, 0…1.
    var acceptance: Double { totalShown == 0 ? 0 : Double(totalAccepted) / Double(totalShown) }

    /// Typing at about 40 words a minute: the minutes this saved.
    var minutesSaved: Double { Double(totalWords) / 40 }

    /// The last `count` days, oldest first, days without use included.
    func recent(_ count: Int, endingAt end: Date = Date(), calendar: Calendar = .current) -> [(date: Date, day: Day)] {
        (0..<count).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: end).map { ($0, day($0)) }
        }
    }
}
