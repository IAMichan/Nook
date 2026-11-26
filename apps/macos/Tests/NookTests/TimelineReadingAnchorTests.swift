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
        anchor.userStep(deltaY: 40, precise: true)
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

    /// Content above shrinks by more than the view stands from the end: the scroll view clamps to the new end by itself
    /// (measured offscreen on 2026-11-18). The row goes back where you read it, not that far again from the clamp.
    func testAViewClampedToTheEndIsNotMovedTwice() {
        let anchor = reading()
        var queued: [@MainActor () -> Void] = []
        anchor.later = { queued.append($0) }
        for index in 3..<10 { anchor.place("r\(index)", top: Double(index) * 100 - 300) }
        anchor.moved(offset: 160, container: 300, holding: true)
        queued.forEach { $0() }
        XCTAssertEqual(scrolls, [140], "r5 now starts at 200, 60 under the top of the view as before")
    }

    /// The scroll view goes along with the row in a report of its own, after your step: that move is not yours.
    func testTheViewGoingAlongAfterYourStepIsNotYours() {
        let anchor = reading()
        var queued: [@MainActor () -> Void] = []
        anchor.later = { queued.append($0) }
        // Rows above r5 measured 3000 shorter; your step up of 40 is reported first, the view going along next.
        for index in 3..<10 { anchor.place("r\(index)", top: Double(index) * 100 - 3000) }
        anchor.userStep(deltaY: 40, precise: true)
        anchor.moved(offset: 400, container: 300, holding: true)
        anchor.moved(offset: -2560, container: 300, holding: true)
        queued.forEach { $0() }
        // r5 at -2500, 100 under the top of the view: where your step put it.
        XCTAssertEqual(scrolls, [-2600])
    }

    /// Steps that could not move the view (you scrolled down at the end, while following) are not counted later.
    func testStepsTheViewCouldNotFollowAreDropped() {
        let anchor = reading()
        anchor.moved(offset: 700, container: 300, holding: false)
        for _ in 0..<20 { anchor.userStep(deltaY: -200, precise: true) }
        anchor.moved(offset: 700, container: 300, holding: false)
        anchor.moved(offset: 700, container: 300, holding: true)
        XCTAssertEqual(anchor.held, AnyHashable("r7"))
        // Up 60 at the end of a step with leftover steps of the wrong way: only what the view moved counts.
        anchor.userStep(deltaY: -500, precise: true)
        anchor.userStep(deltaY: 560, precise: true)
        anchor.moved(offset: 640, container: 300, holding: true)
        anchor.place("r7", top: 700)
        XCTAssertEqual(scrolls, [])
    }

    /// A report from before the anchor's own scroll, after it: not a move of yours that undoes it.
    func testAReportTheViewMovedOnFromIsIgnored() {
        let anchor = reading()
        var at = 440.0
        anchor.currentOffset = { at }
        anchor.scroll = { [unowned self] in
            at = $0
            scrolls.append($0)
        }
        for index in 3..<10 { anchor.place("r\(index)", top: Double(index) * 100 + 60) }
        XCTAssertEqual(scrolls, [500])
        anchor.moved(offset: 440, container: 300, holding: true)
        anchor.moved(offset: 500, container: 300, holding: true)
        anchor.place("r5", top: 560)
        XCTAssertEqual(scrolls, [500])
    }

    /// A correction waiting while you scroll: it waits for the scroll view to report your step instead of undoing it.
    func testACorrectionWaitsForAStepNotYetReported() {
        let anchor = reading()
        var at = 440.0
        anchor.currentOffset = { at }
        var queued: [@MainActor () -> Void] = []
        anchor.later = { queued.append($0) }
        anchor.place("r5", top: 520)
        // Your wheel step moved the view to 400 before the correction ran; the scroll view reports it after.
        anchor.userStep(deltaY: 40, precise: true)
        at = 400
        queued.forEach { $0() }
        XCTAssertEqual(scrolls, [])
        anchor.moved(offset: 400, container: 300, holding: true)
        queued.dropFirst().forEach { $0() }
        XCTAssertEqual(scrolls.last, 420, "r5 at 520, 100 under the top of the view: 60 as before and your step of 40")
    }

    func testAJumpScrollsAtOnceOnlyWithAScrollView() {
        let anchor = TimelineReadingAnchor()
        anchor.scroll = { [unowned self] in scrolls.append($0) }
        XCTAssertFalse(anchor.jump(to: 900), "no scroll view connected yet")
        XCTAssertEqual(scrolls, [])
        anchor.currentOffset = { 400 }
        XCTAssertTrue(anchor.jump(to: 900))
        XCTAssertEqual(scrolls, [900])
    }

    /// A long answer of 2000 points read 800 points in, in a 300-point view at a width of 600.
    private func readingALongAnswer(clock: @escaping () -> Date) -> TimelineReadingAnchor {
        let anchor = TimelineReadingAnchor()
        anchor.scroll = { [unowned self] in scrolls.append($0) }
        anchor.later = { $0() }
        anchor.now = clock
        anchor.width(600)
        anchor.place("answer", top: 0, height: 2000)
        anchor.place("next", top: 2000, height: 100)
        anchor.moved(offset: 800, container: 300, holding: true)
        return anchor
    }

    func testTheLineYouReadInALongAnswerStaysInViewWhenItWrapsAnew() {
        let now = Date()
        let anchor = readingALongAnswer(clock: { now })
        XCTAssertEqual(anchor.held, AnyHashable("answer"))
        // The side panel takes room: the answer wraps to half again as many lines.
        anchor.width(400)
        anchor.place("answer", top: 0, height: 3000)
        // As far into the answer as before, in parts of it: the text you read was 800 of 2000 points in.
        XCTAssertEqual(scrolls, [1200])
    }

    func testALongAnswerThatGrowsAtTheSameWidthMovesNothing() {
        let anchor = readingALongAnswer(clock: { Date() })
        // The agent writes on into it while you read its start.
        anchor.place("answer", top: 0, height: 2400)
        XCTAssertEqual(scrolls, [])
    }

    func testALongAnswerThatGrowsWellAfterAResizeMovesNothing() {
        var now = Date()
        let anchor = readingALongAnswer(clock: { now })
        anchor.width(400)
        anchor.place("answer", top: 0, height: 3000)
        anchor.moved(offset: 1200, container: 300, holding: true)
        scrolls = []
        now += 5
        anchor.place("answer", top: 0, height: 3400)
        XCTAssertEqual(scrolls, [])
    }
}
