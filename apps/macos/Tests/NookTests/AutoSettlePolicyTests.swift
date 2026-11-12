import XCTest

final class AutoSettlePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000_000)
    private let on = AutoSettlePolicy.Settings(enabled: true, inactivityDays: 3, settleOnMergedPullRequest: true)

    private func row(ageDays: Double = 5, _ edit: (inout InboxRow) -> Void = { _ in }) -> InboxRow {
        var r = InboxRow(id: "a", title: "t", project: "p", attention: .idle,
                         lastActivity: now.addingTimeInterval(-ageDays * 86_400))
        edit(&r)
        return r
    }

    private func decide(_ r: InboxRow, merged: Bool = false, _ s: AutoSettlePolicy.Settings? = nil) -> AutoSettleDecision {
        AutoSettlePolicy.decide(row: r, prMerged: merged, settings: s ?? on, now: now)
    }

    func testDefaults() {
        let s = AutoSettlePolicy.Settings()
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.inactivityDays, 3)
    }

    func testInitialSettingsForNewAndExistingInstalls() {
        let fresh = AutoSettlePolicy.newInstallDefaults
        XCTAssertTrue(fresh.enabled)
        XCTAssertEqual(fresh.inactivityDays, 7)
        XCTAssertTrue(fresh.settleOnMergedPullRequest)
        // Nothing stored and no trace of an earlier Nook: a new install.
        XCTAssertEqual(AutoSettlePolicy.initial(stored: nil, usedSince: nil, now: now), fresh)
        // The trace was just written by this very launch: still a new install.
        XCTAssertEqual(AutoSettlePolicy.initial(stored: nil, usedSince: now.addingTimeInterval(-60), now: now), fresh)
        // Nook ran here before: keep the old default (off).
        XCTAssertEqual(AutoSettlePolicy.initial(stored: nil, usedSince: now.addingTimeInterval(-86_400), now: now),
                       AutoSettlePolicy.Settings())
        // What is stored always wins.
        let stored = AutoSettlePolicy.Settings(enabled: false, inactivityDays: 2)
        XCTAssertEqual(AutoSettlePolicy.initial(stored: stored, usedSince: nil, now: now), stored)
    }

    func testInactivityAndRecentActivity() {
        XCTAssertEqual(decide(row(ageDays: 5)), .settle(.inactivity))
        XCTAssertEqual(decide(row(ageDays: 1)), .keep(.recentActivity))
        var off = on; off.inactivityDays = 0
        XCTAssertEqual(decide(row(ageDays: 50), off), .keep(.recentActivity))
    }

    func testReopenedSessionStaysUntilItHasNewActivity() {
        // Brought back from Settled after it went quiet: the rules leave it alone, also a merged pull request.
        let reopened = row(ageDays: 30) { $0.unsettledAt = self.now.addingTimeInterval(-86_400) }
        XCTAssertEqual(decide(reopened), .keep(.unsettledByYou))
        XCTAssertEqual(decide(reopened, merged: true), .keep(.unsettledByYou))
        // Something new happened in it after that: the usual rules apply again.
        let resumed = row(ageDays: 5) { $0.unsettledAt = self.now.addingTimeInterval(-10 * 86_400) }
        XCTAssertEqual(decide(resumed), .settle(.inactivity))
    }

    func testQuietTimeCountsFromWhenASnoozeRanOut() {
        // Quiet for 10 days, but a snooze woke it a day ago: not quiet long enough yet.
        let woke = row(ageDays: 10) { $0.snoozedUntil = self.now.addingTimeInterval(-86_400) }
        XCTAssertEqual(decide(woke), .keep(.recentActivity))
        let wokeLongAgo = row(ageDays: 10) { $0.snoozedUntil = self.now.addingTimeInterval(-5 * 86_400) }
        XCTAssertEqual(decide(wokeLongAgo), .settle(.inactivity))
    }

    func testMergedPullRequest() {
        XCTAssertEqual(decide(row(ageDays: 0), merged: true), .settle(.mergedPullRequest))
        var s = on; s.settleOnMergedPullRequest = false
        XCTAssertEqual(decide(row(ageDays: 0), merged: true, s), .keep(.recentActivity))
    }

    func testDisabledAndSettled() {
        XCTAssertEqual(decide(row(), AutoSettlePolicy.Settings()), .keep(.disabled))
        XCTAssertEqual(decide(row { $0.settled = true }), .keep(.alreadySettled))
    }

    func testNeverSettlesWhatIsBusyOrWaiting() {
        XCTAssertEqual(decide(row { $0.hasOpenRequest = true }, merged: true), .keep(.openRequest))
        XCTAssertEqual(decide(row { $0.attention = .input }), .keep(.openRequest))
        XCTAssertEqual(decide(row { $0.isActive = true }, merged: true), .keep(.turnRunning))
        XCTAssertEqual(decide(row { $0.hasBackgroundWork = true }), .keep(.backgroundWork))
        XCTAssertEqual(decide(row { $0.hasQueued = true }), .keep(.queuedMessages))
        XCTAssertEqual(decide(row { $0.pinned = true }, merged: true), .keep(.pinned))
    }

    func testOptOutIsReversible() {
        var s = on; s.perThreadOptOut = ["a"]
        XCTAssertEqual(decide(row(), s), .keep(.optedOut))
        s.perThreadOptOut = []
        XCTAssertEqual(decide(row(), s), .settle(.inactivity))
    }

    func testSnoozeBlocksUntilItEndsOrWakes() {
        let snoozed = row { $0.snoozedUntil = self.now.addingTimeInterval(3600); $0.snoozedAt = self.now.addingTimeInterval(-86_400 * 6) }
        XCTAssertEqual(decide(snoozed), .keep(.snoozed))
        // An expired snooze no longer blocks (its quiet time counts from when it ran out, see
        // testQuietTimeCountsFromWhenASnoozeRanOut).
        let expired = row { $0.snoozedUntil = self.now.addingTimeInterval(-4 * 86_400) }
        XCTAssertEqual(decide(expired), .settle(.inactivity))
        // Woken early by a failure: not hidden any more, so not protected.
        let failed = row { $0.snoozedUntil = self.now.addingTimeInterval(3600); $0.attention = .failed }
        XCTAssertEqual(decide(failed), .settle(.inactivity))
    }

    func testSettingsDecodeTolerantly() throws {
        let s = try JSONDecoder().decode(AutoSettlePolicy.Settings.self, from: Data(#"{"enabled":true,"x":1}"#.utf8))
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.inactivityDays, 3)
        XCTAssertTrue(s.perThreadOptOut.isEmpty)
    }

    func testOldUntouchedDefaultGetsT3codeRulesOnce() {
        let old = AutoSettlePolicy.Settings(perThreadOptOut: ["run:a"])
        let up = AutoSettlePolicy.upgradingOldDefault(old)
        XCTAssertTrue(up.enabled)
        XCTAssertEqual(up.inactivityDays, 7)
        XCTAssertTrue(up.settleOnMergedPullRequest)
        XCTAssertTrue(up.settleOnClosedPullRequest)
        XCTAssertEqual(up.perThreadOptOut, ["run:a"])
    }

    func testChangedSettingsAreNotUpgraded() {
        let chosen = AutoSettlePolicy.Settings(enabled: false, inactivityDays: 14)
        XCTAssertEqual(AutoSettlePolicy.upgradingOldDefault(chosen), chosen)
        let on = AutoSettlePolicy.Settings(enabled: true, inactivityDays: 3)
        XCTAssertEqual(AutoSettlePolicy.upgradingOldDefault(on), on)
    }
}
