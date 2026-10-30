import XCTest

final class BuildLeftoversTests: XCTestCase {
    private var base: URL!
    private var roots: BuildLeftovers.Roots!
    private let now = Date()
    private let manager = FileManager.default

    override func setUpWithError() throws {
        base = manager.temporaryDirectory.appendingPathComponent("build-leftovers-\(UUID().uuidString)")
        roots = BuildLeftovers.Roots(temporary: [base.appendingPathComponent("tmp")],
                                     scratchpadParents: [base.appendingPathComponent("claude")],
                                     derivedData: base.appendingPathComponent("DerivedData"))
        for folder in roots.temporary + roots.scratchpadParents + [roots.derivedData] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: base)
    }

    /// A folder with a `Build` subfolder and, when `workspace` is set, Xcode's `info.plist`; `age` back-dates all of it.
    @discardableResult
    private func make(_ folder: URL, workspace: String? = nil, age: TimeInterval) throws -> URL {
        let build = folder.appendingPathComponent("Build")
        try manager.createDirectory(at: build, withIntermediateDirectories: true)
        if let workspace {
            let plist = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": workspace], format: .xml, options: 0)
            try plist.write(to: folder.appendingPathComponent("info.plist"))
        }
        let date = now.addingTimeInterval(-age)
        for path in [build.path, folder.appendingPathComponent("info.plist").path, folder.path] where manager.fileExists(atPath: path) {
            try manager.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }
        return folder
    }

    private let old: TimeInterval = 3 * 86_400

    func testFindsStaleTestPackagesAndXcodeBuildsInTemporaryFolders() throws {
        let tmp = roots.temporary[0]
        let tests = try make(tmp.appendingPathComponent("nook-core-tests.abc"), age: old)
        let build = try make(tmp.appendingPathComponent("nook-dd-feature"), workspace: "/x/Nook.xcodeproj", age: old)
        try make(tmp.appendingPathComponent("nook-core-tests.fresh"), age: 60)
        try make(tmp.appendingPathComponent("someone-else"), age: old)

        let found = BuildLeftovers.find(in: roots, now: now)

        XCTAssertEqual(Set(found.map(\.url.lastPathComponent)), [tests.lastPathComponent, build.lastPathComponent])
        XCTAssertEqual(found.first { $0.url.lastPathComponent == "nook-dd-feature" }?.kind, .xcodeBuild)
    }

    func testFindsXcodeBuildsInAgentScratchpads() throws {
        let scratchpad = roots.scratchpadParents[0].appendingPathComponent("project/session/scratchpad")
        try make(scratchpad.appendingPathComponent("dd"), workspace: "/x/Nook.xcodeproj", age: old)
        try make(scratchpad.appendingPathComponent("notes"), age: old)

        XCTAssertEqual(BuildLeftovers.find(in: roots, now: now).map(\.url.lastPathComponent), ["dd"])
    }

    func testFindsBuildsInAWorktreeScratchFolderButNotTheUsersFiles() throws {
        let worktree = base.appendingPathComponent("worktrees/feature")
        roots.worktrees = [worktree]
        let scratch = worktree.appendingPathComponent(".scratch")
        try make(scratch.appendingPathComponent("dd"), workspace: "/x/Nook.xcodeproj", age: old)
        let tests = try make(scratch.appendingPathComponent("coretests2"), age: old)
        try manager.createDirectory(at: tests.appendingPathComponent("Tests/CoreTests"), withIntermediateDirectories: true)
        try Data("// swift-tools-version:5.9".utf8).write(to: tests.appendingPathComponent("Package.swift"))
        for path in ["Package.swift", "Tests", ""] {
            try manager.setAttributes([.modificationDate: now.addingTimeInterval(-old)], ofItemAtPath: tests.appendingPathComponent(path).path)
        }
        try make(scratch.appendingPathComponent("nook-insta"), age: old)
        try make(scratch.appendingPathComponent("dd-fresh"), workspace: "/x/Nook.xcodeproj", age: 60)

        let found = BuildLeftovers.find(in: roots, now: now)

        XCTAssertEqual(Set(found.map(\.url.lastPathComponent)), ["dd", "coretests2"])
        XCTAssertEqual(found.first { $0.url.lastPathComponent == "coretests2" }?.kind, .testPackage)
    }

    func testFindsDerivedDataOfRemovedWorktreesOnly() throws {
        let gone = base.appendingPathComponent("worktrees/feature/apps/macos/Nook.xcodeproj").path
        let kept = base.appendingPathComponent("worktrees/live/apps/macos/Nook.xcodeproj").path
        try manager.createDirectory(atPath: kept, withIntermediateDirectories: true)
        try make(roots.derivedData.appendingPathComponent("Nook-gone"), workspace: gone, age: 60)
        try make(roots.derivedData.appendingPathComponent("Nook-live"), workspace: kept, age: old)
        try make(roots.derivedData.appendingPathComponent("Other-moved"), workspace: "/nowhere/Other.xcodeproj", age: old)

        let found = BuildLeftovers.find(in: roots, now: now)

        XCTAssertEqual(found.map(\.url.lastPathComponent), ["Nook-gone"])
        XCTAssertEqual(found.map(\.kind), [.orphanedDerivedData])
    }

    func testSweepRemovesWhatItFinds() throws {
        let tests = try make(roots.temporary[0].appendingPathComponent("nook-core-tests.abc"), age: old)
        try Data(count: 10_000).write(to: tests.appendingPathComponent("Build/product"))
        try manager.setAttributes([.modificationDate: now.addingTimeInterval(-old)], ofItemAtPath: tests.appendingPathComponent("Build").path)

        let removed = BuildLeftovers.sweep(roots, now: now)

        XCTAssertEqual(removed.map(\.leftover.kind), [.testPackage])
        XCTAssertFalse(manager.fileExists(atPath: tests.path))
    }
}
