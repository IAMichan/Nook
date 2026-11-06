import XCTest

final class PullRequestForgeGitCafeTests: XCTestCase {
    private let repo = RemoteRepository(host: .gitcafe, hostName: "git.cafe", path: "acme/app", webOrigin: "https://git.cafe")
    private let ada: [String: Any] = ["kind": "local", "actorId": "a1", "handle": "ada", "displayName": NSNull(), "avatarUrl": NSNull()]
    private let grace: [String: Any] = ["kind": "github", "actorId": "g1", "login": "grace", "avatarUrl": NSNull(), "linkedProfile": ["handle": "grace-local"]]

    private var pull: [String: Any] {
        ["id": "pr_one", "number": 7, "title": "Change", "state": "open", "draft": false, "sourceBranch": "feature", "targetBranch": "main",
         "headOid": "abcdef", "author": ada, "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "2026-10-02T10:00:00Z", "version": 3,
         "description": "Body", "closedAt": NSNull(), "mergedAt": NSNull(), "sourceRepo": NSNull(),
         "capabilities": ["comment": true, "review": true, "merge": false, "edit": true, "moderate": false]]
    }

    func testDetailMapsThePullRequest() throws {
        let status: [String: Any] = ["merge": ["conflicts": "none", "fastForward": true, "strategies": ["merge", "squash"],
                                               "blockers": [["blockedStrategies": ["squash"]]]]]
        let labels: [[String: Any]] = [["id": "l1", "name": "bug", "color": "#ff0000"]]
        let changes: [[String: Any]] = [["path": "a", "additions": 2, "deletions": 1], ["path": "b"]]
        let detail = try XCTUnwrap(GitCafePullRequestForge.detail(pull: pull, repo: repo, status: status, reviewers: [["id": "x", "actor": grace]],
                                                                  labels: labels, changes: changes))
        XCTAssertEqual(detail.repo, "acme/app")
        XCTAssertEqual(detail.number, 7)
        XCTAssertEqual(detail.body, "Body")
        XCTAssertEqual(detail.author, "ada")
        XCTAssertEqual(detail.state, .open)
        XCTAssertEqual(detail.headSHA, "abcdef")
        XCTAssertEqual(detail.mergeable, true)
        XCTAssertEqual(detail.mergeState, "clean")
        XCTAssertEqual(detail.methods, [.merge])
        XCTAssertEqual(detail.canPush, false)
        XCTAssertEqual(detail.requestedReviewers, ["grace"])
        XCTAssertEqual(detail.labels, ["bug"])
        XCTAssertEqual(detail.labelColors, ["bug": "ff0000"])
        XCTAssertEqual(detail.additions, 2)
        XCTAssertEqual(detail.changedFiles, 2)
        XCTAssertEqual(detail.url?.absoluteString, "https://git.cafe/acme/app/pulls/7")
        XCTAssertEqual(detail.headRepository, "acme/app")
        XCTAssertNil(detail.headOwner)
        XCTAssertEqual(detail.nodeID, "7")
        XCTAssertFalse(detail.activityLoaded)
        XCTAssertFalse(detail.features.lineComments)
    }

    func testStatesConflictsAndBlocks() throws {
        XCTAssertEqual(GitCafePullRequestForge.state(["state": "merged"]), .merged)
        XCTAssertEqual(GitCafePullRequestForge.state(["state": "closed"]), .closed)
        XCTAssertEqual(GitCafePullRequestForge.state(["state": "open", "draft": true]), .draft)
        // GitHub already merged it; the sync has not brought that back yet.
        XCTAssertEqual(GitCafePullRequestForge.state(["state": "open", "providerMerge": ["mergedAt": "2026-10-01T10:00:00Z"]]), .merged)
        let conflicted = try XCTUnwrap(GitCafePullRequestForge.detail(pull: pull, repo: repo, status: ["merge": ["conflicts": "conflicting", "strategies": []]]))
        XCTAssertTrue(conflicted.conflicted)
        let blocked = try XCTUnwrap(GitCafePullRequestForge.detail(pull: pull, repo: repo, status: ["merge": ["conflicts": "pending", "strategies": ["merge"], "permitted": false]]))
        XCTAssertEqual(blocked.mergeState, "blocked")
        XCTAssertNil(blocked.mergeable)
        XCTAssertEqual(blocked.methods, [])
    }

