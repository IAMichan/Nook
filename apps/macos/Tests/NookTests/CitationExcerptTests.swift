import XCTest
#if canImport(NookCore)
@testable import NookCore
#endif

/// What a citation shows of its source: the part of the tool's result it came from, the lines of it that match the
/// sentence, and an answer without a list of sources written out by the model.
@MainActor
final class CitationExcerptTests: XCTestCase {
    private let mails = """
    ### Achterstallige rekening | from Vimexx <billing@vimexx.nl> | 2026-11-14 [id: abc@vimexx]
    De registratie van infaris.com verloopt op 20 november.
    Betaal de openstaande factuur om de domeinnaam te behouden.

    ### Roadmap 2026-2027 Mindlinq | from Laura van Ekris | 2026-11-15 [id: def@mindlinq]
    Zullen we een sessie plannen om de roadmap door te nemen?
    """

    func testAMailsExcerptIsItsOwnBlockWithoutIds() {
        let excerpt = ReferenceParser.excerpt(for: "Achterstallige rekening", in: mails, alone: false)
        XCTAssertEqual(excerpt, """
        Achterstallige rekening | from Vimexx <billing@vimexx.nl> | 2026-11-14
        De registratie van infaris.com verloopt op 20 november.
        Betaal de openstaande factuur om de domeinnaam te behouden.
        """)
        let other = ReferenceParser.excerpt(for: "Roadmap 2026-2027 Mindlinq", in: mails, alone: false)
        XCTAssertEqual(other, "Roadmap 2026-2027 Mindlinq | from Laura van Ekris | 2026-11-15\nZullen we een sessie plannen om de roadmap door te nemen?")
    }

    func testAChatIsFoundByItsNameWithoutTheApp() {
        let chats = """
        ### Mama Jis | 16 nov [chat: 31612345678@s.whatsapp.net]
        - 09:12 · Mama Jis: Kom je zondag eten?
        - 09:13 · You: Ja, om zes uur
        """
        let excerpt = ReferenceParser.excerpt(for: "WhatsApp: Mama Jis", in: chats, alone: false)
        XCTAssertEqual(excerpt, "Mama Jis | 16 nov\n- 09:12 · Mama Jis: Kom je zondag eten?\n- 09:13 · You: Ja, om zes uur")
    }

    func testAnEventInAListIsItsOwnLine() {
        let events = """
        Daily Standup | 2026-11-16T09:00 – 2026-11-16T09:15 | calendar Werk | id E1
        Retrospective Mindlinq-team | 2026-11-16T13:00 – 2026-11-16T14:00 | id E2
        """
        XCTAssertEqual(ReferenceParser.excerpt(for: "Retrospective Mindlinq-team", in: events, alone: false),
                       "Retrospective Mindlinq-team | 2026-11-16T13:00 – 2026-11-16T14:00")
        XCTAssertEqual(ReferenceParser.excerpt(for: "Daily Standup", in: events, alone: false),
                       "Daily Standup | 2026-11-16T09:00 – 2026-11-16T09:15")
    }

    func testAnIssueIsFoundByItsNumber() {
        let issues = "- InfarisHQ/monorepo#4358 [PR, open] 'feat(guard): hosting' · updated 15 nov"
        XCTAssertEqual(ReferenceParser.excerpt(for: "InfarisHQ/monorepo#4358 feat(guard): hosting", in: issues, alone: false), issues)
    }

    func testTheOnlySourceOfAResultIsAllOfIt() {
        XCTAssertEqual(ReferenceParser.excerpt(for: "Something else", in: "Line one\nLine two", alone: true), "Line one\nLine two")
        XCTAssertNil(ReferenceParser.excerpt(for: "Something else", in: "Line one\nLine two", alone: false))
    }

    func testALongExcerptIsCutAtALine() {
        let long = (1...200).map { "Line number \($0) of the note" }.joined(separator: "\n")
        let excerpt = ReferenceParser.excerpt(for: "x", in: long, alone: true) ?? ""
        XCTAssertLessThanOrEqual(excerpt.count, ReferenceParser.excerptLimit + 2)
        XCTAssertTrue(excerpt.hasSuffix(" …"))
    }

