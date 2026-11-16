import XCTest

/// Closing several pull requests at once: every one is tried, a failure is reported with its reason, and a comment that
/// was refused keeps its pull request open.
final class PullRequestBatchCloseTests: XCTestCase {
    private struct Refused: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Records what was sent, in order.
    private actor Forge {
        var sent: [String] = []
        func record(_ line: String) { sent.append(line) }
    }

    func testAFailureDoesNotStopTheRest() async {
        let forge = Forge()
        let outcomes = await PullRequestBatchClose.run([1, 2, 3], comment: nil, post: { _, _ in
            XCTFail("No comment to post")
        }, close: { number in
            await forge.record("close \(number)")
            if number == 2 { throw Refused("GitHub did not permit this (403).") }
        })
        let sent = await forge.sent
        XCTAssertEqual(sent, ["close 1", "close 2", "close 3"])
        XCTAssertEqual(outcomes.map(\.outcome), [.closed, .failed("GitHub did not permit this (403)."), .closed])

        let report = PullRequestBatchClose.report(outcomes) { "#\($0)" }
        XCTAssertEqual(report.closed, 2)
        XCTAssertEqual(report.total, 3)
        XCTAssertFalse(report.allClosed)
        XCTAssertEqual(report.failures.map(\.name), ["#2"])
        XCTAssertEqual(report.failures.map(\.reason), ["GitHub did not permit this (403)."])
        XCTAssertEqual(report.failures.map(\.commentOnly), [false])
    }

    func testTheCommentGoesFirstAndARefusedOneKeepsItOpen() async {
        let forge = Forge()
        let outcomes = await PullRequestBatchClose.run([10, 11], comment: "  Superseded by #12  ", post: { number, text in
            await forge.record("comment \(number): \(text)")
            if number == 11 { throw Refused("locked") }
        }, close: { number in
            await forge.record("close \(number)")
        })
        let sent = await forge.sent
        XCTAssertEqual(sent, ["comment 10: Superseded by #12", "close 10", "comment 11: Superseded by #12"],
                       "#11 is not closed without its comment")
        XCTAssertEqual(outcomes.map(\.outcome), [.closed, .commentFailed("locked")])
        let report = PullRequestBatchClose.report(outcomes) { "#\($0)" }
        XCTAssertEqual(report.closed, 1)
        XCTAssertEqual(report.failures.map(\.commentOnly), [true])
    }

    func testAnEmptyCommentIsNoComment() async {
        XCTAssertNil(PullRequestBatchClose.comment("   \n"))
        XCTAssertNil(PullRequestBatchClose.comment(nil))
        XCTAssertEqual(PullRequestBatchClose.comment(" why "), "why")
        let outcomes = await PullRequestBatchClose.run([1], comment: " ", post: { _, _ in
            XCTFail("Whitespace is not a comment")
        }, close: { _ in })
        XCTAssertEqual(outcomes.map(\.outcome), [.closed])
        XCTAssertTrue(PullRequestBatchClose.report(outcomes) { "#\($0)" }.allClosed)
    }
}
