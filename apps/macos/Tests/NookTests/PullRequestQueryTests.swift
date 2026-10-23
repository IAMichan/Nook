import XCTest

final class PullRequestQueryTests: XCTestCase {
    private func item(_ number: Int, title: String = "Fix", repo: String = "acme/app", author: String = "ada",
                      draft: Bool = false, review: PullRequestItem.Review = .none, ci: PullRequestItem.CI = .unknown,
                      labels: [String] = [], branch: String = "", state: PullRequestItem.State = .open) -> PullRequestItem {
        PullRequestItem(repo: repo, number: number, title: title, url: nil, draft: draft, updated: nil, author: author, ci: ci,
                        state: state, review: review, labels: labels, headBranch: branch)
    }

    func testQualifiersAreReadOutOfTheWords() {
        let query = PullRequestQuery.parse("crash label:bug -label:wip author:@Bob draft:false review:approved checks:failing repo:acme/app")
        XCTAssertEqual(query.words, ["crash"])
        XCTAssertEqual(query.labels, [["bug"]])
        XCTAssertEqual(query.excludedLabels, ["wip"])
        XCTAssertEqual(query.author, "Bob")
        XCTAssertEqual(query.draft, .ready)
        XCTAssertEqual(query.review, .approved)
        XCTAssertEqual(query.checks, .failing)
        XCTAssertEqual(query.repo, "acme/app")
    }

    func testLabelListsQuotesAndScopedLabels() {
        let query = PullRequestQuery.parse(#"label:bug,ui label:"good first issue" area:ui -kind:chore"#)
        XCTAssertEqual(query.labels, [["bug", "ui"], ["good first issue"], ["area:ui"]])
        XCTAssertEqual(query.excludedLabels, ["kind:chore"])
        XCTAssertTrue(query.words.isEmpty)
    }

    func testWordsThatOnlyLookLikeQualifiersStay() {
        let query = PullRequestQuery.parse("12:30 https://example.com review:maybe label:")
        XCTAssertEqual(query.words, ["12:30", "https://example.com", "review:maybe", "label:"])
        XCTAssertEqual(query, PullRequestQuery(words: query.words))
    }

    func testTypedQualifierWinsOverTheDropdown() {
        var filter = PullRequestFilter(query: "review:approved")
        filter.review = .changesRequested
        XCTAssertEqual(filter.effectiveReview, .approved)
        XCTAssertTrue(filter.matches(item(1, review: .approved)))
        XCTAssertFalse(filter.matches(item(2, review: .changesRequested)))
    }

    func testLabelsMustAllHoldAndExcludedOnesLeave() {
        var filter = PullRequestFilter()
        filter.labels = ["Bug"]
        XCTAssertEqual(filter.activeCount, 1)
        XCTAssertTrue(filter.matches(item(1, labels: ["bug", "ui"])))
        XCTAssertFalse(filter.matches(item(2, labels: ["ui"])))
        filter.query = "label:ui,docs -label:wip"
        XCTAssertTrue(filter.matches(item(3, labels: ["bug", "docs"])))
        XCTAssertFalse(filter.matches(item(4, labels: ["bug", "docs", "wip"])))
        XCTAssertFalse(filter.matches(item(5, labels: ["bug"])))
    }

    func testReviewAndRepositoryFilters() {
        var filter = PullRequestFilter()
        filter.review = .noReviews
        XCTAssertTrue(filter.matches(item(1)))
        XCTAssertFalse(filter.matches(item(2, review: .required)))
        filter = PullRequestFilter(repo: "Acme/App")
        XCTAssertTrue(filter.matches(item(1)))
        XCTAssertFalse(filter.matches(item(2, repo: "acme/site")))
        XCTAssertEqual(filter.activeCount, 1)
    }

    func testSearchFindsTheBranch() {
        XCTAssertTrue(PullRequestFilter(query: "feature/login").matches(item(1, branch: "feature/login-form")))
        XCTAssertFalse(PullRequestFilter(query: "feature/login").matches(item(1, branch: "main")))
    }

    func testPickingADraftChoiceTakesTheTypedOneOut() {
        let filter = PullRequestFilter(query: "crash draft:true").settingDraft(.ready)
        XCTAssertEqual(filter.query, "crash")
        XCTAssertEqual(filter.effectiveDraft, .ready)
        XCTAssertEqual(PullRequestFilter(query: "a review:approved b").clearingTyped(["review"]).query, "a b")
        XCTAssertEqual(PullRequestFilter(query: "a  b").clearingTyped(["review"]).query, "a  b", "nothing typed, nothing changes")
    }

    func testFacetsCountEachPullRequestOnceInTheChosenState() {
        var first = item(1, author: "bob", labels: ["bug", "ui"])
        first.labelColors = ["bug": "d73a4a"]
        let account = AccountPullRequests(id: "github", name: "Work", login: "ada",
                                          mine: [item(2, repo: "acme/site", labels: ["bug"]), item(3, labels: ["ui"], state: .merged)],
                                          reviews: [first, first], error: nil)
        let open = PullRequestFilter.facets(in: [account], state: .open)
        XCTAssertEqual(open.labels.map(\.name), ["bug", "ui"])
        XCTAssertEqual(open.labels.map(\.count), [2, 1])
        XCTAssertEqual(open.labels.first?.color, "d73a4a")
        XCTAssertEqual(open.authors.map(\.name), ["ada", "bob"])
        XCTAssertEqual(open.repos.map(\.name), ["acme/app", "acme/site"])
        XCTAssertEqual(PullRequestFilter.facets(in: [account], state: .all).labels.map(\.count), [2, 2])
    }

    func testFilterSurvivesARelaunch() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PullRequestQueryTests"))
        defer { defaults.removePersistentDomain(forName: "PullRequestQueryTests") }
        let filter = PullRequestFilter(query: "label:bug", state: .merged, author: "bob", labels: ["ui"], review: .approved)
        filter.save(to: defaults)
        XCTAssertEqual(PullRequestFilter.load(from: defaults), filter)
        defaults.set(Data(#"{"state":"closed","draft":"drafts"}"#.utf8), forKey: "nook.pulls.filter")
        let older = PullRequestFilter.load(from: defaults)
        XCTAssertEqual(older.state, .closed)
        XCTAssertEqual(older.draft, .drafts)
        XCTAssertEqual(older.review, .all)
    }

    func testRowsCarryLabelColorsAndTheBranch() throws {
        let json = #"""
        {"data": {"viewer": {"login": "ada"},
          "mine": {"nodes": [{"number": 7, "title": "Login", "headRefName": "feature/login",
                              "labels": {"nodes": [{"name": "bug", "color": "d73a4a"}, {"name": "docs", "color": ""}]},
                              "author": {"login": "ada"}, "repository": {"nameWithOwner": "acme/app"}}]},
          "reviews": {"nodes": []}, "mineClosed": {"nodes": []}, "reviewsClosed": {"nodes": []}}}
        """#
        let parsed = try PullRequestGraphQL.parse(Data(json.utf8))
        let row = try XCTUnwrap(parsed.mine.first)
        XCTAssertEqual(row.labels, ["bug", "docs"])
        XCTAssertEqual(row.labelColors, ["bug": "d73a4a"])
        XCTAssertEqual(row.headBranch, "feature/login")
        let saved = try JSONDecoder().decode(PullRequestItem.self, from: Data(#"{"repo":"a/b","number":1,"title":"T","draft":false,"author":"x"}"#.utf8))
        XCTAssertEqual(saved.labelColors, [:])
        XCTAssertEqual(saved.headBranch, "")
    }
}
