import XCTest

/// Pull requests on the phone (`CompanionPullRequests.swift`): the wire shape both sides share, the rules for actions,
/// the patch budget and the phone's offline cache.
final class CompanionPullRequestsTests: XCTestCase {
    private func pull(_ number: Int, state: String = "open", updated: Double = 0, group: String = "mine",
                      url: String? = nil) -> PullDigest {
        PullDigest(url: url ?? "https://github.com/o/r/pull/\(number)", repo: "o/r", number: number, title: "PR \(number)",
                   author: "ada", state: state, ci: "passing", review: "none", conflict: false, additions: 1, deletions: 2,
                   updated: updated, group: group, headBranch: "feature", baseBranch: "main")
    }

    private func detail(files: [PullDetailDigest.File] = []) -> PullDetailDigest {
        PullDetailDigest(url: "https://github.com/o/r/pull/1", repo: "o/r", number: 1, title: "T", body: "B", author: "ada",
                         state: "open", baseBranch: "main", headBranch: "feature", headSHA: "abc", additions: 1, deletions: 0,
                         changedFiles: files.count, updated: 10, checks: [.init(name: "ci", outcome: "passing", detail: "success")],
                         files: files, verdicts: [.init(author: "bob", approved: true)], methods: ["squash", "merge"],
                         blocker: nil, verdictsAllowed: true, lineComments: true, fetched: 20)
    }

    // MARK: Wire

    func testRequestsWithPullActionsRoundTrip() throws {
        let action = CompanionPullAction(kind: .comment, body: "Looks good",
                                         comments: [.init(path: "a.swift", line: 4, side: "RIGHT", body: "nit", startLine: 2)],
                                         method: nil, path: nil, head: "abc")
        let request = CompanionRequest(op: .pullAct, item: "https://github.com/o/r/pull/1", pullAction: action)
        let decoded = try JSONDecoder().decode(CompanionRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)
        let work = CompanionRequest(op: .pullWork, pullWork: PullWorkRequest(url: "https://github.com/o/r/pull/1", agent: "codex", task: "fix", model: nil))
        XCTAssertEqual(try JSONDecoder().decode(CompanionRequest.self, from: JSONEncoder().encode(work)), work)
    }

