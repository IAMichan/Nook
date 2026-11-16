import Foundation

// Accepting or rejecting one hunk of a session's changes: the hunk goes to git as a patch of its own (`HunkPatch`), so
// the rest of the file is left alone.

extension GitService {
    /// Stages (`accept`) or takes out of the working tree (`reject`) the one hunk `patch` holds, in the repository at
    /// `repository`. The patch is written to a file of its own for the call and removed after it.
    func applyHunk(_ patch: String, action: HunkAction, repository: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nook-hunk-\(UUID().uuidString).patch")
        try patch.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        try run(HunkPatch.arguments(for: action, patchPath: file.path), in: repository)
    }
}

extension WorkspaceManager {
    /// Applies one hunk of a changed file of session `id` (a session on this Mac; one on another machine has none to apply
    /// it to), then reads git again so the lists and counts follow. Throws what git says when the hunk no longer fits
    /// (the file changed since the diff was read, or the hunk is already staged).
    func applyHunk(_ id: UUID, patch: String, action: HunkAction) async throws {
        guard let run = run(id), !run.isRemote, let git = sessionGit(for: run) else {
            throw GitError(tr("agents.diff.hunk.failed"))
        }
        // The diff's paths are the repository's, so the patch applies from its root (as `absolutePath` finds files).
        let root = run.worktreePath ?? run.repoRoot ?? run.workingDirectory
        try await Task.detached(priority: .userInitiated) { try git.applyHunk(patch, action: action, repository: root) }.value
        DiffCache.clear()
        refreshGit(id)
    }
}
