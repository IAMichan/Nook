import XCTest

/// The rules for worktrees that remove themselves, and one operation at a time per folder.
final class WorktreeCleanupRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let both = WorktreeCleanup.Rules(onMergedPullRequest: true, daysAfterSettled: 7)

    private func facts(merged: Bool = false, settled: Bool = false, quietDays: Double = 0, changes: Int? = 0,
                       unpushed: Int? = 0, ahead: Int? = 3, branch: String? = "nook/feature") -> WorktreeCleanup.Facts {
        WorktreeCleanup.Facts(worktree: "/tmp/wt/feature", repoRoot: "/tmp/repo", otherFolders: ["/tmp/repo", "/tmp/wt/other"],
                              pullRequestMerged: merged, settled: settled, lastActivity: now.addingTimeInterval(-quietDays * 86_400),
                              branch: "nook/feature",
                              git: changes.map { WorktreeCleanup.GitFacts(localChanges: $0, unpushedCommits: unpushed, aheadOfBase: ahead, branch: branch) })
    }

    func testOffByDefault() {
        XCTAssertFalse(WorktreeCleanup.Rules().isEnabled)
        XCTAssertEqual(WorktreeCleanup.decide(facts(merged: true), rules: WorktreeCleanup.Rules(), now: now), .keep(.disabled))
    }

    func testMergedPullRequestRemoves() {
        XCTAssertEqual(WorktreeCleanup.decide(facts(merged: true), rules: both, now: now), .remove(.mergedPullRequest))
        let daysOnly = WorktreeCleanup.Rules(onMergedPullRequest: false, daysAfterSettled: 7)
        XCTAssertEqual(WorktreeCleanup.decide(facts(merged: true), rules: daysOnly, now: now), .keep(.notDue))
    }

    func testSettledForLongEnoughRemoves() {
        XCTAssertEqual(WorktreeCleanup.decide(facts(settled: true, quietDays: 8), rules: both, now: now), .remove(.settled))
        XCTAssertEqual(WorktreeCleanup.decide(facts(settled: true, quietDays: 2), rules: both, now: now), .keep(.notDue))
        XCTAssertEqual(WorktreeCleanup.decide(facts(settled: false, quietDays: 30), rules: both, now: now), .keep(.notDue),
                       "quiet but not settled")
    }

    func testNeverRemovesWhatIsInUseSharedOrDirty() {
        XCTAssertEqual(WorktreeCleanup.decide(facts(merged: true, changes: 2), rules: both, now: now), .keep(.uncommittedChanges))
        XCTAssertEqual(WorktreeCleanup.decide(facts(merged: true, changes: nil), rules: both, now: now), .keep(.unknownChanges),
                       "git has not been asked yet")
        var active = facts(merged: true)
        active.active = true
        XCTAssertEqual(WorktreeCleanup.decide(active, rules: both, now: now), .keep(.active))
        var shared = facts(merged: true)
        shared.otherFolders.append("/tmp/wt/feature/app")
        XCTAssertEqual(WorktreeCleanup.decide(shared, rules: both, now: now), .keep(.shared))
        var main = facts(merged: true)
        main.repoRoot = "/tmp/wt/feature"
        XCTAssertEqual(WorktreeCleanup.decide(main, rules: both, now: now), .keep(.mainCheckout))
        var remote = facts(merged: true)
        remote.isRemote = true
        XCTAssertEqual(WorktreeCleanup.decide(remote, rules: both, now: now), .keep(.remote))
        var none = facts(merged: true)
        none.worktree = nil
        XCTAssertEqual(WorktreeCleanup.decide(none, rules: both, now: now), .keep(.noWorktree))
    }

    func testQuietSessionsGoAfterTheirDays() {
        let inactive = WorktreeCleanup.Rules(daysInactive: 7)
        XCTAssertEqual(WorktreeCleanup.decide(facts(quietDays: 8), rules: inactive, now: now), .remove(.inactive),
                       "settled or not")
        XCTAssertEqual(WorktreeCleanup.decide(facts(quietDays: 3), rules: inactive, now: now), .keep(.notDue))
    }

    func testAWorktreeWithNothingBeyondItsBaseGoes() {
        let unchanged = WorktreeCleanup.Rules(onUnchanged: true)
        XCTAssertEqual(WorktreeCleanup.decide(facts(changes: nil), rules: unchanged, now: now), .keep(.unknownChanges),
                       "only git can tell")
        XCTAssertEqual(WorktreeCleanup.decide(facts(ahead: 0), rules: unchanged, now: now), .remove(.unchanged))
        XCTAssertEqual(WorktreeCleanup.decide(facts(ahead: 2), rules: unchanged, now: now), .keep(.notDue))
        XCTAssertEqual(WorktreeCleanup.decide(facts(ahead: nil), rules: unchanged, now: now), .keep(.notDue), "no base, no verdict")
        XCTAssertEqual(WorktreeCleanup.decide(facts(changes: 1, ahead: 0), rules: unchanged, now: now), .keep(.uncommittedChanges))
    }

    func testAMergeDoesNotCoverCommitsMadeAfterIt() {
        XCTAssertEqual(WorktreeCleanup.decide(facts(merged: true, unpushed: 2), rules: both, now: now), .keep(.unpushedCommits))
        XCTAssertEqual(WorktreeCleanup.decide(facts(merged: true, settled: true, quietDays: 8, unpushed: 2), rules: both, now: now),
                       .remove(.settled), "another rule still applies; the branch keeps the commits")
        XCTAssertEqual(WorktreeCleanup.decide(facts(merged: true, unpushed: nil), rules: both, now: now), .remove(.mergedPullRequest))
    }

    func testAnOpenTerminalASymlinkOrAnotherBranchKeepsIt() {
        var terminal = facts(merged: true)
        terminal.openTerminal = true
        XCTAssertEqual(WorktreeCleanup.decide(terminal, rules: both, now: now), .keep(.openTerminal))
        var link = facts(merged: true)
        link.isSymlink = true
        XCTAssertEqual(WorktreeCleanup.decide(link, rules: both, now: now), .keep(.symlink))
        XCTAssertEqual(WorktreeCleanup.decide(facts(merged: true, branch: "main"), rules: both, now: now), .keep(.branchChanged))
        XCTAssertEqual(WorktreeCleanup.decide(facts(merged: true, branch: nil), rules: both, now: now), .remove(.mergedPullRequest),
                       "a detached HEAD is not another branch")
    }

    func testAGuardIsReportedOnlyWhenARuleApplied() {
        var active = facts()
        active.active = true
        XCTAssertEqual(WorktreeCleanup.decide(active, rules: both, now: now), .keep(.notDue))
        XCTAssertTrue(WorktreeCleanup.KeepReason.notDue.isQuiet)
        XCTAssertFalse(WorktreeCleanup.KeepReason.openTerminal.isQuiet)
    }

    func testDeletingTheLastSessionRemovesOnlyWhenAskedFor() {
        let rules = WorktreeCleanup.Rules(onDeletedSession: true)
        XCTAssertFalse(rules.isEnabled, "it acts on delete, not on the sweep")
        XCTAssertEqual(WorktreeCleanup.decideAfterDelete(facts(), rules: rules), .remove(.deletedSession))
        XCTAssertEqual(WorktreeCleanup.decideAfterDelete(facts(), rules: WorktreeCleanup.Rules()), .keep(.disabled))
        XCTAssertEqual(WorktreeCleanup.decideAfterDelete(facts(changes: 3), rules: rules), .keep(.uncommittedChanges))
        var terminal = facts()
        terminal.openTerminal = true
        XCTAssertEqual(WorktreeCleanup.decideAfterDelete(terminal, rules: rules), .keep(.openTerminal))
    }

    func testUnusedFoldersAreOnlyThoseNoSessionUsesAfterAnHour() {
        let old = now.addingTimeInterval(-2 * 3600)
        let candidates = [("/tmp/wt/repo/a", old), ("/tmp/wt/repo/b", old), ("/tmp/wt/repo/c", now.addingTimeInterval(-60)),
                          ("/tmp/wt/repo/d", old)].map { (path: $0.0, modified: $0.1) }
        let unused = WorktreeCleanup.orphans(candidates: candidates, used: ["/tmp/wt/repo/a", "/tmp/wt/repo/d/app"], now: now)
        XCTAssertEqual(unused, ["/tmp/wt/repo/b"])
    }

    func testLeaseKeys() {
        XCTAssertEqual(FolderLease.key("/tmp/wt/feature/"), FolderLease.key("/tmp/wt/feature"))
        XCTAssertNotEqual(FolderLease.key("/tmp/wt/feature", machine: "box"), FolderLease.key("/tmp/wt/feature"))
    }

    func testOperationsOnOneFolderNeverOverlap() async throws {
        let lease = FolderLease()
        let log = Log()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                group.addTask {
                    try await lease.run("/tmp/wt/feature") {
                        log.add("start \(index)")
                        Thread.sleep(forTimeInterval: 0.005)
                        log.add("end \(index)")
                    }
                }
            }
            try await group.waitForAll()
        }
        let entries = log.entries
        XCTAssertEqual(entries.count, 12)
        for pair in stride(from: 0, to: entries.count, by: 2) {
            let index = entries[pair].dropFirst("start ".count)
            XCTAssertEqual(entries[pair + 1], "end \(index)", "an operation started before the previous one ended: \(entries)")
        }
        let busy = await lease.busyKeys
        XCTAssertTrue(busy.isEmpty, "a finished folder leaves nothing behind")
    }

    func testOtherFoldersDoNotWait() async throws {
        let lease = FolderLease()
        let gate = DispatchSemaphore(value: 0)
        // The first operation waits until the second, on another folder, has run: serialized globally this would time out.
        async let first: Bool = lease.run("/tmp/a") { gate.wait(timeout: .now() + 5) == .success }
        try await Task.sleep(nanoseconds: 1_000_000)
        try await lease.run("/tmp/b") { gate.signal() }
        let waited = try await first
        XCTAssertTrue(waited)
    }

    func testAFailureDoesNotBlockTheNext() async {
        let lease = FolderLease()
        struct Failure: Error {}
        do {
            try await lease.run("/tmp/x") { throw Failure() }
            XCTFail("the error comes through")
        } catch {}
        let value = try? await lease.run("/tmp/x") { 42 }
        XCTAssertEqual(value, 42)
    }
}

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ entry: String) { lock.withLock { list.append(entry) } }
    var entries: [String] { lock.withLock { list } }
}