    func testTheLedgerKeepsTheExcerptPerReference() async throws {
        let ledger = RetrievalLedger()
        let output = mails + "\n" + ReferenceParser.line(title: "Achterstallige rekening", url: nil, detail: "Vimexx")
            + "\n" + ReferenceParser.line(title: "Roadmap 2026-2027 Mindlinq", url: nil, detail: "Laura")
        _ = try await ledger.run(tool: "search_mail", input: ["query": "excerpt-test"]) { _ in output }
        XCTAssertEqual(ledger.references.count, 2)
        XCTAssertTrue(ledger.references[0].excerpt?.contains("infaris.com verloopt") == true)
        XCTAssertTrue(ledger.references[1].excerpt?.contains("roadmap door te nemen") == true)
    }

    func testAReferenceSavedBeforeExcerptsStillDecodes() throws {
        let old = #"{"number":2,"sourceID":"mail","title":"Hello","detail":"","url":null}"#
        let reference = try JSONDecoder().decode(SourceReference.self, from: Data(old.utf8))
        XCTAssertNil(reference.excerpt)
        XCTAssertEqual(reference.number, 2)
    }

    // MARK: The passage beside a sentence

    func testThePassageMarksTheLinesTheSentenceTookFrom() {
        let excerpt = ReferenceParser.excerpt(for: "Achterstallige rekening", in: mails, alone: false) ?? ""
        let lines = SourcePassage.pick(excerpt, claim: "Herinnering om de verlenging van infaris.com bij Vimexx te betalen")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].relevant, "\(lines)")
        XCTAssertTrue(lines[1].text.contains("infaris.com"))
    }

    func testThePassageLeavesOutTheTitleAndReadsTimesPlainly() {
        let lines = SourcePassage.pick("Retro | 2026-11-16T13:00:00+01:00 – 2026-11-16T14:00 | Heemskerk\nAgenda: sprint",
                                       claim: "retro om 13:00", title: "Retro")
        XCTAssertEqual(lines.map(\.text), ["2026-11-16 13:00 – 2026-11-16 14:00 · Heemskerk", "Agenda: sprint"])
        // Only the title as a whole word goes: "Retrospective" is not "Retro".
        XCTAssertEqual(SourcePassage.pick("Retrospective team", claim: "", title: "Retro").map(\.text), ["Retrospective team"])
    }

    func testAMailsLabelIsItsSender() {
        let mail = SourceReference(number: 1, sourceID: "mail", title: "Achterstallige rekening infaris.com", detail: "Vimexx · 2026-11-14")
        XCTAssertEqual(mail.sender, "Vimexx")
        let event = SourceReference(number: 2, sourceID: "calendar", title: "Retro", detail: "16 nov · Werk")
        XCTAssertNil(event.sender)
    }

    func testWithNothingInCommonThePassageIsTheStartUnmarked() {
        let lines = SourcePassage.pick("One\nTwo\nThree", claim: "zzzz")
        XCTAssertEqual(lines.map(\.text), ["One", "Two", "Three"])
        XCTAssertFalse(lines.contains { $0.relevant })
    }

    func testALongLineIsCutAroundTheMatch() {
        let line = String(repeating: "a ", count: 200) + "infaris.com verloopt" + String(repeating: " b", count: 200)
        let clipped = SourcePassage.clip(line, around: "infaris", width: 60)
        XCTAssertTrue(clipped.contains("infaris"))
        XCTAssertTrue(clipped.hasPrefix("…") && clipped.hasSuffix("…"))
    }

    // MARK: No list of sources in the answer

    func testASourcesLineWrittenByTheModelGoes() {
        let text = """
        Sources: [4] infaris.com: Achterstallige Rekening, Vimexx · [8] WhatsApp +31 6 19304231

        Het concept-antwoord aan Laura staat klaar [30].
        """
        XCTAssertEqual(Citations.withoutSourceList(text), "Het concept-antwoord aan Laura staat klaar [30].")
    }

    func testASourcesHeadingWithItsListGoes() {
        let text = "Klaar [1].\n\n**Bronnen:**\n- [1] Vimexx\n- [2] Agenda"
        XCTAssertEqual(Citations.withoutSourceList(text), "Klaar [1].")
        XCTAssertEqual(Citations.withoutSourceList("Klaar [1].\n\n## Sources\n\n[1] Vimexx"), "Klaar [1].")
    }

    func testOrdinaryTextAboutSourcesStays() {
        for text in ["Bronwater is gezond [2].", "Sources say the deadline moved [1].", "Bron: niets gevonden.", "## Sources\nNone of them answered."] {
            XCTAssertEqual(Citations.withoutSourceList(text), text)
        }
    }
}
