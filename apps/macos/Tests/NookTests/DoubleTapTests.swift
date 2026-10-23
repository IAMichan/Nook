import XCTest

/// Double Tap: the gesture, which fields may be filled, the prompt and how the brain's answer is read.
final class DoubleTapTests: XCTestCase {
    // MARK: Gesture

    func testTwoQuickTapsAreADoubleTap() {
        var gesture = DoubleTapGesture()
        XCTAssertEqual(gesture.update(down: true, alone: true, at: 10.00, lastKeyDown: 0), .none)
        XCTAssertEqual(gesture.update(down: false, alone: true, at: 10.08, lastKeyDown: 0), .tap)
        XCTAssertEqual(gesture.update(down: true, alone: true, at: 10.25, lastKeyDown: 0), .none)
        XCTAssertEqual(gesture.update(down: false, alone: true, at: 10.32, lastKeyDown: 0), .double)
        // A third tap starts a new pair instead of firing again.
        XCTAssertEqual(gesture.update(down: true, alone: true, at: 10.5, lastKeyDown: 0), .none)
        XCTAssertEqual(gesture.update(down: false, alone: true, at: 10.55, lastKeyDown: 0), .tap)
    }

    func testSlowTapsHoldsAndShortcutsAreNot() {
        var slow = DoubleTapGesture()
        _ = slow.update(down: true, alone: true, at: 0, lastKeyDown: -10)
        _ = slow.update(down: false, alone: true, at: 0.1, lastKeyDown: -10)
        _ = slow.update(down: true, alone: true, at: 0.9, lastKeyDown: -10)
        XCTAssertNotEqual(slow.update(down: false, alone: true, at: 1.0, lastKeyDown: -10), .double, "too far apart")

        var hold = DoubleTapGesture()
        _ = hold.update(down: true, alone: true, at: 0, lastKeyDown: -10)
        _ = hold.update(down: false, alone: true, at: 0.1, lastKeyDown: -10)
        _ = hold.update(down: true, alone: true, at: 0.3, lastKeyDown: -10)
        XCTAssertNotEqual(hold.update(down: false, alone: true, at: 1.5, lastKeyDown: -10), .double, "a hold is Flow's, not a tap")

        var shortcut = DoubleTapGesture()
        _ = shortcut.update(down: true, alone: true, at: 0, lastKeyDown: -10)
        _ = shortcut.update(down: false, alone: true, at: 0.1, lastKeyDown: -10)
        _ = shortcut.update(down: true, alone: true, at: 0.3, lastKeyDown: -10)
        XCTAssertNotEqual(shortcut.update(down: false, alone: true, at: 0.4, lastKeyDown: 0.35), .double, "⌘C typed in between")

        var chord = DoubleTapGesture()
        _ = chord.update(down: true, alone: true, at: 0, lastKeyDown: -10)
        _ = chord.update(down: false, alone: true, at: 0.1, lastKeyDown: -10)
        _ = chord.update(down: true, alone: false, at: 0.3, lastKeyDown: -10)
        XCTAssertNotEqual(chord.update(down: false, alone: true, at: 0.4, lastKeyDown: -10), .double, "another modifier held")

        var interrupted = DoubleTapGesture()
        _ = interrupted.update(down: true, alone: true, at: 0, lastKeyDown: -10)
        _ = interrupted.update(down: false, alone: true, at: 0.1, lastKeyDown: -10)
        interrupted.interrupt()
        _ = interrupted.update(down: true, alone: true, at: 0.2, lastKeyDown: -10)
        XCTAssertNotEqual(interrupted.update(down: false, alone: true, at: 0.3, lastKeyDown: -10), .double)
    }

    // MARK: Fields

    private func field(_ role: String, _ label: String, value: String = "", focused: Bool = false, secure: Bool = false,
                       source: Int = 0) -> DoubleTapField {
        DoubleTapField(id: 0, role: role, label: label, value: value, focused: focused, secure: secure, settable: true, source: source)
    }

