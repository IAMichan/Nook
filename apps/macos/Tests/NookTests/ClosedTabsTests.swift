import XCTest

final class ClosedTabsTests: XCTestCase {
    func testTheLastClosedComesBackFirst() {
        var closed = ClosedTabs<String>()
        XCTAssertNil(closed.reopen())
        closed.push("terminal")
        closed.push("browser")
        XCTAssertEqual(closed.reopen(), "browser")
        XCTAssertEqual(closed.reopen(), "terminal")
        XCTAssertNil(closed.reopen())
        XCTAssertTrue(closed.isEmpty)
    }

    func testTabsClosedTogetherComeBackInReverse() {
        var closed = ClosedTabs<Int>()
        closed.push([1, 2, 3])
        XCTAssertEqual(closed.reopen(), 3)
        XCTAssertEqual(closed.reopen(), 2)
    }

    func testATabThatIsOpenAgainIsSkipped() {
        var closed = ClosedTabs<String>()
        closed.push(["a", "b", "c"])
        XCTAssertEqual(closed.reopen(skipping: { $0 == "c" || $0 == "b" }), "a")
        XCTAssertTrue(closed.isEmpty, "the open ones it passed are dropped")
    }

    func testTheStackIsBounded() {
        var closed = ClosedTabs<Int>()
        closed.push(Array(0..<(ClosedTabs<Int>.limit + 5)))
        XCTAssertEqual(closed.entries.count, ClosedTabs<Int>.limit)
        XCTAssertEqual(closed.entries.first, 5)
    }
}
