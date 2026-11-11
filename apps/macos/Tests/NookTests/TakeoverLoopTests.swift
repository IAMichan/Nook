import XCTest

/// Taking over a task: staying on track (repeats, steps that changed nothing, the fresh read after acting), the menu bar,
/// and the ways around the point of no return that are closed.
@MainActor
final class TakeoverLoopTests: XCTestCase {
    private func controlInput(_ steps: [[String: Any]]) -> [String: Any] {
        ["app": "Safari", "steps": steps]
    }

    func testTheSameStepsAThirdTimeAreRefused() {
        XCTAssertFalse(TakeoverPolicy.isRepeat("a", after: []))
        XCTAssertFalse(TakeoverPolicy.isRepeat("a", after: ["a"]))
        XCTAssertFalse(TakeoverPolicy.isRepeat("a", after: ["a", "b"]))
        XCTAssertTrue(TakeoverPolicy.isRepeat("a", after: ["b", "a", "a"]))
    }

    func testTheResultCarriesTheWindowAsItIsNow() {
        let result = TakeoverPolicy.afterAction("Done: click “Next”.", window: "button \"Pay\"", unchanged: false)
        XCTAssertTrue(result.hasPrefix("Done: click “Next”."))
        XCTAssertTrue(result.contains("button \"Pay\""))
        XCTAssertFalse(result.contains("Note:"))
        XCTAssertTrue(TakeoverPolicy.afterAction("Done.", window: "same", unchanged: true).contains("Note:"))
        XCTAssertEqual(TakeoverPolicy.afterAction("Done.", window: "  ", unchanged: false), "Done.")
        let long = TakeoverPolicy.afterAction("Done.", window: String(repeating: "x", count: 20_000), unchanged: false)
        XCTAssertLessThan(long.count, TakeoverPolicy.afterReadLimit + 400)
    }

    func testAMenuCommandRunsUnlessItIsRisky() {
        XCTAssertNil(TakeoverPolicy.checkpoint(tool: "app_menu_command", input: ["app": "Finder", "path": ["File", "New Folder"]],
                                               summary: "new folder"))
        XCTAssertNotNil(TakeoverPolicy.checkpoint(tool: "app_menu_command", input: ["app": "Finder", "path": ["File", "Move to Trash"]],
                                                  summary: "trash"))
        XCTAssertNotNil(TakeoverPolicy.checkpoint(tool: "app_menu_command", input: ["app": "Mail", "path": []], summary: "nothing named"))
    }

    func testALineBreakTypedInAFieldSendsAndWaits() {
        let message = controlInput([["action": "type", "element": "Message", "text": "See you at 8\n"]])
        XCTAssertNotNil(TakeoverPolicy.checkpoint(tool: "control_ui", input: message, summary: "send"))
        let search = controlInput([["action": "type", "element": "Search", "role": "search", "text": "coffee filters\n"]])
        XCTAssertNil(TakeoverPolicy.checkpoint(tool: "control_ui", input: search, summary: "search"))
    }

    func testSpaceOnAFocusedOrderButtonWaits() {
        let space = controlInput([["action": "key", "keys": "space"]])
        XCTAssertNotNil(TakeoverPolicy.checkpoint(tool: "control_ui", input: space, summary: "order",
                                                  focusedLabel: { "Place order" }))
        XCTAssertNil(TakeoverPolicy.checkpoint(tool: "control_ui", input: space, summary: "scroll", focusedLabel: { nil }))
    }

    func testABigPictureIsScaledAndSaysSo() {
        XCTAssertEqual(UIControl.pictureScale(width: 1_000, height: 800, maxSide: 1_400), 1)
        XCTAssertEqual(UIControl.pictureScale(width: 2_800, height: 1_600, maxSide: 1_400), 0.5, accuracy: 0.0001)
        XCTAssertTrue(UIControl.pictureMapping(originX: 10, originY: 20, scale: 1).contains("(10 + px, 20 + py)"))
        XCTAssertTrue(UIControl.pictureMapping(originX: 10, originY: 20, scale: 0.5).contains("px × 2.000"))
    }
}
