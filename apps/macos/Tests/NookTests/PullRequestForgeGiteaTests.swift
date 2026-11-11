import XCTest

final class PullRequestForgeGiteaTests: XCTestCase {
    private let repo = RemoteRepository(host: .forgejo, hostName: "codeberg.org", path: "ada/app", webOrigin: "https://codeberg.org")

    private func pull(_ extra: [String: Any] = [:]) -> [String: Any] {
        var item: [String: Any] = [
            "id": 700, "number": 5, "title": "Add login", "body": "Text", "state": "open", "merged": false, "mergeable": true,
            "html_url": "https://codeberg.org/ada/app/pulls/5", "user": ["login": "ada"],
            "base": ["ref": "main", "sha": "base", "repo": ["full_name": "ada/app"]],
            "head": ["ref": "login", "sha": "abc123", "repo": ["full_name": "ada/app", "owner": ["login": "ada"]]],
            "additions": 4, "deletions": 2, "changed_files": 3, "comments": 1,
            "created_at": "2026-01-02T03:04:05+01:00", "updated_at": "2026-01-03T03:04:05Z",
            "labels": [["id": 1, "name": "bug", "color": "e11d21", "description": "Something is broken"]], "assignees": [["login": "grace"]],
            "requested_reviewers": [["login": "ken"]], "requested_reviewers_teams": [["name": "core"]],
            "milestone": ["title": "1.0"], "is_locked": true, "allow_maintainer_edit": true,
        ]
        item.merge(extra) { $1 }
        return item
    }

    private func detail(_ extra: [String: Any] = [:], repository: [String: Any]? = nil, statuses: [[String: Any]] = []) -> PullRequestDetail {
        GiteaPullRequestForge.detail(pull: pull(extra), repository: repository, statuses: statuses)!
    }

    func testAPullRequestBecomesADetail() {
        let result = detail(repository: ["full_name": "ada/app", "allow_merge_commits": false, "allow_rebase": true, "allow_squash_merge": true,
                                         "permissions": ["push": true]])
        XCTAssertEqual(result.repo, "ada/app")
        XCTAssertEqual(result.number, 5)
        XCTAssertEqual(result.author, "ada")
        XCTAssertEqual(result.state, .open)
        XCTAssertEqual(result.headSHA, "abc123")
        XCTAssertEqual(result.additions, 4)
        XCTAssertEqual(result.deletions, 2)
        XCTAssertEqual(result.changedFiles, 3)
        XCTAssertNotNil(result.created)
        XCTAssertEqual(result.mergeable, true)
        XCTAssertEqual(result.mergeState, "clean")
        XCTAssertEqual(result.methods, [.squash, .rebase])
        XCTAssertEqual(result.canPush, true)
        XCTAssertTrue(result.locked)
        XCTAssertTrue(result.maintainerEdits)
        XCTAssertEqual(result.labelColors, ["bug": "e11d21"])
        XCTAssertEqual(result.labelDescriptions, ["bug": "Something is broken"])
        XCTAssertEqual(result.requestedReviewers, ["ken", "core"])
        XCTAssertEqual(result.requestedTeams, ["core"])
        XCTAssertEqual(result.assignees, ["grace"])
        XCTAssertEqual(result.milestone, "1.0")
        XCTAssertFalse(result.activityLoaded)
        XCTAssertEqual(result.features, GiteaPullRequestForge.forgeFeatures)
        XCTAssertFalse(result.features.autoMerge)
        XCTAssertFalse(result.nodeID.isEmpty, "the page hides draft and rebase without it")
        XCTAssertNil(result.headOwner)
        XCTAssertEqual(result.headRepository, "ada/app")
    }

    func testStatesAndDrafts() {
        XCTAssertEqual(detail(["merged": true, "state": "closed"]).state, .merged)
        XCTAssertEqual(detail(["state": "closed"]).state, .closed)
        XCTAssertEqual(detail(["draft": true]).state, .draft)
        XCTAssertEqual(detail(["title": "WIP: Add login"]).state, .draft, "an older server has only the title")
        XCTAssertEqual(detail(["draft": false, "title": "WIP: Add login"]).state, .open, "a server's own field goes first")
    }

    func testFalseMergeableOnlyCountsWhileItCanMerge() {
        XCTAssertEqual(detail(["mergeable": false]).conflicted, true)
        XCTAssertFalse(detail(["mergeable": false, "draft": true]).conflicted, "a draft is never mergeable")
        XCTAssertNil(detail(["mergeable": false, "state": "closed"]).mergeable)
        XCTAssertEqual(detail(["draft": true]).mergeState, "draft")
    }

