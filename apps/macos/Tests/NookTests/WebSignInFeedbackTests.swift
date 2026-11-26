import XCTest

/// Why a chat app's sign-in window closed without linking it, from where the window stood.
final class WebSignInFeedbackTests: XCTestCase {
    func testTeamsClosedOnSignInPageDidNotFinish() {
        XCTAssertEqual(WebSignInFeedback.teamsClosed(at: URL(string: "https://login.microsoftonline.com/common/oauth2")), .closedEarly)
        XCTAssertEqual(WebSignInFeedback.teamsClosed(at: URL(string: "https://accounts.google.com/signin")), .closedEarly)
        XCTAssertEqual(WebSignInFeedback.teamsClosed(at: nil), .closedEarly)
    }

    func testTeamsClosedOnTeamsWasNotTaken() {
        XCTAssertEqual(WebSignInFeedback.teamsClosed(at: URL(string: "https://teams.microsoft.com/v2/")), .notTaken)
        XCTAssertEqual(WebSignInFeedback.teamsClosed(at: URL(string: "https://teams.cloud.microsoft/v2/")), .notTaken)
    }

    func testTeamsFreeIsAPersonalAccount() {
        let feedback = WebSignInFeedback.teamsClosed(at: URL(string: "https://teams.live.com/v2/"))
        XCTAssertEqual(feedback, .personalAccount)
        XCTAssertFalse(feedback.canRetry)
    }

    func testAlreadyLinkedIsNoError() {
        let feedback = WebSignInFeedback.alreadyLinked("Anna")
        XCTAssertFalse(feedback.isError)
        XCTAssertFalse(feedback.canRetry)
        XCTAssertTrue(WebSignInFeedback.closed(reachedApp: false).canRetry)
        XCTAssertEqual(WebSignInFeedback.closed(reachedApp: true), .notTaken)
    }
}