    func testCandidatesSkipSecretsAndPutTheFocusFirst() {
        let fields = [
            field("field", "First name", source: 0),
            field("password", "Password", source: 1),
            field("field", "Card number", source: 2),
            field("field", "PIN", source: 3),
            field("field", "Spinach preference", source: 4),
            field("search", "Search", source: 5),
            field("textarea", "Message", focused: true, source: 6),
            field("field", "Login", secure: true, source: 7),
            field("field", "IBAN", source: 8)
        ]
        let candidates = DoubleTapLogic.candidates(fields)
        XCTAssertEqual(candidates.map(\.label), ["Message", "First name", "Spinach preference"])
        XCTAssertEqual(candidates.map(\.id), [1, 2, 3])
        XCTAssertEqual(candidates.map(\.source), [6, 0, 4], "the original place is kept for writing")
    }

    func testRoomOnlyWhenAFieldIsEmpty() {
        XCTAssertFalse(DoubleTapLogic.hasRoom([field("field", "Name", value: "Michan")]))
        XCTAssertTrue(DoubleTapLogic.hasRoom([field("field", "Name", value: "Michan"), field("field", "City", value: "  ")]))
    }

    func testPromptNamesFieldsFactsAndScreen() {
        let fields = DoubleTapLogic.candidates([field("field", "Email", focused: true), field("field", "Name", value: "Michan")])
        let prompt = DoubleTapLogic.prompt(app: "Safari", window: "Sign up", fields: fields, facts: ["Lives in Utrecht"],
                                           screen: "Create your account")
        XCTAssertTrue(prompt.contains("App: Safari — window: Sign up"))
        XCTAssertTrue(prompt.contains("[1] field \"Email\", empty ← cursor is here"))
        XCTAssertTrue(prompt.contains("[2] field \"Name\", contains \"Michan\""))
        XCTAssertTrue(prompt.contains("- Lives in Utrecht"))
        XCTAssertTrue(prompt.contains("Text on screen:\nCreate your account"))
    }

    func testPromptCarriesTheUsersRequest() {
        let fields = DoubleTapLogic.candidates([field("field", "Address", focused: true)])
        let prompt = DoubleTapLogic.prompt(app: "Safari", window: "", fields: fields, facts: [], screen: "",
                                           request: "Vul het formulier in met mijn werkadres")
        XCTAssertTrue(prompt.hasPrefix("The user's request: Vul het formulier in met mijn werkadres\n"))
        XCTAssertFalse(DoubleTapLogic.prompt(app: "Safari", window: "", fields: fields, facts: [], screen: "").contains("request"))
    }

    // MARK: Request

    func testAskingToFillInTheFormInFront() {
        for text in ["Vul het formulier in", "vul dit in", "Invullen", "fill in the form", "Fill this out", "fill it in",
                     "Füll das Formular aus", "Remplis le formulaire", "Rellena el formulario", "vul de velden in met mijn werkadres"] {
            XCTAssertTrue(DoubleTapLogic.asksToFill(text), text)
        }
    }

    func testOtherTasksAreNotAFill() {
        for text in ["Bestel nieuwe koffiefilters bij bol.com", "Vul het formulier op bol.com in", "order coffee filters",
                     "Vul mijn boodschappenlijst aan", "Unsubscribe me from this newsletter", "", "fill out https://example.com/form"] {
            XCTAssertFalse(DoubleTapLogic.asksToFill(text), text)
        }
    }

    // MARK: Answer

