import Foundation
import Network

/// A connection to the Mac that stays open (docs/COMPANION.md, "Staying connected"). The phone subscribes on it
/// (`CompanionOp.subscribe`): the Mac answers with the sessions and sends them again whenever they change. Requests
/// travel over the same connection and are matched to their answers by id. A ping every few seconds tells a live
/// connection from one that died without a word (iOS drops sockets of a suspended app that way); nothing back for
/// `CompanionTiming.silenceLimit` closes it, and `CompanionClient` connects again.
final class CompanionChannel: @unchecked Sendable {
    let route: CompanionRoute
    private let key: Data
    private let deviceID: String
    private let connection: NWConnection
    /// Through the relay: a WebSocket, one message per chunk of bytes.
    private let webSocket: Bool
    private let queue = DispatchQueue(label: "nook.companion.channel")
    private let onUpdate: @Sendable (CompanionResponse) -> Void

    // Touched on `queue` only.
    private var reader = CompanionFrameReader()
    private var waiting: [String: CheckedContinuation<CompanionResponse, Error>] = [:]
    private var opening: CheckedContinuation<Void, Error>?
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var closedError: Error?
    private var subscription: String?
    private var lastSeq = 0
    private var lastHeard = Date()
    private var heartbeat: DispatchSourceTimer?

    /// `onUpdate` gets what the Mac sends by itself (the sessions after a change), on the channel's queue. Nil when the
    /// route cannot be opened at all (a relay address that is not https).
    init?(route: CompanionRoute, key: Data, onUpdate: @escaping @Sendable (CompanionResponse) -> Void) {
        guard let connection = RouteLink.connection(route, key: key) else { return nil }
        self.route = route
        self.key = key
        self.deviceID = PairedDevice.identifier(forKey: key)
        self.onUpdate = onUpdate
        self.connection = connection
        self.webSocket = route.isRelay
    }

    /// Whether it is connected and not closed yet.
    var isOpen: Bool { queue.sync { closedError == nil && opening == nil } }

