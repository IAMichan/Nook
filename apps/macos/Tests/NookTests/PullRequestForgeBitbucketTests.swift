import XCTest

final class PullRequestForgeBitbucketTests: XCTestCase {
    private let repo = RemoteRepository(host: .bitbucket, hostName: "bitbucket.org", path: "acme/app", webOrigin: "https://bitbucket.org")

    private let pull: [String: Any] = [
        "id": 12, "title": "Add merging", "description": "Does the thing.", "state": "OPEN", "draft": false,
        "author": ["nickname": "ada", "display_name": "Ada Lovelace"],
        "source": ["branch": ["name": "feature/merge"], "commit": ["hash": "abc1234def56"], "repository": ["full_name": "acme/app"]],
        "destination": ["branch": ["name": "main"], "repository": ["full_name": "acme/app"]],
        "created_on": "2026-10-01T10:00:00+00:00", "updated_on": "2026-10-02T10:00:00+00:00", "closed_on": NSNull(),
        "links": ["html": ["href": "https://bitbucket.org/acme/app/pull-requests/12"]],
        "reviewers": [["nickname": "grace", "uuid": "{1}"], ["nickname": "linus", "uuid": "{2}"]],
        "participants": [
            ["user": ["nickname": "grace"], "role": "REVIEWER", "approved": true, "state": "approved", "participated_on": "2026-10-02T09:00:00+00:00"],
            ["user": ["nickname": "ada"], "role": "PARTICIPANT", "approved": false, "state": NSNull(), "participated_on": "2026-10-02T08:00:00+00:00"],
        ],
    ]

    func testDetailMapsThePullRequest() throws {
        let diffstat: [[String: Any]] = [["lines_added": 4, "lines_removed": 1], ["lines_added": 2, "lines_removed": 3]]
        let statuses: [[String: Any]] = [["key": "ci", "name": "Build", "state": "SUCCESSFUL", "url": "https://ci.example/1"]]
        let detail = try XCTUnwrap(BitbucketPullRequestForge.detail(pull: pull, repo: repo, diffstat: diffstat, statuses: statuses, conflicts: []))
        XCTAssertEqual(detail.repo, "acme/app")
        XCTAssertEqual(detail.number, 12)
        XCTAssertEqual(detail.author, "ada")
        XCTAssertEqual(detail.state, .open)
        XCTAssertEqual(detail.baseBranch, "main")
        XCTAssertEqual(detail.headBranch, "feature/merge")
        XCTAssertEqual(detail.headSHA, "abc1234def56")
        XCTAssertEqual(detail.additions, 6)
        XCTAssertEqual(detail.deletions, 4)
        XCTAssertEqual(detail.changedFiles, 2)
        XCTAssertEqual(detail.mergeable, true)
        XCTAssertEqual(detail.mergeState, "clean")
        XCTAssertEqual(detail.checks.first?.outcome, .passing)
        XCTAssertEqual(detail.url?.absoluteString, "https://bitbucket.org/acme/app/pull-requests/12")
        XCTAssertNil(detail.canPush)
        XCTAssertFalse(detail.activityLoaded)
        XCTAssertFalse(detail.features.labels)
        XCTAssertFalse(detail.features.reactions)
        // Grace approved, so only Linus is still waited for.
        XCTAssertEqual(detail.requestedReviewers, ["linus"])
    }

    func testConflictsAndClosedStates() throws {
        var conflicted = pull
        let open = try XCTUnwrap(BitbucketPullRequestForge.detail(pull: conflicted, repo: repo, conflicts: [["path": "a"]]))
        XCTAssertTrue(open.conflicted)
        XCTAssertEqual(open.mergeState, "dirty")
        conflicted["state"] = "DECLINED"
        conflicted["closed_on"] = "2026-10-03T10:00:00+00:00"
        let closed = try XCTUnwrap(BitbucketPullRequestForge.detail(pull: conflicted, repo: repo, conflicts: [["path": "a"]]))
        XCTAssertEqual(closed.state, .closed)
        XCTAssertNil(closed.mergeable)
        // A comment after the close moves `updated_on`; the page keeps the close's date.
        XCTAssertEqual(closed.updated, PullRequestDetailParser.date("2026-10-03T10:00:00+00:00"))
        XCTAssertEqual(BitbucketPullRequestForge.state(["state": "MERGED"]), .merged)
        XCTAssertEqual(BitbucketPullRequestForge.state(["state": "SUPERSEDED"]), .closed)
        XCTAssertEqual(BitbucketPullRequestForge.state(["state": "OPEN", "draft": true]), .draft)
    }

    func testForkShowsItsOwner() throws {
        var fork = pull
        fork["source"] = ["branch": ["name": "x"], "repository": ["full_name": "ada/app"]]
        let detail = try XCTUnwrap(BitbucketPullRequestForge.detail(pull: fork, repo: repo))
        XCTAssertEqual(detail.headOwner, "ada")
        XCTAssertEqual(detail.headRepository, "ada/app")
    }

