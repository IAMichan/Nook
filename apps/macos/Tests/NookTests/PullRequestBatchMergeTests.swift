import XCTest

/// "Merge alle PR's": the list in the plan, the gate's check of it, which pull requests are skipped, and the report.
final class PullRequestBatchMergeTests: XCTestCase {
    private typealias Target = PullRequestBatchMerge.Target

    func testReadsEveryWayOfWritingAPullRequest() {
        let parsed = PullRequestBatchMerge.targets("IAMichan/nook#12, IAMichan/nook/pull/13\nhttps://github.com/acme/app/pull/7#issuecomment-1; acme/app#7")
        XCTAssertEqual(parsed.targets, [Target(repo: "IAMichan/nook", number: 12), Target(repo: "IAMichan/nook", number: 13),
                                        Target(repo: "acme/app", number: 7)])
        XCTAssertTrue(parsed.invalid.isEmpty)
        XCTAssertEqual(PullRequestBatchMerge.targets(["acme/app#1", "acme/app#2"]).targets.map(\.ref), ["acme/app#1", "acme/app#2"])
    }

    func testRejectsWhatIsNoPullRequest() {
        let parsed = PullRequestBatchMerge.targets("acme/app#0, #12, ../etc#3, acme/app#4")
        XCTAssertEqual(parsed.targets.map(\.ref), ["acme/app#4"])
        XCTAssertEqual(parsed.invalid, ["acme/app#0", "#12", "../etc#3"])
        XCTAssertTrue(PullRequestBatchMerge.problems("acme/app#4").isEmpty)
        XCTAssertFalse(PullRequestBatchMerge.problems("").isEmpty)
        XCTAssertFalse(PullRequestBatchMerge.problems("acme/app#4, nonsense").isEmpty)
        let many = (1...31).map { "acme/app#\($0)" }.joined(separator: ",")
        XCTAssertFalse(PullRequestBatchMerge.problems(many).isEmpty)
    }

    func testTheGateChecksTheList() {
        let schema: [String: Any] = ["type": "object", "properties": ["pulls": ["type": "string"]], "required": ["pulls"]]
        XCTAssertTrue(ActionGate.problems(tool: "github_merge_prs", input: ["pulls": "acme/app#1, acme/app#2"], schema: schema, parseDate: { _ in nil }).isEmpty)
        XCTAssertFalse(ActionGate.problems(tool: "github_merge_prs", input: ["pulls": "all of them"], schema: schema, parseDate: { _ in nil }).isEmpty)
    }

    func testThePlanNamesEveryPullRequest() {
        XCTAssertEqual(PullRequestBatchMerge.summary("acme/app#1, acme/app#2", method: "squash"),
                       "GitHub: merge 2 pull requests (squash): acme/app#1, acme/app#2")
    }

    private func detail(state: PullRequestDetail.State = .open, mergeable: Bool? = true, mergeState: String = "clean",
                        checks: [PullRequestCheck.Outcome] = [], canPush: Bool? = true) -> PullRequestDetail {
        var detail = PullRequestDetail(repo: "acme/app", number: 1, title: "T", body: "", url: nil, author: "ada", state: state,
                                       baseBranch: "main", headBranch: "f", headSHA: "abc", additions: 0, deletions: 0, changedFiles: 0,
                                       created: nil, updated: nil, mergeable: mergeable, mergeState: mergeState)
        detail.checks = checks.enumerated().map { PullRequestCheck(name: "c\($0.offset)", outcome: $0.element, detail: "", url: nil) }
        detail.canPush = canPush
        return detail
    }

    func testSkipsWhatIsNotReady() {
        XCTAssertNil(PullRequestBatchMerge.skipReason(detail()))
        XCTAssertNil(PullRequestBatchMerge.skipReason(detail(mergeable: nil, mergeState: "unknown", checks: [.passing, .skipped])))
        XCTAssertNil(PullRequestBatchMerge.skipReason(detail(mergeState: "behind")))
        XCTAssertEqual(PullRequestBatchMerge.skipReason(detail(state: .draft)), "draft")
        XCTAssertEqual(PullRequestBatchMerge.skipReason(detail(state: .merged)), "already merged")
        XCTAssertEqual(PullRequestBatchMerge.skipReason(detail(state: .closed)), "closed")
        XCTAssertEqual(PullRequestBatchMerge.skipReason(detail(mergeable: false, mergeState: "dirty")), "merge conflicts")
        XCTAssertEqual(PullRequestBatchMerge.skipReason(detail(checks: [.passing, .failing])), "CI failing")
        XCTAssertNil(PullRequestBatchMerge.skipReason(detail(checks: [.passing, .pending])))
        XCTAssertEqual(PullRequestBatchMerge.skipReason(detail(canPush: false)), "no write access")
    }

    func testNotesAMergeWhileCIIsStillRunning() {
        XCTAssertEqual(PullRequestBatchMerge.mergedLabel(.squash, detail(checks: [.passing])), "squash")
        XCTAssertEqual(PullRequestBatchMerge.mergedLabel(.merge, detail(checks: [.pending])), "merge, CI still running")
    }

    func testPicksAMethodTheRepositoryAllows() {
        XCTAssertEqual(PullRequestBatchMerge.method(requested: nil, allowed: [.merge, .squash]), .merge)
        XCTAssertEqual(PullRequestBatchMerge.method(requested: nil, allowed: [.squash]), .squash)
        XCTAssertEqual(PullRequestBatchMerge.method(requested: .rebase, allowed: [.merge, .rebase]), .rebase)
        XCTAssertNil(PullRequestBatchMerge.method(requested: .rebase, allowed: [.squash]))
    }

    func testReportsEveryOutcome() {
        let report = PullRequestBatchMerge.report([
            (Target(repo: "acme/app", number: 1), .merged("squash")),
            (Target(repo: "acme/app", number: 2), .skipped("draft")),
            (Target(repo: "acme/app", number: 3), .failed("GitHub refused the merge (422)."))
        ])
        XCTAssertEqual(report, """
        Merged 1 of 3 pull requests.
        ✓ acme/app#1 merged (squash)
        – acme/app#2 skipped: draft
        ✗ acme/app#3 failed: GitHub refused the merge (422).
        """)
    }
}
