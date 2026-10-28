import Foundation

/// Single git action button: what it does depends on the state of the branch. Changes are committed (with a message an
/// agent writes), then pushed, then proposed as a pull request, as far as makes sense; a branch that is behind is
/// pulled; a diverged branch is left to you. Once the branch's pull request is merged or closed, new work goes to a new
/// branch with a pull request of its own, so one chat can open several.
enum GitQuickAction: Equatable, Sendable {
    case commit, commitPush, commitPushPR, push, pushPR, createPR, pull
    /// A new branch (with the changes, committed there) for a new pull request.
    case branchCommitPushPR, branchPushPR

    var commits: Bool { self == .commit || self == .commitPush || self == .commitPushPR || self == .branchCommitPushPR }
    var pushes: Bool { self != .commit && self != .pull }
    var proposes: Bool { self == .commitPushPR || self == .pushPR || self == .createPR || startsBranch }
    var startsBranch: Bool { self == .branchCommitPushPR || self == .branchPushPR }

    /// The localization key of the button's label.
    var labelKey: String {
        switch self {
        case .commit: return "ws.quick.commit"
        case .commitPush: return "ws.quick.commitPush"
        case .commitPushPR: return "ws.quick.commitPushPR"
        case .push: return "ws.quick.push"
        case .pushPR: return "ws.quick.pushPR"
        case .createPR: return "ws.quick.createPR"
        case .pull: return "ws.quick.pull"
        case .branchCommitPushPR, .branchPushPR: return "ws.quick.newBranchPR"
        }
    }

    /// The localization key of what the toast says once the action is done.
    var doneKey: String {
        switch self {
        case .commit: return "ws.quick.done.commit"
        case .commitPush, .push: return "ws.quick.done.push"
        case .commitPushPR, .pushPR, .createPR: return "ws.quick.done.pr"
        case .branchCommitPushPR, .branchPushPR: return "ws.quick.done.newBranchPR"
        case .pull: return "ws.quick.done.pull"
        }
    }
}

/// What the button needs to know about the branch.
struct GitQuickState: Equatable, Sendable {
    var hasChanges: Bool
    var branch: String?
    var isDefaultBranch: Bool
    var hasUpstream: Bool
    var hasRemote: Bool
    var ahead: Int
    var behind: Int
    /// Commits on this branch that the base branch does not have (for a branch that was never pushed).
    var aheadOfBase: Int
    var hasOpenPullRequest: Bool
    /// The branch had a pull request that is merged or closed (and none is open): its work is done.
    var pullRequestLanded = false
}

enum GitQuickResolver {
    /// The action, or the localization key of why there is nothing to do.
    static func resolve(_ state: GitQuickState) -> Result<GitQuickAction, Reason> {
        guard state.branch != nil else { return .failure(Reason("ws.quick.detached")) }
        let finished = state.hasOpenPullRequest || state.isDefaultBranch
        let landed = landed(state)
        if state.hasChanges {
            if !state.hasRemote { return .success(.commit) }
            if landed { return .success(.branchCommitPushPR) }
            return .success(finished ? .commitPush : .commitPushPR)
        }
        if state.ahead > 0 && state.behind > 0 { return .failure(Reason("ws.quick.diverged")) }
        if state.behind > 0 { return .success(.pull) }
        if !state.hasRemote { return .failure(Reason("ws.quick.noRemote")) }
        if landed && state.ahead > 0 { return .success(.branchPushPR) }
        if state.ahead > 0 || (!state.hasUpstream && state.aheadOfBase > 0) {
            return .success(finished ? .push : .pushPR)
        }
        if !state.hasUpstream { return .failure(Reason("ws.quick.nothingToPush")) }
        // A merged branch is still ahead of the base after a squash: proposing it again would repeat the merged work.
        if landed { return .failure(Reason("ws.quick.landed")) }
        if !finished && state.aheadOfBase > 0 { return .success(.createPR) }
        return .failure(Reason("ws.quick.upToDate"))
    }

    /// The other way to go, offered beside the main action: changes next to an open pull request (or on the default
    /// branch) can start a new branch and pull request of their own instead.
    static func alternatives(_ state: GitQuickState) -> [GitQuickAction] {
        guard state.branch != nil, state.hasChanges, state.hasRemote, !landed(state),
              state.hasOpenPullRequest || state.isDefaultBranch else { return [] }
        return [.branchCommitPushPR]
    }

    /// The localization key of the line under the action that says where its work goes, when that is not obvious.
    static func destinationKey(_ state: GitQuickState, action: GitQuickAction) -> String? {
        if action.startsBranch { return landed(state) ? "ws.quick.landedNewBranch" : "ws.quick.newBranchHint" }
        if state.hasOpenPullRequest && !state.isDefaultBranch && action.pushes { return "ws.quick.addsToPR" }
        return nil
    }

    private static func landed(_ state: GitQuickState) -> Bool {
        state.pullRequestLanded && !state.hasOpenPullRequest && !state.isDefaultBranch
    }

    struct Reason: Error, Equatable { let key: String; init(_ key: String) { self.key = key } }
}

