import Foundation

/// The actions a pull request's row offers while you hold Shift: close and merge an open one, close a draft or mark it
/// ready for review, reopen a closed one. A merged one offers nothing. Each still needs a second click before it is sent
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

    /// The method a quick merge uses: the one you last picked on a pull request's page when the repository allows it,
    /// else the repository's own first choice.
    static func mergeMethod(preferred: PullRequestMergeMethod, allowed: [PullRequestMergeMethod]) -> PullRequestMergeMethod? {
        allowed.contains(preferred) ? preferred : PullRequestBatchMerge.method(requested: nil, allowed: allowed)
    }
}
