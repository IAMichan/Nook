import XCTest

/// GitHub's "Viewed" checkbox: the GraphQL Nook sends and reads, and how the forge's state and the marks on this Mac
/// come together (`PullRequestViewedFiles.reconcile`).
final class PullRequestViewedSyncTests: XCTestCase {
    private func file(_ path: String, _ revision: String?) -> PullRequestFile {
        PullRequestFile(path: path, status: "modified", additions: 1, deletions: 0, patch: nil, previousPath: nil, revision: revision)
    }

    private let pr = PullRequestViewedFiles.key(repo: "acme/web", number: 7)

    private func object(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    // MARK: GraphQL

    func testTheFilesQueryAsksForEveryFilesViewedState() throws {
        let body = try object(PullRequestViewedGraphQL.filesBody(repo: "acme/web", number: 7))
        let query = try XCTUnwrap(body["query"] as? String)
        XCTAssertTrue(query.contains("files(first: 100, after: $after)"))
        XCTAssertTrue(query.contains("nodes { path viewerViewedState }"))
        XCTAssertTrue(query.contains("pageInfo { hasNextPage endCursor }"))
        let variables = try XCTUnwrap(body["variables"] as? [String: Any])
        XCTAssertEqual(variables["owner"] as? String, "acme")
        XCTAssertEqual(variables["name"] as? String, "web")
        XCTAssertEqual(variables["number"] as? Int, 7)
        XCTAssertNil(variables["after"], "The first page has no cursor")

        let next = try object(PullRequestViewedGraphQL.filesBody(repo: "acme/web", number: 7, after: "Y3Vyc29y"))
        XCTAssertEqual((next["variables"] as? [String: Any])?["after"] as? String, "Y3Vyc29y")
        XCTAssertNil(PullRequestViewedGraphQL.filesBody(repo: "not-a-repo", number: 7))
    }

    func testTheMutationsTickAndClearByNodeIDAndPath() throws {
        let mark = try object(PullRequestViewedGraphQL.setViewedBody(nodeID: "PR_kw1", path: "src/a b.swift", viewed: true))
        XCTAssertTrue((mark["query"] as? String)?.contains("markFileAsViewed(input: {pullRequestId: $id, path: $path})") == true)
        XCTAssertFalse((mark["query"] as? String)?.contains("unmarkFileAsViewed") == true)
        XCTAssertEqual(mark["variables"] as? [String: String], ["id": "PR_kw1", "path": "src/a b.swift"])

        let unmark = try object(PullRequestViewedGraphQL.setViewedBody(nodeID: "PR_kw1", path: "a.swift", viewed: false))
        XCTAssertTrue((unmark["query"] as? String)?.contains("unmarkFileAsViewed(input: {pullRequestId: $id, path: $path})") == true)

        XCTAssertNil(PullRequestViewedGraphQL.setViewedBody(nodeID: "", path: "a.swift", viewed: true))
        XCTAssertNil(PullRequestViewedGraphQL.setViewedBody(nodeID: "PR_kw1", path: "", viewed: true))
    }

    func testAPageOfStatesIsRead() throws {
        let answer: [String: Any] = ["data": ["repository": ["pullRequest": ["files": [
            "pageInfo": ["hasNextPage": true, "endCursor": "abc"],
            "nodes": [
                ["path": "a.swift", "viewerViewedState": "VIEWED"],
                ["path": "b.swift", "viewerViewedState": "UNVIEWED"],
                ["path": "c.swift", "viewerViewedState": "DISMISSED"],
                ["path": "d.swift", "viewerViewedState": "SOMETHING_NEW"],
                NSNull(),
            ],
        ]]]]]
        let page = try XCTUnwrap(PullRequestViewedGraphQL.parse(answer))
        XCTAssertEqual(page.states, ["a.swift": .viewed, "b.swift": .unviewed, "c.swift": .changed])
        XCTAssertEqual(page.next, "abc")

        let last: [String: Any] = ["data": ["repository": ["pullRequest": ["files": [
            "pageInfo": ["hasNextPage": false, "endCursor": "zzz"], "nodes": [],
        ]]]]]
        XCTAssertNil(try XCTUnwrap(PullRequestViewedGraphQL.parse(last)).next)
    }

    func testAnErrorOrAMissingPullRequestIsNoAnswer() {
        XCTAssertNil(PullRequestViewedGraphQL.parse(["errors": [["message": "Field 'viewerViewedState' doesn't exist"]]]))
        XCTAssertNil(PullRequestViewedGraphQL.parse(["data": ["repository": ["pullRequest": NSNull()]]]))
        XCTAssertNil(PullRequestViewedGraphQL.parse(nil))
    }

    // MARK: Reconciling

    func testTheForgeWinsOnARead() {
        var marks = PullRequestViewedFiles()
        marks.setViewed(true, file: file("local.swift", "1"), in: pr)
        let files = [file("remote.swift", "r"), file("local.swift", "1"), file("other.swift", "o")]
        let retry = marks.reconcile(["remote.swift": .viewed, "local.swift": .unviewed], files: files, in: pr)
        XCTAssertTrue(retry.isEmpty)
        XCTAssertEqual(marks.status(file("remote.swift", "r"), in: pr), .viewed)
        XCTAssertEqual(marks.status(file("local.swift", "1"), in: pr), .unviewed, "GitHub says not viewed")
        XCTAssertEqual(marks.status(file("other.swift", "o"), in: pr), .unviewed, "Nothing said, nothing changed")
    }

    func testDismissedReadsAsChangedSinceViewed() {
        var marks = PullRequestViewedFiles()
        marks.reconcile(["a.swift": .changed], files: [file("a.swift", "new")], in: pr)
        XCTAssertEqual(marks.status(file("a.swift", "new"), in: pr), .changed)
        // A mark that already reads as changed keeps the revision it was viewed at.
        var earlier = PullRequestViewedFiles()
        earlier.setViewed(true, file: file("b.swift", "old"), in: pr)
        earlier.reconcile(["b.swift": .changed], files: [file("b.swift", "new")], in: pr)
        XCTAssertEqual(earlier.marks[pr]?["b.swift"]?.revision, "old")
    }

    func testViewedOnTheForgeFollowsTheCurrentRevision() {
        var marks = PullRequestViewedFiles()
        marks.setViewed(true, file: file("a.swift", "old"), in: pr)
        XCTAssertEqual(marks.status(file("a.swift", "new"), in: pr), .changed)
        marks.reconcile(["a.swift": .viewed], files: [file("a.swift", "new")], in: pr)
        XCTAssertEqual(marks.status(file("a.swift", "new"), in: pr), .viewed)
    }

    func testAnOfflineToggleStaysAndIsSentAgain() {
        var marks = PullRequestViewedFiles()
        marks.setViewed(true, file: file("a.swift", "1"), in: pr)
        marks.setUnsynced(true, path: "a.swift", in: pr)
        let retry = marks.reconcile(["a.swift": .unviewed], files: [file("a.swift", "1")], in: pr)
        XCTAssertEqual(retry.map(\.path), ["a.swift"])
        XCTAssertEqual(retry.map(\.viewed), [true])
        XCTAssertTrue(marks.isViewed(file("a.swift", "1"), in: pr), "Your toggle is not undone by a read before it got there")
        XCTAssertEqual(marks.unsynced[pr]?["a.swift"], true)
    }

    func testAToggleTheForgeShowsNoLongerWaits() {
        var marks = PullRequestViewedFiles()
        marks.setViewed(false, file: file("a.swift", "1"), in: pr)
        marks.setUnsynced(false, path: "a.swift", in: pr)
        let retry = marks.reconcile(["a.swift": .unviewed], files: [file("a.swift", "1")], in: pr)
        XCTAssertTrue(retry.isEmpty)
        XCTAssertNil(marks.unsynced[pr])
    }

    func testOnlyTheAnswerToTheLatestToggleClearsIt() {
        var marks = PullRequestViewedFiles()
        marks.setUnsynced(true, path: "a.swift", in: pr)
        marks.setUnsynced(false, path: "a.swift", in: pr)
        marks.markSynced(true, path: "a.swift", in: pr)
        XCTAssertEqual(marks.unsynced[pr]?["a.swift"], false, "The answer to the older toggle leaves the newer one waiting")
        marks.markSynced(false, path: "a.swift", in: pr)
        XCTAssertNil(marks.unsynced[pr])
    }

    func testMarksSavedBeforeTheSyncStillLoad() throws {
        let old = #"{"marks":{"acme/web#7":{"a.swift":{"revision":"1","at":0}}}}"#
        let marks = try JSONDecoder().decode(PullRequestViewedFiles.self, from: Data(old.utf8))
        XCTAssertTrue(marks.isViewed(file("a.swift", "1"), in: pr))
        XCTAssertTrue(marks.unsynced.isEmpty)
        var waiting = marks
        waiting.setUnsynced(false, path: "a.swift", in: pr)
        let again = try JSONDecoder().decode(PullRequestViewedFiles.self, from: JSONEncoder().encode(waiting))
        XCTAssertEqual(again, waiting)
    }

    func testOnlyGitHubKeepsAViewedStateOfItsOwn() {
        XCTAssertTrue(PullRequestForgeFeatures.github.viewedFiles)
        for features in [GitLabPullRequestForge.forgeFeatures, GiteaPullRequestForge.forgeFeatures,
                         BitbucketPullRequestForge.forgeFeatures, AzureDevOpsPullRequestForge.forgeFeatures,
                         GitCafePullRequestForge.forgeFeatures] {
            XCTAssertFalse(features.viewedFiles)
        }
    }
}
