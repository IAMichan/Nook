import Foundation

// Usage of every agent on this Mac, read from the agents' own transcripts (Claude Code, Codex, Gemini CLI, Antigravity),
// and what it would cost at API prices, as Settings › Coding agents shows it: per hour or day, per agent and per
// model, split by token type, with cache savings. Foundation only, so it is tested on its own.

/// Tokens of one kind or another. `input` is uncached input; `cacheRead` input served from the prompt cache; `cacheWrite`
/// input written to it.
struct UsageTokens: Codable, Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    /// Everything the model processed.
    var total: Int { input + output + cacheRead + cacheWrite }
    /// All input, cached or not.
    var allInput: Int { input + cacheRead + cacheWrite }

    /// The share of input served from the cache, nil without input.
    var cacheHitRate: Double? {
        allInput > 0 ? Double(cacheRead) / Double(allInput) : nil
    }

    static func + (lhs: UsageTokens, rhs: UsageTokens) -> UsageTokens {
        UsageTokens(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
                    cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite)
    }

    static func += (lhs: inout UsageTokens, rhs: UsageTokens) { lhs = lhs + rhs }
}

/// What a model costs per million tokens of each kind, and what tokens come to at those rates.
struct UsageCost: Equatable, Sendable {
    var input = 0.0
    var output = 0.0
    var cacheRead = 0.0
    var cacheWrite = 0.0

    var total: Double { input + output + cacheRead + cacheWrite }

    static func + (lhs: UsageCost, rhs: UsageCost) -> UsageCost {
        UsageCost(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
                  cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite)
    }

    static func += (lhs: inout UsageCost, rhs: UsageCost) { lhs = lhs + rhs }

    /// The cost of `tokens` at `price` (cache rates fall back to the input rate), nil when the price is not usable.
    static func of(_ tokens: UsageTokens, at price: ModelPrice?) -> UsageCost? {
        guard let price, price.isUsable, let input = price.inputPerMillion, let output = price.outputPerMillion else { return nil }
        let read = price.cacheReadPerMillion ?? input
        let write = price.cacheWritePerMillion ?? input
        return UsageCost(input: Double(tokens.input) * input / 1_000_000,
                         output: Double(tokens.output) * output / 1_000_000,
                         cacheRead: Double(tokens.cacheRead) * read / 1_000_000,
                         cacheWrite: Double(tokens.cacheWrite) * write / 1_000_000)
    }

    /// What the cache saved: cached reads at the full input rate, minus what they cost.
    static func cacheSavings(_ tokens: UsageTokens, at price: ModelPrice?) -> Double {
        guard let price, price.isUsable, let input = price.inputPerMillion else { return 0 }
        let read = price.cacheReadPerMillion ?? input
        return max(0, Double(tokens.cacheRead) * (input - read) / 1_000_000)
    }
}

/// Public list prices (USD per million tokens) of the models agents run, for an API-equivalent estimate. Not your
/// subscription bill. They come from the model manifest (`pricing`), so a price changes between releases like a model
/// does. Matched on the model id's start, longest first; a price you set yourself (`PriceTable`) wins.
enum ModelRates {

    /// The prices of the model manifest in use (`ModelManifest.pricing`), longest prefix first. Set when a manifest is
    /// loaded or fetched, so a price can change between releases like a model can.
    static var manifestList: [(prefix: String, price: ModelPrice)] {
        get { manifestPrices.withLock { $0 } }
        set { manifestPrices.withLock { $0 = newValue } }
    }
    private static let manifestPrices = LockedValue<[(prefix: String, price: ModelPrice)]>([])

    /// Uses the prices of `manifest` from now on; one without prices keeps those of the manifest bundled with the app.
    static func use(_ manifest: ModelManifest?) {
        let prices = manifest?.pricing ?? ModelManifest.bundled()?.pricing ?? []
        manifestList = prices.map { ($0.prefix.lowercased(), $0.modelPrice) }.sorted { $0.prefix.count > $1.prefix.count }
    }

    /// The price for a model: yours first, then the model manifest's (`ModelManifest.pricing`). Ids are compared without a date
    /// suffix or a provider prefix (`anthropic.claude-…`, `claude-sonnet-4-5-20250929`).
    static func price(agent: String, model: String, custom: PriceTable = PriceTable(),
                      manifest: [(prefix: String, price: ModelPrice)]? = nil) -> ModelPrice? {
        if let own = custom.models[PriceTable.key(provider: agent, model: model)], own.isUsable { return own }
        let id = normalized(model)
        // A prefix ends where the id does or at a dash: `gpt-5` is not `gpt-5.2`, whose price may differ.
        func matches(_ prefix: String) -> Bool {
            guard id.hasPrefix(prefix) else { return false }
            let rest = id.dropFirst(prefix.count)
            return rest.isEmpty || rest.hasPrefix("-") || rest.hasPrefix("@") || rest.hasPrefix("[")
        }
        return (manifest ?? manifestList).first { matches($0.prefix) }?.price
    }

