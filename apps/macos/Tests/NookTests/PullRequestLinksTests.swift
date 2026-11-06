import XCTest

final class PullRequestLinksTests: XCTestCase {
    private func link(_ n: Int, base: String? = nil, head: String? = nil, state: PullRequestState = .open,
                      at: Double? = nil, repo: String = "a/b", host: SourceControlHost = .github) -> PullRequestLink {
        PullRequestLink(host: host, repository: repo, number: n, title: "t\(n)", state: state,
                        updatedAt: at.map { Date(timeIntervalSince1970: $0) }, baseBranch: base, headBranch: head)
    }

    // MARK: Opening a link in Nook

    func testGitHubLinkOpensAsItem() throws {
        let item = try XCTUnwrap(PullRequestRef.gitHubItem(try XCTUnwrap(URL(string: "https://github.com/IAMichan/Nook/pull/558"))))
        XCTAssertEqual(item.repo, "IAMichan/Nook")
        XCTAssertEqual(item.number, 558)
        XCTAssertEqual(item.url?.absoluteString, "https://github.com/IAMichan/Nook/pull/558")
        XCTAssertNotNil(PullRequestRef.gitHubItem(try XCTUnwrap(URL(string: "https://github.com/acme/app/pull/12/files"))))
    }

    func testLinkWithTrailingPunctuationOrWwwOpensAsItem() throws {
        for text in ["https://github.com/acme/app/pull/12.", "https://github.com/acme/app/pull/12),",
                     "https://www.github.com/acme/app/pull/12", "https://github.com/acme/app/pull/12#issuecomment-1"] {
            let item = try XCTUnwrap(PullRequestRef.gitHubItem(try XCTUnwrap(URL(string: text))), text)
            XCTAssertEqual(item.number, 12, text)
            XCTAssertEqual(item.url?.absoluteString, "https://github.com/acme/app/pull/12", text)
        }
    }

    func testOtherLinksStayInTheBrowser() throws {
        for text in ["https://gitlab.com/acme/app/-/merge_requests/3", "https://github.com/acme/app/issues/4",
                     "https://github.com/acme/app", "https://git.example.com/acme/app/pull/5"] {
            XCTAssertNil(PullRequestRef.gitHubItem(try XCTUnwrap(URL(string: text))), text)
        }
    }

    // MARK: PullRequestRef

    func testParsesUrlsOfEveryHost() throws {
        let cases: [(String, SourceControlHost, String, Int, String)] = [
            ("https://github.com/acme/app/pull/42/files", .github, "acme/app", 42, "https://github.com/acme/app/pull/42"),
            ("https://gitlab.com/g/sub/p/-/merge_requests/7", .gitlab, "g/sub/p", 7, "https://gitlab.com/g/sub/p/-/merge_requests/7"),
            ("https://bitbucket.org/ws/r/pull-requests/3/", .bitbucket, "ws/r", 3, "https://bitbucket.org/ws/r/pull-requests/3"),
            ("https://codeberg.org/o/r/pulls/5", .forgejo, "o/r", 5, "https://codeberg.org/o/r/pulls/5"),
            ("https://gitea.corp.io/o/r/pulls/6", .gitea, "o/r", 6, "https://gitea.corp.io/o/r/pulls/6"),
            ("https://git.cafe/o/r/pulls/8", .gitcafe, "o/r", 8, "https://git.cafe/o/r/pulls/8"),
            ("https://dev.azure.com/org/proj/_git/repo/pullrequest/9", .azureDevOps, "org/proj/_git/repo", 9,
             "https://dev.azure.com/org/proj/_git/repo/pullrequest/9"),
            ("https://org.visualstudio.com/proj/_git/repo/pullrequest/10", .azureDevOps, "org/proj/_git/repo", 10,
             "https://dev.azure.com/org/proj/_git/repo/pullrequest/10"),
            ("https://git.selfhosted.io/g/p/-/merge_requests/11", .gitlab, "g/p", 11, "https://git.selfhosted.io/g/p/-/merge_requests/11"),
            ("https://git.selfhosted.io/o/r/pulls/12", .forgejo, "o/r", 12, "https://git.selfhosted.io/o/r/pulls/12"),
        ]
        for (text, host, repo, number, canonical) in cases {
            let ref = try XCTUnwrap(PullRequestRef.parse(text), text)
            XCTAssertEqual(ref.host, host, text)
            XCTAssertEqual(ref.repository, repo, text)
            XCTAssertEqual(ref.number, number, text)
            XCTAssertEqual(ref.url?.absoluteString, canonical, text)
        }
    }

