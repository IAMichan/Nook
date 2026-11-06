import XCTest

final class PullRequestForgeAzureDevOpsTests: XCTestCase {
    private let repo = RemoteRepository(host: .azureDevOps, hostName: "dev.azure.com", path: "acme/My Project/_git/app", webOrigin: "https://dev.azure.com")

    private let pull: [String: Any] = [
        "pullRequestId": 12, "title": "Add merging", "description": "Does the thing.", "status": "active", "isDraft": false,
        "mergeStatus": "succeeded", "createdBy": ["displayName": "Ada", "uniqueName": "ada@example.com"],
        "sourceRefName": "refs/heads/feature/merge", "targetRefName": "refs/heads/main",
        "creationDate": "2026-10-01T10:00:00Z", "closedDate": NSNull(),
        "lastMergeSourceCommit": ["commitId": "abc123"],
        "labels": [["id": "1", "name": "urgent", "active": true], ["id": "2", "name": "old", "active": false]],
        "reviewers": [
            ["id": "g", "displayName": "Grace", "uniqueName": "grace@example.com", "vote": 10],
            ["id": "l", "displayName": "Linus", "uniqueName": "linus@example.com", "vote": 0],
            ["id": "t", "displayName": "[app]\\Team", "isContainer": true, "vote": 0],
            ["id": "m", "displayName": "Margaret", "uniqueName": "margaret@example.com", "vote": -5],
            ["id": "c", "displayName": "Core", "isContainer": true, "vote": 10],
        ],
    ]

    func testLocationReadsThePathWithAndWithoutAProject() throws {
        let full = try XCTUnwrap(AzureDevOpsPullRequestForge.location("acme/My Project/_git/app"))
        XCTAssertEqual(full.organization, "acme")
        XCTAssertEqual(full.project, "My Project")
        XCTAssertEqual(full.repository, "app")
        XCTAssertEqual(AzureDevOpsPullRequestForge.location("acme/_git/app")?.project, "app")
        XCTAssertNil(AzureDevOpsPullRequestForge.location("acme/app"))
    }

    func testDetailMapsThePullRequest() throws {
        let statuses: [[String: Any]] = [["id": 1, "state": "succeeded", "context": ["genre": "ci", "name": "build"], "targetUrl": "https://ci.example/1"]]
        let detail = try XCTUnwrap(AzureDevOpsPullRequestForge.detail(pull: pull, repo: repo, statuses: statuses))
        XCTAssertEqual(detail.repo, "acme/My Project/_git/app")
        XCTAssertEqual(detail.author, "ada@example.com")
        XCTAssertEqual(detail.state, .open)
        XCTAssertEqual(detail.baseBranch, "main")
        XCTAssertEqual(detail.headBranch, "feature/merge")
        XCTAssertEqual(detail.headSHA, "abc123")
        XCTAssertEqual(detail.mergeable, true)
        XCTAssertEqual(detail.url?.absoluteString, "https://dev.azure.com/acme/My%20Project/_git/app/pullrequest/12")
        XCTAssertEqual(detail.requestedReviewers, ["linus@example.com", "[app]\\Team"])
        XCTAssertEqual(detail.requestedTeams, ["[app]\\Team"])
        XCTAssertEqual(detail.labels, ["urgent"])
        XCTAssertEqual(detail.checks.first?.name, "ci/build")
        XCTAssertEqual(detail.nodeID, "12")
        XCTAssertEqual(detail.headRepository, repo.path)
        XCTAssertFalse(detail.activityLoaded)
        XCTAssertFalse(detail.features.commitView)
        XCTAssertNil(detail.autoMerge)
    }

    func testStatesAndMergeability() {
        XCTAssertEqual(AzureDevOpsPullRequestForge.state(["status": "completed"]), .merged)
        XCTAssertEqual(AzureDevOpsPullRequestForge.state(["status": "abandoned"]), .closed)
        XCTAssertEqual(AzureDevOpsPullRequestForge.state(["status": "active", "isDraft": true]), .draft)
        XCTAssertEqual(AzureDevOpsPullRequestForge.mergeability(["mergeStatus": "conflicts"]).mergeable, false)
        XCTAssertEqual(AzureDevOpsPullRequestForge.mergeability(["mergeStatus": "conflicts"]).state, "dirty")
        XCTAssertNil(AzureDevOpsPullRequestForge.mergeability(["mergeStatus": "queued"]).mergeable)
        XCTAssertEqual(AzureDevOpsPullRequestForge.mergeability(["mergeStatus": "rejectedByPolicy"]).state, "blocked")
    }

