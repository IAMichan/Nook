import Foundation

/// The actions a pull request's row offers while you hold Shift: close and merge an open one, close a draft or mark it
/// ready for review, reopen a closed one. A merged one offers nothing. Each needs a second click before it is sent
/// (see `PullRequestQuickActionButtons`), and each is written to the action log. Foundation only, so tests can use it.
enum PullRequestQuickAction: String, CaseIterable, Identifiable, Sendable {
    case close, merge, ready, reopen

    var id: String { rawValue }

    static func actions(for item: PullRequestItem) -> [PullRequestQuickAction] {
        switch item.state {
        case .merged: return []
        case .closed: return [.reopen]
        case .open:
            if item.draft { return item.nodeID.isEmpty ? [.close] : [.close, .ready] }
            return [.close, .merge]
        }
    }

    /// The REST or GraphQL action behind it; nil for merge, which goes through the merge call with the head checked.
    func action(for item: PullRequestItem) -> PullRequestAction? {
        switch self {
        case .close: return .close
        case .reopen: return .reopen
        case .ready: return .markReady(nodeID: item.nodeID)
        case .merge: return nil
        }
    }

    /// Why the list already knows a pull request will not merge, as the `tr` key of `PullRequestQuickRunner.blocker`
    /// (takes its number); nil when it may. Failing checks do not hold it back: an admin may merge past them, as on the
    /// pull request's page, and GitHub refuses (or turns on auto-merge) for anyone else. The merge itself checks again
    /// against GitHub's answer.
    static func mergeBlocker(_ item: PullRequestItem) -> String? {
        switch item.state {
        case .merged: return "agents.pulls.quick.blocked.merged"
        case .closed: return "agents.pulls.quick.blocked.closed"
        case .open: break
        }
        if item.draft { return "agents.pulls.quick.blocked.draft" }
        if item.conflict { return "agents.pulls.quick.blocked.conflict" }
        return nil
    }

    /// The method a quick merge uses: the one you last picked on a pull request's page when the repository allows it,
    /// else the repository's own first choice.
    static func mergeMethod(preferred: PullRequestMergeMethod, allowed: [PullRequestMergeMethod]) -> PullRequestMergeMethod? {
        allowed.contains(preferred) ? preferred : PullRequestBatchMerge.method(requested: nil, allowed: allowed)
    }
}

/// What the menu beside a quick Merge offers (on a row while Shift is held, and in the selection bar): turn auto-merge
/// on or off, or merge now with a method of your choice instead of the one you last picked. The Merge button itself is
/// `.merge(nil)`: your usual method, and auto-merge when checks or reviews still hold it back. Foundation only, so tests
/// can use it.
enum PullRequestMergeChoice: Hashable, Sendable, Identifiable {
    /// Merge now; nil for the method you last picked on a pull request's page.
    case merge(PullRequestMergeMethod?)
    /// GitHub merges it by itself once checks and reviews pass, also for an admin who could merge past them now.
    case autoMerge
    /// Stops a merge waiting on auto-merge.
    case disableAutoMerge

    var id: String {
        switch self {
        case .merge(let method): return "merge." + (method?.rawValue ?? "default")
        case .autoMerge: return "autoMerge"
        case .disableAutoMerge: return "disableAutoMerge"
        }
    }

    /// The menu, in its order: auto-merge first (the reason the menu is there), then merging now by each method.
    static let menu: [PullRequestMergeChoice] = [.autoMerge, .disableAutoMerge]
        + PullRequestMergeMethod.allCases.map { .merge($0) }

    /// The `tr` key of its name in the menu.
    var titleKey: String {
        switch self {
        case .merge(let method): return method?.titleKey ?? "agents.pulls.quick.merge"
        case .autoMerge: return "agents.pr.action.enableAutoMerge"
        case .disableAutoMerge: return "agents.pr.action.disableAutoMerge"
        }
    }

    /// Whether it goes through the merge queue; turning auto-merge off changes nothing that the next merge depends on.
    var queues: Bool { self != .disableAutoMerge }

    /// Whether a pull request the list shows can take it: a merge or auto-merge needs nothing the list already knows
    /// holds it back (`mergeBlocker`); turning auto-merge off needs only an open pull request that is not a draft.
    func applies(to item: PullRequestItem) -> Bool {
        switch self {
        case .merge, .autoMerge: return PullRequestQuickAction.mergeBlocker(item) == nil
        case .disableAutoMerge: return item.state == .open && !item.draft && !item.nodeID.isEmpty
        }
    }
}

