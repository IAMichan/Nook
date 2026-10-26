import XCTest

final class PullRequestReadinessTests: XCTestCase {
    private func detail(state: PullRequestDetail.State = .open, mergeable: Bool? = true, mergeState: String = "clean",
                        checks: [PullRequestCheck.Outcome] = [], reviews: [(String, String)] = [],
                        requested: [String] = [], activityLoaded: Bool = true) -> PullRequestDetail {
        var detail = PullRequestDetail(repo: "acme/app", number: 1, title: "T", body: "", url: nil, author: "ada", state: state,
                                       baseBranch: "main", headBranch: "f", headSHA: "abc", additions: 0, deletions: 0, changedFiles: 0,
                                       created: nil, updated: nil, mergeable: mergeable, mergeState: mergeState)
        detail.checks = checks.enumerated().map { PullRequestCheck(name: "c\($0.offset)", outcome: $0.element, detail: "", url: nil) }
        detail.events = reviews.enumerated().map { index, review in
            PullRequestEvent(id: "r\(index)", kind: .review(review.1), author: review.0, body: "",
                             date: Date(timeIntervalSince1970: Double(index * 60)), url: nil)
        }
        detail.requestedReviewers = requested
        detail.activityLoaded = activityLoaded
        return detail
    }

    func testNothingToGetReadyOnceMergedOrClosed() {
        XCTAssertNil(PullRequestReadiness(detail(state: .merged)))
        XCTAssertNil(PullRequestReadiness(detail(state: .closed)))
    }

    func testReadyWhenEverythingIsGreen() throws {
        let readiness = try XCTUnwrap(PullRequestReadiness(detail(checks: [.passing, .skipped], reviews: [("bob", "APPROVED")])))
        XCTAssertEqual(readiness.items, [.noConflicts(base: "main"), .checksPassed(total: 2), .approved(by: ["bob"])])
        XCTAssertEqual(readiness.verdict, .ready)
    }

    func testBlockedByConflictsFailingChecksOrRequestedChanges() throws {
        let readiness = try XCTUnwrap(PullRequestReadiness(detail(mergeable: false, checks: [.failing, .passing],
                                                                  reviews: [("bob", "APPROVED"), ("cy", "CHANGES_REQUESTED")])))
        XCTAssertEqual(readiness.items, [.conflicts(base: "main"), .checksFailing(failing: 1, total: 2),
                                         .changesRequested(by: ["cy"])])
        XCTAssertEqual(readiness.verdict, .blocked)
    }

    func testWaitingOnRunningChecksAReviewerOrABranchBehind() throws {
        let readiness = try XCTUnwrap(PullRequestReadiness(detail(mergeState: "behind", checks: [.pending, .passing],
                                                                  requested: ["bob"])))
        XCTAssertEqual(readiness.items, [.behind(base: "main"), .checksRunning(running: 1, total: 2),
                                         .reviewRequested(from: ["bob"])])
        XCTAssertEqual(readiness.verdict, .waiting)
    }

    func testADraftWaitsAndSaysNothingAboutReviewsBeforeTheyLoad() throws {
        let readiness = try XCTUnwrap(PullRequestReadiness(detail(state: .draft, mergeable: nil, mergeState: "draft",
                                                                  activityLoaded: false)))
        XCTAssertEqual(readiness.items, [.draft, .noChecks])
        XCTAssertEqual(readiness.verdict, .waiting)
    }

    func testAnAnsweredReviewerIsNoLongerWaitedFor() throws {
        let readiness = try XCTUnwrap(PullRequestReadiness(detail(reviews: [("bob", "APPROVED")], requested: ["bob", "cy"])))
        XCTAssertEqual(readiness.items, [.noConflicts(base: "main"), .noChecks, .approved(by: ["bob"]),
                                         .reviewRequested(from: ["cy"])])
    }
}
