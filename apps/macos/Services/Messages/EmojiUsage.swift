import Foundation

/// The emoji you choose in chats (the emoji picker and the quick reaction row), so the picker opens with the ones you use
/// most: the "Frequently used" section and the clock tab. Shared by every chat integration, kept on this Mac only.
///
/// Ranked by "frecency", as the system emoji picker does: every choice adds one point, and points lose half their weight
/// every two weeks. A daily emoji stays on top; one you use a lot this week rises fast; one you stopped using sinks.
/// Foundation only; tested in Tests/NookTests/EmojiUsageTests.swift.
final class EmojiUsage {
    static let shared = EmojiUsage()

    /// The decayed score at `last` (`DecayedCounter`'s entry, saved as before).
    typealias Entry = DecayedCounter<String>.Entry

    /// How many the picker shows: two rows of nine.
    static let shownCount = 18
    /// How many are remembered; the rest is dropped so the stored list stays small.
    static let keptCount = 64
    /// After this long a point weighs half.
    static let halfLife: TimeInterval = 14 * 24 * 3600

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "chatEmojiUsage") {
        self.defaults = defaults
        self.key = key
    }

    private(set) var entries: [String: Entry] {
        get {
            guard let data = defaults.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
            return decoded
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    /// `entry`'s score as of `now`.
    static func score(_ entry: Entry, at now: Date) -> Double {
        Decay.value(entry.score, elapsed: now.timeIntervalSince(entry.last), halfLife: halfLife)
    }

    /// Counts one choice of `character`.
    func record(_ character: String, at now: Date = Date()) {
        guard !character.isEmpty else { return }
        var all = entries
        let previous = all[character].map { Self.score($0, at: now) } ?? 0
        all[character] = Entry(score: previous + 1, last: now)
        if all.count > Self.keptCount {
            let kept = Self.order(all, at: now).prefix(Self.keptCount)
            all = all.filter { kept.contains($0.key) }
        }
        entries = all
    }

    /// The emoji used most, most first; at most `limit`.
    func ranked(limit: Int = EmojiUsage.shownCount, at now: Date = Date()) -> [String] {
        Array(Self.order(entries, at: now).prefix(limit))
    }

    /// `emoji` with the ones you use first (most first), the others after in their own order.
    func usedFirst<T>(_ emoji: [T], character: (T) -> String, at now: Date = Date()) -> [T] {
        let rank = Dictionary(uniqueKeysWithValues: Self.order(entries, at: now).enumerated().map { ($1, $0) })
        guard !rank.isEmpty else { return emoji }
        return emoji.enumerated().sorted { lhs, rhs in
            let left = rank[character(lhs.element)] ?? Int.max, right = rank[character(rhs.element)] ?? Int.max
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Highest score first; the last used first on a tie.
    private static func order(_ entries: [String: Entry], at now: Date) -> [String] {
        struct Ranked { let character: String; let score: Double; let last: Date }
        let ranked = entries.map { Ranked(character: $0.key, score: score($0.value, at: now), last: $0.value.last) }
        return ranked.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.last != rhs.last { return lhs.last > rhs.last }
            return lhs.character < rhs.character
        }.map(\.character)
    }
}
