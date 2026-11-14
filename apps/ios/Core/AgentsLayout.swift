import Foundation

// The Agents list as the Mac's list reads with "Group by project" on (docs/COMPANION.md, "Agents tab"): the sessions
// under their project's folder, and the folder a new session for that project starts in. Foundation only, so it is
// tested on the Mac (NookTests).

/// The sessions of one project, in the order the list gave them (newest first).
struct ProjectGroup<Item>: Identifiable {
    /// The folder the sessions work in, as the Mac names it; empty for sessions without one.
    let folder: String
    var items: [Item]
    var id: String { folder }
}

enum ProjectGroups {
    /// `items` under their folder: a project comes where its first (newest) session is, and each keeps its own order.
    static func group<Item>(_ items: [Item], folder: (Item) -> String) -> [ProjectGroup<Item>] {
        var order: [String] = []
        var byFolder: [String: [Item]] = [:]
        for item in items {
            let key = folder(item).trimmingCharacters(in: .whitespacesAndNewlines)
            if byFolder[key] == nil { order.append(key) }
            byFolder[key, default: []].append(item)
        }
        return order.map { ProjectGroup(folder: $0, items: byFolder[$0] ?? []) }
    }

    /// The project folder on the Mac a new session for `folder` starts in: the project the Mac offers by that name, else
    /// the one whose folder has that name. Nil when the Mac offers none (a folder you never started a session in).
    static func path(forFolder folder: String, in projects: [(name: String, path: String)]) -> String? {
        let name = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let named = projects.first(where: { $0.name == name }) { return named.path }
        return projects.first { ($0.path as NSString).lastPathComponent == name }?.path
    }

    /// The folded projects as one stored line each, so the choice is remembered (`@AppStorage` keeps a string).
    static func encode(_ folded: Set<String>) -> String { folded.sorted().joined(separator: "\n") }
    static func decode(_ stored: String) -> Set<String> {
        Set(stored.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
    }
}
