import Foundation

/// A command a project defines for its sessions, in `nook.json` () at the repository root:
/// `{"scripts": [{"id": "dev", "name": "Dev server", "command": "pnpm dev", "runOnWorktreeCreate": false,
/// "previewUrl": "http://localhost:5173", "autoOpenPreview": true}]}`.
struct ProjectScript: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var command: String
    /// Runs by itself in a terminal right after Nook creates a worktree (install dependencies, copy `.env`).
    var runOnWorktreeCreate: Bool
    /// The page this script serves; shown above the browser and, with `autoOpenPreview`, opened when it runs.
    var previewURL: URL?
    var autoOpenPreview: Bool
}

enum ProjectScripts {
    static let fileNames = ["nook.json", "legacy-scripts.json"]

    /// The scripts of the project around `folder`: the nearest `nook.json`, up to the repository root.
    static func load(folder: String) -> [ProjectScript] {
        guard !folder.isEmpty else { return [] }
        let fm = FileManager.default
        var url = URL(fileURLWithPath: folder, isDirectory: true)
        for _ in 0..<12 {
            for name in fileNames {
                if let data = fm.contents(atPath: url.appendingPathComponent(name).path) {
                    let scripts = parse(data)
                    if !scripts.isEmpty { return scripts }
                }
            }
            // The repository root ends the search (a worktree's ".git" is a file, a checkout's a folder).
            if fm.fileExists(atPath: url.appendingPathComponent(".git").path) { break }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return []
    }

    /// Lenient: a script without a command is skipped, missing names and ids are derived, at most 50 scripts.
    static func parse(_ data: Data) -> [ProjectScript] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["scripts"] as? [[String: Any]] else { return [] }
        var seen: Set<String> = []
        var scripts: [ProjectScript] = []
        for (index, item) in list.prefix(50).enumerated() {
            let command = ((item["command"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { continue }
            let name = ((item["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var id = ((item["id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty { id = WorktreeNaming.slug(name.isEmpty ? command : name, limit: 32) }
            if seen.contains(id) { id += "-\(index)" }
            seen.insert(id)
            let preview = (item["previewUrl"] as? String).flatMap { BridgeURLPolicy.url($0) }
            scripts.append(ProjectScript(id: id, name: name.isEmpty ? command : name, command: command,
                                         runOnWorktreeCreate: (item["runOnWorktreeCreate"] as? Bool) ?? false,
                                         previewURL: preview, autoOpenPreview: (item["autoOpenPreview"] as? Bool) ?? false))
        }
        return scripts
    }
}
