import Foundation

/// The actions a pull request's row offers while you hold Shift: close and merge an open one, close a draft or mark it
/// ready for review, reopen a closed one. A merged one offers nothing. Each needs a second click before it is sent
/// (see `PullRequestQuickActionButtons`; after one confirmed merge, further merges in the same Shift hold go on one
/// click), and each is written to the action log. Foundation only, so tests can use it.
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

    /// The method a quick merge uses: the one you last picked on a pull request's page when the repository allows it,
    /// else the repository's own first choice.
    static func mergeMethod(preferred: PullRequestMergeMethod, allowed: [PullRequestMergeMethod]) -> PullRequestMergeMethod? {
        allowed.contains(preferred) ? preferred : PullRequestBatchMerge.method(requested: nil, allowed: allowed)
    }
}

/// Merging several pull requests in one Shift hold. The first quick merge still asks "Merge it?"; once that is confirmed,
/// every other Merge clicked before Shift is let go merges on one click. The merges queue up in the order clicked and go
/// to GitHub one at a time, so each is checked against what the merge before it changed (a conflict, a stack). The list
/// is read again once, when the queue is empty, so rows do not jump while you click through them.
struct PullRequestQuickMergeQueue: Equatable, Sendable {
    /// A merge was confirmed during this Shift hold: the next ones go on one click.
    private(set) var unlocked = false
    /// Waiting their turn, in the order clicked.
    private(set) var waiting: [String] = []
    /// At GitHub now.
    private(set) var current: String?
    /// Merged since the queue last ran empty; their rows say so until the list is read again.
    private(set) var merged: [String] = []
    private(set) var failed = 0

    enum Phase: Equatable { case waiting, merging, merged }

    func phase(_ id: String) -> Phase? {
        if current == id { return .merging }
        if waiting.contains(id) { return .waiting }
        if merged.contains(id) { return .merged }
        return nil
    }

    var isIdle: Bool { current == nil && waiting.isEmpty }

    /// Shift came up: the next merge asks again. What is queued still goes.
    mutating func shiftReleased() { unlocked = false }

    /// A click on Merge. Unless `confirmed` (the second click of an armed button) or the hold is unlocked, it only says
    /// the button should ask first. Returns whether the merge was queued.
    @discardableResult
    mutating func add(_ id: String, confirmed: Bool) -> Bool {
        guard confirmed || unlocked else { return false }
        unlocked = true
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

    /// Once the queue ran empty: how it went, and a clean slate for the next run.
    mutating func drain() -> (merged: [String], failed: Int)? {
        guard isIdle, !merged.isEmpty || failed > 0 else { return nil }
        defer { merged = []; failed = 0 }
        return (merged, failed)
    }
}
