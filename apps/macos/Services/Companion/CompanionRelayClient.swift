import Combine
import Foundation

/// Keeps this Mac reachable through a relay (`CompanionRelay`, apps/relay), so the iPhone reaches it from anywhere
/// without Tailscale and without a port opened on the router (docs/COMPANION.md, "Away from home"). The relay is Nook's
/// own (one switch), or one on the user's own Cloudflare account that Settings sets up with one API token
/// (`CloudflareRelayDeployer`) and keeps up to date.
/// One outgoing WebSocket per paired phone (and one for an open pairing window), each in that phone's room. What comes
/// through is handed to `CompanionServer` as a connection like any other: every message is sealed with the pairing key,
/// so the relay reads and forges nothing.
@MainActor
final class CompanionRelayClient: ObservableObject {
    static let shared = CompanionRelayClient()

    enum Status: Equatable {
        case off
        /// On, but the address is not an https address.
        case invalid
        case connecting
        case connected
        case failed(String)
    }

    /// Whose relay: Nook's own, or one on the user's own account.
    enum Mode: String {
        case nook, own
    }

    /// Setting up a relay on the user's Cloudflare account.
    enum Setup: Equatable {
        case idle
        case working(CloudflareRelayDeployer.Step)
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var setup: Setup = .idle
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); scheduleApply() }
    }
    @Published var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey); scheduleApply() }
    }
    /// The address of the user's own relay: set by the setup, or typed for a relay deployed some other way.
    @Published var address: String {
        didSet { UserDefaults.standard.set(address, forKey: Self.addressKey); scheduleApply() }
    }

    /// Nook's own relay (the build setting NOOK_RELAY_URL); nil in a build without one.
    static let nookRelay: String? = (Bundle.main.object(forInfoDictionaryKey: "NookRelayURL") as? String)
        .flatMap { $0.isEmpty ? nil : CompanionRelay.normalize($0) }

    private static let enabledKey = "companion.relay.enabled"
    private static let modeKey = "companion.relay.mode"
    private static let addressKey = "companion.relay.address"
    /// The Cloudflare token the relay was set up with (Keychain), to update it when Nook ships new relay code.
    private static let tokenAccount = "companion.relay.cloudflareToken"
    /// The relay code version (`CloudflareRelaySetup.version`) deployed to `address`, and that address.
    private static let deployedKey = "companion.relay.deployed"
    private var updateChecked = false
    private var rooms: [String: RelayRoom] = [:]
    private var watch: AnyCancellable?
    private var pendingApply: Task<Void, Never>?

    init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let stored = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(Mode.init(rawValue:))
        mode = Self.nookRelay == nil ? .own : stored ?? .nook
        address = UserDefaults.standard.string(forKey: Self.addressKey) ?? ""
        // A phone paired or removed, a pairing window opened: the rooms follow.
        watch = CompanionStore.shared.$devices.map { _ in () }
            .merge(with: CompanionStore.shared.$pending.map { _ in () })
            .sink { [weak self] _ in DispatchQueue.main.async { self?.apply() } }
    }

    /// The relay in use: Nook's, or the user's own; nil when that is not set (up) yet.
    var current: String? {
        switch mode {
        case .nook: return Self.nookRelay
        case .own: return CompanionRelay.normalize(address)
        }
    }

    /// The relay phones are told about (`CompanionResponse.relay`): its address while on, "" while off, so they drop it.
    var advertised: String { enabled ? (current ?? "") : "" }

    /// Whether the user's own relay was set up by Nook (so Nook keeps it up to date).
    var ownRelayIsManaged: Bool {
        mode == .own && !address.isEmpty && UserDefaults.standard.string(forKey: Self.deployedKey)?.hasSuffix(" " + address) == true
    }

    // MARK: Setting up a relay on Cloudflare

    /// Deploys the relay to the account the token belongs to, and switches to it once it answers.
    func setUp(token: String) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !isSettingUp else { return }
        setup = .working(.account)
        Task {
            do {
                let address = try await CloudflareRelayDeployer.deploy(token: token) { [weak self] step in self?.setup = .working(step) }
                _ = Keychain.write(token, account: Self.tokenAccount)
                markDeployed(address)
                mode = .own
                self.address = address
                enabled = true
                setup = .idle
                apply()
            } catch {
                setup = .failed(error.localizedDescription)
            }
        }
    }

    /// Forgets the user's own relay here (the Worker stays on their Cloudflare account until they delete it).
    func forgetOwnRelay() {
        _ = Keychain.write("", account: Self.tokenAccount)
        UserDefaults.standard.removeObject(forKey: Self.deployedKey)
        address = ""
        setup = .idle
    }

    private var isSettingUp: Bool {
        if case .working = setup { return true }
        return false
    }

    private func markDeployed(_ address: String) {
        guard let modules = CloudflareRelayDeployer.bundledModules() else { return }
        UserDefaults.standard.set(CloudflareRelaySetup.version(of: modules) + " " + address, forKey: Self.deployedKey)
    }

    /// A relay Nook set up gets the relay code of this Nook version, once a launch, quietly.
    private func updateOwnRelayIfNeeded() {
        guard !updateChecked, enabled, ownRelayIsManaged, !isSettingUp,
              let token = Keychain.read(Self.tokenAccount), let modules = CloudflareRelayDeployer.bundledModules() else { return }
        updateChecked = true
        let current = address
        let version = CloudflareRelaySetup.version(of: modules)
        guard UserDefaults.standard.string(forKey: Self.deployedKey) != version + " " + current else { return }
        Task {
            if let deployed = try? await CloudflareRelayDeployer.deploy(token: token, progress: { _ in }), deployed == current {
                markDeployed(current)
            }
        }
    }

    /// Typing an address changes it once a second at most, not with every key.
    private func scheduleApply() {
        pendingApply?.cancel()
        pendingApply = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.apply()
        }
    }

    /// Opens a room for every paired phone (and the open pairing window), and closes the rest.
    func apply() {
        let store = CompanionStore.shared
        guard store.enabled, enabled else { closeAll(); status = .off; return }
        guard let relay = current else { closeAll(); status = .invalid; return }
        updateOwnRelayIfNeeded()
        var wanted: [String: Data] = [:]
        for device in store.devices {
            if let key = CompanionStore.key(for: device.id) { wanted[device.id] = key }
        }
        if let pending = store.activePending() { wanted[PairedDevice.identifier(forKey: pending)] = pending }
        for (id, room) in rooms where wanted[id] == nil || room.relay != relay {
            room.stop()
            rooms[id] = nil
        }
        for (id, key) in wanted where rooms[id] == nil {
            guard let room = RelayRoom(relay: relay, key: key, onChange: { [weak self] in self?.updateStatus() }) else { continue }
            rooms[id] = room
            room.start()
        }
        updateStatus()
    }

    private func closeAll() {
        for room in rooms.values { room.stop() }
        rooms = [:]
    }

    private func updateStatus() {
        guard enabled, CompanionStore.shared.enabled else { status = .off; return }
        let all = Array(rooms.values)
        if all.contains(where: \.connected) {
            status = .connected
        } else if let problem = all.compactMap(\.lastError).first {
            status = .failed(problem)
        } else {
            status = all.isEmpty ? .off : .connecting
        }
    }
}

