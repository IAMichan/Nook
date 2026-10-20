import Foundation

/// The branch a folder is on, read straight from `.git/HEAD` (no git process), so every row can show it cheaply.
@MainActor
enum GitHead {
    private static var cache: [String: (branch: String?, read: Date)] = [:]

    static func branch(for path: String) -> String? {
        guard !path.isEmpty else { return nil }
        if let hit = cache[path], Date().timeIntervalSince(hit.read) < 30 { return hit.branch }
        let branch = read(path)
        cache[path] = (branch, Date())
        return branch
    }

    private static func read(_ path: String) -> String? {
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
                          let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                    let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = target.hasPrefix("/") ? URL(fileURLWithPath: target) : folder.appendingPathComponent(target)
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
                let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("ref: refs/heads/") { return String(trimmed.dropFirst("ref: refs/heads/".count)) }
                return trimmed.isEmpty ? nil : String(trimmed.prefix(7))
            }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { break }
            folder = parent
        }
        return nil
    }
}
