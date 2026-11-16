import Foundation

/// The Mac's outgoing connection for webhooks from the internet (`WebhookRelay`). It only runs while you turned it on and a
/// webhook task exists, and sleeps between keep-alives.
@MainActor
final class WebhookRelayClient: ObservableObject {
    static let shared = WebhookRelayClient()

    enum State: Equatable {
        case off, connecting, connected
        case noRelay
    }

    @Published private(set) var state: State = .off

    private static let tokenAccount = "scheduled-task-webhook.relay-token"
    private static let pingSeconds: UInt64 = 30
    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var relay: String?

    /// The relay this Mac would use: the one Settings › iPhone names, also while the phone's connection is off.
    private var address: String? { CompanionRelayClient.shared.current }

    /// The address for `task`, once a relay is known.
    func publicURL(for task: UUID) -> String? {
        guard let address, let token = token(create: true) else { return nil }
        return WebhookRelay.publicURL(relay: address, token: token, task: task)
    }

    /// Connects while `wanted`, and keeps at it; otherwise lets go.
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
        guard let url = WebhookRelay.listenURL(relay: address, token: token) else { state = .noRelay; return }
        // Failures in a row: the wait grows with them, with jitter, up to a minute (`RetryBackoff`, as the companion's).
        var failures = 0
        while !Task.isCancelled {
            var request = URLRequest(url: url)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let socket = URLSession.shared.webSocketTask(with: request)
            self.socket = socket
            socket.resume()
            state = .connecting
            // The relay answers each ping without waking the room; the first answer says the connection stands.
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
                    failures = 0
                    guard case .string(let text) = message, let incoming = WebhookRelay.incoming(text) else { continue }
                    let answer = WebhookListener.shared.handle(incoming.request)
                    try await socket.send(.string(WebhookRelay.answer(id: incoming.id, status: answer.status, message: answer.message)))
                }
            } catch {
                state = .connecting
            }
            pings.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            guard !Task.isCancelled else { return }
            failures += 1
            let wait = RetryBackoff.delay(failures: failures, random: Double.random(in: 0...1))
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }
}
