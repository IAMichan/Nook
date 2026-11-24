import XCTest

final class ScrollModelTests: XCTestCase {
    private func frame(_ offset: Double, content: Double = 2000) -> ScrollFrame {
        ScrollFrame(offset: offset, content: content, container: 600)
    }

    func testScrollingUpNearTheEndStopsFollowingAtOnce() {
        // The keyboard, or anything else without a wheel step: up while the sizes stay the same, within the margin too.
        let model = ScrollModel()
        XCTAssertTrue(model.releases(movedFrom: frame(1400), to: frame(1390)))
    }

    func testAWheelStepUpStopsFollowingWhileTheContentGrows() {
        // While an agent works the sizes change on nearly every frame, so a move alone cannot tell you scrolled.
        var model = ScrollModel()
        XCTAssertFalse(model.releases(movedFrom: frame(1400), to: frame(1500, content: 2100)))
        XCTAssertTrue(model.releases(wheel: 3), "up, even within the end margin")
        model.userScrolled()
        XCTAssertFalse(model.shouldFollowEnd)
        XCTAssertFalse(model.releases(wheel: 3), "already free: nothing to write")
        XCTAssertFalse(model.releases(wheel: 0.2), "a sideways step")
    }

    func testAStepDownNeverLetsGo() {
        // While following, the end leaves the view for a frame with each new line: a scroll down then is no release.
        let model = ScrollModel()
        XCTAssertFalse(model.releases(wheel: -3))
        XCTAssertFalse(model.releases(movedFrom: frame(1300), to: frame(1340)))
    }

    func testGrowthIsNotAScroll() {
        var model = ScrollModel()
        XCTAssertFalse(model.releases(movedFrom: frame(1400), to: frame(1380, content: 1980)), "a row above measured shorter")
        XCTAssertFalse(model.releases(movedFrom: frame(1400), to: frame(1600, content: 2200)), "the reply grew")
        model.userScrolled()
        XCTAssertFalse(model.releases(movedFrom: frame(1200), to: frame(1100)), "already free: nothing to write")
    }

    func testAJumpOfTheScrollViewsOwnIsNotYou() {
        // A lazy stack guessed the rows above anew: the end held in one report, the old offset put back in the next.
        let model = ScrollModel()
        let atEnd = frame(5400, content: 6000)
        let putBack = frame(1400, content: 6000)
        XCTAssertTrue(ScrollModel.movedBySelf(from: atEnd, to: putBack))
        XCTAssertFalse(model.releases(movedFrom: atEnd, to: putBack), "following goes on, back to the end")
        // Page Up moves less than a page, an arrow key a line: those are still you.
        XCTAssertFalse(ScrollModel.movedBySelf(from: atEnd, to: frame(4860, content: 6000)))
        XCTAssertTrue(model.releases(movedFrom: atEnd, to: frame(4860, content: 6000)))
        // A move with a size change, or down, is not one of these.
        XCTAssertFalse(ScrollModel.movedBySelf(from: atEnd, to: frame(1400, content: 6100)))
        XCTAssertFalse(ScrollModel.movedBySelf(from: putBack, to: atEnd))
    }

    func testTheEndIsKeptWhenTheScrollViewLeavesItByItself() {
        // Rows moving into the lazy part: the content shrank (the view clamped to its new end), grew back, and the clip
        // view kept the clamped offset, or the content grew under a view that stayed put. Both lose the end.
        let atEnd = frame(5400, content: 6000)
        XCTAssertTrue(ScrollModel.lostEnd(from: frame(7146, content: 7745), to: frame(5400, content: 7745)), "put back by itself")
        XCTAssertTrue(ScrollModel.lostEnd(from: atEnd, to: frame(5400, content: 7600)), "grew under a view that stayed put")
        XCTAssertFalse(ScrollModel.lostEnd(from: atEnd, to: frame(7000, content: 7600)), "grew and the view kept its end")
        XCTAssertFalse(ScrollModel.lostEnd(from: atEnd, to: frame(4860, content: 6000)), "Page Up is you")
        XCTAssertFalse(ScrollModel.lostEnd(from: frame(5000, content: 6000), to: frame(5040, content: 6000)), "a step down")
    }

    func testTheEndIsKeptOnlyWhileFollowingAlsoDuringAScrollOfYours() {
        var model = ScrollModel()
        let atEnd = frame(5400, content: 6000)
        let grown = frame(5400, content: 7600)
        // Whatever the scroll phase, except a scroll of the view's own: you only follow while you head for the end.
        XCTAssertTrue(model.keepsEnd(movedFrom: atEnd, to: grown, animating: false))
        XCTAssertFalse(model.keepsEnd(movedFrom: atEnd, to: grown, animating: true), "a jump to a mark or the pill runs")
        XCTAssertFalse(model.keepsEnd(movedFrom: atEnd, to: frame(5400, content: 6000), animating: false), "nothing changed")
        model.userScrolled()
        XCTAssertFalse(model.keepsEnd(movedFrom: atEnd, to: grown, animating: false), "you scrolled away")
        model.jumpedToEnd()
        model.findStarted()
        XCTAssertFalse(model.keepsEnd(movedFrom: atEnd, to: grown, animating: false), "a find owns the position")
    }

    func testABounceBackToTheEndKeepsFollowing() {
        let model = ScrollModel()
        XCTAssertFalse(model.releases(movedFrom: frame(1420), to: frame(1400)))
    }

