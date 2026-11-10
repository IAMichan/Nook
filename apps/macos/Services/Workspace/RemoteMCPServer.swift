import Foundation
import Security

/// Nook in another app (see `RemoteMCP`): the Mac's outgoing connection to the relay for cloud assistants, the sign-in with the
/// pairing code, the grants, and every tool call passed on to the bridge, where it asks and is audited as for any agent. It
/// only connects while the user turned it on, and sleeps between keep-alives.
@MainActor
final class RemoteMCPServer: ObservableObject {
    static let shared = RemoteMCPServer()

    enum State: Equatable {
        case off, connecting, connected
        case noRelay
    }

    @Published private(set) var state: State = .off
    /// Sign-ins waiting for their code, and the grants: what Settings shows. Saved without the sign-ins.
    @Published private(set) var access: RemoteMCPAccess

    weak var bridge: WorkspaceBridge?

    private static let tokenAccount = "remote-mcp.relay-token"
    private static let pingSeconds: UInt64 = 30
    private static let maxBackoffSeconds: UInt64 = 60
    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var relay: String?
    private let file: URL

    init(file: URL = NookPaths.supportDirectory.appendingPathComponent("remote-mcp.json")) {
        self.file = file
        var loaded = RemoteMCPAccess()
        if let data = try? Data(contentsOf: file), let saved = try? Self.decoder.decode(Saved.self, from: data) {
            loaded.clients = saved.clients
            loaded.grants = saved.grants
        }
        access = loaded
        access.prune(now: Date())
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private struct Saved: Codable {
        var clients: [String: RemoteMCPAccess.Client]
        var grants: [RemoteMCPAccess.Grant]
    }

    private var address: String? { CompanionRelayClient.shared.current }

    /// The address to give an assistant, once a relay is known.
    var publicURL: String? {
        guard let address, let token = token(create: true) else { return nil }
        return RemoteMCP.baseURL(relay: address, room: RemoteMCPTunnel.room(token: token))
    }

    // MARK: Connection

    func set(wanted: Bool) {
        guard wanted else { stop(); state = .off; return }
        guard let address, let token = token(create: true) else { stop(); state = .noRelay; return }
        if loop != nil, relay == address { return }
        stop()
        relay = address
        state = .connecting
        loop = Task { [weak self] in await self?.run(address, token) }
    }

    private func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        relay = nil
    }

    private func token(create: Bool) -> String? {
        if let saved = SecretStore.read(Self.tokenAccount) { return saved }
        guard create else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = WebhookHex.encode(Data(bytes))
        return SecretStore.write(token, account: Self.tokenAccount) == errSecSuccess ? token : nil
    }

