import XCTest

final class PullRequestStackTests: XCTestCase {
    private func item(_ number: Int, head: String, base: String = "main", repo: String = "acme/app", draft: Bool = false,
                      state: PullRequestItem.State = .open, nodeID: String = "") -> PullRequestItem {
        PullRequestItem(repo: repo, number: number, title: "T\(number)", url: nil, draft: draft, updated: nil, author: "ada",
                        state: state, headBranch: head, baseBranch: base, nodeID: nodeID)
    }

    func testAStackRunsFromTheTrunkUp() {
        let bottom = item(1, head: "a")
        let middle = item(2, head: "b", base: "a")
        let top = item(3, head: "c", base: "b")
        let alone = item(4, head: "d")
        let all = [top, alone, middle, bottom]
        XCTAssertEqual(PullRequestStack.stack(of: middle, in: all)?.map(\.number), [1, 2, 3])
        XCTAssertEqual(PullRequestStack.stack(of: top, in: all)?.map(\.number), [1, 2, 3])
        XCTAssertNil(PullRequestStack.stack(of: alone, in: all))
        XCTAssertEqual(PullRequestStack.position(of: middle, in: all)?.index, 2)
        XCTAssertEqual(PullRequestStack.position(of: middle, in: all)?.count, 3)
        XCTAssertEqual(PullRequestStack.mergeOrder(upTo: middle, in: all).map(\.number), [1, 2])
        XCTAssertEqual(PullRequestStack.mergeOrder(upTo: alone, in: all).map(\.number), [4])
    }

    func testOnlyOpenPullRequestsOfTheSameRepositoryCount() {
        let merged = item(1, head: "a", state: .merged)
        let other = item(2, head: "a", repo: "acme/site")
        let upper = item(3, head: "b", base: "a")
        XCTAssertNil(PullRequestStack.stack(of: upper, in: [merged, other, upper]))
    }

    func testABranchWithTwoOnTopGoesThroughTheOneAskedFor() {
        let bottom = item(1, head: "a")
        let left = item(5, head: "l", base: "a")
        let right = item(3, head: "r", base: "a")
        let all = [bottom, left, right]
        XCTAssertEqual(PullRequestStack.stack(of: left, in: all)?.map(\.number), [1, 5])
        XCTAssertEqual(PullRequestStack.stack(of: bottom, in: all)?.map(\.number), [1, 3], "the lowest number above")
    }

    func testALoopOfBasesEnds() {
        let first = item(1, head: "a", base: "b")
        let second = item(2, head: "b", base: "a")
        XCTAssertEqual(PullRequestStack.stack(of: first, in: [first, second])?.count, 2)
    }

    func testQuickActionsFollowTheState() {
        XCTAssertEqual(PullRequestQuickAction.actions(for: item(1, head: "a")), [.close, .merge])
        XCTAssertEqual(PullRequestQuickAction.actions(for: item(1, head: "a", draft: true, nodeID: "PR_1")), [.close, .ready])
        XCTAssertEqual(PullRequestQuickAction.actions(for: item(1, head: "a", draft: true)), [.close], "ready needs the node id")
        XCTAssertEqual(PullRequestQuickAction.actions(for: item(1, head: "a", state: .closed)), [.reopen])
        XCTAssertEqual(PullRequestQuickAction.actions(for: item(1, head: "a", state: .merged)), [])
        XCTAssertNil(PullRequestQuickAction.merge.action(for: item(1, head: "a")))
        XCTAssertEqual(PullRequestQuickAction.mergeMethod(preferred: .squash, allowed: [.merge, .squash]), .squash)
        XCTAssertEqual(PullRequestQuickAction.mergeMethod(preferred: .rebase, allowed: [.squash]), .squash)
        XCTAssertNil(PullRequestQuickAction.mergeMethod(preferred: .merge, allowed: []))
    }

    func testReadyForReviewGoesThroughGraphQL() throws {
        let request = try XCTUnwrap(PullRequestAction.markReady(nodeID: "PR_kw").request(repo: "acme/app", number: 7))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/graphql")
        XCTAssertEqual(request.body?["variables"], AnyHashable(["id": "PR_kw"] as [String: String]))
        XCTAssertNil(PullRequestAction.markReady(nodeID: "").request(repo: "acme/app", number: 7))
        XCTAssertEqual(PullRequestAction.markReady(nodeID: "x").auditTool, "github_ready_pr")
        XCTAssertEqual(PullRequestAction.graphQLError(["errors": [["message": "Not allowed"]]]), "GitHub: Not allowed")
        XCTAssertNil(PullRequestAction.graphQLError(["data": [:] as [String: Any]]))
    }

    func testChangingTheBase() {
        let request = PullRequestAction.changeBase("main").request(repo: "acme/app", number: 7)
        XCTAssertEqual(request?.method, "PATCH")
        XCTAssertEqual(request?.path, "/repos/acme/app/pulls/7")
        XCTAssertEqual(request?.body, ["base": "main"])
        XCTAssertNil(PullRequestAction.changeBase(" ").request(repo: "acme/app", number: 7))
    }

    func testTheAccountChoiceKeepsOneAccount() {
        let work = AccountPullRequests(id: "github", name: "Work", login: "ada", mine: [item(1, head: "a")], reviews: [], error: nil)
        let home = AccountPullRequests(id: "github.home", name: "Home", login: "ada2", mine: [item(2, head: "b")], reviews: [], error: "Offline")
        var filter = PullRequestFilter()
        XCTAssertEqual(filter.apply([work, home]).map(\.id), ["github", "github.home"])
        filter.account = "github.home"
        XCTAssertEqual(filter.apply([work, home]).map(\.id), ["github.home"])
        XCTAssertEqual(filter.activeCount, 1)
    }

    func testTerminalLinksStillFindQuotedFilesWithoutAnExtensionInAFolder() {
        XCTAssertEqual(TerminalLinks.extract(#"see 'docs/Read Me' now"#).map(\.text), ["docs/Read Me"])
        XCTAssertEqual(TerminalLinks.extract("it's fine, isn't it").map(\.text), [])
    }
}
