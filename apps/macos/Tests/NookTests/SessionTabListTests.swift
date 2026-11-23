import XCTest

final class SessionTabListTests: XCTestCase {
    func testOpeningAddsATabOnceAtTheEnd() {
        var tabs = SessionTabList()
        tabs.open("run:a")
        tabs.open("past:b")
        tabs.open("run:a")
        tabs.open("")
        XCTAssertEqual(tabs.ids, ["run:a", "past:b"])
    }

    func testPastTheLimitTheTabLookedAtLongestAgoGoes() {
        var tabs = SessionTabList()
        for index in 0..<SessionTabList.limit { tabs.open("s\(index)") }
        // Looking at the first one again keeps it; the second is now the oldest.
        tabs.open("s0")
        tabs.open("new")
        XCTAssertEqual(tabs.ids.count, SessionTabList.limit)
        XCTAssertTrue(tabs.ids.contains("s0"))
        XCTAssertFalse(tabs.ids.contains("s1"))
        XCTAssertEqual(tabs.ids.last, "new")
    }

    func testClosingTheOpenTabOpensItsRightNeighbourElseItsLeft() {
        var tabs = SessionTabList(ids: ["a", "b", "c"])
        XCTAssertEqual(tabs.close("b", active: "b"), "c")
        XCTAssertEqual(tabs.close("c", active: "c"), "a")
        XCTAssertNil(tabs.close("a", active: "a"))
        XCTAssertTrue(tabs.ids.isEmpty)
    }

    func testClosingAnotherTabKeepsTheOpenOne() {
        var tabs = SessionTabList(ids: ["a", "b", "c"])
        XCTAssertNil(tabs.close("a", active: "b"))
        XCTAssertEqual(tabs.ids, ["b", "c"])
    }

    func testCloseOthersAndToTheRight() {
        var tabs = SessionTabList(ids: ["a", "b", "c", "d"])
        tabs.closeRight(of: "b")
        XCTAssertEqual(tabs.ids, ["a", "b"])
        tabs.closeOthers(than: "b")
        XCTAssertEqual(tabs.ids, ["b"])
    }

    func testATakenOverSessionKeepsItsPlace() {
        var tabs = SessionTabList(ids: ["a", "past:x", "c"])
        tabs.replace("past:x", with: "run:y")
        XCTAssertEqual(tabs.ids, ["a", "run:y", "c"])
        // Already open under its new id: the old tab goes.
        tabs = SessionTabList(ids: ["past:x", "run:y"])
        tabs.replace("past:x", with: "run:y")
        XCTAssertEqual(tabs.ids, ["run:y"])
    }

    func testMoveAndRoundTrip() throws {
        var tabs = SessionTabList(ids: ["a", "b", "c"])
        tabs.move("c", onto: "a")
        XCTAssertEqual(tabs.ids, ["c", "a", "b"])
        let decoded = try JSONDecoder().decode(SessionTabList.self, from: JSONEncoder().encode(tabs))
        XCTAssertEqual(decoded, tabs)
    }
}
