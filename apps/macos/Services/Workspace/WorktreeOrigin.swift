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

    /// The folder to start a new session in for a session at `path`: the main checkout of the repository a linked worktree
    /// was made from, else `path` itself. A bare repository has no checkout, so its worktree stays.
    static func checkoutPath(of path: String) -> String {
        guard !path.isEmpty, let worktree = worktreeRoot(of: path),
              let text = try? String(contentsOf: URL(fileURLWithPath: worktree).appendingPathComponent(".git"), encoding: .utf8),
              let store = gitStore(gitFile: text, worktree: worktree), store.lastPathComponent == ".git"
        else { return path }
        return store.deletingLastPathComponent().path
    }

    /// The folder a new session for the project `name` starts in, from the folders of its sessions (most telling first)
    /// and the folders you opened before (`known`). Always one that is still on disk and carries the project's name: a
    /// session that moved on to another repository keeps its row under this project, but its folder is not this one. An
    /// agent's worktree that was removed leads to the checkout around it (`repo/.claude/worktrees/x` → `repo`), else to a
    /// known folder with the project's name. Nil when none is left, so the "+" never opens the composer on another folder.
    static func newSessionFolder(project name: String, paths: [String], known: [String]) -> String? {
        let paths = paths.filter { !$0.isEmpty }
        for path in paths {
            let checkout = checkoutPath(of: path)
            if URL(fileURLWithPath: checkout).lastPathComponent == name, isDirectory(checkout) { return checkout }
        }
        for path in paths {
            var dir = URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent()
            for _ in 0..<12 where dir.path != "/" {
                if dir.lastPathComponent == name, isDirectory(dir.appendingPathComponent(".git").path) { return dir.path }
                dir = dir.deletingLastPathComponent()
            }
        }
        return known.first { URL(fileURLWithPath: $0).lastPathComponent == name && isDirectory($0) }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return !path.isEmpty && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Walks up from `path` to the first `.git`: a folder there is a main checkout (nil), a file the top of a linked worktree.
    private static func worktreeRoot(of path: String) -> String? {
        var dir = URL(fileURLWithPath: path).standardizedFileURL
        for _ in 0..<12 {
            let git = dir.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? nil : dir.path
            }
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { return nil }
            dir = up
        }
        return nil
    }

    private static func read(_ path: String) -> String? {
        guard let worktree = worktreeRoot(of: path),
              let text = try? String(contentsOf: URL(fileURLWithPath: worktree).appendingPathComponent(".git"), encoding: .utf8)
        else { return nil }
        return repositoryName(gitFile: text, worktree: worktree)
    }

    /// "gitdir: /code/nook/.git/worktrees/fix-x" → "nook"; a bare "/code/nook.git/worktrees/fix-x" → "nook". A relative
    /// gitdir is read from the worktree's folder. A submodule's "gitdir: …/.git/modules/…" is not a worktree.
    static func repositoryName(gitFile text: String, worktree: String) -> String? {
        guard let store = gitStore(gitFile: text, worktree: worktree) else { return nil }
        let name = store.lastPathComponent == ".git" ? store.deletingLastPathComponent().lastPathComponent
            : (store.lastPathComponent as NSString).deletingPathExtension
        return name.isEmpty || name == "/" ? nil : name
    }

    /// The repository's git folder ("/code/nook/.git", or a bare "/code/nook.git") from a linked worktree's `.git` file.
    static func gitStore(gitFile text: String, worktree: String) -> URL? {
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitdir.hasPrefix("/") { gitdir = URL(fileURLWithPath: gitdir, relativeTo: URL(fileURLWithPath: worktree, isDirectory: true)).standardizedFileURL.path }
        guard let range = gitdir.range(of: "/worktrees/", options: .backwards) else { return nil }
        return URL(fileURLWithPath: String(gitdir[..<range.lowerBound]))
    }
}
