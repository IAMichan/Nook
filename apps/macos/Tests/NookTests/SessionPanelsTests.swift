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

    func testChatColumnKeepsItsPlaceWhenAPanelOpens() {
        let closed = PanelSplit.columnStart(column: 736, room: 1600, row: 1600)
        let open = PanelSplit.columnStart(column: 736, room: 1600 - 308, row: 1600)
        XCTAssertEqual(closed, 432)
        XCTAssertEqual(open, closed)
    }

    func testChatColumnMovesOnlyAsFarAsAPanelPushesIt() {
        // Centered in the row it would end at 960, with the panel starting at 884.
        XCTAssertEqual(PanelSplit.columnStart(column: 736, room: 884, row: 1184), 148)
        // A column that fills its room stays at the start of it.
        XCTAssertEqual(PanelSplit.columnStart(column: 644, room: 644, row: 1184), 0)
    }

    func testChatColumnWithoutPanelsIsCenteredInItsRoom() {
        XCTAssertEqual(PanelSplit.columnStart(column: 736, room: 1000, row: nil), 132)
        XCTAssertEqual(PanelSplit.columnStart(column: 736, room: 1000, row: 0), 132)
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
