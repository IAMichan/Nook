import XCTest

final class WorktreeMoveTests: XCTestCase {
    private let cwd = "/Users/me/.nook/worktrees/nook/old-122f"

    func testFindsTheFolderAWorktreeAddMakes() {
        // The command that hid a session's new pull request: run from the main checkout, with an absolute path.
        XCTAssertEqual(WorktreeMove.added(in: "cd /Users/me/Nook && git fetch -q origin main && git worktree add -q -b nook/next-122f /Users/me/.nook/worktrees/nook/next-122f origin/main && cd /Users/me/.nook/worktrees/nook/next-122f && git log --oneline -3", cwd: cwd),
                       "/Users/me/.nook/worktrees/nook/next-122f")
        XCTAssertEqual(WorktreeMove.added(in: "git worktree add ../new-one", cwd: cwd), "/Users/me/.nook/worktrees/nook/new-one")
        XCTAssertEqual(WorktreeMove.added(in: "cd /repo; git worktree add wt/a main", cwd: cwd), "/repo/wt/a")
        XCTAssertEqual(WorktreeMove.added(in: "git -C /repo worktree add -B feat --reason 'x y' ../feat", cwd: cwd), "/feat")
        XCTAssertEqual(WorktreeMove.added(in: "git worktree add -f --detach \"/tmp/with space\" HEAD", cwd: cwd), "/tmp/with space")
        XCTAssertEqual(WorktreeMove.added(in: "git worktree add -- /x/y", cwd: cwd), "/x/y")
    }

    func testIgnoresCommandsThatMakeNoWorktree() {
        XCTAssertNil(WorktreeMove.added(in: "git worktree list", cwd: cwd))
        XCTAssertNil(WorktreeMove.added(in: "git worktree remove /a/b", cwd: cwd))
        XCTAssertNil(WorktreeMove.added(in: "echo 'git worktree add /a/b'", cwd: cwd))
        XCTAssertNil(WorktreeMove.added(in: "grep -rn \"worktree add\" Services", cwd: cwd))
        XCTAssertNil(WorktreeMove.added(in: "git worktree add", cwd: cwd))
    }

    func testFollowsWhenItsOwnWorktreeIsGoneOrTheWorkMoved() {
        let added = "/w/new"
        // Its own folder was cleaned up (a stray file left behind counts as gone: no checkout).
        XCTAssertTrue(WorktreeMove.follows(ownIsCheckout: false, added: added, changedFiles: []))
        // Still there, but the agent changed files in the new one.
        XCTAssertTrue(WorktreeMove.follows(ownIsCheckout: true, added: added, changedFiles: ["/w/new/apps/a.swift"]))
        // Still there and the work stayed: a worktree made for something else is not followed.
        XCTAssertFalse(WorktreeMove.follows(ownIsCheckout: true, added: added, changedFiles: ["/w/old/a.swift", "/w/newer/b.swift"]))
    }
}
