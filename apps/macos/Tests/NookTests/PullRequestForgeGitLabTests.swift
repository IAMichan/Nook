import XCTest

final class PullRequestForgeGitLabTests: XCTestCase {
    private let repo = RemoteRepository(host: .gitlab, hostName: "gitlab.com", path: "group/sub/app", webOrigin: "https://gitlab.com")

    private func mergeRequest(_ extra: [String: Any] = [:]) -> [String: Any] {
        var item: [String: Any] = [
            "id": 900, "iid": 12, "title": "Add login", "description": "Body", "state": "opened", "draft": false,
            "web_url": "https://gitlab.com/group/sub/app/-/merge_requests/12", "author": ["username": "ada"],
            "target_branch": "main", "source_branch": "login", "sha": "abc123", "changes_count": "7",
            "created_at": "2026-01-02T03:04:05.000Z", "updated_at": "2026-01-03T03:04:05.000+01:00",
            "detailed_merge_status": "mergeable", "user": ["can_merge": true], "user_notes_count": 3,
            "labels": ["bug", "ui"], "assignees": [["username": "grace"]],
            "reviewers": [["id": 1, "username": "linus"], ["id": 2, "username": "ken"]],
            "milestone": ["title": "1.0"], "source_project_id": 5, "target_project_id": 5,
        ]
        item.merge(extra) { $1 }
        return item
    }

    private func detail(_ extra: [String: Any] = [:], project: [String: Any]? = nil, source: [String: Any]? = nil,
                        approvals: [String: Any]? = nil) -> PullRequestDetail {
        GitLabPullRequestForge.detail(mergeRequest: mergeRequest(extra), project: project, sourceProject: source, approvals: approvals,
                                      labelColors: ["bug": "ff0000", "other": "00ff00"], jobs: [], repo: repo)!
    }

    func testAMergeRequestBecomesADetail() {
        let result = detail(approvals: ["approved_by": [["user": ["username": "ken"]]]])
        XCTAssertEqual(result.repo, "group/sub/app")
        XCTAssertEqual(result.number, 12)
        XCTAssertEqual(result.author, "ada")
        XCTAssertEqual(result.state, .open)
        XCTAssertEqual(result.baseBranch, "main")
        XCTAssertEqual(result.headBranch, "login")
        XCTAssertEqual(result.headSHA, "abc123")
        XCTAssertEqual(result.changedFiles, 7)
        XCTAssertNotNil(result.created)
        XCTAssertNotNil(result.updated)
        XCTAssertEqual(result.mergeable, true)
        XCTAssertEqual(result.mergeState, "clean")
        XCTAssertEqual(result.canPush, true)
        XCTAssertEqual(result.labels, ["bug", "ui"])
        XCTAssertEqual(result.labelColors, ["bug": "ff0000"])
        XCTAssertEqual(result.assignees, ["grace"])
        XCTAssertEqual(result.milestone, "1.0")
        XCTAssertEqual(result.requestedReviewers, ["linus"], "someone who approved has answered")
        XCTAssertFalse(result.activityLoaded)
        XCTAssertEqual(result.features, GitLabPullRequestForge.forgeFeatures)
        XCTAssertFalse(result.nodeID.isEmpty, "the page hides draft, rebase and auto-merge without it")
        XCTAssertEqual(result.headRepository, "group/sub/app")
        XCTAssertNil(result.headOwner)
    }

    func testStates() {
        XCTAssertEqual(detail(["state": "merged"]).state, .merged)
        XCTAssertEqual(detail(["state": "closed"]).state, .closed)
        XCTAssertEqual(detail(["draft": true]).state, .draft)
    }

    func testAForkNamesItsOwner() {
        let result = detail(["source_project_id": 9], source: ["path_with_namespace": "ada/app"])
        XCTAssertEqual(result.headRepository, "ada/app")
        XCTAssertEqual(result.headOwner, "ada")
        XCTAssertEqual(detail(["source_project_id": 9]).headOwner, "ada", "a fork that cannot be read still has its author")
        XCTAssertNil(detail(["source_project_id": 9]).headRepository)
    }

