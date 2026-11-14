import XCTest

/// Checkpoints per turn: a snapshot under a hidden ref that never touches the branch, and restoring it.
final class GitCheckpointTests: XCTestCase {
    private var repo: URL!
    private var git: GitService!

    override func setUpWithError() throws {
        guard let service = GitService.locate() else { throw XCTSkip("git not available") }
        git = service
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("nook-cp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git.run(["init", "-q", "-b", "main"], in: repo.path)
        try git.run(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "start"], in: repo.path)
        try write("a.txt", "een")
        try write(".gitignore", "secret.txt\n")
        try git.run(["add", "-A"], in: repo.path)
        try git.run(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-q", "-m", "a"], in: repo.path)
    }

    override func tearDown() {
        if let repo { try? FileManager.default.removeItem(at: repo) }
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String) -> String? {
        try? String(contentsOf: repo.appendingPathComponent(name), encoding: .utf8)
    }

    func testLineCountsOfATurnBetweenSnapshots() throws {
        let before = GitService.checkpointRef(session: UUID(), index: 0)
        try git.checkpoint(repo.path, ref: before)
        try write("a.txt", "een\ntwee\ndrie\n")
        let after = GitService.checkpointRef(session: UUID(), index: 1)
        try git.checkpoint(repo.path, ref: after)
        try write("a.txt", "later")

        let turn = try git.lineCounts(repo.path, paths: ["a.txt"], from: before, to: after)
        XCTAssertEqual(turn["a.txt"]?.added, 3)
        XCTAssertEqual(turn["a.txt"]?.removed, 1)
        let untilNow = try git.lineCounts(repo.path, paths: ["a.txt"], from: before, to: nil)
        XCTAssertEqual(untilNow["a.txt"]?.added, 1, "without a snapshot after the turn: the files as they are now")
        XCTAssertTrue(try git.lineCounts(repo.path, paths: [], from: before, to: nil).isEmpty)
    }

    func testLineCountsOfEveryFileATurnChanged() throws {
        let before = GitService.checkpointRef(session: UUID(), index: 0)
        try git.checkpoint(repo.path, ref: before)
        // Changed by a command, not an edit tool: only the snapshots know.
        try write("a.txt", "een\ntwee\n")
        try write("b.txt", "nieuw\n")
        try write("secret.txt", "ignored")
        let after = GitService.checkpointRef(session: UUID(), index: 1)
        try git.checkpoint(repo.path, ref: after)

        let turn = try git.lineCounts(repo.path, paths: nil, from: before, to: after)
        XCTAssertEqual(Set(turn.keys), ["a.txt", "b.txt"], "every changed file, a new one too, but not an ignored one")
        XCTAssertEqual(turn["b.txt"]?.added, 1)
    }

    func testFirstSnapshotOfAFreshWorktreeIsHead() throws {
        let ref = GitService.checkpointRef(session: UUID(), index: 0)
        try git.checkpointHead(repo.path, ref: ref)
        XCTAssertEqual(try git.run(["rev-parse", ref], in: repo.path), try git.run(["rev-parse", "HEAD"], in: repo.path))
        try write("later.txt", "nieuw")
        try git.restore(repo.path, to: ref)
        XCTAssertNil(read("later.txt"), "back to HEAD: a file added later goes")
        XCTAssertEqual(read("a.txt"), "een")
    }

    func testCheckpointAndRestore() throws {
        let session = UUID()
        let head = try git.run(["rev-parse", "HEAD"], in: repo.path)
        try write("a.txt", "twee")
        try write("new.txt", "nieuw")
        try write("secret.txt", "geheim")
        let ref = GitService.checkpointRef(session: session, index: 0)
        try git.checkpoint(repo.path, ref: ref)
        XCTAssertEqual(try git.run(["rev-parse", "HEAD"], in: repo.path), head, "the branch gets no commit")
        XCTAssertTrue(try git.run(["status", "--porcelain"], in: repo.path).contains("a.txt"), "the index is untouched")

        // The agent works on: changes, deletes and adds files.
        try write("a.txt", "drie")
        try FileManager.default.removeItem(at: repo.appendingPathComponent("new.txt"))
        try write("later.txt", "later")

        try git.restore(repo.path, to: ref)
        XCTAssertEqual(read("a.txt"), "twee")
        XCTAssertEqual(read("new.txt"), "nieuw", "a deleted file comes back")
        XCTAssertNil(read("later.txt"), "a file added since goes away")
        XCTAssertEqual(read("secret.txt"), "geheim", "ignored files are never touched")
        XCTAssertEqual(try git.run(["rev-parse", "HEAD"], in: repo.path), head)

        git.removeCheckpoints(repo.path, session: session)
        XCTAssertThrowsError(try git.run(["rev-parse", "--verify", "-q", ref], in: repo.path))
    }

    func testTurnLeavesOutWhatAPullBroughtIn() throws {
        // Upstream work, committed before the turn: a pull brings it in.
        let old = ["GIT_AUTHOR_DATE": "2020-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2020-01-01T00:00:00Z"]
        try git.run(["checkout", "-q", "-b", "upstream"], in: repo.path)
        try write("up.txt", "theirs\n")
        try write("a.txt", "een\nupstream\n")
        try git.git(["add", "-A"], in: repo.path, env: [:])
        try git.git(["commit", "-q", "-m", "upstream"], in: repo.path, env: old)
        try git.run(["checkout", "-q", "main"], in: repo.path)
        let origin = try git.run(["rev-parse", "HEAD"], in: repo.path).trimmingCharacters(in: .whitespacesAndNewlines)

        for initial in [false, true] {
            try git.run(["reset", "-q", "--hard", origin], in: repo.path)
            let started = Date()
            let before = GitService.checkpointRef(session: UUID(), index: 0)
            if initial { try git.checkpointHead(repo.path, ref: before) } else { try git.checkpoint(repo.path, ref: before) }
            XCTAssertNil(git.authoredPaths(repo.path, from: before, to: before, since: started), "HEAD did not move: every change counts")

            // The turn pulls, edits a pulled file, and commits a file of its own.
            try git.run(["merge", "-q", "--ff-only", "upstream"], in: repo.path)
            try write("a.txt", "een\nupstream\nmine\n")
            try write("mine.txt", "new\n")
            try git.git(["add", "mine.txt"], in: repo.path, env: [:])
            try git.git(["commit", "-q", "-m", "mine"], in: repo.path, env: [:])
            let after = GitService.checkpointRef(session: UUID(), index: 1)
            try git.checkpoint(repo.path, ref: after)

            let authored = try XCTUnwrap(git.authoredPaths(repo.path, from: before, to: after, since: started))
            XCTAssertEqual(authored, ["a.txt", "mine.txt"], "initial snapshot is HEAD: \(initial)")
            let turn = try git.lineCounts(repo.path, paths: nil, from: before, to: after, authored: authored)
            XCTAssertEqual(Set(turn.keys), ["a.txt", "mine.txt"], "the pulled up.txt is left out")
            XCTAssertEqual(Set(try git.lineCounts(repo.path, paths: nil, from: before, to: after).keys), ["a.txt", "mine.txt", "up.txt"])
        }
    }

    func testRestoreRemovesWhatAnIgnoreFileFromTheTurnHid() throws {
        try write("secret.txt", "geheim")
        let ref = GitService.checkpointRef(session: UUID(), index: 0)
        try git.checkpoint(repo.path, ref: ref)

        // The turn adds a .gitignore for dist/ and builds into it, and widens the root .gitignore over a file it wrote.
        let dist = repo.appendingPathComponent("web/dist/assets")
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        try write("web/.gitignore", "dist/\n")
        try write("web/dist/index.html", "<html>")
        try write("web/dist/assets/app.js", "js")
        try write(".gitignore", "secret.txt\n*.log\n")
        try write("build.log", "log")

        try git.restore(repo.path, to: ref)
        XCTAssertNil(read("web/.gitignore"), "the new ignore file goes")
        XCTAssertNil(read("web/dist/index.html"), "and so do the files it hid")
        XCTAssertNil(read("web/dist/assets/app.js"))
        XCTAssertNil(read("build.log"), "a file hidden by a changed ignore file goes too")
        XCTAssertEqual(read(".gitignore"), "secret.txt\n")
        XCTAssertEqual(read("secret.txt"), "geheim", "what the snapshot's own rules ignore is never touched")
        XCTAssertEqual(read("a.txt"), "een")
    }

    func testCheckpointWithoutCommits() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("nook-cp-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        try git.run(["init", "-q"], in: empty.path)
        try "x".write(to: empty.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(try git.checkpoint(empty.path, ref: "refs/nook/checkpoints/t/0").isEmpty)
    }

    func testCheckpointPreservesStagedAndUnstagedIndexState() throws {
        try write("staged.txt", "staged")
        try git.run(["add", "staged.txt"], in: repo.path)
        try write("a.txt", "unstaged")
        let statusBefore = try git.run(["status", "--porcelain"], in: repo.path)

        let ref = GitService.checkpointRef(session: UUID(), index: 0)
        try git.checkpoint(repo.path, ref: ref)

        let statusAfter = try git.run(["status", "--porcelain"], in: repo.path)
        XCTAssertEqual(statusAfter, statusBefore, "seeding from the checkout index never alters staged or unstaged entries")
        XCTAssertEqual(try git.run(["show", "\(ref):staged.txt"], in: repo.path), "staged")
        XCTAssertEqual(try git.run(["show", "\(ref):a.txt"], in: repo.path), "unstaged")
    }

    func testCheckpointSeesFilesTheCheckoutMarksUnchanged() throws {
        try write("local.cfg", "committed")
        try git.run(["add", "-A"], in: repo.path)
        try git.run(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-q", "-m", "cfg"], in: repo.path)
        try git.run(["update-index", "--assume-unchanged", "a.txt"], in: repo.path)
        try git.run(["update-index", "--skip-worktree", "local.cfg"], in: repo.path)
        // Same length as before, so only reading the file again shows the change.
        try write("a.txt", "twe")
        try write("local.cfg", "my own setting")

        let ref = GitService.checkpointRef(session: UUID(), index: 0)
        try git.checkpoint(repo.path, ref: ref)

        XCTAssertEqual(try git.run(["show", "\(ref):a.txt"], in: repo.path), "twe", "an assume-unchanged file is read")
        XCTAssertEqual(try git.run(["show", "\(ref):local.cfg"], in: repo.path), "my own setting", "a skip-worktree file is read")
        let flags = try git.run(["ls-files", "-v"], in: repo.path)
        XCTAssertTrue(flags.contains("h a.txt"), "the checkout's own index keeps its flags")
        XCTAssertTrue(flags.contains("S local.cfg"))

        // Going back keeps the local setting instead of writing the committed one over it.
        try write("local.cfg", "changed by the agent")
        try git.restore(repo.path, to: ref)
        XCTAssertEqual(read("local.cfg"), "my own setting")
    }

    func testFlaggedEntriesFromTheListing() {
        let listing = [
            "H 100644 aaa 0\tplain.txt",
            "h 100644 bbb 0\tassumed file.txt",
            "S 100644 ccc 0\tlocal.cfg",
            "S 100644 ddd 0\toutside/cone.txt",
            "s 100755 eee 0\tgone.sh",
            "h 160000 fff 0\tvendor/sub",
            "M 100644 ggg 1\tconflict.txt",
        ].joined(separator: "\0") + "\0"
        let entries = GitService.flaggedEntries(listing) { $0 != "outside/cone.txt" && $0 != "gone.sh" }
        XCTAssertEqual(entries, [
            GitService.FlaggedEntry(mode: "100644", object: "bbb", path: "assumed file.txt"),
            GitService.FlaggedEntry(mode: "100644", object: "ccc", path: "local.cfg"),
        ])
    }
}

extension GitCheckpointTests {
    /// A file as it is in a commit, byte for byte (through `ProcessRunner`, with its deadline), and nothing for a missing one.
    func testExportFileWritesTheBlobBytes() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x0A, 0x80])
        try bytes.write(to: repo.appendingPathComponent("image.png"))
        try git.run(["add", "-A"], in: repo.path)
        try git.run(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-q", "-m", "image"], in: repo.path)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("image.png"))
        let destination = repo.appendingPathComponent("out/nested/image.png")
        XCTAssertTrue(git.exportFile(repo: repo.path, ref: "HEAD", path: "image.png", to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        let missing = repo.appendingPathComponent("out/missing.txt")
        XCTAssertFalse(git.exportFile(repo: repo.path, ref: "HEAD", path: "missing.txt", to: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}
