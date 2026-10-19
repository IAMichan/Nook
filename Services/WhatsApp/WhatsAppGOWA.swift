// GOWA, the local WhatsApp gateway, run by Nook: installed with one click from GOWA's own GitHub releases (SHA-256
// checked), started as a child of Nook on 127.0.0.1 only, stopped when Nook quits.
//
// Adapted from open-source code under the MIT License, Copyright (c) 2026 Louis Raillé (see THIRD-PARTY-NOTICES.md).

import Foundation
import Combine
import CryptoKit

/// GOWA launched by Nook ("Start GOWA automatically" in Settings).
@MainActor
final class WhatsAppGOWAProcess {
    static let shared = WhatsAppGOWAProcess()

    private var process: Process?
    private var lastStart: Date = .distantPast

    static var autoStart: Bool {
        get { UserDefaults.standard.bool(forKey: "whatsappAutoStartGOWA") }
        set { UserDefaults.standard.set(newValue, forKey: "whatsappAutoStartGOWA") }
    }

    /// The binary's path (not a secret: UserDefaults).
    static var binaryPath: String {
        get { UserDefaults.standard.string(forKey: "whatsappGOWAPath") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "whatsappGOWAPath") }
    }

    var isRunning: Bool { process?.isRunning == true }

    /// Where GOWA keeps its own WhatsApp session (its database, not Nook's): one folder in
    /// Application Support, so the link survives restarts.
    nonisolated static var workingDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Nook/GOWA", isDirectory: true)
    }

    /// What the running GOWA was started with: changed, it is restarted; same, left alone.
    private var launchedWith: String?

    /// Brings GOWA in line with Settings: started when "Start GOWA automatically" is on (and
    /// the gateway is GOWA on this Mac), restarted only when its binary, address or password
    /// changed, stopped when the option is off. A GOWA that keeps dying is started again once
    /// a minute at most. Returns false when it can't run.
    @discardableResult
    func sync() -> Bool {
        guard Self.autoStart, WhatsAppSettings.gateway == .gowa else { stopNow(); return false }
        let path = (Self.binaryPath as NSString).expandingTildeInPath
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path),
              let url = URL(string: WhatsAppSettings.url) else {
            Log.connectors.info("WhatsApp: GOWA binary missing or not executable")
            stopNow()
            return false
        }
        // Only ever on this Mac: an address elsewhere is someone else's gateway.
        guard ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else { stopNow(); return false }
        let credential = (WhatsAppSettings.credential ?? "")
        let signature = [path, url.absoluteString, credential].joined(separator: "\u{1F}")
        if isRunning {
            if launchedWith == signature { return true }
            stopNow()   // waits for it to let go of the port and its database
        } else if launchedWith == signature, Date().timeIntervalSince(lastStart) < 60 {
            return true
        }
        try? FileManager.default.createDirectory(at: Self.workingDirectory, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = WAGOWA.launchArguments(for: url)
        p.currentDirectoryURL = Self.workingDirectory
        var env = ProcessInfo.processInfo.environment
        // The credential goes through the environment, not the command line (`ps` shows that).
        if credential.contains(":") { env["APP_BASIC_AUTH"] = credential }
        // GOWA's own web dashboard is not needed (Nook is the interface): it would fetch
        // itself from GitHub at each start.
        env["APP_UI_ENABLED"] = "false"
        p.environment = env
        // GOWA's own output may name contacts or quote messages: it goes nowhere.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                Log.connectors.info("WhatsApp: GOWA exited (\(status))")
            }
        }
        do {
            try p.run()
            process = p
            lastStart = Date()
            launchedWith = signature
            Log.connectors.info("WhatsApp: GOWA started (pid \(p.processIdentifier))")
            return true
        } catch {
            Log.connectors.info("WhatsApp: GOWA could not start: \(error.localizedDescription)")
            return false
        }
    }

    /// Stops GOWA if Nook started it, waiting a second at most for it to go (at quit, or
    /// before starting it again so two never share its database).
    func stopNow() {
        launchedWith = nil
        guard let p = process else { return }
        guard p.isRunning else { process = nil; return }
        p.terminate()
        let deadline = Date().addingTimeInterval(1)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        process = nil
    }
}

@MainActor
final class WhatsAppGOWAInstaller: ObservableObject {
    static let shared = WhatsAppGOWAInstaller()

    enum Step: Equatable {
        case idle
        case checking
        case downloading(megabytes: Int)
        case verifying
        case installing
        case done(version: String)
        case failed(String)
    }

    @Published private(set) var step: Step = .idle

