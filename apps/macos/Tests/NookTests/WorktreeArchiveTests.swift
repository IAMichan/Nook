import XCTest

final class WorktreeArchiveTests: XCTestCase {
    private var base: URL!
    private var worktree: URL!
    private var root: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        base = manager.temporaryDirectory.appendingPathComponent("worktree-archive-\(UUID().uuidString)")
        worktree = base.appendingPathComponent("repo-feature")
        root = base.appendingPathComponent("archive")
        try manager.createDirectory(at: worktree.appendingPathComponent(".scratch/preview"), withIntermediateDirectories: true)
        try Data("png".utf8).write(to: worktree.appendingPathComponent(".scratch/preview/popover.png"))
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: base)
    }

    func testScratchOutlivesItsWorktree() throws {
        XCTAssertTrue(WorktreeArchive.save(worktree: worktree.path, root: root))
        let file = worktree.appendingPathComponent(".scratch/preview/popover.png").path
        try manager.removeItem(at: worktree)

        let kept = try XCTUnwrap(WorktreeArchive.archived(file, worktree: worktree.path, root: root))
        XCTAssertEqual(try String(contentsOfFile: kept, encoding: .utf8), "png")
        XCTAssertNil(WorktreeArchive.archived(worktree.appendingPathComponent("other.png").path, worktree: worktree.path, root: root))
    }

    func testALinkByNameFindsTheRenderInScratch() throws {
        let found = try XCTUnwrap(WorktreeArchive.scratchFile(named: "popover.png", in: worktree.path))
        XCTAssertEqual(URL(fileURLWithPath: found).resolvingSymlinksInPath(),
                       worktree.appendingPathComponent(".scratch/preview/popover.png").resolvingSymlinksInPath())
        XCTAssertNil(WorktreeArchive.scratchFile(named: "missing.png", in: worktree.path))

        try manager.createDirectory(at: worktree.appendingPathComponent(".scratch/other"), withIntermediateDirectories: true)
        try Data().write(to: worktree.appendingPathComponent(".scratch/other/popover.png"))
        XCTAssertNil(WorktreeArchive.scratchFile(named: "popover.png", in: worktree.path), "two candidates: none is guessed")
    }

    func testAClonedRepositoryOrBuildInScratchIsNotKept() throws {
        let clone = worktree.appendingPathComponent(".scratch/t3code")
        try manager.createDirectory(at: clone.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("swift".utf8).write(to: clone.appendingPathComponent("main.swift"))
        try manager.createDirectory(at: worktree.appendingPathComponent(".scratch/web/node_modules/x"), withIntermediateDirectories: true)
        try Data("js".utf8).write(to: worktree.appendingPathComponent(".scratch/web/node_modules/x/index.js"))

        XCTAssertTrue(WorktreeArchive.save(worktree: worktree.path, root: root))
        XCTAssertNotNil(WorktreeArchive.archived(worktree.appendingPathComponent(".scratch/preview/popover.png").path,
                                                 worktree: worktree.path, root: root))
        XCTAssertNil(WorktreeArchive.archived(clone.appendingPathComponent("main.swift").path, worktree: worktree.path, root: root))
        XCTAssertNil(WorktreeArchive.archived(worktree.appendingPathComponent(".scratch/web/node_modules/x/index.js").path,
                                              worktree: worktree.path, root: root))
    }

    func testOldestArchivesGoWhenAllTogetherAreTooLarge() throws {
        let other = base.appendingPathComponent("repo-other")
        try manager.createDirectory(at: other.appendingPathComponent(".scratch"), withIntermediateDirectories: true)
        try Data(count: 64 * 1024).write(to: other.appendingPathComponent(".scratch/big.png"))
        try Data(count: 64 * 1024).write(to: worktree.appendingPathComponent(".scratch/preview/popover.png"))

        XCTAssertTrue(WorktreeArchive.save(worktree: worktree.path, root: root, now: Date(timeIntervalSinceNow: -60)))
        XCTAssertTrue(WorktreeArchive.save(worktree: other.path, root: root, maxTotalBytes: 100 * 1024))

        XCTAssertFalse(manager.fileExists(atPath: WorktreeArchive.location(worktree: worktree.path, root: root).path),
                       "the archive saved longest ago goes")
        XCTAssertTrue(manager.fileExists(atPath: WorktreeArchive.location(worktree: other.path, root: root).path),
                      "the one just saved stays")
    }

    func testATooLargeOrEmptyScratchIsNotKept() throws {
        XCTAssertFalse(WorktreeArchive.save(worktree: worktree.path, root: root, maxBytes: 1))
        XCTAssertFalse(WorktreeArchive.save(worktree: base.appendingPathComponent("none").path, root: root))
    }

    func testOnlyPathsInsideTheWorktreeAreMapped() {
        XCTAssertEqual(WorktreeArchive.relativePath("/a/wt/x/y.png", in: "/a/wt"), "x/y.png")
        XCTAssertNil(WorktreeArchive.relativePath("/a/wt2/y.png", in: "/a/wt"))
        XCTAssertNil(WorktreeArchive.relativePath("/a/wt", in: "/a/wt"))
        XCTAssertNotEqual(WorktreeArchive.location(worktree: "/a/one/wt", root: root),
                          WorktreeArchive.location(worktree: "/a/two/wt", root: root))
    }

    func testOldArchivesArePruned() throws {
        WorktreeArchive.save(worktree: worktree.path, root: root)
        let archive = WorktreeArchive.location(worktree: worktree.path, root: root)
        XCTAssertTrue(manager.fileExists(atPath: archive.path))
        WorktreeArchive.prune(root: root, now: Date().addingTimeInterval(WorktreeArchive.keepFor + 60))
        XCTAssertFalse(manager.fileExists(atPath: archive.path))
    }
}