    func testAFork() {
        let result = detail(["head": ["ref": "login", "sha": "abc", "repo": ["full_name": "grace/app", "owner": ["login": "grace"]]]])
        XCTAssertEqual(result.headOwner, "grace")
        XCTAssertEqual(result.headRepository, "grace/app")
    }

    func testStatusesBecomeChecksWithFailuresFirst() {
        let page = URL(string: "https://codeberg.org/ada/app/pulls/5")
        let checks = GiteaPullRequestForge.checks([
            ["context": "lint", "status": "success", "description": "", "target_url": "/ada/app/actions/runs/1"],
            ["context": "build", "status": "pending", "description": "Waiting", "target_url": "https://ci.example.com/2"],
            ["context": "test", "status": "failure", "description": "Failed", "target_url": ""],
            ["context": "docs", "status": "skipped", "creator": ["login": "bot"]],
            ["context": "old", "state": "error"],
            ["status": "warning"],
        ], pageURL: page)
        XCTAssertEqual(checks.map(\.name), ["test", "old", "build", "lint", "docs", "check"])
        XCTAssertEqual(checks.map(\.outcome), [.failing, .failing, .pending, .passing, .skipped, .skipped])
        XCTAssertEqual(checks[0].detail, "Failed")
        XCTAssertNil(checks[0].url)
        XCTAssertEqual(checks[3].detail, "success", "without a description the state says it")
        XCTAssertEqual(checks[3].url?.absoluteString, "https://codeberg.org/ada/app/actions/runs/1")
        XCTAssertEqual(checks[2].url?.absoluteString, "https://ci.example.com/2")
        XCTAssertEqual(checks[4].reporter, "bot")
        XCTAssertFalse(checks[0].isCheckRun)
    }

    func testAnUnknownStatusStaysOpen() {
        XCTAssertEqual(GiteaPullRequestForge.outcome("something"), .pending)
    }

    func testTheTimeline() {
        let reviews: [[String: Any]] = [
            ["id": 1, "user": ["login": "ken"], "state": "APPROVED", "body": "", "submitted_at": "2026-01-02T01:00:00Z", "comments_count": 0],
            ["id": 2, "user": ["login": "ada"], "state": "REQUEST_CHANGES", "body": "No", "submitted_at": "2026-01-02T02:00:00Z"],
            ["id": 3, "user": ["login": "bob"], "state": "COMMENT", "body": "Hm", "submitted_at": "2026-01-02T03:00:00Z"],
            ["id": 4, "user": ["login": "eve"], "state": "APPROVED", "body": "", "dismissed": true, "submitted_at": "2026-01-02T04:00:00Z"],
            ["id": 5, "user": ["login": "sam"], "state": "PENDING", "body": "x", "submitted_at": "2026-01-02T05:00:00Z"],
            ["id": 6, "user": ["login": "kim"], "state": "REQUEST_REVIEW", "body": "", "submitted_at": "2026-01-02T06:00:00Z"],
            ["id": 7, "user": ["login": "lee"], "state": "COMMENT", "body": "", "submitted_at": "2026-01-02T07:00:00Z"],
        ]
        let events = GiteaPullRequestForge.events(
            reviews: reviews,
            comments: [["id": 9, "body": "Hi", "user": ["login": "ada"], "created_at": "2026-01-02T08:00:00Z", "html_url": "https://codeberg.org/c/9"]],
            lineComments: [], commits: [PullRequestCommit(sha: "c1", message: "Start", author: "ada", date: nil)])
        XCTAssertEqual(events.map(\.id), ["commit-c1", "review-1", "review-2", "review-3", "review-4", "comment-9"])
        XCTAssertEqual(events[2].kind, .review("CHANGES_REQUESTED"))
        XCTAssertEqual(events[3].kind, .review("COMMENTED"))
        XCTAssertEqual(events[4].kind, .review("DISMISSED"))
        XCTAssertEqual(events[5].rawBody, "Hi")
    }

