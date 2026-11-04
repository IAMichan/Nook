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

    /// When Nook removes a session's worktree by itself (Settings › Workspace). All off by default: a worktree stays until
    /// you remove it, or a rule you switched on says it may go. The branch always stays, and a session whose worktree went
    /// gets it back with its next message (`reopen`).
    struct Rules: Equatable, Sendable {
        /// Once the session's pull request is merged (and nothing was committed in the worktree since).
        var onMergedPullRequest = false
        /// This many days after the session settled (you marked it finished, or archived it) and went quiet; 0 is off.
        var daysAfterSettled = 0
        /// This many days after anything last happened in the session, settled or not; 0 is off.
        var daysInactive = 0
        /// When the worktree has no commits beyond its base branch (and no local changes).
        var onUnchanged = false
        /// When the last session working in it is deleted (otherwise "Delete with worktree" asks).
        var onDeletedSession = false
        /// Which local files keep a worktree.
        var keepWhen: KeepWhen = .uncommittedChanges

        /// A rule that runs by itself, on the hourly sweep. `onDeletedSession` acts when a session is deleted.
        var isEnabled: Bool { onMergedPullRequest || daysAfterSettled > 0 || daysInactive > 0 || onUnchanged }
    }

    /// What counts as local changes that keep a worktree.
    enum KeepWhen: String, CaseIterable, Identifiable, Sendable {
        /// Edited tracked files and untracked files; ignored files (builds, `.env`) go with the worktree.
        case uncommittedChanges
        /// Also ignored files, other than `node_modules`.
        case anyLocalFiles
        /// Only edited tracked files; untracked and ignored files go with the worktree.
        case editedTrackedFiles

        var id: String { rawValue }

        /// Git's own removal refuses untracked files; with this choice they may go, so the removal is forced (after the
        /// count of edited tracked files said there are none).
        var forcesRemoval: Bool { self == .editedTrackedFiles }
    }

    /// What git said about a worktree, asked only once a rule applies.
    struct GitFacts: Equatable, Sendable {
        /// Local changes as `Rules.keepWhen` counts them.
        var localChanges: Int
        /// Commits on the worktree's HEAD that are on no remote; nil when git could not tell.
        var unpushedCommits: Int? = nil
        /// Commits beyond the base branch; nil without a base.
        var aheadOfBase: Int? = nil
        /// The branch checked out in the worktree; nil when detached.
        var branch: String? = nil
    }

    /// What Nook knows about a session's worktree when it looks.
    struct Facts: Equatable, Sendable {
        var worktree: String?
        var repoRoot: String?
        var isRemote = false
        /// A turn runs, or the agent's process is still there.
        var active = false
        /// A terminal in Nook is open in the worktree or below it.
        var openTerminal = false
        /// The worktree folder is a symbolic link: what it points to is not Nook's to remove.
        var isSymlink = false
        /// Every folder another session (running or not) works in.
        var otherFolders: [String] = []
        var pullRequestMerged = false
        var settled = false
        var lastActivity: Date
        /// The branch the session works on.
        var branch: String? = nil
        /// Nil: git has not been asked yet.
        var git: GitFacts? = nil
    }

    enum RemoveReason: String, Equatable, Sendable { case mergedPullRequest, settled, inactive, unchanged, deletedSession }

    enum KeepReason: String, Equatable, Sendable {
        case disabled, noWorktree, remote, mainCheckout, active, openTerminal, shared, symlink, branchChanged
        case uncommittedChanges, unpushedCommits, unknownChanges, notDue

        /// A reason that only says no rule applies; the others keep a worktree a rule would have removed.
        var isQuiet: Bool { [.disabled, .noWorktree, .remote, .mainCheckout, .notDue, .unknownChanges].contains(self) }
    }

    enum Decision: Equatable, Sendable {
        case remove(RemoveReason)
        case keep(KeepReason)
    }

    /// Never a worktree that is in use (a turn, the agent's process, a terminal), that another session shares, that is
    /// the main checkout or a symbolic link, whose branch was switched, or that has local changes. After a merge only
    /// while everything in it is on the remote. The branch stays either way: removing a worktree loses nothing that was
    /// committed. Without `git` the answer says only whether a rule applies (`.keep(.unknownChanges)` then means: ask
    /// git, and decide again with what it said).
    static func decide(_ facts: Facts, rules: Rules, now: Date) -> Decision {
        guard rules.isEnabled else { return .keep(.disabled) }
        guard let worktree = facts.worktree, !worktree.isEmpty else { return .keep(.noWorktree) }
        if facts.isRemote { return .keep(.remote) }
        if let repo = facts.repoRoot, WorkspacePathPolicy.normalize(repo) == WorkspacePathPolicy.normalize(worktree) {
            return .keep(.mainCheckout)
        }
        func quietFor(_ days: Int) -> Bool { facts.lastActivity <= now.addingTimeInterval(-Double(days) * 86_400) }
        // The rules that apply without asking git, in order; `unchanged` needs git's answer.
        var reasons: [RemoveReason] = []
        if rules.onMergedPullRequest, facts.pullRequestMerged { reasons.append(.mergedPullRequest) }
        if rules.daysAfterSettled > 0, facts.settled, quietFor(rules.daysAfterSettled) { reasons.append(.settled) }
        if rules.daysInactive > 0, quietFor(rules.daysInactive) { reasons.append(.inactive) }
        if rules.onUnchanged { reasons.append(.unchanged) }
        guard !reasons.isEmpty else { return .keep(.notDue) }
        if let keep = guardReason(facts, worktree: worktree) { return .keep(keep) }
        guard let git = facts.git else { return .keep(.unknownChanges) }
        return settle(reasons, git: git, branch: facts.branch)
    }

    /// The worktree of a session you deleted (`Rules.onDeletedSession`), under the same guards.
    static func decideAfterDelete(_ facts: Facts, rules: Rules) -> Decision {
        guard rules.onDeletedSession else { return .keep(.disabled) }
        guard let worktree = facts.worktree, !worktree.isEmpty else { return .keep(.noWorktree) }
        if facts.isRemote { return .keep(.remote) }
        if let repo = facts.repoRoot, WorkspacePathPolicy.normalize(repo) == WorkspacePathPolicy.normalize(worktree) {
            return .keep(.mainCheckout)
        }
        if let keep = guardReason(facts, worktree: worktree) { return .keep(keep) }
        guard let git = facts.git else { return .keep(.unknownChanges) }
        return settle([.deletedSession], git: git, branch: facts.branch)
    }

    private static func guardReason(_ facts: Facts, worktree: String) -> KeepReason? {
        if facts.active { return .active }
        if facts.openTerminal { return .openTerminal }
        if orphaned(worktree: worktree, otherFolders: facts.otherFolders) == nil { return .shared }
        if facts.isSymlink { return .symlink }
        return nil
    }

    private static func settle(_ reasons: [RemoveReason], git: GitFacts, branch: String?) -> Decision {
        // Someone checked out another branch in it: that work is not the session's to clean up.
        if let branch, let current = git.branch, branch != current { return .keep(.branchChanged) }
        guard git.localChanges == 0 else { return .keep(.uncommittedChanges) }
        var blocked: KeepReason?
        for reason in reasons {
            switch reason {
            case .mergedPullRequest:
                // Committed after the merge and not pushed: the merge does not cover it.
                if let unpushed = git.unpushedCommits, unpushed > 0 { blocked = blocked ?? .unpushedCommits; continue }
                return .remove(reason)
            case .unchanged:
                guard git.aheadOfBase == 0 else { continue }
                return .remove(reason)
            default:
                return .remove(reason)
            }
        }
        return .keep(blocked ?? .notDue)
    }

    // MARK: Orphans

    /// Folders in Nook's worktree folder (`<root>/<repo>/<name>`) that no session uses, touched longer ago than an hour
    /// (one being made right now is not an orphan yet). Only reported: cleanup never removes them.
    static let orphanGrace: TimeInterval = 60 * 60

    static func orphans(candidates: [(path: String, modified: Date)], used: [String], now: Date) -> [String] {
        let usedPaths = used.map(WorkspacePathPolicy.normalize)
        return candidates.filter { candidate in
            let path = WorkspacePathPolicy.normalize(candidate.path)
            let inUse = usedPaths.contains { $0 == path || $0.hasPrefix(path + "/") }
            return !inUse && now.timeIntervalSince(candidate.modified) >= orphanGrace
        }.map(\.path).sorted()
    }

    // MARK: Coming back

    /// How a session whose worktree is gone gets one back when you write to it again, at the same path so the agent's
    /// conversation carries on there.
    enum Reopen: Equatable, Sendable {
        /// Its own branch, checked out again: the work on it is not done yet.
        case branch(String)
        /// Its own branch, gone here but still on the remote: made again from `origin/<name>`.
        case remoteBranch(String)
        /// A new branch from the base: the old one landed (or is gone), so new work gets its own pull request.
        case newBranch(String, base: String)
        /// Neither its branch nor a base to start from.
        case impossible
    }

    static func reopen(branch: String?, branchExists: Bool, remoteBranchExists: Bool = false, merged: Bool, base: String?,
                       newBranch: String) -> Reopen {
        if let branch, branchExists, !merged { return .branch(branch) }
        if let branch, remoteBranchExists, !merged { return .remoteBranch(branch) }
        if let base, !base.isEmpty { return .newBranch(newBranch, base: base) }
        if let branch, branchExists { return .branch(branch) }
        return .impossible
    }
}

