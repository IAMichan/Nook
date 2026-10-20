import Foundation

/// "Merge all my PRs": several pull requests merged in one approved action. The list is written out in the plan, so the
/// user sees (and can edit) exactly which pull requests go before anything runs. Each one is checked again right before
/// its merge; what is not ready is skipped with the reason instead of stopping the rest. Foundation only, so tests can use it.
enum PullRequestBatchMerge {
    /// More than this in one action is no longer something the user can review at a glance.
    static let limit = 30

    struct Target: Equatable, Hashable, Sendable {
        let repo: String
        let number: Int
        var ref: String { "\(repo)#\(number)" }
    }

    /// The pull requests in `pulls`: "owner/name#12", "owner/name/pull/12" or a github.com link, separated by commas,
    /// semicolons, spaces or new lines (or given as a list). Duplicates count once; anything unreadable goes to `invalid`.
    static func targets(_ pulls: Any?) -> (targets: [Target], invalid: [String]) {
        let parts: [String]
        if let list = pulls as? [Any] {
            parts = list.map { "\($0)" }
        } else if let text = pulls as? String {
            parts = text.components(separatedBy: CharacterSet(charactersIn: ",;\n\t "))
        } else {
            parts = []
        }
        var targets: [Target] = []
        var invalid: [String] = []
        for raw in parts {
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`[]()")))
            guard !part.isEmpty else { continue }
            guard let target = target(part) else { invalid.append(part); continue }
            if !targets.contains(target) { targets.append(target) }
        }
        return (targets, invalid)
    }

    private static func target(_ text: String) -> Target? {
        var path = text
        for prefix in ["https://github.com/", "http://github.com/", "github.com/"] where path.lowercased().hasPrefix(prefix) {
            path = String(path.dropFirst(prefix.count))
        }
        let repo: String
        let number: String
        if let range = path.range(of: "/pull/") ?? path.range(of: "/pulls/") {
            repo = String(path[..<range.lowerBound])
            number = String(path[range.upperBound...].prefix { $0.isNumber })
        } else if let hash = path.lastIndex(of: "#") {
            repo = String(path[..<hash])
            number = String(path[path.index(after: hash)...])
        } else {
            return nil
        }
        guard ActionGate.isRepository(repo), let value = Int(number), value > 0 else { return nil }
        return Target(repo: repo, number: value)
    }

    /// The plan's line: "merge 3 pull requests (squash): a/b#1, a/b#2, c/d#7".
    static func summary(_ pulls: Any?, method: String) -> String {
        let found = targets(pulls).targets
        guard !found.isEmpty else { return "GitHub: merge pull requests" }
        let count = found.count == 1 ? "1 pull request" : "\(found.count) pull requests"
        return "GitHub: merge \(count) (\(method)): " + found.map(\.ref).joined(separator: ", ")
    }

    /// What is wrong with the list itself, for the action gate. Empty when it can be proposed.
    static func problems(_ pulls: Any?) -> [String] {
        let (found, invalid) = targets(pulls)
        var problems: [String] = []
        if found.isEmpty { problems.append("Geen pull requests herkend; schrijf ze als eigenaar/naam#nummer.") }
        if found.count > limit { problems.append("Te veel pull requests in één keer (\(found.count)); maximaal \(limit).") }
        if !invalid.isEmpty { problems.append("Geen pull request: \(invalid.joined(separator: ", ")).") }
        return problems
    }

    /// Why this pull request is not merged in a batch, or nil when it goes ahead. Only what certainly fails or would merge
    /// something unfinished is held back; branch protection and the like are left to GitHub, which says why it refuses.
    static func skipReason(_ detail: PullRequestDetail) -> String? {
        switch detail.state {
        case .merged: return "already merged"
        case .closed: return "closed"
        case .draft: return "draft"
        case .open: break
        }
        if detail.canPush == false { return "no write access" }
        if detail.conflicted { return "merge conflicts" }
        switch detail.checkSummary {
        case .failing: return "CI failing"
        case .pending: return "CI still running"
        default: return nil
        }
    }

    /// The method to use: the one asked for when the repository allows it, else the repository's first allowed method
    /// when none was asked for. Nil when the requested method is not allowed there.
    static func method(requested: PullRequestMergeMethod?, allowed: [PullRequestMergeMethod]) -> PullRequestMergeMethod? {
        if let requested { return allowed.contains(requested) ? requested : nil }
        return allowed.contains(.merge) ? .merge : allowed.first
    }

    enum Outcome: Equatable {
        case merged(String)
        case skipped(String)
        case failed(String)
    }

    /// The result the user and the brain read back: what was merged, what was skipped and why, what GitHub refused.
    static func report(_ outcomes: [(Target, Outcome)]) -> String {
        let merged = outcomes.filter { if case .merged = $0.1 { return true }; return false }
        var lines = ["Merged \(merged.count) of \(outcomes.count) pull requests."]
        for (target, outcome) in outcomes {
            switch outcome {
            case .merged(let method): lines.append("✓ \(target.ref) merged (\(method))")
            case .skipped(let reason): lines.append("– \(target.ref) skipped: \(reason)")
            case .failed(let message): lines.append("✗ \(target.ref) failed: \(message)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
