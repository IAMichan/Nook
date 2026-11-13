import XCTest

final class ComposerInlineNameTests: XCTestCase {
    private let models: [ModelMention.Candidate] = [
        .init(agent: "claude", agentName: "Claude Code", model: "opus-4-7", name: "Claude Opus 4.7"),
        .init(agent: "claude", agentName: "Claude Code", model: "sonnet-5", name: "Claude Sonnet 5"),
        .init(agent: "codex", agentName: "Codex", model: "gpt-6-sol", name: "GPT-6 Sol"),
        .init(agent: "codex", agentName: "Codex", model: "gpt-5.3-codex-spark", name: "GPT-5.3 Codex Spark"),
        // The same name under another agent: the first agent keeps it.
        .init(agent: "cursor", agentName: "Cursor", model: "opus", name: "Claude Opus 4.7"),
    ]
    private var candidates: [ComposerInlineName.Candidate] { ComposerInlineName.candidates(models: models) }

    private func match(_ text: String, caret: Int? = nil) -> ComposerInlineName.Match? {
        ComposerInlineName.match(in: text, caret: caret ?? text.utf16.count, candidates: candidates)
    }

    func testAWordOfTheNameFromTheThirdLetter() {
        XCTAssertNil(match("op"), "two letters are ordinary words")
        let found = match("have opu")
        XCTAssertEqual(found?.remainder, "s 4.7")
        XCTAssertEqual(found?.typed, "opu")
        XCTAssertEqual(found?.start, 5)
        XCTAssertEqual(found?.candidate.ref.id, "claude/opus-4-7")
        XCTAssertEqual(match("Clau")?.remainder, "de Opus 4.7", "from the start of the name too")
        XCTAssertEqual(match("SONN")?.remainder, "et 5", "case does not matter; the name keeps its own")
    }

    func testTheLongestRunOfWordsWins() {
        // "gpt-6 s" runs over two words; the hyphen splits words in the name, not in the message.
        let found = match("ask gpt-6 s")
        XCTAssertEqual(found?.typed, "gpt-6 s")
        XCTAssertEqual(found?.remainder, "ol")
        XCTAssertEqual(match("use codex sp")?.remainder, "ark")
    }

    func testAFullyTypedNameShowsWhichOneInBrackets() {
        XCTAssertEqual(match("try opus 4.7")?.remainder, " (Claude Opus 4.7)")
        XCTAssertNil(match("Claude Sonnet 5"), "typed from its first letter to its last: nothing left to show")
    }

    func testOnlyAtTheEndOfAWordAndOutsideTheLists() {
        XCTAssertNil(match("opu "), "after a space")
        XCTAssertNil(match("opux"), "no name goes on like this")
        XCTAssertNil(match("opus later", caret: 3), "the caret inside a word")
        XCTAssertEqual(match("opu later", caret: 3)?.remainder, "s 4.7", "before a space is the end of a word")
        XCTAssertNil(match("@opu"), "the @ list has it")
        XCTAssertNil(match("/sonn"), "a command line")
        XCTAssertNil(match("$sonn"))
        XCTAssertNil(match("123"), "a name starts with a letter")
        XCTAssertEqual(match("first line\n(sonn")?.typed, "sonn", "after a bracket, on its own line")
    }

    func testTabPutsTheChipWhereTheWordsWere() {
        let text = "have opu do it"
        guard let found = match(text, caret: 8) else { return XCTFail("no name") }
        let accepted = found.accepting(in: text)
        let link = ContextRefs.link(ModelMention.ref(models[0]))
        XCTAssertEqual(accepted.text, "have " + link + " do it")
        XCTAssertEqual(accepted.caret, ("have " + link + " ").utf16.count)
        XCTAssertNil(found.accepting(in: "something else entirely").caret, "text that changed is left alone")
    }

    func testEachNameOnce() {
        XCTAssertEqual(candidates.map(\.label), ["Claude Opus 4.7", "Claude Sonnet 5", "GPT-6 Sol", "GPT-5.3 Codex Spark"])
    }
}
