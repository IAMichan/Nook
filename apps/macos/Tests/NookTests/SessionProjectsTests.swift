import XCTest

final class SessionProjectsTests: XCTestCase {
    typealias P = SessionProjects

    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("session-projects-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func repo(_ name: String) throws -> String {
        let url = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("src"), withIntermediateDirectories: true)
        return url.path
    }

    /// A linked worktree of `repo`: its `.git` is a file pointing into the repository's `.git/worktrees`.
    private func worktree(of repo: String, _ name: String) throws -> String {
        let url = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "gitdir: \(repo)/.git/worktrees/\(name)\n".write(to: url.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        return url.path
    }

    func testFileInAnotherRepositoryAddsThatProject() throws {
        let nook = try repo("nook")
        let mono = try repo("monorepo")
        let added = P.adding(file: mono + "/src/app.ts", own: nook, to: [])
        XCTAssertEqual(added, [mono])
        // Listed once.
        XCTAssertNil(P.adding(file: mono + "/README.md", own: nook, to: [mono]))
    }

    func testOwnProjectAndFilesOutsideRepositoriesAddNothing() throws {
        let nook = try repo("nook")
        XCTAssertNil(P.adding(file: nook + "/src/a.swift", own: nook, to: []))
        let loose = base.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        XCTAssertNil(P.adding(file: loose.path + "/todo.md", own: nook, to: []))
        XCTAssertNil(P.adding(file: "relative/file.swift", own: nook, to: []))
    }

    func testWorktreeIsItsRepositorysProject() throws {
        let nook = try repo("nook")
        let tree = try worktree(of: nook, "nook-feature")
        XCTAssertEqual(P.root(of: tree + "/src"), nook)
        // A worktree session that edits its repository's main checkout stays in one project.
        XCTAssertNil(P.adding(file: nook + "/src/a.swift", own: tree, to: []))
        let mono = try repo("monorepo")
        XCTAssertEqual(P.adding(file: mono + "/src/b.ts", own: tree, to: []), [mono])
    }

    func testWrittenFilesFromHookInput() {
        XCTAssertEqual(P.writtenFiles(tool: "Edit", input: ["file_path": "/a/b.swift"], cwd: "/x"), ["/a/b.swift"])
        XCTAssertEqual(P.writtenFiles(tool: "write_file", input: ["file_path": "c.txt"], cwd: "/x"), ["/x/c.txt"])
        XCTAssertEqual(P.writtenFiles(tool: "Read", input: ["file_path": "/a/b.swift"], cwd: "/x"), [])
        let patch = "*** Begin Patch\n*** Update File: /m/src/a.ts\n@@\n-a\n+b\n*** Add File: ../other/new.md\n+hi\n*** End Patch"
        XCTAssertEqual(P.writtenFiles(tool: "apply_patch", input: ["input": patch], cwd: "/x/y"),
                       ["/m/src/a.ts", "/x/other/new.md"])
    }

    func testLabelAndNames() {
        XCTAssertEqual(P.label(own: "Nook", others: []), "Nook")
        XCTAssertEqual(P.label(own: "Nook", others: ["monorepo"]), "Nook + monorepo")
        XCTAssertEqual(P.label(own: "Nook", others: ["monorepo", "site", "docs"]), "Nook + monorepo +2")
        XCTAssertEqual(P.label(own: "Nook", others: ["monorepo", "site"], shown: 2), "Nook + monorepo + site")
        XCTAssertEqual(P.names(["/a/monorepo", "/b/nook", "/c/monorepo"], own: "nook") { ($0 as NSString).lastPathComponent },
                       ["monorepo"])
    }
}