    static func normalized(_ model: String) -> String {
        var id = model.lowercased().trimmingCharacters(in: .whitespaces)
        for prefix in ["anthropic.", "openai/", "anthropic/", "google/", "models/"] where id.hasPrefix(prefix) {
            id = String(id.dropFirst(prefix.count))
        }
        return id
    }
}

/// The hours in which agents used tokens, per agent and model, for the last 90 days.
struct UsageLedger: Equatable, Sendable {
    struct Key: Hashable, Sendable {
        /// `AgentKind.rawValue`: claude, codex, gemini, antigravity.
        var agent: String
        var model: String
        /// Start of the hour.
        var hour: Date
    }

    static let keepDays = 90
    private(set) var buckets: [Key: UsageTokens] = [:]
    /// Replies (requests) per bucket.
    private(set) var replies: [Key: Int] = [:]
    /// When each agent's sessions last did something, to count the sessions of a window.
    private(set) var sessionEnds: [String: [Date]] = [:]

    /// A conversation, as the chat breakdown names it.
    struct Chat: Equatable, Sendable {
        /// `agent:session id` of the conversation's latest transcript.
        var id: String
        var agent: String
        /// The account (`AgentProfile.id`) it ran with.
        var profileID: String
        var title: String
        var project: String
    }

    /// A chat's tokens in one model and one five-minute slot: fine enough to tell what a limit window held.
    struct ChatKey: Hashable, Sendable {
        var chat: String
        var model: String
        var slot: Date
    }

    static let slotLength: TimeInterval = 300
    private(set) var chats: [String: Chat] = [:]
    private(set) var chatBuckets: [ChatKey: UsageTokens] = [:]

    var isEmpty: Bool { buckets.isEmpty }

    /// Attributes tokens to a chat; `add` counts the same tokens per agent and model.
    mutating func addChat(_ chat: Chat, model: String, date: Date, tokens: UsageTokens) {
        guard tokens.total > 0 else { return }
        let slot = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / Self.slotLength).rounded(.down) * Self.slotLength)
        chats[chat.id] = chat
        chatBuckets[ChatKey(chat: chat.id, model: model.isEmpty ? "unknown" : model, slot: slot), default: UsageTokens()] += tokens
    }

    mutating func add(agent: String, model: String, date: Date, tokens: UsageTokens, calendar: Calendar = .current) {
        guard tokens.total > 0 else { return }
        let hour = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        let key = Key(agent: agent, model: model.isEmpty ? "unknown" : model, hour: hour)
        buckets[key, default: UsageTokens()] += tokens
        replies[key, default: 0] += 1
    }

    mutating func addSession(agent: String, ended: Date) {
        sessionEnds[agent, default: []].append(ended)
    }
}

/// How far back the Usage page looks: the last 24 hours by hour, or 7, 30 or 90 days by day.
enum UsageWindow: String, CaseIterable, Identifiable, Sendable {
    case day, week, month, quarter

    var id: String { rawValue }
    var days: Int {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        }
    }
    var hourly: Bool { self == .day }

    /// The columns of its chart, oldest first: the last 24 hours, or the days ending today.
    func columns(now: Date, calendar: Calendar = .current) -> [Date] {
        if hourly {
            let current = calendar.dateInterval(of: .hour, for: now)?.start ?? now
            return (0..<24).reversed().compactMap { calendar.date(byAdding: .hour, value: -$0, to: current) }
        }
        let today = calendar.startOfDay(for: now)
        return (0..<days).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    func column(for hour: Date, calendar: Calendar = .current) -> Date {
        hourly ? hour : calendar.startOfDay(for: hour)
    }
}

/// Everything the Usage page shows for one window.
struct UsageInsights: Equatable, Sendable {
    struct AgentTotal: Equatable, Identifiable, Sendable {
        var agent: String
        var tokens = UsageTokens()
        var cost = 0.0
        var sessions = 0
        var tokenShare = 0.0
        var costShare = 0.0
        var id: String { agent }
    }

    struct ModelTotal: Equatable, Identifiable, Sendable {
        var agent: String
        var model: String
        var tokens = UsageTokens()
        /// Nil when the model has no known price.
        var cost: UsageCost?
        var replies = 0
        var cacheSavings = 0.0
        var tokenShare = 0.0
        var costShare = 0.0
        var id: String { agent + "|" + model }

