import XCTest

final class SessionSuggestionTests: XCTestCase {
    func testParseNeedsAPromptAndTidiesTheRest() throws {
        guard case .failure = SessionSuggestion.parse(["title": "Only a title"]) else { return XCTFail("a prompt is needed") }
        guard case .success(let value) = SessionSuggestion.parse([
            "title": "Bring the server\nto parity", "prompt": "  Port the three features.  ",
            "summary": "The Mac learned\nthree things.", "agent": "codex", "worktree": true
        ]) else { return XCTFail("valid arguments") }
        XCTAssertEqual(value.title, "Bring the server to parity")
        XCTAssertEqual(value.prompt, "Port the three features.")
        XCTAssertEqual(value.summary, "The Mac learned three things.")
        XCTAssertEqual(value.agent, "codex")
        XCTAssertEqual(value.worktree, true)
    }

    func testTitleFallsBackToThePrompt() {
        guard case .success(let value) = SessionSuggestion.parse(["prompt": "Fix the flaky login test\nIt fails on CI."]) else {
            return XCTFail("valid arguments")
        }
        XCTAssertEqual(value.title, "Fix the flaky login test It fails on CI.")
        XCTAssertNil(value.worktree)
    }

    func testTooLongPromptIsRefused() {
        let prompt = String(repeating: "x", count: SessionSuggestion.maxPromptBytes + 1)
        guard case .failure = SessionSuggestion.parse(["prompt": prompt]) else { return XCTFail("too long") }
    }

    func testEventRoundTrip() {
        let suggestion = SessionSuggestion(title: "T", prompt: "Do it", summary: "S", agent: "", worktree: false)
        let event = suggestion.event()
        XCTAssertEqual(event.kind, .system)
        XCTAssertEqual(event.state, .pending)
        XCTAssertEqual(SessionSuggestion(event: event), suggestion)
        XCTAssertNil(SessionSuggestion(event: RunEvent(kind: .system, text: "T", tool: "handoff", detail: event.detail)))
    }

    func testChoicesSetTheCardState() {
        XCTAssertEqual(SessionSuggestion.state(after: .start), .done)
        XCTAssertEqual(SessionSuggestion.state(after: .here), .allowed)
        XCTAssertEqual(SessionSuggestion.state(after: .dismiss), .denied)
        XCTAssertNil(SessionSuggestion.state(after: .options))
    }

    func testAgentsByIdOrName() {
        XCTAssertEqual(RunProvider.named("CODEX"), .codex)
        XCTAssertEqual(RunProvider.named(RunProvider.claude.displayName), .claude)
        XCTAssertNil(RunProvider.named(""))
        XCTAssertNil(RunProvider.named("nope"))
    }
}
