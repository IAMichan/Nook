import XCTest

/// A terminal session's failed turn (`StopFailure`) reads a usage limit or an expired login as a session Nook runs does,
/// through the one classifier and its one list of sign-in phrases.
final class HookFailureTests: XCTestCase {
    func testUsageLimitWithReset() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let failure = FailureClassifier.hookFailure("API Error: Rate limited (reset after 45s)", now: now)
        guard case .usageLimit(let reset) = failure.kind else { return XCTFail("not a limit: \(failure.kind)") }
        XCTAssertEqual(reset, now.addingTimeInterval(45))
        XCTAssertNotEqual(failure.line, "API Error: Rate limited (reset after 45s)")
    }

    func testGeminiQuotaIsALimit() {
        let failure = FailureClassifier.hookFailure("[API Error: RESOURCE_EXHAUSTED quota exceeded]")
        guard case .usageLimit = failure.kind else { return XCTFail("not a limit: \(failure.kind)") }
        XCTAssertEqual(failure.line, tr("agents.notice.limit"))
    }

    func testExpiredLoginAsksToSignIn() {
        for text in ["OAuth session expired and could not be refreshed", "Authentication required", "Not logged in. Run `codex login`."] {
            let failure = FailureClassifier.hookFailure(text)
            XCTAssertEqual(failure.kind, .authentication, text)
            XCTAssertEqual(failure.line, tr("agents.notice.signIn"))
        }
    }

    func testOtherErrorsKeepTheirWords() {
        let failure = FailureClassifier.hookFailure("Prompt is too long")
        XCTAssertEqual(failure.kind, .generic)
        XCTAssertEqual(failure.line, "Prompt is too long")
    }

    func testOneSignInListForEveryAgent() {
        // The ACP wording and Claude Code's wording mean the same everywhere.
        for text in ["Authentication required", "Invalid API key · Please run /login", "API Error: 401"] {
            XCTAssertTrue(AgentSignInFailure.needsSignIn(text), text)
            XCTAssertTrue(AgentErrorText.needsSignIn(text), text)
            XCTAssertEqual(FailureClassifier.classify(FailureEvidence(isError: true, messageText: text)), .authentication, text)
        }
    }
}
