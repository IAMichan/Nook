import XCTest

final class PullRequestFilterTests: XCTestCase {
    private func item(_ number: Int, _ title: String, repo: String = "acme/app", author: String = "ada", draft: Bool = false,
                      ci: PullRequestItem.CI = .unknown) -> PullRequestItem {
        PullRequestItem(repo: repo, number: number, title: title, url: nil, draft: draft, updated: nil, author: author, ci: ci)
    }

    func testEmptyFilterShowsEverything() {
        let filter = PullRequestFilter()
        XCTAssertFalse(filter.isActive)
        XCTAssertTrue(filter.matches(item(1, "Anything")))
    }

    func testSearchNeedsEveryWord() {
        var filter = PullRequestFilter(query: "  Merge  ACME ")
        XCTAssertTrue(filter.isActive)
        XCTAssertTrue(filter.matches(item(1, "Add merging")))
        XCTAssertFalse(filter.matches(item(1, "Add merging", repo: "other/app")))
        filter.query = "@bob"
        XCTAssertTrue(filter.matches(item(1, "Fix", author: "bob")))
        XCTAssertFalse(filter.matches(item(1, "Fix", author: "ada")))
    }

    func testNumberMatchesExactly() {
        let filter = PullRequestFilter(query: "#12")
        XCTAssertTrue(filter.matches(item(12, "Fix")))
        XCTAssertFalse(filter.matches(item(123, "Fix")))
        XCTAssertTrue(PullRequestFilter(query: "12").matches(item(12, "Fix")))
        XCTAssertTrue(PullRequestFilter(query: "2026").matches(item(3, "Plans for 2026")))
    }

    func testStatus() {
        var filter = PullRequestFilter()
        filter.status = .failing
        XCTAssertTrue(filter.matches(item(1, "A", ci: .failing)))
        XCTAssertFalse(filter.matches(item(1, "A", ci: .passing)))
        filter.status = .draft
        XCTAssertTrue(filter.matches(item(1, "A", draft: true)))
        XCTAssertFalse(filter.matches(item(1, "A")))
    }

    func testScopeAndErrorsSurvive() {
        let account = AccountPullRequests(id: "github", name: "Work", login: "ada", mine: [item(1, "Mine")],
                                          reviews: [item(2, "Theirs", author: "bob")], error: "Offline")
        var filter = PullRequestFilter()
        filter.scope = .reviews
        let reviews = filter.apply(account)
        XCTAssertEqual(reviews.reviews.map(\.number), [2])
        XCTAssertEqual(reviews.mine, [])
        XCTAssertEqual(reviews.error, "Offline")
        filter.scope = .mine
        filter.query = "theirs"
        XCTAssertEqual(filter.apply(account).mine, [])
        XCTAssertEqual(filter.apply(account).reviews, [])
    }
}
