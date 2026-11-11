import Foundation

/// The files of a directory with their date and size, read again only where something can have changed.
///
/// A directory whose own modification date is the one of the last listing holds the same files (adding, removing or
/// renaming one changes it): only those files are looked at again, one `stat` each, without listing the directory.
/// Listing every folder of ~/.claude/projects (one per worktree, some 1,300) every 30 seconds took a third of a second of
/// a core while nothing changed (`HistoryScanner`). Not thread-safe: its owner reads it under its own lock.
final class DirectoryListing {
    struct Stamp: Equatable, Codable {
        var modified: Date
        var size: Int
    }

    /// Every entry last listed per directory (unfiltered: callers may ask for different names), with the directory's own
    /// date then.
    private var known: [String: (modified: Date, files: [URL])] = [:]

    /// The files in `directory` whose name passes `include`, with their date and size; empty when it cannot be read.
    func files(in directory: URL, where include: (String) -> Bool) -> [(url: URL, stamp: Stamp)] {
        let path = directory.path
        let directoryModified = Self.stamp(path)?.modified
        let entries: [URL]
        if let directoryModified, let listed = known[path], listed.modified == directoryModified {
            entries = listed.files
        } else {
            guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                known[path] = nil
                return []
            }
            entries = urls
            if let directoryModified { known[path] = (directoryModified, urls) }
        }
        // One `stat` per file either way: a date read another way may differ in its last digit, and a caller keyed on the
        // stamp would take an unchanged file for a new one.
        return entries.compactMap { url in include(url.lastPathComponent) ? Self.stamp(url.path).map { (url, $0) } : nil }
    }

    /// Date and size of a file or directory from one `stat`; nil when it is gone.
    static func stamp(_ path: String) -> Stamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        #if canImport(Darwin)
        let time = info.st_mtimespec
        #else
        let time = info.st_mtim  // Glibc's name (the core tests on Linux)
        #endif
        return Stamp(modified: Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9),
                     size: Int(info.st_size))
    }
}
