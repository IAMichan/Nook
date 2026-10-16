import XCTest

/// Nook's own research before the model answers: which words it searches with, where it searches, and which hits it
/// opens in full. All tool output here is written by hand in the format the real tools use; nothing touches a Mac app.
final class ResearchTests: XCTestCase {
    private let available: [Prefetch.Available] = [
        .init(name: "search_notes", source: "notes", required: ["query"], query: "query"),
        .init(name: "list_notes", source: "notes", required: []),
        .init(name: "read_note", source: "notes", required: ["identifier"]),
        .init(name: "search_mail", source: "mail", required: ["query"], query: "query"),
        .init(name: "inbox_mail", source: "mail", required: []),
        .init(name: "read_mail", source: "mail", required: ["id"]),
        .init(name: "search_files", source: "files", required: ["query"], query: "query"),
        .init(name: "read_file", source: "files", required: ["path"]),
        .init(name: "search_web", source: "web", required: ["query"], query: "query"),
        .init(name: "search_contacts", source: "contacts", required: ["query"], query: "query"),
        .init(name: "list_events", source: "calendar", required: ["from", "to"])
    ]
    private let active: Set<String> = ["calendar", "reminders", "loops", "notes", "mail", "files", "web", "contacts"]

    // MARK: Terms

    func testTermsKeepOnlyTheWordsThatCarryTheQuestion() {
        XCTAssertEqual(Research.terms(in: "Wat staat er in mijn notitie over de verbouwing?").words, ["verbouwing"])
        let lisa = Research.terms(in: "Wat zei Lisa in haar mail over de offerte voor de keuken?")
        XCTAssertEqual(lisa.words, ["lisa", "offerte", "keuken"], "names first, then the most specific words")
        XCTAssertEqual(lisa.names, ["Lisa"])
        XCTAssertEqual(Research.terms(in: "What did Tom write about the launch plan?").words, ["tom", "launch", "plan"])
    }

    func testDatesTimesAndFillerAreNoSearchTerms() {
        XCTAssertEqual(Research.terms(in: "Wat moet ik morgen om 14:30 doen voor Apollo?").words, ["apollo"])
        XCTAssertTrue(Research.terms(in: "Welke notities heb ik?").isEmpty)
        XCTAssertEqual(Research.terms(in: "Zoek factuur 20251043 in mijn mail").words, ["20251043", "factuur"])
    }

    func testApostrophesAreNoQuotes() {
        let terms = Research.terms(in: "Wat staat er in m'n notitie over Jan's verbouwing?")
        XCTAssertTrue(terms.phrases.isEmpty)
        XCTAssertTrue(terms.words.contains("verbouwing"))
    }

    func testQuotedPhrasesStayWhole() {
        let terms = Research.terms(in: "Zoek mijn notitie \"plan van aanpak\"")
        XCTAssertEqual(terms.phrases, ["plan van aanpak"])
        XCTAssertTrue(terms.query().hasPrefix("plan van aanpak"))
    }

    func testFollowUpKeepsWhatTheConversationWasAbout() {
        let history = [ChatTurn(fromUser: true, text: "Wat staat er in mijn notitie over de verbouwing?"),
                       ChatTurn(fromUser: false, text: "In je notitie Verbouwing keuken staat de offerte van Jansen.")]
        let terms = Research.terms(in: "En het budget?", history: history)
        XCTAssertEqual(terms.words, ["budget", "verbouwing"], "the new word first, then the earlier ones")
        XCTAssertTrue(terms.inherited)
        // A new question with enough words of its own does not drag the old topic along.
        XCTAssertFalse(Research.terms(in: "Wat zei Lisa over de offerte voor de keuken?", history: history).inherited)
    }

    // MARK: Where to search

    func testAQuestionThatNamesNoSourceIsSearchedEverywhere() {
        let question = "Wat weet ik over project Apollo?"
        let sources = Research.sources(question: question, intent: ChatIntent.detect(question), terms: Research.terms(in: question),
                                       relevant: ["calendar"], available: available, active: active)
        XCTAssertEqual(sources, ["calendar", "notes", "mail", "files", "contacts"], "not the web: the user's own data first")
    }

