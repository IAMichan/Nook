import XCTest

final class ScrollModelTests: XCTestCase {
    func testStartsFollowing() {
        let m = ScrollModel()
        XCTAssertTrue(m.shouldFollowEnd)
        XCTAssertNil(m.anchorMessageID)
        XCTAssertEqual(m.anchorOffset, 24)
    }

    func testUserScrollCancelsFollowingAndQueuedScrolls() {
        var m = ScrollModel()
        m.userScrolled()
        XCTAssertFalse(m.shouldFollowEnd)
        XCTAssertTrue(m.cancelQueuedScrolls)
        m.contentGrew(toolActivityStarted: true, overflows: true)
        XCTAssertFalse(m.shouldFollowEnd)
    }

    func testSendAnchorsThenToolActivityFollows() {
        var m = ScrollModel()
        let id = UUID()
        m.userScrolled()
        m.sent(messageID: id)
        XCTAssertEqual(m.mode, .anchoringNewTurn)
        XCTAssertEqual(m.anchorMessageID, id)
        XCTAssertFalse(m.cancelQueuedScrolls)
        XCTAssertFalse(m.shouldFollowEnd)
        m.contentGrew(toolActivityStarted: false, overflows: true)
        XCTAssertEqual(m.mode, .anchoringNewTurn)
        m.contentGrew(toolActivityStarted: true, overflows: false)
        XCTAssertEqual(m.mode, .anchoringNewTurn)
        m.contentGrew(toolActivityStarted: true, overflows: true)
        XCTAssertTrue(m.shouldFollowEnd)
        XCTAssertNil(m.anchorMessageID)
    }

    func testUserScrollLeavesAnchor() {
        var m = ScrollModel()
        m.sent(messageID: UUID())
        m.userScrolled()
        XCTAssertEqual(m.mode, .free)
        XCTAssertNil(m.anchorMessageID)
    }

    func testReachedEndResumesFollowingJumpToo() {
        var m = ScrollModel()
        m.userScrolled()
        m.reachedEnd()
        XCTAssertTrue(m.shouldFollowEnd)
        m.userScrolled()
        m.jumpedToEnd()
        XCTAssertTrue(m.shouldFollowEnd)
        XCTAssertFalse(m.cancelQueuedScrolls)
        // reaching the end while anchored keeps the anchor
        m.sent(messageID: UUID())
        m.reachedEnd()
        XCTAssertEqual(m.mode, .anchoringNewTurn)
    }

    func testFindStopsFollowingAndHidesPill() {
        var m = ScrollModel()
        m.findStarted()
        XCTAssertFalse(m.shouldFollowEnd)
        XCTAssertTrue(m.cancelQueuedScrolls)
        XCTAssertFalse(m.jumpPill(awayFor: 10))
        m.reachedEnd()
        XCTAssertEqual(m.mode, .free)
        m.findEnded()
        XCTAssertTrue(m.jumpPill(awayFor: 10))
        m.reachedEnd()
        XCTAssertTrue(m.shouldFollowEnd)
    }

    func testJumpPillAfterDebounce() {
        var m = ScrollModel()
        XCTAssertFalse(m.jumpPill(awayFor: 5))
        m.userScrolled()
        XCTAssertFalse(m.jumpPill(awayFor: 0.1))
        XCTAssertTrue(m.jumpPill(awayFor: 0.15))
        m.reachedEnd()
        XCTAssertFalse(m.jumpPill(awayFor: 5))
    }

    func testMemoryRemembersReplacesAndBounds() {
        var mem = ScrollMemory()
        let anchor = UUID()
        mem.remember(sessionID: "a", position: .offset(120, anchorEventID: anchor))
        XCTAssertEqual(mem.position(for: "a"), .offset(120, anchorEventID: anchor))
        mem.remember(sessionID: "a", position: .end)
        XCTAssertEqual(mem.position(for: "a"), .end)
        XCTAssertEqual(mem.entries.count, 1)
        mem.forget(sessionID: "a")
        XCTAssertNil(mem.position(for: "a"))
        for i in 0..<130 { mem.remember(sessionID: "s\(i)", position: .end) }
        XCTAssertEqual(mem.entries.count, 100)
        XCTAssertNil(mem.position(for: "s0"))
        XCTAssertNotNil(mem.position(for: "s129"))
    }

    func testMemoryCodableAndTolerant() throws {
        var mem = ScrollMemory()
        mem.remember(sessionID: "a", position: .offset(5.5, anchorEventID: nil))
        mem.remember(sessionID: "b", position: .end)
        let back = try JSONDecoder().decode(ScrollMemory.self, from: JSONEncoder().encode(mem))
        XCTAssertEqual(back, mem)
        XCTAssertEqual(try JSONDecoder().decode(ScrollMemory.self, from: Data("{}".utf8)).entries, [])
        let odd = try JSONDecoder().decode(ScrollMemory.Position.self, from: Data(#"{"kind":"future","x":1}"#.utf8))
        XCTAssertEqual(odd, .end)
    }
}