    func open(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if let closedError { return continuation.resume(throwing: closedError) }
                opening = continuation
                connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, self.opening != nil else { return }
                    self.fail(CompanionClientError.timeout)
                }
            }
        }
    }

    /// Sends a request and waits for its answer; a `subscribe` also makes this the connection the Mac's updates come on.
    func request(_ request: CompanionRequest, timeout: TimeInterval) async throws -> CompanionResponse {
        let framed = try Self.frame(request, key: key, deviceID: deviceID)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CompanionResponse, Error>) in
            queue.async { [self] in
                if let closedError { return continuation.resume(throwing: closedError) }
                if request.op == .subscribe {
                    subscription = request.id
                    lastSeq = 0
                }
                waiting[request.id] = continuation
                RouteLink.send(connection, framed, webSocket: webSocket) { [weak self] error in
                    if let error { self?.fail(error) }
                }
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.waiting.removeValue(forKey: request.id)?.resume(throwing: CompanionClientError.timeout)
                }
            }
        }
    }

    /// Pings the Mac every few seconds, and closes the connection when nothing came back for too long.
    func startHeartbeat() {
        queue.async { [self] in
            guard closedError == nil, heartbeat == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + CompanionTiming.pingEvery, repeating: CompanionTiming.pingEvery)
            timer.setEventHandler { [weak self] in self?.beat() }
            heartbeat = timer
            timer.resume()
        }
    }

    /// Returns once the connection is closed, for whatever reason.
    func waitClosed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if closedError != nil { continuation.resume() } else { closeWaiters.append(continuation) }
            }
        }
    }

    func close() {
        queue.async { [self] in fail(CompanionClientError.closed) }
    }

    /// A request, sealed for the Mac and framed.
    static func frame(_ request: CompanionRequest, key: Data, deviceID: String) throws -> Data {
        let sealed = try CompanionSeal.seal(try JSONEncoder().encode(request), pairingKey: key, deviceID: deviceID, direction: .request)
        guard let framed = CompanionFrameReader.frame(sealed) else { throw CompanionClientError.badRequest }
        return framed
    }

    // MARK: On the queue

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard let continuation = opening else { return }
            opening = nil
            lastHeard = Date()
            receive()
            continuation.resume()
        case .failed(let error), .waiting(let error):
            fail(error)
        case .cancelled:
            fail(CompanionClientError.closed)
        default:
            break
        }
    }

    private func receive() {
        RouteLink.receive(connection, webSocket: webSocket) { [weak self] data, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lastHeard = Date()
                for frame in self.reader.feed(data) { self.handle(frame) }
                if self.reader.overflowed { return self.fail(CompanionClientError.badRequest) }
            }
            if let error { return self.fail(error) }
            if complete { return self.fail(CompanionClientError.closed) }
            if self.closedError == nil { self.receive() }
        }
    }

    private func handle(_ frame: Data) {
        guard let plain = try? CompanionSeal.open(frame, pairingKey: key, direction: .response),
              let response = try? JSONDecoder().decode(CompanionResponse.self, from: plain) else {
            return fail(CompanionClientError.badRequest)
        }
        if let seq = response.seq, response.id == subscription {
            // An update the Mac sent by itself; one that does not move on (played back) changes nothing.
            guard seq > lastSeq else { return }
            lastSeq = seq
            onUpdate(response)
        } else if let continuation = waiting.removeValue(forKey: response.id) {
            continuation.resume(returning: response)
        }
        // Anything else (the answer to a ping) only showed that the connection lives.
    }

    private func beat() {
        if Date().timeIntervalSince(lastHeard) > CompanionTiming.silenceLimit { return fail(CompanionClientError.timeout) }
        guard let framed = try? Self.frame(CompanionRequest(op: .ping), key: key, deviceID: deviceID) else { return }
        RouteLink.send(connection, framed, webSocket: webSocket) { _ in }
    }

    private func fail(_ error: Error) {
        guard closedError == nil else { return }
        closedError = error
        heartbeat?.cancel()
        heartbeat = nil
        opening?.resume(throwing: error)
        opening = nil
        let pending = waiting
        waiting = [:]
        for continuation in pending.values { continuation.resume(throwing: error) }
        let waiters = closeWaiters
        closeWaiters = []
        for continuation in waiters { continuation.resume() }
        connection.cancel()
    }
}

/// Checks routes to the Mac: one short connection with one request each.
enum RouteProbe {
    /// The Mac's answer to `request` over `route`, or nil when nothing answered (or something that does not hold the
    /// pairing key: its answer cannot be opened).
    static func check(_ route: CompanionRoute, key: Data, request: CompanionRequest, timeout: TimeInterval) async -> CompanionResponse? {
        guard let framed = try? CompanionChannel.frame(request, key: key, deviceID: PairedDevice.identifier(forKey: key)),
              let reply = try? await Exchange.run(route: route, key: key, payload: framed, timeout: timeout),
              let opened = try? CompanionSeal.open(reply, pairingKey: key, direction: .response),
              let response = try? JSONDecoder().decode(CompanionResponse.self, from: opened),
              response.id == request.id else { return nil }
        return response
    }

    struct Picked {
        let route: CompanionRoute
        let answer: CompanionResponse
    }

    /// Checks every route at once and returns the best one that answered (`CompanionRoutes.pick`): the earlier routes get
    /// a short head start, so a LAN the phone already left does not hold up the Tailscale route. Each route gets its own
    /// request (`makeRequest`), since the Mac refuses a repeated id.
    static func pick(_ routes: [CompanionRoute], key: Data, makeRequest: () -> CompanionRequest) async -> Picked? {
        guard !routes.isEmpty else { return nil }
        let requests = routes.map { _ in makeRequest() }
        return await withTaskGroup(of: (Int, CompanionResponse?)?.self) { group in
            for (index, route) in routes.enumerated() {
                let request = requests[index]
                group.addTask { (index, await RouteProbe.check(route, key: key, request: request, timeout: CompanionTiming.routeCheckTimeout)) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(CompanionTiming.routeHeadStart * 1_000_000_000))
                return nil
            }
            var answers = [CompanionResponse?](repeating: nil, count: routes.count)
            var answered = [Bool?](repeating: nil, count: routes.count)
            var headStartPassed = false
            while let result = await group.next() {
                if let result {
                    answers[result.0] = result.1
                    answered[result.0] = result.1 != nil
                } else {
                    headStartPassed = true
                }
                switch CompanionRoutes.pick(answered, headStartPassed: headStartPassed) {
                case .route(let index):
                    group.cancelAll()
                    guard let answer = answers[index] else { return nil }
                    return Picked(route: routes[index], answer: answer)
                case .unreachable:
                    group.cancelAll()
                    return nil
                case .wait:
                    continue
                }
            }
            return nil
        }
    }
}

