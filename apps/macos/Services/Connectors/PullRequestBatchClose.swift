import Foundation

/// Closing several pull requests in one go (the selection bar's Close, a sweep over rows), with an optional comment that
/// says why. They go one after the other; one that fails is reported with its reason and the rest still go. With a
/// comment, the comment goes first and a pull request whose comment the forge refused is left open, so none closes
/// without the words you wrote for it. Foundation only: the forge calls come in as closures, so tests can use it.
enum PullRequestBatchClose {
    enum Outcome: Equatable, Sendable {
        case closed
        /// The comment was refused; the pull request stays open.
        case commentFailed(String)
        case failed(String)

        var closed: Bool { self == .closed }
    }

    /// The comment as it is sent, or nil when there is none worth sending.
    static func comment(_ text: String?) -> String? {
        let clean = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? nil : clean
    }

    /// Runs `targets` in order: `post` (only with a comment), then `close`. Never stops at a failure.
    static func run<Target>(_ targets: [Target], comment text: String?,
                            post: (Target, String) async throws -> Void,
                            close: (Target) async throws -> Void) async -> [(target: Target, outcome: Outcome)] {
        let comment = comment(text)
        var outcomes: [(target: Target, outcome: Outcome)] = []
        for target in targets {
            if let comment {
                do {
                    try await post(target, comment)
                } catch {
                    outcomes.append((target, .commentFailed(error.localizedDescription)))
                    continue
                }
            }
            do {
                try await close(target)
                outcomes.append((target, .closed))
            } catch {
                outcomes.append((target, .failed(error.localizedDescription)))
            }
        }
        return outcomes
    }

    /// What the result says: how many closed of how many, and each one that did not with its reason.
    struct Report: Equatable, Sendable {
        var closed: Int
        var total: Int
        /// "#12" (or another name) and why it did not close, in the order they went.
        var failures: [(name: String, reason: String, commentOnly: Bool)]

        var allClosed: Bool { failures.isEmpty }

        static func == (lhs: Report, rhs: Report) -> Bool {
            lhs.closed == rhs.closed && lhs.total == rhs.total
                && lhs.failures.map { "\($0.name)|\($0.reason)|\($0.commentOnly)" } == rhs.failures.map { "\($0.name)|\($0.reason)|\($0.commentOnly)" }
        }
    }

    static func report<Target>(_ outcomes: [(target: Target, outcome: Outcome)], name: (Target) -> String) -> Report {
        var failures: [(name: String, reason: String, commentOnly: Bool)] = []
        for (target, outcome) in outcomes {
            switch outcome {
            case .closed: break
            case .commentFailed(let reason): failures.append((name(target), reason, true))
            case .failed(let reason): failures.append((name(target), reason, false))
            }
        }
        return Report(closed: outcomes.count(where: { $0.outcome.closed }), total: outcomes.count, failures: failures)
    }
}