    var busy: Bool {
        switch step {
        case .checking, .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    /// GOWA's version once installed by Nook (not a secret: UserDefaults).
    static var installedVersion: String? {
        get { UserDefaults.standard.string(forKey: "whatsappGOWAVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "whatsappGOWAVersion") }
    }

    /// Where Nook keeps the binary it installed.
    static var binaryURL: URL { WhatsAppGOWAProcess.workingDirectory.appendingPathComponent("gowa") }

    /// A gateway Nook can start: the one it installed, or one the user picked.
    static var isInstalled: Bool {
        let path = (WhatsAppGOWAProcess.binaryPath as NSString).expandingTildeInPath
        return !path.isEmpty && FileManager.default.isExecutableFile(atPath: path)
    }

    static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config, delegate: GitHubOnly(), delegateQueue: nil)
    }()

    func install() {
        guard !busy else { return }
        step = .checking
        Task { await run() }
    }

    private func run() async {
        do {
            // 1. Which build: GOWA's latest release, the zip for this Mac.
            var req = URLRequest(url: WAGOWARelease.latestURL)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (meta, metaResponse) = try await session.data(for: req)
            guard (metaResponse as? HTTPURLResponse)?.statusCode == 200,
                  let release = WAGOWARelease.parse(meta),
                  let picked = WAGOWARelease.pick(release.assets, arch: Self.arch) else {
                throw Failure(tr("whatsapp.install.no-build"))
            }
            var checksums: String? = nil
            if let sums = picked.checksums {
                let (data, _) = try await session.data(from: sums.url)
                checksums = String(data: data, encoding: .utf8)
            }
            guard let expected = WAGOWARelease.expectedSHA256(for: picked.zip, checksums: checksums) else {
                throw Failure(tr("whatsapp.install.no-checksum"))
            }

            // 2. Download.
            step = .downloading(megabytes: max(1, picked.zip.size / 1_000_000))
            let (tmp, zipResponse) = try await session.download(from: picked.zip.url)
            guard (zipResponse as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(tr("whatsapp.install.download-failed")) }

            // 3. Verify: exactly the file GOWA published.
            step = .verifying
            let digest = try await Task.detached { () throws -> String in
                let data = try Data(contentsOf: tmp)
                return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }.value
            guard digest == expected else {
                try? FileManager.default.removeItem(at: tmp)
                throw Failure(tr("whatsapp.install.bad-checksum"))
            }

            // 4. Unzip with macOS's own ditto, put the binary in place, make it runnable.
            step = .installing
            let version = release.version
            let binary = WAGOWARelease.binaryName(arch: Self.arch)
            try await Task.detached {
                try Self.unpack(zip: tmp, binaryName: binary)
            }.value
            Self.installedVersion = version
            WhatsAppSettings.gateway = .gowa
            WhatsAppSettings.url = ""   // back to http://127.0.0.1:3000
            WhatsAppGOWAProcess.binaryPath = Self.binaryURL.path
            WhatsAppGOWAProcess.autoStart = true
            WhatsAppGOWAProcess.shared.stopNow()                     // an older one gives way
            WhatsAppLink.shared.settingsChanged()              // starts it; the QR follows
            step = .done(version: version)
            Log.connectors.info("WhatsApp: GOWA \(version) installed (\(Self.arch))")
        } catch let failure as Failure {
            step = .failed(failure.message)
            Log.connectors.info("WhatsApp: GOWA install failed: \(failure.message)")
        } catch {
            step = .failed(tr("whatsapp.install.download-failed"))
            Log.connectors.info("WhatsApp: GOWA install failed: \(error.localizedDescription)")
        }
    }

    private struct Failure: Error { let message: String; init(_ m: String) { message = m } }

    /// Unzips into a temporary folder, then moves `binaryName` to the GOWA folder as `gowa`.
    nonisolated private static func unpack(zip: URL, binaryName: String) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("nook-gowa-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work); try? fm.removeItem(at: zip) }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, work.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw Failure(tr("whatsapp.install.unzip-failed")) }

        guard let found = fm.enumerator(at: work, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == binaryName }) else {
            throw Failure(tr("whatsapp.install.no-build"))
        }
        try fm.createDirectory(at: WhatsAppGOWAProcess.workingDirectory, withIntermediateDirectories: true)
        let dest = WhatsAppGOWAProcess.workingDirectory.appendingPathComponent("gowa")
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: found, to: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        // Downloaded by Nook itself, it carries no quarantine; cleared anyway so macOS never
        // asks the user to allow it in System Settings.
        removexattr(dest.path, "com.apple.quarantine", 0)
    }
}

/// The download follows GitHub's redirect to its asset storage, and nothing else.
private final class GitHubOnly: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(WAGOWARelease.allowedHost(request.url?.host) ? request : nil)
    }
}
