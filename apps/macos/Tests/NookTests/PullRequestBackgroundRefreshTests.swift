import XCTest

final class PullRequestBackgroundRefreshTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testWaitStretchesWithTheEnergyPlan() {
        XCTAssertEqual(PullRequestBackgroundRefresh.wait(plan: EnergyPlan(pace: .full, reasons: [])), 600)
        XCTAssertEqual(PullRequestBackgroundRefresh.wait(plan: EnergyPlan(pace: .light, reasons: [.battery])), 1200)
        XCTAssertEqual(PullRequestBackgroundRefresh.wait(plan: EnergyPlan(pace: .paused, reasons: [.lowBattery])), 3600)
    }

    func testDueOnceTheIntervalPassed() {
        let plan = EnergyPlan.fullSpeed
        XCTAssertFalse(PullRequestBackgroundRefresh.isDue(lastRead: now.addingTimeInterval(-599), now: now, plan: plan, signals: EnergySignals()))
        XCTAssertTrue(PullRequestBackgroundRefresh.isDue(lastRead: now.addingTimeInterval(-600), now: now, plan: plan, signals: EnergySignals()))
        XCTAssertTrue(PullRequestBackgroundRefresh.isDue(lastRead: .distantPast, now: now, plan: plan, signals: EnergySignals()))
    }

    func testARecentReadByThePanelPostponesIt() {
        let light = EnergyPlan(pace: .light, reasons: [.battery])
        XCTAssertFalse(PullRequestBackgroundRefresh.isDue(lastRead: now.addingTimeInterval(-900), now: now, plan: light, signals: EnergySignals()))
    }

    func testNothingWhileAwayOrTheDisplaysSleep() {
        var away = EnergySignals()
        away.away = true
        var asleep = EnergySignals()
        asleep.displayAsleep = true
        XCTAssertFalse(PullRequestBackgroundRefresh.isDue(lastRead: .distantPast, now: now, plan: .fullSpeed, signals: away))
        XCTAssertFalse(PullRequestBackgroundRefresh.isDue(lastRead: .distantPast, now: now, plan: .fullSpeed, signals: asleep))
    }

    func testAClockThatWentBackCountsAsDue() {
        XCTAssertTrue(PullRequestBackgroundRefresh.isDue(lastRead: now.addingTimeInterval(60), now: now, plan: .fullSpeed, signals: EnergySignals()))
    }
}