        /// Cost per million processed tokens.
        var costPerMillion: Double? {
            guard let cost, tokens.total > 0 else { return nil }
            return cost.total / Double(tokens.total) * 1_000_000
        }
    }

    /// One chat's share of a window.
    struct ChatTotal: Equatable, Identifiable, Sendable {
        var chat: UsageLedger.Chat
        var tokens = UsageTokens()
        /// Nil when none of its models has a known price.
        var cost: UsageCost?
        /// The first and last moment it used tokens in the window.
        var first: Date
        var last: Date
        var tokenShare = 0.0
        var costShare = 0.0
        var id: String { chat.id }
    }

    /// One column of the chart for one agent.
    struct Point: Equatable, Identifiable, Sendable {
        var column: Date
        var agent: String
        var tokens: Int
        var cost: Double
        var id: String { "\(column.timeIntervalSince1970)|\(agent)" }
    }

    var window: UsageWindow
    var columns: [Date] = []
    var tokens = UsageTokens()
    var cost = UsageCost()
    var cacheSavings = 0.0
    /// Tokens of models without a price: left out of the cost.
    var unpricedTokens = 0
    var sessions = 0
    var agents: [AgentTotal] = []
    var models: [ModelTotal] = []
    /// The chats that used the most in the window, the costliest first.
    var chats: [ChatTotal] = []
    /// Per column and agent, zero-filled so every agent has a value in every column.
    var points: [Point] = []

    /// Share of tokens without a price, for the "estimate excludes …" note.
    var unpricedShare: Double { tokens.total > 0 ? Double(unpricedTokens) / Double(tokens.total) : 0 }

    /// Builds the window from the ledger. `sessions` are the sessions per agent that ended in the window; `agent` and
    /// `model` narrow everything to one agent or one model (the model sheet).
    static func make(_ ledger: UsageLedger, window: UsageWindow, now: Date = Date(), calendar: Calendar = .current,
                     prices: PriceTable = PriceTable(), sessions: [String: Int] = [:],
                     agent onlyAgent: String? = nil, model onlyModel: String? = nil) -> UsageInsights {
        var insights = UsageInsights(window: window)
        insights.columns = window.columns(now: now, calendar: calendar)
        guard let first = insights.columns.first else { return insights }
        let end = now

        var agents: [String: AgentTotal] = [:]
        var models: [String: ModelTotal] = [:]
        var series: [String: [Date: (tokens: Int, cost: Double)]] = [:]

        for (key, tokens) in ledger.buckets where key.hour >= first && key.hour <= end {
            if let onlyAgent, key.agent != onlyAgent { continue }
            if let onlyModel, key.model != onlyModel { continue }
            let price = ModelRates.price(agent: key.agent, model: key.model, custom: prices)
            let cost = UsageCost.of(tokens, at: price)

            insights.tokens += tokens
            if let cost { insights.cost += cost } else { insights.unpricedTokens += tokens.total }
            let savings = UsageCost.cacheSavings(tokens, at: price)
            insights.cacheSavings += savings

            var agentTotal = agents[key.agent] ?? AgentTotal(agent: key.agent)
            agentTotal.tokens += tokens
            agentTotal.cost += cost?.total ?? 0
            agents[key.agent] = agentTotal

            let modelKey = key.agent + "|" + key.model
            var model = models[modelKey] ?? ModelTotal(agent: key.agent, model: key.model)
            model.tokens += tokens
            model.replies += ledger.replies[key] ?? 0
            model.cacheSavings += savings
            if let cost { model.cost = (model.cost ?? UsageCost()) + cost }
            models[modelKey] = model

            let column = window.column(for: key.hour, calendar: calendar)
            var cell = series[key.agent, default: [:]][column] ?? (0, 0)
            cell.tokens += tokens.total
            cell.cost += cost?.total ?? 0
            series[key.agent, default: [:]][column] = cell
        }

        let totalTokens = Double(insights.tokens.total)
        let totalCost = insights.cost.total
        // Sessions as given, else the ones the ledger saw end in the window.
        var counts = sessions
        if counts.isEmpty {
            for (agent, ends) in ledger.sessionEnds {
                let count = ends.filter { $0 >= first && $0 <= end }.count
                if count > 0 { counts[agent] = count }
            }
        }
        for (agent, count) in counts where onlyModel == nil && (onlyAgent == nil || onlyAgent == agent) {
            agents[agent, default: AgentTotal(agent: agent)].sessions = count
            insights.sessions += count
        }
        insights.agents = agents.values.map { total in
            var total = total
            total.tokenShare = totalTokens > 0 ? Double(total.tokens.total) / totalTokens : 0
            total.costShare = totalCost > 0 ? total.cost / totalCost : 0
            return total
        }
        .filter { $0.tokens.total > 0 || $0.sessions > 0 }
        .sorted { $0.tokens.total != $1.tokens.total ? $0.tokens.total > $1.tokens.total : $0.agent < $1.agent }

        insights.models = models.values.map { model in
            var model = model
            model.tokenShare = totalTokens > 0 ? Double(model.tokens.total) / totalTokens : 0
            model.costShare = totalCost > 0 ? (model.cost?.total ?? 0) / totalCost : 0
            return model
        }
        .sorted { lhs, rhs in
            let l = lhs.cost?.total ?? -1, r = rhs.cost?.total ?? -1
            if l != r { return l > r }
            return lhs.tokens.total != rhs.tokens.total ? lhs.tokens.total > rhs.tokens.total : lhs.id < rhs.id
        }

        insights.chats = UsageChats.totals(ledger, from: first, to: end, prices: prices, agent: onlyAgent, model: onlyModel)

        let order = insights.agents.map(\.agent)
        insights.points = insights.columns.flatMap { column in
            order.map { agent in
                let cell = series[agent]?[column]
                return Point(column: column, agent: agent, tokens: cell?.tokens ?? 0, cost: cell?.cost ?? 0)
            }
        }
        return insights
    }
}

