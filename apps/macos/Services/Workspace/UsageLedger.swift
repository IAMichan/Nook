import Foundation

// Usage of every agent on this Mac, read from the agents' own transcripts (Claude Code, Codex, Gemini CLI, Antigravity),
// and what it would cost at API prices, as Settings › Usage shows it: per hour or day, per agent and per
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
/// subscription bill. Matched on the model id's start, longest first; a price you set yourself (`PriceTable`) wins.
enum ModelRates {
    private static func rate(_ input: Double, _ output: Double, read: Double? = nil, write: Double? = nil) -> ModelPrice {
        ModelPrice(input: input, output: output, cacheRead: read ?? input * 0.1, cacheWrite: write ?? input * 1.25)
    }

    /// Model id prefix → price. Anthropic's rates as published for its first-party API; OpenAI's and Google's list rates.
    static let list: [(prefix: String, price: ModelPrice)] = [
        ("claude-fable-5-1", rate(10, 50, read: 0.25)),
        ("claude-mythos-5-1", rate(10, 50, read: 0.25)),
        ("claude-fable-5", rate(10, 50)),
        ("claude-opus-5-5", rate(4, 20, read: 0.20)),
        ("claude-opus-5", rate(5, 25)),
        ("claude-opus-4-8", rate(5, 25)),
        ("claude-opus-4-7", rate(5, 25)),
        ("claude-opus-4-6", rate(5, 25)),
        ("claude-opus-4-5", rate(5, 25)),
        ("claude-opus-4-1", rate(15, 75)),
        ("claude-opus-4", rate(15, 75)),
        ("claude-sonnet-5-5", rate(2, 10, read: 0.20)),
        ("claude-sonnet-5", rate(2, 10)),
        ("claude-sonnet-4", rate(3, 15)),
        ("claude-3-7-sonnet", rate(3, 15)),
        ("claude-haiku-5-5", rate(0.10, 0.50)),
        ("claude-haiku-4-5", rate(1, 5)),
        ("claude-3-5-haiku", rate(0.80, 4)),
        ("gpt-5-mini", rate(0.25, 2, read: 0.025, write: 0.25)),
        ("gpt-5-nano", rate(0.05, 0.40, read: 0.005, write: 0.05)),
        ("gpt-5", rate(1.25, 10, read: 0.125, write: 1.25)),
        ("gpt-5.1", rate(1.25, 10, read: 0.125, write: 1.25)),
        ("gemini-2.5-pro", rate(1.25, 10, read: 0.31, write: 1.25)),
        ("gemini-2.5-flash", rate(0.30, 2.50, read: 0.075, write: 0.30)),
    ].sorted { $0.prefix.count > $1.prefix.count }

    /// The price for a model: yours first, then the list. Ids are compared without a date suffix or a provider prefix
    /// (`anthropic.claude-…`, `claude-sonnet-4-5-20250929`).
    static func price(agent: String, model: String, custom: PriceTable = PriceTable()) -> ModelPrice? {
        if let own = custom.models[PriceTable.key(provider: agent, model: model)], own.isUsable { return own }
        let id = normalized(model)
        // A prefix ends where the id does or at a dash: `gpt-5` is not `gpt-5.2`, whose price may differ.
        return list.first { entry in
            guard id.hasPrefix(entry.prefix) else { return false }
            let rest = id.dropFirst(entry.prefix.count)
            return rest.isEmpty || rest.hasPrefix("-") || rest.hasPrefix("@") || rest.hasPrefix("[")
        }?.price
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

    var isEmpty: Bool { buckets.isEmpty }

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
        defaults.set(try? JSONEncoder().encode(table), forKey: defaultsKey)
    }
}
