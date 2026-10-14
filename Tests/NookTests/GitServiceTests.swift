import XCTest

final class GitParsingTests: XCTestCase {
    func testParseStatus() {
        let text = "## main...origin/main [ahead 2, behind 1]\0 M Sources/App.swift\0A  New.swift\0R  Renamed.swift\0Old.swift\0?? notes.txt\0D  Gone.swift\0UU Conflict.swift\0"
        let status = GitService.parseStatus(text)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertEqual(status.files.map(\.path), ["Sources/App.swift", "New.swift", "Renamed.swift", "notes.txt", "Gone.swift", "Conflict.swift"])
        XCTAssertEqual(status.files.map(\.kind), [.modified, .added, .renamed, .untracked, .deleted, .conflicted])
        XCTAssertEqual(status.files[2].oldPath, "Old.swift")
        XCTAssertFalse(status.files[0].staged)
        XCTAssertTrue(status.files[0].unstaged)
        XCTAssertTrue(status.files[1].staged)
    }

    func testParseStatusSpecialHeads() {
        XCTAssertEqual(GitService.parseStatus("## No commits yet on main\0").branch, "main")
        XCTAssertTrue(GitService.parseStatus("## HEAD (no branch)\0").detached)
        XCTAssertTrue(GitService.parseStatus("## feature\0").isClean)
    }

    func testParseNumstat() {
        let text = "3\t1\tSources/App.swift\0-\t-\timage.png\0" + "5\t0\t\0old.swift\0new.swift\0"
        let counts = GitService.parseNumstat(text)
        XCTAssertEqual(counts["Sources/App.swift"]?.added, 3)
        XCTAssertEqual(counts["Sources/App.swift"]?.removed, 1)
        XCTAssertNotNil(counts["image.png"])
        XCTAssertNil(counts["image.png"]?.added ?? nil, "binair: geen regels")
        XCTAssertEqual(counts["new.swift"]?.added, 5)
        XCTAssertNil(counts["old.swift"])
    }

    func testParseWorktrees() {
        let text = """
        worktree /repo
        HEAD abc
        branch refs/heads/main

        worktree /wt/one
        HEAD def
        branch refs/heads/nook/one
        locked

        worktree /wt/two
        HEAD 123
        detached
        prunable gitdir file points to non-existent location

        """
        let list = GitService.parseWorktrees(text)
        XCTAssertEqual(list.map(\.path), ["/repo", "/wt/one", "/wt/two"])
        XCTAssertTrue(list[0].isMain)
        XCTAssertFalse(list[1].isMain)
        XCTAssertEqual(list[1].branch, "nook/one")
        XCTAssertTrue(list[1].locked)
        XCTAssertNil(list[2].branch)
        XCTAssertTrue(list[2].prunable)
    }

    func testCloneURLValidation() {
        XCTAssertTrue(GitService.isCloneURL("https://github.com/owner/repo.git"))
        XCTAssertTrue(GitService.isCloneURL("git@github.com:owner/repo.git"))
        XCTAssertTrue(GitService.isCloneURL("ssh://git@host.example/x/y"))
        XCTAssertFalse(GitService.isCloneURL("--upload-pack=touch /tmp/x"))
        XCTAssertFalse(GitService.isCloneURL("file:///etc"))
        XCTAssertFalse(GitService.isCloneURL("https://exa mple.com/x"))
        XCTAssertFalse(GitService.isCloneURL(""))
        XCTAssertEqual(GitService.cloneFolderName("https://github.com/owner/My.Repo.git/"), "my-repo")
    }
}

/// Echte Git-repositories in een tijdelijke map: worktree maken, wijzigen, committen en veilig opruimen.
final class GitServiceIntegrationTests: XCTestCase {
    private var git: GitService!
    private var root: String!
    private var repo: String!

    override func setUpWithError() throws {
        guard let found = GitService.locate() else { throw XCTSkip("Git staat niet op deze machine") }
        git = found
        setenv("GIT_AUTHOR_NAME", "Nook Test", 1)
        setenv("GIT_AUTHOR_EMAIL", "test@nook.invalid", 1)
        setenv("GIT_COMMITTER_NAME", "Nook Test", 1)
        setenv("GIT_COMMITTER_EMAIL", "test@nook.invalid", 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        root = try TestData.tempFolder()
        repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git.run(["init", "-b", "main"], in: repo)
        try "hallo\n".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try git.run(["add", "README.md"], in: repo)
        try git.run(["-c", "commit.gpgsign=false", "commit", "-m", "eerste"], in: repo)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(atPath: root) }
    }

    func testRepositoryInfo() throws {
        XCTAssertEqual(git.repositoryRoot(for: repo).map(WorkspacePathPolicy.normalize), WorkspacePathPolicy.normalize(repo))
        XCTAssertNil(git.repositoryRoot(for: root), "de bovenliggende map is geen repository")
        XCTAssertEqual(git.currentBranch(repo), "main")
        XCTAssertTrue(git.hasCommits(repo))
        XCTAssertEqual(try git.branches(repo).local, ["main"])
        XCTAssertTrue(git.isValidBranchName("nook/test-1", in: repo))
        XCTAssertFalse(git.isValidBranchName("bad..name", in: repo))
    }