/// How a session whose worktree is gone gets one back when you write to it again.
final class WorktreeReopenTests: XCTestCase {
    private func plan(branch: String? = "nook/feature", exists: Bool = true, onRemote: Bool = false, merged: Bool = false,
                      base: String? = "origin/main") -> WorktreeCleanup.Reopen {
        WorktreeCleanup.reopen(branch: branch, branchExists: exists, remoteBranchExists: onRemote, merged: merged, base: base,
                               newBranch: "nook/next")
    }

    func testABranchGoneHereComesBackFromTheRemote() {
        XCTAssertEqual(plan(exists: false, onRemote: true), .remoteBranch("nook/feature"))
        XCTAssertEqual(plan(exists: false, onRemote: true, merged: true), .newBranch("nook/next", base: "origin/main"))
    }

    func testUnfinishedWorkComesBackOnItsOwnBranch() {
        XCTAssertEqual(plan(), .branch("nook/feature"))
    }

    func testMergedWorkStartsANewBranchFromTheBase() {
        XCTAssertEqual(plan(merged: true), .newBranch("nook/next", base: "origin/main"))
        XCTAssertEqual(plan(exists: false), .newBranch("nook/next", base: "origin/main"), "a deleted branch starts over too")
    }

    func testWithoutBaseTheOldBranchIsTheOnlyWayBack() {
        XCTAssertEqual(plan(merged: true, base: nil), .branch("nook/feature"))
        XCTAssertEqual(plan(exists: false, base: nil), .impossible)
    }
}
