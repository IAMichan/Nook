import XCTest

final class WorktreeOriginTests: XCTestCase {
    func testGitFileNamesTheRepository() {
        XCTAssertEqual(WorktreeOrigin.repositoryName(gitFile: "gitdir: /code/nook/.git/worktrees/fix-x\n", worktree: "/code/nook/.claude/worktrees/fix-x"), "nook")
        XCTAssertEqual(WorktreeOrigin.repositoryName(gitFile: "gitdir: /code/nook.git/worktrees/fix-x", worktree: "/elsewhere/fix-x"), "nook")
        XCTAssertEqual(WorktreeOrigin.repositoryName(gitFile: "gitdir: ../../../.git/worktrees/fix-x", worktree: "/code/nook/.claude/worktrees/fix-x"), "nook")
        // A submodule is not a worktree.
        XCTAssertNil(WorktreeOrigin.repositoryName(gitFile: "gitdir: ../.git/modules/lib", worktree: "/code/nook/lib"))
        XCTAssertNil(WorktreeOrigin.repositoryName(gitFile: "", worktree: "/code/nook"))
    }

    func testWorktreeFolderAndItsSubfoldersNameTheRepository() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-origin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("shop")
        let worktree = main.appendingPathComponent(".claude/worktrees/fix-cart-1a2b")
        let nested = worktree.appendingPathComponent("apps/web")
        try FileManager.default.createDirectory(at: main.appendingPathComponent(".git/worktrees/fix-cart-1a2b"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "gitdir: \(main.path)/.git/worktrees/fix-cart-1a2b\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        XCTAssertEqual(WorktreeOrigin.repositoryName(of: worktree.path), "shop")
        XCTAssertEqual(WorktreeOrigin.repositoryName(of: nested.path), "shop")
        // The main checkout has a .git folder: its own name is right.
        XCTAssertNil(WorktreeOrigin.repositoryName(of: main.path))
    }
}
