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

    // MARK: Reading pages ahead

    private func item(_ number: Int, updated: TimeInterval, state: PullRequestItem.State = .open) -> PullRequestItem {
        PullRequestItem(repo: "o/r", number: number, title: "PR \(number)", url: nil, draft: false,
                        updated: now.addingTimeInterval(updated), author: "me", state: state)
    }

    private func account(_ id: String = "github", mine: [PullRequestItem] = [], reviews: [PullRequestItem] = [], error: String? = nil) -> AccountPullRequests {
        AccountPullRequests(id: id, name: id, login: "me", mine: mine, reviews: reviews, error: error)
    }

    private func numbers(_ picks: [PullRequestDetailWarmup.Pick]) -> [Int] { picks.map(\.item.number) }

    func testWarmupReadsReviewsFirstThenYourOwnNewestFirst() {
        let list = [account(mine: [item(1, updated: -500), item(2, updated: -10)], reviews: [item(3, updated: -900), item(4, updated: -20)])]
        let picks = PullRequestDetailWarmup.picks(accounts: list, seen: { _, _ in nil }, now: now, plan: .fullSpeed)
        XCTAssertEqual(numbers(picks), [4, 3, 2, 1])
    }

    func testWarmupSkipsClosedAndFailedAccounts() {
        let list = [account(mine: [item(1, updated: -10, state: .merged), item(2, updated: -20)]),
                    account("github.work", mine: [item(3, updated: -5)], error: "offline")]
        XCTAssertEqual(numbers(PullRequestDetailWarmup.picks(accounts: list, seen: { _, _ in nil }, now: now, plan: .fullSpeed)), [2])
    }

    func testWarmupStaysWithinItsLimitAndTheEnergyPlan() {
        let many = (1...10).map { item($0, updated: -Double($0)) }
        let list = [account(mine: many)]
        let none: (String, String) -> PullRequestDetailWarmup.Seen? = { _, _ in nil }
        XCTAssertEqual(PullRequestDetailWarmup.picks(accounts: list, seen: none, now: now, plan: .fullSpeed).count, 6)
        XCTAssertEqual(PullRequestDetailWarmup.picks(accounts: list, seen: none, now: now, plan: EnergyPlan(pace: .light, reasons: [.battery])).count, 3)
        XCTAssertTrue(PullRequestDetailWarmup.picks(accounts: list, seen: none, now: now, plan: EnergyPlan(pace: .paused, reasons: [.lowBattery])).isEmpty)
    }

    func testWarmupLeavesARecentUnchangedReadAlone() {
        let pr = item(1, updated: -3000)
        let fresh = PullRequestDetailWarmup.Seen(updated: pr.updated, at: now.addingTimeInterval(-600))
        let old = PullRequestDetailWarmup.Seen(updated: pr.updated, at: now.addingTimeInterval(-1800))
        XCTAssertFalse(PullRequestDetailWarmup.isDue(fresh, item: pr, now: now))
        XCTAssertTrue(PullRequestDetailWarmup.isDue(old, item: pr, now: now))
    }

    func testWarmupReadsAChangedOneAgainAfterAShortWait() {
        let pr = item(1, updated: -10)
        let before = now.addingTimeInterval(-4000)
        XCTAssertFalse(PullRequestDetailWarmup.isDue(PullRequestDetailWarmup.Seen(updated: before, at: now.addingTimeInterval(-60)), item: pr, now: now))
        XCTAssertTrue(PullRequestDetailWarmup.isDue(PullRequestDetailWarmup.Seen(updated: before, at: now.addingTimeInterval(-300)), item: pr, now: now))
        XCTAssertTrue(PullRequestDetailWarmup.isDue(PullRequestDetailWarmup.Seen(updated: pr.updated, at: now.addingTimeInterval(60)), item: pr, now: now))
    }

    func testWarmupPassesOverWhatItNeedNotReadToTheNextOne() {
        let list = [account(mine: [item(1, updated: -10), item(2, updated: -20)])]
        let picks = PullRequestDetailWarmup.picks(accounts: list, seen: { _, id in
            id == "o/r#1" ? PullRequestDetailWarmup.Seen(updated: self.now.addingTimeInterval(-10), at: self.now) : nil
        }, now: now, plan: .fullSpeed)
        XCTAssertEqual(numbers(picks), [2])
    }
}
