import XCTest

@MainActor
final class FinishedSessionsTests: XCTestCase {
    private let key = "Test Agent|finished-sessions-test"

    override func setUp() {
        super.setUp()
        FinishedSessions.shared.reopen(key)
    }

    override func tearDown() {
        FinishedSessions.shared.reopen(key)
        super.tearDown()
    }

    func testMarkedChatIsFinishedAndReopensByHand() {
        let store = FinishedSessions.shared
        let now = Date()
        XCTAssertFalse(store.isFinished(key: key, idle: true, lastActive: now, now: now))
        store.mark(key)
        XCTAssertTrue(store.isFinished(key: key, idle: false, lastActive: now, now: now), "a mark holds whatever the state")
        store.reopenByUser(key)
        XCTAssertFalse(store.isFinished(key: key, idle: true, lastActive: now.addingTimeInterval(-3600), now: now),
                       "reopened after its last activity: stays open")
    }

    func testIdleChatFinishesByItself() {
        let store = FinishedSessions.shared
        let now = Date()
        let quiet = now.addingTimeInterval(-FinishedSessions.autoFinishAfter - 1)
        XCTAssertTrue(store.isFinished(key: key, idle: true, lastActive: quiet, now: now))
        XCTAssertFalse(store.isFinished(key: key, idle: true, lastActive: now.addingTimeInterval(-60), now: now), "too recent")
        XCTAssertFalse(store.isFinished(key: key, idle: false, lastActive: quiet, now: now), "the agent is working")
        XCTAssertFalse(store.isFinished(key: key, idle: true, lastActive: nil, now: now), "no known activity")
    }

    func testReopenedChatFinishesAgainAfterNewActivity() {
        let store = FinishedSessions.shared
        store.reopenByUser(key)
        // New activity after the reopen, then quiet again for longer than the delay.
        let activity = Date().addingTimeInterval(60)
        let now = activity.addingTimeInterval(FinishedSessions.autoFinishAfter + 1)
        XCTAssertTrue(store.isFinished(key: key, idle: true, lastActive: activity, now: now))
    }

    func testKeysFollowTheConversation() {
        XCTAssertEqual(FinishedSessions.key(agent: "Codex", conversation: "abc", fallback: "x"), "Codex|abc")
        XCTAssertEqual(FinishedSessions.key(agent: "Codex", conversation: "", fallback: "x"), "x")
        XCTAssertEqual(FinishedSessions.key(agent: "Codex", conversation: nil, fallback: "x"), "x")
    }
}