/// One phone's room on the relay: the Mac's WebSocket, the phone connections that came through it, and reconnecting.
@MainActor
final class RelayRoom {
    let relay: String
    private let url: URL
    private let onChange: () -> Void
    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var peers: [UInt32: CompanionPeer] = [:]
    private(set) var connected = false
    private(set) var lastError: String?
    private var lastHeard = Date()

    /// The keep-alive goes this often; a socket that heard nothing for `silenceLimit` is replaced.
    private static let keepAlive: TimeInterval = 30
    private static let silenceLimit: TimeInterval = 75

    init?(relay: String, key: Data, onChange: @escaping () -> Void) {
        guard let url = CompanionRelay.socketURL(relay: relay, room: CompanionRelay.room(forKey: key), role: .mac) else { return nil }
        self.relay = relay
        self.url = url
        self.onChange = onChange
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        dropPeers()
        connected = false
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            let task = URLSession.shared.webSocketTask(with: url)
            self.task = task
            task.resume()
            let since = Date()
            lastHeard = since
            // The relay answers "ping" with "pong" without waking up; the first one shows the socket is open.
            task.send(.string("ping")) { _ in }
            let keepAlive = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(Self.keepAlive * 1_000_000_000))
                    guard let self, !Task.isCancelled else { return }
                    if Date().timeIntervalSince(self.lastHeard) > Self.silenceLimit { task.cancel(with: .goingAway, reason: nil); return }
                    task.send(.string("ping")) { _ in }
                }
            }
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    lastHeard = Date()
                    if !connected {
                        connected = true
                        lastError = nil
                        failures = 0
                        onChange()
                    }
                    if case .data(let data) = message { handle(data) }
                }
            } catch {
                if !Task.isCancelled { lastError = error.localizedDescription }
            }
            keepAlive.cancel()
            task.cancel(with: .goingAway, reason: nil)
            dropPeers()
            if connected {
                connected = false
            }
            onChange()
            if Task.isCancelled { return }
            failures = Date().timeIntervalSince(since) >= RetryBackoff.stableAfter ? 1 : failures + 1
            try? await Task.sleep(nanoseconds: UInt64(RetryBackoff.delay(failures: failures, random: Double.random(in: 0...1)) * 1_000_000_000))
        }
    }

    private func handle(_ data: Data) {
        guard let message = RelayMux.decode(data) else { return }
        let server = CompanionServer.shared
        switch message.kind {
        case .open:
            peers[message.connection] = server.relayOpened(RelayTransport(room: self, connection: message.connection))
        case .data:
            guard let peer = peers[message.connection] else {
                send(RelayMux.encode(.close, connection: message.connection))
                return
            }
            server.relayReceived(peer, data: message.payload)
        case .close:
            if let peer = peers.removeValue(forKey: message.connection) { server.relayClosed(peer) }
        }
    }

    fileprivate func send(_ data: Data, to connection: UInt32) {
        send(RelayMux.encode(.data, connection: connection, payload: data))
    }

    /// The Mac ends a phone connection: the relay closes the phone's socket.
    fileprivate func finish(_ connection: UInt32) {
        send(RelayMux.encode(.close, connection: connection))
        if let peer = peers.removeValue(forKey: connection) { CompanionServer.shared.relayClosed(peer) }
    }

    private func send(_ message: Data) {
        task?.send(.data(message)) { _ in }
    }

    private func dropPeers() {
        let gone = peers.values
        peers = [:]
        for peer in gone { CompanionServer.shared.relayClosed(peer) }
    }
}

/// A phone connection through the relay, as `CompanionServer` answers it.
@MainActor
final class RelayTransport: CompanionTransport {
    private weak var room: RelayRoom?
    private let connection: UInt32
    private var cancelled = false

    init(room: RelayRoom, connection: UInt32) {
        self.room = room
        self.connection = connection
    }

    func send(_ data: Data) {
        guard !cancelled else { return }
        room?.send(data, to: connection)
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        room?.finish(connection)
    }
}
