import XCTest

/// Sending through WhatsApp Web beside the chat: which pages count as WhatsApp Web, and what the page's answer means.
final class WhatsAppWebTests: XCTestCase {
    func testOnlyWhatsAppWebItself() {
        XCTAssertTrue(WhatsAppWeb.isWhatsAppWeb(URL(string: "https://web.whatsapp.com/")))
        XCTAssertTrue(WhatsAppWeb.isWhatsAppWeb(URL(string: "https://WEB.whatsapp.com/send?phone=1")))
        XCTAssertFalse(WhatsAppWeb.isWhatsAppWeb(URL(string: "https://web.whatsapp.com.example.com/")))
        XCTAssertFalse(WhatsAppWeb.isWhatsAppWeb(URL(string: "https://www.whatsapp.com/")))
        XCTAssertFalse(WhatsAppWeb.isWhatsAppWeb(nil))
    }

    func testOutcomes() {
        XCTAssertEqual(WhatsAppWeb.outcome(["status": "sent", "chat": "Doorsturen"]), .sent("Doorsturen"))
        XCTAssertEqual(WhatsAppWeb.outcome(["status": "opened", "chat": "Jan"]), .opened("Jan"))
        XCTAssertEqual(WhatsAppWeb.outcome(["status": "signedOut"]), .signedOut)
        XCTAssertEqual(WhatsAppWeb.outcome(["status": "notFound"]), .notFound)
        XCTAssertEqual(WhatsAppWeb.outcome(["status": "ambiguous", "candidates": ["Doorsturen A", "Doorsturen B"]]),
                       .ambiguous(["Doorsturen A", "Doorsturen B"]))
        XCTAssertEqual(WhatsAppWeb.outcome(["status": "draft", "chat": "Mama"]), .draft("Mama"))
        XCTAssertEqual(WhatsAppWeb.outcome(["status": "notSent", "chat": "Mama"]), .notSent("Mama"))
        XCTAssertEqual(WhatsAppWeb.outcome(["status": "failed", "step": "composer"]), .failed("composer"))
    }

    func testAnAnswerThatIsNoOutcomeIsAFailure() {
        XCTAssertEqual(WhatsAppWeb.outcome(nil), .failed("answer"))
        XCTAssertEqual(WhatsAppWeb.outcome("sent"), .failed("answer"))
        XCTAssertEqual(WhatsAppWeb.outcome(["chat": "Mama"]), .failed("answer"))
    }

    /// The chat and the text reach the page as arguments only: the script never has them spliced into its source.
    func testScriptTakesItsInputAsArguments() {
        XCTAssertTrue(WhatsAppWeb.sendScript.contains("norm(name)"))
        XCTAssertTrue(WhatsAppWeb.sendScript.contains("text.split"))
        XCTAssertFalse(WhatsAppWeb.sendScript.contains("\\("))
    }

    /// "@open chat Jan" finds the chat the same way as sending does, then stops: it never types or sends anything.
    func testOpenScriptOnlyOpensTheChat() {
        XCTAssertTrue(WhatsAppWeb.openScript.contains("norm(name)"))
        XCTAssertTrue(WhatsAppWeb.openScript.contains("status: 'opened'"))
        XCTAssertFalse(WhatsAppWeb.openScript.contains("insertText', false, line"))
        XCTAssertFalse(WhatsAppWeb.openScript.contains("data-icon=\"send\""))
        XCTAssertFalse(WhatsAppWeb.openScript.contains("\\("))
        XCTAssertTrue(WhatsAppWeb.sendScript.hasPrefix(WhatsAppWeb.openScript.components(separatedBy: "return { status: 'opened'").first ?? "-"))
    }
}