    func testACommandIsNotSearchedEverywhere() {
        let question = "Zet de muziek wat zachter"
        let sources = Research.sources(question: question, intent: ChatIntent.detect(question), terms: Research.terms(in: question),
                                       relevant: ["calendar"], available: available, active: active)
        XCTAssertEqual(sources, ["calendar"])
    }

    func testAFollowUpSearchesWhereTheQuestionBeforeLooked() {
        let history = [ChatTurn(fromUser: true, text: "Wat staat er in mijn notitie over de verbouwing?")]
        let question = "En het budget?"
        let sources = Research.sources(question: question, intent: ChatIntent.detect(question),
                                       terms: Research.terms(in: question, history: history),
                                       relevant: ["calendar"], previous: ["calendar", "notes"], available: available, active: active)
        XCTAssertTrue(sources.contains("notes"))
    }

    func testANamedSourceIsNeverReplacedBySearchingEverywhere() {
        let question = "Wat staat er in Bear over Apollo?"
        let sources = Research.sources(question: question, intent: ChatIntent.detect(question), terms: Research.terms(in: question),
                                       relevant: ["calendar"], named: ["bear"], available: available, active: active)
        XCTAssertEqual(sources, ["calendar"], "Bear cannot be read: no searching notes, mail and files for the word instead")
    }

    func testLookupsSearchWithTheTermsInsteadOfListingTheNewest() {
        let question = "Wat zei Lisa over de offerte?"
        let calls = Research.lookups(question: question, terms: Research.terms(in: question), sources: ["calendar", "notes", "mail"], available: available)
        XCTAssertEqual(calls.map(\.tool), ["search_notes", "search_mail"])
        XCTAssertEqual(calls.first?.input["query"] as? String, "lisa offerte")
    }

    func testWithoutTermsTheSourceOverviewIsUsed() {
        let question = "Welke notities heb ik?"
        let calls = Research.lookups(question: question, terms: Research.terms(in: question), sources: ["notes"], available: available)
        XCTAssertEqual(calls.map(\.tool), ["list_notes"])
    }

    func testUnreadMailGetsTheInboxNextToTheSearch() {
        let question = "Heb ik nog ongelezen mail van Lisa?"
        let calls = Research.lookups(question: question, terms: Research.terms(in: question), sources: ["mail"], available: available)
        XCTAssertEqual(calls.map(\.tool).first, "search_mail")
        XCTAssertEqual(calls.count, 2, "the search plus the inbox overview")
    }

    func testContactsAreOnlySearchedForAName() {
        let terms = Research.terms(in: "wat is het nummer van de loodgieter?")
        XCTAssertNil(Research.search(source: "contacts", terms: terms, question: "", available: available))
        let named = Research.terms(in: "Wat is het nummer van Lisa?")
        XCTAssertEqual(Research.search(source: "contacts", terms: named, question: "", available: available)?.input["query"] as? String, "Lisa")
    }

    func testOnlyToolsWithASearchFieldCountAsSearch() {
        XCTAssertTrue(Research.isSearch(.init(name: "mcp_search", source: "linear", required: ["query"], query: "query")))
        XCTAssertFalse(Research.isSearch(.init(name: "list_notes", source: "notes", required: [])))
        XCTAssertFalse(Research.isSearch(.init(name: "read_file", source: "files", required: ["path"])))
        XCTAssertFalse(Research.isSearch(.init(name: "mcp_get", source: "linear", required: ["query", "team"], query: "query")))
    }

    func testQueryFieldIsFoundInASchema() {
        XCTAssertEqual(Prefetch.Available.queryField(["type": "object", "properties": ["q": ["type": "string"]]]), "q")
        XCTAssertNil(Prefetch.Available.queryField(["type": "object", "properties": ["path": ["type": "string"]]]))
    }

    // MARK: What to open

    private let longBody = String(repeating: "De keuken wordt in november verbouwd. ", count: 30)

