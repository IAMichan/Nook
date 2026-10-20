import Foundation

/// The pull requests of each session's branch, asked from GitHub on a schedule that follows their state (see
/// `PullRequestSettlement.syncInterval`) and kept across restarts. Feeds the badge on a row and "settle when the pull
/// request is merged". Agents Nook did not start (a terminal session, an earlier or cloud one) are followed by folder
/// and branch instead.
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

    /// A GitHub pull request merged from Nook: the badges of its sessions turn merged at once, not at the next round.
    func markMerged(repository: String, number: Int) {
        func settle(_ list: [PullRequestLink]) -> [PullRequestLink] {
            list.map { link in
                guard link.host == .github, link.number == number, link.state.isOpen,
                      link.repository.lowercased() == repository.lowercased() else { return link }
                var link = link
                link.state = .merged
                return link
            }
        }
        links = links.mapValues(settle)
        folderLinks = folderLinks.mapValues(settle)
        save()
    }

    /// One branch to ask about: a session Nook runs, or another agent's folder.
    private enum Job {
        case run(UUID, branch: String)
        case folder(key: String, path: String, branch: String)
    }

    /// At most this many branches per round, so one round stays short and never holds up the next.
    private static let perRound = 8
    private static let tick: Duration = .seconds(15)
    private weak var workspace: WorkspaceManager?
    private var folders: [(path: String, branch: String)] = []
    private var loop: Task<Void, Never>?

    /// Keeps the badges current from now on, also while the list is off screen: a merged pull request shows as merged
    /// without opening anything. `folders` are the other agents' folders and branches, replaced on every call.
    func follow(workspace: WorkspaceManager, folders: [(path: String, branch: String)], now: Date = Date()) {
        self.workspace = workspace
        self.folders = folders
        refresh(now: now)
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tick)
                guard let self else { return }
                self.refresh(now: Date())
            }
        }
    }

    /// Asks for the branches that are due, open requests first and then the longest unasked. Sequential, so a long
    /// list never floods GitHub.
    private func refresh(now: Date) {
        guard !running, let workspace else { return }
        var due: [(job: Job, open: Bool, last: Date)] = []
        for run in workspace.runs where !run.archived {
            guard let branch = run.branch, !branch.isEmpty, !BranchPolicy.isDefaultBranch(branch, detectedDefault: run.baseBranch) else { continue }
            let known = links[run.id] ?? []
            guard PullRequestSettlement.needsSync(lastChecked: checked[run.id], now: now,
                                                  interval: PullRequestSettlement.syncInterval(links: known)) else { continue }
            due.append((job: .run(run.id, branch: branch), open: PullRequestSettlement.anyOpen(links: known),
                        last: checked[run.id] ?? .distantPast))
        }
        var seen = Set<String>()
        for folder in folders {
            guard !folder.path.isEmpty, !folder.branch.isEmpty, !BranchPolicy.isDefaultBranch(folder.branch) else { continue }
            let key = Self.folderKey(path: folder.path, branch: folder.branch)
            guard seen.insert(key).inserted else { continue }
            let known = folderLinks[key] ?? []
            guard PullRequestSettlement.needsSync(lastChecked: folderChecked[key], now: now,
                                                  interval: PullRequestSettlement.syncInterval(links: known)) else { continue }
            due.append((job: .folder(key: key, path: folder.path, branch: folder.branch), open: PullRequestSettlement.anyOpen(links: known),
                        last: folderChecked[key] ?? .distantPast))
        }
        guard !due.isEmpty else { return }
        let round = due.sorted { ($0.open ? 0 : 1, $0.last) < ($1.open ? 0 : 1, $1.last) }.prefix(Self.perRound).map(\.job)
        running = true
        Task {
            defer { running = false }
            for job in round {
                switch job {
                case .run(let id, let branch):
                    checked[id] = now
                    guard let repo = await workspace.remoteRepository(id),
                          let found = await SourceForge.requests(repo: repo, branch: branch) else { continue }
                    links[id] = found.isEmpty ? nil : found
                case .folder(let key, let path, let branch):
                    folderChecked[key] = now
                    guard let repo = await Self.repository(path: path),
                          let found = await SourceForge.requests(repo: repo, branch: branch) else { continue }
                    folderLinks[key] = found.isEmpty ? nil : found
                }
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