/// Which chats used the tokens: of a window of the Usage page, or of one account's limit window.
enum UsageChats {
    /// The chats with tokens in `from...to`, the costliest first (unpriced ones by tokens after them). `profile`, `agent`
    /// and `model` narrow it down.
    static func totals(_ ledger: UsageLedger, from: Date, to: Date, prices: PriceTable = PriceTable(), profile: String? = nil,
                       agent onlyAgent: String? = nil, model onlyModel: String? = nil) -> [UsageInsights.ChatTotal] {
        var found: [(key: UsageLedger.ChatKey, tokens: UsageTokens)] = []
        for (key, tokens) in ledger.chatBuckets where key.slot >= from.addingTimeInterval(-UsageLedger.slotLength) && key.slot <= to {
            if let onlyModel, key.model != onlyModel { continue }
            guard let chat = ledger.chats[key.chat] else { continue }
            if let onlyAgent, chat.agent != onlyAgent { continue }
            if let profile, chat.profileID != profile { continue }
            found.append((key, tokens))
        }
        return totals(ledger, buckets: found, prices: prices)
    }

    static func totals(_ ledger: UsageLedger, buckets: [(key: UsageLedger.ChatKey, tokens: UsageTokens)],
                       prices: PriceTable) -> [UsageInsights.ChatTotal] {
        var rates: [String: ModelPrice?] = [:]
        var byChat: [String: UsageInsights.ChatTotal] = [:]
        for (key, tokens) in buckets {
            guard let chat = ledger.chats[key.chat] else { continue }
            let rateKey = chat.agent + "|" + key.model
            if rates[rateKey] == nil { rates[rateKey] = .some(ModelRates.price(agent: chat.agent, model: key.model, custom: prices)) }
            let cost = UsageCost.of(tokens, at: rates[rateKey] ?? nil)
            var total = byChat[chat.id] ?? UsageInsights.ChatTotal(chat: chat, first: key.slot, last: key.slot)
            total.tokens += tokens
            if let cost { total.cost = (total.cost ?? UsageCost()) + cost }
            total.first = min(total.first, key.slot)
            total.last = max(total.last, key.slot)
            byChat[chat.id] = total
        }
        let tokenSum = Double(byChat.values.map(\.tokens.total).reduce(0, +))
        let costSum = byChat.values.map { $0.cost?.total ?? 0 }.reduce(0, +)
        return byChat.values.map { total in
            var total = total
            total.tokenShare = tokenSum > 0 ? Double(total.tokens.total) / tokenSum : 0
            total.costShare = costSum > 0 ? (total.cost?.total ?? 0) / costSum : 0
            return total
        }
        .sorted { lhs, rhs in
            let l = lhs.cost?.total ?? -1, r = rhs.cost?.total ?? -1
            if l != r { return l > r }
            return lhs.tokens.total != rhs.tokens.total ? lhs.tokens.total > rhs.tokens.total : lhs.id < rhs.id
        }
    }
}

