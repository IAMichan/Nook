import XCTest

@MainActor
final class FinishedSessionsTests: XCTestCase {
    private var key = "Test Agent|finished-sessions-test"

    override func setUp() {
        super.setUp()
        key = "Test Agent|finished-sessions-test-\(UUID().uuidString)"
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

    func testBusyChatMarkedByYouStaysFinishedUntilANewTurn() {
        let store = FinishedSessions.shared
        store.mark(key, busy: true)
        store.reconcile(busy: [key])
        XCTAssertTrue(store.contains(key), "settled during a hanging turn: the turn does not undo it")
        XCTAssertTrue(store.isMarkedWhileBusy(key))
        store.reconcile(busy: [])
        XCTAssertTrue(store.contains(key), "the turn ended: still finished")
        XCTAssertFalse(store.isMarkedWhileBusy(key))
        store.reconcile(busy: [key])
        XCTAssertFalse(store.contains(key), "a new turn reopens it")
    }

    func testIdleMarkReopensWhenTheAgentWorksAgain() {
        let store = FinishedSessions.shared
        store.mark(key)
        store.reconcile(busy: [key])
        XCTAssertFalse(store.contains(key))
    }

    func testKeysFollowTheConversation() {
        XCTAssertEqual(FinishedSessions.key(agent: "Codex", conversation: "abc", fallback: "x"), "Codex|abc")
        XCTAssertEqual(FinishedSessions.key(agent: "Codex", conversation: "", fallback: "x"), "x")
        XCTAssertEqual(FinishedSessions.key(agent: "Codex", conversation: nil, fallback: "x"), "x")
    }
}