    func testValuesAreReadFailClosed() {
        let fields = DoubleTapLogic.candidates([
            field("field", "City", focused: true),
            field("field", "Name", value: "Michan"),
            field("textarea", "Motivation"),
            field("field", "Phone")
        ])
        let reply = """
        Sure! ```json
        {"fields": {"1": "Utrecht\\nNL", "2": "Someone else", "3": "I like building tools.\\nEvery day.", "4": 612345678, "9": "x"}}
        ```
        """
        let values = DoubleTapLogic.values(from: reply, fields: fields)
        XCTAssertEqual(values[1], "Utrecht NL", "a one-line field gets one line")
        XCTAssertNil(values[2], "never overwrite what is typed")
        XCTAssertEqual(values[3], "I like building tools.\nEvery day.")
        XCTAssertEqual(values[4], "612345678")
        XCTAssertNil(values[9], "a field that was not offered")

        XCTAssertEqual(DoubleTapLogic.values(from: "I can't help with that.", fields: fields), [:])
        XCTAssertEqual(DoubleTapLogic.values(from: "{\"fields\": {}}", fields: fields), [:])
        XCTAssertEqual(DoubleTapLogic.values(from: "{\"[1]\": \"Utrecht\"}", fields: fields), [1: "Utrecht"])
    }

    func testCardAndSocialSecurityNumbersAreDropped() {
        XCTAssertTrue(DoubleTapLogic.containsHighRiskNumber("4111 1111 1111 1111"))
        XCTAssertTrue(DoubleTapLogic.containsHighRiskNumber("card 4111-1111-1111-1111 ok"))
        XCTAssertTrue(DoubleTapLogic.containsHighRiskNumber("SSN 123-45-6789"))
        XCTAssertFalse(DoubleTapLogic.containsHighRiskNumber("06 1234 5678"))
        XCTAssertFalse(DoubleTapLogic.containsHighRiskNumber("4111 1111 1111 1112"), "not Luhn-valid")
        XCTAssertFalse(DoubleTapLogic.containsHighRiskNumber("Utrecht, 3511 AB"))

        let fields = DoubleTapLogic.candidates([field("field", "Notes", focused: true)])
        XCTAssertEqual(DoubleTapLogic.values(from: "{\"fields\": {\"1\": \"use 4111111111111111\"}}", fields: fields), [:])
    }

    // MARK: Sending

    func testTheSendButtonIsFoundButNeverAPaymentOrDelete() {
        XCTAssertEqual(DoubleTapLogic.submitButton(labels: ["Cancel", "Send message", "Help"], defaultIndex: nil), 1)
        XCTAssertEqual(DoubleTapLogic.submitButton(labels: ["Annuleren", "Volgende", "Verzenden"], defaultIndex: nil), 2, "send beats next")
        XCTAssertEqual(DoubleTapLogic.submitButton(labels: ["Back", "Create account"], defaultIndex: 1), 1, "the default button")
        XCTAssertNil(DoubleTapLogic.submitButton(labels: ["Back", "Pay now"], defaultIndex: 1))
        XCTAssertNil(DoubleTapLogic.submitButton(labels: ["Bestellen en betalen", "Verwijderen"], defaultIndex: nil))
        XCTAssertNil(DoubleTapLogic.submitButton(labels: ["Sender settings"], defaultIndex: nil), "whole words only")
        XCTAssertEqual(DoubleTapLogic.submitButton(labels: ["Sign up"], defaultIndex: nil), 0)
    }

    // MARK: Writing at the cursor

    func testWritingRequestsInEveryLanguage() {
        for text in ["schrijf een sollicitatiebrief", "Write a short intro about our product", "can you write a reply",
                     "kun je een brief schrijven", "vertaal dit naar het Engels", "maak een samenvatting van deze tekst",
                     "herschrijf dit formeler", "schreib eine Antwort", "écris une lettre de motivation",
                     "escribe un correo a Ana", "translate this into Dutch", "typ een korte reactie"] {
            XCTAssertTrue(DoubleTapLogic.asksToWrite(text), text)
        }
        for text in ["wat is het weer morgen", "maak een afspraak om 3 uur", "how do I write a for loop in Swift",
                     "finish this for me", "voeg een afspraak toe", "schrijf me in op bol.com", "open Spotify",
                     "schrijf een post op Reddit over Nook", ""] {
            XCTAssertFalse(DoubleTapLogic.asksToWrite(text), text)
        }
    }

