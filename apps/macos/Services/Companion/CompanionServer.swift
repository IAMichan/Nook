import Combine
import Foundation
import Network

/// The Mac side of the iPhone companion: a TCP listener (announced on the local network with Bonjour) that answers sealed
/// requests from paired phones. Nothing is readable without a pairing key, nothing is accepted that is stale, repeated or
/// too frequent, and what a phone may do is limited by `CompanionPolicy`. Every action lands in the audit log.
///
/// A phone that subscribes keeps its connection open: the Mac sends the sessions again whenever they change, and the
/// phone pings it to tell a live connection from a dead one (docs/COMPANION.md, "Staying connected"). A request that
/// changed something is answered once; a repeat of its id gets the same answer (`CommandReceipts`).
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
    private var receipts: [String: CommandReceipts] = [:]
    /// Repeats of a request that is still being carried out, by device and request id: they get its answer.
    private var running: [String: [CheckedContinuation<CompanionResponse, Never>]] = [:]
    private var open = 0
    private static let maxConnections = 8
    private let queue = DispatchQueue(label: "nook.companion.server")
    /// Connections a phone subscribed on, at most one per phone.
    private var streams: [CompanionPeer] = []
    private var watch: AnyCancellable?
    private var streamTimer: Timer?
    private var endpointCache: (at: Date, port: UInt16, list: [CompanionEndpoint])?

    func attach(app: AppModel) {
        self.app = app
        // Subscribed phones get the sessions when they change; streaming text changes the workspace many times a
        // second, so at most one look a second, and only what changed is sent.
        watch = app.workspace.objectWillChange.merge(with: app.hub.objectWillChange)
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.pushChanges() } }
        apply()
        KeepAwake.shared.attach(app: app)
    }

    /// A phone is connected live right now (the Mac stays awake for it, `KeepAwake`).
    var hasLivePhone: Bool { !streams.isEmpty }

    /// Starts or stops the listener (and the relay connection) to match the settings.
    func apply() {
        if CompanionStore.shared.enabled { start() } else { stop() }
        CompanionRelayClient.shared.apply()
        KeepAwake.shared.update()
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
        for peer in streams { peer.transport.cancel() }
        streams = []
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
            CompanionDiagnosticsLog.mac.record("listener", ["state": "failed", "error": error.localizedDescription])
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
        // The other addresses go along, so a phone that cannot resolve the .local name still finds the Mac.
        let alternates = endpoints().map(\.host).filter { $0.lowercased() != host.lowercased() }
        let relay = CompanionRelayClient.shared.advertised
        return PairingLink(host: host, port: port, key: key, macName: MachineName.local, alternates: alternates,
                           relay: relay.isEmpty ? nil : relay)
    }

    /// Where phones can reach this Mac now (`CompanionEndpoints`); read again at most every 30 seconds.
    func endpoints(now: Date = Date()) -> [CompanionEndpoint] {
        guard case .listening(let port) = state else { return [] }
        if let cache = endpointCache, cache.port == port, now.timeIntervalSince(cache.at) < 30 { return cache.list }
        let list = CompanionEndpoints.current(port: port)
        endpointCache = (now, port, list)
        return list
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard open < Self.maxConnections else { connection.cancel(); return }
        open += 1
        let peer = CompanionPeer(TCPTransport(connection), counted: true)
        connection.stateUpdateHandler = { [weak self] new in
            switch new {
            case .failed, .cancelled: Task { @MainActor in self?.closed(peer) }
            default: break
            }
        }
        connection.start(queue: queue)
        expireUnlessSubscribed(peer)
        read(peer, connection: connection, reader: CompanionFrameReader())
    }

    /// A connection lives at most 30 seconds, unless the phone subscribed on it: then as long as it keeps talking.
    private func expireUnlessSubscribed(_ peer: CompanionPeer) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            Task { @MainActor in if peer.streamID == nil { peer.transport.cancel() } }
        }
    }

    private func closed(_ peer: CompanionPeer) {
        guard !peer.closed else { return }
        peer.closed = true
        if peer.counted { open = max(0, open - 1) }
        let wasLive = streams.contains { $0 === peer }
        if wasLive {
            CompanionDiagnosticsLog.mac.record("streamClosed", ["device": peer.deviceID ?? "", "via": peer.counted ? "direct" : "relay",
                                                                "quiet": String(Int(Date().timeIntervalSince(peer.lastHeard)))])
        }
        streams.removeAll { $0 === peer }
        if streams.isEmpty { streamTimer?.invalidate(); streamTimer = nil }
        if wasLive { KeepAwake.shared.update() }
    }

    private func read(_ peer: CompanionPeer, connection: NWConnection, reader: CompanionFrameReader) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            var reader = reader
            guard let self else { return }
            if let data, !data.isEmpty {
                let frames = reader.feed(data)
                if reader.overflowed { connection.cancel(); return }
                let remaining = reader
                Task { @MainActor in
                    await self.dispatch(frames, peer: peer)
                    if !complete, error == nil { self.read(peer, connection: connection, reader: remaining) } else { connection.cancel() }
                }
            } else if complete || error != nil {
                connection.cancel()
            }
        }
    }

    private func dispatch(_ frames: [Data], peer: CompanionPeer) async {
        if peer.streamID != nil {
            // A live connection: a slow request (a question to Nook) must not hold up the pings behind it.
            for frame in frames { Task { await self.respond(to: frame, peer: peer) } }
        } else {
            for frame in frames { await respond(to: frame, peer: peer) }
        }
    }

    // MARK: Through the relay

    /// A phone connected through the relay (`CompanionRelayClient`): from here on it is a connection like any other.
    func relayOpened(_ transport: CompanionTransport) -> CompanionPeer {
        let peer = CompanionPeer(transport, counted: false)
        expireUnlessSubscribed(peer)
        return peer
    }

    /// Bytes from a phone through the relay, in the order they came.
    func relayReceived(_ peer: CompanionPeer, data: Data) {
        let frames = peer.reader.feed(data)
        if peer.reader.overflowed { peer.transport.cancel(); return }
        guard !frames.isEmpty else { return }
        peer.pending = peer.pending.then { [weak self] in await self?.dispatch(frames, peer: peer) }
    }

    func relayClosed(_ peer: CompanionPeer) { closed(peer) }

    private func send(_ response: CompanionResponse, key: Data, deviceID: String, on transport: CompanionTransport) {
        // Only what this phone may see, and only the features it may use (`CompanionScopes`).
        let response = CompanionScopes.redact(response, granted: scopes(of: deviceID))
        guard let json = try? JSONEncoder().encode(response),
              let sealed = try? CompanionSeal.seal(json, pairingKey: key, deviceID: deviceID, direction: .response),
              let framed = CompanionFrameReader.frame(sealed) else { return }
        transport.send(framed)
    }

    private func respond(to frame: Data, peer: CompanionPeer) async {
        let connection = peer.transport
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
        peer.lastHeard = Date()
        // What this phone may do is decided on the Mac (Settings › Devices); anything else is refused before it runs.
        if !pairing, !CompanionScopes.allows(request.op, granted: scopes(of: claimed)) {
            CompanionDiagnosticsLog.mac.record("refused", ["op": request.op.rawValue, "error": "scope", "device": claimed])
            send(.failure(request.id, .notAllowedFromPhone, message: "scope"), key: key, deviceID: claimed, on: connection)
            return
        }
        let keeps = !pairing && CommandReceipts.keeps(request.op)
        if keeps {
            // A repeat of a request that changes something (its answer got lost, or it waited in the phone's outbox):
            // the answer it got, without doing it again; while the first is still being carried out, its answer once
            // it is there.
            switch receipts[claimed, default: CommandReceipts()].begin(request.id, now: Date()) {
            case .answered(let earlier):
                let refusal = guards[claimed, default: RequestGuard()].admitRetry(request, now: Date())
                send(refusal.map { CompanionResponse.failure(request.id, $0) } ?? earlier, key: key, deviceID: claimed, on: connection)
                return
            case .running:
                if let refusal = guards[claimed, default: RequestGuard()].admitRetry(request, now: Date()) {
                    send(.failure(request.id, refusal), key: key, deviceID: claimed, on: connection)
                    return
                }
                let slot = claimed + "|" + request.id
                let earlier = await withCheckedContinuation { continuation in
                    running[slot, default: []].append(continuation)
                }
                send(earlier, key: key, deviceID: claimed, on: connection)
                return
            case .new:
                break
            }
        }
        // The guard lives per device and is changed in place: a repeated id or a burst is refused from here on.
        if let refusal = guards[claimed, default: RequestGuard()].admit(request, now: Date()) {
            if keeps { receipts[claimed]?.cancel(request.id) }
            CompanionDiagnosticsLog.mac.record("refused", ["op": request.op.rawValue, "error": refusal.rawValue, "device": claimed,
                                                           "skew": String(Int(Date().timeIntervalSince1970 - request.sent))])
            send(.failure(request.id, refusal), key: key, deviceID: claimed, on: connection)
            return
        }

        if pairing {
            guard request.op == .hello, store.completePairing(name: request.text ?? "") != nil else {
                send(.failure(request.id, .badRequest), key: key, deviceID: claimed, on: connection)
                return
            }
            audit("paired", request.text ?? "iPhone")
            CompanionDiagnosticsLog.mac.record("paired", ["device": claimed, "relay": peer.counted ? "no" : "yes"])
        } else {
            store.touch(claimed)
        }
        if [CompanionOp.hello, .list, .subscribe].contains(request.op) {
            store.noteVersions(device: claimed, protocolVersion: request.protocolVersion,
                               appVersion: CompanionProtocol.cleanVersion(request.appVersion))
        }
        if request.op == .subscribe, !pairing {
            subscribe(peer, request: request, deviceID: claimed, key: key)
            return
        }
        let response = await handle(request, deviceID: claimed)
        if keeps {
            receipts[claimed, default: CommandReceipts()].finish(request.id, response, now: Date())
            // Failed in passing: the phone may send the same id again (its outbox does), and it must get through.
            if !CommandReceipts.settles(response) { guards[claimed]?.forget(request) }
            // Repeats that came while it ran get the same answer.
            for waiter in running.removeValue(forKey: claimed + "|" + request.id) ?? [] { waiter.resume(returning: response) }
        }
        send(response, key: key, deviceID: claimed, on: connection)
    }

    // MARK: Live connections

    /// Keeps the connection open for this phone and answers like `list`; from now on the sessions follow by themselves.
    private func subscribe(_ peer: CompanionPeer, request: CompanionRequest, deviceID: String, key: Data) {
        guard let app else { send(.failure(request.id, .failed), key: key, deviceID: deviceID, on: peer.transport); return }
        // One live connection per phone: a newer one (another network, the app restarted) replaces the older.
        for old in streams where old !== peer && old.deviceID == deviceID { old.transport.cancel() }
        streams.removeAll { $0 !== peer && $0.deviceID == deviceID }
        peer.deviceID = deviceID
        peer.key = key
        peer.streamID = request.id
        peer.seq = 0
        CompanionDiagnosticsLog.mac.record("subscribed", ["device": deviceID, "via": peer.counted ? "direct" : "relay",
                                                          "protocol": request.protocolVersion.map { String($0) } ?? "1"])
        let sessions = digests(app)
        peer.sent = sessions
        if !streams.contains(where: { $0 === peer }) { streams.append(peer) }
        KeepAwake.shared.update()
        send(Self.versioned(CompanionResponse(id: request.id, ok: true, macName: MachineName.local, sessions: sessions,
                                              features: CompanionFeature.all, endpoints: endpoints(),
                                              relay: CompanionRelayClient.shared.advertised)),
             key: key, deviceID: deviceID, on: peer.transport)
        if streamTimer == nil {
            // Closes connections that went quiet (a phone that left without saying so) and catches changes the
            // workspace does not announce (agents in a terminal).
            streamTimer = Timer.scheduledCoalesced(withTimeInterval: 5) { [weak self] _ in
                Task { @MainActor in self?.checkStreams() }
            }
        }
    }

    private func checkStreams(now: Date = Date()) {
        let paired = Set(CompanionStore.shared.devices.map(\.id))
        for peer in streams where now.timeIntervalSince(peer.lastHeard) > CompanionTiming.streamIdle
            || !paired.contains(peer.deviceID ?? "") {
            peer.transport.cancel()
        }
        pushChanges()
    }

    /// Sends every subscribed phone the sessions, when they changed since it last got them.
    private func pushChanges() {
        guard let app, !streams.isEmpty else { return }
        let sessions = digests(app)
        for peer in streams where peer.sent != sessions {
            guard let key = peer.key, let deviceID = peer.deviceID, let id = peer.streamID else { continue }
            peer.seq += 1
            peer.sent = sessions
            send(CompanionResponse(id: id, ok: true, sessions: sessions, seq: peer.seq), key: key, deviceID: deviceID, on: peer.transport)
        }
    }

    /// What a paired phone may do; nothing beyond keeping the connection for a key without a device.
    private func scopes(of deviceID: String) -> Set<CompanionScope> {
        CompanionStore.shared.devices.first { $0.id == deviceID }?.grantedScopes ?? []
    }

    /// Ends a phone's live connections, so it connects again and learns what it may do now.
    func dropStreams(for deviceID: String) {
        for peer in streams where peer.deviceID == deviceID { peer.transport.cancel() }
    }

    func audit(_ action: String, _ detail: String) {
        app?.store.audit(tool: "companion_" + action, args: detail, result: "ok")
    }

    // MARK: Requests

    private func handle(_ request: CompanionRequest, deviceID: String) async -> CompanionResponse {
        guard let app else { return .failure(request.id, .failed) }
        let workspace = app.workspace
        let macName = MachineName.local
        switch request.op {
        case .hello, .list, .subscribe:
            return Self.versioned(CompanionResponse(id: request.id, ok: true, macName: macName, sessions: digests(app),
                                                    features: CompanionFeature.all, endpoints: endpoints(),
                                                    relay: CompanionRelayClient.shared.advertised))
        case .ping:
            return CompanionResponse(id: request.id, ok: true)
        case .requestUpdate:
            // Only opens the update panel, where installing stays a click on the Mac; nothing is installed from here.
            let updater = AppUpdater.shared
            if case .unavailable = updater.phase { return CompanionResponse(id: request.id, ok: true, message: "unavailable") }
            guard updater.available != nil else { return CompanionResponse(id: request.id, ok: true, message: "none") }
            updater.showPanel()
            audit("update_request", CompanionStore.shared.devices.first { $0.id == deviceID }?.name ?? "")
            return CompanionResponse(id: request.id, ok: true, message: "available")
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
        case .liveActivity:
            guard let live = request.live, live.isValid else { return .failure(request.id, .badRequest) }
            CompanionStore.shared.applyLive(device: deviceID, live)
            if live.kind == .off || live.kind == .pushToStart {
                audit(live.kind == .off ? "live_off" : "live_registered", CompanionStore.shared.devices.first { $0.id == deviceID }?.name ?? "")
            }
            CompanionNotifier.shared.refreshLiveActivities()
            return CompanionResponse(id: request.id, ok: true, macName: macName,
                                     message: CompanionStore.shared.canPush && CompanionStore.shared.push.enabled ? "push" : "nopush")
        case .decide:
            // An agent in a terminal on the Mac, or a request through the workspace bridge.
            if let session = request.session, CompanionAgents.handles(session) {
                let allow = request.allow == true
                if let error = CompanionAgents.decide(app, session: session, item: request.item ?? "", allow: allow) {
                    return .failure(request.id, error)
                }
                audit(allow ? "allow" : "deny", session)
                return CompanionResponse(id: request.id, ok: true, sessions: digests(app))
            }
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
            return CompanionResponse(id: request.id, ok: true, sessions: digests(app))
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
            return CompanionResponse(id: request.id, ok: true, sessions: digests(app))
        case .send:
            // An agent outside Nook (the Claude app, a terminal): answered as on the Mac, by continuing it in Nook.
            if let session = request.session, CompanionAgents.handles(session) {
                guard let text = CompanionPolicy.cleanMessage(request.text ?? "") else { return .failure(request.id, .badRequest) }
                if let error = await CompanionAgents.send(app, session: session, text: text) { return .failure(request.id, error) }
                audit("send", session)
                return CompanionResponse(id: request.id, ok: true, sessions: digests(app), message: "sent")
            }
            guard let runID = request.session.flatMap(UUID.init(uuidString:)), let run = workspace.run(runID) else {
                return .failure(request.id, .unknownSession)
            }
            guard let text = CompanionPolicy.cleanMessage(request.text ?? "") else { return .failure(request.id, .badRequest) }
            // While it works: into the running turn when the phone asks to steer and the turn can take it (as the Mac's
            // composer steers), else in line for after the turn.
            let outcome: String
            if !run.status.isActive {
                workspace.send(runID, text: text)
                outcome = "sent"
            } else if request.steer == true, workspace.canSteer(runID), workspace.steer(runID, text: text) {
                outcome = "steered"
            } else {
                workspace.enqueue(runID, text: text)
                outcome = "queued"
            }
            audit(outcome == "steered" ? "steer" : "send", run.title)
            return CompanionResponse(id: request.id, ok: true, sessions: digests(app), message: outcome)
        case .stop:
            guard let runID = request.session.flatMap(UUID.init(uuidString:)), let run = workspace.run(runID) else {
                return .failure(request.id, .unknownSession)
            }
            workspace.stop(runID)
            audit("stop", run.title)
            return CompanionResponse(id: request.id, ok: true, sessions: digests(app))
        case .options:
            return await launchOptions(request, app: app)
        case .start:
            return await launch(request, app: app)
        case .timeline:
            return await timeline(request, app: app)
        case .manage:
            return manage(request, app: app)
        case .chats:
            return chats(request, app: app)
        case .chat:
            return chat(request, app: app)
        case .ask:
            return ask(request, app: app)
        case .chatStop:
            return stopChat(request, app: app)
        case .home:
            return home(request, app: app)
        case .usage:
            return usage(request, app: app)
        case .music:
            return music(request, app: app)
        case .inbox:
            return inbox(request, app: app)
        case .inboxChat:
            return await inboxChat(request, app: app)
        case .inboxSend:
            return await inboxSend(request, app: app)
        case .inboxMark:
            return inboxMark(request, app: app)
        }
    }

    /// An answer to `hello`, `list` or `subscribe`, with the versions this Mac speaks (`CompanionProtocol`).
    private static func versioned(_ response: CompanionResponse) -> CompanionResponse {
        var response = response
        response.protocolVersion = CompanionProtocol.version
        response.oldestPhone = CompanionProtocol.oldestPhone
        response.appVersion = CompanionProtocol.appVersion
        return response
    }

    private func canAllow(_ pending: PendingPermission) -> Bool {
        var safe: Bool?
        if let command = (pending.input.object as? [String: Any])?["command"] as? String {
            safe = CommandRisk.assess(command).level == .safe
        }
        return CompanionPolicy.canAllow(tool: pending.tool, commandIsSafe: safe)
    }

    /// Workspace sessions, then agents running in a terminal and bridge requests (`CompanionAgents`).
    func digests(_ app: AppModel) -> [SessionDigest] {
        digests(app.workspace) + CompanionAgents.digests(app)
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
            // From memory only: the phone asks every few seconds, and reading released timelines back from disk would
            // also keep them all in memory.
            let lastAnswer = workspace.lastAnswer(run.id)
            return SessionDigest(id: run.id.uuidString, title: CompanionPolicy.excerpt(run.title), agent: run.provider.displayName,
                                 attention: String(describing: workspace.attention(run, unseen: false, now: now)),
                                 folder: URL(fileURLWithPath: run.workingDirectory).lastPathComponent, branch: run.branch,
                                 updated: run.updatedAt.timeIntervalSince1970, excerpt: CompanionPolicy.excerpt(lastAnswer), items: items,
                                 model: (run.resolvedModel ?? run.model).isEmpty ? nil : CompanionPolicy.excerpt(run.resolvedModel ?? run.model),
                                 actions: Self.actions(run, now: now).map(\.rawValue),
                                 canSteer: workspace.canSteer(run.id))
        }
    }
}

