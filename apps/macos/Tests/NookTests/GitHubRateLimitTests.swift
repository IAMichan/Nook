import XCTest

final class GitHubRateLimitTests: XCTestCase {
    private func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse? {
        HTTPURLResponse(url: URL(string: "https://api.github.com/repos/a/b/pulls")!, statusCode: status, httpVersion: nil, headerFields: headers)
    }

    func testSignedOutLimitPointsAtTheToken() {
        let text = "API rate limit exceeded for 86.95.248.97. (But here's the good news: Authenticated requests get a higher rate limit.)"
        XCTAssertTrue(GitHubRateLimit.isAnonymous(text))
        let message = GitHubRateLimit.message(response(403, ["X-RateLimit-Reset": "1793352646"]), text)
        XCTAssertNotNil(message)
        XCTAssertFalse(message?.contains("86.95.248.97") ?? true)
    }

    func testAccountLimitIsNotSignedOut() {
        XCTAssertFalse(GitHubRateLimit.isAnonymous("API rate limit exceeded for user ID 123."))
        XCTAssertFalse(GitHubRateLimit.isAnonymous("You have exceeded a secondary rate limit."))
        XCTAssertNotNil(GitHubRateLimit.message(response(429), "You have exceeded a secondary rate limit."))
    }

    func testOtherErrorsPassThrough() {
        XCTAssertNil(GitHubRateLimit.message(response(403), "Resource not accessible by integration"))
        XCTAssertNil(GitHubRateLimit.message(response(422), "Validation Failed"))
        XCTAssertNil(GitHubRateLimit.message(nil, "API rate limit exceeded for 1.2.3.4."))
    }
}