    func testAutoMerge() {
        let on = detail(["merge_when_pipeline_succeeds": true, "squash": true, "merge_user": ["username": "ada"]])
        XCTAssertEqual(on.autoMerge, PullRequestAutoMerge(method: .squash, enabledBy: "ada"))
        XCTAssertTrue(on.autoMergeAllowed)
        XCTAssertNil(detail().autoMerge)
    }

    func testMergeStatusInGitHubsWords() {
        func state(_ status: String) -> String { GitLabPullRequestForge.mergeState(["detailed_merge_status": status]) }
        XCTAssertEqual(state("mergeable"), "clean")
        XCTAssertEqual(state("conflict"), "dirty")
        XCTAssertEqual(state("need_rebase"), "behind")
        XCTAssertEqual(state("not_approved"), "blocked")
        XCTAssertEqual(state("ci_still_running"), "unstable")
        XCTAssertEqual(state("checking"), "unknown")
        XCTAssertEqual(GitLabPullRequestForge.mergeState(["has_conflicts": true]), "dirty")
        XCTAssertNil(GitLabPullRequestForge.mergeable(["detailed_merge_status": "checking"]))
        XCTAssertNil(GitLabPullRequestForge.mergeable(["merge_status": "unchecked"]))
        XCTAssertEqual(GitLabPullRequestForge.mergeable(["has_conflicts": true]), false)
        XCTAssertEqual(GitLabPullRequestForge.mergeable(["merge_status": "can_be_merged"]), true)
    }

    func testMethodsFollowTheProject() {
        XCTAssertEqual(GitLabPullRequestForge.methods(["squash_option": "never"]), [.merge])
        XCTAssertEqual(GitLabPullRequestForge.methods(["squash_option": "always"]), [.squash])
        XCTAssertEqual(GitLabPullRequestForge.methods(["squash_option": "default_off"]), [.merge, .squash])
        XCTAssertEqual(GitLabPullRequestForge.methods(nil), [.merge, .squash])
    }

    func testJobsBecomeChecksWithFailuresFirst() {
        let jobs: [[String: Any]] = [
            ["name": "lint", "status": "success", "web_url": "https://gitlab.com/j/1", "started_at": "2026-01-02T03:04:05.000Z"],
            ["name": "flaky", "status": "failed", "allow_failure": true],
            ["name": "build", "status": "running"],
            ["name": "test", "status": "failed"],
            ["name": "deploy", "status": "manual"],
        ]
        let checks = GitLabPullRequestForge.checks(pipeline: ["id": 4, "status": "failed"], jobs: jobs)
        XCTAssertEqual(checks.map(\.name), ["test", "build", "lint", "flaky", "deploy"])
        XCTAssertEqual(checks.map(\.outcome), [.failing, .pending, .passing, .skipped, .skipped])
        XCTAssertTrue(checks[1].running)
        XCTAssertNotNil(checks[2].started)
        XCTAssertNil(checks[0].checkRunID, "a job has no report at GitHub's address")
    }

    func testAPipelineWithoutJobsIsOneCheck() {
        let checks = GitLabPullRequestForge.checks(pipeline: ["status": "pending", "web_url": "https://gitlab.com/p/1"], jobs: [])
        XCTAssertEqual(checks.map(\.name), ["Pipeline"])
        XCTAssertEqual(checks.first?.outcome, .pending)
        XCTAssertTrue(GitLabPullRequestForge.checks(pipeline: nil, jobs: []).isEmpty)
    }

