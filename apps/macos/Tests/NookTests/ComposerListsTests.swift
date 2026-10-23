import XCTest

final class ComposerListsTests: XCTestCase {
    func testBulletsAndTasksContinue() {
        XCTAssertEqual(ComposerLists.continued(old: "Todo:\n- milk", new: "Todo:\n- milk\n"), "Todo:\n- milk\n- ")
        XCTAssertEqual(ComposerLists.continued(old: "  * nested", new: "  * nested\n"), "  * nested\n  * ")
        XCTAssertEqual(ComposerLists.continued(old: "- [x] done", new: "- [x] done\n"), "- [x] done\n- [ ] ")
    }

    func testNumbersCountOnAndKeepTheirPadding() {
        XCTAssertEqual(ComposerLists.continued(old: "1. one", new: "1. one\n"), "1. one\n2. ")
        XCTAssertEqual(ComposerLists.continued(old: "9) nine", new: "9) nine\n"), "9) nine\n10) ")
        XCTAssertEqual(ComposerLists.continued(old: "07. seven", new: "07. seven\n"), "07. seven\n08. ")
    }

    func testAnEmptyItemEndsTheList() {
        XCTAssertEqual(ComposerLists.continued(old: "- milk\n- ", new: "- milk\n- \n"), "- milk\n")
        XCTAssertEqual(ComposerLists.continued(old: "1. a\n2. ", new: "1. a\n2. \n"), "1. a\n")
    }

    func testOtherEditsAreLeftAlone() {
        XCTAssertNil(ComposerLists.continued(old: "plain text", new: "plain text\n"))
        XCTAssertNil(ComposerLists.continued(old: "- milk", new: "- milk and"))
        XCTAssertNil(ComposerLists.continued(old: "- a\n- b", new: "- a\n\n- b"))
        XCTAssertNil(ComposerLists.continued(old: "-not a list", new: "-not a list\n"))
        XCTAssertNil(ComposerLists.continued(old: "2024.", new: "2024.\n"))
    }
}