extension CompanionDiagnosticsLog {
    /// The Mac's companion log (docs/COMPANION.md, "Diagnostics"): local only, copied redacted from Settings › Devices.
    static let mac = CompanionDiagnosticsLog(url: NookPaths.supportDirectory.appendingPathComponent("companion-diagnostics.ndjson"))
}

/// One connection from a phone (directly, or through the relay), and what the Mac knows about it once the phone
/// subscribed on it.
@MainActor
final class CompanionPeer {
    let transport: CompanionTransport
    /// A direct connection, counted against `CompanionServer.maxConnections`; the relay limits its own.
    let counted: Bool
    var closed = false
    /// Bytes through the relay that do not make a whole frame yet, and the frames still being answered, in order.
    var reader = CompanionFrameReader()
    var pending = SerialTail()
    /// When the phone last sent anything (a request or a ping).
    var lastHeard = Date()
    /// Set when the phone subscribed: the id every update carries, the phone and its key, and what it was sent.
    var streamID: String?
    var deviceID: String?
    var key: Data?
    var seq = 0
    var sent: [SessionDigest]?

    init(_ transport: CompanionTransport, counted: Bool) {
        self.transport = transport
        self.counted = counted
    }
}

/// How the Mac answers a phone: a direct TCP connection, or a connection through the relay.
@MainActor
protocol CompanionTransport: AnyObject {
    func send(_ data: Data)
    /// Ends the connection; the server hears of it as for any other close.
    func cancel()
}

@MainActor
final class TCPTransport: CompanionTransport {
    private let connection: NWConnection

    init(_ connection: NWConnection) { self.connection = connection }

    func send(_ data: Data) { connection.send(content: data, completion: .contentProcessed { _ in }) }
    func cancel() { connection.cancel() }
}

/// Runs work one after another: each piece starts when the previous one finished.
@MainActor
struct SerialTail {
    private var last: Task<Void, Never>?

    func then(_ work: @escaping @MainActor () async -> Void) -> SerialTail {
        let previous = last
        var next = SerialTail()
        next.last = Task { @MainActor in
            await previous?.value
            await work()
        }
        return next
    }
}
