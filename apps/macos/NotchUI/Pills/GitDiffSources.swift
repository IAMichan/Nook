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

    nonisolated static func make(directory: String) -> GitDiffSources {
        MainActor.assumeIsolated { GitDiffSources(directory: directory) }
    }

    init(directory: String) {
        folder = FolderGitModel(directory: directory)
    }

    var isRepository: Bool { folder.isRepository }

    /// Reads the folder's git state and its newest commits again.
    func refresh() async {
        guard !folder.directory.isEmpty else { return }
        await folder.refresh()
        // The folder's own changes are published on it, not here: say once that they may have changed.
        objectWillChange.send()
        guard let root = folder.root else {
            if !commits.isEmpty { commits = [] }
            loaded = true
            return
        }
        let fresh = await Task.detached(priority: .utility) { GitService.shared?.commits(root) ?? [] }.value
        if fresh != commits { commits = fresh }
        loaded = true
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

    func commit(_ id: String) -> GitCommitSummary? { commits.first { $0.id == id } }

    /// Reads which files a commit changed, once.
    func loadCommit(_ id: String) async {
        guard commitFiles[id] == nil, let root = folder.root, let commit = commit(id) else { return }
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