    private let discussions: [[String: Any]] = [
        ["id": "single", "individual_note": true, "notes": [
            ["id": 10, "body": "Nice", "author": ["username": "ada"], "created_at": "2026-01-02T01:00:00.000Z", "system": false],
        ]],
        ["id": "thread", "individual_note": false, "notes": [
            ["id": 20, "body": "Why?", "author": ["username": "ken"], "created_at": "2026-01-02T02:00:00.000Z", "system": false,
             "resolvable": true, "resolved": true, "position": ["new_path": "a.swift", "old_path": "a.swift", "new_line": 7]],
            ["id": 21, "body": "Because", "author": ["username": "ada"], "created_at": "2026-01-02T03:00:00.000Z", "system": false,
             "resolvable": true, "resolved": true, "position": ["new_path": "a.swift", "old_path": "a.swift", "new_line": 7]],
        ]],
        ["id": "removed", "individual_note": false, "notes": [
            ["id": 30, "body": "Gone", "author": ["username": "ken"], "created_at": "2026-01-02T04:00:00.000Z", "system": false,
             "position": ["old_path": "b.swift", "new_line": NSNull(), "old_line": 3]],
        ]],
        ["id": "general", "individual_note": false, "notes": [
            ["id": 40, "body": "Top", "author": ["username": "ken"], "created_at": "2026-01-02T05:00:00.000Z", "system": false],
            ["id": 41, "body": "Answer", "author": ["username": "ada"], "created_at": "2026-01-02T06:00:00.000Z", "system": false],
        ]],
        ["id": "sys", "individual_note": true, "notes": [
            ["id": 50, "body": "approved this merge request", "author": ["username": "ken"], "created_at": "2026-01-02T07:00:00.000Z", "system": true],
            ["id": 51, "body": "requested review from @linus", "author": ["username": "ada"], "created_at": "2026-01-02T08:00:00.000Z", "system": true],
            ["id": 52, "body": "added 1 commit", "author": ["username": "ada"], "created_at": "2026-01-02T09:00:00.000Z", "system": true],
            ["id": 53, "body": "deleted source branch `login`", "author": ["username": "ada"], "created_at": "2026-01-02T10:00:00.000Z", "system": true],
            ["id": 54, "body": "approved this merge request", "author": ["username": "reset"], "created_at": "2026-01-02T11:00:00.000Z", "system": true],
        ]],
    ]

    private func events() -> [PullRequestEvent] {
        let commit = PullRequestCommit(sha: "c1", message: "Start\n\nMore", author: "ada", date: PullRequestDetailParser.date("2026-01-01T00:00:00Z"))
        return GitLabPullRequestForge.events(discussions: discussions, approvals: ["approved_by": [["user": ["username": "ken"]]]],
                                             commits: [commit], url: "https://gitlab.com/g/a/-/merge_requests/12")
    }

    func testTheTimelineIsInOrderWithTheIdsThePageReads() {
        XCTAssertEqual(events().map(\.id), ["commit-c1", "comment-10", "line-20", "line-21", "line-30", "comment-40", "comment-41",
                                            "review-approved-ken", "timeline-51", "timeline-53"])
    }

    func testAThreadKeepsItsDiscussionAndItsRoot() {
        let all = events()
        let root = all.first { $0.id == "line-20" }, reply = all.first { $0.id == "line-21" }
        XCTAssertEqual(root?.kind, .lineComment(path: "a.swift", line: 7))
        XCTAssertEqual(root?.threadID, "thread")
        XCTAssertEqual(root?.resolved, true)
        XCTAssertNil(root?.replyTo)
        XCTAssertEqual(root?.restComment?.id, 20)
        XCTAssertEqual(root?.url?.absoluteString, "https://gitlab.com/g/a/-/merge_requests/12#note_20")
        XCTAssertEqual(reply?.replyTo, "line-20")
        XCTAssertEqual(reply?.threadID, "thread")
        XCTAssertEqual(reply?.resolved, false, "resolved sits on a thread's first comment")
        XCTAssertEqual(reply?.rawBody, "Because")
        XCTAssertEqual(all.first { $0.id == "line-30" }?.kind, .lineComment(path: "b.swift", line: 3))
        XCTAssertNil(all.first { $0.id == "comment-10" }?.threadID)
        XCTAssertEqual(all.first { $0.id == "comment-41" }?.threadID, "general")
        XCTAssertNil(all.first { $0.id == "comment-41" }?.replyTo)
        XCTAssertEqual(GitLabPullRequestForge.thread(of: 21, in: all), "thread")
        XCTAssertEqual(GitLabPullRequestForge.thread(of: 41, in: all), "general")
        XCTAssertNil(GitLabPullRequestForge.thread(of: 999, in: all))
    }

