import XCTest

final class PullRequestAttentionTests: XCTestCase {
    private func item(_ number: Int, repo: String = "acme/app", draft: Bool = false, ci: PullRequestItem.CI = .unknown,
                      state: PullRequestItem.State = .open, review: PullRequestItem.Review = .none,
                      conflict: Bool = false) -> PullRequestItem {
        var item = PullRequestItem(repo: repo, number: number, title: "PR \(number)", url: nil, draft: draft, updated: nil,
                                   author: "ada", ci: ci, state: state)
        item.review = review
        item.conflict = conflict
        return item
    }

    private func account(_ id: String = "github", mine: [PullRequestItem] = [], reviews: [PullRequestItem] = [],
                         watched: [PullRequestItem] = []) -> AccountPullRequests {
        var account = AccountPullRequests(id: id, name: id, login: "ada", mine: mine, reviews: reviews, error: nil)
        account.watched = watched
        return account
    }

    private var ready: PullRequestItem { item(1, ci: .passing, review: .approved) }

    func testReadyToMergeNeedsEverythingInPlace() {
        func isReady(_ item: PullRequestItem) -> Bool { PullRequestRepoGroup.Row(item: item, role: .mine).isReadyToMerge }
        XCTAssertTrue(isReady(ready))
        XCTAssertFalse(isReady(item(1, draft: true, ci: .passing, review: .approved)), "a draft cannot merge")
        XCTAssertFalse(isReady(item(1, ci: .passing, review: .approved, conflict: true)), "a conflict holds it back")
        XCTAssertFalse(isReady(item(1, ci: .pending, review: .approved)), "checks still running")
        XCTAssertFalse(isReady(item(1, ci: .passing, review: .required)), "no approval yet")
        XCTAssertFalse(isReady(item(1, ci: .passing, state: .merged, review: .approved)), "already merged")
    }

    func testEachChipAsksSomethingOnlyOfItsOwnRows() {
        let review = PullRequestRepoGroup.Row(item: item(1), role: .review)
        let failing = PullRequestRepoGroup.Row(item: item(2, ci: .failing), role: .mine)
        let watchedFailing = PullRequestRepoGroup.Row(item: item(3, ci: .failing), role: .watched)
        let readyRow = PullRequestRepoGroup.Row(item: ready, role: .mine)
        let watchedReady = PullRequestRepoGroup.Row(item: ready, role: .watched)
        let closedReview = PullRequestRepoGroup.Row(item: item(4, state: .closed), role: .review)

        XCTAssertTrue(PullRequestAttention.review.includes(review))
        XCTAssertFalse(PullRequestAttention.review.includes(closedReview), "only open pull requests ask anything")
        XCTAssertTrue(PullRequestAttention.failing.includes(failing))
        XCTAssertFalse(PullRequestAttention.failing.includes(watchedFailing), "someone else's failing checks are theirs")
        XCTAssertTrue(PullRequestAttention.ready.includes(readyRow))
        XCTAssertFalse(PullRequestAttention.ready.includes(watchedReady))
    }

    func testCountsEachPullRequestOnceAcrossAccounts() {
        let shared = item(7)
        let accounts = [
            account("github", mine: [item(2, ci: .failing), ready], reviews: [shared, item(8)]),
            account("github.work", reviews: [shared]),
        ]
        let counts = PullRequestAttention.counts(in: accounts)
        XCTAssertEqual(counts[.review], 2, "#7 is listed by both accounts but waits for one review")
        XCTAssertEqual(counts[.failing], 1)
        XCTAssertEqual(counts[.ready], 1)
    }

    func testChipNarrowsTheListToWhatItCounts() {
        let accounts = [account(mine: [item(2, ci: .failing), ready, item(3)], reviews: [item(8)],
                                watched: [item(9, ci: .failing)])]
        var filter = PullRequestFilter()
        filter.attention = .failing
        let shown = filter.apply(accounts)[0]
        XCTAssertEqual(shown.mine.map(\.number), [2])
        XCTAssertTrue(shown.reviews.isEmpty)
        XCTAssertTrue(shown.watched.isEmpty, "a watched pull request's failing checks are not yours")

        filter.attention = .review
        XCTAssertEqual(filter.apply(accounts)[0].reviews.map(\.number), [8])
        XCTAssertTrue(filter.apply(accounts)[0].mine.isEmpty)

        filter.attention = .ready
        XCTAssertEqual(filter.apply(accounts)[0].mine.map(\.number), [1])
    }

    func testChipCountsAsAFilterAndClears() {
        var filter = PullRequestFilter()
        filter.attention = .review
        XCTAssertTrue(filter.isActive)
        XCTAssertEqual(filter.activeCount, 1, "the Filters badge counts the chip, and Clear takes it off")
    }

    func testChipIsKeptAcrossLaunchesAndOldFiltersStillLoad() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PullRequestAttentionTests"))
        defaults.removePersistentDomain(forName: "PullRequestAttentionTests")
        var filter = PullRequestFilter(query: "fix")
        filter.attention = .ready
        filter.save(to: defaults)
        XCTAssertEqual(PullRequestFilter.load(from: defaults).attention, .ready)

        // A filter saved before the chips existed has no attention key.
        let old = try JSONDecoder().decode(PullRequestFilter.self, from: Data(#"{"query":"fix","state":"open"}"#.utf8))
        XCTAssertNil(old.attention)
        XCTAssertEqual(old.query, "fix")
        defaults.removePersistentDomain(forName: "PullRequestAttentionTests")
    }
}