/// One operation at a time per folder: a checkpoint, a restore and the removal of the same worktree never overlap
/// (a workspace lease). Operations on different folders run side by side. The work itself runs off the actor.
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

/// What the latest cleanup did with each worktree a rule applied to (removed, kept and why, or failed), and the folders
/// in Nook's worktree folder no session uses. Shown in Settings › Workspace; kept across restarts.
struct WorktreeCleanupReport: Codable, Equatable, Sendable {
    enum Trigger: String, Codable, Sendable { case automatic, manual }
    enum Outcome: String, Codable, Sendable { case removed, kept, failed }

    struct Entry: Codable, Equatable, Sendable, Identifiable {
        var path: String
        var title: String?
        var outcome: Outcome
        /// A `WorktreeCleanup.RemoveReason` or `KeepReason` raw value; for a failure git's message.
        var reason: String
        var bytes: Int64?

        var id: String { path }
    }

    struct Orphan: Codable, Equatable, Sendable, Identifiable {
        var path: String
        var bytes: Int64?

        var id: String { path }
    }

    var trigger: Trigger
    var startedAt: Date
    var finishedAt: Date
    var entries: [Entry] = []
    var orphans: [Orphan] = []

    static let defaultsKey = "ws.worktreeCleanupReport"

    func count(_ outcome: Outcome) -> Int { entries.filter { $0.outcome == outcome }.count }

    var bytesFreed: Int64 { entries.filter { $0.outcome == .removed }.compactMap(\.bytes).reduce(0, +) }
}
