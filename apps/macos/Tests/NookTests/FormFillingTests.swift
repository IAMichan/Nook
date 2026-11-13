import XCTest

/// "Vul het formulier in" is a task Nook does itself in the window where the form is open, however it is phrased. Reading
/// the page in the browser never reports an open page as missing, also when the browser does not hand over its text.
final class FormFillingTests: XCTestCase {
    private func action(_ text: String) -> String? { ChatIntent.detect(text).primaryAction }

    func testFillingInAFormIsTakenOverInEveryLanguage() {
        // The request that ended in "ik zie geen FileSender-tab" while the page was open.
        XCTAssertEqual(action("Ik heb van arjan den hartog een zip gekregen die ik naar Bit moet mailen (eerst uploaden naar filesender, en vul nu het formulier in wat open staat in de browser in filesender"), "take_over")
        XCTAssertEqual(action("Vul mijn formulier in"), "take_over")
        XCTAssertEqual(action("Kun je het formulier invullen?"), "take_over")
        XCTAssertEqual(action("wil je dit aanvraagformulier voor me invullen"), "take_over")
        XCTAssertEqual(action("Fill in the form on my screen"), "take_over")
        XCTAssertEqual(action("Can you fill out this form for me?"), "take_over")
        XCTAssertEqual(action("Füll bitte das Formular aus"), "take_over")
        XCTAssertEqual(action("Kannst du das Formular ausfüllen?"), "take_over")
        XCTAssertEqual(action("Remplis le formulaire pour moi"), "take_over")
        XCTAssertEqual(action("Rellena el formulario"), "take_over")
    }

    func testAQuestionAboutAFormIsNotATask() {
        XCTAssertFalse(ChatIntent.fillsForm("Hoe vul ik dit formulier in?"))
        XCTAssertFalse(ChatIntent.fillsForm("How do I fill in this form?"))
        XCTAssertFalse(ChatIntent.fillsForm("Wat is een formulier?"))
        XCTAssertFalse(ChatIntent.fillsForm("Vul de vaatwasser"))
    }

    func testAPageWhoseTextTheBrowserKeepsIsStillOpen() throws {
        let tab = try XCTUnwrap(OpenBrowserTab.parse("FileSender|||https://filesender.bit.nl/?s=upload|||1\n"))
        XCTAssertEqual(tab, OpenBrowserTab.Tab(title: "FileSender", url: "https://filesender.bit.nl/?s=upload", visible: true, text: ""))
        let answer = OpenBrowserTab.describe(tab, browser: "Microsoft Edge")
        XCTAssertTrue(answer.contains("https://filesender.bit.nl/?s=upload"))
        XCTAssertTrue(answer.contains("take_over"))
        XCTAssertTrue(answer.contains("Do not say it is not open"))
    }

    func testAPageWithTextAndATabBehindAnother() throws {
        let tab = try XCTUnwrap(OpenBrowserTab.parse("Upload|||https://example.com|||0\nLine one\nLine two"))
        XCTAssertFalse(tab.visible)
        XCTAssertEqual(tab.text, "Line one\nLine two")
        XCTAssertTrue(OpenBrowserTab.describe(tab, browser: "Safari").contains("behind another tab"))
    }

    func testNoTabIsNothing() {
        XCTAssertNil(OpenBrowserTab.parse(""))
        XCTAssertNil(OpenBrowserTab.parse("\n"))
        XCTAssertNil(OpenBrowserTab.parse("|||||||1\n"))
    }

    func testTheScriptLooksForANamedTabAndNeverFailsOnJavaScript() {
        let chromium = OpenBrowserTab.script(app: "Microsoft Edge", safari: false, match: "File\"Sender")
        XCTAssertTrue(chromium.contains("tell application \"Microsoft Edge\""))
        XCTAssertTrue(chromium.contains("set q to \"File\\\"Sender\""))
        XCTAssertTrue(chromium.contains("active tab of theWin"))
        // The JavaScript read sits inside a try, so title and address come back when it is switched off.
        XCTAssertNotNil(chromium.range(of: #"try\s+set docText to execute theTab javascript"#, options: .regularExpression))
        let safari = OpenBrowserTab.script(app: "Safari", safari: true, match: nil)
        XCTAssertTrue(safari.contains("current tab of theWin"))
        XCTAssertTrue(safari.contains("set docText to text of theTab"))
        XCTAssertFalse(safari.contains("javascript"))
    }
}