    func testLineCommentsOnOneLineAreOneThread() {
        let comments: [[String: Any]] = [
            ["id": 11, "body": "Later", "user": ["login": "ada"], "path": "a.swift", "position": 7, "original_position": 0,
             "created_at": "2026-01-02T02:00:00Z", "resolver": NSNull()],
            ["id": 10, "body": "First", "user": ["login": "ken"], "path": "a.swift", "position": 7, "original_position": 0,
             "created_at": "2026-01-02T01:00:00Z", "resolver": ["login": "ada"]],
            ["id": 12, "body": "Old side", "user": ["login": "ken"], "path": "a.swift", "position": 0, "original_position": 7,
             "created_at": "2026-01-02T03:00:00Z", "resolver": NSNull()],
        ]
        let events = GiteaPullRequestForge.events(reviews: [], comments: [], lineComments: comments, commits: [])
        XCTAssertEqual(events.map(\.id), ["line-10", "line-11", "line-12"])
        XCTAssertEqual(events[0].kind, .lineComment(path: "a.swift", line: 7))
        XCTAssertNil(events[0].replyTo)
        XCTAssertTrue(events[0].resolved)
        XCTAssertNil(events[0].threadID, "the page offers no resolving that the forge's API cannot do")
        XCTAssertEqual(events[1].replyTo, "line-10")
        XCTAssertFalse(events[1].resolved)
        XCTAssertNil(events[2].replyTo, "the old side of a line is another thread")
        XCTAssertFalse(events[2].resolved)
        XCTAssertFalse(events[2].outdated)
    }

    func testLinksFilterOnTheBranch() {
        let links = GiteaPullRequestForge.links([
            pull(),
            pull(["number": 6, "head": ["ref": "other"]]),
            pull(["number": 7, "merged": true, "state": "closed"]),
            pull(["number": 8, "mergeable": false]),
            pull(["number": 9, "draft": true, "mergeable": false]),
        ], branch: "login", repo: repo)
        XCTAssertEqual(links.map(\.number), [5, 7, 8, 9])
        XCTAssertEqual(links.map(\.state), [.open, .merged, .open, .draft])
        XCTAssertEqual(links.map(\.conflicted), [false, false, true, false])
        XCTAssertEqual(links.first?.host, .forgejo)
        XCTAssertEqual(links.first?.baseBranch, "main")
        XCTAssertEqual(links.first?.repository, "ada/app")
    }

    func testAReviewBody() {
        let lines = [PullRequestAction.LineComment(path: "a", line: 3, side: "RIGHT", body: "new"),
                     PullRequestAction.LineComment(path: "b", line: 4, side: "LEFT", body: "old")]
        let body = GiteaPullRequestForge.reviewBody(.requestChanges, body: " Fix ", commit: "abc", comments: lines)
        XCTAssertEqual(body["event"] as? String, "REQUEST_CHANGES")
        XCTAssertEqual(body["body"] as? String, "Fix")
        XCTAssertEqual(body["commit_id"] as? String, "abc")
        let sent = body["comments"] as? [[String: Any]]
        XCTAssertEqual(sent?[0]["new_position"] as? Int, 3)
        XCTAssertEqual(sent?[0]["old_position"] as? Int, 0)
        XCTAssertEqual(sent?[1]["new_position"] as? Int, 0)
        XCTAssertEqual(sent?[1]["old_position"] as? Int, 4)
        XCTAssertEqual(GiteaPullRequestForge.reviewBody(.approve, body: "", commit: "", comments: [])["event"] as? String, "APPROVED")
        XCTAssertNil(GiteaPullRequestForge.reviewBody(.comment, body: "", commit: "", comments: [])["comments"])
    }

    func testMergeBody() {
        let body = GiteaPullRequestForge.mergeBody(method: .squash, sha: "abc")
        XCTAssertEqual(body["Do"] as? String, "squash")
        XCTAssertEqual(body["head_commit_id"] as? String, "abc")
        XCTAssertNil(GiteaPullRequestForge.mergeBody(method: .rebase, sha: "")["head_commit_id"])
    }

    func testLabelNamesBecomeIDs() {
        let labels: [[String: Any]] = [["id": 1, "name": "Bug"], ["id": 2, "name": "ui"]]
        XCTAssertEqual(GiteaPullRequestForge.labelIDs(["ui", " bug "], in: labels), [2, 1])
        XCTAssertTrue(GiteaPullRequestForge.labelIDs(["nope"], in: labels).isEmpty)
    }

    func testADraftIsATitlePrefix() {
        XCTAssertEqual(GiteaPullRequestForge.title("Add login", draft: true), "WIP: Add login")
        XCTAssertEqual(GiteaPullRequestForge.title("[WIP] Add login", draft: false), "Add login")
        XCTAssertEqual(GiteaPullRequestForge.title("WIP: Add login", draft: true), "WIP: Add login")
    }
}
