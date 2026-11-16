import Foundation

/// The branch a folder is on, and whether it is a linked worktree, read straight from `.git` (no git process), so every
/// row can show them cheaply.
@MainActor
enum GitHead {
    private static var cache: [String: (head: Head, read: Date)] = [:]

    private struct Head {
        var branch: String?
        var worktree = false
    }

    static func branch(for path: String) -> String? { head(path).branch }

    /// A linked worktree (its `.git` is a file pointing at the repository), not the repository's own folder.
    static func isWorktree(_ path: String) -> Bool { head(path).worktree }

    private static var refreshing: Set<String> = []

    /// Read on the main thread once per folder; after that a row only reads the remembered value, and a value older than
    /// 30 seconds is read again off the main thread, shown as it was until that is done.
    private static func head(_ path: String) -> Head {
        guard !path.isEmpty else { return Head() }
        if let hit = cache[path] {
            if Date().timeIntervalSince(hit.read) >= 30, !refreshing.contains(path) {
                refreshing.insert(path)
                Task.detached(priority: .utility) {
                    let fresh = read(path)
                    await MainActor.run {
                        cache[path] = (fresh, Date())
                        refreshing.remove(path)
                    }
                }
            }
            return hit.head
        }
        let head = read(path)
        cache[path] = (head, Date())
        return head
    }

    private nonisolated static func read(_ path: String) -> Head {
        let fm = FileManager.default
        var folder = URL(fileURLWithPath: path, isDirectory: true)
        for _ in 0..<12 {
            let dotGit = folder.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                var gitDir = dotGit
                if !isDirectory.boolValue {
                    // A worktree: ".git" is a file pointing at the real git directory.
                    guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return Head() }
                    let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = target.hasPrefix("/") ? URL(fileURLWithPath: target) : folder.appendingPathComponent(target)
                }
                let worktree = !isDirectory.boolValue
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else {
                    return Head(worktree: worktree)
                }
                let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("ref: refs/heads/") {
                    return Head(branch: String(trimmed.dropFirst("ref: refs/heads/".count)), worktree: worktree)
                }
                return Head(branch: trimmed.isEmpty ? nil : String(trimmed.prefix(7)), worktree: worktree)
            }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { break }
            folder = parent
        }
        return Head()
    }
}
