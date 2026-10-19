import Foundation

/// The pull requests of each session's branch, asked from GitHub at most once a minute per session and kept across
/// restarts. Feeds the badge on a row and "settle when the pull request is merged". Agents Nook did not start (a
/// terminal session, an earlier or cloud one) are followed by folder and branch instead.
@MainActor
final class PullRequestSync: ObservableObject {
    static let shared = PullRequestSync()

    @Published private(set) var links: [UUID: [PullRequestLink]] = [:]
    /// Keyed by `folderKey(path:branch:)`.
    @Published private(set) var folderLinks: [String: [PullRequestLink]] = [:]
    private var checked: [UUID: Date] = [:]
    private var folderChecked: [String: Date] = [:]
    private var running = false
    private let defaults = UserDefaults.standard
    private static let key = "agents.pullRequests.v1"
    private static let foldersKey = "agents.pullRequests.folders.v1"

    init() {
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([String: [PullRequestLink]].self, from: data) {
            links = Dictionary(stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } },
                               uniquingKeysWith: { first, _ in first })
        }
        if let data = defaults.data(forKey: Self.foldersKey),
           let stored = try? JSONDecoder().decode([String: [PullRequestLink]].self, from: data) {
            folderLinks = stored
        }
    }

    func badge(_ id: UUID) -> PullRequestBadge? { PullRequestBadge.text(links: links[id] ?? []) }

    func badge(path: String, branch: String?) -> PullRequestBadge? {
        guard let branch else { return nil }
        return PullRequestBadge.text(links: folderLinks[Self.folderKey(path: path, branch: branch)] ?? [])
    }

    nonisolated static func folderKey(path: String, branch: String) -> String { path + "\n" + branch }

    func merged(_ id: UUID) -> Bool { PullRequestSettlement.shouldSettle(links: links[id] ?? []) }

    /// Asks for every session with a feature branch that is due, and for every other agent's folder and branch in
    /// `folders`. Sequential, so a long list never floods GitHub.
    func refresh(workspace: WorkspaceManager, folders: [(path: String, branch: String)] = [], now: Date = Date()) {
        guard !running else { return }
        let due = workspace.runs.filter { run in
            guard let branch = run.branch, !branch.isEmpty, !BranchPolicy.isDefaultBranch(branch, detectedDefault: run.baseBranch) else { return false }
            return PullRequestSettlement.needsSync(lastChecked: checked[run.id], now: now)
        }
        var seen = Set<String>()
        let dueFolders = folders.filter { folder in
            guard !folder.path.isEmpty, !folder.branch.isEmpty, !BranchPolicy.isDefaultBranch(folder.branch) else { return false }
            let key = Self.folderKey(path: folder.path, branch: folder.branch)
            return seen.insert(key).inserted && PullRequestSettlement.needsSync(lastChecked: folderChecked[key], now: now)
        }
        guard !due.isEmpty || !dueFolders.isEmpty else { return }
        running = true
        Task {
            defer { running = false }
            for run in due {
                checked[run.id] = now
                guard let branch = run.branch, let repo = await workspace.remoteRepository(run.id),
                      let found = await SourceForge.requests(repo: repo, branch: branch) else { continue }
                if found.isEmpty { links[run.id] = nil } else { links[run.id] = found }
            }
            for folder in dueFolders {
                let key = Self.folderKey(path: folder.path, branch: folder.branch)
                folderChecked[key] = now
                guard let repo = await Self.repository(path: folder.path),
                      let found = await SourceForge.requests(repo: repo, branch: folder.branch) else { continue }
                if found.isEmpty { folderLinks[key] = nil } else { folderLinks[key] = found }
            }
            save()
        }
    }

    /// The forge repository of a folder on this Mac; nil when it is gone or has no remote.
    private nonisolated static func repository(path: String) async -> RemoteRepository? {
        await Task.detached { () -> RemoteRepository? in
            guard let git = GitService.shared, FileManager.default.fileExists(atPath: path) else { return nil }
            return SourceForge.repository(remoteURL: git.remoteURL(path))
        }.value
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: links.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
        if let data = try? JSONEncoder().encode(folderLinks) { defaults.set(data, forKey: Self.foldersKey) }
    }
}
