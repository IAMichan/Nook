import XCTest

final class AgentSignInFailureTests: XCTestCase {
    typealias F = AgentSignInFailure

    func testLoginErrorsAskToSignInAgain() {
        XCTAssertTrue(F.needsSignIn("Failed to authenticate: OAuth session expired and could not be refreshed"))
        XCTAssertTrue(F.needsSignIn("Invalid API key · Please run /login"))
        XCTAssertTrue(F.needsSignIn("API Error: 401 {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\"}}"))
        XCTAssertTrue(F.needsSignIn("Not logged in. Run `codex login`."))
        XCTAssertTrue(F.needsSignIn("Request had invalid authentication credentials: Unauthorized"))
    }

    func testOtherErrorsDoNot() {
        XCTAssertFalse(F.needsSignIn(nil))
        XCTAssertFalse(F.needsSignIn(""))
        XCTAssertFalse(F.needsSignIn("Prompt is too long: 210000 tokens > 200000 maximum"))
        XCTAssertFalse(F.needsSignIn("API Error: 529 Overloaded"))
        XCTAssertFalse(F.needsSignIn("interrupted"))
    }

    func testEveryAgentNookSignsInOffersIt() {
        for provider in RunProvider.allCases {
            XCTAssertEqual(F.canSignInAgain(provider), provider != .acp, provider.rawValue)
        }
    }
}