    func testLinksLeaveOutForksOfTheSameBranchName() {
        var fork = pull
        fork["id"] = 13
        fork["source"] = ["branch": ["name": "feature/merge"], "repository": ["full_name": "ada/app"]]
        let links = BitbucketPullRequestForge.links([pull, fork], repo: repo)
        XCTAssertEqual(links.map(\.number), [12])
        XCTAssertEqual(links.first?.headBranch, "feature/merge")
        XCTAssertEqual(links.first?.host, .bitbucket)
    }

    func testRequestsPathEscapesTheBranchAndAsksEveryState() {
        let path = BitbucketPullRequestForge.requestsPath("acme/app", branch: "a\"b")
        XCTAssertTrue(path.hasPrefix("/repositories/acme/app/pullrequests?state=OPEN&state=MERGED&state=DECLINED&state=SUPERSEDED&"))
        XCTAssertTrue(path.contains("q=source.branch.name%20%3D%20%22a%5C%22b%22"), path)
    }

    func testNextPageStaysOnTheAPI() {
        XCTAssertEqual(BitbucketPullRequestForge.nextPath("https://api.bitbucket.org/2.0/repositories/a/b/x?page=2"), "/repositories/a/b/x?page=2")
        XCTAssertNil(BitbucketPullRequestForge.nextPath("https://evil.example/2.0/repositories"))
        XCTAssertNil(BitbucketPullRequestForge.nextPath(NSNull()))
    }

    func testCommentsBecomeThreads() throws {
        let inline: [String: Any] = ["path": "a.swift", "to": 7, "from": NSNull(), "outdated": true]
        let comments: [[String: Any]] = [
            ["id": 1, "content": ["raw": "Plain"], "user": ["nickname": "ada"], "created_on": "2026-10-01T10:00:00+00:00"],
            ["id": 2, "content": ["raw": "On a line"], "user": ["display_name": "Build bot"], "created_on": "2026-10-01T11:00:00+00:00",
             "inline": inline, "resolution": ["type": "comment_resolution"], "links": ["html": ["href": "https://bitbucket.org/c/2"]]],
            ["id": 3, "content": ["raw": "Reply"], "user": ["nickname": "grace"], "created_on": "2026-10-01T12:00:00+00:00", "parent": ["id": 2]],
            ["id": 4, "content": ["raw": "Reply to the reply"], "user": ["nickname": "ada"], "created_on": "2026-10-01T13:00:00+00:00", "parent": ["id": 3]],
            ["id": 5, "content": ["raw": "Gone"], "deleted": true, "created_on": "2026-10-01T13:00:00+00:00"],
            ["id": 6, "content": ["raw": "Draft"], "pending": true, "created_on": "2026-10-01T13:00:00+00:00"],
            ["id": 7, "content": ["raw": "  "], "created_on": "2026-10-01T13:00:00+00:00"],
        ]
        let events = BitbucketPullRequestForge.comments(comments)
        XCTAssertEqual(events.map(\.id), ["comment-1", "line-2", "line-3", "line-4"])
        XCTAssertEqual(events[0].kind, .comment)
        XCTAssertEqual(events[0].restComment?.id, 1)
        XCTAssertEqual(events[0].rawBody, "Plain")
        XCTAssertEqual(events[1].kind, .lineComment(path: "a.swift", line: 7))
        XCTAssertEqual(events[1].author, "Build bot")
        XCTAssertTrue(events[1].resolved)
        XCTAssertTrue(events[1].outdated)
        XCTAssertEqual(events[1].threadID, "2")
        XCTAssertEqual(events[1].url?.absoluteString, "https://bitbucket.org/c/2")
        XCTAssertNil(events[1].replyTo)
        XCTAssertEqual(events[2].replyTo, "line-2")
        // A reply to a reply still hangs from the thread's first comment.
        XCTAssertEqual(events[3].replyTo, "line-2")
        XCTAssertEqual(events[3].threadID, "2")
        XCTAssertEqual(events[3].kind, .lineComment(path: "a.swift", line: 7))
        XCTAssertFalse(events[3].resolved)
    }

    func testCommentOnARemovedLineUsesTheOldLine() {
        let comment: [String: Any] = ["id": 1, "content": ["raw": "x"], "inline": ["path": "a", "to": NSNull(), "from": 9]]
        XCTAssertEqual(BitbucketPullRequestForge.comments([comment]).first?.kind, .lineComment(path: "a", line: 9))
    }

    func testTimelineHoldsVerdictsCommitsAndComments() {
        let commits = BitbucketPullRequestForge.commits([
            ["hash": "b2", "message": "Second\n\nmore", "date": "2026-10-02T07:00:00+00:00", "author": ["raw": "Ada Lovelace <ada@example.com>"]],
            ["hash": "a1", "message": "First", "date": "2026-10-01T07:00:00+00:00", "author": ["user": ["nickname": "ada"], "raw": "x"]],
        ])
        XCTAssertEqual(commits.map(\.sha), ["a1", "b2"])
        XCTAssertEqual(commits.map(\.author), ["ada", "Ada Lovelace"])
        let events = BitbucketPullRequestForge.events(pull: pull, comments: [], commits: commits)
        XCTAssertEqual(events.map(\.id), ["commit-a1", "commit-b2", "review-grace"])
        XCTAssertEqual(events[2].kind, .review("APPROVED"))
        var detail = BitbucketPullRequestForge.detail(pull: pull, repo: repo)
        detail?.events = events
        XCTAssertEqual(detail?.verdicts.first?.author, "grace")
        let asked: [String: Any] = ["participants": [["user": ["nickname": "linus"], "state": "changes_requested"]]]
        XCTAssertEqual(BitbucketPullRequestForge.reviews(asked).first?.kind, .review("CHANGES_REQUESTED"))
    }

