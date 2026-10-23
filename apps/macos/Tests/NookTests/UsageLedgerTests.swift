import XCTest

final class UsageLedgerTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let now = Date(timeIntervalSince1970: 1_800_000_000) // a fixed moment

    private func tokens(_ input: Int, _ output: Int, read: Int = 0, write: Int = 0) -> UsageTokens {
        UsageTokens(input: input, output: output, cacheRead: read, cacheWrite: write)
    }

    func testListPricesMatchOnTheIdsStart() {
        XCTAssertEqual(ModelRates.price(agent: "claude", model: "claude-sonnet-4-5-20250929")?.inputPerMillion, 3)
        XCTAssertEqual(ModelRates.price(agent: "claude", model: "claude-opus-4-5-20251101")?.inputPerMillion, 5)
        XCTAssertEqual(ModelRates.price(agent: "claude", model: "claude-opus-4-1-20250805")?.inputPerMillion, 15)
        XCTAssertEqual(ModelRates.price(agent: "claude", model: "claude-opus-5-5")?.cacheReadPerMillion, 0.20)
        XCTAssertEqual(ModelRates.price(agent: "claude", model: "claude-sonnet-5-5")?.outputPerMillion, 10)
        XCTAssertEqual(ModelRates.price(agent: "claude", model: "anthropic.claude-haiku-4-5")?.inputPerMillion, 1)
        XCTAssertEqual(ModelRates.price(agent: "codex", model: "gpt-5-codex")?.inputPerMillion, 1.25)
        XCTAssertEqual(ModelRates.price(agent: "codex", model: "gpt-5-mini")?.inputPerMillion, 0.25)
        XCTAssertNil(ModelRates.price(agent: "codex", model: "gpt-5.2"))
        XCTAssertNil(ModelRates.price(agent: "claude", model: "unknown"))
        // Cache rates default to a tenth of input for reads and a quarter more for writes.
        XCTAssertEqual(ModelRates.price(agent: "claude", model: "claude-sonnet-4-6")?.cacheReadPerMillion ?? 0, 0.3, accuracy: 1e-9)
        XCTAssertEqual(ModelRates.price(agent: "claude", model: "claude-sonnet-4-6")?.cacheWritePerMillion ?? 0, 3.75, accuracy: 1e-9)
    }

    func testYourOwnPriceWins() {
        var table = PriceTable()
        table.setPrice(ModelPrice(input: 1, output: 2), provider: "codex", model: "gpt-5.2")
        XCTAssertEqual(ModelRates.price(agent: "codex", model: "gpt-5.2", custom: table)?.outputPerMillion, 2)
    }

    func testCostAndCacheSavings() {
        let price = ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)
        let cost = UsageCost.of(tokens(1_000_000, 100_000, read: 2_000_000, write: 400_000), at: price)
        XCTAssertEqual(cost?.input ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(cost?.output ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(cost?.cacheRead ?? 0, 0.6, accuracy: 1e-9)
        XCTAssertEqual(cost?.cacheWrite ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(UsageCost.cacheSavings(tokens(0, 0, read: 2_000_000), at: price), 5.4, accuracy: 1e-9)
        XCTAssertNil(UsageCost.of(tokens(1, 1), at: nil))
        XCTAssertEqual(tokens(100, 0, read: 300).cacheHitRate ?? 0, 0.75, accuracy: 1e-9)
    }

    func testTheLedgerBucketsByHour() {
        var ledger = UsageLedger()
        ledger.add(agent: "claude", model: "claude-sonnet-4-5", date: now.addingTimeInterval(-100), tokens: tokens(10, 5), calendar: calendar)
        ledger.add(agent: "claude", model: "claude-sonnet-4-5", date: now.addingTimeInterval(-200), tokens: tokens(1, 1), calendar: calendar)
        ledger.add(agent: "claude", model: "", date: now, tokens: tokens(0, 0), calendar: calendar)
        XCTAssertEqual(ledger.buckets.count, 1)
        XCTAssertEqual(ledger.buckets.values.first?.total, 17)
        XCTAssertEqual(ledger.replies.values.first, 2)
    }

    func testInsightsForAWeek() {
        var ledger = UsageLedger()
        let day = 86_400.0
        ledger.add(agent: "claude", model: "claude-sonnet-4-5", date: now.addingTimeInterval(-3_600), tokens: tokens(1_000_000, 0, read: 1_000_000), calendar: calendar)
        ledger.add(agent: "codex", model: "gpt-5-codex", date: now.addingTimeInterval(-2 * day), tokens: tokens(0, 1_000_000), calendar: calendar)
        ledger.add(agent: "codex", model: "gpt-9", date: now.addingTimeInterval(-2 * day), tokens: tokens(500_000, 0), calendar: calendar)
        // Older than the window.
        ledger.add(agent: "claude", model: "claude-sonnet-4-5", date: now.addingTimeInterval(-20 * day), tokens: tokens(9_000_000, 0), calendar: calendar)

        let insights = UsageInsights.make(ledger, window: .week, now: now, calendar: calendar, sessions: ["claude": 3, "codex": 1])
        XCTAssertEqual(insights.columns.count, 7)
        XCTAssertEqual(insights.tokens.total, 3_500_000)
        // Sonnet: 1M input at $3 + 1M cached at $0.30; Codex: 1M output at $10; gpt-9 has no price.
        XCTAssertEqual(insights.cost.total, 13.3, accuracy: 1e-9)
        XCTAssertEqual(insights.unpricedTokens, 500_000)
        XCTAssertEqual(insights.cacheSavings, 2.7, accuracy: 1e-9)
        XCTAssertEqual(insights.sessions, 4)
        XCTAssertEqual(insights.agents.map(\.agent), ["claude", "codex"])
        XCTAssertEqual(insights.agents.first?.costShare ?? 0, 3.3 / 13.3, accuracy: 1e-9)
        XCTAssertEqual(insights.models.map(\.model), ["gpt-5-codex", "claude-sonnet-4-5", "gpt-9"])
        XCTAssertNil(insights.models.last?.cost)
        XCTAssertEqual(insights.models[1].tokens.cacheHitRate ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(insights.models[0].costPerMillion ?? 0, 10, accuracy: 1e-9)
        // Every agent has a value in every column.
        XCTAssertEqual(insights.points.count, 14)
        XCTAssertEqual(insights.points.filter { $0.agent == "claude" }.map(\.tokens).reduce(0, +), 2_000_000)
        XCTAssertEqual(insights.unpricedShare, 500_000.0 / 3_500_000.0, accuracy: 1e-9)
    }

    func testTheLastDayIsHourly() {
        var ledger = UsageLedger()
        ledger.add(agent: "claude", model: "claude-haiku-4-5", date: now.addingTimeInterval(-30 * 3_600), tokens: tokens(5, 5), calendar: calendar)
        ledger.add(agent: "claude", model: "claude-haiku-4-5", date: now.addingTimeInterval(-60), tokens: tokens(1, 1), calendar: calendar)
        let insights = UsageInsights.make(ledger, window: .day, now: now, calendar: calendar)
        XCTAssertEqual(insights.columns.count, 24)
        XCTAssertEqual(insights.tokens.total, 2)
        XCTAssertEqual(insights.points.map(\.tokens).reduce(0, +), 2)
    }

    func testNarrowingToOneModel() {
        var ledger = UsageLedger()
        ledger.add(agent: "claude", model: "a", date: now, tokens: tokens(1, 0), calendar: calendar)
        ledger.add(agent: "claude", model: "b", date: now, tokens: tokens(2, 0), calendar: calendar)
        let insights = UsageInsights.make(ledger, window: .week, now: now, calendar: calendar, model: "b")
        XCTAssertEqual(insights.tokens.total, 2)
        XCTAssertEqual(insights.models.map(\.model), ["b"])
    }

    func testFormats() {
        XCTAssertEqual(UsageFormat.tokens(845), "845")
        XCTAssertEqual(UsageFormat.tokens(12_400), "12.4K")
        XCTAssertEqual(UsageFormat.tokens(3_000_000), "3M")
        XCTAssertEqual(UsageFormat.tokens(1_260_000_000), "1.3B")
        XCTAssertEqual(UsageFormat.usd(4.2), "$4.20")
        XCTAssertEqual(UsageFormat.usd(12_345), "$12.3K")
        XCTAssertEqual(UsageFormat.percent(0.4234), "42%")
        XCTAssertEqual(UsageFormat.percent(0.004), "0.4%")
        XCTAssertEqual(UsageFormat.percent(0.0004), "<0.1%")
    }

    func testSessionsComeFromTheLedger() {
        var ledger = UsageLedger()
        ledger.add(agent: "claude", model: "a", date: now, tokens: tokens(1, 0), calendar: calendar)
        ledger.addSession(agent: "claude", ended: now.addingTimeInterval(-3_600))
        ledger.addSession(agent: "claude", ended: now.addingTimeInterval(-40 * 86_400))
        let insights = UsageInsights.make(ledger, window: .week, now: now, calendar: calendar)
        XCTAssertEqual(insights.sessions, 1)
        XCTAssertEqual(insights.agents.first?.sessions, 1)
    }
}
