import Foundation

// Custom model prices. The agent's own reported cost is
// used unless the user set a price for the model.

struct ModelPrice: Codable, Equatable, Sendable {
    var inputPerMillion: Double?
    var outputPerMillion: Double?
    /// Blank = use the input rate.
    var cacheReadPerMillion: Double?
    var cacheWritePerMillion: Double?

    init(input: Double? = nil, output: Double? = nil, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
        inputPerMillion = input; outputPerMillion = output; cacheReadPerMillion = cacheRead; cacheWritePerMillion = cacheWrite
    }

    private enum CodingKeys: String, CodingKey { case inputPerMillion, outputPerMillion, cacheReadPerMillion, cacheWritePerMillion }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputPerMillion = try? c.decode(Double.self, forKey: .inputPerMillion)
        outputPerMillion = try? c.decode(Double.self, forKey: .outputPerMillion)
        cacheReadPerMillion = try? c.decode(Double.self, forKey: .cacheReadPerMillion)
        cacheWritePerMillion = try? c.decode(Double.self, forKey: .cacheWritePerMillion)
    }

    /// A price needs both main rates; `0` is a valid rate (free), nil is not.
    var isUsable: Bool {
        guard let i = inputPerMillion, let o = outputPerMillion else { return false }
        return i >= 0 && o >= 0 && i.isFinite && o.isFinite
    }
}

/// Where a cost came from: a price you set, the agent's own report, or Nook's estimate from its tokens at the model's
/// list price (`ModelRates`) for an agent that reports tokens but no cost.
enum CostSource: String, Equatable, Sendable { case reported, custom, estimated }

enum CostResult: Equatable, Sendable {
    case priced(Double, source: CostSource)
    case unpriced

    var amount: Double? { if case .priced(let v, _) = self { return v }; return nil }

    /// Nook worked it out from the tokens: the view says "estimated".
    var isEstimate: Bool { if case .priced(_, .estimated) = self { return true }; return false }
}

/// A cell of the price editor across several environments.
enum PriceCell: Equatable, Sendable {
    case value(Double?)
    case mixed
}

struct PriceComparison: Equatable, Sendable {
    var input: PriceCell, output: PriceCell, cacheRead: PriceCell, cacheWrite: PriceCell
    var hasMixed: Bool { [input, output, cacheRead, cacheWrite].contains(.mixed) }
}

struct PriceTable: Codable, Equatable, Sendable {
    /// Keyed "provider|model".
    var models: [String: ModelPrice] = [:]
    /// Keyed by provider; used for models without their own entry.
    var providerDefaults: [String: ModelPrice] = [:]

    init(models: [String: ModelPrice] = [:], providerDefaults: [String: ModelPrice] = [:]) {
        self.models = models; self.providerDefaults = providerDefaults
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        models = (try? c.decode([String: ModelPrice].self, forKey: .models)) ?? [:]
        providerDefaults = (try? c.decode([String: ModelPrice].self, forKey: .providerDefaults)) ?? [:]
    }

    private enum CodingKeys: String, CodingKey { case models, providerDefaults }

    static func key(provider: String, model: String) -> String { "\(provider.lowercased())|\(model)" }

    mutating func setPrice(_ price: ModelPrice, provider: String, model: String) { models[Self.key(provider: provider, model: model)] = price }

    /// "Reset to automatic".
    mutating func resetPrice(provider: String, model: String) { models[Self.key(provider: provider, model: model)] = nil }

    func price(provider: String, model: String) -> ModelPrice? {
        let exact = Self.key(provider: provider, model: model)
        if !model.isEmpty {
            if let p = models[exact] { return p }
            if let p = models.first(where: { $0.key.lowercased() == exact.lowercased() })?.value { return p }
        }
        return providerDefaults[provider.lowercased()]
    }

    /// The one cost of a turn or a session, for every agent: a price you set for the model, else the cost the agent
    /// reported (Claude Code, OpenCode, Pi, ACP agents that send it), else an estimate from its tokens at the model's
    /// list price (`ModelRates`, marked `.estimated`) for agents that report tokens but no cost (Codex, Gemini CLI,
    /// ACP agents that send none). Token counts that are nil were not reported and count as nothing; no tokens at all
    /// and no reported cost is "unpriced", not zero.
    func cost(tokens: UsageTokens?, reported: Double?, provider: String, model: String,
              manifest: [(prefix: String, price: ModelPrice)]? = nil) -> CostResult {
        if let tokens, let price = price(provider: provider, model: model), let custom = UsageCost.of(tokens, at: price) {
            return .priced(custom.total, source: .custom)
        }
        // An unusable custom price falls through to what the agent reported.
        if let reported, reported.isFinite { return .priced(reported, source: .reported) }
        guard let tokens, tokens.total > 0,
              let list = ModelRates.price(agent: provider, model: model, custom: PriceTable(), manifest: manifest),
              let estimate = UsageCost.of(tokens, at: list) else { return .unpriced }
        return .priced(estimate.total, source: .estimated)
    }

