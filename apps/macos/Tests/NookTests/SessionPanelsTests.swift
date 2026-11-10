import XCTest

final class SessionPanelsTests: XCTestCase {
    func testSidePanelReopensOnTheTabItShowed() {
        XCTAssertEqual(PanelReopening.tab(hidden: "browser", tabs: ["terminal", "browser"]), "browser")
    }

    func testSidePanelReopensOnItsFirstTabWhenThatTabIsGone() {
        XCTAssertEqual(PanelReopening.tab(hidden: "browser", tabs: ["terminal", "changes"]), "terminal")
        XCTAssertEqual(PanelReopening.tab(hidden: nil, tabs: ["outputs"]), "outputs")
    }

    func testSidePanelWithoutTabsHasNothingToReopen() {
        XCTAssertNil(PanelReopening.tab(hidden: "browser", tabs: [String]()))
    }

    func testChatColumnIsCenteredInTheRoomBesideThePanels() {
        XCTAssertEqual(PanelSplit.columnStart(column: 736, room: 1000), 132)
        // A panel that opens takes room from the right: the column moves to the middle of what is left.
        XCTAssertEqual(PanelSplit.columnStart(column: 736, room: 1600 - 308), 278)
    }

    func testChatColumnThatFillsItsRoomStartsAtItsEdge() {
        XCTAssertEqual(PanelSplit.columnStart(column: 644, room: 644), 0)
        XCTAssertEqual(PanelSplit.columnStart(column: 736, room: 600), 0)
    }

    func testContextRingStaysQuietUntilHalfUsed() {
        XCTAssertFalse(ContextMeter.worthShowing(0.49))
        XCTAssertTrue(ContextMeter.worthShowing(0.5))
    }

    func testSessionPanelShortcutLeavesTheTerminalAlone() {
        let rule = Keybindings.defaults.first { $0.command == "sessionPanel.toggle" }
        XCTAssertEqual(rule?.key, "mod+shift+b")
        XCTAssertEqual(rule?.when, "!terminalFocus")
        XCTAssertTrue(Keybindings.commandIDs.contains("sessionPanel.toggle"))
    }
}
