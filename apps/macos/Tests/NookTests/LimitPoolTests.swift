import XCTest

final class LimitPoolTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let fiveHours: TimeInterval = 5 * 3600
    private let week: TimeInterval = 7 * 86_400

    func testNoLimitsNoPool() {
        XCTAssertNil(LimitPool.make([LimitPool.Account(id: "a", name: "a", limits: [])], now: now))
    }

    func testOneAccountIsAPoolOfOne() throws {
        let pool = try XCTUnwrap(LimitPool.make([LimitPool.Account(id: "a", name: "a", limits: [
            .init(label: "5 hours", used: 38, resetsAt: now.addingTimeInterval(3600), duration: fiveHours),
        ])], now: now))
        XCTAssertEqual(pool.windows.map(\.left), [62])
        XCTAssertEqual(pool.windows.map(\.used), [38])
        XCTAssertEqual(pool.windows[0].columns.map(\.left), [62])
    }

    func testThePoolAveragesAndKeepsColumns() throws {
        let work = LimitPool.Account(id: "w", name: "Work", limits: [
            .init(label: "5 hours", used: 80, resetsAt: now.addingTimeInterval(600)),
            .init(label: "Week", used: 50, resetsAt: now.addingTimeInterval(86_400)),
        ])
        let personal = LimitPool.Account(id: "p", name: "Personal", limits: [
            .init(label: "5 hours", used: 20, resetsAt: now.addingTimeInterval(7_200)),
        ])
        let pool = try XCTUnwrap(LimitPool.make([personal, work], now: now))
        XCTAssertEqual(pool.windows.map(\.label), ["5 hours", "Week"])
        // Work refills first, so it comes first in every window.
        XCTAssertEqual(pool.windows[0].columns.map(\.name), ["Work", "Personal"])
        XCTAssertEqual(pool.windows[1].columns.map(\.name), ["Work", "Personal"])
        XCTAssertEqual(pool.windows[0].left, 50)
        // Personal reports no weekly window: a gap, not zero.
        XCTAssertNil(pool.windows[1].columns[1].left)
        XCTAssertEqual(pool.windows[1].left, 50)
        // Work's 5-hour reset hands back its 80 % of one of two accounts: 40 % of the pool.
        XCTAssertEqual(pool.windows[0].nextRefill, LimitPool.Reset(accountID: "w", at: now.addingTimeInterval(600), restores: 40))
    }

    func testPaceComparesSpendingWithTheClock() throws {
        // Two hours into five, 40 % elapsed: 60 % used is ahead, 40 % on pace, 10 % under.
        let reset = now.addingTimeInterval(3 * 3600)
        func pace(_ used: Double) -> LimitPool.Pace? {
            LimitPool.pace(.init(label: "5 hours", used: used, resetsAt: reset, duration: fiveHours), now: now)
        }
        XCTAssertEqual(pace(60), .ahead)
        XCTAssertEqual(pace(40), .on)
        XCTAssertEqual(pace(10), .under)
        XCTAssertEqual(LimitPool.timeLeft(.init(label: "5 hours", used: 0, resetsAt: reset, duration: fiveHours), now: now), 60)
        XCTAssertEqual(LimitPool.timeElapsed(.init(label: "5 hours", used: 0, resetsAt: reset, duration: fiveHours), now: now), 40)
        // Without a reset time there is no clock, so no pace.
        XCTAssertNil(LimitPool.pace(.init(label: "5 hours", used: 1, resetsAt: nil, duration: fiveHours), now: now))
    }

    func testASpentWeekEmptiesTheSessionWindow() throws {
        let account = LimitPool.Account(id: "a", name: "a", limits: [
            .init(label: "5 hours", used: 20, resetsAt: now.addingTimeInterval(3600), duration: fiveHours),
            .init(label: "Week", used: 100, resetsAt: now.addingTimeInterval(86_400), duration: week),
        ])
        let pool = try XCTUnwrap(LimitPool.make([account], now: now))
        let session = try XCTUnwrap(pool.windows.first { $0.kind == .session })
        XCTAssertEqual(session.left, 0)
        XCTAssertNil(session.pace)
        // The session resets first but the week still blocks it: it comes back with the week, all of it.
        XCTAssertEqual(session.columns[0].limit?.resetsAt, now.addingTimeInterval(86_400))
        XCTAssertEqual(session.columns[0].refill, 100)
    }

    func testASpentWeekOfAnotherGroupLeavesTheSessionWindowAlone() throws {
        let account = LimitPool.Account(id: "a", name: "a", limits: [
            .init(label: "Gemini · 5 hours", used: 19, resetsAt: now.addingTimeInterval(3 * 3600), duration: fiveHours),
            .init(label: "Gemini · Week", used: 8, resetsAt: now.addingTimeInterval(4 * 86_400), duration: week),
            .init(label: "Gemini 4 Argon · Week", used: 100, resetsAt: now.addingTimeInterval(4 * 86_400), duration: week),
        ])
        let pool = try XCTUnwrap(LimitPool.make([account], now: now))
        let session = try XCTUnwrap(pool.windows.first { $0.label == "Gemini · 5 hours" })
        XCTAssertEqual(session.used, 19)
        XCTAssertEqual(session.columns[0].limit?.resetsAt, now.addingTimeInterval(3 * 3600))
    }

    func testSessionWindowsSortBeforeTheWeek() throws {
        let account = LimitPool.Account(id: "a", name: "a", limits: [
            .init(label: "Week", used: 10, resetsAt: now.addingTimeInterval(86_400), duration: week),
            .init(label: "5 hours", used: 10, resetsAt: now.addingTimeInterval(3600), duration: fiveHours),
        ])
        XCTAssertEqual(try XCTUnwrap(LimitPool.make([account], now: now)).windows.map(\.label), ["5 hours", "Week"])
    }

    func testAPoolWeighsItsAccountsByPlanSize() throws {
        let weights = (max: LimitPool.weights(agent: "claude", plan: "Max 5x"), pro: LimitPool.weights(agent: "claude", plan: "Pro"))
        let max = LimitPool.Account(id: "m", name: "Max", limits: [
            .init(label: "5 hours", used: 0, resetsAt: now.addingTimeInterval(3600), duration: fiveHours),
            .init(label: "Week", used: 0, resetsAt: now.addingTimeInterval(86_400), duration: week),
        ], sessionWeight: weights.max.session, weeklyWeight: weights.max.weekly)
        let pro = LimitPool.Account(id: "p", name: "Pro", limits: [
            .init(label: "5 hours", used: 60, resetsAt: now.addingTimeInterval(1800), duration: fiveHours),
            .init(label: "Week", used: 60, resetsAt: now.addingTimeInterval(7_200), duration: week),
        ], sessionWeight: weights.pro.session, weeklyWeight: weights.pro.weekly)
        let pool = try XCTUnwrap(LimitPool.make([max, pro], now: now))
        // Max 5x holds five times Pro's session: 60 % of one sixth of the pool is 10 %.
        let session = try XCTUnwrap(pool.windows.first { $0.kind == .session })
        XCTAssertEqual(session.used, 10)
        XCTAssertEqual(session.nextRefill?.restores, 10)
        // Claude's plans name no weekly size, so the week counts both accounts once.
        XCTAssertEqual(try XCTUnwrap(pool.windows.first { $0.kind == .weekly }).used, 30)
    }

    func testAnUnknownPlanCountsEveryAccountOnce() throws {
        let plus = LimitPool.weights(agent: "codex", plan: "Plus")
        let a = LimitPool.Account(id: "a", name: "a", limits: [.init(label: "5 hours", used: 80, resetsAt: nil, duration: fiveHours)],
                                  sessionWeight: plus.session, weeklyWeight: plus.weekly)
        let b = LimitPool.Account(id: "b", name: "b", limits: [.init(label: "5 hours", used: 20, resetsAt: nil, duration: fiveHours)])
        XCTAssertEqual(try XCTUnwrap(LimitPool.make([a, b], now: now)).windows[0].used, 50)
    }

    func testPlanSizes() {
        XCTAssertEqual(LimitPool.weights(agent: "claude", plan: "Max 20x").session, 20)
        XCTAssertEqual(LimitPool.weights(agent: "claude", plan: "Max").session, 5)
        XCTAssertNil(LimitPool.weights(agent: "claude", plan: "Max 5x").weekly)
        XCTAssertNil(LimitPool.weights(agent: "claude", plan: "Team").session)
        XCTAssertEqual(LimitPool.weights(agent: "codex", plan: "Pro").weekly, 20)
        XCTAssertEqual(LimitPool.weights(agent: "codex", plan: "Plus").session, 1)
        XCTAssertNil(LimitPool.weights(agent: "gemini", plan: "Pro").session)
        XCTAssertNil(LimitPool.weights(agent: "codex", plan: "").session)
    }
}
