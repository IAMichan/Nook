import XCTest

final class ScrollModelTests: XCTestCase {
    private func frame(_ offset: Double, content: Double = 2000) -> ScrollFrame {
        ScrollFrame(offset: offset, content: content, container: 600)
    }

    func testScrollingUpNearTheEndStopsFollowingAtOnce() {
        // A wheel or a drag that began at the end, still within the margin `atEnd` allows.
        let model = ScrollModel()
        XCTAssertEqual(model.reaction(movedFrom: frame(1400), to: frame(1390)), .userScrolled)
    }

    func testGrowthIsNotAScroll() {
        var model = ScrollModel()
        XCTAssertNil(model.reaction(movedFrom: frame(1400), to: frame(1380, content: 1980)), "a row above measured shorter")
        XCTAssertNil(model.reaction(movedFrom: frame(1400), to: frame(1600, content: 2200)), "the reply grew")
        model.userScrolled()
        XCTAssertNil(model.reaction(movedFrom: frame(1200), to: frame(1100)), "already free: nothing to write")
    }

    func testABounceBackToTheEndKeepsFollowing() {
        let model = ScrollModel()
        XCTAssertNil(model.reaction(movedFrom: frame(1420), to: frame(1400)))
    }

    func testScrollingBackToTheVeryEndFollowsAgain() {
        var model = ScrollModel()
        model.userScrolled()
        XCTAssertNil(model.reaction(movedFrom: frame(1300), to: frame(1340)), "not at the end yet")
        let reaction = model.reaction(movedFrom: frame(1340), to: frame(1360))
        XCTAssertEqual(reaction, .reachedEnd)
        if let reaction { model.apply(reaction) }
        XCTAssertTrue(model.shouldFollowEnd)
        model.findStarted()
        XCTAssertNil(model.reaction(movedFrom: frame(1380), to: frame(1400)), "a find owns the position")
    }

    func testTheEndLeavesOutTheRoomAroundTheView() {
        // As a real scroll view reports it with a 40 pt toolbar above and a 100 pt composer under: the container is the
        // height between them, and the very end is at 1881 (measured).
        let end = ScrollFrame(offset: 1881, content: 2281, container: 360, insetTop: 40, insetBottom: 100)
        XCTAssertEqual(end.maxOffset, 1881)
        XCTAssertTrue(end.nearEnd, "at its end: no pill back to the end")
        let up = ScrollFrame(offset: 1700, content: 2281, container: 360, insetTop: 40, insetBottom: 100)
        XCTAssertFalse(up.nearEnd)
        XCTAssertEqual(ScrollFrame(offset: -40, content: 200, container: 360, insetTop: 40).maxOffset, -40, "content that fits")
    }

    func testStartsFollowing() {
        let m = ScrollModel()
        XCTAssertTrue(m.shouldFollowEnd)
        XCTAssertFalse(m.cancelQueuedScrolls)
    }

    func testUserScrollCancelsFollowingAndQueuedScrolls() {
        var m = ScrollModel()
        m.userScrolled()
        XCTAssertFalse(m.shouldFollowEnd)
        XCTAssertTrue(m.cancelQueuedScrolls)
        XCTAssertTrue(m.isFreeAfterUserScroll)
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

    func testToEndPillOnlyAfterScrollingAwayFromTheEnd() {
        var m = ScrollModel()
        XCTAssertFalse(m.showsToEndPill(atEnd: false))
        m.userScrolled()
        XCTAssertTrue(m.showsToEndPill(atEnd: false))
        // At the end it never shows, even before following resumes.
        XCTAssertFalse(m.showsToEndPill(atEnd: true))
        m.findStarted()
        XCTAssertFalse(m.showsToEndPill(atEnd: false))
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

    func testRowsInViewIsBlankOnlyWhenNoDrawnRowReachesIntoTheView() {
        typealias Span = RowsInView.Span
        // A row in the middle of the view, or one running through all of it.
        XCTAssertFalse(RowsInView.blank(rows: 10, drawn: [Span(top: 1200, bottom: 1300)], top: 1000, height: 600))
        XCTAssertFalse(RowsInView.blank(rows: 10, drawn: [Span(top: 0, bottom: 5000)], top: 1000, height: 600))
        // Rows still drawn, but all of them above or below the view: what a lazy stack's own reports call "in view".
        XCTAssertTrue(RowsInView.blank(rows: 10, drawn: [Span(top: 200, bottom: 990), Span(top: 1700, bottom: 1800)],
                                       top: 1000, height: 600))
        // A hairline at the edge, or a row with no height, is not something to read.
        XCTAssertTrue(RowsInView.blank(rows: 10, drawn: [Span(top: 900, bottom: 1004)], top: 1000, height: 600))
        XCTAssertTrue(RowsInView.blank(rows: 10, drawn: [Span(top: 1200, bottom: 1200)], top: 1000, height: 600))
        // No row drawn at all.
        XCTAssertTrue(RowsInView.blank(rows: 10, drawn: [], top: 1000, height: 600))
        // Nothing to show, or no view yet: never blank.
        XCTAssertFalse(RowsInView.blank(rows: 0, drawn: [], top: 1000, height: 600))
        XCTAssertFalse(RowsInView.blank(rows: 10, drawn: [], top: 0, height: 0))
    }

    func testABlankConversationIsRebuiltFromItsThirdTryOnEveryFourth() {
        let rebuilt = (0..<12).filter { RowsInView.rebuilds(attempt: $0) }
        XCTAssertEqual(rebuilt, [2, 6, 10])
    }

    func testOnlyTheFirstFrameOfAScrollChangesTheState() {
        var m = ScrollModel()
        XCTAssertFalse(m.isFreeAfterUserScroll)
        m.userScrolled()
        XCTAssertTrue(m.isFreeAfterUserScroll)
        let before = m
        m.userScrolled()
        XCTAssertEqual(m, before)
        m.jumpedToEnd()
        XCTAssertFalse(m.isFreeAfterUserScroll)
    }
}