    private func run(_ address: String, _ token: String) async {
        guard let url = RemoteMCPTunnel.listenURL(relay: address, token: token) else { state = .noRelay; return }
        var backoff: UInt64 = 2
        while !Task.isCancelled {
            var request = URLRequest(url: url)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let socket = URLSession.shared.webSocketTask(with: request)
            socket.maximumMessageSize = 4 * RemoteMCPHTTP.maxBody
            self.socket = socket
            socket.resume()
            state = .connecting
            let pings = Task {
                while !Task.isCancelled {
                    socket.send(.string("ping")) { _ in }
                    try? await Task.sleep(nanoseconds: Self.pingSeconds * 1_000_000_000)
                }
            }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    state = .connected
                    backoff = 2
                    guard case .string(let text) = message, let incoming = RemoteMCPHTTP.incoming(text) else { continue }
                    // A call may wait for the user's approval: it must not hold up the next request.
                    Task { [weak self] in
                        guard let self else { return }
                        let answer = await self.handle(incoming, base: RemoteMCP.baseURL(relay: address, room: RemoteMCPTunnel.room(token: token)),
                                                       relay: address, room: RemoteMCPTunnel.room(token: token))
                        try? await socket.send(.string(RemoteMCPHTTP.frame(id: incoming.id, answer)))
                    }
                }
            } catch {
                state = .connecting
            }
            pings.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
            backoff = min(backoff * 2, Self.maxBackoffSeconds)
        }
    }

    // MARK: Requests

    private static var random: RemoteMCPAccess.Random {
        func bytes(_ count: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: count)
            _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
            return bytes
        }
        return .init(secret: { WebhookHex.encode(Data(bytes($0))) },
                     digits: { count in
                         // Rejection sampling keeps every digit equally likely.
                         var out = ""
                         while out.count < count { for byte in bytes(count) where byte < 250 && out.count < count { out += String(byte % 10) } }
                         return out
                     })
    }

    func handle(_ request: RemoteMCPHTTP.Request, base: String, relay: String, room: String) async -> RemoteMCPHTTP.Answer {
        let now = Date()
        let waitingBefore = Set(access.waiting.map(\.id))
        var copy = access
        let answer = RemoteMCPHTTP.oauth(request, access: &copy, base: base, now: now, random: Self.random,
                                         texts: { tr($0) })
        if let answer {
            if copy != access {
                access = copy
                save()
            }
            for signIn in access.waiting where !waitingBefore.contains(signIn.id) { announce(signIn) }
            return answer
        }
        let metadata = RemoteMCP.metadataURL(relay: relay, room: room, name: "oauth-protected-resource")
        guard let token = RemoteMCPHTTP.bearer(request), let grant = access.grant(accessToken: token, now: now) else {
            return RemoteMCPHTTP.unauthorized(metadata: metadata)
        }
        guard WorkspaceSettings.shared.remoteMCPEnabled else { return RemoteMCPHTTP.json(503, ["error": "off"]) }
        guard request.method == "POST" else { return RemoteMCPHTTP.Answer(status: 405, headers: ["content-type": "text/plain"]) }
        guard let object = try? JSONSerialization.jsonObject(with: request.body), let bridge else {
            return RemoteMCPHTTP.json(400, ["jsonrpc": "2.0", "error": ["code": -32700, "message": "Parse error"]])
        }
        access.used(grant.id, now: now)
        let messages = (object as? [[String: Any]]) ?? [(object as? [String: Any]) ?? [:]]
        var replies: [[String: Any]] = []
        for message in messages {
            // The grant is read again for each message: a level the user lowered, or a grant they revoked, counts at once.
            guard let current = access.grants.first(where: { $0.id == grant.id }) else {
                return RemoteMCPHTTP.unauthorized(metadata: metadata)
            }
            if let reply = await bridge.answer(assistant: message, name: current.client, level: current.level) { replies.append(reply) }
        }
        if replies.isEmpty { return RemoteMCPHTTP.Answer(status: 202, headers: ["cache-control": "no-store"]) }
        return RemoteMCPHTTP.json(200, [:], extra: [:]).withBody(
            (try? JSONSerialization.data(withJSONObject: object is [Any] ? replies as Any : replies[0])) ?? Data())
    }

    private func announce(_ signIn: RemoteMCPAccess.SignIn) {
        SystemNotifier.shared.notice(id: "remote-mcp-" + signIn.id, title: tr("remotemcp.notice.title", signIn.clientName),
                                     body: tr("remotemcp.notice.body", RemoteMCP.display(code: signIn.code)),
                                     banner: NoticeBanner(level: .timeSensitive), open: {}, fallback: {})
    }

    // MARK: Settings

    func setLevel(_ level: RemoteAccessLevel, signIn id: String) {
        access.setLevel(level, for: id)
    }

    func deny(signIn id: String) {
        access.deny(id)
        SystemNotifier.shared.withdraw("remote-mcp-" + id)
    }

    func setLevel(_ level: RemoteAccessLevel, grant id: String) {
        access.setLevel(level, forGrant: id)
        save()
    }

    func revoke(_ id: String) {
        access.revoke(id)
        save()
    }

    /// Drops every grant and the address itself: a new token makes a new address, so a link that leaked stops working.
    func resetEverything() {
        access.revokeAll()
        access.clients = [:]
        save()
        _ = SecretStore.remove(Self.tokenAccount)
        stop()
        set(wanted: WorkspaceSettings.shared.remoteMCPEnabled)
    }

    func refreshExpired() {
        var copy = access
        copy.prune(now: Date())
        if copy != access { access = copy; save() }
    }

    private func save() {
        let saved = Saved(clients: access.clients, grants: access.grants)
        guard let data = try? Self.encoder.encode(saved) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

private extension RemoteMCPHTTP.Answer {
    func withBody(_ data: Data) -> RemoteMCPHTTP.Answer {
        var copy = self
        copy.body = data
        return copy
    }
}
