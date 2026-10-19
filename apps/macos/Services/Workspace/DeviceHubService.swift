import Foundation
import Combine
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Runs the device tools on this Mac (see DeviceHub): installs expo-device-hub and agent-device with npm into
/// Application Support (once, after you ask), starts the hub on a free loopback port, keeps it running, and hands agents
/// an agent-device command for the simulator they open. Simulators are never shut down behind your back.
@MainActor
final class DeviceHubService: ObservableObject {
    static let shared = DeviceHubService()

    enum State: Equatable {
        case idle
        /// No Xcode, or no Node.js: why, in words.
        case unavailable(String)
        case needsInstall
        case installing
        case starting
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var devices: [DeviceHub.Device] = []
    @Published private(set) var problem: String?

    private(set) var origin: URL?
    private var process: Process?
    private var startedAt = Date()
    private var restartDelay: TimeInterval = 0
    private var stopping = false
    private var node: String?
    private var npm: String?

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nook/DeviceTools", isDirectory: true)
    }

    private var toolsRoot: URL { Self.root.appendingPathComponent("tools", isDirectory: true) }
    private var stateDir: URL { Self.root.appendingPathComponent("state", isDirectory: true) }
    private var hubFolder: URL { DeviceHub.installFolder(root: toolsRoot, package: DeviceHub.hubPackage, version: DeviceHub.hubVersion) }
    private var agentFolder: URL { DeviceHub.installFolder(root: toolsRoot, package: DeviceHub.agentPackage, version: DeviceHub.agentVersion) }

    // MARK: Lifecycle

    /// Gets the hub running if it can without asking: installed tools start, missing ones wait for `install()`.
    func prepare() async {
        guard state == .idle || isFailed else { return }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else {
            state = .unavailable(tr("sim.hub.noXcode"))
            return
        }
        let tools = await Task.detached(priority: .utility) { (Self.locate("node"), Self.locate("npm")) }.value
        node = tools.0
        npm = tools.1
        guard node != nil else {
            state = .unavailable(tr("sim.hub.noNode"))
            return
        }
        guard installed(hubFolder, version: DeviceHub.hubVersion, entry: DeviceHub.hubEntry(hubFolder)) else {
            state = .needsInstall
            return
        }
        await start()
    }

    private var isFailed: Bool { if case .failed = state { return true } else { return false } }

    /// Installs both tools (npm, about a minute), then starts the hub.
    func install() async {
        guard let npm else { state = .unavailable(tr("sim.hub.noNode")); return }
        state = .installing
        let folders = [(DeviceHub.hubPackage, DeviceHub.hubVersion, hubFolder, DeviceHub.hubEntry(hubFolder)),
                       (DeviceHub.agentPackage, DeviceHub.agentVersion, agentFolder, DeviceHub.agentEntry(agentFolder))]
        for (package, version, folder, entry) in folders where !installed(folder, version: version, entry: entry) {
            let failure = await Task.detached(priority: .userInitiated) {
                Self.installPackage(npm: npm, package: package, version: version, folder: folder, entry: entry)
            }.value
            if let failure {
                state = .failed(failure)
                return
            }
        }
        await start()
    }

    private func installed(_ folder: URL, version: String, entry: URL) -> Bool {
        let sentinel = folder.appendingPathComponent(DeviceHub.sentinelName)
        return FileManager.default.fileExists(atPath: entry.path)
            && (try? String(contentsOf: sentinel, encoding: .utf8)) == DeviceHub.sentinel(version: version)
    }

