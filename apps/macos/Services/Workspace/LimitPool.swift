import Foundation

/// Every subscription account of one agent read as one pool, as the Usage limits sheet shows it (the same model as
/// t3code's limit pools): per window (5 hours, week) how much of the pool is left and whether it is spent ahead of the
/// clock, with a column per account that stays in the same place across windows, and which reset comes next and how
/// much of the pool it hands back. Everything reads as room left, not as what was used. One account is a pool of one.
struct LimitPool: Equatable, Sendable {
    /// Spending against the window's clock: more than 5 points ahead of the time elapsed, level with it, or behind it.
    enum Pace: String, Equatable, Sendable {
        case ahead, on, under
    }

    /// The kind of window, from its length: the session window sorts before the week, the week before the rest.
    enum Kind: Int, Comparable, Sendable {
        case session, weekly, other

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }

        init(duration: TimeInterval?) {
            guard let duration else { self = .other; return }
            if duration <= 24 * 3600 { self = .session } else if duration <= 8 * 86_400 { self = .weekly } else { self = .other }
        }
    }

    struct Limit: Equatable, Sendable {
        var label: String
        /// Used, 0...100.
        var used: Double
        var resetsAt: Date?
        /// How long the window lasts, when known; with `resetsAt` it places the window's start and so its pace.
        var duration: TimeInterval? = nil
    }

    struct Account: Equatable, Sendable {
        var id: String
        var name: String
        var limits: [Limit]
    }

    /// One account in one window.
    struct Member: Equatable, Identifiable, Sendable {
        var accountID: String
        var name: String
        /// The account's window, as it counts for the pool; nil when the account does not report this window (a gap).
        var limit: Limit?
        /// How much of this account its next reset gives back, 0...100.
        var refill: Double
        var id: String { accountID }

        /// Left, 0...100, rounded as it is shown; nil for a gap.
        var left: Int? { limit.map { LimitPool.left($0.used) } }
        /// Used, 0...100, as the modal shows it; nil for a gap.
        var used: Int? { left.map { 100 - $0 } }
    }

    struct Reset: Equatable, Sendable {
        var accountID: String
        var at: Date
        /// How much of the pool (0...100) this reset gives back.
        var restores: Int
    }

    struct Window: Equatable, Identifiable, Sendable {
        var label: String
        var kind: Kind
        /// Left of the whole pool, 0...100: the mean over the accounts that report the window.
        var left: Int
        var pace: Pace?
        /// One per account of the pool, in the pool's account order; a member without a limit is a gap.
        var columns: [Member]
        /// The coming resets, soonest first.
        var resets: [Reset]
        var id: String { label }
        /// Used of the whole pool, 0...100, as the modal shows it.
        var used: Int { 100 - left }

        /// The first reset that gives anything back.
        var nextRefill: Reset? { resets.first { $0.restores > 0 } }
    }

    var accounts: [Account] = []
    var windows: [Window] = []

    /// Nil when no account reports a limit.
    static func make(_ accounts: [Account], now: Date = Date()) -> LimitPool? {
        let reporting = accounts.filter { !$0.limits.isEmpty }
        guard !reporting.isEmpty else { return nil }

        // Accounts in the order their first window resets, soonest first, then by name.
        let first = reporting.flatMap(\.limits).min { Kind(duration: $0.duration) < Kind(duration: $1.duration) }
        func firstReset(_ account: Account) -> Date {
            guard let first, let limit = account.limits.first(where: { $0.label == first.label }) else { return .distantFuture }
            return member(account, limit, now: now).limit?.resetsAt ?? .distantFuture
        }
        let order = reporting.sorted {
            let (a, b) = (firstReset($0), firstReset($1))
            return a != b ? a < b : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        var labels: [String] = []
        for account in order { for limit in account.limits where !labels.contains(limit.label) { labels.append(limit.label) } }

        let windows = labels.map { label -> Window in
            let columns = order.map { account -> Member in
                guard let limit = account.limits.first(where: { $0.label == label }) else {
                    return Member(accountID: account.id, name: account.name, limit: nil, refill: 0)
                }
                return member(account, limit, now: now)
            }
            let members = columns.filter { $0.limit != nil }
            let used = members.map { $0.limit!.used }.reduce(0, +) / Double(max(members.count, 1))
            // Pace counts only windows with a clock; the others add spending without elapsed time.
            let timed = members.compactMap { member -> (used: Double, elapsed: Double)? in
                guard let limit = member.limit, let elapsed = elapsedShare(limit, now: now) else { return nil }
                return (limit.used, elapsed)
            }
            let pace = timed.isEmpty ? nil : paceOf(used: timed.map(\.used).reduce(0, +) / Double(timed.count),
                                                     elapsed: timed.map(\.elapsed).reduce(0, +) / Double(timed.count))
            let resets = members.compactMap { member -> Reset? in
                guard let at = member.limit?.resetsAt, at > now else { return nil }
                return Reset(accountID: member.accountID, at: at, restores: Int((member.refill / Double(members.count)).rounded()))
            }
            .sorted { $0.at < $1.at }
            // From the window as reported: a spent session window loses its clock, not its kind.
            let kind = Kind(duration: order.lazy.compactMap { $0.limits.first { $0.label == label } }.first?.duration)
            return Window(label: label, kind: kind, left: left(used), pace: pace, columns: columns, resets: resets)
        }
        // Stable: windows of one kind keep the order the agent gives them.
        let sorted = windows.enumerated().sorted { $0.element.kind != $1.element.kind ? $0.element.kind < $1.element.kind : $0.offset < $1.offset }
        return LimitPool(accounts: order, windows: sorted.map(\.element))
    }

    /// An account's window as the pool counts it. While the account's week is spent, its session window is spent too: it
    /// reads as empty, without a pace, and comes back with whichever of the two resets frees it.
    static func member(_ account: Account, _ limit: Limit, now: Date) -> Member {
        let plain = Member(accountID: account.id, name: account.name, limit: limit, refill: limit.used)
        guard Kind(duration: limit.duration) == .session,
              let week = account.limits.first(where: { Kind(duration: $0.duration) == .weekly && $0.used >= 100 }) else { return plain }
        var spent = limit
        spent.used = 100
        spent.duration = nil
        spent.resetsAt = nil
        var refill = 0.0
        // Without both clocks there is no telling when the blocked quota comes back.
        if let weekReset = week.resetsAt, let sessionReset = limit.resetsAt, weekReset > now, sessionReset > now {
            if sessionReset <= weekReset {
                spent.resetsAt = weekReset
                refill = 100
            } else if limit.used >= 100 {
                spent.resetsAt = sessionReset
                refill = 100
            } else {
                spent.resetsAt = weekReset
                refill = 100 - max(0, min(100, limit.used))
            }
        }
        return Member(accountID: account.id, name: account.name, limit: spent, refill: refill)
    }

    /// What is left of a window, rounded: 100 minus what was used.
    static func left(_ used: Double) -> Int {
        Int((100 - max(0, min(100, used))).rounded())
    }

    /// How far `now` is into the window, 0...1; nil without a clock.
    static func elapsedShare(_ limit: Limit, now: Date) -> Double? {
        guard let resetsAt = limit.resetsAt, let duration = limit.duration, duration > 0 else { return nil }
        return max(0, min(1, (duration - resetsAt.timeIntervalSince(now)) / duration))
    }

    /// The window's time still to come, 0...100: where the even-pace line sits on a bar that shows what is left.
    static func timeLeft(_ limit: Limit, now: Date) -> Int? {
        elapsedShare(limit, now: now).map { Int(((1 - $0) * 100).rounded()) }
    }

    /// The window's time gone by, 0...100: where the even-pace line sits on a bar that shows what was used.
    static func timeElapsed(_ limit: Limit, now: Date) -> Int? {
        timeLeft(limit, now: now).map { 100 - $0 }
    }

    static func pace(_ limit: Limit, now: Date) -> Pace? {
        elapsedShare(limit, now: now).map { paceOf(used: limit.used, elapsed: $0) }
    }

    static func paceOf(used: Double, elapsed: Double) -> Pace {
        let gap = used - elapsed * 100
        if gap > 5 { return .ahead }
        if gap < -5 { return .under }
        return .on
    }
}
