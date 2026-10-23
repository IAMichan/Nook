import XCTest

final class PullRequestListTests: XCTestCase {
    private func item(_ number: Int, state: PullRequestItem.State = .open, ci: PullRequestItem.CI = .unknown, draft: Bool = false,
                      review: PullRequestItem.Review = .none, conflict: Bool = false, size: Int = 10, updated: Double = 0) -> PullRequestItem {
        PullRequestItem(repo: "acme/app", number: number, title: "T\(number)", url: nil, draft: draft,
                        updated: Date(timeIntervalSince1970: updated), author: "me", ci: ci, state: state,
                        additions: size, deletions: 0, review: review, conflict: conflict)
    }

    func testMergeReadinessPutsApprovedAndGreenFirstAndConflictsLast() {
        let rows = [
            item(1, conflict: true), item(2, ci: .passing), item(3, ci: .passing, review: .approved, size: 500),
            item(4, ci: .passing, review: .approved, size: 5), item(5, state: .merged), item(6, draft: true),
        ].map { PullRequestRepoGroup.Row(item: $0, role: .mine) }
        XCTAssertEqual(rows.sorted(by: .readiness).map(\.item.number), [4, 3, 2, 6, 1, 5])
    }

    func testBlockedOnMeLeadsWithReviewsThenWhatBlocksYours() {
        let rows = [
            PullRequestRepoGroup.Row(item: item(1, ci: .passing, review: .approved), role: .mine),
            PullRequestRepoGroup.Row(item: item(2, ci: .failing), role: .mine),
            PullRequestRepoGroup.Row(item: item(3), role: .review),
            PullRequestRepoGroup.Row(item: item(4, conflict: true), role: .mine),
            PullRequestRepoGroup.Row(item: item(5, review: .changesRequested), role: .mine),
            PullRequestRepoGroup.Row(item: item(6), role: .watched),
        ]
        XCTAssertEqual(rows.sorted(by: .blockedOnMe).map(\.item.number), [3, 4, 5, 2, 1, 6])
    }

    func testSizeSorts() {
        let rows = [item(1, size: 50), item(2, size: 5), item(3, state: .closed, size: 900)].map { PullRequestRepoGroup.Row(item: $0, role: .mine) }
        XCTAssertEqual(rows.sorted(by: .largest).map(\.item.number), [1, 2, 3])
        XCTAssertEqual(rows.sorted(by: .smallest).map(\.item.number), [2, 1, 3])
    }

    func testTheListReadsReviewDecisionConflictAndLabels() {
        let json = """
        {"data": {"viewer": {"login": "me"}, "mine": {"nodes": [
          {"number": 7, "title": "A", "url": "https://github.com/acme/app/pull/7", "isDraft": false, "updatedAt": "2026-10-01T10:00:00Z",
           "state": "OPEN", "additions": 3, "deletions": 1, "reviewDecision": "CHANGES_REQUESTED", "mergeable": "CONFLICTING",
           "labels": {"nodes": [{"name": "bug"}, {"name": "ui"}]}, "author": {"login": "me"},
           "repository": {"nameWithOwner": "acme/app"}, "commits": {"nodes": []}}]},
         "reviews": {"nodes": []}, "mineClosed": {"nodes": []}, "reviewsClosed": {"nodes": []}}}
        """
        let parsed = try? PullRequestGraphQL.parse(Data(json.utf8))
        let first = parsed?.mine.first
        XCTAssertEqual(first?.review, .changesRequested)
        XCTAssertEqual(first?.conflict, true)
        XCTAssertEqual(first?.labels, ["bug", "ui"])
        XCTAssertEqual(first?.size, 4)
    }

    func testOldSavedRowsStillDecode() throws {
        let old = #"{"repo":"a/b","number":1,"title":"x","draft":false,"author":"me"}"#
        let decoded = try JSONDecoder().decode(PullRequestItem.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.review, PullRequestItem.Review.none)
        XCTAssertFalse(decoded.conflict)
        XCTAssertEqual(decoded.labels, [])
    }