    func testParsesShortForms() throws {
        let full = try XCTUnwrap(PullRequestRef.parse(" acme/app#12 "))
        XCTAssertEqual(full.repository, "acme/app")
        XCTAssertNil(full.url)
        XCTAssertEqual(full.reference, "acme/app#12")
        let bare = try XCTUnwrap(PullRequestRef.parse("#12"))
        XCTAssertNil(bare.repository)
        XCTAssertEqual(bare.reference, "#12")
        XCTAssertEqual(try XCTUnwrap(PullRequestRef.parse("g/sub/p#1")).repository, "g/sub/p")
    }

    func testReferenceOfAzureDropsGitMarker() throws {
        XCTAssertEqual(PullRequestRef.parse("https://dev.azure.com/o/p/_git/r/pullrequest/2")?.reference, "o/p/r#2")
    }

    func testRejectsNonReferences() {
        for text in ["", "#", "#0", "#abc", "#-3", "12", "owner#1", "a/b#", "https://github.com/a/b", "https://github.com/a/b/pull/x",
                     "https://github.com/a/b/issues/3", "ftp://github.com/a/b/pull/1", "https://example.com/x", "a b/c#1"] {
            XCTAssertNil(PullRequestRef.parse(text), text)
        }
    }

    // MARK: Link coding

    func testLinkRoundTripAndTolerantDecoding() throws {
        let original = link(3, base: "main", head: "x", state: .merged, at: 100)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(PullRequestLink.self, from: data), original)

