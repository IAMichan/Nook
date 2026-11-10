import XCTest

/// Search with AI: the searches from the brain's plan, the fallback without it, gathering hits and reading citations
/// (`SearchAI`).
final class SearchAITests: XCTestCase {
    private func hit(_ id: String, kind: SearchKind = .chat, text: String = "text") -> SearchHit {
        SearchHit(document: SearchDocument(id: id, kind: kind, title: id), score: 1, titleRanges: [], snippet: text,
                  snippetRanges: [], passage: SearchPassage(text: text, author: "Anna"), matches: 1)
    }

    func testQueriesFromPlan() {
        XCTAssertEqual(SearchAI.queries(fromPlan: #"Sure: {"queries": ["invoice anna", "factuur anna", "invoice anna", " "]}"#),
                       ["invoice anna", "factuur anna"])
        XCTAssertEqual(SearchAI.queries(fromPlan: "1. deploy friday\n- in:chats deploy\n"), ["deploy friday", "in:chats deploy"])
        let many = #"{"queries": ["a1", "a2", "a3", "a4", "a5"]}"#
        XCTAssertEqual(SearchAI.queries(fromPlan: many).count, SearchAI.maxQueries)
    }

    func testKeywordQueryDropsFiller() {
        XCTAssertEqual(SearchAI.keywordQuery("Wat zei Anna over de factuur?"), "zei OR anna OR factuur")
        XCTAssertEqual(SearchAI.keywordQuery("When did we deploy the hotfix"), "deploy OR hotfix")
        XCTAssertEqual(SearchAI.keywordQuery("what is the"), "")
        // A broad search finds a document with any of the words.
        let index = SearchIndex([SearchDocument(id: "chat:anna", kind: .chat, title: "Anna",
                                                passages: [SearchPassage(text: "De factuur is betaald")])])
        XCTAssertEqual(index.search(SearchQuery.parse(SearchAI.keywordQuery("Wat zei Anna over de factuur?"))).first?.id, "chat:anna")
    }

    func testLooksLikeQuestion() {
        XCTAssertTrue(SearchAI.looksLikeQuestion("deploy?"))
        XCTAssertTrue(SearchAI.looksLikeQuestion("wanneer heb ik de factuur gestuurd"))
        XCTAssertTrue(SearchAI.looksLikeQuestion("what did Anna say about dinner"))
        XCTAssertFalse(SearchAI.looksLikeQuestion("login bug"))
        XCTAssertFalse(SearchAI.looksLikeQuestion("what"))
    }

    func testGatherTakesTurnsWithoutRepeats() {
        let gathered = SearchAI.gather([[hit("a"), hit("b"), hit("c")], [hit("b"), hit("d"), hit("x", kind: .action)]], limit: 4)
        XCTAssertEqual(gathered.map(\.id), ["a", "b", "d", "c"])
    }

    func testAnswerPromptNumbersSourcesAndShields() {
        let prompt = SearchAI.answerPrompt(question: "Who pays?", sources: [hit("a", text: "I pay, mail me@x.com")],
                                           language: "Answer in Dutch.", shield: { $0.replacingOccurrences(of: "me@x.com", with: "[email]") })
        XCTAssertTrue(prompt.contains("Question: Who pays?"))
        XCTAssertTrue(prompt.contains("[1] chat · a"))
        XCTAssertTrue(prompt.contains("Anna: I pay, mail [email]"))
        XCTAssertFalse(prompt.contains("me@x.com"))
        XCTAssertTrue(prompt.hasSuffix("Answer in Dutch."))
    }

    func testCitations() {
        XCTAssertEqual(SearchAI.citations(in: "Anna pays [2], on Friday [1, 3]. Again [2]. Not [9] or [x].", count: 3), [2, 1, 3])
        XCTAssertEqual(SearchAI.citations(in: "[1]", count: 0), [])
        let sources = [hit("a"), hit("b"), hit("c")]
        XCTAssertEqual(SearchAI.ordered(sources, citing: [3, 1]).map(\.id), ["c", "a", "b"])
    }

    func testCleanAnswer() {
        XCTAssertEqual(SearchAI.clean("<think>hmm</think>\n Anna pays [1]. "), "Anna pays [1].")
        XCTAssertEqual(SearchAI.clean("```\nAnna pays\n```"), "Anna pays")
    }
}
