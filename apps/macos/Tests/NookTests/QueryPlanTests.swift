import XCTest

/// The brain's reading of a question before the research: parsing its plan and turning that plan into lookups.
/// The model's replies here are written by hand; no model runs.
final class QueryPlanTests: XCTestCase {
    private let available: [Prefetch.Available] = [
        .init(name: "search_whatsapp", source: "whatsapp", required: ["query"], query: "query"),
        .init(name: "whatsapp_open_chats", source: "whatsapp", required: []),
        .init(name: "read_whatsapp", source: "whatsapp", required: ["chat"]),
        .init(name: "search_mail", source: "mail", required: ["query"], query: "query"),
        .init(name: "inbox_mail", source: "mail", required: []),
        .init(name: "search_files", source: "files", required: ["query"], query: "query"),
        .init(name: "read_file", source: "files", required: ["path"])
    ]
    private let known: Set<String> = ["whatsapp", "mail", "files", "notes"]

    func testAPlanIsReadFromTheReply() {
        let reply = """
        ```json
        {"goal": "Which WhatsApp chats are unread or wait for a reply", "kind": "listing", "sources": ["whatsapp", "slack"], "queries": []}
        ```
        """
        let plan = QueryPlanner.parse(reply, known: known)
        XCTAssertEqual(plan?.kind, .listing)
        XCTAssertEqual(plan?.sources, ["whatsapp"], "a source Nook does not have is dropped")
        XCTAssertEqual(plan?.goal, "Which WhatsApp chats are unread or wait for a reply")
    }

    func testANameInsteadOfAnIdStillCounts() {
        let plan = QueryPlanner.parse(#"{"goal": "x", "kind": "lookup", "sources": ["WhatsApp", "Mail"], "queries": ["offerte"]}"#, known: known)
        XCTAssertEqual(plan?.sources, ["whatsapp", "mail"])
    }

    func testNoJSONNoPlan() {
        XCTAssertNil(QueryPlanner.parse("Ja, je hebt chats openstaan.", known: known))
        XCTAssertEqual(QueryPlanner.parse(#"{"goal": "x", "kind": "weird"}"#, known: known)?.kind, .lookup, "an unknown kind is a lookup")
    }

    func testAListingAsksTheSourceForWhatIsOpen() {
        let plan = QueryPlan(goal: "open chats", kind: .listing, sources: ["whatsapp"], queries: [])
        let calls = QueryPlanner.lookups(plan, question: "Heb ik chats openstaan in whatsapp", available: available)
        XCTAssertEqual(calls.map(\.tool), ["whatsapp_open_chats"], "no search in files for the word whatsapp")
    }

    func testEveryQueryIsTriedInEveryPlannedSource() {
        let plan = QueryPlan(goal: "what Lisa said about the quote", kind: .lookup, sources: ["whatsapp", "mail"], queries: ["Lisa offerte", "prijsopgave"])
        let calls = QueryPlanner.lookups(plan, question: "wat zei Lisa over de offerte?", available: available)
        XCTAssertEqual(calls.map(\.tool), ["search_whatsapp", "search_whatsapp", "search_mail", "search_mail"])
        XCTAssertEqual(calls.last?.input["query"] as? String, "prijsopgave", "the synonym the model thought of is searched too")
    }

    func testAPlanGivesTheTermsToRankWith() {
        let terms = QueryPlan(goal: "", kind: .lookup, sources: [], queries: ["Lisa offerte", "keuken"]).terms
        XCTAssertTrue(terms.words.contains("offerte"))
        XCTAssertTrue(terms.words.contains("keuken"))
        XCTAssertEqual(terms.names, ["Lisa"])
    }

    func testThePromptListsWhatEachSourceCanDo() {
        let prompt = QueryPlanner.prompt(question: "Heb ik chats openstaan?", history: [],
                                         sources: [.init(id: "whatsapp", title: "WhatsApp", canSearch: true, canList: true)])
        XCTAssertTrue(prompt.contains("- whatsapp — WhatsApp: search, newest/unread/open items"), prompt)
        XCTAssertTrue(prompt.hasSuffix("Question: Heb ik chats openstaan?\nJSON:"))
    }

    // MARK: Files worth showing

    func testBuildOutputIsLeftOutAndDocumentsComeFirst() {
        let paths = ["/Users/dev/Code/ExampleApp/apps/app/dist/assets/index-BRcVVYD8.js",
                     "/Users/dev/Code/Nook/Services/Connectors/AppConnectors.swift",
                     "/Users/dev/Documents/Project Proposal.pdf",
                     "/Users/dev/Code/Nook/docs/ASSISTANT.md"]
        XCTAssertEqual(Research.rankFiles(paths), ["/Users/dev/Documents/Project Proposal.pdf", "/Users/dev/Code/Nook/docs/ASSISTANT.md",
                                                   "/Users/dev/Code/Nook/Services/Connectors/AppConnectors.swift"])
        XCTAssertEqual(Research.rankFiles(paths, codeFirst: true).first, "/Users/dev/Code/Nook/Services/Connectors/AppConnectors.swift")
    }
}