    func testAnswersWithPullsRoundTripAndOldAnswersStillRead() throws {
        var response = CompanionResponse(id: "1", ok: true)
        response.pulls = [pull(1)]
        response.pull = detail(files: [.init(path: "a", status: "modified", additions: 1, deletions: 0, patch: "@@", truncated: false, viewed: "viewed")])
        XCTAssertEqual(try JSONDecoder().decode(CompanionResponse.self, from: JSONEncoder().encode(response)), response)
        // An answer from a Mac before pull requests has neither.
        let old = try JSONDecoder().decode(CompanionResponse.self, from: Data(#"{"id":"1","ok":true}"#.utf8))
        XCTAssertNil(old.pulls)
        XCTAssertNil(old.pull)
    }

    func testAnUnknownOpFromANewerPhoneDoesNotDecode() {
        // The Mac answers it `badRequest` rather than guessing (the phone only sends what `features` lists).
        XCTAssertThrowsError(try JSONDecoder().decode(CompanionRequest.self, from: Data(#"{"id":"1","sent":0,"op":"pullFuture"}"#.utf8)))
    }

    func testPullRequestOpsNeedTheirScopes() {
        XCTAssertTrue(CompanionScopes.allows(.pulls, granted: [.read]))
        XCTAssertTrue(CompanionScopes.allows(.pull, granted: [.read]))
        XCTAssertFalse(CompanionScopes.allows(.pullAct, granted: [.read, .approve]), "merging acts for you")
        XCTAssertTrue(CompanionScopes.allows(.pullAct, granted: [.operate]))
        XCTAssertTrue(CompanionScopes.allows(.pullWork, granted: [.operate]))
        var response = CompanionResponse(id: "1", ok: true, features: CompanionFeature.all)
        response.pulls = [pull(1)]
        response.pull = detail()
        let redacted = CompanionScopes.redact(response, granted: [.approve])
        XCTAssertNil(redacted.pulls)
        XCTAssertNil(redacted.pull)
        XCTAssertFalse(redacted.features?.contains(CompanionFeature.pullRequests) ?? true)
        XCTAssertFalse(redacted.features?.contains(CompanionFeature.attachments) ?? true)
    }

    func testActionsAreKeptAsReceiptsAndReadsAreNot() {
        XCTAssertTrue(CommandReceipts.keeps(.pullAct))
        XCTAssertTrue(CommandReceipts.keeps(.pullWork))
        XCTAssertFalse(CommandReceipts.keeps(.pulls))
        XCTAssertFalse(CommandReceipts.keeps(.pull))
        XCTAssertFalse(CompanionOutbox.queues(.pullAct), "a merge means something only now")
    }

    // MARK: Actions

    func testWhatAnActionNeeds() {
        XCTAssertTrue(CompanionPullAction(kind: .approve).isValid)
        XCTAssertFalse(CompanionPullAction(kind: .requestChanges, body: "  ").isValid, "a request for changes says what")
        XCTAssertTrue(CompanionPullAction(kind: .requestChanges, body: "Please rename").isValid)
        XCTAssertFalse(CompanionPullAction(kind: .comment).isValid)
        XCTAssertTrue(CompanionPullAction(kind: .comment, comments: [.init(path: "a", line: 1, side: "RIGHT", body: "x")]).isValid,
                      "line comments alone make a review")
        XCTAssertFalse(CompanionPullAction(kind: .merge).isValid, "a merge names the head it saw")
        XCTAssertTrue(CompanionPullAction(kind: .merge, head: "abc").isValid)
        XCTAssertFalse(CompanionPullAction(kind: .merge, method: "octopus", head: "abc").isValid)
        XCTAssertFalse(CompanionPullAction(kind: .viewed).isValid)
        XCTAssertTrue(CompanionPullAction(kind: .unviewed, path: "a.swift").isValid)
    }

    func testLineCommentsMustPointAtALine() {
        func comment(_ note: CompanionPullAction.LineComment) -> Bool { CompanionPullAction(kind: .comment, comments: [note]).isValid }
        XCTAssertFalse(comment(.init(path: "a", line: 0, side: "RIGHT", body: "x")))
        XCTAssertFalse(comment(.init(path: "a", line: 3, side: "MIDDLE", body: "x")))
        XCTAssertFalse(comment(.init(path: "a", line: 3, side: "LEFT", body: " ")))
        XCTAssertFalse(comment(.init(path: "a", line: 3, side: "LEFT", body: "x", startLine: 5)), "a range starts before it ends")
        XCTAssertTrue(comment(.init(path: "a", line: 5, side: "LEFT", body: "x", startLine: 3)))
        let many = (1...51).map { CompanionPullAction.LineComment(path: "a", line: $0, side: "RIGHT", body: "x") }
        XCTAssertFalse(CompanionPullAction(kind: .comment, comments: many).isValid)
    }

    // MARK: Budget

    func testPatchesAreCutToFitOneAnswer() {
        let line = String(repeating: "x", count: 99) + "\n"
        let big = String(repeating: line, count: 600) // 60 KB
        let files = (0..<4).map { PullDetailDigest.File(path: "f\($0)", status: "modified", additions: 1, deletions: 1, patch: big,
                                                         truncated: false, viewed: "unviewed") }
        let cut = PullDetailDigest.budgeted(files, each: 40 * 1024, total: 100 * 1024)
        XCTAssertTrue(cut[0].truncated)
        XCTAssertLessThanOrEqual(cut[0].patch?.utf8.count ?? 0, 40 * 1024)
        XCTAssertTrue(cut[0].patch?.hasSuffix("x") ?? false, "cut at a whole line")
        XCTAssertNotNil(cut[1].patch)
        XCTAssertNil(cut[2].patch, "past the budget a file keeps its counts only")
        XCTAssertTrue(cut[2].truncated)
        XCTAssertEqual(cut[3].additions, 1)
        let small = PullDetailDigest.budgeted([files[0]].map { var f = $0; f.patch = "@@ -1 +1 @@\n-a\n+b"; return f })
        XCTAssertFalse(small[0].truncated)
    }

    func testListsPutOpenAndNewestFirstAndEachPullOnce() {
        let list = PullDigest.trimmed([pull(1, state: "merged", updated: 50), pull(2, updated: 10), pull(3, updated: 30),
                                       pull(2, updated: 10, group: "linked"), pull(4, state: "draft", updated: 5)], limit: 3)
        XCTAssertEqual(list.map(\.number), [3, 2, 4])
        XCTAssertEqual(list.first { $0.number == 2 }?.group, "mine", "the first group that lists it wins")
    }

    // MARK: Offline

    func testTheCacheKeepsTheNewestDetailsAndNeverGoesBack() {
        var cache = PullCache()
        for number in 1...12 {
            var read = detail()
            read.url = "https://github.com/o/r/pull/\(number)"
            cache.record(read, at: Date(timeIntervalSince1970: Double(number)))
        }
        XCTAssertEqual(cache.details.count, PullCache.maxDetails)
        XCTAssertNil(cache.detail("https://github.com/o/r/pull/1"))
        XCTAssertNotNil(cache.detail("HTTPS://github.com/o/r/pull/12"))
        var older = detail()
        older.url = "https://github.com/o/r/pull/12"
        older.title = "old"
        cache.record(older, at: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(cache.detail(older.url)?.detail.title, "T")

        cache.record(list: [pull(1)], at: Date(timeIntervalSince1970: 100))
        cache.record(list: [], at: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(cache.list.count, 1, "an older list never replaces a newer one")
        let data = try? JSONEncoder().encode(cache)
        XCTAssertEqual(data.flatMap { try? JSONDecoder().decode(PullCache.self, from: $0) }, cache)
    }

    func testTheCacheKeepsLinkedListsOfAFewSessions() {
        var cache = PullCache()
        for index in 0..<(PullCache.maxLinkedSessions + 3) { cache.record(linked: [pull(index)], session: String(format: "s%03d", index)) }
        XCTAssertEqual(cache.linked.count, PullCache.maxLinkedSessions)
        XCTAssertNotNil(cache.linked[String(format: "s%03d", PullCache.maxLinkedSessions + 2)], "the newest stays")
    }

    func testBlockersNameTheQuickMergeReasons() {
        // The Mac maps `PullRequestQuickRunner.blocker` keys ("agents.pulls.quick.blocked.<reason>") onto these.
        for reason in ["merged", "closed", "draft", "access", "conflict", "checks"] {
            XCTAssertNotNil(PullMergeBlocker(rawValue: reason), reason)
        }
    }
}