/// Git work behind the button. Synchronous, like the rest of GitService: call off the main thread.
extension GitService {
    /// Staged-as-if-everything context for a commit message, from a temporary index so your own staging stays put.
    func commitContext(_ directory: String) throws -> (files: String, patch: String) {
        try withTemporaryIndex(directory) { env in
            if let head = try? git(["rev-parse", "--verify", "-q", "HEAD"], in: directory, env: env), !head.isEmpty {
                try git(["read-tree", "HEAD"], in: directory, env: env)
            }
            try git(["add", "-A", "--", "."], in: directory, env: env)
            let files = try git(["diff", "--cached", "--name-status"], in: directory, env: env)
            let patch = try git(["diff", "--no-ext-diff", "--cached", "--patch", "--minimal"], in: directory, env: env)
            return (String(files.prefix(8_000)), String(patch.prefix(50_000)))
        }
    }

    /// `git add -A` and a commit with a subject and an optional body. Returns the short hash.
    func commitAll(_ directory: String, subject: String, body: String) throws -> String {
        try run(["add", "-A"], in: directory)
        var arguments = ["commit", "-m", subject]
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { arguments += ["-m", body] }
        try run(arguments, in: directory, timeout: 120)
        return try run(["rev-parse", "--short", "HEAD"], in: directory).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A new branch at HEAD, taking the uncommitted changes along. Returns where the branch it left was last pushed
    /// (`origin/feat`), the cut for `moveOntoBase`.
    func startBranch(_ directory: String, name: String, remote: String) throws -> String? {
        guard !name.isEmpty, !name.hasPrefix("-") else { throw GitError("Invalid branch name.") }
        let old = currentBranch(directory)
        try run(["switch", "-c", name], in: directory)
        guard let old, refExists("refs/remotes/\(remote)/\(old)", in: directory) else { return nil }
        return "\(remote)/\(old)"
    }

    /// Replays the commits made after `cut` onto the freshly fetched base, so a new pull request holds only the new work
    /// (a squash-merged branch would otherwise bring its merged commits again). A conflict leaves the branch as it was.
    /// Returns whether it moved.
    @discardableResult
    func moveOntoBase(_ directory: String, base: String, remote: String, cut: String) -> Bool {
        _ = try? run(["fetch", "--quiet", remote, base], in: directory, timeout: 60)
        let target = comparisonBase(directory, base: base, remote: remote)
        guard target != cut, (try? run(["merge-base", "--is-ancestor", cut, "HEAD"], in: directory)) != nil else { return false }
        do {
            try run(["rebase", "--quiet", "--onto", target, cut], in: directory, timeout: 120)
            return true
        } catch {
            _ = try? run(["rebase", "--abort"], in: directory)
            return false
        }
    }

    /// Fast-forward only: never a merge commit or a rebase behind your back.
    func pullFastForward(_ directory: String) throws {
        try run(["pull", "--ff-only"], in: directory, timeout: 300)
    }

    /// Commits on HEAD that `base` does not have; nil when the base is unknown.
    func commitsAhead(_ directory: String, of base: String) -> Int? {
        guard let text = try? run(["rev-list", "--count", base + "..HEAD"], in: directory) else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The repository's default branch for pull requests: what the remote's HEAD points at, else `main` or `master`
    /// when one exists. Never the current branch (`defaultBaseBranch` falls back to it), so a feature branch is never
    /// mistaken for the default one.
    func defaultBranch(_ directory: String, remote: String) -> String? {
        if let text = try? run(["symbolic-ref", "--quiet", "--short", "refs/remotes/\(remote)/HEAD"], in: directory) {
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix(remote + "/"), name.count > remote.count + 1 { return String(name.dropFirst(remote.count + 1)) }
        }
        return ["main", "master"].first { refExists("refs/heads/\($0)", in: directory) || refExists("refs/remotes/\(remote)/\($0)", in: directory) }
    }

    /// The base to compare against: the remote branch when there is one (`origin/main`), else the local one.
    func comparisonBase(_ directory: String, base: String, remote: String) -> String {
        refExists("refs/remotes/\(remote)/\(base)", in: directory) ? "\(remote)/\(base)" : base
    }

    /// Commits, diff stat and patch since `base`, for a pull request.
    func pullRequestContext(_ directory: String, base: String) throws -> (commits: String, stat: String, patch: String) {
        let commits = try run(["log", "--oneline", base + "..HEAD"], in: directory)
        let stat = try run(["diff", "--stat", base + "...HEAD"], in: directory)
        let patch = try run(["diff", "--no-ext-diff", "--patch", "--minimal", base + "...HEAD"], in: directory, timeout: 120)
        return (String(commits.prefix(20_000)), String(stat.prefix(20_000)), String(patch.prefix(60_000)))
    }

    /// The repository's pull request template, if it has one.
    static func pullRequestTemplate(_ root: String) -> String? {
        let candidates = [".github/pull_request_template.md", ".github/PULL_REQUEST_TEMPLATE.md", "PULL_REQUEST_TEMPLATE.md",
                          "pull_request_template.md", "docs/PULL_REQUEST_TEMPLATE.md", "docs/pull_request_template.md"]
        for name in candidates {
            if let text = try? String(contentsOfFile: (root as NSString).appendingPathComponent(name), encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }
}
