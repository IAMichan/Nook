import Foundation

/// Halving with time, the one formula every fading count in Nook uses.
enum Decay {
    /// `value` after `elapsed` seconds, halving every `halfLife`. Time running backwards (a clock change) fades nothing.
    static func value(_ value: Double, elapsed: TimeInterval, halfLife: TimeInterval) -> Double {
        guard halfLife > 0 else { return value }
        return value * pow(0.5, max(0, elapsed) / halfLife)
    }
}

/// Counts that fade: every point loses half its weight each `halfLife`, so what happened lately counts more than what
/// happened long ago ("frecency"). A key can also gather negative evidence (a dismissal, a rejection), weighed by
/// `negativeWeight` against the positive. Memory strength, the emoji you use, the sessions you open, the phrases you
/// write and the feedback on Nook's notices all fade this way; each keeps its own half-life.
/// Foundation only; tested in Tests/NookTests/DecayedCounterTests.swift.
struct DecayedCounter<Key: Hashable & Codable & Sendable>: Codable, Equatable, Sendable {
    /// One key's points, as they stood at `last`.
    struct Entry: Codable, Equatable, Sendable {
        /// The positive points at `last`.
        var score: Double
        /// The negative points at `last`.
        var negative: Double = 0
        var last: Date

        init(score: Double, negative: Double = 0, last: Date) {
            self.score = score
            self.negative = negative
            self.last = last
        }

        /// Read back from a list saved before negative points existed (`EmojiUsage`'s), too.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            score = try container.decode(Double.self, forKey: .score)
            negative = try container.decodeIfPresent(Double.self, forKey: .negative) ?? 0
            last = try container.decode(Date.self, forKey: .last)
        }

        private enum CodingKeys: String, CodingKey { case score, negative, last }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(score, forKey: .score)
            if negative != 0 { try container.encode(negative, forKey: .negative) }
            try container.encode(last, forKey: .last)
        }
    }

    var halfLife: TimeInterval
    /// How much one negative point weighs against a positive one in `score`.
    var negativeWeight: Double
    /// At most this many keys; the weakest fall away first.
    var limit: Int
    private(set) var entries: [Key: Entry] = [:]

    init(halfLife: TimeInterval, negativeWeight: Double = 1, limit: Int = 500) {
        self.halfLife = halfLife
        self.negativeWeight = negativeWeight
        self.limit = limit
    }

    /// `entry` as it stands at `now`.
    func faded(_ entry: Entry, at now: Date) -> Entry {
        let elapsed = now.timeIntervalSince(entry.last)
        return Entry(score: Decay.value(entry.score, elapsed: elapsed, halfLife: halfLife),
                     negative: Decay.value(entry.negative, elapsed: elapsed, halfLife: halfLife), last: max(now, entry.last))
    }

    /// Adds points to `key` at `now`: `positive` and `negative` both at full weight.
    mutating func add(_ key: Key, positive: Double = 0, negative: Double = 0, at now: Date = Date()) {
        var entry = entries[key].map { faded($0, at: now) } ?? Entry(score: 0, last: now)
        entry.score += positive
        entry.negative += negative
        entries[key] = entry
        trim(at: now)
    }

    /// The positive and negative points of `key` at `now`.
    func points(_ key: Key, at now: Date = Date()) -> (positive: Double, negative: Double) {
        guard let entry = entries[key] else { return (0, 0) }
        let current = faded(entry, at: now)
        return (current.score, current.negative)
    }

    /// Positive points less the weighed negative ones, at `now`.
    func score(_ key: Key, at now: Date = Date()) -> Double {
        let points = points(key, at: now)
        return points.positive - negativeWeight * points.negative
    }

    /// The keys, highest score first (ties by key order is not defined: callers sort further when they need to).
    func ranked(at now: Date = Date()) -> [Key] {
        entries.keys.map { ($0, score($0, at: now)) }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    mutating func remove(_ key: Key) { entries[key] = nil }

    /// Keeps the `limit` keys with the most evidence either way.
    private mutating func trim(at now: Date) {
        guard entries.count > limit else { return }
        let kept = entries.map { key, entry -> (Key, Double) in
            let current = faded(entry, at: now)
            return (key, current.score + current.negative)
        }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
        let keep = Set(kept)
        entries = entries.filter { keep.contains($0.key) }
    }
}
