import Foundation

/// The worktree a session leaves behind when you delete it: its own worktree, when no
/// other session works in it or below it. A session in your main checkout leaves nothing to remove.
enum WorktreeCleanup {
    static func orphaned(worktree: String?, otherFolders: [String]) -> String? {
        guard let worktree, !worktree.isEmpty else { return nil }
        let root = WorkspacePathPolicy.normalize(worktree)
        let shared = otherFolders.contains { folder in
            let other = WorkspacePathPolicy.normalize(folder)
            return other == root || other.hasPrefix(root + "/")
        }
        return shared ? nil : worktree
    }

    // MARK: Cleanup rules

    /// When Nook removes a session's worktree by itself (Settings › Workspace). Both off by default.
    struct Rules: Equatable, Sendable {
        /// Once the session's pull request is merged.
        var onMergedPullRequest = false
        /// This many days after the session settled (you marked it finished, or archived it) and went quiet; 0 is off.
        var daysAfterSettled = 0

        var isEnabled: Bool { onMergedPullRequest || daysAfterSettled > 0 }
    }

    /// What Nook knows about a session's worktree when it looks.
    struct Facts: Equatable, Sendable {
        var worktree: String?
        var repoRoot: String?
        var isRemote = false
        /// A turn runs, or the agent's process is still there.
        var active = false
        /// Every folder another session (running or not) works in.
        var otherFolders: [String] = []
        var pullRequestMerged = false
        var settled = false
        var lastActivity: Date
        /// Files changed and not committed (tracked or untracked); nil: not known yet (git has not been asked).
        var uncommittedFiles: Int? = nil
    }

    enum RemoveReason: String, Equatable, Sendable { case mergedPullRequest, settled }

    enum KeepReason: String, Equatable, Sendable {
        case disabled, noWorktree, remote, mainCheckout, active, shared, uncommittedChanges, unknownChanges, notDue
    }

    enum Decision: Equatable, Sendable {
        case remove(RemoveReason)
        case keep(KeepReason)
    }

    /// Never a worktree that is in use, that another session shares, that is the main checkout, or that has changes you
    /// did not commit. The branch stays either way: removing a worktree loses nothing that was committed.
    /// Without `uncommittedFiles` the answer says only whether a rule applies (`.keep(.unknownChanges)` then means: ask
    /// git, and decide again with the count).
    static func decide(_ facts: Facts, rules: Rules, now: Date) -> Decision {
        guard rules.isEnabled else { return .keep(.disabled) }
        guard let worktree = facts.worktree, !worktree.isEmpty else { return .keep(.noWorktree) }
        if facts.isRemote { return .keep(.remote) }
        if let repo = facts.repoRoot, WorkspacePathPolicy.normalize(repo) == WorkspacePathPolicy.normalize(worktree) {
            return .keep(.mainCheckout)
        }
        if facts.active { return .keep(.active) }
        if orphaned(worktree: worktree, otherFolders: facts.otherFolders) == nil { return .keep(.shared) }
        let reason: RemoveReason
        if rules.onMergedPullRequest, facts.pullRequestMerged {
            reason = .mergedPullRequest
        } else if rules.daysAfterSettled > 0, facts.settled,
                  facts.lastActivity <= now.addingTimeInterval(-Double(rules.daysAfterSettled) * 86_400) {
            reason = .settled
        } else {
            return .keep(.notDue)
        }
        guard let changes = facts.uncommittedFiles else { return .keep(.unknownChanges) }
        return changes == 0 ? .remove(reason) : .keep(.uncommittedChanges)
    }

    // MARK: Coming back

    /// How a session whose worktree is gone gets one back when you write to it again, at the same path so the agent's
    /// conversation carries on there.
    enum Reopen: Equatable, Sendable {
        /// Its own branch, checked out again: the work on it is not done yet.
        case branch(String)
        /// A new branch from the base: the old one landed (or is gone), so new work gets its own pull request.
        case newBranch(String, base: String)
        /// Neither its branch nor a base to start from.
        case impossible
    }

    static func reopen(branch: String?, branchExists: Bool, merged: Bool, base: String?, newBranch: String) -> Reopen {
        if let branch, branchExists, !merged { return .branch(branch) }
        if let base, !base.isEmpty { return .newBranch(newBranch, base: base) }
        if let branch, branchExists { return .branch(branch) }
        return .impossible
    }
}

/// One operation at a time per folder: a checkpoint, a restore and the removal of the same worktree never overlap
/// (workspace lease). Operations on different folders run side by side. The work itself runs off the actor.
actor FolderLease {
    static let shared = FolderLease()

    private var tails: [String: Task<Void, Never>] = [:]

    /// The key for a folder: the normalized path, prefixed with the machine for a session on another one.
    static func key(_ folder: String, machine: String? = nil) -> String {
        (machine.map { $0 + ":" } ?? "") + WorkspacePathPolicy.normalize(folder)
    }

    /// Runs `body` once every earlier operation on `key` has finished, in the order they were asked for.
    func run<T: Sendable>(_ key: String, priority: TaskPriority = .utility,
                          _ body: @escaping @Sendable () throws -> T) async throws -> T {
        let previous = tails[key]
        let work = Task<T, Error>.detached(priority: priority) {
            await previous?.value
            return try body()
        }
        let tail = Task<Void, Never> { _ = await work.result }
        tails[key] = tail
        let result = await work.result
        if tails[key] == tail { tails[key] = nil }
        return try result.get()
    }

    /// Folders with an operation running or waiting (for tests).
    var busyKeys: Set<String> { Set(tails.keys) }
}
