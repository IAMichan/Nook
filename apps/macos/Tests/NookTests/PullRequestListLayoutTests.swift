import XCTest

final class PullRequestListLayoutTests: XCTestCase {
    private func item(_ number: Int, repo: String = "acme/app", author: String = "ada", ci: PullRequestItem.CI = .unknown,
                      state: PullRequestItem.State = .open, head: String = "", base: String = "main") -> PullRequestItem {
        var item = PullRequestItem(repo: repo, number: number, title: "T\(number)", url: nil, draft: false, updated: nil,
                                   author: author, ci: ci, state: state)
        item.headBranch = head.isEmpty ? "b\(number)" : head
        item.baseBranch = base
        return item
    }

    private var accounts: [AccountPullRequests] {
        [AccountPullRequests(id: "github", name: "Ada", login: "ada",
                             mine: [item(1, ci: .failing), item(2, head: "top", base: "b1"), item(3, state: .merged)],
                             reviews: [item(4, repo: "acme/web", author: "bob"), item(1, ci: .failing)],
                             watched: [item(5, repo: "acme/web", author: "cy"), item(6, author: "cy", state: .closed)]),
         AccountPullRequests(id: "github.work", name: "Work", login: "ada-w", mine: [], reviews: [], error: "rejected")]
    }

    /// The layout says what the page used to work out on every redraw, with the same answers.
    func testLayoutMatchesTheListItReplaces() {
        let accounts = self.accounts
        let filter = PullRequestFilter(query: "acme")
        let layout = PullRequestListLayout(accounts: accounts, filter: filter, sort: .attention, grouping: .involvement)

        XCTAssertEqual(layout.shown, filter.apply(accounts))
        XCTAssertEqual(layout.attention, PullRequestAttention.counts(in: filter.apply(accounts)))
        XCTAssertEqual(layout.facets, PullRequestFilter.facets(in: accounts, state: .open))
        XCTAssertEqual(layout.waitingForYou, 2)
        XCTAssertEqual(layout.allCount, 6)
        XCTAssertEqual(layout.shownCount, 4)
        XCTAssertFalse(layout.isEmpty)
        // The account with an error stays, to show it; groups and their keys as the page folds them.
        XCTAssertEqual(layout.sections.map(\.id), ["github", "github.work"])
        let groups = layout.sections[0].groups
        XCTAssertEqual(groups.map(\.id), ["github role:review", "github role:mine", "github role:watched"])
        XCTAssertEqual(groups.map { $0.rows.map(\.item.number) }, filter.apply(accounts[0]).byRole(sort: .attention).map { $0.rows.map(\.item.number) })
        XCTAssertEqual(groups.map { $0.rows.map(\.item.number) }, [[4, 1], [2], [5]])
        // Stacks come from the whole list, so a filtered-out base still places the row above it.
        XCTAssertEqual(layout.sections[0].stacks["acme/app#2"]?.index, 2)
    }

    func testRepositoryGroupsCountTheReviewsWaiting() {
        let layout = PullRequestListLayout(accounts: accounts, filter: PullRequestFilter(), sort: .attention, grouping: .repository)
        let web = layout.sections[0].groups.first { $0.repo == "acme/web" }
        XCTAssertEqual(web?.id, "github acme/web")
        XCTAssertEqual(web?.waiting, 1)
        XCTAssertNil(web?.role)
    }

    /// A chip on narrows the rows, but the chips still count the list as the other filters leave it.
    func testChipCountsIgnoreTheChipItself() {
        let accounts = self.accounts
        var filter = PullRequestFilter()
        filter.attention = .failing
        let layout = PullRequestListLayout(accounts: accounts, filter: filter, sort: .attention, grouping: .involvement)
        XCTAssertEqual(layout.attention, PullRequestAttention.counts(in: PullRequestFilter().apply(accounts)))
        XCTAssertEqual(layout.shownCount, 1)
    }

    func testAFilteredListLeavesOutAccountsWithoutMatches() {
        var accounts = self.accounts
        accounts[1] = AccountPullRequests(id: "github.work", name: "Work", login: "ada-w", mine: [item(9, repo: "other/x")], reviews: [])
        let layout = PullRequestListLayout(accounts: accounts, filter: PullRequestFilter(query: "acme"), sort: .attention, grouping: .involvement)
        XCTAssertEqual(layout.sections.map(\.id), ["github"])
        let none = PullRequestListLayout(accounts: accounts, filter: PullRequestFilter(query: "nothing-matches"), sort: .attention, grouping: .involvement)
        XCTAssertTrue(none.isEmpty)
    }

    /// Worked out once while its inputs stay the same, again when one changes.
    func testLastValueWorksOutOncePerChange() {
        let memo = LastValue<PullRequestListLayout.Inputs, Int>()
        var runs = 0
        let accounts = self.accounts
        let inputs = PullRequestListLayout.Inputs(accounts: accounts, filter: PullRequestFilter(), sort: .attention, grouping: .involvement)
        for _ in 0..<5 { _ = memo.value(for: inputs) { _ in runs += 1; return runs } }
        XCTAssertEqual(runs, 1)
        let typed = PullRequestListLayout.Inputs(accounts: accounts, filter: PullRequestFilter(query: "a"), sort: .attention, grouping: .involvement)
        XCTAssertEqual(memo.value(for: typed) { _ in runs += 1; return runs }, 2)
        XCTAssertEqual(memo.value(for: typed) { _ in runs += 1; return runs }, 2)
    }
}