    func testAutoCompleteShowsAsAutoMerge() throws {
        var auto = pull
        auto["autoCompleteSetBy"] = ["uniqueName": "ada@example.com"]
        auto["completionOptions"] = ["mergeStrategy": "squash"]
        let detail = try XCTUnwrap(AzureDevOpsPullRequestForge.detail(pull: auto, repo: repo))
        XCTAssertEqual(detail.autoMerge, PullRequestAutoMerge(method: .squash, enabledBy: "ada@example.com"))
    }

    func testLinks() {
        var conflicted = pull
        conflicted["mergeStatus"] = "conflicts"
        let link = AzureDevOpsPullRequestForge.links([conflicted], repo: repo).first
        XCTAssertEqual(link?.repository, repo.path)
        XCTAssertEqual(link?.headBranch, "feature/merge")
        XCTAssertEqual(link?.conflicted, true)
        XCTAssertEqual(link?.url, "https://dev.azure.com/acme/My%20Project/_git/app/pullrequest/12")
    }

    func testRequestsPathNamesTheFullRef() {
        let path = AzureDevOpsPullRequestForge.requestsPath(branch: "feature/merge")
        XCTAssertTrue(path.contains("searchCriteria.sourceRefName=refs%2Fheads%2Ffeature%2Fmerge"), path)
        XCTAssertTrue(path.contains("searchCriteria.status=all"))
        XCTAssertTrue(path.hasSuffix("api-version=7.1"))
    }

    func testChecksKeepTheNewestOfAContextAndDropNotApplicable() {
        let checks = AzureDevOpsPullRequestForge.checks([
            ["id": 1, "state": "failed", "context": ["genre": "ci", "name": "build"]],
            ["id": 2, "state": "succeeded", "context": ["genre": "ci", "name": "build"]],
            ["id": 3, "state": "pending", "context": ["name": "scan"]],
            ["id": 4, "state": "notApplicable", "context": ["name": "skip"]],
            ["id": 5, "state": "error", "context": ["name": "lint"]],
        ])
        XCTAssertEqual(checks.map(\.name), ["lint", "scan", "ci/build"])
        XCTAssertEqual(checks.map(\.outcome), [.failing, .pending, .passing])
    }

    func testThreadsBecomeEvents() throws {
        let threads: [[String: Any]] = [
            ["id": 7, "status": "active", "comments": [
                ["id": 1, "parentCommentId": 0, "content": "Plain", "commentType": "text", "author": ["uniqueName": "ada@example.com"], "publishedDate": "2026-10-01T10:00:00Z"],
            ]],
            ["id": 8, "status": "fixed", "threadContext": ["filePath": "/src/a.swift", "rightFileStart": ["line": 4, "offset": 1]], "comments": [
                ["id": 1, "parentCommentId": 0, "content": "On a line", "commentType": "text", "author": ["displayName": "Grace"], "publishedDate": "2026-10-01T11:00:00Z"],
                ["id": 2, "parentCommentId": 1, "content": "Reply", "commentType": "text", "author": ["uniqueName": "ada@example.com"], "publishedDate": "2026-10-01T12:00:00Z"],
                ["id": 3, "parentCommentId": 1, "content": "Gone", "isDeleted": true],
            ]],
            ["id": 9, "comments": [["id": 1, "content": "Ada voted 10", "commentType": "system"]]],
            ["id": 10, "isDeleted": true, "comments": [["id": 1, "content": "Hidden", "commentType": "text"]]],
            ["id": 11, "status": "active", "threadContext": ["filePath": "/b.swift", "leftFileStart": ["line": 2, "offset": 1]], "comments": [
                ["id": 1, "content": "Removed line", "commentType": "text"],
            ]],
        ]
        let events = AzureDevOpsPullRequestForge.comments(threads: threads)
        XCTAssertEqual(events.map(\.id), ["comment-700001", "line-800001", "line-800002", "line-1100001"])
        XCTAssertEqual(events[0].kind, .comment)
        XCTAssertEqual(events[1].kind, .lineComment(path: "src/a.swift", line: 4))
        XCTAssertTrue(events[1].resolved)
        XCTAssertEqual(events[1].threadID, "8")
        XCTAssertEqual(events[2].replyTo, "line-800001")
        XCTAssertFalse(events[2].resolved)
        XCTAssertEqual(events[3].kind, .lineComment(path: "b.swift", line: 2))
        XCTAssertFalse(events[3].resolved)
    }

    func testCommentNumberHoldsThreadAndComment() throws {
        let number = AzureDevOpsPullRequestForge.commentNumber(thread: 8123, comment: 42)
        let place = AzureDevOpsPullRequestForge.comment(number)
        XCTAssertEqual(place.thread, 8123)
        XCTAssertEqual(place.comment, 42)
        let event = PullRequestEvent(id: "line-\(number)", kind: .comment, author: "", body: "", date: nil, url: nil)
        XCTAssertEqual(event.restComment?.id, number)
    }

