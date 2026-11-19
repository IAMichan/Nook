import XCTest

/// The forge's hourly limit, read from its answers: background reads slow down, stop under the reserve, and nothing goes
/// out once it is used up, until the reset.
final class ForgeRateBudgetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func answer(_ path: String = "/repos/a/b/pulls/1", status: Int = 200, remaining: Int, limit: Int = 5000,
                        resetIn: TimeInterval = 1800, resource: String? = "core", extra: [String: String] = [:]) -> HTTPURLResponse {
        var headers = ["X-RateLimit-Limit": String(limit), "X-RateLimit-Remaining": String(remaining),
                       "X-RateLimit-Reset": String(Int(now.timeIntervalSince1970 + resetIn))]
        if let resource { headers["X-RateLimit-Resource"] = resource }
        headers.merge(extra) { _, new in new }
        return HTTPURLResponse(url: URL(string: "https://api.github.com" + path)!, statusCode: status, httpVersion: nil,
                               headerFields: headers)!
    }

    func testBackgroundSlowsDownAndStopsUnderTheReserve() {
        let budget = ForgeRateBudget()
        XCTAssertTrue(budget.allowsBackground(now: now))
        XCTAssertEqual(budget.slowdown(now: now), 1)

        budget.record(answer(remaining: 3000), now: now)
        XCTAssertEqual(budget.slowdown(now: now), 1)
        budget.record(answer(remaining: 2000), now: now)
        XCTAssertEqual(budget.slowdown(now: now), 2)
        budget.record(answer(remaining: 1000), now: now)
        XCTAssertEqual(budget.slowdown(now: now), 4)
        XCTAssertTrue(budget.allowsBackground(now: now))

        budget.record(answer(remaining: 499), now: now)
        XCTAssertFalse(budget.allowsBackground(now: now), "the last tenth is kept for what you do yourself")
        XCTAssertNil(budget.pausedUntil(URL(string: "https://api.github.com/repos/a/b")!, now: now), "but it still goes out")

        // After the reset the forge has filled it again.
        let later = now.addingTimeInterval(1801)
        XCTAssertTrue(budget.allowsBackground(now: later))
        XCTAssertEqual(budget.slowdown(now: later), 1)
    }

    func testUsedUpPausesUntilTheResetPerLimit() {
        let budget = ForgeRateBudget()
        budget.record(answer(status: 403, remaining: 0, resetIn: 600), now: now)
        let rest = URL(string: "https://api.github.com/repos/a/b/pulls/1")!
        XCTAssertEqual(budget.pausedUntil(rest, now: now), now.addingTimeInterval(600))
        XCTAssertNil(budget.pausedUntil(URL(string: "https://api.github.com/graphql")!, now: now), "GraphQL has its own limit")
        XCTAssertNil(budget.pausedUntil(URL(string: "https://gitlab.com/api/v4/projects")!, now: now), "other hosts are untouched")
        XCTAssertNil(budget.pausedUntil(rest, now: now.addingTimeInterval(601)))
    }

    func testRefusalWithoutATimeWaitsLongerEachTime() {
        let budget = ForgeRateBudget()
        let url = URL(string: "https://ghe.example.com/api/v3/repos/a/b")!
        let refusal = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: [:])!
        budget.record(refusal, now: now)
        XCTAssertEqual(budget.pausedUntil(url, now: now), now.addingTimeInterval(30))
        budget.record(refusal, now: now)
        XCTAssertEqual(budget.pausedUntil(url, now: now), now.addingTimeInterval(60))
        XCTAssertEqual(ForgeRateBudget.fallbackPause(attempt: 20), 15 * 60)

        let asked = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: ["Retry-After": "90"])!
        budget.record(asked, now: now)
        XCTAssertEqual(budget.pausedUntil(url, now: now), now.addingTimeInterval(90))
    }

    func testGraphQLGoesFirstUntilItRunsLow() {
        let budget = ForgeRateBudget()
        XCTAssertTrue(budget.prefersGraphQL(now: now), "nothing known: GraphQL, batched")
        budget.record(answer("/graphql", remaining: 1500, resource: "graphql"), now: now)
        XCTAssertTrue(budget.prefersGraphQL(now: now), "still over a quarter")
        budget.record(answer("/graphql", remaining: 1000, resource: "graphql"), now: now)
        XCTAssertFalse(budget.prefersGraphQL(now: now), "under a quarter, and REST has more left")
        budget.record(answer(remaining: 500), now: now)
        XCTAssertTrue(budget.prefersGraphQL(now: now), "REST has even less")
        budget.record(answer(status: 403, remaining: 0), now: now)
        XCTAssertTrue(budget.prefersGraphQL(now: now))
        XCTAssertTrue(budget.allowsBackground(forPage: URL(string: "https://github.com/a/b/pull/1"), orGraphQL: true, now: now))
        XCTAssertFalse(budget.allowsBackground(forPage: URL(string: "https://github.com/a/b/pull/1"), now: now))
        budget.record(answer("/graphql", status: 403, remaining: 0, resource: "graphql"), now: now)
        XCTAssertFalse(budget.prefersGraphQL(now: now), "GraphQL used up: REST, even when it is too")
    }

    func testResourceOfARequest() {
        XCTAssertEqual(ForgeRateBudget.resource(of: URL(string: "https://api.github.com/graphql")!), "graphql")
        XCTAssertEqual(ForgeRateBudget.resource(of: URL(string: "https://ghe.example.com/api/graphql")!), "graphql")
        XCTAssertEqual(ForgeRateBudget.resource(of: URL(string: "https://api.github.com/search/issues?q=x")!), "search")
        XCTAssertEqual(ForgeRateBudget.resource(of: URL(string: "https://api.github.com/repos/a/b")!), "core")
        XCTAssertEqual(ForgeRateBudget.apiHost(forPage: URL(string: "https://github.com/a/b/pull/1")), "api.github.com")
        XCTAssertEqual(ForgeRateBudget.apiHost(forPage: URL(string: "https://ghe.example.com/a/b/pull/1")), "ghe.example.com")
    }

    /// The gate's own answer reads as GitHub's limit, with the time it lifts.
    func testGateRefusalReadsAsARateLimit() {
        let url = URL(string: "https://api.github.com/repos/a/b/pulls/1")!
        let (response, body) = ForgeRateGate.refusal(url, until: Date().addingTimeInterval(600))
        XCTAssertEqual(ConnectorErrorKind.forHTTP(response, body: body), .rateLimited)
        XCTAssertEqual(response.value(forHTTPHeaderField: "X-RateLimit-Resource"), "core")
        XCTAssertFalse(GitHubRateLimit.isAnonymous(String(decoding: body, as: UTF8.self)))
    }

    func testSnapshotFromGraphQLSpeaksLikeTheRestRead() throws {
        let json = """
        {"data":{"repository":{"pullRequest":{
          "title":"Fix it","state":"OPEN","merged":false,"isDraft":false,"mergeable":"CONFLICTING",
          "mergeStateStatus":"DIRTY","baseRefName":"main","autoMergeRequest":null,
          "commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
            {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"FAILURE"},
            {"__typename":"CheckRun","name":"lint","status":"IN_PROGRESS","conclusion":null},
            {"__typename":"StatusContext","context":"ci/legacy","state":"SUCCESS"}]}}}}]},
          "reviews":{"nodes":[{"state":"PENDING","body":"draft","author":{"__typename":"User","login":"ann"}},
                              {"state":"CHANGES_REQUESTED","body":"Please fix","author":{"__typename":"User","login":"ann"}}]},
          "comments":{"nodes":[{"body":"Later","createdAt":"2026-11-19T10:05:00Z","author":{"__typename":"Bot","login":"coderabbitai"}}]},
          "reviewThreads":{"nodes":[{"path":"a.swift","comments":{"nodes":[
            {"body":"Here","createdAt":"2026-11-19T10:00:00Z","author":{"__typename":"User","login":"bob"}}]}}]}
        }}}}
        """
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let snapshot = try XCTUnwrap(GitHubPullRequestSnapshotQuery.parse(root))
        XCTAssertEqual(snapshot.state, "open")
        XCTAssertEqual(snapshot.checks, "failure")
        XCTAssertEqual(snapshot.failedChecks, ["build"])
        XCTAssertTrue(snapshot.checksKnown)
        XCTAssertEqual(snapshot.reviews, [.init(author: "ann", verdict: "CHANGES_REQUESTED", text: "Please fix")])
        XCTAssertEqual(snapshot.comments, [.init(author: "bob", verdict: "", text: "a.swift: Here"),
                                           .init(author: "coderabbitai[bot]", verdict: "", text: "Later")])
        XCTAssertTrue(snapshot.conflicted)
        XCTAssertTrue(snapshot.mergeabilityKnown)
        XCTAssertEqual(snapshot.merge, PullRequestMergeFacts(state: "dirty", autoMerge: false, baseBranch: "main"))
        XCTAssertEqual(snapshot.title, "Fix it")

        XCTAssertNil(GitHubPullRequestSnapshotQuery.parse(["data": ["repository": NSNull()]]))
        XCTAssertNil(GitHubPullRequestSnapshotQuery.body(repo: "no-owner", number: 1))
    }
}
