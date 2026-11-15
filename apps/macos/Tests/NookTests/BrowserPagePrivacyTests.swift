import XCTest

/// The page in the browser's side panel follows the privacy settings Nook's main window sets: a page is part of the
/// screen, so it stays on this Mac whenever the screen does, and the brain is told where it is. Which questions the
/// screen brain takes for the page is in `BrainSelectionTests` (it needs the Mac).
final class BrowserPagePrivacyTests: XCTestCase {
    func testThePageStaysOnThisMacWheneverTheScreenDoes() {
        XCTAssertTrue(PrivacyLevel.strict.keptOnMac(byHand: []).contains(SourceCatalog.browserExtension), "Strict keeps the screen, so the page too")
        XCTAssertTrue(PrivacyLevel.open.keptOnMac(byHand: [SourceCatalog.screen]).contains(SourceCatalog.browserExtension),
                      "the screen kept here by hand keeps the page too")
        XCTAssertTrue(PrivacyLevel.open.keptOnMac(byHand: [SourceCatalog.browserExtension]).contains(SourceCatalog.browserExtension))
        XCTAssertFalse(PrivacyLevel.balanced.keptOnMac(byHand: ["mail"]).contains(SourceCatalog.browserExtension),
                       "nothing kept here that the page belongs to")
        XCTAssertEqual(SourceCatalog.browserExtension, BrowserExtensionTools.sourceID)
    }

    func testTheBrainIsToldWhereThePageIs() throws {
        let page = try XCTUnwrap(BrowserExtensionPanel.Page(["title": "Bank", "url": "https://bank.example.com", "text": "Saldo € 1.234"]))
        let shared = BrowserExtensionPanel.note(page: page, browser: "Arc", privacy: .shared)
        XCTAssertTrue(shared.contains("without calling chrome_read"))
        let readHere = BrowserExtensionPanel.note(page: page, browser: "Arc", privacy: .readHere)
        XCTAssertTrue(readHere.contains("note from a model on the user's Mac"))
        XCTAssertTrue(readHere.contains("never ask for the page"))
        XCTAssertFalse(readHere.contains("1.234"), "the note never carries the page's text")
        let kept = BrowserExtensionPanel.note(page: page, browser: "Arc", privacy: .keptHere)
        XCTAssertTrue(kept.contains("Settings › Brain › Screen work"))
        XCTAssertFalse(kept.contains("chrome_read"), "no tool it does not have")
        XCTAssertFalse(kept.contains("1.234"))
    }

    func testTheModelOnThisMacKnowsItReadsAPage() {
        let prompt = PrivateBrief.prompt(request: "Wat is mijn saldo?", history: "", context: "", screen: "Saldo € 1.234",
                                         budget: 8_000, place: PrivateBrief.pagePlace("Bank\nOverzicht"))
        XCTAssertTrue(prompt.contains("On the page the user has open in their browser (\"Bank Overzicht\")"))
        XCTAssertTrue(prompt.contains("<screen_content>"))
        XCTAssertTrue(PrivateBrief.prompt(request: "x", history: "", context: "", screen: "y", budget: 8_000).contains("On the user's screen:"))
        // Whatever the model writes, contact details are taken out before the note leaves.
        XCTAssertEqual(PrivateBrief.sealed("Mail lisa@example.com over de factuur"), "Mail [email] over de factuur")
    }
}
