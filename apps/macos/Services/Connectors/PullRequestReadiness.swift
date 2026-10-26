import Foundation

/// What still stands between an open pull request and its merge, at a glance: one line per thing GitHub weighs
/// (conflicts, checks, reviews, a branch that is behind, a draft), each good, waiting or in the way, and the verdict over
/// them. The Summary shows it at the top, so you do not have to read the checks and the timeline to know where it stands.
/// Foundation only, so tests can use it.
struct PullRequestReadiness: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        /// Nothing to do.
        case good
        /// Still running or waiting on someone else.
        case waiting
        /// Has to change before it can merge.
        case blocking
        /// Nothing to say either way (no checks, no reviews yet).
        case neutral
    }

    enum Item: Equatable, Sendable {
        case draft
        case conflicts(base: String)
        case noConflicts(base: String)
        case behind(base: String)
        case checksFailing(failing: Int, total: Int)
        case checksRunning(running: Int, total: Int)
        case checksPassed(total: Int)
        case noChecks
        case changesRequested(by: [String])
        case approved(by: [String])
        case reviewRequested(from: [String])
        case noReviews

        var tone: Tone {
            switch self {
            case .conflicts, .checksFailing, .changesRequested: .blocking
            case .draft, .behind, .checksRunning, .reviewRequested: .waiting
            case .noConflicts, .checksPassed, .approved: .good
            case .noChecks, .noReviews: .neutral
            }
        }
    }

    enum Verdict: Equatable, Sendable {
        case ready
        case waiting
        case blocked
    }

    let items: [Item]

    /// Blocked when one line is in the way, waiting while one still waits, else ready.
    var verdict: Verdict {
        if items.contains(where: { $0.tone == .blocking }) { return .blocked }
        if items.contains(where: { $0.tone == .waiting }) { return .waiting }
        return .ready
    }

    /// Nil for a merged or closed pull request: there is nothing left to get ready.
    init?(_ detail: PullRequestDetail) {
        guard detail.isOpen else { return nil }
        var items: [Item] = []
        if detail.state == .draft { items.append(.draft) }

        if detail.conflicted {
            items.append(.conflicts(base: detail.baseBranch))
        } else if detail.mergeState == "behind" {
            items.append(.behind(base: detail.baseBranch))
        } else if detail.mergeable == true {
            items.append(.noConflicts(base: detail.baseBranch))
        }

        let counts = detail.checkCounts
        let total = detail.checks.count
        if total == 0 {
            items.append(.noChecks)
        } else if counts.failing > 0 {
            items.append(.checksFailing(failing: counts.failing, total: total))
        } else if counts.pending > 0 {
            items.append(.checksRunning(running: counts.pending, total: total))
        } else {
            items.append(.checksPassed(total: total))
        }

        // Reviews come with the activity; until then nothing is said about them rather than "no reviews".
        if detail.activityLoaded {
            let verdicts = detail.verdicts
            let changes = verdicts.filter { !$0.approved }.map(\.author)
            let approvals = verdicts.filter(\.approved).map(\.author)
            let answered = Set(verdicts.map(\.author))
            let waiting = detail.requestedReviewers.filter { !answered.contains($0) }
            if !changes.isEmpty {
                items.append(.changesRequested(by: changes))
            } else if !approvals.isEmpty {
                items.append(.approved(by: approvals))
            }
            if changes.isEmpty, !waiting.isEmpty {
                items.append(.reviewRequested(from: waiting))
            } else if changes.isEmpty, approvals.isEmpty {
                items.append(.noReviews)
            }
        }
        self.items = items
    }
}
