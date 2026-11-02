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

        // A new session for the project starts in the main checkout, not in the agent's worktree.
        XCTAssertEqual(WorktreeOrigin.checkoutPath(of: nested.path), main.standardizedFileURL.path)
        XCTAssertEqual(WorktreeOrigin.checkoutPath(of: main.path), main.path)
        XCTAssertEqual(WorktreeOrigin.checkoutPath(of: ""), "")
    }

    func testBareRepositoryKeepsTheWorktreeAsCheckout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-origin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appendingPathComponent("fix-x")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(root.path)/shop.git/worktrees/fix-x\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        XCTAssertEqual(WorktreeOrigin.checkoutPath(of: worktree.path), worktree.path)
    }

    func testNewSessionFolderIsAlwaysOneThatExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-origin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("shop")
        let other = root.appendingPathComponent("elsewhere/shop")
        try FileManager.default.createDirectory(at: main.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let removedClaude = main.appendingPathComponent(".claude/worktrees/fix-cart").path
        let removedNook = root.appendingPathComponent("worktrees/shop/fix-cart").path

        // A session that moved on to another repository does not lead there.
        let moved = root.appendingPathComponent("blog")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        XCTAssertEqual(WorktreeOrigin.newSessionFolder(project: "shop", paths: [moved.path, main.path], known: []), main.path)
        XCTAssertNil(WorktreeOrigin.newSessionFolder(project: "shop", paths: [moved.path], known: []))
        // A folder that still exists wins, also after a removed worktree.
        XCTAssertEqual(WorktreeOrigin.newSessionFolder(project: "shop", paths: [removedNook, main.path], known: []), main.path)
        // A removed agent worktree inside the repository leads back to it.
        XCTAssertEqual(WorktreeOrigin.newSessionFolder(project: "shop", paths: [removedClaude], known: []),
                       main.standardizedFileURL.path)
        // A removed worktree elsewhere falls back to a folder you opened before with the project's name.
        XCTAssertEqual(WorktreeOrigin.newSessionFolder(project: "shop", paths: [removedNook], known: ["/nope/shop", other.path]),
                       other.path)
        XCTAssertNil(WorktreeOrigin.newSessionFolder(project: "shop", paths: [removedNook], known: ["/nope/shop"]))
    }
}
