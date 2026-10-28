import XCTest

@MainActor
final class PullRequestStatusTests: XCTestCase {
    func testKeyIgnoresTabsQueriesAndCase() {
        let a = PullRequestStatusStore.key(URL(string: "https://github.com/IAMichan/Nook/pull/797/files?w=1")!)
        let b = PullRequestStatusStore.key(URL(string: "https://github.com/iamichan/nook/pull/797/")!)
        XCTAssertEqual(a, "github.com/iamichan/nook/pull/797")
        XCTAssertEqual(a, b)
        XCTAssertEqual(PullRequestStatusStore.key(repo: "IAMichan/Nook", number: 797), a)
        XCTAssertEqual(PullRequestStatusStore.key(URL(string: "https://gitlab.com/g/r/-/merge_requests/4/diffs")!),
                       "gitlab.com/g/r/-/merge_requests/4")
        XCTAssertNil(PullRequestStatusStore.key(URL(string: "https://github.com/a/b")!))
    }

    func testNewestReadWinsAndKeepsKnownChecks() {
        let store = PullRequestStatusStore()
        let url = URL(string: "https://github.com/a/b/pull/1")!
        let now = Date()
        let snapshot = PullRequestSnapshot(state: "open", checks: "pending", failedChecks: [], reviews: [], comments: [], conflicted: true)
        store.record(url: url, snapshot: snapshot, at: now)
        XCTAssertEqual(store.status(url), PullRequestStatus(glyph: .conflict, checks: "pending"))
        // An older read (a sync round that started before) does not turn it back.
        store.record([PullRequestLink(host: .github, repository: "a/b", number: 1, url: url.absoluteString)], at: now.addingTimeInterval(-5))
        XCTAssertEqual(store.status(url)?.glyph, .conflict)
        // A newer one without checks keeps the checks it knew.
        store.record([PullRequestLink(host: .github, repository: "a/b", number: 1, url: url.absoluteString, state: .merged)], at: now.addingTimeInterval(5))
        XCTAssertEqual(store.status(url), PullRequestStatus(glyph: .merged, checks: "pending"))
    }

    func testBadgeLinksTakeTheNewestState() {
        let store = PullRequestStatusStore()
        let link = PullRequestLink(host: .github, repository: "a/b", number: 2, url: "https://github.com/a/b/pull/2")
        store.record(key: PullRequestStatusStore.key(repo: "a/b", number: 2), glyph: .conflict, checks: nil)
        XCTAssertEqual(PullRequestBadge.text(links: store.current([link]))?.glyph, .conflict)
    }
}