    func testHitsOfEverySourceKnowHowToOpen() {
        let note = Research.hits(in: "### Verbouwing keuken [map: Huis] | 2026-10-01 [id: x-coredata://ABC/ICNote/p12]\n\(longBody)", tool: "search_notes")
        XCTAssertEqual(note.first?.title, "Verbouwing keuken")
        XCTAssertEqual(note.first?.read, "read_note")
        XCTAssertEqual(note.first?.input["identifier"] as? String, "x-coredata://ABC/ICNote/p12")

        let mail = Research.hits(in: "### Offerte verbouwing | from Jansen <info@jansen.nl> | 2026-10-02 [id: abc@jansen.nl]\n\(longBody)", tool: "search_mail")
        XCTAssertEqual(mail.first?.title, "Offerte verbouwing")
        XCTAssertEqual(mail.first?.input["id"] as? String, "abc@jansen.nl")

        let files = Research.hits(in: "~/Documents/Offerte keuken.pdf\n~/Pictures/keuken.jpg", tool: "search_files")
        XCTAssertEqual(files.map(\.read), ["read_file", nil], "a photo has no text to read")

        let github = Research.hits(in: "3 results, 3 most recently updated:\n- IAMichan/nook#12 [issue, open] 'Launch checklist' · updated 1 okt", tool: "github_search")
        XCTAssertEqual(github.first?.input["repo"] as? String, "IAMichan/nook")
        XCTAssertEqual(github.first?.input["number"] as? Int, 12)
        XCTAssertEqual(github.first?.title, "Launch checklist")

        let notion = Research.hits(in: "- Roadmap Q4 (id 1234abcd-1234-1234-1234-1234567890ab) · edited 1 okt", tool: "notion_search")
        XCTAssertEqual(notion.first?.title, "Roadmap Q4")
        XCTAssertEqual(notion.first?.input["page"] as? String, "1234abcd-1234-1234-1234-1234567890ab")

        let web = Research.hits(in: "### Weer Amsterdam\nhttps://weer.example/amsterdam\nZonnig, 18 graden", tool: "search_web")
        XCTAssertEqual(web.first?.input["url"] as? String, "https://weer.example/amsterdam")
    }

    func testTheBestMatchesAcrossSourcesAreOpened() {
        let notes = """
        ### Boodschappen | 2026-10-15 [id: n1]
        melk, eieren

        ### Verbouwing keuken [map: Huis] | 2026-10-01 [id: n2]
        \(longBody) Het budget is 15.000 euro.
        """
        let mail = "### Offerte verbouwing | from Jansen | 2026-10-02 [id: m1]\n\(longBody)"
        let readers: Set<String> = ["read_note", "read_mail", "read_file"]
        let terms = Research.Terms(words: ["verbouwing", "budget"])
        let open = Research.toOpen([("search_notes", notes), ("search_mail", mail)], terms: terms, wantsContent: false, available: readers, limit: 3)
        XCTAssertEqual(open.map(\.title), ["Verbouwing keuken", "Offerte verbouwing"], "a note without the words is not opened")
        XCTAssertEqual(open.first?.input["identifier"] as? String, "n2")
    }

    func testAShortHitIsNotOpenedAgain() {
        let notes = "### Verbouwing | 2026-10-01 [id: n2]\nBudget 15.000 euro."
        let open = Research.toOpen([("search_notes", notes)], terms: Research.Terms(words: ["verbouwing"]), wantsContent: false,
                                   available: ["read_note"], limit: 3)
        XCTAssertTrue(open.isEmpty, "the search already showed the whole note")
    }

    func testNoReadToolNoOpening() {
        let mail = "### Offerte verbouwing | from Jansen | 2026-10-02 [id: m1]\n\(longBody)"
        XCTAssertTrue(Research.toOpen([("search_mail", mail)], terms: Research.Terms(words: ["verbouwing"]), wantsContent: false,
                                      available: ["read_note"], limit: 3).isEmpty)
    }

    func testReadingTheNewestWhenAskedForItsContent() {
        let list = "Recente notities in Apple Notities:\n- Boodschappen (Huis) — gewijzigd 2026-10-15 [id: n1]\n- Werk — gewijzigd 2026-10-14 [id: n2]"
        let open = Research.toOpen([("list_notes", list)], terms: Research.Terms(), wantsContent: true, available: ["read_note"], limit: 2)
        XCTAssertEqual(open.map { $0.input["identifier"] as? String }, ["n1"])
        XCTAssertTrue(Research.toOpen([("list_notes", list)], terms: Research.Terms(), wantsContent: false, available: ["read_note"], limit: 2).isEmpty)
        XCTAssertTrue(Research.wantsContent("Lees mijn laatste notitie voor"))
    }

