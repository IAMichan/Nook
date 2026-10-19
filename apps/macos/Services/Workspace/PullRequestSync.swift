import Foundation

/// The pull requests of each session's branch, asked from GitHub at most once a minute per session and kept across
/// restarts. Feeds the badge on a row and "settle when the pull request is merged".
@MainActor
final class PullRequestSync: ObservableObject {
    static let shared = PullRequestSync()

    @Published private(set) var links: [UUID: [PullRequestLink]] = [:]
    private var checked: [UUID: Date] = [:]
    private var running = false
    private let defaults = UserDefaults.standard
    private static let key = "agents.pullRequests.v1"

    init() {
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([String: [PullRequestLink]].self, from: data) {
            links = Dictionary(stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } },
                               uniquingKeysWith: { first, _ in first })
        }
    }

    func badge(_ id: UUID) -> PullRequestBadge? { PullRequestBadge.text(links: links[id] ?? []) }

    func merged(_ id: UUID) -> Bool { PullRequestSettlement.shouldSettle(links: links[id] ?? []) }

    /// Asks for every session with a feature branch that is due. Sequential, so a long list never floods GitHub.
    func refresh(workspace: WorkspaceManager, now: Date = Date()) {
        guard !running else { return }
        let due = workspace.runs.filter { run in
            guard let branch = run.branch, !branch.isEmpty, !BranchPolicy.isDefaultBranch(branch, detectedDefault: run.baseBranch) else { return false }
            return PullRequestSettlement.needsSync(lastChecked: checked[run.id], now: now)
        }
        guard !due.isEmpty else { return }
        running = true
        Task {
            defer { running = false }
            for run in due {
                checked[run.id] = now
                guard let branch = run.branch, let repo = await workspace.remoteRepository(run.id),
                      let found = await SourceForge.requests(repo: repo, branch: branch) else { continue }
                if found.isEmpty { links[run.id] = nil } else { links[run.id] = found }
            }
            save()
        }
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: links.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
    }
}