/// An account's usage in one limit window (the 5-hour session window), with the chats that filled it.
struct UsageBlock: Equatable, Identifiable, Sendable {
    var profileID: String
    var start: Date
    var end: Date
    /// The window has not run out yet.
    var active: Bool
    /// `start` is the window's own start as the agent reports it, not guessed from the first tokens.
    var reported: Bool
    var tokens = UsageTokens()
    var cost = 0.0
    var chats: [UsageInsights.ChatTotal] = []
    var id: String { profileID + "|" + String(start.timeIntervalSince1970) }
}

enum UsageBlocks {
    /// The windows of one account in the last `days`, newest first. A window starts with the first tokens after the
    /// previous one ran out and lasts `duration`. `anchor` is the start of the window the agent reports right now: tokens
    /// from before it belong to earlier windows, and it starts one even when it still holds no tokens.
    static func make(_ ledger: UsageLedger, profile: String, duration: TimeInterval, anchor: Date? = nil, now: Date = Date(),
                     days: Int = 3, prices: PriceTable = PriceTable()) -> [UsageBlock] {
        guard duration > 0 else { return [] }
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        var slots: [(key: UsageLedger.ChatKey, tokens: UsageTokens)] = []
        // From one window earlier, so a window that began before `since` still starts where it did.
        for (key, tokens) in ledger.chatBuckets where key.slot >= since.addingTimeInterval(-duration) && key.slot <= now {
            guard ledger.chats[key.chat]?.profileID == profile else { continue }
            slots.append((key, tokens))
        }
        slots.sort { $0.key.slot < $1.key.slot }

        typealias Slot = (key: UsageLedger.ChatKey, tokens: UsageTokens)
        var groups: [(start: Date, reported: Bool, slots: [Slot])] = []
        for slot in slots {
            let at = slot.key.slot
            let crossesAnchor = anchor.map { (groups.last?.start ?? $0) < $0 && at >= $0 } ?? false
            if let last = groups.last, at < last.start.addingTimeInterval(duration), !crossesAnchor {
                groups[groups.count - 1].slots.append(slot)
            } else if let anchor, at >= anchor, at < anchor.addingTimeInterval(duration) {
                groups.append((anchor, true, [slot]))
            } else {
                groups.append((at, false, [slot]))
            }
        }
        if let anchor, anchor <= now, now < anchor.addingTimeInterval(duration), !groups.contains(where: { $0.start == anchor }) {
            groups.append((anchor, true, []))
        }

        return groups.filter { $0.start.addingTimeInterval(duration) > since }.reversed().map { group in
            let chats = UsageChats.totals(ledger, buckets: group.slots, prices: prices)
            return UsageBlock(profileID: profile, start: group.start, end: group.start.addingTimeInterval(duration),
                              active: now < group.start.addingTimeInterval(duration), reported: group.reported,
                              tokens: chats.reduce(UsageTokens()) { $0 + $1.tokens },
                              cost: chats.reduce(0) { $0 + ($1.cost?.total ?? 0) }, chats: chats)
        }
    }
}

/// How the Usage page writes its numbers.
enum UsageFormat {
    /// "845", "12.4K", "3.2M", "1.1B".
    static func tokens(_ count: Int) -> String {
        let value = Double(count)
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return trimmed(value / 1_000) + "K"
        case ..<1_000_000_000: return trimmed(value / 1_000_000) + "M"
        default: return trimmed(value / 1_000_000_000) + "B"
        }
    }

    /// "$0.00", "$4.20", "$1,234.56", "$12.3K" above ten thousand.
    static func usd(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "$0.00" }
        if value >= 10_000 { return "$" + trimmed(value / 1_000) + "K" }
        return CostFormat.usd(value)
    }

    /// "42%", "0.4%", "<0.1%".
    static func percent(_ share: Double) -> String {
        guard share > 0 else { return "0%" }
        if share < 0.001 { return "<0.1%" }
        if share < 0.1 { return String(format: "%.1f%%", share * 100) }
        return "\(Int((share * 100).rounded()))%"
    }

    private static func trimmed(_ value: Double) -> String {
        let text = value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}

/// Custom prices you set on the Usage page, kept on this Mac.
enum UsagePrices {
    static let defaultsKey = "usage.prices"

    static func load(defaults: UserDefaults = .standard) -> PriceTable {
        guard let data = defaults.data(forKey: defaultsKey) else { return PriceTable() }
        return (try? JSONDecoder().decode(PriceTable.self, from: data)) ?? PriceTable()
    }

    static func save(_ table: PriceTable, defaults: UserDefaults = .standard) {
        defaults.setEncoded(table, forKey: defaultsKey)
    }
}

/// A value several threads read and write, behind a lock.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
