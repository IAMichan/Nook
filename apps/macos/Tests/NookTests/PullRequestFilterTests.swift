import XCTest

final class PullRequestFilterTests: XCTestCase {
    private func item(_ number: Int, _ title: String, repo: String = "acme/app", author: String = "ada", draft: Bool = false,
                      ci: PullRequestItem.CI = .unknown, state: PullRequestItem.State = .open) -> PullRequestItem {
        PullRequestItem(repo: repo, number: number, title: title, url: nil, draft: draft, updated: nil, author: author, ci: ci, state: state)
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
    }

    func testDraft() {
        var filter = PullRequestFilter()
        filter.draft = .drafts
        XCTAssertTrue(filter.matches(item(1, "A", draft: true)))
        XCTAssertFalse(filter.matches(item(1, "A")))
        filter.draft = .ready
        XCTAssertFalse(filter.matches(item(1, "A", draft: true)))
        XCTAssertTrue(filter.matches(item(1, "A")))
    }

    func testStateShowsOpenByDefault() {
        var filter = PullRequestFilter()
        XCTAssertFalse(filter.isActive, "open is the default, not a filter")
        XCTAssertTrue(filter.matches(item(1, "A")))
        XCTAssertFalse(filter.matches(item(2, "B", state: .closed)))
        XCTAssertFalse(filter.matches(item(3, "C", state: .merged)))
        filter.state = .closed
        XCTAssertEqual(filter.activeCount, 1)
        XCTAssertTrue(filter.matches(item(2, "B", state: .closed)))
        XCTAssertFalse(filter.matches(item(3, "C", state: .merged)), "closed means closed without merging")
        filter.state = .merged
        XCTAssertTrue(filter.matches(item(3, "C", state: .merged)))
        filter.state = .all
        XCTAssertTrue([item(1, "A"), item(2, "B", state: .closed), item(3, "C", state: .merged)].allSatisfy(filter.matches))
    }

    func testAuthor() {
        var filter = PullRequestFilter()
        filter.author = "Bob"
        XCTAssertTrue(filter.matches(item(1, "A", author: "bob")))
        XCTAssertFalse(filter.matches(item(1, "A", author: "ada")))
        let account = AccountPullRequests(id: "github", name: "Work", login: "ada", mine: [item(1, "A"), item(2, "B")],
                                          reviews: [item(3, "C", author: "bob"), item(4, "D", author: "")], error: nil)
        XCTAssertEqual(PullRequestFilter.authors(in: [account]), ["ada", "bob"])
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

    func testWatchedScope() {
        var account = AccountPullRequests(id: "github", name: "Work", login: "ada", mine: [item(1, "Mine")],
                                          reviews: [item(2, "Theirs", author: "bob")], error: nil)
        account.watched = [item(3, "Team", author: "cleo")]
        var filter = PullRequestFilter()
        XCTAssertEqual(filter.apply(account).watched.map(\.number), [3])
        XCTAssertEqual(PullRequestFilter.authors(in: [account]).sorted(), ["ada", "bob", "cleo"])
        filter.scope = .watched
        let watched = filter.apply(account)
        XCTAssertEqual(watched.watched.map(\.number), [3])
        XCTAssertEqual(watched.mine, [])
        XCTAssertEqual(watched.reviews, [])
        filter.scope = .mine
        XCTAssertEqual(filter.apply(account).watched, [])
    }

    func testGroupsByRepository() {
        var account = AccountPullRequests(id: "github", name: "Work", login: "ada",
                                          mine: [item(1, "Mine", repo: "acme/web"), item(2, "Also mine", repo: "acme/app")],
                                          reviews: [item(3, "Theirs", repo: "acme/app", author: "bob")], error: nil)
        // Watched lists can repeat a pull request that is also yours: it shows once, as yours.
        account.watched = [item(4, "Team", repo: "acme/web", author: "cleo"), item(1, "Mine", repo: "acme/web")]
        let groups = account.byRepo
        XCTAssertEqual(groups.map(\.repo), ["acme/app", "acme/web"])
        XCTAssertEqual(groups[0].rows.map(\.item.number), [3, 2])
        XCTAssertEqual(groups[0].rows.map(\.role), [.review, .mine])
        XCTAssertEqual(groups[1].rows.map(\.item.number), [1, 4])
        XCTAssertEqual(groups[1].rows.map(\.role), [.mine, .watched])
    }
}
