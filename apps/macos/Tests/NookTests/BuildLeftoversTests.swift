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

    /// `scripts/xcode.sh` builds into `<worktree>/.build/xcode`; a worktree that stays for weeks kept 3–5 GB there.
    func testFindsAStaleXcodeBuildInAWorktreeBuildFolder() throws {
        let stale = base.appendingPathComponent("worktrees/idle")
        let busy = base.appendingPathComponent("worktrees/busy")
        roots.worktrees = [stale, busy]
        try make(stale.appendingPathComponent(".build/xcode"), workspace: stale.path + "/apps/macos/Nook.xcodeproj", age: old)
        try make(stale.appendingPathComponent(".build/notes"), age: old)
        try make(busy.appendingPathComponent(".build/xcode"), workspace: busy.path + "/apps/macos/Nook.xcodeproj", age: 60)

        let found = BuildLeftovers.find(in: roots, now: now)

        // The temporary folder is under /var, a symlink to /private/var: compare resolved paths.
        XCTAssertEqual(found.map { $0.url.resolvingSymlinksInPath().path },
                       [stale.appendingPathComponent(".build/xcode").resolvingSymlinksInPath().path])
        XCTAssertEqual(found.map(\.kind), [.xcodeBuild])
    }

    /// A settled session's worktree loses its build after an hour; one still in use keeps it for two days.
    func testASettledWorktreeLosesItsBuildAfterAnHour() throws {
        let settled = base.appendingPathComponent("worktrees/merged")
        let open = base.appendingPathComponent("worktrees/open")
        roots.worktrees = [settled, open]
        roots.settledWorktrees = [settled]
        let twoHours: TimeInterval = 2 * 60 * 60
        try make(settled.appendingPathComponent(".build/xcode"), workspace: settled.path + "/apps/macos/Nook.xcodeproj", age: twoHours)
        try make(settled.appendingPathComponent(".build/fresh"), workspace: settled.path + "/apps/macos/Nook.xcodeproj", age: 60)
        try make(open.appendingPathComponent(".build/xcode"), workspace: open.path + "/apps/macos/Nook.xcodeproj", age: twoHours)

        let found = BuildLeftovers.find(in: roots, now: now)

        XCTAssertEqual(found.map { $0.url.resolvingSymlinksInPath().path },
                       [settled.appendingPathComponent(".build/xcode").resolvingSymlinksInPath().path])
    }

    func testRemovesDependenciesOnlyFromIdleWorktrees() throws {
        let idle = base.appendingPathComponent("worktrees/idle")
        let busy = base.appendingPathComponent("worktrees/busy")
        roots.worktrees = [idle, busy]
        roots.idleWorktrees = [idle]
        for folder in ["node_modules/react/node_modules", "packages/app/node_modules", "apps/web/src", ".git/node_modules"] {
            try manager.createDirectory(at: idle.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try manager.createDirectory(at: busy.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        // A link to a shared install is not the worktree's to remove.
        try manager.createSymbolicLink(at: idle.appendingPathComponent("apps/web/node_modules"), withDestinationURL: busy.appendingPathComponent("node_modules"))

        let found = BuildLeftovers.find(in: roots, now: now)

        // Listing a folder gives /private/var for the temporary folder's /var: compare resolved paths.
        let root = idle.resolvingSymlinksInPath().path + "/"
        XCTAssertEqual(Set(found.map { $0.url.resolvingSymlinksInPath().path.replacingOccurrences(of: root, with: "") }),
                       ["node_modules", "packages/app/node_modules"])
        XCTAssertEqual(Set(found.map(\.kind)), [.dependencies])
    }

    func testAWorktreeIsIdleUnlessSomethingWorksInIt() {
        let worktree = "/w/nook/feature"
        XCTAssertTrue(BuildLeftovers.isIdle(worktree, busy: ["/w/nook/other", "/Users/me"], mainCheckouts: []))
        XCTAssertFalse(BuildLeftovers.isIdle(worktree, busy: ["/w/nook/feature/"], mainCheckouts: []))
        XCTAssertFalse(BuildLeftovers.isIdle(worktree, busy: ["/w/nook/feature/apps/web"], mainCheckouts: []))
        XCTAssertFalse(BuildLeftovers.isIdle(worktree, busy: [], mainCheckouts: ["/w/nook/feature"]))
        XCTAssertTrue(BuildLeftovers.isIdle(worktree, busy: ["/w/nook/feature-2"], mainCheckouts: []))
    }

    /// The busy folders are resolved once for a whole sweep and give every worktree the same answer.
    func testHeldFoldersAnswerForEveryWorktreeAtOnce() {
        let held = BuildLeftovers.heldFolders(["/w/nook/a/apps/web", "/w/nook/a/apps/web", "/w/other/b", "/Users/me"])
        XCTAssertFalse(BuildLeftovers.isIdle("/w/nook/a", held: held, mainCheckouts: []))
        XCTAssertFalse(BuildLeftovers.isIdle("/w/other/b", held: held, mainCheckouts: []))
        XCTAssertTrue(BuildLeftovers.isIdle("/w/nook/c", held: held, mainCheckouts: []))
        XCTAssertTrue(BuildLeftovers.isIdle("/w/nook/a-2", held: held, mainCheckouts: []))
        // A folder above a worktree (your home folder) says nothing about it.
        XCTAssertTrue(BuildLeftovers.isIdle("/Users/me/project", held: held, mainCheckouts: []))
    }

    func testLowDiskSpaceWarnsOnceUntilItRecovered() {
        XCTAssertFalse(DiskSpace.isLow(available: 30_000_000_000, wasLow: false))
        XCTAssertTrue(DiskSpace.isLow(available: 20_000_000_000, wasLow: false))
        // Hovering around the limit stays one low period.
        XCTAssertTrue(DiskSpace.isLow(available: 30_000_000_000, wasLow: true))
        XCTAssertFalse(DiskSpace.isLow(available: 45_000_000_000, wasLow: true))
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