    func testRankingKeepsTheSourceOrderForEqualMatches() {
        let chunks = ["Boodschappen melk", "Verbouwing keuken budget", "Keuken ideeën", "Verbouwing badkamer"]
        let best = Research.best(chunks, terms: Research.Terms(words: ["verbouwing", "keuken"]), keep: 3, title: { $0 }, text: { _ in "" })
        XCTAssertEqual(best, ["Verbouwing keuken budget", "Keuken ideeën", "Verbouwing badkamer"])
    }

    func testMatchingIgnoresCaseAndAccents() {
        XCTAssertGreaterThan(Research.score(title: "Café De Kroon", text: "", terms: Research.Terms(words: ["cafe"])), 0)
    }

    func testSearchesComeWithTheirReader() {
        XCTAssertEqual(Research.companions(of: ["search_notes", "search_mail", "read_note"]), ["read_mail"])
        XCTAssertEqual(Research.companions(of: ["search_reminders"]), [])
    }

    // MARK: Lookups in a question

    func testWhatCountsAsALookup() {
        XCTAssertTrue(Research.isLookup("Wat weet ik over Apollo?"))
        XCTAssertTrue(Research.isLookup("zoek de offerte van Jansen"))
        XCTAssertTrue(Research.isLookup("Vat mijn notities over de verbouwing samen"))
        XCTAssertFalse(Research.isLookup("Zet de muziek wat zachter"))
    }

    func testReadingNotesIsNotMakingOne() {
        XCTAssertNil(ChatIntent.detect("Maak een samenvatting van mijn notities over de verbouwing").primaryAction)
        XCTAssertEqual(ChatIntent.detect("Zet de samenvatting van mijn mail in een notitie").primaryAction, "create_note")
        XCTAssertEqual(ChatIntent.detect("Maak een notitie: boodschappen melk en eieren").primaryAction, "create_note")
    }
}

/// Seeing only what is about the question, and opening hits of sources Nook does not know (MCP servers).
final class ResearchGroundingTests: XCTestCase {
    func testUnrelatedResultsAreLeftOut() {
        let output = """
        ### Verbouwing keuken | 2026-10-01 [id: n1]
        Offerte van Jansen.

        ### Recept appeltaart | 2026-09-01 [id: n2]
        - appels
        - kaneel

        Sources in this result (cite using the bracketed number, e.g. [1]):
        [1] Verbouwing keuken
        """
        let kept = Research.relevantOnly(output, tool: "search_notes", terms: Research.Terms(words: ["verbouwing"]))
        XCTAssertTrue(kept.contains("Verbouwing keuken"))
        XCTAssertFalse(kept.contains("appeltaart"))
        XCTAssertFalse(kept.contains("kaneel"), "the list inside a dropped note goes with it")
        XCTAssertTrue(kept.contains("[1] Verbouwing keuken"), "the numbered sources stay")
        let none = Research.relevantOnly(output, tool: "search_notes", terms: Research.Terms(words: ["vakantie"]))
        XCTAssertTrue(none.hasPrefix("(2 results, none of them about"), none)
    }

    func testAppTextKeepsThePartsAboutTheQuestion() {
        let window = (0..<200).map { "regel \($0)" }.joined(separator: "\n") + "\nJan: de offerte is goedgekeurd\n" + (0..<200).map { "rest \($0)" }.joined(separator: "\n")
        let focused = Research.focus(window, terms: Research.Terms(words: ["offerte"]), limit: 600)
        XCTAssertTrue(focused.contains("Jan: de offerte is goedgekeurd"))
        XCTAssertTrue(focused.contains("regel 0"), "the first line names the window")
        XCTAssertFalse(focused.contains("regel 100"))
    }

