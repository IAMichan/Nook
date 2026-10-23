import XCTest

final class PullRequestViewedFilesTests: XCTestCase {
    private func file(_ path: String, _ revision: String?) -> PullRequestFile {
        PullRequestFile(path: path, status: "modified", additions: 1, deletions: 0, patch: nil, previousPath: nil, revision: revision)
    }

    private let pr = PullRequestViewedFiles.key(repo: "Acme/Web", number: 7)

    func testAMarkHoldsUntilThePushChangesTheFile() {
        var viewed = PullRequestViewedFiles()
        viewed.setViewed(true, file: file("a.swift", "aaa"), in: pr)
        XCTAssertTrue(viewed.isViewed(file("a.swift", "aaa"), in: pr))
        XCTAssertFalse(viewed.isViewed(file("a.swift", "bbb"), in: pr))
        XCTAssertFalse(viewed.isViewed(file("b.swift", "aaa"), in: pr))
        XCTAssertEqual(pr, "acme/web#7")
    }

    func testARemovedFileIsARealRevision() {
        var viewed = PullRequestViewedFiles()
        viewed.setViewed(true, file: file("gone.swift", ""), in: pr)
        XCTAssertTrue(viewed.isViewed(file("gone.swift", ""), in: pr))
        XCTAssertFalse(viewed.isViewed(file("gone.swift", "back"), in: pr))
    }

    func testWithoutARevisionTheMarkHolds() {
        var viewed = PullRequestViewedFiles()
        viewed.setViewed(true, file: file("a.swift", nil), in: pr)
        XCTAssertTrue(viewed.isViewed(file("a.swift", "later"), in: pr))
        viewed.setViewed(true, file: file("b.swift", "x"), in: pr)
        XCTAssertTrue(viewed.isViewed(file("b.swift", nil), in: pr))
        XCTAssertEqual(viewed.viewedCount([file("a.swift", nil), file("b.swift", "x"), file("c.swift", "y")], in: pr), 2)
    }

    func testUnmarkingAndPruning() {
        var viewed = PullRequestViewedFiles()
        viewed.setViewed(true, file: file("a.swift", "1"), in: pr)
        viewed.setViewed(true, file: file("b.swift", "2"), in: pr)
        viewed.setViewed(false, file: file("a.swift", "1"), in: pr)
        XCTAssertFalse(viewed.isViewed(file("a.swift", "1"), in: pr))
        viewed.prune(pr, keeping: [file("c.swift", "3")])
        XCTAssertTrue(viewed.marks.isEmpty)
    }

    func testOnlyTheNewestPullRequestsAreKept() {
        var viewed = PullRequestViewedFiles()
        let start = Date(timeIntervalSince1970: 0)
        for number in 0...PullRequestViewedFiles.limit {
            viewed.setViewed(true, file: file("a", "1"), in: PullRequestViewedFiles.key(repo: "r", number: number),
                             now: start.addingTimeInterval(Double(number)))
        }
        XCTAssertEqual(viewed.marks.count, PullRequestViewedFiles.limit)
        XCTAssertNil(viewed.marks[PullRequestViewedFiles.key(repo: "r", number: 0)])
    }

    func testTheParserKeepsGitHubsRevision() {
        let files = PullRequestDetailParser.files([
            ["filename": "a.swift", "status": "modified", "sha": "abc"],
            ["filename": "b.swift", "status": "removed", "sha": "def"],
        ])
        XCTAssertEqual(files.map(\.revision), ["abc", ""])
    }
}
