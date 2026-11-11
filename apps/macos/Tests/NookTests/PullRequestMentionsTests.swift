import XCTest

final class PullRequestMentionsTests: XCTestCase {
    private func refs(_ command: String) -> [String] {
        PullRequestMentions.inCommand([command]).map { $0.url?.absoluteString ?? $0.reference }
    }

    func testCommandNamesThePullRequestItWorksOn() {
        XCTAssertEqual(refs("gh pr checks 3877"), ["#3877"])
        XCTAssertEqual(refs("gh pr checks --watch 3878"), ["#3878"])
        XCTAssertEqual(refs("cd repo && gh pr checkout 12 && npm test"), ["#12"])
        XCTAssertEqual(refs("gh pr view 3877 --json statusCheckRollup; gh pr view 3878 --json statusCheckRollup"), ["#3877", "#3878"])
        XCTAssertEqual(refs("gh pr view 5 -R acme/app"), ["acme/app#5"])
        XCTAssertEqual(refs("gh pr diff --repo=acme/app 7"), ["acme/app#7"])
        XCTAssertEqual(refs("gh pr view https://github.com/acme/app/pull/9"), ["https://github.com/acme/app/pull/9"])
        XCTAssertEqual(refs("glab mr view 4"), ["#4"])
    }

    func testCommandWithoutOneNamesNone() {
        XCTAssertEqual(refs("gh pr list --state open"), [])
        XCTAssertEqual(refs("gh pr create --title Fix --body 12"), [])
        XCTAssertEqual(refs("gh pr view"), [])
        XCTAssertEqual(refs("gh pr comment --body 12"), [])
        XCTAssertEqual(refs("git log -n 12"), [])
        XCTAssertEqual(refs("gh run view 12345"), [])
    }

    func testMessageNamesHashesAndLinks() {
        let found = PullRequestMentions.inMessage("Fix the CI of #3878 and https://github.com/acme/app/pull/3877.")
            .map { $0.url?.absoluteString ?? $0.reference }
        XCTAssertEqual(found, ["https://github.com/acme/app/pull/3877", "#3878"])
        XCTAssertEqual(PullRequestMentions.inMessage("color #fff, a#12, # 3, see https://example.com/x").count, 0)
        XCTAssertEqual(PullRequestMentions.inMessage("#12 and #12 again").count, 1)
    }
}