    func testMCPHitsAreOpenedWithTheServersReadTool() {
        let available: [Prefetch.Available] = [
            .init(name: "mcp_linear_search_issues", source: "mcp.linear", required: ["query"], query: "query"),
            .init(name: "mcp_linear_get_issue", source: "mcp.linear", required: ["id"])
        ]
        let openers = Research.openers(available)
        XCTAssertEqual(openers["mcp_linear_search_issues"], Research.Opener(tool: "mcp_linear_get_issue", field: "id"))

        let json = #"{"issues": [{"id": "ENG-12", "title": "Offerte module", "state": "open"}, {"id": "ENG-13", "title": "Login bug"}]}"#
        let open = Research.toOpen([("mcp_linear_search_issues", json)], terms: Research.Terms(words: ["offerte"]), wantsContent: false,
                                   available: ["mcp_linear_get_issue"], limit: 3, openers: openers)
        XCTAssertEqual(open.map { $0.input["id"] as? String }, ["ENG-12"])

        let lines = "- Offerte module (id: ENG-12)\n- Login bug (id: ENG-13)"
        let fromText = Research.genericHits(in: lines, tool: "mcp_linear_search_issues", opener: Research.Opener(tool: "mcp_linear_get_issue", field: "id"))
        XCTAssertEqual(fromText.map { $0.input["id"] as? String }, ["ENG-12", "ENG-13"])
    }

    func testChatsAreOpenedAtThePassageAboutTheQuestion() {
        let output = "### Jan | 2026-10-01 [chat: 7]\n- 2026-10-01 10:00 · Jan: de offerte komt morgen"
        let open = Research.toOpen([("search_messages", output)], terms: Research.Terms(words: ["offerte"]), wantsContent: false,
                                   available: ["read_messages"], limit: 2)
        XCTAssertEqual(open.first?.input["chat"] as? String, "7")
        XCTAssertEqual(open.first?.input["query"] as? String, "offerte")
    }

    // MARK: Asking about one app

    private let chatTools: [Prefetch.Available] = [
        .init(name: "search_whatsapp", source: "whatsapp", required: ["query"], query: "query"),
        .init(name: "whatsapp_open_chats", source: "whatsapp", required: []),
        .init(name: "read_whatsapp", source: "whatsapp", required: ["chat"])
    ]

    func testSourceNamesAndStatusWordsAreNoSearchTerms() {
        XCTAssertTrue(Research.terms(in: "Heb ik chats openstaan in whatsapp").isEmpty, "the question says where to look, not what to look for")
        XCTAssertTrue(Research.terms(in: "Do I have unanswered WhatsApp chats?").isEmpty)
        XCTAssertEqual(Research.terms(in: "Wat appte Lisa in WhatsApp over de offerte?").words, ["lisa", "offerte"])
    }

    func testOpenChatsAreListedNotSearched() {
        let question = "Heb ik chats openstaan in whatsapp"
        let calls = Research.lookups(question: question, terms: Research.terms(in: question), sources: ["whatsapp"], available: chatTools)
        XCTAssertEqual(calls.map(\.tool), ["whatsapp_open_chats"])
        // A question about a person in WhatsApp still searches.
        let lisa = "Wat appte Lisa over de offerte?"
        XCTAssertEqual(Research.lookups(question: lisa, terms: Research.terms(in: lisa), sources: ["whatsapp"], available: chatTools).map(\.tool),
                       ["search_whatsapp"])
    }

    func testOpenChatsOpenTheChatWhenAskedForItsContent() {
        let output = "## WhatsApp: open chats (last 14 days, 5 chats checked)\n### Jan | 2026-10-15 [chat: 12]\n- 2 unread · newest message 2026-10-15 09:00 from Jan: kom je morgen?"
        let open = Research.toOpen([("whatsapp_open_chats", output)], terms: Research.Terms(), wantsContent: true, available: ["read_whatsapp"], limit: 2)
        XCTAssertEqual(open.first?.read, "read_whatsapp")
        XCTAssertEqual(open.first?.input["chat"] as? String, "12")
    }

    func testOpenChatsComeFirstForAQuestionAboutWhatIsOpen() {
        XCTAssertTrue(Prefetch.prefersListing("whatsapp", "heb ik nog chats openstaan"))
        XCTAssertTrue(Prefetch.prefersListing("messages", "who is waiting for my reply?"))
        XCTAssertFalse(Prefetch.prefersListing("whatsapp", "wat appte Lisa over de offerte"))
        XCTAssertTrue(ChatIntent.detect("Heb ik chats openstaan in whatsapp").tools.contains("whatsapp_open_chats"))
    }
}
