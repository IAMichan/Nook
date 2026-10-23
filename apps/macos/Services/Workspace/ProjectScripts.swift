import Foundation

/// A command a project defines for its sessions, in `nook.json` at the repository root:
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
    static let fileNames = ["nook.json"]

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

    /// The file new scripts go into: the nearest `nook.json` up to the repository root, else a new
    /// `nook.json` at that root (or in the folder itself outside a repository).
    static func fileURL(folder: String) -> URL {
        let fm = FileManager.default
        let start = URL(fileURLWithPath: folder, isDirectory: true)
        var url = start
        for _ in 0..<12 {
            for name in fileNames where fm.fileExists(atPath: url.appendingPathComponent(name).path) {
                return url.appendingPathComponent(name)
            }
            if fm.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.appendingPathComponent(fileNames[0]) }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return start.appendingPathComponent(fileNames[0])
    }

    /// `data` (a project file, or nothing yet) with one more script at the end; everything else in the file stays.
    static func appending(name: String, command: String, to data: Data?) throws -> Data {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { throw ProjectScriptError.emptyCommand }
        var root: [String: Any] = [:]
        if let data, !data.isEmpty {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ProjectScriptError.unreadable }
            root = object
        }
        var list = (root["scripts"] as? [[String: Any]]) ?? []
        let taken = Set(parse((try? JSONSerialization.data(withJSONObject: ["scripts": list])) ?? Data()).map(\.id))
        var id = WorktreeNaming.slug(name.isEmpty ? command : name, limit: 32)
        if id.isEmpty { id = "script" }
        var unique = id
        var counter = 2
        while taken.contains(unique) { unique = "\(id)-\(counter)"; counter += 1 }
        var entry: [String: Any] = ["id": unique, "command": command]
        if !name.isEmpty { entry["name"] = name }
        list.append(entry)
        root["scripts"] = list
        var output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        output.append(contentsOf: Array("\n".utf8))
        return output
    }

    /// Adds a script to the project around `folder` and returns the file it went into.
    @discardableResult
    static func add(name: String, command: String, folder: String) throws -> URL {
        let url = fileURL(folder: folder)
        let existing = FileManager.default.contents(atPath: url.path)
        try appending(name: name, command: command, to: existing).write(to: url, options: .atomic)
        return url
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

/// Why a script could not be added. Its user-facing text (`LocalizedError`) lives in the app target, next to the
/// session panel, because `tr` is not part of the test target.
enum ProjectScriptError: Error, Equatable {
    case emptyCommand, unreadable
}