    func testOnlyTheApprovalsThatStandAreVerdicts() {
        let all = events()
        XCTAssertEqual(all.first { $0.id == "review-approved-ken" }?.date, PullRequestDetailParser.date("2026-01-02T07:00:00.000Z"))
        var result = detail()
        result.events = all
        XCTAssertEqual(result.verdicts.map(\.author), ["ken"], "a push reset the other approval")
    }

    func testSystemNotesBecomeActivity() {
        let all = events()
        XCTAssertEqual(all.first { $0.id == "timeline-51" }?.kind, .activity(type: "review_requested", detail: "@linus"))
        var result = detail()
        result.events = all
        XCTAssertTrue(result.branchDeleted)
        XCTAssertNil(all.first { $0.id == "timeline-52" }, "commits come from their own list")
    }

    func testCommitsComeOldestFirst() {
        let commits = GitLabPullRequestForge.commits([
            ["id": "new", "title": "New", "message": "New\n\nBody", "author_name": "Ada", "authored_date": "2026-01-02T03:04:05.000+01:00"],
            ["id": "old", "title": "Old", "author_name": "Ken"],
        ])
        XCTAssertEqual(commits.map(\.sha), ["old", "new"])
        XCTAssertEqual(commits[0].message, "Old")
        XCTAssertEqual(commits[1].author, "Ada")
        XCTAssertNotNil(commits[1].date)
    }

    func testDiffsBecomeFiles() {
        let files = GitLabPullRequestForge.files([
            ["old_path": "a", "new_path": "a", "diff": "@@ -1,2 +1,2 @@\n x\n-y\n+z\n+w\n"],
            ["old_path": "b", "new_path": "b", "new_file": true, "diff": "@@ -0,0 +1 @@\n+a\n"],
            ["old_path": "c", "new_path": "c", "deleted_file": true, "diff": "@@ -1 +0,0 @@\n-a\n"],
            ["old_path": "d", "new_path": "e", "renamed_file": true, "diff": ""],
        ])
        XCTAssertEqual(files.map(\.status), ["modified", "added", "removed", "renamed"])
        XCTAssertEqual(files[0].additions, 2)
        XCTAssertEqual(files[0].deletions, 1)
        XCTAssertEqual(files[0].patch, "@@ -1,2 +1,2 @@\n x\n-y\n+z\n+w")
        XCTAssertEqual(files[2].revision, "")
        XCTAssertEqual(files[3].path, "e")
        XCTAssertEqual(files[3].previousPath, "d")
        XCTAssertNil(files[3].patch)
        XCTAssertNil(files[0].previousPath)
    }

    func testIssuesAndLabels() {
        let issues = GitLabPullRequestForge.issues([["iid": 3, "title": "Bug", "state": "opened", "web_url": "https://gitlab.com/i/3"],
                                                    ["iid": 4, "title": "Old", "state": "closed"]], repository: "g/a")
        XCTAssertEqual(issues.map(\.id), ["g/a#3", "g/a#4"])
        XCTAssertEqual(issues.map(\.open), [true, false])
        let labels = GitLabPullRequestForge.labels([["name": "bug", "color": "#FF0000"]])
        XCTAssertEqual(labels.first?.name, "bug")
        XCTAssertEqual(labels.first?.color, "FF0000")
    }

