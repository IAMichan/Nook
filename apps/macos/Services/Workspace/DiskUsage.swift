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
        let keySet = Set(keys)
        var total: Int64 = 0
        var done = false
        // A worktree with its build holds hundreds of thousands of files; every URL is autoreleased, so drain in batches.
        while !done {
            autoreleasepool {
                for _ in 0..<2_000 {
                    guard let url = items.nextObject() as? URL else { done = true; return }
                    guard let values = try? url.resourceValues(forKeys: keySet), values.isRegularFile == true else { continue }
                    total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                }
            }
        }
        return total
    }

    /// How long a size measured for the Worktrees list stays good. Measuring walks every file of a worktree and its build
    /// (hundreds of thousands), so measuring each worktree on every refresh kept a core busy for minutes at a time.
    static let cachedSizeAge: TimeInterval = 15 * 60

    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cache: [String: (bytes: Int64?, at: Date)] = [:]

    /// `allocatedSize(of:)`, measured again only when the last measurement of `path` is older than `maxAge`.
    static func cachedAllocatedSize(of path: String, maxAge: TimeInterval = cachedSizeAge, now: Date = Date()) -> Int64? {
        cacheLock.lock()
        let known = cache[path]
        cacheLock.unlock()
        if let known, now.timeIntervalSince(known.at) < maxAge { return known.bytes }
        let bytes = allocatedSize(of: path)
        cacheLock.lock()
        cache[path] = (bytes, now)
        cacheLock.unlock()
        return bytes
    }

    /// The last size measured for `path`, however old; nil when it was never measured. Measures nothing.
    static func knownSize(of path: String) -> Int64? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[path]?.bytes ?? nil
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

/// Whether a Worktrees list is open, readable from the background refresh that measures worktree sizes
/// (`WorkspaceManager.worktreesShown`).
final class WorktreeListFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false

    var isOpen: Bool {
        get { lock.lock(); defer { lock.unlock() }; return open }
        set { lock.lock(); open = newValue; lock.unlock() }
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
