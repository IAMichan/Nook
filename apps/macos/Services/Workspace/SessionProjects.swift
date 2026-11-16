import Foundation

/// The projects a session works in besides its own: a chat started in Nook that also edits files in a monorepo is
/// "Nook + monorepo" in the list. Shared by sessions Nook runs (`recordFileChange`) and sessions known from hooks, for every
/// agent alike: both learn of a changed file and ask here whether it lies in another project.
///
/// A project is the repository's own folder (its main checkout): a file in a worktree of the same repository is the same
/// project, and a file outside any repository (a scratch file, a config in the home folder) is none.
enum SessionProjects {
    /// At most this many other projects are remembered for one session.
    static let limit = 6

    /// `projects` with the project of `file` added when it is another project than the session's own folder `own`; nil
    /// when nothing changes (the file is in its own project, in no project, or its project is already listed).
    static func adding(file: String, own: String, to projects: [String],
                       root: (String) -> String? = { SessionProjects.root(of: $0) }) -> [String]? {
        guard file.hasPrefix("/"), !own.isEmpty, projects.count < limit else { return nil }
        // Inside the session's own folder: nothing to look up.
        if file.hasPrefix(own.hasSuffix("/") ? own : own + "/") { return nil }
        guard let project = root((file as NSString).deletingLastPathComponent) else { return nil }
        if project == root(own) || projects.contains(project) { return nil }
        return projects + [project]
    }

    /// The files a tool call wrote, absolute, as a hook reports it: the path of an edit or write (Claude Code, Gemini CLI,
    /// Cursor, …), or every file a patch touches (Codex's `apply_patch`). Relative paths are read from `cwd`.
    static func writtenFiles(tool: String, input: [String: Any], cwd: String) -> [String] {
        changedFiles(tool: tool, input: input).map { absolute($0.path, cwd: cwd) }
    }

    /// `path` as it is when absolute, else read from `cwd`.
    static func absolute(_ path: String, cwd: String) -> String {
        if path.hasPrefix("/") || cwd.isEmpty { return path }
        return URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(path).standardizedFileURL.path
    }

    /// The files a call changes as the agent named them, each with how ("modified", "written", "deleted"): the file
    /// of an edit, write or delete of any agent (`CanonicalTool`), or every file a patch touches. Empty for a call that
    /// changes no file.
    static func changedFiles(tool: String, input: [String: Any]) -> [(path: String, kind: String)] {
        switch CanonicalTool.kind(tool) {
        case .edit:
            // str_replace_editor's create writes a whole file.
            if case .write = EditPatch.change(tool: tool, input: input) {
                return ToolInput.path(input).map { [($0, "written")] } ?? []
            }
            return ToolInput.path(input).map { [($0, "modified")] } ?? []
        case .write:
            return ToolInput.path(input).map { [($0, "written")] } ?? []
        case .delete:
            return ToolInput.path(input).map { [($0, "deleted")] } ?? []
        case .patch:
            let patch = (input["input"] as? String) ?? (input["patch"] as? String) ?? (input["command"] as? String) ?? ""
            return patchChanges(patch)
        default:
            return []
        }
    }

    /// The files an `apply_patch` patch adds, updates, deletes or moves to, each with how.
    static func patchChanges(_ patch: String) -> [(path: String, kind: String)] {
        let heads = [("*** Add File: ", "written"), ("*** Update File: ", "modified"), ("*** Delete File: ", "deleted"),
                     ("*** Move to: ", "written")]
        var files: [(path: String, kind: String)] = []
        for line in patch.split(separator: "\n") {
            guard let head = heads.first(where: { line.hasPrefix($0.0) }) else { continue }
            let path = line.dropFirst(head.0.count).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty, !files.contains(where: { $0.path == path }) { files.append((path, head.1)) }
        }
        return files
    }

    /// The files an `apply_patch` patch adds, updates, deletes or moves to.
    static func patchFiles(_ patch: String) -> [String] {
        patchChanges(patch).map(\.path)
    }

    /// The names the list shows for `projects`, in the order they were found, without the session's own name.
    static func names(_ projects: [String], own: String, name: (String) -> String) -> [String] {
        var seen: Set<String> = [own]
        return projects.map(name).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// "Nook + monorepo", or "Nook + monorepo +2" when there are more than fit.
    static func label(own: String, others: [String], shown: Int = 1) -> String {
        guard !others.isEmpty else { return own }
        let named = others.prefix(shown).joined(separator: " + ")
        let rest = others.count - shown
        return own + " + " + named + (rest > 0 ? " +\(rest)" : "")
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    /// The main checkout of the repository `folder` is in, read from `.git` without a git process; nil outside a
    /// repository, or for the home folder itself. Remembered per folder: a session changes many files in few folders.
    static func root(of folder: String) -> String? {
        if let hit = lock.withLock({ cache[folder] }) { return hit }
        let found = read(folder)
        lock.withLock {
            if cache.count > 2_000 { cache.removeAll() }
            cache[folder] = found
        }
        return found
    }

    private static func read(_ folder: String) -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var url = URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL
        for _ in 0..<24 {
            let path = url.path
            if path == "/" || path == home { return nil }
            let dotGit = url.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return path }
                // A linked worktree: ".git" is a file "gitdir: <repo>/.git/worktrees/<name>"; its project is <repo>.
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return path }
                let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let gitDir = target.hasPrefix("/") ? target : url.appendingPathComponent(target).standardizedFileURL.path
                guard let range = gitDir.range(of: "/.git/worktrees/") else { return path }
                return String(gitDir[..<range.lowerBound])
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == path { return nil }
            url = parent
        }
        return nil
    }
}
