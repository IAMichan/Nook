import Foundation

// The "changed files" tree under a turn: directories aggregate their children's numbers,
// chains of single-child directories collapse into one row ("src/app"), and every row has a stable id (its path) so
// expansion state survives rebuilds.

struct ChangedFilesTree: Equatable, Sendable {
    struct FileStat: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case added, modified, deleted
            case renamed(from: String)
        }

        var path: String
        /// nil for binary files: no numbers are shown for them.
        var added: Int?
        var removed: Int?
        var kind: Kind = .modified
    }

    struct Stats: Equatable, Sendable {
        var added = 0
        var removed = 0
        var fileCount = 0
        /// False when no file below has numbers (only binaries).
        var hasNumbers = false
    }

    struct Row: Equatable, Identifiable, Sendable {
        var depth: Int
        var isDirectory: Bool
        /// A collapsed chain shows as "src/app".
        var name: String
        /// Full path; stable id.
        var path: String
        var stats: Stats
        var kind: FileStat.Kind?
        var id: String { path }
    }

    fileprivate struct Node: Equatable, Sendable {
        var name: String
        var path: String
        var isDirectory: Bool
        var stats: Stats
        var kind: FileStat.Kind?
        var children: [Node]
    }

    fileprivate var roots: [Node]
    let totals: Stats

    var isEmpty: Bool { roots.isEmpty }

    private final class Builder {
        var name: String
        var path: String
        var dirs: [String: Builder] = [:]
        var files: [Node] = []
        init(name: String, path: String) { self.name = name; self.path = path }
    }

    static func build(_ changes: [FileStat]) -> ChangedFilesTree {
        let root = Builder(name: "", path: "")
        var totals = Stats()
        for change in changes {
            let parts = change.path.split(separator: "/").map(String.init)
            guard let fileName = parts.last else { continue }
            var cursor = root
            var prefix = ""
            for part in parts.dropLast() {
                prefix += (prefix.isEmpty ? "" : "/") + part
                if let next = cursor.dirs[part] { cursor = next } else {
                    let next = Builder(name: part, path: prefix)
                    cursor.dirs[part] = next
                    cursor = next
                }
            }
            let stats = fileStats(change)
            totals = merged(totals, stats)
            cursor.files.append(Node(name: fileName, path: parts.joined(separator: "/"), isDirectory: false,
                                     stats: stats, kind: change.kind, children: []))
        }
        return ChangedFilesTree(roots: finish(root).children, totals: totals)
    }

    private static func fileStats(_ change: FileStat) -> Stats {
        Stats(added: change.added ?? 0, removed: change.removed ?? 0, fileCount: 1,
              hasNumbers: change.added != nil || change.removed != nil)
    }

    private static func merged(_ a: Stats, _ b: Stats) -> Stats {
        Stats(added: a.added + b.added, removed: a.removed + b.removed, fileCount: a.fileCount + b.fileCount,
              hasNumbers: a.hasNumbers || b.hasNumbers)
    }

    private static func finish(_ builder: Builder) -> Node {
        var children = builder.dirs.values.map(finish) + builder.files
        children.sort(by: order)
        var node = Node(name: builder.name, path: builder.path, isDirectory: true,
                        stats: children.reduce(Stats()) { merged($0, $1.stats) }, kind: nil, children: children)
        // Collapse only chains of directories: a lone file keeps its own row.
        while node.children.count == 1, node.children[0].isDirectory, !node.path.isEmpty {
            let only = node.children[0]
            node = Node(name: node.name + "/" + only.name, path: only.path, isDirectory: true, stats: only.stats,
                        kind: nil, children: only.children)
        }
        return node
    }

    private static func order(_ a: Node, _ b: Node) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        let x = a.name.lowercased(), y = b.name.lowercased()
        return x == y ? a.name < b.name : x < y
    }

    /// Visible rows; a directory shows its children only while its path is in `expanded`.
    func flatten(expanded: Set<String>) -> [Row] {
        var rows: [Row] = []
        func walk(_ nodes: [Node], depth: Int) {
            for node in nodes {
                rows.append(Row(depth: depth, isDirectory: node.isDirectory, name: node.name, path: node.path,
                                stats: node.stats, kind: node.kind))
                if node.isDirectory, expanded.contains(node.path) { walk(node.children, depth: depth + 1) }
            }
        }
        walk(roots, depth: 0)
        return rows
    }

    var expandAll: Set<String> {
        var paths = Set<String>()
        func walk(_ nodes: [Node]) {
            for node in nodes where node.isDirectory { paths.insert(node.path); walk(node.children) }
        }
        walk(roots)
        return paths
    }

    var collapseAll: Set<String> { [] }
}
