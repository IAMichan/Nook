import XCTest

/// "@open whatsapp" and friends: which chat messages open an app next to the chat, and which stay questions.
final class EmbeddedAppTests: XCTestCase {
    private func opened(_ text: String) -> String? {
        if case .open(let app) = EmbeddedAppCatalog.command(in: text) { return app.id }
        return nil
    }

    func testOpenCommands() {
        XCTAssertEqual(opened("@open whatsapp"), "whatsapp")
        XCTAssertEqual(opened("@open WhatsApp"), "whatsapp")
        XCTAssertEqual(opened("@open whats app"), "whatsapp")
        XCTAssertEqual(opened("@whatsapp"), "whatsapp")
        XCTAssertEqual(opened("@openen gmail"), "gmail")
        XCTAssertEqual(opened("@open google calendar"), "calendar")
        XCTAssertEqual(opened("open whatsapp in nook"), "whatsapp")
        XCTAssertEqual(opened("öffne Slack im Nook"), "slack")
    }

    func testWebAddressesOpenAsTheirOwnApp() {
        guard case .open(let app) = EmbeddedAppCatalog.command(in: "@open notion.so/my-page") else { return XCTFail("not opened") }
        XCTAssertEqual(app.url.absoluteString, "https://notion.so/my-page")
        XCTAssertEqual(app.title, "notion.so")
        XCTAssertNil(EmbeddedAppCatalog.webApp("http://example.com"), "only https")
        XCTAssertNil(EmbeddedAppCatalog.webApp("lisa@example.com"))
    }

    func testCloseAndUnknown() {
        XCTAssertEqual(EmbeddedAppCatalog.command(in: "@close"), .close)
        XCTAssertEqual(EmbeddedAppCatalog.command(in: "@sluit"), .close)
        XCTAssertEqual(EmbeddedAppCatalog.command(in: "@open foo bar"), .unknown("foo bar"))
    }

    func testOtherMessagesStayQuestions() {
        XCTAssertNil(EmbeddedAppCatalog.command(in: "@Lisa wat vind jij?"))
        XCTAssertNil(EmbeddedAppCatalog.command(in: "Open WhatsApp"), "the Mac app, through open_app")
        XCTAssertNil(EmbeddedAppCatalog.command(in: "Wat staat er in WhatsApp?"))
        XCTAssertNil(EmbeddedAppCatalog.command(in: "lisa@example.com"))
    }

    func testMentionList() {
        XCTAssertEqual(EmbeddedAppCatalog.matching(EmbeddedAppCatalog.mentionQuery("open")).count, EmbeddedAppCatalog.all.count)
        XCTAssertEqual(EmbeddedAppCatalog.matching(EmbeddedAppCatalog.mentionQuery("wh")).first?.id, "whatsapp")
    }

    func testEachAppKeepsItsOwnStore() {
        let ids = EmbeddedAppCatalog.all.map(\.storeID)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(EmbeddedAppCatalog.storeID(for: "whatsapp"), EmbeddedAppCatalog.storeID(for: "whatsapp"), "the same every launch")
    }

    func testSplitKeepsBothSidesUsable() {
        XCTAssertEqual(EmbeddedSplit.chatWidth(500, total: 1200), 500)
        XCTAssertEqual(EmbeddedSplit.chatWidth(100, total: 1200), EmbeddedSplit.minimumChat, "the chat never gets too narrow")
        XCTAssertEqual(EmbeddedSplit.chatWidth(5000, total: 1200), 1200 - EmbeddedSplit.minimumApp - EmbeddedSplit.handle, "nor does the app")
        XCTAssertEqual(EmbeddedSplit.chatWidth(400, total: 0), 400, "width not known yet")
        XCTAssertEqual(EmbeddedSplit.chatWidth(400, total: 500), EmbeddedSplit.minimumChat, "too small for both: the chat keeps its minimum")
    }
}
