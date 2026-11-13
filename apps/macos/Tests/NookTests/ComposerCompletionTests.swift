import XCTest

final class ComposerCompletionTests: XCTestCase {
    func testTheChoiceRoundTrips() {
        let choices: [ComposerCompletion.Choice] = [
            .sameAsAutocomplete, .local("/Models/gemma.gguf"), .local("brain:qwen3-4b"),
            .api(provider: "openrouter", model: "anthropic/claude-haiku-5.5"), .api(provider: "ollama", model: ""),
        ]
        for choice in choices { XCTAssertEqual(ComposerCompletion.Choice(stored: choice.stored), choice) }
        XCTAssertEqual(ComposerCompletion.Choice(stored: "something odd"), .sameAsAutocomplete)
        XCTAssertEqual(ComposerCompletion.Choice(stored: "api:"), .sameAsAutocomplete)
    }

    func testAsksOnlyAtTheEndOfALineOfProse() {
        XCTAssertTrue(ComposerCompletion.asks(before: "Please fix the", after: ""))
        XCTAssertTrue(ComposerCompletion.asks(before: "Please fix the ", after: "\nsecond line"), "the end of its own line")
        XCTAssertFalse(ComposerCompletion.asks(before: "", after: ""))
        XCTAssertFalse(ComposerCompletion.asks(before: "   ", after: ""))
        XCTAssertFalse(ComposerCompletion.asks(before: "Please fix", after: " the bug"), "words after the caret")
        XCTAssertFalse(ComposerCompletion.asks(before: "first\n", after: ""), "a line just begun")
        XCTAssertFalse(ComposerCompletion.asks(before: "/comp", after: ""), "a command has its list")
        XCTAssertFalse(ComposerCompletion.asks(before: "look at @Log", after: ""), "a mention has its list")
        XCTAssertFalse(ComposerCompletion.asks(before: "see #12", after: ""))
        XCTAssertTrue(ComposerCompletion.asks(before: "look at @Log ", after: ""), "a finished mention")
    }

    func testTheContextNamesTheRecipientAndCarriesTheLastAnswer() {
        let situation = ComposerCompletion.Situation(recipient: "Claude Code", project: "nook",
                                                     lastAnswer: String(repeating: "x", count: 3_000) + "Shall I also add tests?")
        let input = ComposerCompletion.context(before: "Yes, and", after: "", situation: situation, hint: "Answer the agent")
        XCTAssertEqual(input.windowTitle, "Message to Claude Code about nook")
        XCTAssertEqual(input.appName, "Nook")
        XCTAssertEqual(input.screenText?.count, ComposerCompletion.answerLength)
        XCTAssertTrue(input.screenText?.hasSuffix("Shall I also add tests?") ?? false)
        XCTAssertEqual(input.fieldHint, "Answer the agent")
    }

    func testTheAPIPromptEndsWithTheTextToWriteBack() {
        let prompt = ComposerCompletion.apiPrompt(before: "Can you", situation: .init(recipient: "Codex", lastAnswer: "Done."),
                                                  instructions: ["Write in English", " "])
        XCTAssertTrue(prompt.hasSuffix("TEXT:\nCan you"))
        XCTAssertTrue(prompt.contains("(message to Codex)"))
        XCTAssertTrue(prompt.contains("Write in English"))
        XCTAssertTrue(prompt.contains("Done."))
    }

    func testTheContinuationKeepsTheSpaceOrItsAbsence() {
        XCTAssertEqual(ComposerCompletion.continuation(of: "Can you run the tests", before: "Can you"), " run the tests")
        XCTAssertEqual(ComposerCompletion.continuation(of: "Please implement the parser", before: "Please imple"), "ment the parser")
        // The API took the typed space off its answer.
        XCTAssertEqual(ComposerCompletion.continuation(of: "Can you run the tests", before: "Can you "), "run the tests")
        XCTAssertEqual(ComposerCompletion.continuation(of: "\"Can you run it\"", before: "Can you"), " run it", "quotes around it")
        XCTAssertEqual(ComposerCompletion.continuation(of: "```\nCan you run it\n```", before: "Can you"), " run it\n", "a code fence")
        XCTAssertNil(ComposerCompletion.continuation(of: "Can you", before: "Can you"), "only written back")
        XCTAssertNil(ComposerCompletion.continuation(of: "Sure! Here is a continuation.", before: "Can you"), "something else")
        // Written back with a small change at the start: the last words are found.
        XCTAssertEqual(ComposerCompletion.continuation(of: "can you check the build log first", before: "Can you check the build"),
                       " log first")
    }

    func testTheClippedTextIsWhatTheAPIWritesBack() {
        let long = String(repeating: "word ", count: 200) + "and then"
        let typed = ComposerCompletion.apiText(long)
        XCTAssertEqual(typed.count, ComposerCompletion.apiTextLength)
        XCTAssertEqual(ComposerCompletion.continuation(of: typed + " we ship it", before: long), " we ship it")
    }

    func testTypingThroughOrTakingAWordCarriesTheRest() {
        let suggestion = CompletionSuggestion(" run the tests")
        XCTAssertEqual(ComposerCompletion.carried(suggestion, inserted: " ru")?.remaining, "n the tests")
        XCTAssertEqual(ComposerCompletion.carried(suggestion, inserted: " run")?.remaining, " the tests")
        XCTAssertNil(ComposerCompletion.carried(suggestion, inserted: " walk"), "typed something else")
        XCTAssertNil(ComposerCompletion.carried(suggestion, inserted: " run the tests"), "nothing left")
    }
}
