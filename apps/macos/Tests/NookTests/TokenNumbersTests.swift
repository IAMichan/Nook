import XCTest

/// One way to read a number from an agent's JSON, one split of cached input for Codex and Gemini CLI (live and in the
/// history alike), and one tolerant reader of Codex's rate-limit windows.
final class TokenNumbersTests: XCTestCase {
    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    func testNumbers() {
        let object = json(#"{"a": 12, "b": "34", "c": true, "d": " 5.5 ", "e": "x", "f": 7.9}"#)
        XCTAssertEqual(JSONNumber.double(object["a"]), 12)
        XCTAssertEqual(JSONNumber.int(object["b"]), 34)
        XCTAssertNil(JSONNumber.double(object["c"]), "a JSON boolean is no number")
        XCTAssertEqual(JSONNumber.double(object["d"]), 5.5)
        XCTAssertNil(JSONNumber.int(object["e"]))
        XCTAssertEqual(JSONNumber.int(object["f"]), 7)
        XCTAssertNil(JSONNumber.double(Double.infinity))
        XCTAssertEqual(ClaudeStreamParser.number("3"), 3)
        XCTAssertEqual(CodexRateLimits.number(object["a"]), 12)
    }

    func testCodexInputWithoutTheCachedPart() {
        let snake = TokenUsageSplit.codex(json(#"{"input_tokens": 1000, "cached_input_tokens": 800, "output_tokens": 50}"#))
        XCTAssertEqual(snake, TokenCounts(input: 200, output: 50, cacheRead: 800))
        let camel = TokenUsageSplit.codex(json(#"{"inputTokens": 1000, "cachedInputTokens": 800, "outputTokens": 50, "cacheWriteInputTokens": 3}"#))
        XCTAssertEqual(camel, TokenCounts(input: 200, output: 50, cacheRead: 800, cacheWrite: 3))
        // The app server and the exec stream read it the same.
        XCTAssertEqual(CodexAppServerMapper.counts(json(#"{"inputTokens": 10, "cachedInputTokens": 4}"#)).input, 6)
    }

    func testGeminiThoughtsCountTheSameLiveAndInTheHistory() {
        // A chat file's tokens: input with the cached part, thoughts apart.
        let file = TokenUsageSplit.gemini(json(#"{"input": 1000, "cached": 600, "output": 40, "thoughts": 60}"#))
        XCTAssertEqual(file, TokenCounts(input: 400, output: 100, cacheRead: 600))
        // The stream's stats: input_tokens with the cached part, input without; thoughts when it sends them.
        let stream = TokenUsageSplit.gemini(json(#"{"input_tokens": 1000, "input": 400, "cached": 600, "output_tokens": 40, "thoughts": 60}"#))
        XCTAssertEqual(stream, file)
        let line = #"{"type":"result","status":"success","stats":{"input_tokens":1000,"cached":600,"output_tokens":40,"thoughts":60}}"#
        guard case .result(_, _, let usage)? = GeminiStreamParser.parse(line).first else { return XCTFail("no result") }
        XCTAssertEqual(usage.inputTokens, 400)
        XCTAssertEqual(usage.outputTokens, 100)
        XCTAssertEqual(usage.cacheReadTokens, 600)
    }

    func testCodexWindowsInEitherSpelling() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let app = CodexRateLimits.windows(json(#"{"planType": "pro", "primary": {"usedPercent": 40, "windowDurationMins": 300, "resetsAt": 1800000600}, "secondary": {"usedPercent": 10, "windowDurationMins": 10080}}"#), at: now)
        let log = CodexRateLimits.windows(json(#"{"plan_type": "pro", "primary": {"used_percent": 40, "window_minutes": 300, "resets_in_seconds": 600}, "secondary": {"used_percent": 10, "window_minutes": 10080}}"#), at: now, source: .sessionLog)
        XCTAssertEqual(app.fiveHour, log.fiveHour)
        XCTAssertEqual(app.weekly, log.weekly)
        XCTAssertEqual(app.fiveHour?.resetsAt, now.addingTimeInterval(600))
        XCTAssertEqual(log.planType, "pro")
        XCTAssertEqual(log.source, .sessionLog)
        // A usage limit's reset reads the same windows.
        XCTAssertEqual(UsageLimits.codexReset(json(#"{"rateLimits": {"primary": {"used_percent": 100, "resets_at": 1800000600}}}"#)),
                       Date(timeIntervalSince1970: 1_800_000_600))
    }
}