    func testTheEndComingIntoViewByItselfDoesNotFollowAgain() {
        // Scrolling up near the end of a long session: the lazy stack measures rows above shorter than it guessed, and
        // the end comes into view for a frame without you scrolling down (measured offscreen on 2026-11-18). Following
        // then pulled the view back to the end on every second step up.
        var model = ScrollModel()
        model.userScrolled()
        model.endInView(true)
        XCTAssertFalse(model.shouldFollowEnd, "a step up within the margin of the end")
        model.endInView(false)
        model.endInView(true)
        XCTAssertFalse(model.shouldFollowEnd, "the end came into view by itself")
        XCTAssertTrue(model.showsToEndPill(atEnd: false))
    }

    func testScrollingDownToTheEndFollowsAgain() {
        var model = ScrollModel()
        model.endInView(false)
        model.userScrolled()
        XCTAssertTrue(model.returns(wheel: -3))
        XCTAssertFalse(model.returns(wheel: 3), "up is no way back")
        XCTAssertFalse(model.returns(wheel: -0.2), "a sideways step")
        model.userScrolledDown()
        XCTAssertFalse(model.shouldFollowEnd, "not at the end yet")
        XCTAssertFalse(model.returns(wheel: -3), "already heading there: nothing to write")
        model.endInView(true)
        XCTAssertTrue(model.shouldFollowEnd)
        XCTAssertFalse(model.returns(wheel: -3), "following: nothing to write")
    }

    func testAStepDownWithTheEndInViewFollowsAtOnce() {
        // You let go within the margin of the end and scroll down again: the end never left the view.
        var model = ScrollModel()
        model.userScrolled()
        model.userScrolledDown()
        XCTAssertTrue(model.shouldFollowEnd)
    }

    func testAStepUpAfterHeadingDownLetsGoAgain() {
        var model = ScrollModel()
        model.endInView(false)
        model.userScrolled()
        model.userScrolledDown()
        XCTAssertTrue(model.releases(wheel: 3), "heading down, then up again")
        model.userScrolled()
        model.endInView(true)
        XCTAssertFalse(model.shouldFollowEnd)
    }

    func testAFindOwnsThePositionAlsoWhenYouScrollDownToTheEnd() {
        var model = ScrollModel()
        model.endInView(false)
        model.findStarted()
        model.userScrolledDown()
        model.endInView(true)
        XCTAssertFalse(model.shouldFollowEnd)
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
        m.endInView(false)
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
        m.endInView(false)
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
        m.endInView(false)
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

    func testTheRowsDrawnInFullAndWhatIsUnderThemAreNeverBlank() {
        typealias Span = RowsInView.Span
        // Seen in the app: at the end, the last row hidden (its step on the live line), and the view on the live line,
        // its task list and the room held under rows that folded. Not blank: the guard scrolled up and back down.
        let rows = [Span(top: 5900, bottom: 6540), Span(top: 6564, bottom: 6564)]
        XCTAssertFalse(RowsInView.blank(rows: 39, drawn: rows, top: 6615, height: 849, drawnFrom: 5200))
        // Reaching only a hairline into the part drawn in full is still blank.
        XCTAssertTrue(RowsInView.blank(rows: 39, drawn: [], top: 4000, height: 600, drawnFrom: 4596))
        // Above the part drawn in full, in the lazy rows, a stretch with none of them drawn is blank as before.
        XCTAssertTrue(RowsInView.blank(rows: 39, drawn: rows, top: 2000, height: 849, drawnFrom: 5200))
        XCTAssertFalse(RowsInView.blank(rows: 39, drawn: [Span(top: 2100, bottom: 2400)], top: 2000, height: 849, drawnFrom: 5200))
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

    // MARK: Held height of the last rows

    func testHeldHeightNeverShrinksWhileHolding() {
        var held = HeldHeight()
        XCTAssertEqual(held.height(natural: 500, width: 600, key: 1, holds: true), 500)
        // A thought folds into "Ran 3 commands": the rows keep their height, with room under them.
        XCTAssertEqual(held.height(natural: 420, width: 600, key: 1, holds: true), 500)
        // The next output fills the room first, then grows past it.
        XCTAssertEqual(held.height(natural: 480, width: 600, key: 1, holds: true), 500)
        XCTAssertEqual(held.height(natural: 560, width: 600, key: 1, holds: true), 560)
        XCTAssertEqual(held.height(natural: 540, width: 600, key: 1, holds: true), 560)
    }

    func testHeldHeightLetsGo() {
        var held = HeldHeight()
        _ = held.height(natural: 500, width: 600, key: 1, holds: true)
        // You stopped following, or the agent is done.
        XCTAssertEqual(held.height(natural: 400, width: 600, key: 1, holds: false), 400)
        XCTAssertEqual(held.height(natural: 380, width: 600, key: 1, holds: true), 380)
        // A new turn, or a block opened or closed.
        XCTAssertEqual(held.height(natural: 300, width: 600, key: 2, holds: true), 300)
    }

    func testHeldHeightIsPerWidth() {
        var held = HeldHeight()
        _ = held.height(natural: 500, width: 600, key: 1, holds: true)
        // A narrower window wraps the rows taller, a wider one shorter: each width keeps its own.
        XCTAssertEqual(held.height(natural: 300, width: 900, key: 1, holds: true), 300)
        XCTAssertEqual(held.height(natural: 450, width: 600, key: 1, holds: true), 500)
    }
}
