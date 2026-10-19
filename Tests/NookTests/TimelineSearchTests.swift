import XCTest

final class TimelineSearchTests: XCTestCase {
    private func ev(_ kind: RunEvent.Kind, _ text: String, detail: String? = nil, output: String? = nil) -> RunEvent {
        RunEvent(kind: kind, text: text, detail: detail, output: output)
    }

    func testEmptyQueryAndEmptyTimeline() {
        XCTAssertEqual(TimelineSearch.search([ev(.user, "a")], query: "").state, .idle)
        XCTAssertEqual(TimelineSearch.search([ev(.user, "a")], query: "  ").state, .idle)
        XCTAssertEqual(TimelineSearch.search([], query: "a").state, .noResults)
    }

    func testCaseAndDiacriticInsensitive() {
        let r = TimelineSearch.search([ev(.assistant, "Café CAFE cafe")], query: "cafe")
        XCTAssertEqual(r.matches.map(\.range), [0..<4, 5..<9, 10..<14])
        XCTAssertEqual(r.state, .results)
    }

    func testFieldsAndOffsets() {
        let e = ev(.tool, "run", detail: "x foo", output: "foo foo")
        let r = TimelineSearch.search([e], query: "foo")
        XCTAssertEqual(r.matches.map(\.field), [.detail, .output, .output])
        XCTAssertEqual(r.matches[0].range, 2..<5)
    }

    func testThinkingIgnoredUnlessIncluded() {
        let e = [ev(.thinking, "hmm foo")]
        XCTAssertEqual(TimelineSearch.search(e, query: "foo").state, .noResults)
        XCTAssertEqual(TimelineSearch.search(e, query: "foo", includeThinking: true).matches.count, 1)
    }

    func testRegexCharactersAreLiteral() {
        let r = TimelineSearch.search([ev(.assistant, "a.b a+b (x) [y] a*")], query: ".")
        XCTAssertEqual(r.matches.count, 1)
        XCTAssertEqual(TimelineSearch.search([ev(.assistant, "(x) [y]")], query: "(x)").matches.count, 1)
        XCTAssertEqual(TimelineSearch.search([ev(.assistant, "aab")], query: ".*").state, .noResults)
    }

    func testUnicodeUTF16Offsets() {
        let r = TimelineSearch.search([ev(.assistant, "😀 hi 😀 hi")], query: "hi")
        XCTAssertEqual(r.matches.map(\.range), [3..<5, 8..<10])
    }

    func testTooLongQueryFails() {
        XCTAssertEqual(TimelineSearch.search([], query: String(repeating: "a", count: 501)).state, .failed)
    }

    func testNavigationWrapsBothWays() {
        let r = TimelineSearch.search([ev(.assistant, "a a a")], query: "a")
        XCTAssertEqual(r.next(after: nil), 0)
        XCTAssertEqual(r.next(after: 1), 2)
        XCTAssertEqual(r.next(after: 2), 0)
        XCTAssertNil(r.next(after: 2, wrap: false))
        XCTAssertEqual(r.previous(before: nil), 2)
        XCTAssertEqual(r.previous(before: 0), 2)
        XCTAssertNil(r.previous(before: 0, wrap: false))
        XCTAssertEqual(r.previous(before: 2), 1)
        XCTAssertNil(TimelineSearchResult.idle.next(after: nil))
    }

    func testCountLabel() {
        let r = TimelineSearch.search([ev(.assistant, "a a a")], query: "a")
        XCTAssertEqual(r.countLabel(current: 0), "1/3")
        XCTAssertEqual(r.countLabel(current: 2), "3/3")
        XCTAssertEqual(r.countLabel(current: nil), "0/3")
        XCTAssertEqual(TimelineSearchResult.idle.countLabel(current: nil), "0/0")
    }

    func testRevealTargets() {
        let a = ev(.tool, "foo"), b = ev(.tool, "foo"), c = ev(.tool, "foo")
        let group = UUID()
        let r = TimelineSearch.search([a, b, c], query: "foo")
        XCTAssertEqual(r.revealTargets(containers: [a.id: group, b.id: group]), [group])
        XCTAssertEqual(r.revealTargets(containers: [:]), [])
    }

    func testFastOnFiveThousandEvents() {
        let events = (0..<5000).map { ev(.assistant, "message number \($0) with some filler text", output: "output \($0) needle") }
        let start = Date()
        let r = TimelineSearch.search(events, query: "needle")
        XCTAssertEqual(r.matches.count, 5000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