    func testForkShowsItsOwner() throws {
        var fork = pull
        fork["sourceRepo"] = ["owner": "ada", "name": "app"]
        let detail = try XCTUnwrap(GitCafePullRequestForge.detail(pull: fork, repo: repo))
        XCTAssertEqual(detail.headOwner, "ada")
        XCTAssertEqual(detail.headRepository, "ada/app")
    }

    func testLinksMatchTheBranch() {
        var other = pull
        other["number"] = 8
        other["sourceBranch"] = "other"
        let links = GitCafePullRequestForge.links([pull, other], branch: "feature", repo: repo)
        XCTAssertEqual(links.map(\.number), [7])
        XCTAssertEqual(links.first?.url, "https://git.cafe/acme/app/pulls/7")
    }

    func testNumberOfAnIDIsStableAndUsableInAnEvent() {
        XCTAssertEqual(GitCafePullRequestForge.number(of: "thread-one"), GitCafePullRequestForge.number(of: "thread-one"))
        XCTAssertNotEqual(GitCafePullRequestForge.number(of: "thread-one"), GitCafePullRequestForge.number(of: "thread-two"))
        XCTAssertGreaterThan(GitCafePullRequestForge.number(of: "x"), 0)
        let number = GitCafePullRequestForge.number(of: "root")
        let event = PullRequestEvent(id: "line-\(number)", kind: .comment, author: "", body: "", date: nil, url: nil)
        XCTAssertEqual(event.restComment?.id, number)
    }

    func testCommentsBecomeThreads() {
        let line: [String: Any] = ["author": ada, "path": "a.swift", "line": 3, "side": "right", "commitOid": "abcdef", "resolvedAt": NSNull()]
        func comment(_ id: String, _ thread: String, _ time: String, _ extra: [String: Any]) -> [String: Any] {
            line.merging(["id": id, "threadId": thread, "body": id, "createdAt": "2026-10-01T1\(time):00:00Z"].merging(extra) { $1 }) { $1 }
        }
        let list = [
            comment("reply", "root", "2", [:]),
            comment("root", "root", "1", ["resolvedAt": "2026-10-02T10:00:00Z"]),
            comment("plain", "plain", "0", ["path": NSNull(), "line": NSNull(), "side": NSNull()]),
            comment("older", "lost", "3", ["commitOid": "old"]),
            comment("later", "lost", "4", ["commitOid": "old"]),
        ]
        let events = GitCafePullRequestForge.comments(list, head: "abcdef")
        let number = { GitCafePullRequestForge.number(of: $0) }
        XCTAssertEqual(events.map(\.body), ["plain", "root", "reply", "older", "later"])
        XCTAssertEqual(events[0].id, "comment-\(number("plain"))")
        XCTAssertEqual(events[0].kind, .comment)
        XCTAssertEqual(events[1].id, "line-\(number("root"))")
        XCTAssertEqual(events[1].kind, .lineComment(path: "a.swift", line: 3))
        XCTAssertTrue(events[1].resolved)
        XCTAssertEqual(events[1].threadID, "root")
        XCTAssertNil(events[1].replyTo)
        XCTAssertFalse(events[1].outdated)
        XCTAssertEqual(events[2].replyTo, "line-\(number("root"))")
        XCTAssertFalse(events[2].resolved)
        // The thread's first comment is gone, so the oldest one left stands in for it.
        XCTAssertNil(events[3].replyTo)
        XCTAssertEqual(events[4].replyTo, "line-\(number("older"))")
        XCTAssertTrue(events[4].outdated)
    }

