import XCTest

/// The new-session composer's project inspection: a repository is seen as one, also right after launch while
/// `gitService` is still being located (the worktree and base-branch choices hang on it).
final class ProjectInspectionTests: XCTestCase {
    private var repo: URL!
    private var git: GitService!

    override func setUpWithError() throws {
        guard let service = GitService.locate() else { throw XCTSkip("git not available") }
        git = service
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("nook-inspect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git.run(["init", "-q", "-b", "main"], in: repo.path)
        try git.run(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "start"], in: repo.path)
    }

    override func tearDown() {
        if let repo { try? FileManager.default.removeItem(at: repo) }
    }

    func testInspectionBeforeGitIsLocatedStillSeesTheRepository() {
        // At launch the composer inspects the last project before `gitService` is set: it must wait for git.
        let info = ProjectInfo.inspect(repo.path, git: ProjectInfo.inspectionGit(known: nil))
        XCTAssertEqual(info.repoRoot.map(WorkspacePathPolicy.normalize), WorkspacePathPolicy.normalize(repo.path))
        XCTAssertEqual(info.currentBranch, "main")
        XCTAssertTrue(info.hasCommits)
        XCTAssertTrue(info.branches.contains("main"))
        XCTAssertFalse(info.isWorktree)
    }

    func testAKnownGitIsUsedAsIs() {
        XCTAssertEqual(ProjectInfo.inspectionGit(known: git)?.executable, git.executable)
    }

    func testAPlainFolderHasNoRepository() throws {
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("nook-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        let info = ProjectInfo.inspect(plain.path, git: git)
        XCTAssertNil(info.repoRoot)
        XCTAssertNil(info.currentBranch)
    }
}
