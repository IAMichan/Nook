import Foundation

/// How much disk a folder takes, and removing what Nook left in a folder of its own that macOS never cleans.
/// A worktree holds its own build (often several GB), so the Worktrees list shows this next to each one.
enum DiskUsage {
    /// Bytes allocated on disk under `path`, without following symbolic links; nil when it cannot be read.
    static func allocatedSize(of path: String) -> Int64? {
        let root = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                                         errorHandler: { _, _ in true }) else { return nil }
        var total: Int64 = 0
        for case let url as URL in items {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Removes the entries directly in `directory` that were not modified since `age` ago. For a temporary folder Nook
    /// hands to an agent as TMPDIR: unlike the system's, nobody else ever empties it. Returns the names it removed.
    @discardableResult
    static func purge(_ directory: URL, olderThan age: TimeInterval, now: Date = Date()) -> [String] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                             options: []) else { return [] }
        var removed: [String] = []
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            guard now.timeIntervalSince(modified) > age, (try? manager.removeItem(at: entry)) != nil else { continue }
            removed.append(entry.lastPathComponent)
        }
        return removed
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