    /// npm into a staging folder, checked, then moved into place: a half install never counts.
    nonisolated private static func installPackage(npm: String, package: String, version: String, folder: URL, entry: URL) -> String? {
        let manager = FileManager.default
        let parent = folder.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".staging-" + UUID().uuidString.prefix(8))
        do { try manager.createDirectory(at: staging, withIntermediateDirectories: true) } catch { return error.localizedDescription }
        defer { try? manager.removeItem(at: staging) }
        let arguments = DeviceHub.npmInstallArguments(prefix: staging.path, package: package, version: version)
        guard let output = try? ProcessRunner.run(npm, arguments, environment: loginEnvironment(), timeout: 600) else {
            return tr("sim.hub.npmFailed", package)
        }
        guard output.status == 0 else {
            let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400)
            return tr("sim.hub.npmFailed", package) + (detail.isEmpty ? "" : "\n" + detail)
        }
        let stagedEntry = staging.appendingPathComponent(entry.path.replacingOccurrences(of: folder.path + "/", with: ""))
        guard manager.fileExists(atPath: stagedEntry.path) else { return tr("sim.hub.npmFailed", package) }
        do {
            try Data(DeviceHub.sentinel(version: version).utf8).write(to: staging.appendingPathComponent(DeviceHub.sentinelName))
            if manager.fileExists(atPath: folder.path) { try manager.removeItem(at: folder) }
            try manager.moveItem(at: staging, to: folder)
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    /// Starts the hub and waits for `/readyz` (at most 30 s).
    func start() async {
        guard process == nil, let node else { return }
        state = .starting
        stopping = false
        // A `ps` (up to 5 s) and the login shell (up to 15 s): never on the main thread, which they used to block on every
        // start and automatic restart.
        let stateFile = stateDir.appendingPathComponent("hub.json")
        let loginEnvironment = await Task.detached(priority: .userInitiated) { () -> [String: String] in
            Self.stopStaleHub(file: stateFile)
            return Self.loginEnvironment()
        }.value
        // Stopped meanwhile, or another start got there first (everything from here to `self.process` runs without waiting).
        guard !stopping, process == nil else { return }
        let port = Self.freePort()
        let entry = DeviceHub.hubEntry(hubFolder).path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = DeviceHub.hubArguments(entry: entry, port: port)
        var environment = loginEnvironment
        for (key, value) in DeviceHub.quietEnvironment { environment[key] = value }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.hubExited() }
        }
        do { try process.run() } catch {
            state = .failed(error.localizedDescription)
            return
        }
        self.process = process
        startedAt = Date()
        let origin = URL(string: "http://127.0.0.1:\(port)")!
        self.origin = origin
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, self.process === process {
            if let (_, response) = try? await URLSession.shared.data(from: origin.appendingPathComponent("readyz")),
               let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) {
                writeHubState(pid: process.processIdentifier, port: port, entry: entry)
                state = .ready
                await refreshDevices()
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if self.process === process {
            stop()
            state = .failed(tr("sim.hub.notReady"))
        }
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
        origin = nil
        try? FileManager.default.removeItem(at: stateDir.appendingPathComponent("hub.json"))
        if state == .ready || state == .starting { state = .idle }
    }

    /// Gone without being asked: back after 1 s, doubling up to 30 s (back to 1 s once it had run a minute).
    private func hubExited() {
        process = nil
        origin = nil
        guard !stopping else { return }
        restartDelay = DeviceHub.restartDelay(previous: restartDelay, upFor: Date().timeIntervalSince(startedAt))
        state = .starting
        let delay = restartDelay
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.stopping, self.process == nil else { return }
            await self.start()
        }
    }

    private func writeHubState(pid: Int32, port: Int, entry: String) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let object: [String: Any] = ["pid": Int(pid), "port": port, "entryPath": entry]
        if let data = try? JSONSerialization.data(withJSONObject: object) { try? data.write(to: stateDir.appendingPathComponent("hub.json")) }
    }

    /// A hub left by an earlier Nook (it crashed): stopped, but only when that process really is the hub.
    nonisolated private static func stopStaleHub(file: URL) {
        defer { try? FileManager.default.removeItem(at: file) }
        guard let data = try? Data(contentsOf: file), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value, let entry = object["entryPath"] as? String, pid > 1 else { return }
        guard let output = try? ProcessRunner.run("/bin/ps", ["-o", "command=", "-p", String(pid)], timeout: 5),
              output.stdout.contains(entry) else { return }
        kill(pid, SIGTERM)
    }

    // MARK: The hub's API

    func refreshDevices() async {
        guard let data = try? await get(DeviceHub.devicesPath) else { return }
        let answer = DeviceHub.devices(data)
        devices = answer.devices
        problem = answer.problem
    }

    /// Boots the simulator when needed, then attaches serve-sim (booting alone does not start the stream).
    func open(_ udid: String) async throws {
        if let device = devices.first(where: { $0.id == udid }), !device.booted {
            let body: [String: Any] = ["platform": "ios", "id": udid, "name": device.name]
            let data = try await post(DeviceHub.bootPath, body: body, timeout: 180)
            let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if (answer?["ok"] as? Bool) != true {
                let message = (answer?["error"] as? String) ?? tr("sim.hub.bootFailed")
                switch DeviceHub.bootFailure(message) {
                case .diskSpace: throw NookError(tr("sim.hub.bootDisk"))
                case .timeout: throw NookError(tr("sim.hub.bootTimeout"))
                case .launchFailed: throw NookError(message)
                }
            }
        }
        _ = try await post(DeviceHub.startPath, body: ["udid": udid], timeout: 180)
        await refreshDevices()
    }

    func shutdown(_ udid: String) async {
        _ = try? await post(DeviceHub.shutdownPath, body: ["udid": udid], timeout: 60)
        await refreshDevices()
    }

    func screenshot(_ udid: String) async throws -> Data {
        let data = try await post(DeviceHub.screenshotPath(udid: udid), body: nil, timeout: 20)
        guard !data.isEmpty else { throw NookError(tr("sim.hub.screenshotFailed")) }
        return data
    }

    func url(_ path: String, websocket: Bool = false) -> URL? {
        guard let origin else { return nil }
        let base = websocket ? origin.absoluteString.replacingOccurrences(of: "http://", with: "ws://") : origin.absoluteString
        return URL(string: base + path)
    }

    private func get(_ path: String) async throws -> Data {
        guard let url = url(path) else { throw NookError(tr("sim.hub.notRunning")) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw NookError(tr("sim.hub.requestFailed"))
        }
        return data
    }

    private func post(_ path: String, body: [String: Any]?, timeout: TimeInterval) async throws -> Data {
        guard let url = url(path) else { throw NookError(tr("sim.hub.notRunning")) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw NookError(tr("sim.hub.requestFailed"))
        }
        return data
    }

    // MARK: agent-device for agents

    /// The command and flags an agent drives this simulator with: the daemon running, a config
    /// with its port and token, and a shim that refuses to run without them.
    func agentTarget(runID: String, udid: String) async throws -> (command: String, targetArgs: [String]) {
        guard let node else { throw NookError(tr("sim.hub.noNode")) }
        let entry = DeviceHub.agentEntry(agentFolder).path
        guard installed(agentFolder, version: DeviceHub.agentVersion, entry: DeviceHub.agentEntry(agentFolder)) else {
            throw NookError(tr("sim.hub.notInstalled"))
        }
        let agentState = stateDir.appendingPathComponent("agent-device", isDirectory: true)
        let daemon = try await Task.detached(priority: .userInitiated) {
            try Self.startDaemon(node: node, entry: entry, stateDir: agentState)
        }.value
        let hosts = stateDir.appendingPathComponent("hosts", isDirectory: true)
        let bin = stateDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let config = hosts.appendingPathComponent(DeviceHub.stableID("local") + ".json")
        try Data(DeviceHub.agentConfig(port: daemon.port, token: daemon.token).utf8).write(to: config, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let launcher = bin.appendingPathComponent("agent-device-launcher.mjs")
        try Data(DeviceHub.launcherScript(node: node, entry: entry).utf8).write(to: launcher, options: .atomic)
        let shim = bin.appendingPathComponent("agent-device")
        try Data(DeviceHub.shimScript(node: node, launcher: launcher.path).utf8).write(to: shim, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        return (shim.path, ["--platform", "ios", "--udid", udid, "--config", config.path,
                            "--session", DeviceHub.agentSession(runID: runID, deviceID: udid)])
    }

    /// The agent-device daemon: reused while it answers `/health`, otherwise started (`devices --json` starts it) and
    /// waited for until it writes daemon.json.
    nonisolated private static func startDaemon(node: String, entry: String, stateDir: URL) throws -> (port: Int, token: String) {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let file = stateDir.appendingPathComponent("daemon.json")
        if let data = try? Data(contentsOf: file), let daemon = DeviceHub.daemon(data), healthy(port: daemon.port) { return daemon }
        try? FileManager.default.removeItem(at: file)
        var environment = loginEnvironment()
        for (key, value) in DeviceHub.agentEnvironment(stateDir: stateDir.path) { environment[key] = value }
        _ = try? ProcessRunner.run(node, [entry, "devices", "--json"], environment: environment, timeout: 30)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let data = try? Data(contentsOf: file), let daemon = DeviceHub.daemon(data) { return daemon }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw NookError(tr("sim.hub.daemonFailed"))
    }

    nonisolated private static func healthy(port: Int) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 3)
        return ok
    }

    // MARK: Helpers

    /// A program as your login shell finds it (nvm, Homebrew, asdf).
    nonisolated static func locate(_ program: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let output = try? ProcessRunner.run(shell, ["-lc", "command -v " + program], timeout: 15), output.status == 0 else {
            return ["/opt/homebrew/bin/", "/usr/local/bin/"].map { $0 + program }.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        let path = output.stdout.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return path.hasPrefix("/") ? path : nil
    }

    /// The environment with your login shell's PATH, so npm finds node and its scripts their tools.
    nonisolated static func loginEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let path = loginPath() { environment["PATH"] = path }
        return environment
    }

    /// The login shell's PATH, asked once per launch: starting the shell (with its startup files) takes up to seconds,
    /// and the hub, each npm install and the device daemon all need it.
    nonisolated private static func loginPath() -> String? {
        loginPathLock.lock()
        defer { loginPathLock.unlock() }
        if let cachedLoginPath { return cachedLoginPath }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let output = try? ProcessRunner.run(shell, ["-lc", "printf %s \"$PATH\""], timeout: 15), output.status == 0,
              !output.stdout.isEmpty else { return nil }
        cachedLoginPath = output.stdout
        return output.stdout
    }

    private nonisolated static let loginPathLock = NSLock()
    private nonisolated(unsafe) static var cachedLoginPath: String?

    /// A free loopback port, from the system.
    nonisolated static func freePort() -> Int {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return Int.random(in: 49152...60999) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound else { return Int.random(in: 49152...60999) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

extension Notification.Name {
    /// An agent opened a simulator (device_open): the Simulator page shows it. The object is its UDID.
    static let nookOpenSimulator = Notification.Name("nook.openSimulator")
}