/// Merges sent from a pull request's row or from the selection bar under a list. They queue up in the order given and
/// go to GitHub one at a time, so each is checked against what the merge before it changed (a conflict, a stack). The
/// list is read again after each merge (see `PullRequestMergeFollowUp`), so a conflict a merge causes shows at once.
struct PullRequestQuickMergeQueue: Equatable, Sendable {
    /// Waiting their turn, in the order given.
    private(set) var waiting: [String] = []
    /// At GitHub now.
    private(set) var current: String?
    /// Merged since the queue last ran empty; their rows say so until the list is read again.
    private(set) var merged: [String] = []
    /// Not merged but handed to auto-merge: checks or reviews still held them back and no admin bypass was possible.
    private(set) var autoMerged: [String] = []
    private(set) var failed = 0

    enum Phase: Equatable { case waiting, merging, merged, autoMerge }

    func phase(_ id: String) -> Phase? {
        if current == id { return .merging }
        if waiting.contains(id) { return .waiting }
        if merged.contains(id) { return .merged }
        if autoMerged.contains(id) { return .autoMerge }
        return nil
    }

    var isIdle: Bool { current == nil && waiting.isEmpty }

    /// Queues a merge; false when this pull request is queued, at GitHub or just merged already.
    @discardableResult
    mutating func add(_ id: String) -> Bool {
        guard phase(id) == nil else { return false }
        waiting.append(id)
        return true
    }

    /// Takes a merge out of the queue while it still waits its turn; false once it is at GitHub or done, when there is
    /// nothing left to stop.
    @discardableResult
    mutating func remove(_ id: String) -> Bool {
        guard let index = waiting.firstIndex(of: id) else { return false }
        waiting.remove(at: index)
        return true
    }

    /// The next one to send, now marked as at GitHub; nil when one is already there or nothing waits.
    mutating func next() -> String? {
        guard current == nil, !waiting.isEmpty else { return nil }
        current = waiting.removeFirst()
        return current
    }

    mutating func finish(success: Bool) {
        guard let id = current else { return }
        current = nil
        if success { merged.append(id) } else { failed += 1 }
    }

    /// The one at GitHub got auto-merge instead of a merge.
    mutating func finishAutoMerge() {
        guard let id = current else { return }
        current = nil
        autoMerged.append(id)
    }

    /// Something changed at GitHub this run, so the list is read again.
    var changed: Bool { !merged.isEmpty || !autoMerged.isEmpty }

    /// How many of `merged`, `autoMerged` and `failed` were reported already (`report`).
    private var reportedMerged = 0, reportedAutoMerged = 0, reportedFailed = 0

    /// While nothing waits or is at GitHub: what finished since the last report, for the toast. The rows keep showing
    /// Merged or Auto-merge until `drain`, which waits for the list to be read again; the toast does not wait for that.
    mutating func report() -> (merged: [String], autoMerged: [String], failed: Int)? {
        guard isIdle else { return nil }
        let result = (merged: Array(merged.dropFirst(reportedMerged)), autoMerged: Array(autoMerged.dropFirst(reportedAutoMerged)),
                      failed: failed - reportedFailed)
        (reportedMerged, reportedAutoMerged, reportedFailed) = (merged.count, autoMerged.count, failed)
        guard !result.merged.isEmpty || !result.autoMerged.isEmpty || result.failed > 0 else { return nil }
        return result
    }

    /// Once the queue ran empty: how it went, and a clean slate for the next run.
    mutating func drain() -> (merged: [String], autoMerged: [String], failed: Int)? {
        guard isIdle, changed || failed > 0 else { return nil }
        defer { merged = []; autoMerged = []; failed = 0; reportedMerged = 0; reportedAutoMerged = 0; reportedFailed = 0 }
        return (merged, autoMerged, failed)
    }
}

/// After a merge from Nook the other open pull requests on the same repository can now conflict with their base. GitHub
/// works that out again on its own time (`mergeable` is UNKNOWN meanwhile), so one read right after the merge rarely
/// shows it. The store reads the list again a few times, quickly at first, until GitHub knows every open pull request
/// on the merged repositories again (see `PullRequestStore.followMerge`). Each new merge starts the count over, so a
/// batch keeps the rows behind it current while it goes through.
enum PullRequestMergeFollowUp {
    /// The wait before each read, in seconds; the last read is the one at the end of this list.
    static let waits: [TimeInterval] = [1, 3, 5, 8, 13, 21]
    /// Reads made even when nothing looks pending: GitHub can answer the old mergeability for a moment after a merge.
    static let minimumReads = 2

    static func wait(before read: Int) -> TimeInterval { waits[min(max(read, 0), waits.count - 1)] }

    /// Whether GitHub is still working out mergeability for an open pull request on one of `repos`.
    static func pending(_ accounts: [AccountPullRequests], repos: Set<String>) -> Bool {
        accounts.contains { account in
            (account.mine + account.reviews + account.watched).contains {
                $0.state == .open && !$0.conflictKnown && repos.contains($0.repo)
            }
        }
    }

    /// Whether to read again after `reads` reads since the last merge.
    static func goesOn(reads: Int, pending: Bool) -> Bool {
        reads < waits.count && (reads < minimumReads || pending)
    }
}