    func testTimelineHoldsReviewsAndCommits() {
        let commits = GitCafePullRequestForge.commits([["oid": "a1", "summary": "First", "time": 1_790_000_000]])
        XCTAssertEqual(commits.first?.date, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(commits.first?.author, "?")
        let reviews: [[String: Any]] = [
            ["id": "r1", "author": ada, "body": NSNull(), "verdict": "approve", "dismissedAt": NSNull(), "createdAt": "2026-10-01T10:00:00Z"],
            ["id": "r2", "author": grace, "body": "No", "verdict": "request_changes", "dismissedAt": "2026-10-02T10:00:00Z", "createdAt": "2026-10-01T11:00:00Z"],
            ["id": "r3", "author": grace, "body": NSNull(), "verdict": "comment", "dismissedAt": NSNull(), "createdAt": "2026-10-01T12:00:00Z"],
            ["id": "r4", "author": ["kind": "unavailable", "actorId": "x"], "body": "Hm", "verdict": "comment", "dismissedAt": NSNull(), "createdAt": "2026-10-01T13:00:00Z"],
        ]
        let events = GitCafePullRequestForge.events(comments: [], reviews: reviews, commits: commits, head: nil)
        // The commit is from 2026-09-21, the reviews from October, and an empty remark says nothing.
        XCTAssertEqual(events.map(\.id), ["commit-a1", "review-r1", "review-r2", "review-r4"])
        XCTAssertEqual(events[1].kind, .review("APPROVED"))
        XCTAssertEqual(events[2].kind, .review("DISMISSED"))
        XCTAssertEqual(events[2].author, "grace")
        XCTAssertEqual(events[3].author, "?")
    }

    func testChecksKeepTheNewestRunOfAReporter() {
        let checks = GitCafePullRequestForge.checks([
            ["id": "9", "provider": "github", "name": "Build", "status": "completed", "conclusion": "failure", "detailsUrl": "https://ci.example/9"],
            ["id": "10", "provider": "github", "name": "Build", "status": "completed", "conclusion": "success", "detailsUrl": "https://ci.example/10"],
            ["id": "status:a", "name": "Old", "status": "completed", "conclusion": "failure"],
            ["id": "status:b", "name": "Old", "status": "in_progress", "conclusion": NSNull()],
        ])
        XCTAssertEqual(checks.map(\.outcome), [.failing, .pending, .passing])
        XCTAssertEqual(checks.last?.url?.absoluteString, "https://ci.example/10")
    }

    func testFilesTakeTheirHunks() {
        let listed: [[String: Any]] = [
            ["path": "new.txt", "status": "added", "newOid": "n1"],
            ["path": "gone.txt", "status": "deleted"],
            ["path": "pic.png", "status": "modified", "binary": true, "newOid": "n2"],
            ["path": "now.txt", "oldPath": "was.txt", "status": "renamed", "newOid": "n3"],
        ]
        XCTAssertEqual(GitCafePullRequestForge.readablePaths(listed), ["new.txt", "gone.txt", "now.txt"])
        let hunk: [String: Any] = ["oldStart": 0, "oldLines": 0, "newStart": 1, "newLines": 2, "lines": [
            ["origin": "+", "content": "one\n"], ["origin": "+", "content": "two"], ["origin": ">", "content": ""],
        ]]
        let files = GitCafePullRequestForge.files(listed: listed, details: [["path": "new.txt", "status": "added", "newOid": "n1", "hunks": [hunk]]])
        XCTAssertEqual(files.map(\.status), ["added", "removed", "modified", "renamed"])
        XCTAssertEqual(files[0].patch, "@@ -0,0 +1,2 @@\n+one\n+two\n\\ No newline at end of file")
        XCTAssertEqual(files[0].additions, 2)
        XCTAssertEqual(files[0].revision, "n1")
        XCTAssertEqual(files[1].revision, "")
        XCTAssertNil(files[2].patch)
        XCTAssertEqual(files[3].previousPath, "was.txt")
    }

    func testRequestShapes() throws {
        let review = GitCafePullRequestForge.reviewBody(.requestChanges, body: "No", head: "abc", version: 3)
        XCTAssertEqual(review["verdict"] as? String, "request_changes")
        XCTAssertEqual(review["commitOid"] as? String, "abc")
        XCTAssertEqual(review["expectedVersion"] as? Int, 3)
        XCTAssertNil(GitCafePullRequestForge.reviewBody(.approve, body: "", head: "abc", version: 3)["body"])
        XCTAssertEqual(GitCafePullRequestForge.changed(["a"], ids: ["a", "b"], adding: true), ["a", "b"])
        XCTAssertEqual(GitCafePullRequestForge.changed(["a", "b"], ids: ["a"], adding: false), ["b"])
        let candidates: [[String: Any]] = [["id": "1", "actor": ada], ["id": "2", "actor": grace]]
        XCTAssertEqual(try GitCafePullRequestForge.actorIDs(["@ADA", "grace-local"], candidates: candidates), ["1", "2"])
        XCTAssertThrowsError(try GitCafePullRequestForge.actorIDs(["nobody"], candidates: candidates))
        XCTAssertEqual(try GitCafePullRequestForge.labelIDs(["Bug"], labels: [["id": "l", "name": "bug"]]), ["l"])
        XCTAssertThrowsError(try GitCafePullRequestForge.labelIDs(["x"], labels: []))
        XCTAssertThrowsError(try GitCafePullRequestForge.version([:]))
    }
}
