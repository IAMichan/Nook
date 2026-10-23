import XCTest

final class WorktreeCleanupTests: XCTestCase {
    func testAWorktreeOnlyThisSessionUsesIsOffered() {
        XCTAssertEqual(WorktreeCleanup.orphaned(worktree: "/tmp/wt/feature", otherFolders: ["/tmp/repo", "/tmp/wt/other"]),
                       "/tmp/wt/feature")
    }

    func testAWorktreeAnotherSessionWorksInStays() {
        XCTAssertNil(WorktreeCleanup.orphaned(worktree: "/tmp/wt/feature", otherFolders: ["/tmp/wt/feature"]))
        XCTAssertNil(WorktreeCleanup.orphaned(worktree: "/tmp/wt/feature", otherFolders: ["/tmp/wt/feature/app"]))
        XCTAssertNil(WorktreeCleanup.orphaned(worktree: "/tmp/wt/feature/", otherFolders: ["/tmp/wt/feature"]))
    }

    func testASessionWithoutAWorktreeLeavesNothing() {
        XCTAssertNil(WorktreeCleanup.orphaned(worktree: nil, otherFolders: []))
        XCTAssertNil(WorktreeCleanup.orphaned(worktree: "", otherFolders: []))
    }

    func testASimilarNameIsNotTheSameFolder() {
        XCTAssertEqual(WorktreeCleanup.orphaned(worktree: "/tmp/wt/feat", otherFolders: ["/tmp/wt/feature"]), "/tmp/wt/feat")
    }
}
