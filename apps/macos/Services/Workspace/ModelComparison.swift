import Foundation

// Sending one prompt to several models: the new-session composer starts one session per chosen model, each in its own
// worktree, and the Agents list groups them under the first one that started. Pure decisions about the selection, the
// configurations and what a partly failed send leaves behind; `WorkspaceManager.startComparison` runs them. Foundation
// only, so it is tested on its own.

/// One model to send the prompt to: the agent, the account it runs under and the model (empty: the agent's default).
struct ComparisonTarget: Codable, Hashable, Sendable {
    var provider: RunProvider
    var profileID: String
    var model: String
}

enum ModelComparison {
    /// At most this many sessions start from one prompt: each one is a worktree and an agent running at once.
    static let maxModels = 4

    /// Adds or removes a model next to the one the composer has chosen. The chosen model always stays; the list keeps the
    /// order you picked in and never grows past `maxModels` together with it.
    static func toggling(_ target: ComparisonTarget, in extras: [ComparisonTarget], primary: ComparisonTarget) -> [ComparisonTarget] {
        guard target != primary else { return extras.filter { $0 != primary } }
        if extras.contains(target) { return extras.filter { $0 != target } }
        let kept = extras.filter { $0 != primary }
        return kept.count + 1 >= maxModels ? kept : kept + [target]
    }

    /// Every model the prompt goes to: the chosen one first, then the others without doubles, capped at `maxModels`.
    static func targets(primary: ComparisonTarget, extras: [ComparisonTarget]) -> [ComparisonTarget] {
        var seen: Set<ComparisonTarget> = []
        return Array(([primary] + extras).filter { seen.insert($0).inserted }.prefix(maxModels))
    }

    /// One configuration per target, from the composer's own: each in a new worktree with a branch of its own, named
    /// after the task and the model so the rows tell them apart. An access level the agent does not support falls back
    /// to one it does; the effort only carries over within the same agent.
    static func configs(base: NewRunConfig, targets: [ComparisonTarget], ids: [UUID],
                        modelName: (ComparisonTarget) -> String) -> [NewRunConfig] {
        let title = base.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = title.isEmpty ? WorktreeNaming.title(from: base.task) : title
        return zip(targets, ids).map { target, id in
            var config = base
            config.provider = target.provider
            config.profileID = target.profileID
            config.model = target.model
            config.isolation = .worktree
            config.branchName = WorktreeNaming.branchName(task: base.task, id: id)
            config.title = shown + " · " + modelName(target)
            if target.provider != base.provider { config.effort = nil }
            if !target.provider.capabilities.policies.contains(config.permission) {
                config.permission = target.provider.capabilities.policies.contains(.acceptEdits)
                    ? .acceptEdits : (target.provider.capabilities.policies.first ?? .acceptEdits)
            }
            return config
        }
    }

    /// Where a comparison's session comes from: the first one that started is the group's parent, every later one points
    /// at it (see `RunLineage.Kind.comparison`).
    static func lineage(leader: UUID?) -> RunLineage? {
        leader.map { RunLineage(kind: .comparison, parentID: $0, atEvent: 0) }
    }

    /// How a comparison went: which targets started (with their session) and which failed (with why).
    struct Outcome: Equatable, Sendable {
        var started: [(target: ComparisonTarget, id: UUID)] = []
        var failed: [(target: ComparisonTarget, message: String)] = []

        /// The session the composer opens: the group's parent.
        var leader: UUID? { started.first?.id }
        /// Anything failed: the prompt stays in the composer, with the failed models still chosen to try again.
        var keepsPrompt: Bool { !failed.isEmpty }
        var failedTargets: [ComparisonTarget] { failed.map(\.target) }

        static func == (a: Outcome, b: Outcome) -> Bool {
            a.started.map(\.target) == b.started.map(\.target) && a.started.map(\.id) == b.started.map(\.id)
                && a.failed.map(\.target) == b.failed.map(\.target) && a.failed.map(\.message) == b.failed.map(\.message)
        }
    }

    /// After a send: the model the composer keeps chosen and the extra ones, so trying again only sends what failed.
    /// Nil when everything started (the composer starts fresh).
    static func retrySelection(after outcome: Outcome) -> (primary: ComparisonTarget, extras: [ComparisonTarget])? {
        guard let first = outcome.failedTargets.first else { return nil }
        return (first, Array(outcome.failedTargets.dropFirst()))
    }
}
