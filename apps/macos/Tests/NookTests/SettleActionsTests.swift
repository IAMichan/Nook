import XCTest

/// What settling a session does to its terminals and project scripts (`nook.json` `stopOnSettle` / `runOnSettle`).
final class SettleActionsTests: XCTestCase {
    private let folder = "/Users/me/.nook/worktrees/web/fix-login"
    private let dev = ProjectScript(id: "dev", name: "Dev", command: "pnpm dev", runOnWorktreeCreate: false, previewURL: nil,
                                    autoOpenPreview: false, stopOnSettle: true)
    private let clean = ProjectScript(id: "clean", name: "Clean", command: "rm -rf node_modules", runOnWorktreeCreate: false,
                                      previewURL: nil, autoOpenPreview: false, runOnSettle: true)
    private let watch = ProjectScript(id: "watch", name: "Watch", command: "pnpm watch", runOnWorktreeCreate: false,
                                      previewURL: nil, autoOpenPreview: false)

    private func terminal(_ origin: String, command: String? = nil, running: Bool = true, idle: Bool) -> SettleActions.Terminal {
        SettleActions.Terminal(id: UUID(), origin: origin, command: command, running: running, idleAtPrompt: idle)
    }

    func testParsesTheSettleKeys() {
        let json = #"{"scripts":[{"command":"pnpm dev","stopOnSettle":true},{"command":"make clean","runOnSettle":true},{"command":"x"}]}"#
        let scripts = ProjectScripts.parse(Data(json.utf8))
        XCTAssertEqual(scripts.map(\.stopOnSettle), [true, false, false])
        XCTAssertEqual(scripts.map(\.runOnSettle), [false, true, false])
    }

    func testIdleTerminalsCloseAndStopOnSettleScriptsStop() {
        let idle = terminal(folder + "/src", idle: true)
        let server = terminal(folder, command: "pnpm dev", idle: false)
        let byHand = terminal(folder, command: "pnpm watch", idle: false)
        let elsewhere = terminal("/Users/me/code/other", idle: true)
        let ended = terminal(folder, running: false, idle: false)
        let plan = SettleActions.plan(folder: folder, ownWorktree: true, terminals: [idle, server, byHand, elsewhere, ended],
                                      scripts: [dev, clean, watch], openFolders: [])
        XCTAssertEqual(plan.close, [idle.id])
        XCTAssertEqual(plan.stop, [server.id])
        XCTAssertEqual(plan.run.map(\.id), ["clean"])
    }

    func testAStopOnSettleScriptThatEndedClosesLikeAnyIdleTerminal() {
        let server = terminal(folder, command: "pnpm dev", idle: true)
        let plan = SettleActions.plan(folder: folder, ownWorktree: false, terminals: [server], scripts: [dev], openFolders: [])
        XCTAssertEqual(plan.close, [server.id])
        XCTAssertTrue(plan.stop.isEmpty)
    }

    func testCleanupOnlyRunsInAWorktreeOfItsOwn() {
        let plan = SettleActions.plan(folder: folder, ownWorktree: false, terminals: [], scripts: [clean], openFolders: [])
        XCTAssertTrue(plan.run.isEmpty, "the project's own checkout is shared with other work")
    }

    func testNothingHappensWhileAnotherSessionWorksThere() {
        let idle = terminal(folder, idle: true)
        for open in [folder, folder + "/", "/Users/me/.nook/worktrees/web", folder + "/packages/api"] {
            let plan = SettleActions.plan(folder: folder, ownWorktree: true, terminals: [idle], scripts: [dev, clean],
                                          openFolders: [open])
            XCTAssertTrue(plan.isEmpty, open)
        }
        let sibling = SettleActions.plan(folder: folder, ownWorktree: true, terminals: [idle], scripts: [],
                                         openFolders: [folder + "-2"])
        XCTAssertEqual(sibling.close, [idle.id], "a folder that only shares a prefix is not the same folder")
    }

    func testTheRootFolderIsNeverSettled() {
        let plan = SettleActions.plan(folder: "/", ownWorktree: true, terminals: [terminal("/tmp", idle: true)],
                                      scripts: [clean], openFolders: [])
        XCTAssertTrue(plan.isEmpty)
    }

    func testCleanupCommandExitsOnlyWhenItSucceeds() {
        XCTAssertEqual(SettleActions.cleanupCommand("make clean"), "make clean && exit 0")
    }

    // MARK: Process tree

    func testDescendantsWalksEveryLevelOnce() {
        let tree: [Int32: [Int32]] = [10: [11, 12], 11: [13], 12: [13, 14], 13: []]
        XCTAssertEqual(ProcessTree.descendants(of: 10, children: { tree[$0] ?? [] }), [11, 12, 13, 14])
        XCTAssertEqual(ProcessTree.descendants(of: 10, children: { tree[$0] ?? [] }, limit: 2).count, 2)
    }

    func testDescendsFollowsParents() {
        let parents: [Int32: Int32] = [40: 30, 30: 20, 20: 1]
        XCTAssertTrue(ProcessTree.descends(40, from: [20], parent: { parents[$0] }))
        XCTAssertFalse(ProcessTree.descends(40, from: [99], parent: { parents[$0] }))
        XCTAssertFalse(ProcessTree.descends(5, from: [20], parent: { $0 }), "a loop ends")
    }

    func testStopTargetSparesProtectedGroups() {
        XCTAssertEqual(ProcessTree.stopTarget(pid: 50, group: 50, protectedGroups: [7]), .group(50))
        XCTAssertEqual(ProcessTree.stopTarget(pid: 50, group: 7, protectedGroups: [7]), .process(50))
        XCTAssertEqual(ProcessTree.stopTarget(pid: 50, group: nil, protectedGroups: []), .process(50))
        XCTAssertEqual(ProcessTree.stopTarget(pid: 50, group: 1, protectedGroups: []), .process(50))
    }

    func testOnlyServersNookStartedCanBeStopped() {
        let parents: [Int32: Int32] = [300: 200, 200: 100, 400: 1]
        let roots = DevServerOwnership.Roots(processes: [100], groups: [77])
        XCTAssertTrue(DevServerOwnership.startedByNook(pid: 300, group: 300, roots: roots, parent: { parents[$0] }),
                      "below a terminal shell")
        XCTAssertTrue(DevServerOwnership.startedByNook(pid: 400, group: 77, roots: roots, parent: { parents[$0] }),
                      "an agent's group, also after launchd adopted it")
        XCTAssertFalse(DevServerOwnership.startedByNook(pid: 400, group: 400, roots: roots, parent: { parents[$0] }),
                       "started in another terminal app")
        XCTAssertFalse(DevServerOwnership.startedByNook(pid: 1, group: 77, roots: roots, parent: { parents[$0] }))
        XCTAssertEqual(DevServerOwnership.protectedGroups(roots).isSuperset(of: [100, 77]), true)
    }
}
