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

/// Whether the startup disk runs out of room. On 2026-11-09 agent worktrees filled a 1 TB disk to the last byte and
/// nothing said so; now Nook says it in time, and first frees what is safe to free (`WorkspaceManager.watchDiskSpace`).
enum DiskSpace {
    /// Below this much free space Nook warns.
    static let lowBytes: Int64 = 25_000_000_000
    /// It warns again only after the free space came back above this, so a disk hovering at the limit says it once.
    static let recoveredBytes: Int64 = 40_000_000_000

    /// Free space on the volume of `url` as macOS counts it for things you need (purgeable space included).
    static func available(at url: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// Whether the disk counts as low now, given whether it did before (`recoveredBytes` gives the margin).
    static func isLow(available: Int64, wasLow: Bool) -> Bool {
        wasLow ? available < recoveredBytes : available < lowBytes
    }
}
