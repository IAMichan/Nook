import XCTest

final class PriceTableTests: XCTestCase {
    private func usage(_ i: Int? = nil, _ o: Int? = nil, read: Int? = nil, write: Int? = nil, cost: Double? = nil) -> RunUsage {
        RunUsage(inputTokens: i, outputTokens: o, cacheReadTokens: read, cacheWriteTokens: write, reportedCostUSD: cost)
    }

    func testReportedCostIsUsedWithoutCustomPrice() {
        let table = PriceTable()
        XCTAssertEqual(table.cost(for: usage(1000, 1000, cost: 0.42), provider: "claude", model: "opus"), .priced(0.42, source: .reported))
    }

    func testCustomPriceBeatsReportedCost() {
        var table = PriceTable()
        table.setPrice(ModelPrice(input: 3, output: 15), provider: "claude", model: "opus")
        let result = table.cost(for: usage(1_000_000, 2_000_000, cost: 99), provider: "claude", model: "opus")
        XCTAssertEqual(result, .priced(33, source: .custom))
    }

    func testResetGoesBackToReported() {
        var table = PriceTable()
        table.setPrice(ModelPrice(input: 1, output: 1), provider: "claude", model: "m")
        table.resetPrice(provider: "claude", model: "m")
        XCTAssertEqual(table.cost(for: usage(10, 10, cost: 1), provider: "claude", model: "m"), .priced(1, source: .reported))
    }

    func testUnpricedWithoutAnything() {
        XCTAssertEqual(PriceTable().cost(for: usage(100, 100), provider: "codex", model: "x"), .unpriced)
        XCTAssertNil(CostFormat.usd(.unpriced))
    }

    func testCacheRatesFallBackToInputRate() {
        var table = PriceTable()
        table.setPrice(ModelPrice(input: 2, output: 10), provider: "p", model: "m")
        XCTAssertEqual(table.cost(for: usage(0, 0, read: 1_000_000, write: 1_000_000), provider: "p", model: "m"), .priced(4, source: .custom))
        table.setPrice(ModelPrice(input: 2, output: 10, cacheRead: 0, cacheWrite: 5), provider: "p", model: "m")
        XCTAssertEqual(table.cost(for: usage(0, 0, read: 1_000_000, write: 1_000_000), provider: "p", model: "m"), .priced(5, source: .custom))
    }

    func testNilTokenFieldsAreNotGuessed() {
        var table = PriceTable()
        table.setPrice(ModelPrice(input: 1, output: 1), provider: "p", model: "m")
        // Only output reported: input counts as nothing, not as an estimate.
        XCTAssertEqual(table.cost(for: usage(nil, 1_000_000), provider: "p", model: "m"), .priced(1, source: .custom))
        // Nothing reported at all: no price from a custom rate; falls to unpriced.
        XCTAssertEqual(table.cost(for: usage(), provider: "p", model: "m"), .unpriced)
    }

    func testFreeModelWithZeroRates() {
        var table = PriceTable()
        table.setPrice(ModelPrice(input: 0, output: 0), provider: "p", model: "local")
        XCTAssertEqual(table.cost(for: usage(5000, 5000, cost: 3), provider: "p", model: "local"), .priced(0, source: .custom))
    }

    func testIncompleteCustomPriceFallsBackToReported() {
        var table = PriceTable()
        table.setPrice(ModelPrice(input: 1, output: nil), provider: "p", model: "m")
        XCTAssertEqual(table.cost(for: usage(10, 10, cost: 7), provider: "p", model: "m"), .priced(7, source: .reported))
    }

    func testProviderDefaultAndModelPrecedence() {
        var table = PriceTable()
        table.providerDefaults["codex"] = ModelPrice(input: 1, output: 1)
        table.setPrice(ModelPrice(input: 10, output: 10), provider: "codex", model: "big")
        XCTAssertEqual(table.price(provider: "codex", model: "big")?.inputPerMillion, 10)
        XCTAssertEqual(table.price(provider: "codex", model: "other")?.inputPerMillion, 1)
        XCTAssertEqual(table.price(provider: "codex", model: "")?.inputPerMillion, 1)
        XCTAssertNil(table.price(provider: "claude", model: "big"))
        XCTAssertEqual(table.price(provider: "Codex", model: "BIG")?.inputPerMillion, 10, "case-insensitive fallback")
    }

