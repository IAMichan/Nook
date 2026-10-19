import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Installs an ACP agent that the registry offers only as a download: fetched over HTTPS, checked
/// against the registry's SHA-256 before anything is unpacked, unpacked with the system's own tools into a folder of its
/// own in Application Support, and only then made into an account. Nothing runs during the install.
enum AcpInstaller {
    enum Failure: LocalizedError {
        case notDownloadable
        case download(Int)
        case tooLarge
        case checksum
        case unpack(String)
        case programMissing

        var errorDescription: String? {
            switch self {
            case .notDownloadable: return tr("acp.install.notDownloadable")
            case .download(let status): return tr("acp.install.download", status)
            case .tooLarge: return tr("acp.install.tooLarge")
            case .checksum: return tr("acp.install.checksum")
            case .unpack(let detail): return tr("acp.install.unpack", detail)
            case .programMissing: return tr("acp.install.programMissing")
            }
        }
    }

    static let maxBytes: Int64 = 1024 * 1024 * 1024

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nook/AcpAgents", isDirectory: true)
    }

    /// Downloads, checks and unpacks the entry's program; returns the folder it is in.
    static func install(_ entry: AcpRegistry.Entry, session: URLSession = .shared) async throws -> String {
        guard let binary = entry.binary else { throw Failure.notDownloadable }
        var request = URLRequest(url: binary.archive)
        request.timeoutInterval = 120
        let (downloaded, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.download(status) }
        return try await Task.detached(priority: .userInitiated) {
            try place(downloaded, binary: binary, id: entry.id, version: entry.version)
        }.value
    }

    /// Everything after the download, off the main thread: check, unpack into a fresh folder, then move it into place.
    private static func place(_ file: URL, binary: AcpRegistry.Binary, id: String, version: String) throws -> String {
        let manager = FileManager.default
        let size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= maxBytes else { throw Failure.tooLarge }
        guard try sha256(of: file) == binary.sha256 else { throw Failure.checksum }

        let safeVersion = version.replacingOccurrences(of: "/", with: "_")
        let target = root.appendingPathComponent(id, isDirectory: true).appendingPathComponent(safeVersion, isDirectory: true)
        let staging = root.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        var relative = binary.command
        while relative.hasPrefix("./") { relative.removeFirst(2) }
        switch binary.kind {
        case .zip:
            try unpack("/usr/bin/ditto", ["-x", "-k", file.path, staging.path])
        case .tar:
            try unpack("/usr/bin/tar", ["-xf", file.path, "-C", staging.path])
        case .raw:
            let destination = staging.appendingPathComponent(relative)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: file, to: destination)
        }

        // The program has to be a file inside the folder, also after following links.
        let program = staging.appendingPathComponent(relative)
        let resolved = program.resolvingSymlinksInPath().standardizedFileURL.path
        let base = staging.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var isDirectory: ObjCBool = false
        guard resolved.hasPrefix(base), manager.fileExists(atPath: resolved, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw Failure.programMissing
        }
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resolved)

        if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: staging, to: target)
        return target.path
    }

    /// Removes a folder this installer made (and its agent's folder once empty); anything else is left alone.
    static func uninstall(_ folder: String) {
        let manager = FileManager.default
        let base = root.standardizedFileURL.path + "/"
        let url = URL(fileURLWithPath: folder).standardizedFileURL
        guard url.path.hasPrefix(base) else { return }
        try? manager.removeItem(at: url)
        let parent = url.deletingLastPathComponent()
        if parent.path.hasPrefix(base), (try? manager.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
            try? manager.removeItem(at: parent)
        }
    }

    private static func unpack(_ tool: String, _ arguments: [String]) throws {
        let output = try ProcessRunner.run(tool, arguments, timeout: 300)
        guard output.status == 0, !output.timedOut else {
            throw Failure.unpack(String(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)))
        }
    }

    private static func sha256(of file: URL) throws -> String {
        #if canImport(CryptoKit)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        throw Failure.checksum
        #endif
    }
}
