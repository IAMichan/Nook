import XCTest

/// Picking several Nooks or sessions at once: ⌘-click, ⇧-click ranges, select all, and rows that leave the list.
final class ListSelectionTests: XCTestCase {
    private let order = ["a", "b", "c", "d", "e"]

    func testPlainClickOpensUntilSelecting() {
        var selection = ListSelection<String>()
        XCTAssertEqual(selection.click(command: false, shift: false), .open)
        XCTAssertEqual(selection.click(command: true, shift: false), .toggle)
        XCTAssertEqual(selection.click(command: false, shift: true), .extend)
        selection.begin()
        XCTAssertEqual(selection.click(command: false, shift: false), .toggle)
    }

    func testToggleAddsAndRemoves() {
        var selection = ListSelection<String>()
        selection.toggle("b")
        selection.toggle("d")
        XCTAssertEqual(selection.ordered(order), ["b", "d"])
        selection.toggle("b")
        XCTAssertEqual(selection.ordered(order), ["d"])
        XCTAssertTrue(selection.isActive)
    }

    func testShiftClickTakesTheRangeFromTheLastToggledRow() {
        var selection = ListSelection<String>()
        selection.toggle("d")
        selection.extend(to: "b", in: order)
        XCTAssertEqual(selection.ordered(order), ["b", "c", "d"])
        // The anchor stays, so a second ⇧-click widens from the same row.
        selection.extend(to: "e", in: order)
        XCTAssertEqual(selection.ordered(order), ["b", "c", "d", "e"])
    }

    func testShiftClickWithoutAnchorPicksOneRow() {
        var selection = ListSelection<String>()
        selection.extend(to: "c", in: order)
        XCTAssertEqual(selection.ordered(order), ["c"])
    }

    func testToggleAllSelectsEverythingThenNothing() {
        var selection = ListSelection<String>()
        selection.toggle("a")
        selection.toggleAll(order)
        XCTAssertEqual(selection.count, 5)
        selection.toggleAll(order)
        XCTAssertTrue(selection.isEmpty)
        XCTAssertTrue(selection.isActive)
    }

    func testRowsThatLeaveTheListDropOut() {
        var selection = ListSelection<String>()
        selection.toggle("a")
        selection.toggle("c")
        selection.keep(only: ["b", "c"])
        XCTAssertEqual(selection.ordered(order), ["c"])
        // "c" was toggled last and is still there: it stays the anchor.
        selection.extend(to: "e", in: order)
        XCTAssertEqual(selection.ordered(order), ["c", "d", "e"])
    }

    func testClearEndsSelecting() {
        var selection = ListSelection<String>()
        selection.toggle("a")
        selection.clear()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertFalse(selection.isActive)
        XCTAssertEqual(selection.click(command: false, shift: false), .open)
    }
}
