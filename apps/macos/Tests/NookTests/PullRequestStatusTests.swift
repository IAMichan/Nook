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

    /// The tray row of a pull request the branch sync has not named reads its title here; a read without one keeps it.
    func testReadsKeepTheTitle() {
        let store = PullRequestStatusStore()
        let url = URL(string: "https://github.com/a/b/pull/6")!
        let now = Date()
        var snapshot = PullRequestSnapshot(state: "open", checks: "success", failedChecks: [], reviews: [], comments: [])
        snapshot.title = "Fix the tray"
        store.record(url: url, snapshot: snapshot, at: now)
        XCTAssertEqual(store.status(url)?.title, "Fix the tray")
        store.record([PullRequestLink(host: .github, repository: "a/b", number: 6, url: url.absoluteString, state: .merged)], at: now.addingTimeInterval(5))
        XCTAssertEqual(store.status(url)?.glyph, .merged)
        XCTAssertEqual(store.status(url)?.title, "Fix the tray")
        var renamed = PullRequestLink(host: .github, repository: "a/b", number: 6, url: url.absoluteString, state: .merged)
        renamed.title = "Fix the composer tray"
        store.record([renamed], at: now.addingTimeInterval(10))
        XCTAssertEqual(store.status(url)?.title, "Fix the composer tray")
    }

    func testKeptStatesShowBeforeTheFirstReadAndTheReadWins() {
        let store = PullRequestStatusStore()
        let url = URL(string: "https://github.com/a/b/pull/3")!
        store.seed([(url.absoluteString, .merged)])
        XCTAssertEqual(store.status(url)?.glyph, .merged, "a merged pull request is not open until its first read")
        // A copy that kept an older state does not turn it back, in either order.
        store.seed([(url.absoluteString, .open)])
        XCTAssertEqual(store.status(url)?.glyph, .merged)
        let other = URL(string: "https://github.com/a/b/pull/4")!
        store.seed([(other.absoluteString, .open), (other.absoluteString, .merged)])
        XCTAssertEqual(store.status(other)?.glyph, .merged)
        // A real read says more than what was kept: a reopened request turns open again, and stays so.
        store.record(key: PullRequestStatusStore.key(url), glyph: .open, checks: nil)
        XCTAssertEqual(store.status(url)?.glyph, .open)
        store.seed([(url.absoluteString, .merged)])
        XCTAssertEqual(store.status(url)?.glyph, .open)
    }

    func testKeptStatesStillGetTheirFirstRead() async {
        let store = PullRequestStatusStore()
        let url = URL(string: "https://github.com/a/b/pull/5")!
        store.seed([(url.absoluteString, .open)])
        store.fetch = { _ in PullRequestSnapshot(state: "merged", checks: "success", failedChecks: [], reviews: [], comments: [], conflicted: false) }
        await store.refresh(url)
        XCTAssertEqual(store.status(url), PullRequestStatus(glyph: .merged, checks: "success"))
    }

    func testBadgeLinksTakeTheNewestState() {
        let store = PullRequestStatusStore()
        let link = PullRequestLink(host: .github, repository: "a/b", number: 2, url: "https://github.com/a/b/pull/2")
        store.record(key: PullRequestStatusStore.key(repo: "a/b", number: 2), glyph: .conflict, checks: nil)
        XCTAssertEqual(PullRequestBadge.text(links: store.current([link]))?.glyph, .conflict)
    }

    func testMergeStatusAnswersWhetherItCanBeMerged() {
        func status(_ state: String, checks: String? = "", glyph: PullRequestBadge.Glyph = .open, auto: Bool = false) -> PullRequestMergeStatus {
            PullRequestMergeStatus(glyph: glyph, checks: checks, merge: PullRequestMergeFacts(state: state, autoMerge: auto, baseBranch: "main"))
        }
        XCTAssertEqual(status("clean"), .ready)
        XCTAssertEqual(status("clean", checks: "success"), .ready)
        XCTAssertEqual(status("behind"), .behind(base: "main"))
        XCTAssertEqual(status("blocked"), .blocked)
        XCTAssertEqual(status("blocked", checks: "failure"), .checksFailing, "the failing check is the reason worth naming")
        XCTAssertEqual(status("blocked", checks: "pending"), .checksRunning)
        XCTAssertEqual(status("unstable", checks: "pending"), .checksRunning)
        XCTAssertEqual(status("unstable"), .checksFailing)
        XCTAssertEqual(status("blocked", checks: "pending", auto: true), .autoMerge)
        XCTAssertEqual(status("unknown"), .open, "nothing known is never called ready")
        XCTAssertEqual(status("clean", glyph: .conflict), .conflict)
        XCTAssertEqual(status("clean", glyph: .draft), .draft)
        XCTAssertEqual(status("clean", checks: "failure", glyph: .merged), .merged)
        XCTAssertEqual(PullRequestMergeStatus(glyph: .open, checks: "failure", merge: nil), .checksFailing,
                       "failing checks show before a read has said how merging stands")
        XCTAssertEqual(PullRequestMergeStatus(glyph: .open, checks: "pending", merge: nil), .checksRunning)
        XCTAssertEqual(PullRequestMergeStatus(glyph: .open, checks: "success", merge: nil), .open)
        XCTAssertEqual(PullRequestMergeStatus(glyph: .open, checks: nil, merge: nil), .open)
    }

    /// The branch sync says only the state. It must not keep the checks from being read, or the tray above the composer
    /// never shows CI.
    func testTheBranchSyncDoesNotHoldBackTheChecksRead() async {
        let store = PullRequestStatusStore()
        let url = URL(string: "https://github.com/a/b/pull/6")!
        store.record([PullRequestLink(host: .github, repository: "a/b", number: 6, url: url.absoluteString)], at: Date())
        store.fetch = { _ in PullRequestSnapshot(state: "open", checks: "failure", failedChecks: ["ci"], reviews: [], comments: [], conflicted: false) }
        await store.refresh(url, maxAge: 20)
        XCTAssertEqual(store.status(url)?.checks, "failure")
        // A read that knew the checks does count: the next one within `maxAge` waits.
        store.fetch = { _ in PullRequestSnapshot(state: "open", checks: "success", failedChecks: [], reviews: [], comments: [], conflicted: false) }
        await store.refresh(url, maxAge: 20)
        XCTAssertEqual(store.status(url)?.checks, "failure")
    }

    func testAReadWithoutMergeFactsKeepsTheLastOnes() {
        let store = PullRequestStatusStore()
        let url = URL(string: "https://github.com/a/b/pull/3")!
        let key = PullRequestStatusStore.key(url)
        store.record(key: key, glyph: .open, checks: "success", merge: PullRequestMergeFacts(state: "clean"))
        store.record(key: key, glyph: .open, checks: nil)
        XCTAssertEqual(store.status(url)?.mergeStatus, .ready)
    }
}