    func testWritePromptHoldsTheContextAroundTheCursor() {
        let prompt = DoubleTapLogic.writePrompt(request: "schrijf verder", app: "Microsoft Word", window: "Brief.docx",
                                                before: "Geachte heer Jansen,", after: "Met vriendelijke groet", selected: "",
                                                facts: ["Lives in Utrecht"], screen: "")
        XCTAssertTrue(prompt.contains("The user's request: schrijf verder"))
        XCTAssertTrue(prompt.contains("App: Microsoft Word — window: Brief.docx"))
        XCTAssertTrue(prompt.contains("Geachte heer Jansen,"))
        XCTAssertTrue(prompt.contains("Text after the cursor:\nMet vriendelijke groet"))
        XCTAssertFalse(prompt.contains("Selected text"))
        let empty = DoubleTapLogic.writePrompt(request: "write a poem", app: "Notes", window: "", before: "", after: "",
                                               selected: "Old line", facts: [], screen: "")
        XCTAssertTrue(empty.contains("Selected text (your text replaces it):\nOld line"))
        XCTAssertTrue(empty.contains("the cursor is at the start"))
    }

    func testWrittenTextIsCleanedAndChecked() {
        XCTAssertEqual(DoubleTapLogic.written(from: "```\nHallo Jan,\n\nTot morgen!\n```"), "Hallo Jan,\n\nTot morgen!")
        XCTAssertEqual(DoubleTapLogic.written(from: "\"Dear Ms. Smith\""), "Dear Ms. Smith")
        XCTAssertEqual(DoubleTapLogic.written(from: "## Intro\nThis is **important**."), "Intro\nThis is important.")
        XCTAssertNil(DoubleTapLogic.written(from: "   "))
        XCTAssertNil(DoubleTapLogic.written(from: "Pay with 4111 1111 1111 1111"))
        XCTAssertNil(DoubleTapLogic.written(from: String(repeating: "a", count: DoubleTapLogic.maxWrittenLength + 1)))
    }

    func testPreviewIsOneShortLine() {
        XCTAssertEqual(DoubleTapLogic.preview("Hallo Jan,\n\nTot morgen!"), "Hallo Jan, Tot morgen!")
        XCTAssertEqual(DoubleTapLogic.preview(String(repeating: "word ", count: 30), limit: 10), "word word…")
    }

    func testProgressLineShowsWhatNookDoesThenTheNewestWords() {
        XCTAssertEqual(DoubleTapLogic.progressLine(text: "", status: "Thinking…"), "Thinking…")
        XCTAssertEqual(DoubleTapLogic.progressLine(text: "", status: ""), "")
        XCTAssertEqual(DoubleTapLogic.progressLine(text: "Morgen heb je\n\nom 9:00 een afspraak", status: "Thinking…"),
                       "om 9:00 een afspraak")
        let long = DoubleTapLogic.progressLine(text: "one two three four five six seven eight", status: "", limit: 20)
        XCTAssertTrue(long.hasPrefix("…"), long)
        XCTAssertTrue(long.hasSuffix("seven eight"), long)
        XCTAssertLessThanOrEqual(long.count, 20)
    }

    // MARK: Editing what is there

    func testEditRequestsInEveryLanguage() {
        for text in ["punt 5 moet dit worden", "Punt 3 moet worden: gratis verzending", "verwijder alinea 2",
                     "maak de tweede alinea korter", "herschrijf de laatste zin formeler", "vervang 'Jansen' door 'de Vries'",
                     "vervang Jansen door de Vries", "change point 5 to this", "make item 2 more formal", "delete the last sentence",
                     "Punkt 5 soll das werden", "ersetze den ersten Absatz", "le point 5 doit devenir ceci",
                     "el punto 5 debe ser esto", "vertaal punt 4 naar het Engels"] {
            XCTAssertTrue(DoubleTapLogic.asksToEdit(text), text)
        }
        for text in ["schrijf een sollicitatiebrief", "vul het formulier in", "wat is het weer morgen", "maak een afspraak om 3 uur",
                     "dat is een goed punt", "verwijder de afspraak van morgen", "zet Night Shift aan",
                     "verander punt 5 op bol.com", "open Spotify", ""] {
            XCTAssertFalse(DoubleTapLogic.asksToEdit(text), text)
        }
    }

