import Foundation

/// The repository a linked git worktree was made from. An agent's own worktree (Claude Code's `.claude/worktrees/<name>`,
/// Nook's, Codex's, Cursor's…) is named after its branch, so a session's row names the repository instead. Read from the
/// worktree's `.git` file, which says where its main checkout keeps it, and kept: a folder's origin does not change.
enum WorktreeOrigin {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var names: [String: String?] = [:]
    }

    private static let cache = Cache()

    /// The main checkout's folder name for a path inside a linked worktree; nil for a main checkout, a submodule, or a
    /// folder outside git (or not on this Mac).
    static func repositoryName(of path: String) -> String? {
        guard !path.isEmpty else { return nil }
        cache.lock.lock()
        if let hit = cache.names[path] {
            cache.lock.unlock()
            return hit
        }
        cache.lock.unlock()
        let found = read(path)
        cache.lock.lock()
        cache.names[path] = found
        cache.lock.unlock()
        return found
    }

    /// Walks up from `path` to the first `.git`: a folder there is a main checkout, a file a linked worktree.
    private static func read(_ path: String) -> String? {
        var dir = URL(fileURLWithPath: path).standardizedFileURL
        for _ in 0..<12 {
            let git = dir.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                guard !isDirectory.boolValue, let text = try? String(contentsOf: git, encoding: .utf8) else { return nil }
                return repositoryName(gitFile: text, worktree: dir.path)
            }
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { return nil }
            dir = up
        }
        return nil
    }

    /// "gitdir: /code/nook/.git/worktrees/fix-x" → "nook"; a bare "/code/nook.git/worktrees/fix-x" → "nook". A relative
    /// gitdir is read from the worktree's folder. A submodule's "gitdir: …/.git/modules/…" is not a worktree.
    static func repositoryName(gitFile text: String, worktree: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitdir.hasPrefix("/") { gitdir = URL(fileURLWithPath: gitdir, relativeTo: URL(fileURLWithPath: worktree, isDirectory: true)).standardizedFileURL.path }
        guard let range = gitdir.range(of: "/worktrees/", options: .backwards) else { return nil }
        let store = URL(fileURLWithPath: String(gitdir[..<range.lowerBound]))
        let name = store.lastPathComponent == ".git" ? store.deletingLastPathComponent().lastPathComponent
            : (store.lastPathComponent as NSString).deletingPathExtension
        return name.isEmpty || name == "/" ? nil : name
    }
}
