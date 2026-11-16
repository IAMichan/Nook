import XCTest

final class TooltipTextTests: XCTestCase {
    func testShortTextIsUnchanged() {
        XCTAssertEqual(TooltipText.clamped("Open diff"), "Open diff")
        XCTAssertEqual(TooltipText.clamped("Line one\nLine two"), "Line one\nLine two")
    }

    func testLongCommandKeepsItsFirstLines() {
        let command = (1...40).map { "    line \($0)   with  spaces" }.joined(separator: "\n\n")
        let tip = TooltipText.clamped(command)
        XCTAssertEqual(tip.split(separator: "\n").count, TooltipText.maxLines)
        XCTAssertTrue(tip.hasPrefix("line 1 with spaces\nline 2 with spaces"))
        XCTAssertTrue(tip.hasSuffix("…"))
    }

    func testOneLongLineIsCut() {
        let tip = TooltipText.clamped(String(repeating: "abc ", count: 200))
        XCTAssertLessThanOrEqual(tip.count, TooltipText.maxCharacters + 1)
        XCTAssertTrue(tip.hasSuffix("…"))
    }
}
