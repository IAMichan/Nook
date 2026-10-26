import Combine
import Foundation

/// Keeps this Mac reachable through the relay the user deployed (`CompanionRelay`, apps/relay), so the iPhone reaches it
/// from anywhere without Tailscale and without a port opened on the router (docs/COMPANION.md, "Away from home").
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

    @Published private(set) var status: Status = .off
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); scheduleApply() }
    }
    /// The relay's address as typed.
    @Published var address: String {
        didSet { UserDefaults.standard.set(address, forKey: Self.addressKey); scheduleApply() }
    }

    private static let enabledKey = "companion.relay.enabled"
    private static let addressKey = "companion.relay.address"
    private var rooms: [String: RelayRoom] = [:]
    private var watch: AnyCancellable?
    private var pendingApply: Task<Void, Never>?

    init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        address = UserDefaults.standard.string(forKey: Self.addressKey) ?? ""
        // A phone paired or removed, a pairing window opened: the rooms follow.
        watch = CompanionStore.shared.$devices.map { _ in () }
            .merge(with: CompanionStore.shared.$pending.map { _ in () })
            .sink { [weak self] _ in DispatchQueue.main.async { self?.apply() } }
    }

    /// The relay phones are told about (`CompanionResponse.relay`): its address while on, "" while off, so they drop it.
    var advertised: String { enabled ? (CompanionRelay.normalize(address) ?? "") : "" }

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
        guard let relay = CompanionRelay.normalize(address) else { closeAll(); status = .invalid; return }
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