    func testChecksKeepTheLatestRunOfAKey() {
        let checks = BitbucketPullRequestForge.checks([
            ["key": "ci", "name": "Build", "state": "FAILED"],
            ["key": "lint", "state": "INPROGRESS", "url": "https://ci.example/2"],
            ["key": "ci", "name": "Build", "state": "SUCCESSFUL"],
            ["key": "stop", "name": "Stopped", "state": "STOPPED"],
        ])
        XCTAssertEqual(checks.map(\.name), ["Stopped", "lint", "Build"])
        XCTAssertEqual(checks.map(\.outcome), [.failing, .pending, .passing])
    }

    func testFilesJoinTheDiffstatAndTheDiff() {
        let diff = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1 @@
        +hello
        """
        let diffstat: [[String: Any]] = [
            ["status": "added", "lines_added": 1, "lines_removed": 0, "old": NSNull(), "new": ["path": "new.txt"]],
            ["status": "renamed", "lines_added": 0, "lines_removed": 0, "old": ["path": "was.png"], "new": ["path": "now.png"]],
            ["status": "removed", "lines_added": 0, "lines_removed": 2, "old": ["path": "gone.txt"], "new": NSNull()],
        ]
        let files = BitbucketPullRequestForge.files(diff: diff, diffstat: diffstat)
        XCTAssertEqual(files.map(\.path), ["new.txt", "now.png", "gone.txt"])
        XCTAssertEqual(files.map(\.status), ["added", "renamed", "removed"])
        XCTAssertEqual(files[0].patch, "@@ -0,0 +1 @@\n+hello")
        XCTAssertNil(files[1].patch)
        XCTAssertEqual(files[1].previousPath, "was.png")
        XCTAssertEqual(BitbucketPullRequestForge.files(diff: diff, diffstat: []).map(\.path), ["new.txt"])
    }

    func testRequestShapes() throws {
        XCTAssertEqual(BitbucketPullRequestForge.mergeStrategy(.merge), "merge_commit")
        XCTAssertEqual(BitbucketPullRequestForge.mergeStrategy(.squash), "squash")
        XCTAssertEqual(BitbucketPullRequestForge.mergeStrategy(.rebase), "rebase_fast_forward")
        let right = BitbucketPullRequestForge.lineCommentBody(.init(path: "a", line: 3, side: "RIGHT", body: "x"))
        XCTAssertEqual((right["inline"] as? [String: Any])?["to"] as? Int, 3)
        let left = BitbucketPullRequestForge.lineCommentBody(.init(path: "a", line: 3, side: "LEFT", body: "x"))
        XCTAssertEqual((left["inline"] as? [String: Any])?["from"] as? Int, 3)
        XCTAssertTrue(BitbucketPullRequestForge.sameCommit("abc1234def56", "abc1234def5678900000"))
        XCTAssertFalse(BitbucketPullRequestForge.sameCommit("abc1234def56", "ffff"))
        XCTAssertFalse(BitbucketPullRequestForge.sameCommit("", "ffff"))
    }

    func testReviewersAreAddedToTheOnesAlreadyAsked() throws {
        let members: [[String: Any]] = [["user": ["nickname": "grace", "uuid": "{1}"]], ["user": ["nickname": "linus", "uuid": "{2}"]]]
        let ids = try BitbucketPullRequestForge.reviewerIDs(["@Linus"], members: members, current: [["uuid": "{1}"]])
        XCTAssertEqual(ids, ["{1}", "{2}"])
        XCTAssertThrowsError(try BitbucketPullRequestForge.reviewerIDs(["nobody"], members: members, current: []))
    }

    func testACommentOnSeveralLinesNamesItsFirstLine() {
        let range = BitbucketPullRequestForge.lineCommentBody(.init(path: "a", line: 9, side: "RIGHT", body: "x", startLine: 5, startSide: "RIGHT"))
        let inline = range["inline"] as? [String: Any]
        XCTAssertEqual(inline?["to"] as? Int, 9)
        XCTAssertEqual(inline?["start_to"] as? Int, 5)
        XCTAssertNil(inline?["start_from"])
        let across = BitbucketPullRequestForge.lineCommentBody(.init(path: "a", line: 9, side: "RIGHT", body: "x", startLine: 4, startSide: "LEFT"))
        XCTAssertEqual((across["inline"] as? [String: Any])?["start_from"] as? Int, 4)
        let one = BitbucketPullRequestForge.lineCommentBody(.init(path: "a", line: 9, side: "RIGHT", body: "x", startLine: 9, startSide: "RIGHT"))
        XCTAssertNil((one["inline"] as? [String: Any])?["start_to"])
    }
}
