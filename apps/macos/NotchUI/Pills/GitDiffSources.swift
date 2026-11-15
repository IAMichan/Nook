import Combine
import SwiftUI

/// The changes in a session's folder that git knows, as choices of the diff panel beside the conversation next to the
/// agent's turns: what is not committed yet, the branch against where it left its base (`FolderGitModel.changes`), and
/// each of the newest commits. Read when the panel opens or one of them is picked, never while it sits idle.
@MainActor
final class GitDiffSources: ObservableObject {
    /// The folder's git state: its root, the uncommitted files and the branch's changes since its base.
    let folder: FolderGitModel
    @Published private(set) var commits: [GitCommitSummary] = []
    /// The files of the commits read so far, by hash.
    @Published private(set) var commitFiles: [String: [GitFileChange]] = [:]
    @Published private(set) var loaded = false
    /// A commit opened from a link that is older than the newest `commitLimit`: shown on its own under them.
    @Published private(set) var linked: GitCommitSummary?
    /// The newest commits the choices list, one at a time.
    nonisolated static let commitLimit = 100

    nonisolated static func make(directory: String) -> GitDiffSources {
        MainActor.assumeIsolated { GitDiffSources(directory: directory) }
    }

    /// The folder's own changes, passed on as they come: it publishes its root and status first and the slower branch
    /// comparison after, so the files show as soon as git knows them instead of after the whole read.
    private var folderChanges: AnyCancellable?
    /// The read under way: a second call (the panel opening and its choice being read at once) waits for it instead of
    /// reading git again beside it.
    private var refreshing: Task<Void, Never>?

    init(directory: String) {
        folder = FolderGitModel(directory: directory)
        folderChanges = folder.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var isRepository: Bool { folder.isRepository }

    /// Reads the folder's git state and its newest commits again.
    func refresh() async {
        if let refreshing { return await refreshing.value }
        let task = Task { await read() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func read() async {
        guard !folder.directory.isEmpty else {
            if !loaded { loaded = true }
            return
        }
        await folder.refresh()
        guard let root = folder.root else {
            if !commits.isEmpty { commits = [] }
            if !loaded { loaded = true }
            return
        }
        // The files are known now: the panel shows them (or says there are none) while the commits for its menu are read.
        if !loaded { loaded = true }
        let fresh = await Task.detached(priority: .userInitiated) {
            GitService.shared?.commits(root, count: GitDiffSources.commitLimit) ?? []
        }.value
        if fresh != commits { commits = fresh }
    }

    /// The files of a git choice; nil for a commit not read yet (`loadCommit`) or a choice that is not git's.
    func files(_ selection: TurnDiffSelection) -> [GitFileChange]? {
        switch selection.source {
        case .uncommitted: return folder.files
        case .branch: return folder.changes
        case .commit(let id): return commitFiles[id]
        case .turns, .turn: return nil
        }
    }

    func commit(_ id: String) -> GitCommitSummary? { commits.first { $0.id == id } ?? (linked?.id == id ? linked : nil) }

    /// Reads which files a commit changed, once. A commit beyond the newest ones (opened from a link) is read first.
    func loadCommit(_ id: String) async {
        guard commitFiles[id] == nil else { return }
        if folder.root == nil { await folder.refresh() }
        guard let root = folder.root else { return }
        if commit(id) == nil {
            linked = await Task.detached(priority: .userInitiated) { GitService.shared?.commit(root, named: id) }.value
        }
        // A hash that names no commit has no files: the panel says so instead of waiting for them forever.
        guard let commit = commit(id) else {
            commitFiles[id] = []
            return
        }
        let files = await Task.detached(priority: .userInitiated) {
            (try? GitService.shared?.changes(root, commit: commit)) ?? []
        }.value
        commitFiles[id] = files
    }

    /// The diff of one file of a git choice.
    func diff(_ selection: TurnDiffSelection, file: GitFileChange, options: DiffReadOptions) async throws -> String {
        guard let root = folder.root, let git = GitService.shared else { throw GitError(tr("ws.error.noGit")) }
        switch selection.source {
        case .branch:
            return try await folder.diff(file, options: options)
        case .uncommitted:
            return try await Task.detached(priority: .userInitiated) {
                try git.diff(root, file: file, ignoreWhitespace: options.ignoreWhitespace)
            }.value
        case .commit(let id):
            let parent = commit(id)?.parent ?? GitService.emptyTree
            return try await Task.detached(priority: .userInitiated) {
                try git.diff(root, path: file.path, from: parent, to: id, ignoreWhitespace: options.ignoreWhitespace)
            }.value
        case .turns, .turn:
            return ""
        }
    }
}
