import XCTest

/// Pull request reads that come in together go out as one GraphQL request per account, at most 20 per request.
final class GitHubSnapshotBatcherTests: XCTestCase {
    private actor Sent {
        var bodies: [(variables: [String: Any], token: String)] = []
        func add(_ body: Data, _ token: String) {
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            bodies.append(((object?["variables"] as? [String: Any]) ?? [:], token))
        }
        var count: Int { bodies.count }
        var tokens: [String] { bodies.map(\.token) }
        var sizes: [Int] { bodies.map { $0.variables.count / 3 } }
    }

    private static func pull(_ title: String) -> [String: Any] {
        ["pullRequest": ["title": title, "state": "OPEN", "merged": false, "isDraft": false, "mergeable": "MERGEABLE",
                         "mergeStateStatus": "CLEAN", "baseRefName": "main"] as [String: Any]]
    }

    func testReadsTogetherGoOutAsOneRequestPerAccount() async {
        let sent = Sent()
        let batcher = GitHubSnapshotBatcher(window: .milliseconds(50)) { body, token in
            await sent.add(body, token)
            let variables = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["variables"] as? [String: Any] ?? [:]
            var data: [String: Any] = [:]
            for index in 0..<(variables.count / 3) {
                // Number 404 is one this account cannot see.
                if variables["k\(index)"] as? Int == 404 { data["p\(index)"] = NSNull() }
                else { data["p\(index)"] = Self.pull("PR \(variables["k\(index)"] ?? "?")") }
            }
            return ["data": data]
        }
        async let a = batcher.snapshot(repo: "o/r", number: 1, token: "t1")
        async let b = batcher.snapshot(repo: "o/r", number: 2, token: "t1")
        async let same = batcher.snapshot(repo: "O/R", number: 1, token: "t1")
        async let hidden = batcher.snapshot(repo: "o/r", number: 404, token: "t1")
        async let other = batcher.snapshot(repo: "o/r", number: 3, token: "t2")
        let answers = await [a, b, same, hidden, other]

        guard case .snapshot(let first) = answers[0], case .snapshot(let second) = answers[1] else { return XCTFail("\(answers)") }
        XCTAssertEqual(first.title, "PR 1")
        XCTAssertEqual(second.title, "PR 2")
        XCTAssertEqual(answers[2], answers[0], "the same pull request asked twice is read once")
        XCTAssertEqual(answers[3], .missing)
        let requests = await sent.count
        XCTAssertEqual(requests, 2, "one request per account")
        let sizes = await sent.sizes
        XCTAssertEqual(sizes.sorted(), [1, 3])
    }

    func testLongListsAreSplitAndFailuresFallBack() async {
        let sent = Sent()
        let batcher = GitHubSnapshotBatcher(window: .milliseconds(50)) { body, token in
            await sent.add(body, token)
            return nil
        }
        let answers = await withTaskGroup(of: GitHubSnapshotBatcher.Answer.self) { group in
            for number in 1...25 { group.addTask { await batcher.snapshot(repo: "o/r", number: number, token: "t") } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(answers.count, 25)
        XCTAssertTrue(answers.allSatisfy { $0 == .failed }, "a failed request sends every read to REST")
        let sizes = await sent.sizes
        XCTAssertEqual(sizes.sorted(), [5, 20])
    }

    func testBatchQueryNamesEachPullRequestUnderItsOwnAlias() throws {
        let body = try XCTUnwrap(GitHubPullRequestSnapshotQuery.batchBody([("a/b", 1), ("no-owner", 2), ("c/d", 3)]))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let query = try XCTUnwrap(object["query"] as? String)
        XCTAssertTrue(query.contains("p0: repository(owner: $o0"))
        XCTAssertFalse(query.contains("p1:"), "a name without an owner is left out")
        XCTAssertTrue(query.contains("p2: repository(owner: $o2"))
        XCTAssertTrue(query.contains("fragment nookSnapshot on PullRequest"))
        let variables = try XCTUnwrap(object["variables"] as? [String: Any])
        XCTAssertEqual(variables["o2"] as? String, "c")
        XCTAssertEqual(variables["k2"] as? Int, 3)
    }

    func testBadgesWakeOnTheSameBeat() {
        let now = Date(timeIntervalSince1970: 1_000.3)
        XCTAssertEqual(PullRequestStatusStore.aligned(30, now: now), 39.7, accuracy: 0.001)
        XCTAssertEqual(PullRequestStatusStore.aligned(30, now: Date(timeIntervalSince1970: 1_007)), 33, accuracy: 0.001)
        XCTAssertEqual(PullRequestStatusStore.aligned(0, now: now), 0)
    }
}
