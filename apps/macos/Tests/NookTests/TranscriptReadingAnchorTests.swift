import XCTest

/// The message you read stays where it is on screen while what is above it changes height (`TranscriptReadingAnchor`).
@MainActor
final class TranscriptReadingAnchorTests: XCTestCase {
    /// Ten messages of 100 points under a 40-point button, a 300-point view scrolled to 440: message 4 starts at its top.
    private func reading() -> TranscriptReadingAnchor {
        let anchor = TranscriptReadingAnchor()
        anchor.stack(at: 40, holding: true)
        for index in 0..<10 {
            anchor.place("m\(index)", at: CGRect(x: 0, y: CGFloat(index) * 100, width: 200, height: 100), holding: true)
        }
        anchor.moved(from: 0, to: 0, container: 300, sizesSame: true, holding: true)
        anchor.moved(from: 0, to: 440, container: 300, sizesSame: true, holding: true)
        return anchor
    }

    func testHoldsTheFirstMessageInView() {
        let anchor = reading()
        XCTAssertEqual(anchor.held, "m4")
        XCTAssertEqual(anchor.inView, 0)
    }

    func testAMessageAboveThatGrowsScrollsTheChatByAsMuch() {
        var scrolls: [CGFloat] = []
        let anchor = reading()
        anchor.scroll = { scrolls.append($0) }
        // A link's card above the view loads and grows by 160: everything under it moves down.
        anchor.place("m1", at: CGRect(x: 0, y: 100, width: 200, height: 260), holding: true)
        for index in 2..<10 {
            anchor.place("m\(index)", at: CGRect(x: 0, y: CGFloat(index) * 100 + 160, width: 200, height: 100), holding: true)
        }
        XCTAssertEqual(scrolls, [600])
        // The scroll that was asked for is not you: the message keeps its place.
        anchor.moved(from: 440, to: 600, container: 300, sizesSame: true, holding: true)
        XCTAssertEqual(anchor.held, "m4")
        XCTAssertEqual(anchor.inView, 0)
    }

    func testAMessageBelowThatGrowsMovesNothing() {
        var scrolls: [CGFloat] = []
        let anchor = reading()
        anchor.scroll = { scrolls.append($0) }
        anchor.place("m8", at: CGRect(x: 0, y: 800, width: 200, height: 400), holding: true)
        anchor.moved(from: 440, to: 440, container: 300, sizesSame: false, holding: true)
        XCTAssertEqual(scrolls, [])
    }

    func testYourOwnScrollMovesTheHeldPlaceAlong() {
        var scrolls: [CGFloat] = []
        let anchor = reading()
        anchor.scroll = { scrolls.append($0) }
        anchor.moved(from: 440, to: 400, container: 300, sizesSame: true, holding: true)
        XCTAssertEqual(anchor.inView, 40)
        // Then a picture above loads: the message stays 40 below the top.
        for index in 0..<10 {
            anchor.place("m\(index)", at: CGRect(x: 0, y: CGFloat(index) * 100 + 50, width: 200, height: 100), holding: true)
        }
        XCTAssertEqual(scrolls, [450])
    }

    func testTheButtonAboveGoingAwayIsKeptToo() {
        var scrolls: [CGFloat] = []
        let anchor = reading()
        anchor.scroll = { scrolls.append($0) }
        anchor.stack(at: 0, holding: true)
        XCTAssertEqual(scrolls, [400])
    }

    func testNothingIsHeldAtTheNewestMessageAndHoldingStartsFresh() {
        var scrolls: [CGFloat] = []
        let anchor = reading()
        anchor.scroll = { scrolls.append($0) }
        // At the newest message the chat follows its end: sizes change, nothing is kept.
        anchor.moved(from: 440, to: 740, container: 300, sizesSame: true, holding: false)
        anchor.place("m1", at: CGRect(x: 0, y: 100, width: 200, height: 300), holding: false)
        XCTAssertEqual(scrolls, [])
        // Scrolled back up from there: what is in view then is held, not the place from before.
        anchor.moved(from: 740, to: 700, container: 300, sizesSame: true, holding: true)
        XCTAssertEqual(scrolls, [])
        XCTAssertEqual(anchor.held, "m7")
    }
}
