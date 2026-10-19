import XCTest

final class PullRequestLinksTests: XCTestCase {
    private func link(_ n: Int, base: String? = nil, head: String? = nil, state: PullRequestState = .open,
                      at: Double? = nil, repo: String = "a/b", host: SourceControlHost = .github) -> PullRequestLink {
        PullRequestLink(host: host, repository: repo, number: n, title: "t\(n)", state: state,
                        updatedAt: at.map { Date(timeIntervalSince1970: $0) }, baseBranch: base, headBranch: head)
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
        XCTAssertEqual(stack, PullRequestBadge(glyph: .stack, label: .stack(3)))
        XCTAssertNil(stack?.text)
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

    // MARK: Settlement

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

    func testFastForwardDecision() {
        XCTAssertEqual(BranchPolicy.shouldFastForward(ahead: 0, behind: 0, dirty: false), .upToDate)
        XCTAssertEqual(BranchPolicy.shouldFastForward(ahead: 2, behind: 0, dirty: true), .upToDate)
        XCTAssertEqual(BranchPolicy.shouldFastForward(ahead: 0, behind: 3, dirty: false), .fastForward)
        XCTAssertEqual(BranchPolicy.shouldFastForward(ahead: 0, behind: 3, dirty: true), .skipDirty)
        XCTAssertEqual(BranchPolicy.shouldFastForward(ahead: 1, behind: 3, dirty: false), .skipDiverged)
        XCTAssertEqual(BranchPolicy.shouldFastForward(ahead: 1, behind: 3, dirty: true), .skipDiverged)
    }
}