    func testEditPromptHoldsTheDocumentSelectionAndClipboard() {
        let document = "Voorwaarden\rLevering binnen 5 dagen\rRetour binnen 14 dagen"
        let prompt = DoubleTapLogic.editPrompt(request: "punt 2 moet dit worden", app: "Microsoft Word", window: "Offerte.docx",
                                               document: document, cursor: NSRange(location: 12, length: 0),
                                               clipboard: "Retour binnen 30 dagen", facts: [], screen: "")
        XCTAssertTrue(prompt.contains("The user's request: punt 2 moet dit worden"))
        XCTAssertTrue(prompt.contains("App: Microsoft Word — window: Offerte.docx"))
        XCTAssertTrue(prompt.contains("The document:\n" + document))
        XCTAssertTrue(prompt.contains("Clipboard:\nRetour binnen 30 dagen"))
        XCTAssertTrue(prompt.contains("Text just before the cursor:"))
        let long = String(repeating: "a", count: 30_000)
        let excerpt = DoubleTapLogic.editPrompt(request: "x", app: "Pages", window: "", document: long,
                                                cursor: NSRange(location: 29_000, length: 0), clipboard: "", facts: [], screen: "")
        XCTAssertTrue(excerpt.contains("an excerpt around the cursor"))
        XCTAssertLessThan(excerpt.count, 20_000)
    }

