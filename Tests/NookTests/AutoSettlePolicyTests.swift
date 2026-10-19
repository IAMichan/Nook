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

    func testInactivityAndRecentActivity() {
        XCTAssertEqual(decide(row(ageDays: 5)), .settle(.inactivity))
        XCTAssertEqual(decide(row(ageDays: 1)), .keep(.recentActivity))
        var off = on; off.inactivityDays = 0
        XCTAssertEqual(decide(row(ageDays: 50), off), .keep(.recentActivity))
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
        // Expired snooze no longer blocks.
        let expired = row { $0.snoozedUntil = self.now.addingTimeInterval(-1) }
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
}
