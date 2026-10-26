import XCTest

final class TimelineVisitsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    private var rows: [TimelineLanding.Row] {
        [("a", at(0)), ("step", nil), ("b", at(10)), ("c", at(20)), ("d", at(30))]
    }

    func testANeverSeenConversationOpensAtTheEnd() {
        XCTAssertEqual(TimelineLanding.decide(rows, visit: nil), .end)
    }

    func testLeftAtTheEndComesBackToWhatIsNew() {
        let visit = TimelineVisit(anchorID: "a", open: [], atEnd: true, lastViewedAt: at(15))
        XCTAssertEqual(TimelineLanding.decide(rows, visit: visit), .newSince("c"))
        let nothingNew = TimelineVisit(anchorID: "a", open: [], atEnd: true, lastViewedAt: at(40))
        XCTAssertEqual(TimelineLanding.decide(rows, visit: nothingNew), .end)
    }

    func testLeftHigherUpComesBackToThatRow() {
        let visit = TimelineVisit(anchorID: "b", open: ["fold:x"], atEnd: false, lastViewedAt: at(15))
        XCTAssertEqual(TimelineLanding.decide(rows, visit: visit), .row("b"))
        let gone = TimelineVisit(anchorID: "zz", open: [], atEnd: false, lastViewedAt: at(15))
        XCTAssertEqual(TimelineLanding.decide(rows, visit: gone), .end, "a row that is gone falls back to the end")
    }

    func testTheNewLineNeedsSomethingOlderAboveIt() {
        XCTAssertNil(TimelineLanding.firstNew(rows, since: at(-5)), "everything is new: no line at the top")
        XCTAssertEqual(TimelineLanding.firstNew(rows, since: at(0)), "b", "a row without a time is skipped")
        XCTAssertNil(TimelineLanding.firstNew(rows, since: at(30)))
    }

    func testTopIsTheFirstVisibleRowInOrder() {
        XCTAssertEqual(TimelineLanding.top(rows, visible: ["d", "b", "c"]), "b")
        XCTAssertNil(TimelineLanding.top(rows, visible: []))
    }

    func testVisitsAreBoundedByLastViewed() {
        var visits = TimelineVisits()
        for index in 0..<(TimelineVisits.limit + 5) {
            visits.remember(sessionID: "s\(index)", visit: TimelineVisit(anchorID: nil, open: [], atEnd: true, lastViewedAt: at(Double(index))))
        }
        XCTAssertEqual(visits.visits.count, TimelineVisits.limit)
        XCTAssertNil(visits.visit(for: "s0"))
        XCTAssertNotNil(visits.visit(for: "s\(TimelineVisits.limit + 4)"))
        visits.forget(sessionID: "s10")
        XCTAssertNil(visits.visit(for: "s10"))
    }

    func testDecodingIsTolerant() throws {
        var visits = TimelineVisits()
        visits.remember(sessionID: "run:1", visit: TimelineVisit(anchorID: "x", open: ["fold:a"], atEnd: false, lastViewedAt: at(5)))
        let back = try JSONDecoder().decode(TimelineVisits.self, from: JSONEncoder().encode(visits))
        XCTAssertEqual(back, visits)
        XCTAssertEqual(try JSONDecoder().decode(TimelineVisits.self, from: Data("{}".utf8)).visits.count, 0)
        let partial = try JSONDecoder().decode(TimelineVisit.self, from: Data("{}".utf8))
        XCTAssertTrue(partial.atEnd)
        XCTAssertNil(partial.anchorID)
    }

    func testRowDates() {
        let message = AgentChatMessage(id: "m", kind: .assistant, text: "hi", date: at(3))
        let fold = TranscriptRow.fold(id: "f", seconds: 2, rows: [.working(since: nil), .thinking(message)])
        XCTAssertEqual(fold.visitDate, at(3))
        XCTAssertNil(TranscriptRow.live(nil).visitDate)
        XCTAssertEqual(TranscriptRow.user(message).visitDate, at(3))
    }
}
