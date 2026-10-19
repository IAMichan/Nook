import XCTest

final class PullRequestDetailTests: XCTestCase {
    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func list(_ text: String) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    }

    private let pull = """
    {"number": 12, "title": "Add merging", "body": "  Does the thing.\\n", "html_url": "https://github.com/acme/app/pull/12",
     "user": {"login": "ada"}, "state": "open", "draft": false, "merged": false, "mergeable": true, "mergeable_state": "clean",
     "additions": 40, "deletions": 3, "changed_files": 2, "created_at": "2026-10-01T10:00:00Z", "updated_at": "2026-10-02T10:00:00Z",
     "base": {"ref": "main", "repo": {"full_name": "acme/app"}}, "head": {"ref": "feature/merge", "sha": "abc1234def"}}
    """

    func testParsesThePullRequest() throws {
        let detail = try XCTUnwrap(PullRequestDetailParser.detail(pull: try json(pull)))
        XCTAssertEqual(detail.id, "acme/app#12")
        XCTAssertEqual(detail.title, "Add merging")
        XCTAssertEqual(detail.body, "Does the thing.")
        XCTAssertEqual(detail.author, "ada")
        XCTAssertEqual(detail.state, .open)
        XCTAssertEqual(detail.baseBranch, "main")
        XCTAssertEqual(detail.headBranch, "feature/merge")
        XCTAssertEqual(detail.headSHA, "abc1234def")
        XCTAssertEqual(detail.additions, 40)
        XCTAssertEqual(detail.changedFiles, 2)
        XCTAssertNotNil(detail.created)
        XCTAssertTrue(detail.canMerge)
        XCTAssertNil(detail.mergeNote)
    }

    func testStates() throws {
        var object = try json(pull)
        object["draft"] = true
        XCTAssertEqual(PullRequestDetailParser.detail(pull: object)?.state, .draft)
        XCTAssertEqual(PullRequestDetailParser.detail(pull: object)?.canMerge, false)
        object["state"] = "closed"
        XCTAssertEqual(PullRequestDetailParser.detail(pull: object)?.state, .closed)
        object["merged"] = true
        XCTAssertEqual(PullRequestDetailParser.detail(pull: object)?.state, .merged)
        XCTAssertEqual(PullRequestDetailParser.detail(pull: object)?.mergeNote, "agents.pr.note.merged")
    }

    func testMergeabilityNotes() throws {
        var object = try json(pull)
        object["mergeable"] = false
        object["mergeable_state"] = "dirty"
        let conflicted = try XCTUnwrap(PullRequestDetailParser.detail(pull: object))
        XCTAssertFalse(conflicted.canMerge)
        XCTAssertEqual(conflicted.mergeNote, "agents.pr.note.conflict")

        object["mergeable"] = NSNull()
        object["mergeable_state"] = "unknown"
        let computing = try XCTUnwrap(PullRequestDetailParser.detail(pull: object))
        XCTAssertTrue(computing.canMerge)
        XCTAssertEqual(computing.mergeNote, "agents.pr.note.checking")

        object["mergeable"] = true
        object["mergeable_state"] = "blocked"
        let blocked = try XCTUnwrap(PullRequestDetailParser.detail(pull: object))
        XCTAssertTrue(blocked.canMerge, "GitHub decides: an admin may bypass branch protection")
        XCTAssertEqual(blocked.mergeNote, "agents.pr.note.blocked")
    }

    func testRepositorySettings() throws {
        let repository = try json(#"{"allow_merge_commit": false, "allow_squash_merge": true, "permissions": {"push": false}}"#)
        let detail = try XCTUnwrap(PullRequestDetailParser.detail(pull: try json(pull), repository: repository))
        XCTAssertEqual(detail.methods, [.squash, .rebase])
        XCTAssertEqual(detail.canPush, false)
        XCTAssertFalse(detail.canMerge)
        XCTAssertEqual(detail.mergeNote, "agents.pr.note.noAccess")
        XCTAssertEqual(PullRequestDetailParser.methods([:]), PullRequestMergeMethod.allCases)
    }

    func testChecksPutFailuresFirst() throws {
        let runs = try list("""
        [{"name": "lint", "status": "completed", "conclusion": "success", "html_url": "https://github.com/acme/app/runs/1"},
         {"name": "tests", "status": "completed", "conclusion": "failure"},
         {"name": "build", "status": "in_progress", "conclusion": null},
         {"name": "deploy", "status": "completed", "conclusion": "skipped"}]
        """)
        let statuses = try list(#"[{"context": "ci/legacy", "state": "success", "description": "", "target_url": "https://ci.example.com/1"}]"#)
        let checks = PullRequestDetailParser.checks(runs: runs, statuses: statuses)
        XCTAssertEqual(checks.map(\.name), ["tests", "build", "lint", "ci/legacy", "deploy"])
        XCTAssertEqual(checks.map(\.outcome), [.failing, .pending, .passing, .passing, .skipped])
        XCTAssertEqual(checks[3].detail, "success")

        var detail = try XCTUnwrap(PullRequestDetailParser.detail(pull: try json(pull)))
        detail.checks = checks
        XCTAssertEqual(detail.checkSummary, .failing)
        XCTAssertEqual(detail.mergeNote, "agents.pr.note.unstable")
        detail.checks = Array(checks.dropFirst())
        XCTAssertEqual(detail.checkSummary, .pending)
    }

    func testConversationIsInOrderWithoutEmptyWrappers() throws {
        let reviews = try list("""
        [{"id": 1, "user": {"login": "bob"}, "state": "APPROVED", "body": "", "submitted_at": "2026-10-02T09:00:00Z"},
         {"id": 2, "user": {"login": "bob"}, "state": "COMMENTED", "body": "", "submitted_at": "2026-10-01T12:00:00Z"},
         {"id": 3, "user": {"login": "eve"}, "state": "PENDING", "body": "draft", "submitted_at": null}]
        """)
        let comments = try list(#"[{"id": 4, "user": {"login": "ada"}, "body": "Thanks!", "created_at": "2026-10-02T10:00:00Z"}]"#)
        let lines = try list(#"[{"id": 5, "user": {"login": "bob"}, "body": "Rename", "path": "a.swift", "line": 7, "created_at": "2026-10-01T12:00:00Z"}]"#)
        let events = PullRequestDetailParser.events(reviews: reviews, comments: comments, lineComments: lines)
        XCTAssertEqual(events.map(\.id), ["line-5", "review-1", "comment-4"])
        XCTAssertEqual(events[0].kind, .lineComment(path: "a.swift", line: 7))
        XCTAssertEqual(events[1].kind, .review("APPROVED"))
    }

    func testTimelineMergesCommitsAndEvents() throws {
        let timeline = try list("""
        [{"id": 10, "event": "labeled", "actor": {"login": "ada"}, "label": {"name": "bug"}, "created_at": "2026-10-01T11:00:00Z"},
         {"id": 11, "event": "subscribed", "actor": {"login": "ada"}, "created_at": "2026-10-01T11:01:00Z"},
         {"id": 12, "event": "commented", "actor": {"login": "bob"}, "created_at": "2026-10-01T11:02:00Z"},
         {"id": 13, "event": "review_requested", "actor": {"login": "ada"}, "requested_reviewer": {"login": "bob"}, "created_at": "2026-10-01T13:00:00Z"},
         {"event": "cross-referenced", "actor": {"login": "eve"}, "created_at": "2026-10-03T09:00:00Z",
          "source": {"issue": {"number": 7, "title": "Crash", "repository": {"full_name": "acme/app"}}}},
         {"id": 14, "event": "merged", "actor": {"login": "ada"}, "commit_id": "fedcba9876", "created_at": "2026-10-04T09:00:00Z"}]
        """)
        let commits = [PullRequestCommit(sha: "1234567890", message: "Add merging", author: "ada",
                                         date: PullRequestDetailParser.date("2026-10-01T10:00:00Z"))]
        let events = PullRequestDetailParser.events(reviews: [], comments: [], lineComments: [], timeline: timeline, commits: commits)
        XCTAssertEqual(events.map(\.kind), [
            .commit(sha: "1234567890"),
            .activity(type: "labeled", detail: "bug"),
            .activity(type: "review_requested", detail: "@bob"),
            .activity(type: "cross-referenced", detail: "acme/app#7 Crash"),
            .activity(type: "merged", detail: "fedcba9"),
        ])
        XCTAssertEqual(events[0].body, "Add merging")
        XCTAssertEqual(events[1].author, "ada")
        XCTAssertEqual(Set(events.map(\.id)).count, events.count)
    }

    func testCommitsAndFiles() throws {
        let commits = PullRequestDetailParser.commits(try list("""
        [{"sha": "1234567890", "author": null, "commit": {"message": "Add merging\\n\\nBody", "author": {"name": "Ada", "date": "2026-10-01T10:00:00Z"}}}]
        """))
        XCTAssertEqual(commits.first?.shortSHA, "1234567")
        XCTAssertEqual(commits.first?.subject, "Add merging")
        XCTAssertEqual(commits.first?.author, "Ada")

        let files = PullRequestDetailParser.files(try list("""
        [{"filename": "b.swift", "status": "renamed", "previous_filename": "a.swift", "additions": 1, "deletions": 0, "patch": "@@ -1 +1 @@\\n-a\\n+b"},
         {"filename": "logo.png", "status": "added", "additions": 0, "deletions": 0}]
        """))
        XCTAssertEqual(files.map(\.path), ["b.swift", "logo.png"])
        XCTAssertEqual(files[0].previousPath, "a.swift")
        XCTAssertNotNil(files[0].patch)
        XCTAssertNil(files[1].patch)
    }

    func testMergeRequestPinsTheHead() {
        let body = PullRequestDetailParser.mergeBody(method: .squash, sha: "abc")
        XCTAssertEqual(body["merge_method"] as? String, "squash")
        XCTAssertEqual(body["sha"] as? String, "abc")
        XCTAssertNil(PullRequestDetailParser.mergeBody(method: .merge, sha: "")["sha"])
    }

    func testMergeErrors() {
        XCTAssertTrue(PullRequestDetailParser.mergeError(status: 409, object: [:]).contains("409"))
        XCTAssertTrue(PullRequestDetailParser.mergeError(status: 405, object: ["message": "Pull Request is not mergeable"])
            .contains("Pull Request is not mergeable"))
        XCTAssertEqual(PullRequestDetailParser.mergeError(status: 500, object: [:]), "GitHub returned an error (500).")
    }
}
