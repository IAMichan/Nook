import XCTest

/// Double Tap suggestions: what the field offers for what is in front, and that every offer takes the path it should
/// when it is sent as typed.
final class DoubleTapSuggestTests: XCTestCase {
    private func texts(_ scene: DoubleTapScene?, recents: [String] = [], language: AppLanguage = .en,
                       selectionLanguage: String? = nil) -> [String] {
        DoubleTapLogic.suggestions(for: scene, recents: recents, language: language, selectionLanguage: selectionLanguage)
            .map(\.text)
    }

    private func requireTranslations() throws {
        if tr("doubletap.suggest.improve") == "doubletap.suggest.improve" { throw XCTSkip("translations are shimmed") }
    }

    func testASelectionIsRewrittenInPlace() throws {
        try requireTranslations()
        var scene = DoubleTapScene(focus: .text, selection: "Ik kom morgen iets later binnen want de trein rijdt niet.")
        scene.focusEmpty = false
        let chips = texts(scene, selectionLanguage: "nl")
        XCTAssertEqual(chips.first, "Improve this")
        XCTAssertTrue(chips.contains("Translate this into English"), "\(chips)")
        XCTAssertTrue(chips.contains("Explain the selected text"))
        XCTAssertFalse(chips.contains("Shorten this"), "a short selection is not shortened")
    }

    func testATranslationGoesToTheOtherLanguage() {
        XCTAssertEqual(DoubleTapLogic.translationTarget(selectionLanguage: "en", app: .nl), "nl")
        XCTAssertEqual(DoubleTapLogic.translationTarget(selectionLanguage: "nl", app: .nl), "en")
        XCTAssertNil(DoubleTapLogic.translationTarget(selectionLanguage: "en", app: .en))
        XCTAssertNil(DoubleTapLogic.translationTarget(selectionLanguage: nil, app: .de))
    }

    func testAnEmptyReplyBoxAsksForAReply() throws {
        try requireTranslations()
        let whatsapp = DoubleTapScene(bundleID: "net.whatsapp.WhatsApp", focus: .text)
        XCTAssertEqual(texts(whatsapp).first, "Write a reply")
        let web = DoubleTapScene(bundleID: "com.apple.Safari", focus: .field, placeholder: "Write a message…")
        XCTAssertEqual(texts(web).first, "Write a reply")
        // A document with text in it: carry on writing instead.
        var document = DoubleTapScene(bundleID: "com.microsoft.Word", focus: .text)
        document.focusEmpty = false
        XCTAssertEqual(texts(document).first, "Write more")
    }

    func testAFormWithEmptyFieldsIsFilledIn() throws {
        try requireTranslations()
        let form = DoubleTapScene(bundleID: "com.apple.Safari", focus: .field, emptyFields: 4)
        XCTAssertEqual(texts(form).first, "Fill in the form")
        let one = DoubleTapScene(bundleID: "com.apple.Safari", focus: .none, emptyFields: 1)
        XCTAssertFalse(texts(one).contains("Fill in the form"), "one stray field is not a form")
    }

    func testAWindowWithADayGoesToTheCalendar() throws {
        try requireTranslations()
        let now = ISO8601DateFormatter().date(from: "2026-11-11T09:00:00Z")!
        XCTAssertTrue(DoubleTapLogic.hasDates("Borrel op vrijdag 14 november om 17:00 bij Jansen", now: now))
        XCTAssertTrue(DoubleTapLogic.hasDates("Meeting on November 20, 2026 at 3pm", now: now))
        XCTAssertFalse(DoubleTapLogic.hasDates("Battery 80%   14:30", now: now), "a clock is not a day")
        XCTAssertFalse(DoubleTapLogic.hasDates("", now: now))
    }

    func testRecentRequestsFillTheRestWithoutRepeats() throws {
        try requireTranslations()
        let recents = ["Improve this", "zet de vergadering van morgen een uur later", "write a thank-you note"]
        var scene = DoubleTapScene(focus: .text, selection: "hello there friend, how are you")
        scene.focusEmpty = false
        let chips = texts(scene, recents: recents)
        XCTAssertEqual(chips.count, DoubleTapLogic.maxSuggestions)
        XCTAssertEqual(chips.count(where: { $0 == "Improve this" }), 1, "a recent request already offered is not repeated")
        XCTAssertTrue(chips.contains("zet de vergadering van morgen een uur later"))
        XCTAssertEqual(texts(nil, recents: recents), recents, "with Nook in front: only what you asked lately")
    }

    func testRememberingKeepsTheNewestFirst() {
        var recents: [String] = []
        recents = DoubleTapLogic.remembering("vertaal dit", in: recents)
        recents = DoubleTapLogic.remembering("fill in the form", in: recents)
        recents = DoubleTapLogic.remembering("Vertaal dit", in: recents)
        XCTAssertEqual(recents, ["Vertaal dit", "fill in the form"])
        XCTAssertEqual(DoubleTapLogic.remembering(String(repeating: "x", count: 200), in: recents), recents, "too long to offer")
        for index in 0..<20 { recents = DoubleTapLogic.remembering("request \(index)", in: recents) }
        XCTAssertEqual(recents.count, DoubleTapLogic.maxRecents)
    }

    /// Every suggestion, in every language, is routed the way it is meant: rewriting and replying at the cursor,
    /// filling the form, and the rest to the chat (with the window).
    func testEverySuggestionTakesItsPath() {
        for language in AppLanguage.allCases {
            let text = { (key: String) in I18n.text(key, [], for: language) }
            guard text("doubletap.suggest.improve") != "doubletap.suggest.improve" else { return }
            for key in ["improve", "shorten", "reply", "continue"] {
                let request = text("doubletap.suggest." + key)
                XCTAssertTrue(DoubleTapLogic.asksToWrite(request), "\(language): \(request) writes at the cursor")
                XCTAssertFalse(DoubleTapLogic.asksToFill(request), "\(language): \(request)")
            }
            let translate = I18n.text("doubletap.suggest.translate", ["English"], for: language)
            XCTAssertTrue(DoubleTapLogic.asksToWrite(translate), "\(language): \(translate)")
            XCTAssertTrue(DoubleTapLogic.asksToFill(text("doubletap.suggest.fill")), "\(language)")
            XCTAssertFalse(DoubleTapLogic.asksToEdit(text("doubletap.suggest.fill")), "\(language)")
            for key in ["explain", "calendar", "summarize"] {
                let request = text("doubletap.suggest." + key)
                XCTAssertFalse(DoubleTapLogic.asksToWrite(request), "\(language): \(request) goes to the chat")
                XCTAssertFalse(DoubleTapLogic.asksToFill(request), "\(language): \(request)")
                XCTAssertFalse(DoubleTapLogic.asksToEdit(request), "\(language): \(request)")
            }
        }
    }
}
