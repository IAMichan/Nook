import Foundation

/// A cache bounded by what its values weigh rather than by how many there are: a few long transcripts or answers can take
/// as much as thousands of short ones. When an insert takes it over `budget`, the least recently used entries go until it
/// is back at three quarters of it, so a full cache does not sort itself on every insert. Not thread-safe: the owner
/// locks or keeps it on one actor.
struct ByteBudgetCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var cost: Int
        var used: UInt64
    }

    let budget: Int
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    /// What the entries weigh together.
    private(set) var bytes = 0

    init(budget: Int) {
        self.budget = budget
    }

    var count: Int { entries.count }

    /// The value, marked as just used.
    mutating func value(_ key: Key) -> Value? {
        guard entries[key] != nil else { return nil }
        clock += 1
        entries[key]?.used = clock
        return entries[key]?.value
    }

    /// The value, without marking it used.
    func peek(_ key: Key) -> Value? { entries[key]?.value }

    /// Keeps `value` at `cost` bytes. A value heavier than the whole budget is not kept.
    mutating func set(_ value: Value, for key: Key, cost: Int) {
        remove(key)
        let cost = max(cost, 1)
        guard cost <= budget else { return }
        clock += 1
        entries[key] = Entry(value: value, cost: cost, used: clock)
        bytes += cost
        guard bytes > budget else { return }
        let target = budget * 3 / 4
        for (old, entry) in entries.sorted(by: { $0.value.used < $1.value.used }) {
            guard bytes > target, old != key else { break }
            entries[old] = nil
            bytes -= entry.cost
        }
    }

    mutating func remove(_ key: Key) {
        if let gone = entries.removeValue(forKey: key) { bytes -= gone.cost }
    }

    mutating func removeAll() {
        entries.removeAll()
        bytes = 0
    }
}
