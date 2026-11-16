import Foundation

/// What a session's conversation still links to after its worktree is gone. Removing a worktree (after its pull request
/// merged, after it settled, or by hand) deletes its git-ignored `.scratch/` folder too, where agents put renders and
/// drafts for you (AGENTS.md §5). That folder is copied here first, so those links still open; committed files come
/// back from git instead (`WorkspaceManager.recoverFile`).
enum WorktreeArchive {
    /// The folder of drafts and renders meant for you, git-ignored in every worktree.
    static let scratch = ".scratch"
    /// A `.scratch` larger than this is not kept: it holds builds, not drafts.
    static let maxBytes: Int64 = 512 * 1024 * 1024
    /// Archives not touched for this long are removed when the next one is saved.
    static let keepFor: TimeInterval = 30 * 24 * 60 * 60
    /// All archives together stay under this; the ones saved longest ago go first (141 archives took 5.4 GB).
    static let maxTotalBytes: Int64 = 2 * 1024 * 1024 * 1024

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nook/Worktree archive", isDirectory: true)
    }

    /// Where a worktree's files are kept: its folder name plus a stable hash of its path (two repositories can have a
    /// worktree of the same name).
    static func location(worktree: String, root: URL = root) -> URL {
        let path = WorkspacePathPolicy.normalize(worktree)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let name = (path as NSString).lastPathComponent
        return root.appendingPathComponent("\(name)-\(String(hash, radix: 16))", isDirectory: true)
    }

    /// Copies the worktree's `.scratch` into its archive, over what an earlier removal of the same path kept. Returns
    /// false when there was nothing to keep or it was too large. What can be made again is left out (`isRebuildable`):
    /// a clone of another repository or a build an agent put there is not a draft, and took 550 MB per archive.
    @discardableResult
    static func save(worktree: String, root: URL = root, maxBytes: Int64 = maxBytes, maxTotalBytes: Int64 = maxTotalBytes,
                     now: Date = Date()) -> Bool {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: worktree).appendingPathComponent(scratch, isDirectory: true)
        guard fm.fileExists(atPath: source.path) else { return false }
        prune(root: root, now: now)
        // The enumerator can hand back paths with symbolic links resolved (`/private/var` for `/var`).
        let sourcePath = source.resolvingSymlinksInPath().path
        let files = keptFiles(in: source)
        guard !files.isEmpty, files.reduce(Int64(0), { $0 + $1.bytes }) <= maxBytes else { return false }
        let archive = location(worktree: worktree, root: root)
        let target = archive.appendingPathComponent(scratch, isDirectory: true)
        var saved = false
        for file in files {
            let filePath = file.url.resolvingSymlinksInPath().path
            guard filePath.hasPrefix(sourcePath + "/") else { continue }
            let relative = String(filePath.dropFirst(sourcePath.count + 1))
            let destination = target.appendingPathComponent(relative)
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            if (try? fm.copyItem(at: file.url, to: destination)) != nil { saved = true }
        }
        // The archive's date is when it was last saved, for `prune`.
        try? fm.setAttributes([.modificationDate: now], ofItemAtPath: archive.path)
        limit(root: root, to: maxTotalBytes, keeping: archive)
        return saved
    }

    /// The regular files of a `.scratch` worth keeping, with their sizes: not inside a folder `isRebuildable` names.
    static func keptFiles(in folder: URL) -> [(url: URL, bytes: Int64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return [] }
        var files: [(url: URL, bytes: Int64)] = []
        for case let item as URL in items {
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if isRebuildable(item) { items.skipDescendants() }
            } else if values.isRegularFile == true {
                files.append((item, Int64(values.fileSize ?? 0)))
            }
        }
        return files
    }

    /// A folder that is not a draft: a repository (it has `.git`), installed dependencies, or a build.
    static func isRebuildable(_ folder: URL) -> Bool {
        let name = folder.lastPathComponent
        if [".git", "node_modules", ".build", "DerivedData", "Pods"].contains(name) { return true }
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appendingPathComponent(".git").path)
            || fm.fileExists(atPath: folder.appendingPathComponent("info.plist").path)
            && BuildLeftovers.workspacePath(folder) != nil
    }

    /// Removes the archives saved longest ago until all of them together fit in `maxTotalBytes`; `keeping` (the one
    /// just saved) stays.
    static func limit(root: URL = root, to maxTotalBytes: Int64 = maxTotalBytes, keeping: URL? = nil) {
        let fm = FileManager.default
        guard let archives = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var sized = archives.map { archive in
            (url: archive, bytes: DiskUsage.allocatedSize(of: archive.path) ?? 0,
             date: (try? archive.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }
        var total = sized.reduce(Int64(0)) { $0 + $1.bytes }
        sized.sort { $0.date < $1.date }
        let kept = keeping.map { $0.standardizedFileURL.path }
        for archive in sized where total > maxTotalBytes && archive.url.standardizedFileURL.path != kept {
            guard (try? fm.removeItem(at: archive.url)) != nil else { continue }
            total -= archive.bytes
        }
    }

    /// The kept copy of a file that was in the worktree at `worktree`, when there is one.
    static func archived(_ path: String, worktree: String, root: URL = root) -> String? {
        guard let relative = relativePath(path, in: worktree) else { return nil }
        let copy = location(worktree: worktree, root: root).appendingPathComponent(relative).path
        return FileManager.default.fileExists(atPath: copy) ? copy : nil
    }

    /// `path` relative to `folder`, or nil when it is not inside it.
    static func relativePath(_ path: String, in folder: String) -> String? {
        let file = WorkspacePathPolicy.normalize(path)
        let base = WorkspacePathPolicy.normalize(folder)
        guard file.hasPrefix(base + "/") else { return nil }
        return String(file.dropFirst(base.count + 1))
    }

    /// The one file named `name` under `folder`'s `.scratch`: an agent often names a render it made there by its file
    /// name alone, which then resolves against the worktree's root. Nil when there is none or more than one.
    static func scratchFile(named name: String, in folder: String) -> String? {
        let base = URL(fileURLWithPath: folder).appendingPathComponent(scratch, isDirectory: true)
        guard !name.isEmpty, let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return nil }
        var found: String?
        for case let file as URL in files where file.lastPathComponent == name {
            guard found == nil else { return nil }
            found = file.path
        }
        return found
    }

    /// Removes archives not saved again for `keepFor`.
    static func prune(root: URL = root, now: Date = Date()) {
        let fm = FileManager.default
        guard let archives = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for archive in archives {
            guard let date = (try? archive.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(date) > keepFor else { continue }
            try? fm.removeItem(at: archive)
        }
    }
}
