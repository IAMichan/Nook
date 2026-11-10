import Foundation

// The usage widget on the iPhone's Home Screen (docs/COMPANION.md, "Usage widget"): the plan limits of every agent account
// as the Mac last reported them (`UsageDigest.accounts`), kept by the app in its app group, and the widget's timeline
// built from them: one entry now and one at every reset, so a limit that resets shows so on time without the app or the
// Mac. Standalone Foundation, so the widget extension compiles it without the rest of the protocol.

/// The limits as the app last heard them from its Mac.
struct UsageSnapshot: Codable, Equatable, Sendable {
    struct Limit: Codable, Equatable, Sendable {
        var label: String
        var percent: Double
        var resetsAt: Double?
    }

    struct Account: Codable, Equatable, Identifiable, Sendable {
        var id: String
        /// The agent's short name ("Claude", "Codex").
        var agent: String
        var account: String
        var limits: [Limit]
    }

    var macName: String
    var accounts: [Account]
    /// When the Mac answered (seconds since 1970).
    var taken: Double

    static let fileName = "usage-widget.json"
}

enum UsageWidgetTimeline {
    /// One limit as a row shows it at a moment.
    struct Row: Equatable, Identifiable, Sendable {
        var id: String
        var agent: String
        var account: String
        var label: String
        /// 0…100; 0 once the limit reset.
        var percent: Double
        var resetsAt: Date?
        /// The reset time passed since the Mac said how much was used.
        var reset: Bool
    }

    struct Entry: Equatable, Sendable {
        var date: Date
        var rows: [Row]
        var macName: String
        var taken: Date?
        /// What the Mac said is older than `staleAfter`: the widget says so instead of looking current.
        var stale: Bool
    }

    /// Older than this, the numbers read as "as of" rather than as now.
    static let staleAfter: TimeInterval = 6 * 3600
    /// How far ahead the timeline reaches; WidgetKit asks again after it.
    static let horizon: TimeInterval = 24 * 3600
    static let maxEntries = 24

    /// The rows at `date`: per account its most used limit first, the accounts with the most used limit first. A limit
    /// whose reset passed reads 0 and `reset`.
    static func rows(_ snapshot: UsageSnapshot, at date: Date) -> [Row] {
        let now = date.timeIntervalSince1970
        let accounts = snapshot.accounts.map { account -> [Row] in
            account.limits.map { limit in
                let passed = limit.resetsAt.map { $0 <= now } ?? false
                return Row(id: account.id + "|" + limit.label, agent: account.agent, account: account.account, label: limit.label,
                           percent: passed ? 0 : min(max(limit.percent, 0), 100),
                           resetsAt: passed ? nil : limit.resetsAt.map(Date.init(timeIntervalSince1970:)), reset: passed)
            }.sorted { $0.percent > $1.percent }
        }.filter { !$0.isEmpty }
        return accounts.sorted { ($0.first?.percent ?? 0) > ($1.first?.percent ?? 0) }.flatMap { $0 }
    }

    /// The most used limit of each account, for the small widget.
    static func headline(_ rows: [Row], count: Int) -> [Row] {
        var seen = Set<String>()
        return Array(rows.filter { seen.insert($0.agent + "|" + $0.account).inserted }.prefix(count))
    }

    /// Entries from `now`: one now, then one at each reset within `horizon`, and one when the numbers turn stale.
    static func entries(_ snapshot: UsageSnapshot?, now: Date) -> [Entry] {
        guard let snapshot else { return [Entry(date: now, rows: [], macName: "", taken: nil, stale: false)] }
        let taken = Date(timeIntervalSince1970: snapshot.taken)
        var moments: Set<Double> = [now.timeIntervalSince1970]
        let end = now.addingTimeInterval(horizon).timeIntervalSince1970
        for account in snapshot.accounts {
            for limit in account.limits {
                if let reset = limit.resetsAt, reset > now.timeIntervalSince1970, reset <= end { moments.insert(reset) }
            }
        }
        let staleAt = taken.addingTimeInterval(staleAfter).timeIntervalSince1970
        if staleAt > now.timeIntervalSince1970, staleAt <= end { moments.insert(staleAt) }
        return moments.sorted().prefix(maxEntries).map { moment in
            let date = Date(timeIntervalSince1970: moment)
            return Entry(date: date, rows: rows(snapshot, at: date), macName: snapshot.macName, taken: taken,
                         stale: moment >= staleAt)
        }
    }
}