/// One short connection: send the frame, read until one whole frame came back, with a timeout. Cancelling the task
/// closes the connection at once.
enum Exchange {
    static func run(route: CompanionRoute, key: Data, payload: Data, timeout: TimeInterval = 8) async throws -> Data {
        guard let connection = RouteLink.connection(route, key: key) else { throw CompanionClientError.badRequest }
        let webSocket = route.isRelay
        let queue = DispatchQueue(label: "nook.companion.client")
        let box = Once()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                var reader = CompanionFrameReader()
                func finish(_ result: Result<Data, Error>) {
                    connection.cancel()
                    box.resume(result)
                }
                func receive() {
                    RouteLink.receive(connection, webSocket: webSocket) { data, complete, error in
                        if let data, !data.isEmpty {
                            let frames = reader.feed(data)
                            if let first = frames.first { return finish(.success(first)) }
                            if reader.overflowed { return finish(.failure(CompanionClientError.badRequest)) }
                        }
                        if error != nil || complete { return finish(.failure(CompanionClientError.closed)) }
                        receive()
                    }
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        RouteLink.send(connection, payload, webSocket: webSocket) { error in
                            if error != nil { finish(.failure(CompanionClientError.closed)) } else { receive() }
                        }
                    case .failed(let error): finish(.failure(error))
                    case .waiting(let error): finish(.failure(error))
                    default: break
                    }
                }
                box.install(continuation)
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(CompanionClientError.timeout)) }
            }
        } onCancel: {
            queue.async {
                connection.cancel()
                box.resume(.failure(CancellationError()))
            }
        }
    }

    /// Resumes a continuation once, however many callbacks race; a result that comes before the continuation waits for it.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?
        private var early: Result<Data, Error>?
        private var done = false

        func install(_ continuation: CheckedContinuation<Data, Error>) {
            lock.lock()
            if let early {
                done = true
                self.early = nil
                lock.unlock()
                continuation.resume(with: early)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func resume(_ result: Result<Data, Error>) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            guard let c = continuation else {
                if early == nil { early = result }
                lock.unlock()
                return
            }
            done = true
            continuation = nil
            lock.unlock()
            c.resume(with: result)
        }
    }
}

/// How a route is opened: TCP straight to the Mac, or a WebSocket to this pairing's room on the relay
/// (`CompanionRelay`). Either way the same sealed frames travel; the relay passes them on.
enum RouteLink {
    static func connection(_ route: CompanionRoute, key: Data) -> NWConnection? {
        if let relay = route.relay {
            guard let url = CompanionRelay.socketURL(relay: relay, room: CompanionRelay.room(forKey: key), role: .phone) else { return nil }
            let parameters: NWParameters = url.scheme == "wss" ? .tls : .tcp
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
            return NWConnection(to: .url(url), using: parameters)
        }
        guard let port = NWEndpoint.Port(rawValue: route.port) else { return nil }
        return NWConnection(host: NWEndpoint.Host(route.host), port: port, using: .tcp)
    }

    static func send(_ connection: NWConnection, _ data: Data, webSocket: Bool, completion: @escaping (NWError?) -> Void) {
        if webSocket {
            let context = NWConnection.ContentContext(identifier: "frame", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed(completion))
        } else {
            connection.send(content: data, completion: .contentProcessed(completion))
        }
    }

