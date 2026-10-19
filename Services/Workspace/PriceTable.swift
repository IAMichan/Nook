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

enum CostSource: String, Equatable, Sendable { case reported, custom }

enum CostResult: Equatable, Sendable {
    case priced(Double, source: CostSource)
    case unpriced

    var amount: Double? { if case .priced(let v, _) = self { return v }; return nil }
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

    /// Token counts that are nil were not reported and count as nothing; they are never estimated. No tokens at all and
    /// no reported cost is "unpriced", not zero.
    func cost(for usage: RunUsage, provider: String, model: String) -> CostResult {
        if let price = price(provider: provider, model: model) {
            if let custom = Self.compute(price, usage) { return .priced(custom, source: .custom) }
            // An unusable custom price falls through to what the agent reported.
        }
        if let reported = usage.reportedCostUSD, reported.isFinite { return .priced(reported, source: .reported) }
        return .unpriced
    }

    private static func compute(_ price: ModelPrice, _ usage: RunUsage) -> Double? {
        guard price.isUsable, usage.totalTokens != nil, let input = price.inputPerMillion, let output = price.outputPerMillion else { return nil }
        let read = price.cacheReadPerMillion ?? input
        let write = price.cacheWritePerMillion ?? input
        let sum = Double(usage.inputTokens ?? 0) * input + Double(usage.outputTokens ?? 0) * output
            + Double(usage.cacheReadTokens ?? 0) * read + Double(usage.cacheWriteTokens ?? 0) * write
        return sum / 1_000_000
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
}
