import Foundation
import Network

/// The Mac side of the iPhone companion: a TCP listener (announced on the local network with Bonjour) that answers sealed
/// requests from paired phones. Nothing is readable without a pairing key, nothing is accepted that is stale, repeated or
/// too frequent, and what a phone may do is limited by `CompanionPolicy`. Every action lands in the audit log.
@MainActor
final class CompanionServer: ObservableObject {
    static let shared = CompanionServer()

    enum State: Equatable {
        case stopped
        case listening(port: UInt16)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped

    private var listener: NWListener?
    private weak var app: AppModel?
    private var guards: [String: RequestGuard] = [:]
    private var open = 0
    private static let maxConnections = 8
    private let queue = DispatchQueue(label: "nook.companion.server")

    func attach(app: AppModel) {
        self.app = app
        apply()
    }

    /// Starts or stops the listener to match the setting.
    func apply() {
        if CompanionStore.shared.enabled { start() } else { stop() }
    }

    var port: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: CompanionStore.portKey)
        return (1024...65535).contains(stored) ? UInt16(stored) : 0
    }

    private func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
            listener.service = NWListener.Service(name: MachineName.local, type: CompanionConstants.bonjourType)
            listener.stateUpdateHandler = { [weak self] new in
                Task { @MainActor in self?.listenerChanged(new) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    private func listenerChanged(_ new: NWListener.State) {
        switch new {
        case .ready:
            if let port = listener?.port?.rawValue {
                state = .listening(port: port)
                // A stable port keeps paired phones working after a restart.
                UserDefaults.standard.set(Int(port), forKey: CompanionStore.portKey)
            }
        case .failed(let error):
            state = .failed(error.localizedDescription)
            listener?.cancel()
            listener = nil
            // A taken port: pick another next time.
            UserDefaults.standard.removeObject(forKey: CompanionStore.portKey)
        default: break
        }
    }

    /// What the phone is shown to pair: the key of an open pairing window and where this Mac can be reached.
    func pairingLink() -> PairingLink? {
        guard case .listening(let port) = state else { return nil }
        let key = CompanionStore.shared.activePending() ?? CompanionStore.shared.beginPairing()
        var host = ProcessInfo.processInfo.hostName
        if !host.contains(".") { host += ".local" }
        return PairingLink(host: host, port: port, key: key, macName: MachineName.local)
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard open < Self.maxConnections else { connection.cancel(); return }
        open += 1
        connection.stateUpdateHandler = { [weak self] new in
            switch new {
            case .failed, .cancelled: Task { @MainActor in self?.open = max(0, (self?.open ?? 1) - 1) }
            default: break
            }
        }
        connection.start(queue: queue)
        // A connection lives at most 30 seconds.
        queue.asyncAfter(deadline: .now() + 30) { connection.cancel() }
        read(connection, reader: CompanionFrameReader())
    }

    private func read(_ connection: NWConnection, reader: CompanionFrameReader) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            var reader = reader
            guard let self else { return }
            if let data, !data.isEmpty {
                let frames = reader.feed(data)
                if reader.overflowed { connection.cancel(); return }
                let remaining = reader
                Task { @MainActor in
                    for frame in frames { await self.respond(to: frame, on: connection) }
                    if !complete, error == nil { self.read(connection, reader: remaining) } else { connection.cancel() }
                }
            } else if complete || error != nil {
                connection.cancel()
            }
        }
    }

    private func send(_ response: CompanionResponse, key: Data, deviceID: String, on connection: NWConnection) {
        guard let json = try? JSONEncoder().encode(response),
              let sealed = try? CompanionSeal.seal(json, pairingKey: key, deviceID: deviceID, direction: .response),
              let framed = CompanionFrameReader.frame(sealed) else { return }
        connection.send(content: framed, completion: .contentProcessed { _ in })
    }

    private func respond(to frame: Data, on connection: NWConnection) async {
        let store = CompanionStore.shared
        guard let claimed = CompanionSeal.claimedDevice(frame) else { connection.cancel(); return }
        // The key of a paired device, or the key of the open pairing window (which proves itself by opening the message).
        var key = CompanionStore.key(for: claimed)
        var pairing = false
        if key == nil, let pendingKey = store.activePending(), PairedDevice.identifier(forKey: pendingKey) == claimed {
            key = pendingKey
            pairing = true
        }
        guard let key, let plain = try? CompanionSeal.open(frame, pairingKey: key, direction: .request),
              let request = try? JSONDecoder().decode(CompanionRequest.self, from: plain) else {
            connection.cancel()
            return
        }
        // The guard lives per device and is changed in place: a repeated id or a burst is refused from here on.
        if let refusal = guards[claimed, default: RequestGuard()].admit(request, now: Date()) {
            send(.failure(request.id, refusal), key: key, deviceID: claimed, on: connection)
            return
        }

        if pairing {
            guard request.op == .hello, store.completePairing(name: request.text ?? "") != nil else {
                send(.failure(request.id, .badRequest), key: key, deviceID: claimed, on: connection)
                return
            }
            audit("paired", request.text ?? "iPhone")
        } else {
            store.touch(claimed)
        }
        let response = await handle(request, deviceID: claimed)
        send(response, key: key, deviceID: claimed, on: connection)
    }

    private func audit(_ action: String, _ detail: String) {
        app?.store.audit(tool: "companion_" + action, args: detail, result: "ok")
    }

    // MARK: Requests

    private func handle(_ request: CompanionRequest, deviceID: String) async -> CompanionResponse {
        guard let app else { return .failure(request.id, .failed) }
        let workspace = app.workspace
        let macName = MachineName.local
        switch request.op {
        case .hello:
            return CompanionResponse(id: request.id, ok: true, macName: macName, sessions: digests(workspace))
        case .list:
            return CompanionResponse(id: request.id, ok: true, macName: macName, sessions: digests(workspace))
        case .register:
            // The token goes into a URL on Apple's host: only hex is accepted.
            guard let token = request.text, APNsJWT.validToken(token) else { return .failure(request.id, .badRequest) }
            CompanionStore.shared.setPush(device: deviceID, token: token.lowercased(), production: request.item != "development")
            audit("push_registered", CompanionStore.shared.devices.first { $0.id == deviceID }?.name ?? "")
            return CompanionResponse(id: request.id, ok: true, macName: macName,
                                     message: CompanionStore.shared.canPush && CompanionStore.shared.push.enabled ? "push" : "nopush")
        case .unregister:
            CompanionStore.shared.setPush(device: deviceID, token: nil, production: nil)
            return CompanionResponse(id: request.id, ok: true)
        case .decide:
            guard let runID = request.session.flatMap(UUID.init(uuidString:)), workspace.run(runID) != nil else {
                return .failure(request.id, .unknownSession)
            }
            guard let pending = workspace.approvals[runID]?.first(where: { $0.id == request.item }) else {
                return .failure(request.id, .unknownItem)
            }
            let allow = request.allow == true
            if allow, !canAllow(pending) { return .failure(request.id, .notAllowedFromPhone) }
            workspace.decide(runID, requestID: pending.id, allow ? .allow : .deny)
            audit(allow ? "allow" : "deny", "\(workspace.run(runID)?.title ?? "") · \(pending.tool)")
            return CompanionResponse(id: request.id, ok: true, sessions: digests(workspace))
        case .answer:
            guard let runID = request.session.flatMap(UUID.init(uuidString:)), workspace.run(runID) != nil else {
                return .failure(request.id, .unknownSession)
            }
            guard let question = workspace.questions[runID]?.first(where: { $0.id == request.item }) else {
                return .failure(request.id, .unknownItem)
            }
            guard question.questions.count == 1, let first = question.questions.first,
                  let text = CompanionPolicy.cleanMessage(request.text ?? "") else {
                return .failure(request.id, .notAllowedFromPhone)
            }
            // A free answer only where the agent accepts one; otherwise it has to be one of the options.
            if !first.allowsOther, !first.options.contains(where: { $0.label == text }) { return .failure(request.id, .badRequest) }
            workspace.answer(runID, questionID: question.id, answers: [first.id: [text]])
            audit("answer", workspace.run(runID)?.title ?? "")
            return CompanionResponse(id: request.id, ok: true, sessions: digests(workspace))
        case .send:
            guard let runID = request.session.flatMap(UUID.init(uuidString:)), let run = workspace.run(runID) else {
                return .failure(request.id, .unknownSession)
            }
            guard let text = CompanionPolicy.cleanMessage(request.text ?? "") else { return .failure(request.id, .badRequest) }
            if run.status.isActive { workspace.enqueue(runID, text: text) } else { workspace.send(runID, text: text) }
            audit("send", run.title)
            return CompanionResponse(id: request.id, ok: true, sessions: digests(workspace), message: run.status.isActive ? "queued" : "sent")
        case .stop:
            guard let runID = request.session.flatMap(UUID.init(uuidString:)), let run = workspace.run(runID) else {
                return .failure(request.id, .unknownSession)
            }
            workspace.stop(runID)
            audit("stop", run.title)
            return CompanionResponse(id: request.id, ok: true, sessions: digests(workspace))
        }
    }

    private func canAllow(_ pending: PendingPermission) -> Bool {
        var safe: Bool?
        if let command = (pending.input.object as? [String: Any])?["command"] as? String {
            safe = CommandRisk.assess(command).level == .safe
        }
        return CompanionPolicy.canAllow(tool: pending.tool, commandIsSafe: safe)
    }

    private func digests(_ workspace: WorkspaceManager) -> [SessionDigest] {
        let now = Date()
        let runs = workspace.runs.filter { !$0.archived }.sorted { $0.updatedAt > $1.updatedAt }.prefix(25)
        return runs.map { run in
            var items: [SessionDigest.Item] = []
            for pending in workspace.approvals[run.id] ?? [] {
                items.append(.init(id: pending.id, kind: .approval, title: CompanionPolicy.excerpt(pending.summary),
                                   detail: CompanionPolicy.excerpt(pending.tool), canAllow: canAllow(pending), options: []))
            }
            for question in workspace.questions[run.id] ?? [] {
                let first = question.questions.first
                let single = question.questions.count == 1
                items.append(.init(id: question.id, kind: .question, title: CompanionPolicy.excerpt(first?.question ?? ""),
                                   detail: CompanionPolicy.excerpt(first?.header ?? ""), canAllow: single,
                                   options: single ? (first?.options.map(\.label) ?? []) : []))
            }
            let lastAnswer = workspace.timeline(run.id).last(where: { $0.kind == .assistant })?.text ?? ""
            return SessionDigest(id: run.id.uuidString, title: CompanionPolicy.excerpt(run.title), agent: run.provider.displayName,
                                 attention: String(describing: workspace.attention(run, unseen: false, now: now)),
                                 folder: URL(fileURLWithPath: run.workingDirectory).lastPathComponent, branch: run.branch,
                                 updated: run.updatedAt.timeIntervalSince1970, excerpt: CompanionPolicy.excerpt(lastAnswer), items: items)
        }
    }
}
