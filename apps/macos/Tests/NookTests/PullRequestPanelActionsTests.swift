import XCTest

final class PullRequestPanelActionsTests: XCTestCase {
    private func request(_ action: PullRequestAction) -> PullRequestAction.Request? { action.request(repo: "acme/app", number: 7) }

    func testReviewWithLineCommentsSendsThemTogether() throws {
        let comment = PullRequestAction.LineComment(path: "a.swift", line: 3, side: "LEFT", body: "why?")
        let spec = try XCTUnwrap(request(.reviewWithComments(.comment, body: "", commit: "abc", comments: [comment])))
        XCTAssertEqual(spec.path, "/repos/acme/app/pulls/7/reviews")
        let body = try XCTUnwrap(spec.body)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body), "it goes out as JSON")
        let sent = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: body)) as? [String: Any])
        XCTAssertEqual(sent["commit_id"] as? String, "abc")
        XCTAssertNil(sent["body"], "the comments are the words of the review")
        let first = try XCTUnwrap((sent["comments"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["side"] as? String, "LEFT")
        XCTAssertEqual(first["line"] as? Int, 3)
    }

    func testReviewWithoutLineCommentsStillNeedsWords() {
        XCTAssertNil(request(.reviewWithComments(.comment, body: " ", commit: "abc", comments: [])))
        XCTAssertNotNil(request(.reviewWithComments(.approve, body: "", commit: "abc", comments: [])))
    }

    func testReplyAndEditGoToTheRightComment() {
        XCTAssertEqual(request(.reply(to: 5, body: "ok"))?.path, "/repos/acme/app/pulls/7/comments/5/replies")
        XCTAssertNil(request(.reply(to: 5, body: "  ")))
        XCTAssertEqual(request(.editComment(id: 5, lineComment: true, body: "x"))?.path, "/repos/acme/app/pulls/comments/5")
        XCTAssertEqual(request(.editComment(id: 5, lineComment: false, body: "x"))?.path, "/repos/acme/app/issues/comments/5")
    }

    func testResolvingUsesTheMutationForTheWayItGoes() throws {
        let done = try XCTUnwrap(request(.setThreadResolved(threadID: "T", resolved: true))?.body?["query"] as? String)
        let open = try XCTUnwrap(request(.setThreadResolved(threadID: "T", resolved: false))?.body?["query"] as? String)
        XCTAssertTrue(done.contains("resolveReviewThread"))
        XCTAssertTrue(open.contains("unresolveReviewThread"))
    }

    func testDeleteBranchKeepsItsSlashesAndUsesTheForksRepository() {
        let spec = request(.deleteBranch(repository: "ada/app", branch: "feature/x y"))
        XCTAssertEqual(spec?.method, "DELETE")
        XCTAssertEqual(spec?.path, "/repos/ada/app/git/refs/heads/feature/x%20y")
    }

    func testAutoMergeNamesTheMethodInCapitals() throws {
        let variables = try XCTUnwrap(request(.enableAutoMerge(nodeID: "N", method: .squash))?.body?["variables"] as? [String: String])
        XCTAssertEqual(variables["method"], "SQUASH")
    }

    func testRevertURLComesFromTheAnswer() {
        let answer: [String: Any] = ["data": ["revertPullRequest": ["revertPullRequest": ["url": "https://github.com/a/b/pull/9"]]]]
        XCTAssertEqual(PullRequestAction.revertURL(answer), "https://github.com/a/b/pull/9")
        XCTAssertNil(PullRequestAction.revertURL([:]))
    }

    func testRestCommentReadsTheEventsID() {
        func event(_ id: String) -> PullRequestEvent { PullRequestEvent(id: id, kind: .comment, author: "a", body: "", date: nil, url: nil) }
        XCTAssertEqual(event("line-12").restComment?.id, 12)
        XCTAssertEqual(event("line-12").restComment?.lineComment, true)
        XCTAssertEqual(event("comment-3").restComment?.lineComment, false)
        XCTAssertNil(event("review-3").restComment, "GitHub has no such address for a review")
    }

    func testAThreadCarriesItsIDForResolving() {
        let answer: [String: Any] = ["data": ["repository": ["pullRequest": ["reviewThreads": ["nodes": [
            ["id": "T1", "isResolved": false, "isOutdated": false, "comments": ["nodes": [["databaseId": 1]]]],
        ]]]]]]
        let threads = PullRequestDetailParser.reviewThreads(answer)
        var event = PullRequestEvent(id: "line-1", kind: .lineComment(path: "a", line: 1), author: "a", body: "", date: nil, url: nil)
        event = PullRequestDetailParser.applying(threads, to: [event])[0]
        XCTAssertEqual(event.threadID, "T1")
    }

    func testTheRowOffersOneThingInOrder() {
        XCTAssertEqual(PullRequestRowAction.pick(open: true, conflicted: true, draft: true, checks: .failing), .resolve)
        XCTAssertEqual(PullRequestRowAction.pick(open: true, conflicted: false, draft: true, checks: .failing), .ready)
        XCTAssertEqual(PullRequestRowAction.pick(open: true, conflicted: false, draft: false, checks: .failing), .fix)
        XCTAssertNil(PullRequestRowAction.pick(open: true, conflicted: false, draft: false, checks: .pending))
        XCTAssertEqual(PullRequestRowAction.pick(open: true, conflicted: false, draft: false, checks: .passing), .merge)
        XCTAssertNil(PullRequestRowAction.pick(open: false, conflicted: false, draft: false, checks: .passing))
    }

    func testARangeCommentNamesItsFirstLine() throws {
        let comment = PullRequestAction.LineComment(path: "a", line: 9, side: "RIGHT", body: "x", startLine: 4, startSide: "RIGHT")
        let spec = try XCTUnwrap(request(.reviewWithComments(.comment, body: "", commit: "", comments: [comment])))
        let sent = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: try XCTUnwrap(spec.body))) as? [String: Any])
        let first = try XCTUnwrap((sent["comments"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["start_line"] as? Int, 4)
    }

    func testCheckoutUsesTheBranchOrTheForgesRef() {
        let own = PullRequestCheckoutPlan(host: .github, repository: "a/b", number: 7, headBranch: "feature", fork: false)
        XCTAssertEqual(own.ref, "feature")
        XCTAssertTrue(own.tracksOrigin)
        let fork = PullRequestCheckoutPlan(host: .github, repository: "a/b", number: 7, headBranch: "feature", fork: true)
        XCTAssertEqual(fork.ref, "pull/7/head")
        XCTAssertEqual(fork.branch, "pr-7")
        XCTAssertEqual(PullRequestCheckoutPlan(host: .gitlab, repository: "a/b", number: 7, headBranch: "", fork: true).ref, "merge-requests/7/head")
    }

    func testNativeStackReadsItsLayersFromTheBottomUp() throws {
        let answer: [[String: Any]] = [["number": 3, "base": ["ref": "main"], "pull_requests": [
            ["number": 1, "title": "One", "head": ["ref": "a", "sha": "s1"], "state": "closed", "merged_at": "2026-01-01T00:00:00Z"],
            ["number": 2, "title": "Two", "head": ["ref": "b", "sha": "s2"], "state": "open"],
        ]]]
        let stack = try XCTUnwrap(PullRequestNativeStack.parse(answer))
        XCTAssertEqual(stack.base, "main")
        XCTAssertEqual(stack.layers.map(\.state), [.merged, .open])
        let item = PullRequestItem(repo: "a/b", number: 2, title: "Two", url: nil, draft: false, updated: nil, author: "")
        XCTAssertEqual(stack.items(repo: "a/b", like: item)[0].baseBranch, "main")
        XCTAssertNil(PullRequestNativeStack.parse([] as [[String: Any]]))
    }

    func testEmojiAddressesPerKind() {
        func event(_ id: String) -> PullRequestEvent { PullRequestEvent(id: id, kind: .comment, author: "a", body: "", date: nil, url: nil) }
        XCTAssertEqual(event("description-7").reactionPath, "issues/7/reactions")
        XCTAssertEqual(event("line-3").reactionPath, "pulls/comments/3/reactions")
        XCTAssertEqual(event("comment-3").reactionPath, "issues/comments/3/reactions")
        XCTAssertNil(event("review-3").reactionPath)
    }

    func testADiffSplitsIntoFiles() {
        let diff = """
        diff --git a/old.txt b/new.txt
        rename from old.txt
        rename to new.txt
        --- a/old.txt
        +++ b/new.txt
        @@ -1 +1 @@
        -a
        +b
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -x
        """
        let files = UnifiedDiffFiles.split(diff)
        XCTAssertEqual(files.map(\.path), ["new.txt", "gone.txt"])
        XCTAssertEqual(files[0].status, "renamed")
        XCTAssertEqual(files[0].previousPath, "old.txt")
        XCTAssertEqual(files[0].additions, 1)
        XCTAssertEqual(files[1].status, "removed")
        XCTAssertEqual(files[1].deletions, 1)
    }
}
