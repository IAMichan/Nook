import XCTest

final class HistoryWindowTests: XCTestCase {
    /// `turns` user turns, each followed by `perTurn` tool events.
    private func timeline(turns: Int, perTurn: Int, text: String = "x") -> [RunEvent] {
        (0..<turns).flatMap { t in
            [RunEvent(kind: .user, text: "u\(t)")] + (0..<perTurn).map { _ in RunEvent(kind: .tool, text: text) }
        }
    }

    func testEmptyAndSmallCoverEverything() {
        XCTAssertEqual(HistoryWindow.initial(events: []), .init(startIndex: 0, hasMore: false))
        let e = timeline(turns: 3, perTurn: 2)
        XCTAssertEqual(HistoryWindow.initial(events: e), .init(startIndex: 0, hasMore: false))
        XCTAssertEqual(HistoryWindow.initial(events: e).loadedRange(count: e.count), 0..<9)
    }

    func testLastTenUserTurns() {
        let e = timeline(turns: 25, perTurn: 1)
        let w = HistoryWindow.initial(events: e)
        XCTAssertEqual(w.startIndex, 15 * 2)
        XCTAssertTrue(w.hasMore)
        XCTAssertEqual(e[w.startIndex].kind, .user)
    }

    func testItemCapMovesToUserBoundary() {
        let e = timeline(turns: 10, perTurn: 19) // 200 events, 20 per turn
        let w = HistoryWindow.initial(events: e, maxUserTurns: 10, maxItems: 75)
        XCTAssertEqual(e[w.startIndex].kind, .user)
        XCTAssertLessThanOrEqual(e.count - w.startIndex, 75)
        XCTAssertEqual(w.startIndex, 140)
    }

    func testHugeSingleTurnHardCap() {
        var e = [RunEvent(kind: .user, text: "go")]
        e += (0..<500).map { _ in RunEvent(kind: .tool, text: "t") }
        let w = HistoryWindow.initial(events: e)
        XCTAssertEqual(w.startIndex, 501 - 75)
        XCTAssertTrue(w.hasMore)
    }

    func testByteCapShrinksAtBoundary() {
        let e = timeline(turns: 10, perTurn: 1, text: String(repeating: "a", count: 1000))
        let w = HistoryWindow.initial(events: e, maxBytes: 5_000)
        XCTAssertEqual(e[w.startIndex].kind, .user)
        XCTAssertLessThanOrEqual(HistoryWindow.bytesEstimate(e, in: w), 5_000 + 1100)
        XCTAssertGreaterThan(w.startIndex, 0)
    }

    func testEarlierLoadsTwentyMoreTurns() {
        let e = timeline(turns: 60, perTurn: 1)
        let first = HistoryWindow.initial(events: e)
        let second = HistoryWindow.earlier(events: e, from: first.startIndex)
        XCTAssertEqual(second.startIndex, first.startIndex - 40)
        XCTAssertEqual(e[second.startIndex].kind, .user)
        XCTAssertTrue(second.hasMore)
        let third = HistoryWindow.earlier(events: e, from: second.startIndex)
        XCTAssertEqual(third, .init(startIndex: 20, hasMore: true))
        XCTAssertEqual(HistoryWindow.earlier(events: e, from: third.startIndex), .init(startIndex: 0, hasMore: false))
        XCTAssertEqual(HistoryWindow.earlier(events: e, from: 0), .init(startIndex: 0, hasMore: false))
        XCTAssertEqual(HistoryWindow.earlier(events: [], from: 5).startIndex, 0)
    }

    func testBytesEstimate() {
        let e = [RunEvent(kind: .user, text: "abc", detail: "de", output: "f")]
        XCTAssertEqual(HistoryWindow.bytesEstimate(e, in: .init(startIndex: 0, hasMore: false)), 64 + 6)
        XCTAssertEqual(HistoryWindow.bytesEstimate(e, in: .init(startIndex: 1, hasMore: true)), 0)
        XCTAssertEqual(HistoryWindow.bytesEstimate([], in: .init(startIndex: 0, hasMore: false)), 0)
    }
}