        let sparse = try JSONDecoder().decode(PullRequestLink.self, from: Data(#"{"number":4,"future":{"a":1},"state":"weird"}"#.utf8))
        XCTAssertEqual(sparse.number, 4)
        XCTAssertEqual(sparse.state, .open)
        XCTAssertEqual(sparse.repository, "")
        XCTAssertNil(sparse.title)
        XCTAssertFalse(sparse.conflicted)
        XCTAssertThrowsError(try JSONDecoder().decode(PullRequestLink.self, from: Data(#"{"repository":"a/b"}"#.utf8)))
    }

    // MARK: Stack

    func testChainsByBaseAndHead() {
        let a = link(1, base: "main", head: "a")
        let b = link(2, base: "a", head: "b")
        let c = link(3, base: "b", head: "c")
        let layers = PullRequestStack.order(links: [a, c, b]).map { $0.map(\.number) }
        XCTAssertEqual(layers, [[3], [2], [1]], "top of the stack first")
    }

    func testSiblingsShareALayerAndUnrelatedStaySeparate() {
        let a = link(1, base: "main", head: "a")
        let b = link(2, base: "a", head: "b")
        let c = link(3, base: "a", head: "c")
        let loose = link(9, base: "main", head: "z")
        XCTAssertEqual(PullRequestStack.order(links: [loose, c, b, a]).map { $0.map(\.number) }, [[2, 3], [1, 9]])
        XCTAssertTrue(PullRequestStack.isStack(links: [a, b]))
        XCTAssertFalse(PullRequestStack.isStack(links: [a, loose]))
    }

    func testStackIgnoresOtherRepositoriesCyclesAndDuplicates() {
        let a = link(1, base: "main", head: "a")
        let other = link(2, base: "a", head: "b", repo: "x/y")
        XCTAssertEqual(PullRequestStack.order(links: [a, other]).count, 1)
        let p = link(1, base: "q", head: "p"), q = link(2, base: "p", head: "q")
        XCTAssertFalse(PullRequestStack.order(links: [p, q]).isEmpty)
        XCTAssertEqual(PullRequestStack.order(links: [a, a]).flatMap { $0 }.count, 1)
        XCTAssertTrue(PullRequestStack.order(links: []).isEmpty)
    }

    func testChainsThroughTheLiveDuplicateHead() {
        let old = link(1, base: "main", head: "a", state: .closed)
        let live = link(5, base: "main", head: "a")
        let child = link(6, base: "a", head: "b")
        XCTAssertEqual(PullRequestStack.order(links: [old, live, child]).map { $0.map(\.number) }, [[6], [1, 5]])
    }

    // MARK: Badge

    func testBadgeForOneManyAndStack() {
        XCTAssertNil(PullRequestBadge.text(links: []))
        let one = PullRequestBadge.text(links: [link(12, state: .draft)])
        XCTAssertEqual(one, PullRequestBadge(glyph: .draft, label: .number(12)))
        XCTAssertEqual(one?.text, "#12")
        let many = PullRequestBadge.text(links: [link(12, head: "a"), link(13, head: "b", state: .merged), link(14, head: "c", state: .closed)])
        XCTAssertEqual(many, PullRequestBadge(glyph: .open, label: .numberPlus(12, extra: 2)))
        XCTAssertEqual(many?.text, "#12 +2")
        let stack = PullRequestBadge.text(links: [link(1, base: "main", head: "a"), link(2, base: "a", head: "b"), link(3, base: "b", head: "c")])
        XCTAssertEqual(stack, PullRequestBadge(glyph: .stack, label: .stack(3, merged: 0)))
        XCTAssertNil(stack?.text)
    }

    func testAStackBadgeSaysHowFarItMerged() {
        let part = PullRequestBadge.text(links: [link(1, base: "main", head: "a", state: .merged), link(2, base: "a", head: "b"),
                                                 link(3, base: "b", head: "c")])
        XCTAssertEqual(part, PullRequestBadge(glyph: .stack, label: .stack(3, merged: 1)))
        let all = PullRequestBadge.text(links: [link(1, base: "main", head: "a", state: .merged), link(2, base: "a", head: "b", state: .merged)])
        XCTAssertEqual(all, PullRequestBadge(glyph: .merged, label: .stack(2, merged: 2)))
        let dropped = PullRequestBadge.text(links: [link(1, base: "main", head: "a", state: .closed), link(2, base: "a", head: "b", state: .closed)])
        XCTAssertEqual(dropped, PullRequestBadge(glyph: .closed, label: .stack(2, merged: 0)))
    }

    func testBadgePrefersUnresolvedThenMergedOverClosed() {
        XCTAssertEqual(PullRequestBadge.text(links: [link(1, state: .closed), link(2, state: .merged)])?.glyph, .merged)
        XCTAssertEqual(PullRequestBadge.text(links: [link(1, state: .open), link(2, state: .merged)])?.label, .numberPlus(1, extra: 1))
    }

    func testBadgeShowsAMergeConflictOnlyWhileOpen() {
        var conflicted = link(5)
        conflicted.conflicted = true
        XCTAssertEqual(PullRequestBadge.text(links: [conflicted]), PullRequestBadge(glyph: .conflict, label: .number(5)))
        conflicted.state = .draft
        XCTAssertEqual(PullRequestBadge.text(links: [conflicted])?.glyph, .conflict)
        conflicted.state = .merged
        XCTAssertEqual(PullRequestBadge.text(links: [conflicted])?.glyph, .merged)
        XCTAssertEqual(PullRequestBadge.text(links: [link(6)])?.glyph, .open)
    }

    func testMergeabilityOfEachForge() {
        XCTAssertTrue(PullRequestMergeability.githubConflicted(["mergeable": false, "mergeable_state": "dirty"]))
        XCTAssertTrue(PullRequestMergeability.githubConflicted(["mergeable_state": "dirty"]))
        XCTAssertFalse(PullRequestMergeability.githubConflicted(["mergeable": true, "mergeable_state": "clean"]))
        XCTAssertFalse(PullRequestMergeability.githubConflicted(["mergeable": NSNull(), "mergeable_state": "unknown"]))
        XCTAssertTrue(PullRequestMergeability.gitlabConflicted(["has_conflicts": true]))
        XCTAssertTrue(PullRequestMergeability.gitlabConflicted(["detailed_merge_status": "conflict"]))
        XCTAssertFalse(PullRequestMergeability.gitlabConflicted(["has_conflicts": false, "detailed_merge_status": "mergeable"]))
    }

    // MARK: Composer match

    func testMatchNumberPrefixOnlyForDigits() {
        let list = [(number: 12, title: "Fix 13 bug"), (number: 120, title: "Docs"), (number: 3, title: "Add 12 things"), (number: 21, title: "x")]
        XCTAssertEqual(PullRequestMatch.filter(list, query: "12").map(\.number), [12, 120])
        XCTAssertEqual(PullRequestMatch.filter(list, query: "#12").map(\.number), [12, 120])
        XCTAssertEqual(PullRequestMatch.filter(list, query: "9").map(\.number), [])
    }

    func testMatchTitleContainsCaseInsensitiveAndLimit() {
        let list = (1...10).map { (number: $0, title: "Résumé page \($0)") }
        XCTAssertEqual(PullRequestMatch.filter(list, query: "RESUME").count, 6)
        XCTAssertEqual(PullRequestMatch.filter(list, query: "").count, 6)
        XCTAssertEqual(PullRequestMatch.filter(list, query: "  ").map(\.number), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(PullRequestMatch.filter(list, query: "nothing").count, 0)
        XCTAssertEqual(PullRequestMatch.filter(list, query: "page 7").map(\.number), [7])
    }

    // MARK: Rounds

    func testASlowHostHoldsUpOnlyItsOwnBranches() {
        let old = Date(timeIntervalSince1970: 0), recent = Date(timeIntervalSince1970: 100)
        let due: [PullRequestRound.Due<String>] = [
            .init(lane: "github.com", job: "gh-closed-old", open: false, last: old),
            .init(lane: "github.com", job: "gh-closed-recent", open: false, last: recent),
            .init(lane: "github.com", job: "gh-open", open: true, last: recent),
            .init(lane: "gitlab.slow", job: "gl", open: true, last: old),
            .init(lane: "", job: "unknown", open: false, last: old)
        ]
        let all = PullRequestRound.plan(due, busy: [], perRound: 2)
        XCTAssertEqual(all.map(\.lane), ["", "github.com", "gitlab.slow"])
        XCTAssertEqual(all[1].jobs, ["gh-open", "gh-closed-old"], "open first, then the longest unasked, at most perRound")
        let waiting = PullRequestRound.plan(due, busy: ["gitlab.slow"], perRound: 8)
        XCTAssertEqual(waiting.map(\.lane), ["", "github.com"], "its jobs wait; the others go on")
    }

    // MARK: Settlement

    func testSyncSlowsDownForWhatHasBeenQuietForADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = now.addingTimeInterval(-3_600)
        let old = now.addingTimeInterval(-3 * 86_400)
        func link(_ state: PullRequestState, updated: Date?) -> PullRequestLink {
            PullRequestLink(host: .github, repository: "a/b", number: 1, state: state, updatedAt: updated)
        }
        // An open request is asked about at the same pace however old it is.
        XCTAssertEqual(PullRequestSettlement.syncInterval(links: [link(.open, updated: old)], now: now), 30)
        XCTAssertEqual(PullRequestSettlement.syncInterval(links: [link(.merged, updated: recent)], now: now), 900)
        XCTAssertEqual(PullRequestSettlement.syncInterval(links: [link(.merged, updated: old)], now: now), 21_600)
        XCTAssertEqual(PullRequestSettlement.syncInterval(links: [link(.closed, updated: old), link(.merged, updated: recent)], now: now), 900)
        // A session at work on a branch that merged long ago can get a new request.
        XCTAssertEqual(PullRequestSettlement.syncInterval(links: [link(.merged, updated: old)], quietSince: recent, now: now), 900)
        // No date to go on: stays at the merged pace.
        XCTAssertEqual(PullRequestSettlement.syncInterval(links: [link(.merged, updated: nil)], now: now), 900)
        XCTAssertEqual(PullRequestSettlement.syncInterval(links: [], quietSince: recent, now: now), 60)
        XCTAssertEqual(PullRequestSettlement.syncInterval(links: [], quietSince: old, now: now), 900)
        XCTAssertEqual(PullRequestSettlement.syncInterval(links: [], now: now), 60)
    }

    func testSettlementRules() {
        XCTAssertFalse(PullRequestSettlement.shouldSettle(links: []))
        XCTAssertFalse(PullRequestSettlement.allMerged(links: []))
        let merged = link(1, state: .merged, at: 10), closed = link(2, state: .closed, at: 20)
        XCTAssertTrue(PullRequestSettlement.allMerged(links: [merged]))
        XCTAssertFalse(PullRequestSettlement.allMerged(links: [merged, closed]))
        XCTAssertTrue(PullRequestSettlement.shouldSettle(links: [merged]))
        XCTAssertFalse(PullRequestSettlement.shouldSettle(links: [merged], settleOnMerge: false))
        XCTAssertTrue(PullRequestSettlement.shouldSettle(links: [merged], settleOnMerge: false) == false)
        XCTAssertTrue(PullRequestSettlement.shouldSettle(links: [merged, closed], settleOnMerge: false), "newest is closed")
        XCTAssertTrue(PullRequestSettlement.anyOpen(links: [merged, link(3, state: .draft)]))
        XCTAssertFalse(PullRequestSettlement.shouldSettle(links: [merged, link(3, state: .open)]))
        XCTAssertFalse(PullRequestSettlement.shouldSettle(links: [merged, link(3, state: .draft)]), "a draft is unresolved")
    }

    func testSettlementReverseState() {
        var links = [link(1, state: .open)]
        XCTAssertFalse(PullRequestSettlement.shouldSettle(links: links))
        links[0].state = .merged
        XCTAssertTrue(PullRequestSettlement.shouldSettle(links: links))
        links[0].state = .open
        XCTAssertFalse(PullRequestSettlement.shouldSettle(links: links), "a reopened PR keeps the session")
    }

    func testNeedsSyncOncePerMinute() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(PullRequestSettlement.needsSync(lastChecked: nil, now: now))
        XCTAssertFalse(PullRequestSettlement.needsSync(lastChecked: now.addingTimeInterval(-59), now: now))
        XCTAssertTrue(PullRequestSettlement.needsSync(lastChecked: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(PullRequestSettlement.needsSync(lastChecked: now.addingTimeInterval(30), now: now), "clock went back")
        XCTAssertFalse(PullRequestSettlement.needsSync(lastChecked: now.addingTimeInterval(-100), now: now, interval: 300))
    }

    func testSyncIntervalFollowsTheState() {
        XCTAssertEqual(PullRequestSettlement.syncInterval(links: [link(1)]), 30)
        XCTAssertEqual(PullRequestSettlement.syncInterval(links: [link(1, state: .merged), link(2, state: .draft)]), 30)
        XCTAssertEqual(PullRequestSettlement.syncInterval(links: []), 60)
        XCTAssertEqual(PullRequestSettlement.syncInterval(links: [link(1, state: .merged)]), 900)
    }

    // MARK: BranchPolicy

    func testDefaultBranches() {
        for name in ["main", "master", "trunk", "develop", "origin/main", "refs/heads/master", "Main"] {
            XCTAssertTrue(BranchPolicy.isDefaultBranch(name), name)
        }
        XCTAssertFalse(BranchPolicy.isDefaultBranch("feature/x"))
        XCTAssertFalse(BranchPolicy.isDefaultBranch("release"))
        XCTAssertTrue(BranchPolicy.isDefaultBranch("release", detectedDefault: "origin/release"))
        XCTAssertFalse(BranchPolicy.isDefaultBranch("feature/x", detectedDefault: "release"))
    }

    func testSuggestedBranchNameAvoidsExisting() {
        let id = UUID(uuidString: "3FA2B1C4-0000-0000-0000-000000000000")!
        let first = BranchPolicy.suggestBranchName(task: "Fix de login-bug!", id: id, existing: [])
        XCTAssertEqual(first, "nook/fix-de-login-bug-3fa2")
        let second = BranchPolicy.suggestBranchName(task: "Fix de login-bug!", id: id, existing: [first])
        XCTAssertEqual(second, "nook/fix-de-login-bug-3fa2b1")
        let third = BranchPolicy.suggestBranchName(task: "Fix de login-bug!", id: id, existing: [first.uppercased(), second])
        XCTAssertEqual(third, "nook/fix-de-login-bug-3fa2b1c4")
        let all = Set(["nook/fix-de-login-bug-3fa2", "nook/fix-de-login-bug-3fa2b1", "nook/fix-de-login-bug-3fa2b1c4",
                       "nook/fix-de-login-bug-3fa2b1c400000000", "nook/fix-de-login-bug-3fa2b1c400000000-2"])
        let last = BranchPolicy.suggestBranchName(task: "Fix de login-bug!", id: id, existing: all)
        XCTAssertFalse(all.contains(last))
        XCTAssertEqual(BranchPolicy.suggestBranchName(task: "", id: id, prefix: "wt/", existing: []), "wt/sessie-3fa2")
    }

    func testShownPullRequestPrefersOpenThenNewestLanded() {
        let old = PullRequestLink(host: .github, repository: "o/r", number: 3, url: "https://github.com/o/r/pull/3",
                                  state: .closed, updatedAt: Date(timeIntervalSince1970: 100))
        let merged = PullRequestLink(host: .github, repository: "o/r", number: 7, url: "https://github.com/o/r/pull/7",
                                     state: .merged, updatedAt: Date(timeIntervalSince1970: 200))
        let open = PullRequestLink(host: .gitlab, repository: "o/r", number: 9, url: "https://gitlab.com/o/r/-/merge_requests/9")
        let other = PullRequestLink(host: .bitbucket, repository: "o/r", number: 11, url: "https://bitbucket.org/o/r/pull-requests/11")
        XCTAssertEqual(PullRequestLink.shown(in: [old, merged, open])?.absoluteString, open.url)
        XCTAssertEqual(PullRequestLink.shown(in: [merged, old])?.absoluteString, merged.url)
        XCTAssertNil(PullRequestLink.shown(in: [other]))
        XCTAssertNil(PullRequestLink.shown(in: []))
    }

    func testBadgeFromALinkAlone() {
        let url = URL(string: "https://github.com/o/r/pull/3265")!
        XCTAssertEqual(PullRequestBadge.link(url, glyph: nil), PullRequestBadge(glyph: .open, label: .number(3265)))
        XCTAssertEqual(PullRequestBadge.link(url, glyph: .merged)?.glyph, .merged)
        XCTAssertEqual(PullRequestBadge.link(URL(string: "https://gitlab.com/o/r/-/merge_requests/9")!, glyph: nil)?.label, .number(9))
        XCTAssertNil(PullRequestBadge.link(URL(string: "https://github.com/o/r")!, glyph: nil))
    }

    func testFastForwardDecision() {
        XCTAssertEqual(BranchPolicy.shouldFastForward(ahead: 0, behind: 0, dirty: false), .upToDate)
        XCTAssertEqual(BranchPolicy.shouldFastForward(ahead: 2, behind: 0, dirty: true), .upToDate)
        XCTAssertEqual(BranchPolicy.shouldFastForward(ahead: 0, behind: 3, dirty: false), .fastForward)
        XCTAssertEqual(BranchPolicy.shouldFastForward(ahead: 0, behind: 3, dirty: true), .skipDirty)
        XCTAssertEqual(BranchPolicy.shouldFastForward(ahead: 1, behind: 3, dirty: false), .skipDiverged)
        XCTAssertEqual(BranchPolicy.shouldFastForward(ahead: 1, behind: 3, dirty: true), .skipDiverged)
    }

    // MARK: A session's branches

    func testLeavingBranchKeepsEarlierOnesInOrder() {
        XCTAssertEqual(SessionBranches.leaving("feat-a", for: "feat-b", earlier: nil, base: "main"), ["feat-a"])
        XCTAssertEqual(SessionBranches.leaving("feat-b", for: "feat-c", earlier: ["feat-a"], base: "main"), ["feat-a", "feat-b"])
        XCTAssertNil(SessionBranches.leaving("main", for: "feat-a", earlier: nil, base: "main"), "the default branch is not listed")
        XCTAssertEqual(SessionBranches.leaving("feat-b", for: "feat-a", earlier: ["feat-a"], base: nil), ["feat-b"],
                       "going back to a branch takes it out of the earlier ones")
    }

    func testKeepingReplacesAnOlderReadOfTheSameRequest() {
        var first = link(1, head: "feat-a"); first.url = "https://github.com/a/b/pull/1"
        var merged = first; merged.state = .merged
        var second = link(2, head: "feat-b"); second.url = "https://github.com/a/b/pull/2"
        let kept = SessionBranches.keeping([merged, second], in: [first])
        XCTAssertEqual(kept.map(\.number), [1, 2])
        XCTAssertEqual(kept.first?.state, .merged)
    }

    func testSessionPullRequestsKeepAnEarlierBranchsRequestInView() {
        var merged = link(1, head: "feat-a"); merged.state = .merged
        let moved = SessionPullRequests(current: [], earlier: [merged])
        XCTAssertEqual(moved.badge, PullRequestBadge(glyph: .merged, label: .number(1)), "a new worktree without a request still shows the last one")
        let both = SessionPullRequests(current: [link(2, head: "feat-b")], earlier: [merged, link(2, head: "feat-b")])
        XCTAssertEqual(both.current.map(\.number), [2])
        XCTAssertEqual(both.earlier.map(\.number), [1], "a request of the current branch is not listed again")
        XCTAssertEqual(both.badge, PullRequestBadge(glyph: .open, label: .numberPlus(2, extra: 1)))
    }

    func testSessionPullRequestsListEarlierOnesNewestFirst() {
        var old = link(1, head: "a"); old.updatedAt = Date(timeIntervalSince1970: 100)
        var new = link(2, head: "b"); new.updatedAt = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(SessionPullRequests(current: [], earlier: [old, new]).earlier.map(\.number), [2, 1])
    }

    func testRowsListEveryBranchWithItsPullRequest() {
        var first = link(1, head: "feat-a"); first.url = "https://github.com/a/b/pull/1"
        let current = URL(string: "https://github.com/a/b/pull/2")!
        let rows = SessionBranches.rows(earlier: ["feat-a"], earlierLinks: [first], current: "feat-b", currentPullRequest: current)
        XCTAssertEqual(rows.map(\.branch), ["feat-a", "feat-b"])
        XCTAssertEqual(rows.map(\.pullRequest), [URL(string: first.url), current])
        XCTAssertEqual(rows.map(\.isCurrent), [false, true])
    }

    func testRowsAreEmptyForASessionWithOneBranch() {
        let current = URL(string: "https://github.com/a/b/pull/2")!
        XCTAssertTrue(SessionBranches.rows(earlier: [], earlierLinks: [], current: "feat-b", currentPullRequest: current).isEmpty)
    }

    func testOnlyABranchWithoutWorkCountsAsEmpty() {
        // A question answered without changes, then the agent branched off for the change: the first branch is empty.
        XCTAssertTrue(SessionBranches.isEmpty(aheadOfBase: 0, pushed: false))
        XCTAssertFalse(SessionBranches.isEmpty(aheadOfBase: 2, pushed: false))
        XCTAssertFalse(SessionBranches.isEmpty(aheadOfBase: 0, pushed: true))
        XCTAssertFalse(SessionBranches.isEmpty(aheadOfBase: nil, pushed: false))
        // Its worktree and branch removed, never pushed: nothing is left of it.
        XCTAssertTrue(SessionBranches.isEmpty(aheadOfBase: nil, pushed: false, exists: false))
        XCTAssertFalse(SessionBranches.isEmpty(aheadOfBase: nil, pushed: true, exists: false))
    }

    func testAWatchedEarlierPullRequestIsNotShownTwice() {
        var first = link(1, head: "feat-a"); first.url = "https://github.com/a/b/pull/1"
        let watched = URL(string: first.url)!
        let rows = SessionBranches.rows(earlier: ["feat-a"], earlierLinks: [first], current: "feat-b", currentPullRequest: watched)
        XCTAssertEqual(rows.map(\.pullRequest), [watched, nil])
    }

    func testAWatchedEarlierPullRequestLeavesTheCurrentBranchItsOwn() {
        var first = link(1, head: "feat-a"); first.url = "https://github.com/a/b/pull/1"
        var second = link(2, head: "feat-b"); second.url = "https://github.com/a/b/pull/2"
        let rows = SessionBranches.rows(earlier: ["feat-a"], earlierLinks: [first], current: "feat-b",
                                        currentPullRequest: URL(string: first.url), currentLinks: [second])
        XCTAssertEqual(rows.map(\.pullRequest), [URL(string: first.url), URL(string: second.url)])
    }

    func testAWatchedEarlierPullRequestOfAnUnnamedBranchKeepsItsRow() {
        var first = link(1, head: "feat-a"); first.url = "https://github.com/a/b/pull/1"
        var second = link(2, head: "feat-b"); second.url = "https://github.com/a/b/pull/2"
        let rows = SessionBranches.rows(earlier: [], earlierLinks: [first], current: "feat-b",
                                        currentPullRequest: URL(string: first.url), currentLinks: [second])
        XCTAssertEqual(rows.map(\.pullRequest), [URL(string: first.url), URL(string: second.url)])
    }

    func testTheWatchedOneOfTheCurrentBranchStaysItsRow() {
        var first = link(1, head: "feat-a"); first.url = "https://github.com/a/b/pull/1"
        var older = link(2, head: "feat-b"); older.url = "https://github.com/a/b/pull/2"; older.state = .closed
        var newer = link(3, head: "feat-b"); newer.url = "https://github.com/a/b/pull/3"
        let rows = SessionBranches.rows(earlier: ["feat-a"], earlierLinks: [first], current: "feat-b",
                                        currentPullRequest: URL(string: older.url), currentLinks: [newer, older])
        XCTAssertEqual(rows.last?.pullRequest, URL(string: older.url))
    }

    func testManyBranchesFoldTheOlderOnes() {
        let url = URL(string: "https://github.com/a/b/pull/1")!
        let rows = [SessionBranches.Row(branch: "a", pullRequest: url, isCurrent: false),
                    SessionBranches.Row(branch: "b", pullRequest: nil, isCurrent: false),
                    SessionBranches.Row(branch: "c", pullRequest: nil, isCurrent: false),
                    SessionBranches.Row(branch: "d", pullRequest: nil, isCurrent: false),
                    SessionBranches.Row(branch: "e", pullRequest: nil, isCurrent: true)]
        let folded = SessionBranches.folded(rows, open: false)
        XCTAssertEqual(folded.shown.map(\.branch), ["c", "d", "e"])
        XCTAssertEqual(folded.hidden, 2)
        XCTAssertEqual(folded.hiddenPullRequests, 1)
        XCTAssertEqual(SessionBranches.folded(rows, open: true).shown.count, 5)
        XCTAssertEqual(SessionBranches.folded(Array(rows.suffix(4)), open: false).hidden, 0, "four rows stay open: folding one saves nothing")
    }

    func testOnlyACallThatMakesOrShowsAPullRequestLendsItsOutputLink() {
        XCTAssertTrue(PullRequestToolCall.showsPullRequest(tool: "Bash", command: ["gh pr create --fill"]))
        XCTAssertTrue(PullRequestToolCall.showsPullRequest(tool: "Bash", command: ["git push && gh pr view --json url"]))
        XCTAssertTrue(PullRequestToolCall.showsPullRequest(tool: "shell", command: [nil, "glab mr create -t Fix"]))
        XCTAssertTrue(PullRequestToolCall.showsPullRequest(tool: "pull_request_create", command: []))
        XCTAssertTrue(PullRequestToolCall.showsPullRequest(tool: "mcp__github__create_pull_request", command: []))
        // Editing or testing pull request code prints sample links that are no pull request of this session.
        XCTAssertFalse(PullRequestToolCall.showsPullRequest(
            tool: "Bash", command: ["python3 - <<'EOF' p='apps/macos/Services/Connectors/PullRequestActions.swift'"]))
        XCTAssertFalse(PullRequestToolCall.showsPullRequest(tool: "Bash", command: ["./scripts/core-tests.sh --filter PullRequestStackTests"]))
        XCTAssertFalse(PullRequestToolCall.showsPullRequest(tool: "Read", command: ["docs/pull_request_template.md"]))
        XCTAssertFalse(PullRequestToolCall.showsPullRequest(tool: "Bash", command: ["gh pr list", "gh prompt create"]))
    }
}
