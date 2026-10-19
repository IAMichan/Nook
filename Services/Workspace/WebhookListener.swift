import Foundation
import Network

/// The local webhook endpoint for scheduled tasks: `POST http://127.0.0.1:<port>/hooks/<task id>`.
///
/// It listens on the loopback address only (never on the network) and checks every request before anything else happens:
/// the HMAC signature over the body (`WebhookVerifier`, constant time), a delivery id that was not seen before
/// (`DeliveryLog`), the rate (`RateWindow`, 60 a minute per task) and the queue of the task (`WebhookQueue`, 20).
/// The request body is untrusted data: it reaches the agent only quoted inside `WebhookPrompt`.
///
/// Headers a sender gives: `X-Hub-Signature-256` (or `X-Nook-Signature-256`) = `sha256=<hex HMAC of the body>` and
/// `X-Nook-Delivery` (or `X-GitHub-Delivery`, `Idempotency-Key`) = a unique id per delivery.
@MainActor
final class WebhookListener: ObservableObject {
    static let shared = WebhookListener()

    enum State: Equatable {
        case stopped
        case listening(port: UInt16)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped

    private var listener: NWListener?
    private var port: UInt16 = 0
    private weak var store: ScheduledTaskStore?
    private var logs: [UUID: DeliveryLog] = [:]
    private var rates: [UUID: RateWindow] = [:]
    private var openConnections = 0
    private static let maxConnections = 16
    private let queue = DispatchQueue(label: "nook.webhook.listener")

    func start(port: UInt16, store: ScheduledTaskStore) {
        self.store = store
        if listener != nil, self.port == port { return }
        stop()
        let parameters = NWParameters.tcp
        // Loopback only, twice over: the interface type and the local address.
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { state = .failed("port"); return }
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in self?.listenerChanged(newState, port: port) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            self.port = port
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
        if case .failed = state {} else { state = .stopped }
    }

    private func listenerChanged(_ newState: NWListener.State, port: UInt16) {
        guard self.port == port, listener != nil else { return }
        switch newState {
        case .ready: state = .listening(port: port)
        case .failed(let error):
            state = .failed(error.localizedDescription)
            listener?.cancel()
            listener = nil
            self.port = 0
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard openConnections < Self.maxConnections else { connection.cancel(); return }
        openConnections += 1
        let handler = Connection(connection: connection, queue: queue, owner: self)
        handler.run()
    }

    fileprivate func connectionClosed() { openConnections = max(0, openConnections - 1) }

    // MARK: Decision

    /// What to answer a complete request. Order matters: nothing about a task is revealed or changed before the signature
    /// is right, so an unsigned flood cannot fill the logs or use up a task's rate.
    func handle(_ request: WebhookHTTP.Request, now: Date = Date()) -> (status: Int, message: String) {
        guard request.method == "POST" else { return (405, "POST only") }
        guard let store, let taskID = WebhookHTTP.taskID(fromPath: request.path),
              store.isEnabled, let task = store.task(taskID), task.enabled, task.rule.isWebhook,
              let secret = store.webhookSecret(for: taskID) else { return (404, "unknown hook") }
        guard WebhookVerifier.verify(secret: secret, body: request.body, signatureHeader: WebhookHTTP.signature(in: request.headers)) else {
            return (401, "bad signature")
        }
        guard let deliveryID = WebhookHTTP.deliveryID(in: request.headers) else { return (400, "missing or invalid delivery id") }

        var rate = rates[taskID] ?? RateWindow()
        let decision = rate.admit(now: now)
        rates[taskID] = rate
        if case .limited = decision { return (429, "rate limited") }

        var log = logs[taskID] ?? DeliveryLog()
        guard !log.contains(deliveryID) else { return (409, "duplicate delivery") }

        switch store.acceptWebhook(taskID: taskID, deliveryID: deliveryID, payload: request.body, now: now) {
        case .accepted:
            _ = log.record(deliveryID)
            logs[taskID] = log
            return (202, "accepted")
        case .queueFull:
            return (429, "queue full")
        case .unknownTask:
            return (404, "unknown hook")
        }
    }

    // MARK: One connection

    /// Reads one request, asks the listener what to answer, answers and closes. A connection that does not finish in
    /// ten seconds is cut.
    private final class Connection: @unchecked Sendable {
        private let connection: NWConnection
        private let queue: DispatchQueue
        private weak var owner: WebhookListener?
        private var buffer = Data()
        private var finished = false

        init(connection: NWConnection, queue: DispatchQueue, owner: WebhookListener) {
            self.connection = connection
            self.queue = queue
            self.owner = owner
        }

        func run() {
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) { [self] in close() }
            receive()
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [self] data, _, isComplete, error in
                if finished { return }
                if let data { buffer.append(data) }
                if error != nil { close(); return }
                switch WebhookHTTP.parse(buffer) {
                case .request(let request):
                    let owner = self.owner
                    Task { @MainActor in
                        let answer = owner?.handle(request) ?? (503, "unavailable")
                        self.queue.async { self.reply(answer.0, answer.1) }
                    }
                case .reject(let status):
                    reply(status, "rejected")
                case .needMore:
                    if isComplete { close() } else { receive() }
                }
            }
        }

        private func reply(_ status: Int, _ message: String) {
            guard !finished else { return }
            connection.send(content: WebhookHTTP.response(status: status, message: message), completion: .contentProcessed { [self] _ in close() })
        }

        private func close() {
            guard !finished else { return }
            finished = true
            connection.cancel()
            let owner = self.owner
            Task { @MainActor in owner?.connectionClosed() }
        }
    }
}
