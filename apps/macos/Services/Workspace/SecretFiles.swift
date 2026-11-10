import Foundation

/// Private files that carry a secret to an agent's shell commands without the agent ever reading the value: the agent
/// gets only the path and uses it as `"$(cat '<path>')"`, so the value never enters its transcript, its context or Nook's
/// timeline.
///
/// Every file lives in Nook's own support folder (never in a project), in one folder per session. Folders are 0700 and
/// files 0600, written under a temporary name opened with `O_EXCL | O_NOFOLLOW` and renamed into place, so a planted link
/// is never followed. A file goes after `lifetime`, when its session is archived or deleted, when Nook quits, and on the
/// next launch (`removeAll`), whichever comes first.
struct SecretFiles: Sendable {
    /// How long a delivered secret stays readable.
    static let lifetime: TimeInterval = 24 * 60 * 60

    /// The scope of secrets pasted in a composer that has no session id yet (a new session, an agent's own session).
    static let composerScope = "composer"

    /// The folder that holds one folder per session.
    let root: URL

    /// Nook's own: `~/Library/Application Support/Nook/agent-secrets`.
    static var standard: SecretFiles {
        SecretFiles(root: NookPaths.supportDirectory.appendingPathComponent("agent-secrets", isDirectory: true))
    }

    enum Failure: Error, Equatable {
        case invalidName
        case unsafeFolder
        case write(Int32)
    }

    /// A session's folder name: a run id, or a short tag for callers without one. Anything else becomes "_".
    static func scope(_ raw: String) -> String {
        let cleaned = String(raw.prefix(80).map { $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) ? $0 : "_" })
        return cleaned.isEmpty ? "_" : cleaned
    }

    /// The scope for a caller Nook did not start (an agent in your own terminal): one per folder, so two projects never
    /// share a file, and the folder path itself never shows in the file's path.
    static func folderScope(_ directory: String) -> String {
        // FNV-1a: stable across launches (Swift's own hash is not), and only used to keep folders apart.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in directory.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "folder-" + String(hash, radix: 16)
    }

    /// Where `name` of `scope` is (or would be) delivered.
    func url(name: String, scope: String) -> URL {
        root.appendingPathComponent(Self.scope(scope), isDirectory: true).appendingPathComponent(name)
    }

    /// Writes `value` (exactly, no newline added) for `name` in `scope` and returns its path. A second delivery of the same
    /// name replaces the first in one step, so a command that reads it never sees half a value.
    @discardableResult
    func write(_ value: String, name: String, scope: String) throws -> URL {
        guard Self.isValidName(name) else { throw Failure.invalidName }
        let folder = root.appendingPathComponent(Self.scope(scope), isDirectory: true)
        try privateFolder(root)
        try privateFolder(folder)
        let final = folder.appendingPathComponent(name)
        let partial = folder.appendingPathComponent(name + ".partial")
        unlink(partial.path)
        let fd = open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.write(errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        do {
            try handle.write(contentsOf: Data(value.utf8))
        } catch {
            close(fd)
            unlink(partial.path)
            throw Failure.write(EIO)
        }
        // The mode asked for at open() is masked by the umask: set it outright.
        fchmod(fd, 0o600)
        close(fd)
        guard rename(partial.path, final.path) == 0 else {
            let error = errno
            unlink(partial.path)
            throw Failure.write(error)
        }
        return final
    }

    /// Removes every file of one session.
    func remove(scope: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(Self.scope(scope), isDirectory: true))
    }

    /// Removes every delivered secret (quit, next launch).
    func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Removes the files older than `lifetime`, and folders left empty. Returns when the next file runs out, if any.
    @discardableResult
    func sweep(now: Date = Date()) -> Date? {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        var next: Date?
        for folder in folders {
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            var left = 0
            for file in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let expiry = modified.addingTimeInterval(Self.lifetime)
                if expiry <= now {
                    try? fm.removeItem(at: file)
                } else {
                    left += 1
                    next = min(next ?? expiry, expiry)
                }
            }
            if left == 0 { try? fm.removeItem(at: folder) }
        }
        return next
    }

    /// The text an agent gets instead of the value: where it is and how to use it, never the value itself.
    static func instructions(name: String, path: String) -> String {
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        Nook saved \(name) in a private file that only the user's account can read: \(path)
        Use it in shell commands without reading it, for example `export \(name)="$(cat \(quoted))"` or \
        `curl -H "Authorization: Bearer $(cat \(quoted))" …`. Never print, echo or cat it on its own, never copy it into \
        the repository or a log, and do not ask the user for the value. The file is deleted after 24 hours, when this \
        session ends or when Nook quits; ask again with request_secret if you need it after that.
        """
    }

    /// Same rule as a secret's name (`BridgeSecret.name`), checked again so a path can never climb out of its folder.
    static func isValidName(_ name: String) -> Bool {
        (1...64).contains(name.count) && name.first != "." && !name.contains("..")
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// Creates `url` as a folder only this user may enter, and refuses one that is a link or someone else's.
    private func privateFolder(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw Failure.write(errno) }
            guard lstat(url.path, &info) == 0 else { throw Failure.write(errno) }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw Failure.unsafeFolder }
        if (info.st_mode & 0o777) != 0o700 { chmod(url.path, 0o700) }
    }
}