    func testMixedAcrossEnvironments() {
        let a = ModelPrice(input: 1, output: 2)
        let b = ModelPrice(input: 1, output: 3)
        let cmp = PriceTable.compare([a, b])
        XCTAssertEqual(cmp.input, .value(1))
        XCTAssertEqual(cmp.output, .mixed)
        XCTAssertTrue(cmp.hasMixed)
        XCTAssertFalse(PriceTable.compare([a, a]).hasMixed)
        XCTAssertTrue(PriceTable.compare([a, nil]).hasMixed, "priced in one environment, not in the other")
        var t1 = PriceTable(), t2 = PriceTable()
        t1.setPrice(a, provider: "p", model: "m"); t2.setPrice(b, provider: "p", model: "m")
        XCTAssertTrue(PriceTable.compare(tables: [t1, t2], provider: "p", model: "m").hasMixed)
    }

    func testSummaryFlagsPartialAndMixedSources() {
        let s = CostSummary.combine([.priced(1, source: .reported), .priced(2, source: .custom), .unpriced])
        XCTAssertEqual(s.total, 3)
        XCTAssertEqual(s.priced, 2)
        XCTAssertTrue(s.isPartial)
        XCTAssertTrue(s.mixedSources)
        XCTAssertFalse(CostSummary.combine([.priced(1, source: .custom)]).isPartial)
    }

    func testCodableToleratesMissingAndUnknownFields() throws {
        let json = #"{"models":{"p|m":{"inputPerMillion":1,"outputPerMillion":2,"extra":true}},"future":1}"#
        let table = try JSONDecoder().decode(PriceTable.self, from: Data(json.utf8))
        XCTAssertEqual(table.models["p|m"], ModelPrice(input: 1, output: 2))
        XCTAssertEqual(try JSONDecoder().decode(PriceTable.self, from: Data("{}".utf8)), PriceTable())
        let back = try JSONDecoder().decode(PriceTable.self, from: JSONEncoder().encode(table))
        XCTAssertEqual(back, table)
    }

    func testUSDFormat() {
        XCTAssertEqual(CostFormat.usd(0), "$0.00")
        XCTAssertEqual(CostFormat.usd(0.0012), "$0.0012")
        XCTAssertEqual(CostFormat.usd(1.5), "$1.50")
        XCTAssertEqual(CostFormat.usd(1234567.891), "$1,234,567.89")
        XCTAssertEqual(CostFormat.usd(999.999), "$1,000.00")
        XCTAssertEqual(CostFormat.usd(-3), "$0.00")
        XCTAssertEqual(CostFormat.usd(.nan), "$0.00")
        XCTAssertEqual(CostFormat.usd(.priced(2, source: .custom)), "$2.00")
    }

    // MARK: One cost for every agent

    private let list: [(prefix: String, price: ModelPrice)] = [("gpt-5", ModelPrice(input: 1, output: 10, cacheRead: 0.1))]

    func testTokensWithoutAReportedCostAreEstimated() {
        // Codex and Gemini CLI report tokens but no cost: the model's list price, marked as an estimate.
        let result = PriceTable().cost(for: usage(1_000_000, 100_000, read: 2_000_000), provider: "codex", model: "gpt-5",
                                       manifest: list)
        XCTAssertEqual(result, .priced(1 + 1 + 0.2, source: .estimated))
        XCTAssertTrue(result.isEstimate)
        XCTAssertEqual(CostFormat.label(result), tr("ws.cost.estimated", "$2.20"))
    }

    func testReportedCostWinsOverTheEstimate() {
        let result = PriceTable().cost(for: usage(1_000_000, 0, cost: 0.5), provider: "codex", model: "gpt-5", manifest: list)
        XCTAssertEqual(result, .priced(0.5, source: .reported))
        XCTAssertEqual(CostFormat.label(result), "$0.50")
    }

    func testYourPriceWinsOverBoth() {
        var table = PriceTable()
        table.setPrice(ModelPrice(input: 2, output: 2), provider: "codex", model: "gpt-5")
        XCTAssertEqual(table.cost(for: usage(1_000_000, 0, cost: 9), provider: "codex", model: "gpt-5", manifest: list),
                       .priced(2, source: .custom))
    }

    func testAModelWithoutAPriceStaysUnpriced() {
        XCTAssertEqual(PriceTable().cost(for: usage(10, 10), provider: "gemini", model: "unknown", manifest: list), .unpriced)
        XCTAssertNil(CostFormat.label(.unpriced))
    }

    func testATurnIsPricedTheSameWay() {
        let turn = TurnUsage(inputTokens: 1_000_000, outputTokens: 0)
        XCTAssertEqual(PriceTable().cost(for: turn, provider: "gemini", model: "gpt-5-mini", manifest: list),
                       .priced(1, source: .estimated))
    }
}
