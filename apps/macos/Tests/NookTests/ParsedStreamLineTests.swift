import XCTest

/// Agent output is parsed on the queue that read it, with the same parsers as before, so the main thread only applies
/// the events.
final class ParsedStreamLineTests: XCTestCase {
    func testEachAgentGetsItsOwnParser() {
        let claude = #"{"type":"system","subtype":"init","session_id":"s1","model":"claude-opus"}"#
        XCTAssertEqual(ParsedStreamLine.parse(claude, provider: .claude), .claude(ClaudeStreamParser.parse(claude)))
        let codex = #"{"type":"thread.started","thread_id":"t1"}"#
        XCTAssertEqual(ParsedStreamLine.parse(codex, provider: .codex), .codex(CodexStreamParser.parse(codex)))
        let gemini = #"{"type":"init","session_id":"g1","model":"gemini-2.5-pro"}"#
        XCTAssertEqual(ParsedStreamLine.parse(gemini, provider: .gemini), .gemini(GeminiStreamParser.parse(gemini)))
        for provider in [RunProvider.opencode, .cursor, .grok, .antigravity, .acp] {
            XCTAssertEqual(ParsedStreamLine.parse(claude, provider: provider), .none, "ACP agents read their own messages")
        }
    }

    func testABatchKeepsItsOrder() {
        let lines = ["not json", #"{"type":"thread.started","thread_id":"t1"}"#, ""]
        XCTAssertEqual(ParsedStreamLine.parse(lines, provider: .codex), lines.map { .codex(CodexStreamParser.parse($0)) })
    }
}