    func testActionsBuildGitHubsRequests() {
        XCTAssertEqual(PullRequestAction.review(.approve, body: "").request(repo: "a/b", number: 3),
                       .init(method: "POST", path: "/repos/a/b/pulls/3/reviews", body: ["event": "APPROVE"]))
        XCTAssertNil(PullRequestAction.review(.requestChanges, body: "  ").request(repo: "a/b", number: 3))
        XCTAssertEqual(PullRequestAction.review(.comment, body: "Looks fine").request(repo: "a/b", number: 3)?.body,
                       ["event": "COMMENT", "body": "Looks fine"])
        XCTAssertEqual(PullRequestAction.comment("hi").request(repo: "a/b", number: 3)?.path, "/repos/a/b/issues/3/comments")
        XCTAssertNil(PullRequestAction.comment(" ").request(repo: "a/b", number: 3))
        XCTAssertEqual(PullRequestAction.close.request(repo: "a/b", number: 3)?.body, ["state": "closed"])
        XCTAssertEqual(PullRequestAction.reopen.request(repo: "a/b", number: 3)?.method, "PATCH")
        XCTAssertNil(PullRequestAction.edit(title: " ", body: "x").request(repo: "a/b", number: 3))
        XCTAssertEqual(PullRequestAction.requestReviewers(["@anna, bob", "anna", "bad name!"]).request(repo: "a/b", number: 3)?.body,
                       ["reviewers": ["anna", "bob", "bad"]])
        XCTAssertEqual(PullRequestAction.updateBranch(headSHA: "abc").request(repo: "a/b", number: 3),
                       .init(method: "PUT", path: "/repos/a/b/pulls/3/update-branch", body: ["expected_head_sha": "abc"]))
        XCTAssertEqual(PullRequestAction.removeLabel("needs review").request(repo: "a/b", number: 3)?.path,
                       "/repos/a/b/issues/3/labels/needs%20review")
        XCTAssertEqual(PullRequestAction.removeLabel("needs review").request(repo: "a/b", number: 3)?.method, "DELETE")
        XCTAssertEqual(PullRequestAction.comment("secret words").auditArgs(repo: "a/b", number: 3), "a/b#3 comment (12 characters)")
        XCTAssertTrue(PullRequestAction.error(status: 422, object: ["message": "Validation Failed", "errors": ["Review cannot request changes on your own pull request"]])
            .contains("own pull request"))
    }

    func testFileOrderReadsSourceThenItsTestsThenGenerated() {
        let paths = ["Package.resolved", "docs/guide.md", "Tests/ParserTests.swift", "Sources/Parser.swift", "Sources/App.swift",
                     "web/__snapshots__/a.snap", "web/util.test.ts", "web/util.ts", "Tests/OrphanTests.swift", "dist/app.min.js"]
        XCTAssertEqual(PullRequestFileOrder.ordered(paths), [
            "Sources/App.swift", "Sources/Parser.swift", "Tests/ParserTests.swift", "web/util.ts", "web/util.test.ts",
            "Tests/OrphanTests.swift", "docs/guide.md", "dist/app.min.js", "Package.resolved", "web/__snapshots__/a.snap",
        ])
        XCTAssertEqual(PullRequestFileOrder.kind("yarn.lock"), .generated)
        XCTAssertEqual(PullRequestFileOrder.subject("test_util.py"), "util")
    }

    func testAViewedFileThatChangedSaysSo() {
        func file(_ revision: String) -> PullRequestFile {
            PullRequestFile(path: "a.swift", status: "modified", additions: 1, deletions: 0, patch: nil, previousPath: nil, revision: revision)
        }
        var viewed = PullRequestViewedFiles()
        let key = PullRequestViewedFiles.key(repo: "a/b", number: 1)
        XCTAssertEqual(viewed.status(file("1"), in: key), .unviewed)
        viewed.setViewed(true, file: file("1"), in: key)
        XCTAssertEqual(viewed.status(file("1"), in: key), .viewed)
        XCTAssertEqual(viewed.status(file("2"), in: key), .changed)
    }
}
