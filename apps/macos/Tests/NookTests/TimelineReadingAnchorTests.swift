import XCTest

/// The row you read in an agent's conversation stays where it is on screen while what is above it changes height
/// (`TimelineReadingAnchor`).
@MainActor
final class TimelineReadingAnchorTests: XCTestCase {
    private var scrolls: [Double] = []

    /// Ten rows of 100 points in a 300-point view, scrolled back to 440: row 5 is the first that starts in view.
    private func reading() -> TimelineReadingAnchor {
        let anchor = TimelineReadingAnchor()
        anchor.scroll = { [unowned self] in scrolls.append($0) }
        anchor.later = { $0() }
        for index in 0..<10 { anchor.place("r\(index)", top: Double(index) * 100) }
        anchor.moved(offset: 440, container: 300, holding: true)
        return anchor
    }

    func testHoldsTheFirstRowThatStartsInView() {
        XCTAssertEqual(reading().held, AnyHashable("r5"))
    }

    func testARowAboveThatGrowsScrollsByAsMuch() {
        let anchor = reading()
        // The lazy stack measures row 2 (it had guessed): 60 taller, everything under it moves down.
        for index in 3..<10 { anchor.place("r\(index)", top: Double(index) * 100 + 60) }
        XCTAssertEqual(scrolls, [500])
        // The scroll asked for comes back as a move: nothing more happens.
        anchor.moved(offset: 500, container: 300, holding: true)
        XCTAssertEqual(scrolls, [500])
        XCTAssertEqual(anchor.held, AnyHashable("r5"))
    }

    func testARowBelowThatGrowsMovesNothing() {
        let anchor = reading()
        anchor.place("r9", top: 1200)
        anchor.place("r8", top: 1000)
        XCTAssertEqual(scrolls, [])
    }

    func testYourStepCountsAlsoWhenARowIsMeasuredInIt() {
        let anchor = reading()
        // Scrolling up 30 points brings row 3 into view and measures row 1 (20 shorter) in the same step.
        anchor.moved(offset: 410, container: 300, holding: true)
        for index in 2..<10 { anchor.place("r\(index)", top: Double(index) * 100 - 20) }
        // The view moves up with the content, from where you scrolled to, not back to where it was.
        XCTAssertEqual(scrolls, [390])
    }

    func testFollowingTheEndHoldsNothing() {
        let anchor = reading()
        anchor.moved(offset: 700, container: 300, holding: false)
        for index in 3..<10 { anchor.place("r\(index)", top: Double(index) * 100 + 60) }
        XCTAssertNil(anchor.held)
        XCTAssertEqual(scrolls, [])
    }

    func testAFoldingTurnKeepsTheFoldInPlace() {
        let anchor = reading()
        anchor.moved(offset: 520, container: 300, holding: true)
        XCTAssertEqual(anchor.held, AnyHashable("r6"))
        // The turn ends: its steps from row 4 on fold under row 4, which becomes "Worked for …", 40 high.
        for index in 5..<10 { anchor.place("r\(index)", top: nil) }
        XCTAssertEqual(anchor.held, AnyHashable("r4"))
        // The fold itself does not move: nothing scrolls.
        anchor.place("r4", top: 400)
        XCTAssertEqual(scrolls, [])
    }

    func testScrollingOnHoldsTheNextRowInView() {
        let anchor = reading()
        anchor.moved(offset: 820, container: 300, holding: true)
        XCTAssertEqual(anchor.held, AnyHashable("r9"))
    }

    func testEarlierTurnsDrawnAboveKeepTheRowInPlace() {
        let anchor = reading()
        // "Show earlier messages" puts 200 points of turns above the stack of rows.
        anchor.stack(at: 200)
        XCTAssertEqual(scrolls, [640])
    }

    func testInsideOneTallRowThatRowIsHeld() {
        let anchor = TimelineReadingAnchor()
        anchor.scroll = { [unowned self] in scrolls.append($0) }
        anchor.later = { $0() }
        anchor.place("a", top: 0)
        anchor.place("long", top: 100)
        anchor.place("b", top: 3000)
        anchor.moved(offset: 1200, container: 300, holding: true)
        XCTAssertEqual(anchor.held, AnyHashable("long"))
        anchor.place("long", top: 140)
        XCTAssertEqual(scrolls, [1240])
    }

    /// In one pass of layout the rows report before the scroll view: a step of yours in that pass still counts.
    func testAStepReportedAfterTheRowsIsKept() {
        let anchor = reading()
        var queued: [@MainActor () -> Void] = []
        anchor.later = { queued.append($0) }
        for index in 3..<10 { anchor.place("r\(index)", top: Double(index) * 100 + 60) }
        XCTAssertEqual(scrolls, [])
        // Then the scroll view: you scrolled up 40 in that same pass. Once the pass is done, the view moves along.
        anchor.moved(offset: 400, container: 300, holding: true)
        XCTAssertEqual(scrolls, [])
        queued.forEach { $0() }
        XCTAssertEqual(scrolls, [460])
    }

    /// The scroll view now and then moves along with a row above the view by itself: not a second time.
    func testAViewThatMovedAlongItselfIsLeftAlone() {
        let anchor = reading()
        var queued: [@MainActor () -> Void] = []
        anchor.later = { queued.append($0) }
        for index in 3..<10 { anchor.place("r\(index)", top: Double(index) * 100 - 82) }
        anchor.moved(offset: 358, container: 300, holding: true)
        queued.forEach { $0() }
        XCTAssertEqual(scrolls, [])
    }

    func testAToolbarAboveIsLeftOutOfWhatIsInView() {
        let anchor = TimelineReadingAnchor()
        anchor.later = { $0() }
        for index in 0..<10 { anchor.place("r\(index)", top: Double(index) * 100) }
        // Offset 440 under a 50-point toolbar: the view shows the content from 490 on.
        anchor.moved(offset: 440, container: 300, insetTop: 50, holding: true)
        XCTAssertEqual(anchor.held, AnyHashable("r5"))
    }
}
