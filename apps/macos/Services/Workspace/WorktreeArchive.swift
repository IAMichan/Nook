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
    static let keepFor: TimeInterval = 60 * 24 * 60 * 60

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
    /// false when there was nothing to keep or it was too large.
    @discardableResult
    static func save(worktree: String, root: URL = root, maxBytes: Int64 = maxBytes, now: Date = Date()) -> Bool {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: worktree).appendingPathComponent(scratch, isDirectory: true)
        guard fm.fileExists(atPath: source.path) else { return false }
        prune(root: root, now: now)
        guard size(of: source) <= maxBytes else { return false }
        let target = location(worktree: worktree, root: root).appendingPathComponent(scratch, isDirectory: true)
        guard let files = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
        var saved = false
        // The enumerator can hand back paths with symbolic links resolved (`/private/var` for `/var`).
        let sourcePath = source.resolvingSymlinksInPath().path
        for case let file as URL in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let filePath = file.resolvingSymlinksInPath().path
            guard filePath.hasPrefix(sourcePath + "/") else { continue }
            let relative = String(filePath.dropFirst(sourcePath.count + 1))
            let destination = target.appendingPathComponent(relative)
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            if (try? fm.copyItem(at: file, to: destination)) != nil { saved = true }
        }
        // The archive's date is when it was last saved, for `prune`.
        try? fm.setAttributes([.modificationDate: now], ofItemAtPath: location(worktree: worktree, root: root).path)
        return saved
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

    private static func size(of folder: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