    func testTimelineHoldsVotesAndCommits() {
        let commits = AzureDevOpsPullRequestForge.commits([
            ["commitId": "b2", "comment": "Second", "author": ["name": "Ada", "date": "2026-10-02T07:00:00Z"]],
            ["commitId": "a1", "comment": "First", "author": ["name": "Ada", "date": "2026-10-01T07:00:00Z"]],
        ])
        XCTAssertEqual(commits.map(\.sha), ["a1", "b2"])
        let events = AzureDevOpsPullRequestForge.events(pull: pull, threads: [], commits: commits)
        let verdicts = events.compactMap { event -> String? in
            if case .review(let state) = event.kind { return event.author + " " + state }
            return nil
        }
        // The group's vote is its members' vote, so it does not count on its own.
        XCTAssertEqual(verdicts.sorted(), ["grace@example.com APPROVED", "margaret@example.com CHANGES_REQUESTED"])
        XCTAssertEqual(events.filter { if case .commit = $0.kind { return true } else { return false } }.count, 2)
    }

    func testFilesHaveNoPatch() {
        let files = AzureDevOpsPullRequestForge.files([
            ["changeType": "edit", "item": ["path": "/a.swift", "objectId": "o1"]],
            ["changeType": "add", "item": ["path": "/b.swift", "objectId": "o2"]],
            ["changeType": "delete", "item": ["path": "/c.swift", "originalObjectId": "o3"]],
            ["changeType": "rename, edit", "sourceServerItem": "/old.swift", "item": ["path": "/d.swift", "objectId": "o4"]],
            ["changeType": "rename", "originalPath": "/was.swift", "item": ["path": "/e.swift", "objectId": "o5"]],
            ["changeType": "edit", "item": ["path": "/dir", "isFolder": true]],
            ["changeType": "edit", "item": ["path": "/module", "gitObjectType": "commit"]],
        ])
        XCTAssertEqual(files.map(\.path), ["a.swift", "b.swift", "c.swift", "d.swift", "e.swift"])
        XCTAssertEqual(files.map(\.status), ["modified", "added", "removed", "renamed", "renamed"])
        XCTAssertEqual(files[3].previousPath, "old.swift")
        XCTAssertEqual(files[4].previousPath, "was.swift")
        XCTAssertEqual(files[0].revision, "o1")
        XCTAssertEqual(files[2].revision, "")
        XCTAssertTrue(files.allSatisfy { $0.patch == nil })
    }

    func testRequestShapes() throws {
        XCTAssertEqual(AzureDevOpsPullRequestForge.mergeStrategy(.merge), "noFastForward")
        XCTAssertEqual(AzureDevOpsPullRequestForge.mergeStrategy(.squash), "squash")
        XCTAssertEqual(AzureDevOpsPullRequestForge.mergeStrategy(.rebase), "rebase")
        XCTAssertEqual(AzureDevOpsPullRequestForge.vote(.approve), 10)
        XCTAssertEqual(AzureDevOpsPullRequestForge.vote(.requestChanges), -5)
        XCTAssertNil(AzureDevOpsPullRequestForge.vote(.comment))
        XCTAssertNil(AzureDevOpsPullRequestForge.threadBody("Hi")["threadContext"])
        let line = AzureDevOpsPullRequestForge.threadBody("Hi", line: .init(path: "a.swift", line: 9, side: "LEFT", body: "Hi", startLine: 7))
        let context = try XCTUnwrap(line["threadContext"] as? [String: Any])
        XCTAssertEqual(context["filePath"] as? String, "/a.swift")
        XCTAssertEqual((context["leftFileStart"] as? [String: Any])?["line"] as? Int, 7)
        XCTAssertEqual((context["leftFileEnd"] as? [String: Any])?["line"] as? Int, 9)
        let delete = AzureDevOpsPullRequestForge.deleteBranchBody("x", head: "abc")
        XCTAssertEqual(delete["name"] as? String, "refs/heads/x")
        XCTAssertEqual(delete["newObjectId"] as? String, String(repeating: "0", count: 40))
    }

    func testABarePersonalTokenGetsItsColon() {
        let decoded = { (text: String) in String(decoding: Data(base64Encoded: text) ?? Data(), as: UTF8.self) }
        XCTAssertEqual(decoded(AzureDevOpsPullRequestForge.credential("secret")), ":secret")
        XCTAssertEqual(decoded(AzureDevOpsPullRequestForge.credential("ada:secret")), "ada:secret")
    }
}
