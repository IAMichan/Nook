import XCTest

/// The rules for worktrees that remove themselves, and one operation at a time per folder.
final class WorktreeCleanupRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let both = WorktreeCleanup.Rules(onMergedPullRequest: true, daysAfterSettled: 7)

    private func facts(merged: Bool = false, settled: Bool = false, quietDays: Double = 0, changes: Int? = 0) -> WorktreeCleanup.Facts {
        WorktreeCleanup.Facts(worktree: "/tmp/wt/feature", repoRoot: "/tmp/repo", otherFolders: ["/tmp/repo", "/tmp/wt/other"],
                              pullRequestMerged: merged, settled: settled, lastActivity: now.addingTimeInterval(-quietDays * 86_400),
                              uncommittedFiles: changes)
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
