import Foundation
import Security

/// Nook's own chat helper, nook-chatd (apps/chatd, built by scripts/build-chatd.sh and copied into
/// Nook.app/Contents/Helpers): it links Telegram, Signal, Messenger, Instagram, X, LinkedIn and Slack on this Mac
/// on its own, and answers the local API that `ChatLinker` and `ChatServiceBridge` read.
/// Nook starts it as its child on 127.0.0.1 with a fresh token each time, and it stops when Nook quits (or by itself when
/// Nook is gone). Its linked accounts and chats stay in Application Support/Nook/ChatHelper.
@MainActor
final class ChatHelper: ObservableObject {
    static let shared = ChatHelper()

    /// It answers on its port: the chat service is Nook's own.
    @Published private(set) var isRunning = false
    /// Why it did not start, in its own words; nil while it runs or was never tried.
    @Published private(set) var problem: String?

    // Nonisolated: `answers(at:)` uses `base` as a default argument, which is evaluated outside the main actor.
    nonisolated static let port = 29373
    nonisolated static let base = URL(string: "http://127.0.0.1:\(port)")!
    /// A new one every start, kept only in memory: only this Nook can use the helper.
    private(set) var token: String?
    private var process: Process?
    private var starting: Task<Bool, Never>?

    /// Where the helper is in this build of Nook; nil when scripts/build-chatd.sh was not run before building.
    static var binary: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/nook-chatd")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var isBuilt: Bool { binary != nil }

    /// An account of this app is linked through the helper.
    static func linked(_ app: String) -> Bool {
        shared.isRunning && ChatLinker.shared.networks.contains { $0.app == app && !$0.accounts.isEmpty }
    }

    /// The helper runs and links this app: one built before it had an app (Slack) does not.
    static func offers(_ app: String) -> Bool {
        shared.isRunning && ChatLinker.shared.networks.contains { $0.app == app && $0.canLink }
    }

    /// The apps the helper links.
    static let apps: Set<String> = ["telegram", "signal", "messenger", "instagram", "x", "linkedin", "slack"]
    /// The apps whose terms forbid other clients and that do restrict accounts for it: linking them says so first.
    static let riskyApps: Set<String> = ["messenger", "instagram", "x", "linkedin"]

    static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nook/ChatHelper", isDirectory: true)
    }

    /// Starts the helper when it is not running yet and waits until it answers (half a minute at most). True once it runs.
    @discardableResult
    func start() async -> Bool {
        if isRunning, process?.isRunning == true { return true }
        if let starting { return await starting.value }
        let task = Task { await launch() }
        starting = task
        let running = await task.value
        starting = nil
        return running
    }

    private func launch() async -> Bool {
        guard let binary = Self.binary else { return false }
        stop()
        guard let token = Self.newToken() else { return false }
        try? FileManager.default.createDirectory(at: Self.dataDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let p = Process()
        p.executableURL = binary
        p.arguments = ["-addr", "127.0.0.1:\(Self.port)", "-data", Self.dataDirectory.path]
        var env = ProcessInfo.processInfo.environment
        // The token goes through the environment, not the command line (`ps` shows that).
        env["NOOK_CHATD_TOKEN"] = token
        // Telegram logs in with an app id and hash: the ones this build comes with, or your own from Settings.
        if let keys = TelegramBridge.keys {
            env["NOOK_TELEGRAM_API_ID"] = String(keys.id)
            env["NOOK_TELEGRAM_API_HASH"] = keys.hash
        }
        p.environment = env
        // Its output may name contacts or quote messages: it goes nowhere.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                Log.connectors.info("Chats: nook-chatd exited (\(status))")
                guard ChatHelper.shared.process === proc else { return }
                ChatHelper.shared.process = nil
                ChatHelper.shared.isRunning = false
            }
        }
        do {
            try p.run()
        } catch {
            problem = error.localizedDescription
            return false
        }
        process = p
        self.token = token
        Log.connectors.info("Chats: nook-chatd started (pid \(p.processIdentifier))")
        let end = Date().addingTimeInterval(30)
        while Date() < end, p.isRunning {
            if await Self.answers() {
                isRunning = true
                problem = nil
                return true
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        problem = p.isRunning ? tr("chats.service.unreachable") : "exit \(p.terminationStatus)"
        stop()
        return false
    }

    /// Stops the helper if Nook started it (at quit), waiting two seconds at most.
    func stop() {
        isRunning = false
        token = nil
        guard let p = process else { return }
        process = nil
        guard p.isRunning else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    /// Whether a chat service answers at `base`: its info needs no token.
    static func answers(at base: URL = base) async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("v1/info"), timeoutInterval: 2)
        request.httpMethod = "GET"
        guard let (_, response) = try? await ConnectorHTTP.session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private static func newToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