    private let refs: [String: Any] = ["base_sha": "b", "start_sha": "s", "head_sha": "h"]
    private let patch = "@@ -10,3 +20,4 @@ func a()\n same\n-gone\n+new\n+newer\n also"

    func testAPositionNamesBothSidesOfAnUnchangedLine() {
        let file = PullRequestFile(path: "new.swift", status: "renamed", additions: 2, deletions: 1, patch: patch, previousPath: "old.swift")
        func position(_ line: Int, _ side: String) -> [String: Any] {
            GitLabPullRequestForge.position(.init(path: "new.swift", line: line, side: side, body: "x"), refs: refs, file: file)
        }
        let added = position(21, "RIGHT")
        XCTAssertEqual(added["new_line"] as? Int, 21)
        XCTAssertNil(added["old_line"])
        XCTAssertEqual(added["old_path"] as? String, "old.swift")
        XCTAssertEqual(added["new_path"] as? String, "new.swift")
        XCTAssertEqual(added["base_sha"] as? String, "b")
        XCTAssertEqual(added["start_sha"] as? String, "s")
        XCTAssertEqual(added["head_sha"] as? String, "h")
        XCTAssertEqual(added["position_type"] as? String, "text")
        let removed = position(11, "LEFT")
        XCTAssertEqual(removed["old_line"] as? Int, 11)
        XCTAssertNil(removed["new_line"])
        let context = position(23, "RIGHT")
        XCTAssertEqual(context["new_line"] as? Int, 23)
        XCTAssertEqual(context["old_line"] as? Int, 12)
        let contextLeft = position(10, "LEFT")
        XCTAssertEqual(contextLeft["old_line"] as? Int, 10)
        XCTAssertEqual(contextLeft["new_line"] as? Int, 20)
    }

    func testAPositionWithoutThePatchOnlyHasItsOwnSide() {
        let position = GitLabPullRequestForge.position(.init(path: "a", line: 3, side: "RIGHT", body: "x"), refs: refs, file: nil)
        XCTAssertEqual(position["new_line"] as? Int, 3)
        XCTAssertEqual(position["old_path"] as? String, "a")
        XCTAssertNil(position["old_line"])
    }

    func testADraftIsATitlePrefix() {
        XCTAssertEqual(GitLabPullRequestForge.title("Add login", draft: true), "Draft: Add login")
        XCTAssertEqual(GitLabPullRequestForge.title("Draft: Add login", draft: true), "Draft: Add login")
        XCTAssertEqual(GitLabPullRequestForge.title("draft: Add login", draft: false), "Add login")
        XCTAssertEqual(GitLabPullRequestForge.title("[Draft] WIP: Add login", draft: false), "Add login")
    }

    func testMergeBodyAndAnswer() {
        let squash = GitLabPullRequestForge.mergeBody(method: .squash, sha: "abc")
        XCTAssertEqual(squash["squash"] as? Bool, true)
        XCTAssertEqual(squash["sha"] as? String, "abc")
        XCTAssertEqual(GitLabPullRequestForge.mergeBody(method: .merge, sha: "")["squash"] as? Bool, false)
        XCTAssertNil(GitLabPullRequestForge.mergeBody(method: .merge, sha: "")["sha"])
        XCTAssertEqual(GitLabPullRequestForge.mergedSHA(["squash_commit_sha": "s", "merge_commit_sha": "m", "sha": "h"]), "s")
        XCTAssertEqual(GitLabPullRequestForge.mergedSHA(["squash_commit_sha": NSNull(), "merge_commit_sha": "m"]), "m")
        XCTAssertEqual(GitLabPullRequestForge.mergedSHA(["merge_commit_sha": NSNull(), "sha": "h"]), "h")
        XCTAssertEqual(GitLabPullRequestForge.mergedSHA([:]), "")
    }

    func testUsernamesKeepDotsAndUnderscores() {
        XCTAssertEqual(GitLabPullRequestForge.usernames(["@anna.b, bob_c", "ANNA.B"]), ["anna.b", "bob_c"])
    }
}
