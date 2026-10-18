import CryptoKit
import Foundation

/// Installs Google's Antigravity ACP server: the pinned release for this Mac, checked on size and
/// SHA-256 before anything is unpacked, exactly the two expected files of the expected sizes, a test start that must
/// answer as Antigravity with Google sign-in, and only then made active. Nothing is installed when a step fails.
@MainActor
final class AntigravityInstaller: ObservableObject {
    static let shared = AntigravityInstaller()

    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case verifying
        case unpacking
        case checking
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Bumped after an install or removal, so views look again.
    @Published private(set) var revision = 0
    private var observation: NSKeyValueObservation?
    let paths = AntigravityPaths(support: NookPaths.supportDirectory)
    /// Read from disk once, and again after an install or removal (views ask often).
    private(set) var installed: (executable: String, harness: String)?

    private init() {
        installed = paths.installed()
    }

    var isBusy: Bool {
        switch phase {
        case .downloading, .verifying, .unpacking, .checking: return true
        case .idle, .failed: return false
        }
    }

    func install() {
        guard !isBusy else { return }
        guard let asset = AntigravityRelease.current else {
            phase = .failed(tr("ws.antigravity.unsupported"))
            return
        }
        phase = .downloading(0)
        Task {
            do {
                try await run(asset)
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
            observation?.invalidate()
            observation = nil
            installed = paths.installed()
            revision += 1
        }
    }

    func uninstall() {
        guard !isBusy else { return }
        try? FileManager.default.removeItem(at: paths.tools)
        phase = .idle
        installed = nil
        revision += 1
    }

    // MARK: Steps

    private func run(_ asset: AntigravityRelease.Asset) async throws {
        let needed = Int64(asset.archiveBytes + asset.executable.bytes + asset.harness.bytes) + 100_000_000
        try FileManager.default.createDirectory(at: paths.versions(asset), withIntermediateDirectories: true)
        if let free = try? paths.tools.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < needed {
            throw NookError(tr("ws.antigravity.noSpace", ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)))
        }
        let archive = try await download(asset)
        defer { try? FileManager.default.removeItem(at: archive) }

        phase = .verifying
        let check = try await Task.detached(priority: .userInitiated) { try Self.sha256(of: archive) }.value
        guard check.bytes == asset.archiveBytes, check.digest == asset.sha256 else { throw NookError(tr("ws.antigravity.badDownload")) }

        phase = .unpacking
        let staging = paths.versions(asset).appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try await Task.detached(priority: .userInitiated) { try Self.unpack(archive, into: staging, asset: asset) }.value

        phase = .checking
        try await smokeTest(executable: staging.appendingPathComponent(asset.executable.name).path)

        let release = paths.release(asset)
        try? FileManager.default.removeItem(at: release)
        try FileManager.default.moveItem(at: staging, to: release)
        let record = try JSONSerialization.data(withJSONObject: ["releaseId": asset.sha256, "version": AntigravityRelease.version])
        try record.write(to: paths.active(asset), options: .atomic)
    }

    private func download(_ asset: AntigravityRelease.Asset) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: asset.url) { location, response, error in
                if let error { return continuation.resume(throwing: error) }
                guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return continuation.resume(throwing: NookError(tr("ws.antigravity.badDownload")))
                }
                // The downloaded file is removed when this handler returns: keep it first.
                let kept = FileManager.default.temporaryDirectory.appendingPathComponent("agy-acp-\(UUID().uuidString).zip")
                do {
                    try FileManager.default.moveItem(at: location, to: kept)
                    continuation.resume(returning: kept)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { @Sendable [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    if case .downloading = self?.phase { self?.phase = .downloading(fraction) }
                }
            }
            task.resume()
        }
    }

    nonisolated private static func sha256(of file: URL) throws -> (bytes: Int, digest: String) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            total += chunk.count
        }
        return (total, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Only the two expected files, flat, of exactly the pinned sizes; made executable.
    nonisolated private static func unpack(_ archive: URL, into folder: URL, asset: AntigravityRelease.Asset) throws {
        let list = try ProcessRunner.run("/usr/bin/unzip", ["-Z1", archive.path], in: nil, environment: nil, timeout: 60)
        let names = list.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard list.status == 0, Set(names) == [asset.executable.name, asset.harness.name], names.count == 2 else {
            throw NookError(tr("ws.antigravity.badArchive"))
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let unzip = try ProcessRunner.run("/usr/bin/unzip", ["-q", "-o", archive.path, "-d", folder.path], in: nil, environment: nil, timeout: 600)
        guard unzip.status == 0, !unzip.timedOut else { throw NookError(tr("ws.antigravity.badArchive")) }
        let files = try names.map { name -> AntigravityRelease.Member in
            let path = folder.appendingPathComponent(name).path
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard (attributes[.type] as? FileAttributeType) == .typeRegular else { throw NookError(tr("ws.antigravity.badArchive")) }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return AntigravityRelease.Member(name: name, bytes: (attributes[.size] as? NSNumber)?.intValue ?? -1)
        }
        guard AntigravityRelease.verify(files, asset: asset) else { throw NookError(tr("ws.antigravity.badArchive")) }
    }

    /// A test start in a throwaway profile: `initialize` must answer as Antigravity, with Google sign-in.
    private func smokeTest(executable: String) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("nook-agy-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let harness = URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent(AntigravityRelease.current?.harness.name ?? "").path
        var environment = AntigravityAcp.environment(profile: scratch.path, harness: harness, browserHelper: "/usr/bin/true", temp: scratch.path)
        environment["BROWSER"] = "/usr/bin/true"
        var spec = LaunchSpec(executable: executable, arguments: [], extraEnvironment: environment, workingDirectory: scratch.path,
                              initialInput: [], keepsInputOpen: true)
        spec.removedEnvironment = AntigravityAcp.removedEnvironment
        let client = AcpClient(spec: spec)
        try client.start()
        defer { client.stop() }
        let answer: [String: Any]? = await withCheckedContinuation { continuation in
            let once = Once()
            client.request("initialize", AcpRPC.initializeParams()) { result in
                if once.claim() { continuation.resume(returning: (try? result.get())?.dictionary) }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
        guard let answer, AntigravityAcp.looksInstalled(answer) else { throw NookError(tr("ws.antigravity.checkFailed")) }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }
}