    func cost(for usage: RunUsage, provider: String, model: String,
              manifest: [(prefix: String, price: ModelPrice)]? = nil) -> CostResult {
        cost(tokens: Self.tokens(usage.inputTokens, usage.outputTokens, usage.cacheReadTokens, usage.cacheWriteTokens),
             reported: usage.reportedCostUSD, provider: provider, model: model, manifest: manifest)
    }

    func cost(for turn: TurnUsage, provider: String, model: String,
              manifest: [(prefix: String, price: ModelPrice)]? = nil) -> CostResult {
        cost(tokens: Self.tokens(turn.inputTokens, turn.outputTokens, turn.cacheReadTokens, turn.cacheWriteTokens),
             reported: turn.reportedCostUSD, provider: provider, model: model, manifest: manifest)
    }

    /// The counts a usage reported; nil when it reported none.
    private static func tokens(_ input: Int?, _ output: Int?, _ read: Int?, _ write: Int?) -> UsageTokens? {
        guard input != nil || output != nil || read != nil || write != nil else { return nil }
        return UsageTokens(input: input ?? 0, output: output ?? 0, cacheRead: read ?? 0, cacheWrite: write ?? 0)
    }

    /// Same model in several environments: cells where they disagree are "Mixed".
    static func compare(_ prices: [ModelPrice?]) -> PriceComparison {
        func cell(_ get: (ModelPrice) -> Double?) -> PriceCell {
            let values = prices.map { $0.flatMap(get) }
            return values.dropFirst().allSatisfy { $0 == values[0] } ? .value(values.first ?? nil) : .mixed
        }
        return PriceComparison(input: cell { $0.inputPerMillion }, output: cell { $0.outputPerMillion },
                               cacheRead: cell { $0.cacheReadPerMillion }, cacheWrite: cell { $0.cacheWritePerMillion })
    }

    static func compare(tables: [PriceTable], provider: String, model: String) -> PriceComparison {
        compare(tables.map { $0.price(provider: provider, model: model) })
    }
}

/// Costs of several sessions added up.
struct CostSummary: Equatable, Sendable {
    var total: Double
    var priced: Int
    var unpriced: Int
    /// Reported and custom costs both contributed.
    var mixedSources: Bool
    /// Some sessions have no price: the total is a lower bound.
    var isPartial: Bool { unpriced > 0 }

    static func combine(_ results: [CostResult]) -> CostSummary {
        var total = 0.0, priced = 0, unpriced = 0
        var sources: Set<CostSource> = []
        for r in results {
            switch r {
            case .priced(let v, let s): total += v; priced += 1; sources.insert(s)
            case .unpriced: unpriced += 1
            }
        }
        return CostSummary(total: total, priced: priced, unpriced: unpriced, mixedSources: sources.count > 1)
    }
}

enum CostFormat {
    /// Locale-independent: cents above a cent, four decimals below, thousands grouped.
    static func usd(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "$0.00" }
        if value < 0.01 { return String(format: "$%.4f", value) }
        let fixed = String(format: "%.2f", value)
        let parts = fixed.split(separator: ".")
        var whole = String(parts[0]), grouped = ""
        while whole.count > 3 { grouped = "," + whole.suffix(3) + grouped; whole = String(whole.dropLast(3)) }
        return "$" + whole + grouped + "." + parts[1]
    }

    /// Nil for unpriced: the view shows its own "Unpriced" label.
    static func usd(_ result: CostResult) -> String? { result.amount.map { usd($0) } }

    /// A cost on a line of its own: cents, or "< $0.01" for less (`AgentPathFormat.cost`).
    static func short(_ usd: Double) -> String {
        usd < 0.01 && usd > 0 ? "< $0.01" : String(format: "$%.2f", usd)
    }

    /// A turn's or session's cost as the timeline and the inspector show it ("$0.42", "$0.42 (estimated)"); nil when
    /// unpriced.
    static func label(_ result: CostResult) -> String? {
        guard let amount = result.amount else { return nil }
        let text = short(amount)
        return result.isEstimate ? tr("ws.cost.estimated", text) : text
    }
}

extension WorkspaceRun {
    /// The model a session's tokens are priced at: the one the agent said it ran, else the one you chose.
    var pricedModel: String { resolvedModel.flatMap { $0.isEmpty ? nil : $0 } ?? model }

    /// The session's cost so far, for every agent (`PriceTable.cost`).
    func cost(of usage: RunUsage, prices: PriceTable) -> CostResult {
        prices.cost(for: usage, provider: provider.rawValue, model: pricedModel)
    }

    /// One turn's cost, for every agent (`PriceTable.cost`).
    func cost(of turn: TurnUsage, prices: PriceTable) -> CostResult {
        prices.cost(for: turn, provider: provider.rawValue, model: pricedModel)
    }
}
