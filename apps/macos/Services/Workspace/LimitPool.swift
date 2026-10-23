import Foundation

/// Every subscription account of one agent read as one pool, as Usage › Limits shows it: per window (5 hours,
/// week) how much of the pool is left, with a segment per account that stays in the same column across windows, and
/// when the next reset comes and how much of the pool it hands back. Accounts are ordered by their next refill of the
/// first window, soonest first.
struct LimitPool: Equatable, Sendable {
    struct Limit: Equatable, Sendable {
        var label: String
        /// Used, 0...100.
        var used: Double
        var resetsAt: Date?
    }

    struct Account: Equatable, Sendable {
        var id: String
        var name: String
        var limits: [Limit]
    }

    struct Segment: Equatable, Identifiable, Sendable {
        var accountID: String
        var name: String
        /// Left in this account, 0...100; nil when the account does not report this window (a gap in the bar).
        var left: Double?
        var resetsAt: Date?
        var id: String { accountID }
    }

    struct Window: Equatable, Identifiable, Sendable {
        var label: String
        /// Left of the whole pool, 0...100: the mean over the accounts that report the window.
        var left: Double
        var segments: [Segment]
        /// The next reset among the accounts, and how much of the pool (0...100) it gives back.
        var nextReset: Date?
        var restores: Double
        var id: String { label }
    }

    var windows: [Window] = []

    /// Nil with fewer than two accounts: one account needs no pool.
    static func make(_ accounts: [Account], now: Date = Date()) -> LimitPool? {
        let reporting = accounts.filter { !$0.limits.isEmpty }
        guard reporting.count >= 2 else { return nil }
        var labels: [String] = []
        for account in reporting { for limit in account.limits where !labels.contains(limit.label) { labels.append(limit.label) } }
        guard let first = labels.first else { return nil }

        func reset(_ account: Account) -> Date {
            account.limits.first { $0.label == first }?.resetsAt.flatMap { $0 > now ? $0 : nil } ?? .distantFuture
        }
        let order = reporting.sorted { reset($0) != reset($1) ? reset($0) < reset($1) : $0.name < $1.name }

        let windows: [Window] = labels.map { label in
            let segments = order.map { account -> Segment in
                let limit = account.limits.first { $0.label == label }
                return Segment(accountID: account.id, name: account.name,
                               left: limit.map { max(0, min(100, 100 - $0.used)) },
                               resetsAt: limit?.resetsAt.flatMap { $0 > now ? $0 : nil })
            }
            let known = segments.compactMap(\.left)
            let left = known.isEmpty ? 0 : known.reduce(0, +) / Double(known.count)
            let next = segments.compactMap { segment in segment.resetsAt.map { (segment, $0) } }.min { $0.1 < $1.1 }
            let restores = next.flatMap { pair in pair.0.left.map { (100 - $0) / Double(max(known.count, 1)) } } ?? 0
            return Window(label: label, left: left, segments: segments, nextReset: next?.1, restores: restores)
        }
        return LimitPool(windows: windows)
    }
}