    func testEditsAreFoundInTheDocumentFailClosed() {
        let document = "Afspraken\r1 Levering binnen 5 dagen\rRetour binnen 14 dagen\rBetaling binnen 30 dagen"
        let reply = """
        ```json
        {"edits": [{"find": "Retour binnen 14 dagen", "replace": "Retour binnen **30** dagen"},
                   {"find": "Levering binnen 5 dagen", "replace": "Levering binnen 2 dagen"},
                   {"find": "Niet in het document", "replace": "x"},
                   {"find": "binnen", "replace": "ambiguous"},
                   {"find": "Betaling binnen 30 dagen", "replace": "Betaling binnen 30 dagen"}]}
        ```
        """
        let (edits, missed) = DoubleTapLogic.edits(from: reply, in: document)
        XCTAssertEqual(edits.map(\.replace), ["Retour binnen 30 dagen", "Levering binnen 2 dagen"], "last first, Markdown gone")
        XCTAssertEqual(missed, 2, "not there, and there more than once")
        XCTAssertEqual((document as NSString).substring(with: edits[1].range), "Levering binnen 5 dagen")
        XCTAssertTrue(DoubleTapLogic.edits(from: "Sure, I changed it.", in: document).edits.isEmpty)
        XCTAssertTrue(DoubleTapLogic.edits(from: #"{"edits": [{"find": "Retour binnen 14 dagen", "replace": "4111 1111 1111 1111"}]}"#,
                                           in: document).edits.isEmpty, "a card number is never typed")
        let deletion = DoubleTapLogic.edits(from: #"{"find": "Retour binnen 14 dagen", "replace": ""}"#, in: document).edits
        XCTAssertEqual(deletion.first?.replace, "", "an empty replace deletes")
    }

    func testLocateEvensOutQuotesSpacesAndListMarkers() {
        let document = "Intro\r\rHet \u{201C}nieuwe\u{201D}  plan\u{00A0}start\rNog een punt"
        let range = DoubleTapLogic.locate("Het \"nieuwe\" plan start", in: document)
        XCTAssertEqual(range.map { (document as NSString).substring(with: $0) }, "Het \u{201C}nieuwe\u{201D}  plan\u{00A0}start")
        let marked = DoubleTapLogic.locate("2. Nog een punt", in: document)
        XCTAssertEqual(marked.map { (document as NSString).substring(with: $0) }, "Nog een punt")
        XCTAssertNil(DoubleTapLogic.locate("Bestaat niet", in: document))
    }

    func testAppliedComparesWithLineBreaksEvenedOut() {
        let before = "Een\rTwee\rDrie"
        let edit = DoubleTapEdit(find: "Twee", replace: "2\n2b", range: NSRange(location: 4, length: 4))
        XCTAssertTrue(DoubleTapLogic.applied(edit, before: before, after: "Een\r2\r2b\rDrie"))
        XCTAssertFalse(DoubleTapLogic.applied(edit, before: before, after: before))
        XCTAssertEqual(DoubleTapLogic.editPreview(edit), "“Twee” → “2 2b”")
        XCTAssertEqual(DoubleTapLogic.editPreview(DoubleTapEdit(find: "Twee", replace: "", range: edit.range)), "“Twee” ✕")
    }

    // MARK: The run's steps

    func testEachStepEndsTheOneBeforeIt() {
        var run = DoubleTapRun(request: "  vertaal dit  ")
        XCTAssertEqual(run.request, "vertaal dit")
        XCTAssertTrue(run.isRunning)
        run.step("Pages lezen…")
        run.step("Pages lezen…")
        run.step("  ")
        run.step("Denkt na: vertaal dit")
        XCTAssertEqual(run.steps.map(\.text), ["Pages lezen…", "Denkt na: vertaal dit"], "the same line twice is one step")
        XCTAssertEqual(run.steps.map(\.state), [.done, .running])
    }

    func testFinishingMarksTheLastStepAndKeepsTheFirstResult() {
        var done = DoubleTapRun(request: "", started: Date(timeIntervalSince1970: 100))
        done.step("Typt in Pages: Hallo")
        done.finish(.done, result: "Getypt in Pages", detail: "⌘Z", at: Date(timeIntervalSince1970: 103.4))
        done.finish(.failed, result: "later")
        done.step("after the end")
        XCTAssertFalse(done.isRunning)
        XCTAssertEqual(done.outcome, .done)
        XCTAssertEqual(done.result, "Getypt in Pages")
        XCTAssertEqual(done.resultDetail, "⌘Z")
        XCTAssertEqual(done.steps.map(\.state), [.done])
        XCTAssertEqual(done.seconds, 3)

        var failed = DoubleTapRun(request: "")
        failed.step("Denkt na…")
        failed.finish(.failed, result: "Het brein gaf geen antwoord")
        XCTAssertEqual(failed.steps.last?.state, .failed)

        var stopped = DoubleTapRun(request: "")
        stopped.step("Denkt na…")
        stopped.finish(.stopped, result: "Gestopt")
        XCTAssertEqual(stopped.steps.last?.state, .failed)
        XCTAssertNil(DoubleTapRun(request: "").seconds, "no time while it works")
    }

    func testChecksSkipEmptyValuesAndCountTheRest() {
        var run = DoubleTapRun(request: "")
        run.check("Naam", "  Michan ")
        run.check("Leeg", "   ")
        XCTAssertEqual(run.checks.map(\.value), ["Michan"])
        for index in 0..<(DoubleTapRun.maxChecks + 2) { run.check("Veld \(index)", "waarde") }
        XCTAssertEqual(run.checks.count, DoubleTapRun.maxChecks)
        XCTAssertEqual(run.moreChecks, 3)
    }

    func testOnlyTheLatestStepsAreKept() {
        var run = DoubleTapRun(request: "")
        for index in 0..<(DoubleTapRun.maxSteps + 5) { run.step("Stap \(index)") }
        XCTAssertEqual(run.steps.count, DoubleTapRun.maxSteps)
        XCTAssertEqual(run.steps.last?.text, "Stap \(DoubleTapRun.maxSteps + 4)")
        XCTAssertEqual(Set(run.steps.map(\.id)).count, run.steps.count, "ids stay unique")
    }
}
