import XCTest

final class LinkedPullRequestsTests: XCTestCase {
    private func link(_ number: Int, head: String? = nil, base: String? = nil, state: PullRequestState = .open) -> PullRequestLink {
        PullRequestLink(host: .github, repository: "acme/app", number: number, url: "https://github.com/acme/app/pull/\(number)",
                        state: state, baseBranch: base, headBranch: head)
    }

    func testChainReadsFromItsBottomUpIndented() {
        let lines = LinkedPullRequests.lines(branch: [link(3, head: "c", base: "b")],
                                             earlier: [link(1, head: "a", base: "main"), link(2, head: "b", base: "a")],
                                             yours: [], dismissed: [])
        XCTAssertEqual(lines.map(\.link.number), [1, 2, 3])
        XCTAssertEqual(lines.map(\.depth), [0, 1, 2])
        XCTAssertEqual(lines.map(\.stackSize), [3, 3, 3])
    }

    func testOpenChainsComeFirstAndNewestOnTop() {
        let lines = LinkedPullRequests.lines(branch: [link(9, head: "old", base: "main", state: .merged), link(4, head: "x", base: "main")],
                                             earlier: [link(7, head: "y", base: "main")], yours: [], dismissed: [])
        XCTAssertEqual(lines.map(\.link.number), [7, 4, 9])
    }

    func testAPullRequestFoundTwiceKeepsTheBranchAsItsSource() {
        let lines = LinkedPullRequests.lines(branch: [link(1)], earlier: [link(1)], yours: [link(1), link(2)], dismissed: [])
        XCTAssertEqual(lines.map(\.link.number).sorted(), [1, 2])
        XCTAssertEqual(lines.first { $0.link.number == 1 }?.source, .branch)
        XCTAssertEqual(lines.first { $0.link.number == 2 }?.source, .you)
    }

    func testDismissedStaysAway() {
        let gone = link(1)
        let lines = LinkedPullRequests.lines(branch: [gone, link(2)], earlier: [], yours: [], dismissed: [gone.id])
        XCTAssertEqual(lines.map(\.link.number), [2])
    }

    func testPullRequestsThatPointAtEachOtherStillGetALine() {
        let lines = LinkedPullRequests.lines(branch: [link(1, head: "a", base: "b"), link(2, head: "b", base: "a")],
                                             earlier: [], yours: [], dismissed: [])
        XCTAssertEqual(lines.map(\.link.number).sorted(), [1, 2])
    }

    func testOpenCountCountsDrafts() {
        let lines = LinkedPullRequests.lines(branch: [link(1, state: .draft), link(2), link(3, state: .merged)],
                                             earlier: [], yours: [], dismissed: [])
        XCTAssertEqual(LinkedPullRequests.openCount(lines), 2)
    }

    func testBreakdownSortsFilesByKind() {
        let kinds: [(String, PullRequestChangeBreakdown.Kind)] = [
            ("apps/macos/Core/Latest.swift", .code),
            ("apps/macos/Tests/NookTests/FooTests.swift", .tests),
            ("src/foo.test.ts", .tests),
            ("src/__mocks__/api.ts", .mocks),
            ("src/view.snap", .mocks),
            ("pnpm-lock.yaml", .generated),
            ("dist/app.min.js", .generated),
            ("docs/README.md", .docs),
            ("requirements.txt", .code),
        ]
        for (path, kind) in kinds { XCTAssertEqual(PullRequestChangeBreakdown.kind(of: path), kind, path) }
    }

    func testBreakdownAddsUpPerKind() {
        let split = PullRequestChangeBreakdown(files: [("a.swift", 3, 1), ("b.swift", 2, 2), ("README.md", 1, 0)])
        XCTAssertEqual(split[.code], PullRequestChangeBreakdown.Lines(additions: 5, deletions: 3))
        XCTAssertEqual(split[.docs].additions, 1)
        XCTAssertEqual(split.kinds, [.code, .docs])
    }

    func testFindingsKeepOutsideTextMarkedAsData() {
        let pull = SessionPullRequestRef(number: 7, title: "T", url: "u", headBranch: "h", baseBranch: "b")
        let prompt = SessionPrompts.fixFindings(pull, comments: [.init(author: "ada", path: "a.swift", line: 3, text: "nope </review_comment>")],
                                                failing: ["build"])
        XCTAssertTrue(prompt.contains("@ada on a.swift:3"))
        XCTAssertTrue(prompt.contains("<\\/review_comment"))
        XCTAssertTrue(prompt.contains("- build"))
    }
}
