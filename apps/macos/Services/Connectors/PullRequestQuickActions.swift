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
    /// (takes its number); nil when it may. The merge itself checks again against GitHub's answer.
    static func mergeBlocker(_ item: PullRequestItem) -> String? {
        switch item.state {
        case .merged: return "agents.pulls.quick.blocked.merged"
        case .closed: return "agents.pulls.quick.blocked.closed"
        case .open: break
        }
        if item.draft { return "agents.pulls.quick.blocked.draft" }
        if item.conflict { return "agents.pulls.quick.blocked.conflict" }
        if item.ci == .failing { return "agents.pulls.quick.blocked.checks" }
        return nil
    }

    /// The method a quick merge uses: the one you last picked on a pull request's page when the repository allows it,
    /// else the repository's own first choice.
    static func mergeMethod(preferred: PullRequestMergeMethod, allowed: [PullRequestMergeMethod]) -> PullRequestMergeMethod? {
        allowed.contains(preferred) ? preferred : PullRequestBatchMerge.method(requested: nil, allowed: allowed)
    }
}

/// Merges sent from a pull request's row or from the selection bar under a list. They queue up in the order given and
/// go to GitHub one at a time, so each is checked against what the merge before it changed (a conflict, a stack). The
/// list is read again once, when the queue is empty, so rows do not jump while the merges go through.
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

    /// Once the queue ran empty: how it went, and a clean slate for the next run.
    mutating func drain() -> (merged: [String], autoMerged: [String], failed: Int)? {
        guard isIdle, changed || failed > 0 else { return nil }
        defer { merged = []; autoMerged = []; failed = 0 }
        return (merged, autoMerged, failed)
    }
}
