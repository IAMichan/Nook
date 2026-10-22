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

    func testCheckpointWithoutCommits() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("nook-cp-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        try git.run(["init", "-q"], in: empty.path)
        try "x".write(to: empty.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(try git.checkpoint(empty.path, ref: "refs/nook/checkpoints/t/0").isEmpty)
    }
}
