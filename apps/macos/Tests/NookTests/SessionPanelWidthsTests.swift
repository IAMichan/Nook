import XCTest

final class SessionPanelWidthsTests: XCTestCase {
    func testEachSessionKeepsItsOwnWidth() {
        var widths = SessionPanelWidths()
        widths.set(800, for: "a")
        XCTAssertEqual(widths.width(for: "a", fallback: 540), 800)
        XCTAssertEqual(widths.width(for: "b", fallback: 540), 540, "resizing one session leaves the others alone")
    }

    func testAContinuedConversationKeepsItsWidth() {
        var widths = SessionPanelWidths()
        widths.set(700, for: "new")
        widths.move(from: "new", to: "run:1")
        XCTAssertEqual(widths.width(for: "run:1", fallback: 540), 700)
        XCTAssertEqual(widths.width(for: "new", fallback: 540), 540)
    }

    func testOldestSessionGoesFirstPastTheLimit() {
        var widths = SessionPanelWidths()
        for index in 0...SessionPanelWidths.limit { widths.set(Double(index), for: "s\(index)") }
        XCTAssertEqual(widths.widths.count, SessionPanelWidths.limit)
        XCTAssertNil(widths.widths["s0"])
        XCTAssertEqual(widths.width(for: "s\(SessionPanelWidths.limit)", fallback: 0), Double(SessionPanelWidths.limit))
    }

    func testRoundTripsThroughDefaults() {
        var widths = SessionPanelWidths()
        widths.set(600, for: "a")
        widths.set(650, for: "b")
        XCTAssertEqual(SessionPanelWidths(encoded: widths.encoded), widths)
        XCTAssertEqual(SessionPanelWidths(encoded: ["junk": 1]), SessionPanelWidths())
    }
}