    /// Hands over the next bytes: `complete` when the other side ended the connection (for the relay: it closed the
    /// socket, for instance because the Mac is not connected to it).
    static func receive(_ connection: NWConnection, webSocket: Bool, handler: @escaping (Data?, Bool, NWError?) -> Void) {
        guard webSocket else {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                handler(data, complete, error)
            }
            return
        }
        connection.receiveMessage { data, context, _, error in
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .close?: handler(nil, true, error)
            case .binary?, .cont?: handler(data, false, error)
            default: handler(nil, error != nil, error)
            }
        }
    }
}

/// One detailed check of a route for "Why can't I connect?" (`CompanionDiagnosis`): like `RouteProbe.check`, but it
/// tells apart what went wrong (nothing there, something that does not hold the key, the relay's close code, a refusal).
enum RouteDiagnostics {
    static func probe(_ route: CompanionRoute, key: Data, timeout: TimeInterval = 5) async -> CompanionDiagnosis.RouteOutcome {
        let request = CompanionRequest(op: .ping)
        guard let framed = try? CompanionChannel.frame(request, key: key, deviceID: PairedDevice.identifier(forKey: key)),
              let connection = RouteLink.connection(route, key: key) else { return .unreachable }
        let webSocket = route.isRelay
        let queue = DispatchQueue(label: "nook.companion.diagnose")
        let started = Date()
        return await withCheckedContinuation { (continuation: CheckedContinuation<CompanionDiagnosis.RouteOutcome, Never>) in
            let once = OnceOutcome(continuation)
            var reader = CompanionFrameReader()
            var opened = false
            func finish(_ outcome: CompanionDiagnosis.RouteOutcome) {
                connection.cancel()
                once.resume(outcome)
            }
            func handle(_ frame: Data) {
                guard let plain = try? CompanionSeal.open(frame, pairingKey: key, direction: .response) else { return finish(.wrongKey) }
                guard let response = try? JSONDecoder().decode(CompanionResponse.self, from: plain), response.id == request.id else {
                    return finish(.wrongKey)
                }
                if response.ok {
                    finish(.answered(milliseconds: Int(Date().timeIntervalSince(started) * 1000)))
                } else {
                    finish(.refused(response.error ?? .failed))
                }
            }
            func feed(_ data: Data?) -> Bool {
                guard let data, !data.isEmpty else { return false }
                let frames = reader.feed(data)
                if let first = frames.first { handle(first); return true }
                if reader.overflowed { finish(.wrongKey); return true }
                return false
            }
            func receive() {
                if webSocket {
                    connection.receiveMessage { data, context, _, error in
                        let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                        if metadata?.opcode == .close { return finish(.closed(code: closeCode(metadata?.closeCode))) }
                        if feed(data) { return }
                        if error != nil { return finish(.closedWithoutAnswer) }
                        receive()
                    }
                } else {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                        if feed(data) { return }
                        // The Mac closes a connection whose key it does not know without a word.
                        if error != nil || complete { return finish(.closedWithoutAnswer) }
                        receive()
                    }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    opened = true
                    RouteLink.send(connection, framed, webSocket: webSocket) { error in
                        if error != nil { finish(.closedWithoutAnswer) } else { receive() }
                    }
                case .failed, .waiting: finish(opened ? .closedWithoutAnswer : .unreachable)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(opened ? .timedOut : .unreachable) }
        }
    }

    /// The number of a WebSocket close code (the relay's are private codes, 4000 and up).
    private static func closeCode(_ code: NWProtocolWebSocket.CloseCode?) -> Int {
        switch code {
        case .privateCode(let value)?: return Int(value)
        case .applicationCode(let value)?: return Int(value)
        case .protocolCode(let value)?: return Int(value.rawValue)
        case nil: return 1005
        @unknown default: return 1005
        }
    }

    /// Resumes a continuation once, however many callbacks race.
    private final class OnceOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CompanionDiagnosis.RouteOutcome, Never>?

        init(_ continuation: CheckedContinuation<CompanionDiagnosis.RouteOutcome, Never>) { self.continuation = continuation }

        func resume(_ value: CompanionDiagnosis.RouteOutcome) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }
}