    func testWorktreeLifecycle() throws {
        let path = root + "/worktrees/repo/taak-a"
        try git.addWorktree(repo: repo, path: path, branch: "nook/taak-a", base: "main")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/README.md"))
        XCTAssertEqual(git.currentBranch(path), "nook/taak-a")
        XCTAssertEqual(git.currentBranch(repo), "main", "de eigen checkout verandert nooit van branch")

        // Een tweede worktree van dezelfde repository: echt los van de eerste.
        let other = root + "/worktrees/repo/taak-b"
        try git.addWorktree(repo: repo, path: other, branch: "nook/taak-b", base: "main")
        try "a\n".write(toFile: path + "/a.txt", atomically: true, encoding: .utf8)
        XCTAssertEqual(try git.status(path).files.map(\.path), ["a.txt"])
        XCTAssertTrue(try git.status(other).isClean, "wijzigingen in de ene worktree zie je niet in de andere")
        XCTAssertTrue(try git.status(repo).isClean)

        // Status telt regels van nieuwe bestanden.
        let status = try git.status(path)
        XCTAssertEqual(status.files.first?.kind, .untracked)
        XCTAssertEqual(status.files.first?.added, 1)

        // Weghalen met wijzigingen weigert zonder force.
        XCTAssertThrowsError(try git.removeWorktree(repo: repo, path: path, force: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        // Committen en voorsprong op de basis.
        let sha = try git.commit(path, message: "voeg a toe", paths: ["a.txt"])
        XCTAssertFalse(sha.isEmpty)
        XCTAssertTrue(try git.status(path).isClean)
        let divergence = try XCTUnwrap(git.divergence(path, base: "main"))
        XCTAssertEqual(divergence.ahead, 1)
        XCTAssertEqual(divergence.behind, 0)

        let list = try git.worktrees(repo)
        XCTAssertEqual(list.count, 3)
        XCTAssertTrue(list[0].isMain)

        // Nu schoon: weghalen lukt; de branch en zijn commit blijven.
        try git.removeWorktree(repo: repo, path: path, force: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(git.localBranchExists("nook/taak-a", in: repo))
        XCTAssertEqual(try git.worktrees(repo).count, 2)
    }

    func testWorktreeGuards() throws {
        XCTAssertThrowsError(try git.addWorktree(repo: repo, path: root + "/x", branch: "nook/x", base: "bestaat-niet"))
        XCTAssertThrowsError(try git.addWorktree(repo: repo, path: root + "/x", branch: "main", base: "main"), "bestaande branch")
        XCTAssertThrowsError(try git.addWorktree(repo: repo, path: root + "/x", branch: "bad name", base: "main"))
        XCTAssertThrowsError(try git.removeWorktree(repo: repo, path: repo, force: true), "nooit de hoofdmap")
        XCTAssertThrowsError(try git.removeWorktree(repo: repo, path: root, force: true), "nooit een map die geen worktree is")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/README.md"))
    }

    func testWorktreeNeedsCommits() throws {
        let empty = root + "/empty"
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        try git.run(["init", "-b", "main"], in: empty)
        XCTAssertFalse(git.hasCommits(empty))
        XCTAssertThrowsError(try git.addWorktree(repo: empty, path: root + "/wt", branch: "nook/x", base: "main"))
    }

    func testDiffForTrackedAndUntrackedFiles() throws {
        try "hallo\nwereld\n".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try "nieuw\n".write(toFile: repo + "/nieuw.txt", atomically: true, encoding: .utf8)
        let status = try git.status(repo)
        let readme = try XCTUnwrap(status.files.first { $0.path == "README.md" })
        XCTAssertEqual(readme.added, 1)
        XCTAssertEqual(readme.removed, 0)
        XCTAssertTrue(try git.diff(repo, file: readme).contains("+wereld"))
        let untracked = try XCTUnwrap(status.files.first { $0.path == "nieuw.txt" })
        XCTAssertTrue(try git.diff(repo, file: untracked).contains("+nieuw"))
    }

    func testCommitRequiresMessageAndFiles() throws {
        try "x\n".write(toFile: repo + "/x.txt", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try git.commit(repo, message: "  ", paths: ["x.txt"]))
        XCTAssertThrowsError(try git.commit(repo, message: "ok", paths: []))
    }

    func testPushRefusesUnknownRemote() throws {
        XCTAssertThrowsError(try git.push(repo, remote: "origin", branch: "main"))
    }

    func testCloneLocalRepositoryIsRefusedButHTTPSShapeAccepted() throws {
        // Een pad is geen geldig kloon-adres; zo kan een opdracht nooit lokale bestanden als bron gebruiken.
        XCTAssertThrowsError(try git.clone(url: repo, into: root + "/clones"))
    }
}
