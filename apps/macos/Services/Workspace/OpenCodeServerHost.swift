import Foundation

/// An answer of the OpenCode server: its HTTP status and JSON, or why there was none.
struct OpenCodeReply: Sendable {
    var status: Int
    var json: JSONBox?
    /// Set when no answer came (the server is gone, a timeout), or for an error status: its message.
    var error: String?

    var ok: Bool { (200..<300).contains(status) && error == nil }
    var notFound: Bool { status == 404 }
}

enum OpenCodeServerError: Error, Equatable {
    /// This OpenCode has no server Nook speaks (1.x, or a version that would not tell): the session uses ACP.
    case unsupported(String?)
    case launch(String)
    case timeout
    case exited(String)

    var localizedDescription: String {
        switch self {
        case .unsupported(let version): return "OpenCode \(version ?? "?") has no server Nook can use"
        case .launch(let message): return message
        case .timeout: return "The OpenCode server did not start in time."
        case .exited(let stderr): return stderr.isEmpty ? "The OpenCode server stopped." : stderr
        }
    }
}

/// One `opencode serve` Nook started for an account: bound to 127.0.0.1 on a port the system picks, with a password
/// only Nook knows, kept in memory (`OpenCodeServe`). It is an `AgentProcess`, so it runs behind your own work, is
/// stopped and waited for when Nook quits (`QuitShutdown`), and the ledger stops what a crashed Nook left behind. Its event
/// stream stays open while it runs; a dropped stream is opened again (`onReconnected` then lets the sessions catch up).
@MainActor
final class OpenCodeServerHost {
    enum State: Equatable { case starting, ready, stopped }

    let key: String
    let executable: String
    private let password = OpenCodeServe.makePassword()
    private var process: AgentProcess?
    private(set) var baseURL: URL?
    private(set) var version: String?
    private(set) var state: State = .starting
    private var waiters: [(Result<Void, OpenCodeServerError>) -> Void] = []
    private var stream: OpenCodeEventStream?
    private var streamFailures = 0
    private var startTimeout: Task<Void, Never>?
    private var everConnected = false

    /// Events of the stream, in order, on the main thread.
    var onEvents: (([OpenCodeEvent]) -> Void)?
    /// The stream was open again after a drop: what was said meanwhile is lost, so the sessions look for themselves.
    var onReconnected: (() -> Void)?
    /// The server ended after it was ready, with what it last wrote to stderr.
    var onGone: ((String) -> Void)?

    private static let startSeconds: UInt64 = 30
    private static let reconnectAttempts = 5

    init(key: String, executable: String) {
        self.key = key
        self.executable = executable
    }

    /// Calls `done` once the server answers and its stream is open (at once when it already is).
    func whenReady(_ done: @escaping (Result<Void, OpenCodeServerError>) -> Void) {
        switch state {
        case .ready: done(.success(()))
        case .stopped: done(.failure(.exited("")))
        case .starting: waiters.append(done)
        }
    }

    /// Starts the server for an account (`environment`: the account's variables). Its version is read first: an
    /// OpenCode without the server API Nook speaks is not started at all.
    func start(environment: [String: String], workingDirectory: String) {
        let executable = executable
        startTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.startSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.state == .starting else { return }
            self.fail(.timeout)
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let version = Self.installedVersion(executable)
            await self?.launch(version: version, environment: environment, workingDirectory: workingDirectory)
        }
    }

    private func launch(version: String?, environment: [String: String], workingDirectory: String) {
        guard state == .starting else { return }
        guard OpenCodeServe.supports(version: version) else { return fail(.unsupported(version)) }
        self.version = version
        var extra = environment
        extra[OpenCodeServe.passwordVariable] = password
        var spec = LaunchSpec(executable: executable, arguments: OpenCodeServe.arguments, extraEnvironment: extra,
                              workingDirectory: workingDirectory, initialInput: [], keepsInputOpen: true)
        spec.removedEnvironment = OpenCodeServe.removedEnvironment
        let process = AgentProcess(spec: spec)
        process.onLines = { [weak self] lines in
            guard let url = lines.lazy.compactMap(OpenCodeServe.listeningURL(inLine:)).first else { return }
            Task { @MainActor in self?.listening(at: url) }
        }
        process.onExit = { [weak self] status, stderr in
            Task { @MainActor in self?.exited(status: status, stderr: stderr) }
        }
        do {
            try process.start()
        } catch {
            return fail(.launch(error.localizedDescription))
        }
        self.process = process
    }

    private func listening(at url: URL) {
        guard state == .starting, baseURL == nil else { return }
        baseURL = url
        Task {
            // The server says it listens before every route is up: its info is asked a few times.
            for attempt in 0..<10 {
                let info = await self.send("GET", "/api/info", timeout: 5)
                guard self.state == .starting else { return }
                if info.ok {
                    let reported = info.json?.dictionary["version"] as? String
                    guard OpenCodeServe.supports(version: reported ?? self.version) else { return self.fail(.unsupported(reported)) }
                    if let reported { self.version = reported }
                    return self.openStream()
                }
                if info.status == 401 { return self.fail(.launch("The OpenCode server rejected Nook's password.")) }
                // A 1.x server answers its own pages here, not OpenCode 2's info.
                if info.notFound { return self.fail(.unsupported(self.version)) }
                try? await Task.sleep(nanoseconds: UInt64(200_000_000 * (attempt + 1)))
            }
            self.fail(.launch("The OpenCode server did not answer."))
        }
    }

    private func openStream() {
        guard let baseURL, state != .stopped else { return }
        stream?.cancel()
        let stream = OpenCodeEventStream(url: baseURL.appendingPathComponent("api/event"),
                                         authorization: OpenCodeServe.authorization(password: password))
        stream.onEvents = { [weak self] events in
            Task { @MainActor in self?.received(events) }
        }
        stream.onEnd = { [weak self, weak stream] error in
            Task { @MainActor in
                guard let self, let stream, self.stream === stream else { return }
                self.streamEnded(error)
            }
        }
        self.stream = stream
        stream.start()
    }

    private func received(_ events: [OpenCodeEvent]) {
        guard state != .stopped else { return }
        if events.contains(.connected) {
            streamFailures = 0
            if state == .starting {
                state = .ready
                everConnected = true
                startTimeout?.cancel()
                let waiting = waiters
                waiters.removeAll()
                for waiter in waiting { waiter(.success(())) }
            } else if everConnected {
                onReconnected?()
            }
        }
        let work = events.filter { $0 != .connected }
        if !work.isEmpty { onEvents?(work) }
    }

    private func streamEnded(_ error: String?) {
        guard state != .stopped, process?.isRunning == true else { return }
        streamFailures += 1
        guard streamFailures <= Self.reconnectAttempts else {
            // The server no longer talks: what it still does cannot be followed, so it goes.
            let message = error ?? "The OpenCode server stopped sending events."
            stop()
            onGone?(message)
            return
        }
        let wait = UInt64(streamFailures) * 1_000_000_000
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait)
            guard let self, self.state != .stopped else { return }
            self.openStream()
        }
    }

    private func exited(status: Int32, stderr: String) {
        guard state != .stopped else { return }
        let wasReady = state == .ready
        state = .stopped
        stream?.cancel()
        stream = nil
        process = nil
        startTimeout?.cancel()
        let text = AgentLogLines.withoutLog(stderr.components(separatedBy: "\n")).joined(separator: "\n")
        if wasReady {
            onGone?(text)
        } else {
            finishWaiters(.failure(.exited(text)))
        }
    }

    private func fail(_ error: OpenCodeServerError) {
        guard state == .starting else { return }
        state = .stopped
        startTimeout?.cancel()
        stream?.cancel()
        stream = nil
        process?.onExit = nil
        process?.stop(grace: 1)
        process = nil
        finishWaiters(.failure(error))
    }

    private func finishWaiters(_ result: Result<Void, OpenCodeServerError>) {
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter(result) }
    }

    /// Stops the server and its stream; what still waits on it hears it is gone.
    func stop() {
        let wasStarting = state == .starting
        state = .stopped
        startTimeout?.cancel()
        stream?.cancel()
        stream = nil
        process?.onExit = nil
        process?.closeInput()
        process?.stop(grace: 1)
        process = nil
        if wasStarting { finishWaiters(.failure(.exited(""))) }
    }

    var isRunning: Bool { state != .stopped }

    // MARK: Requests

    /// One request to the server. Never throws: a server that is gone or slow answers with status 0 and an error.
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Any? = nil,
              timeout: TimeInterval = 30) async -> OpenCodeReply {
        guard let baseURL, var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return OpenCodeReply(status: 0, json: nil, error: "The OpenCode server is not running.")
        }
        components.path = path
        if !query.isEmpty {
            components.queryItems = query
            // `+` in a folder name would read as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { return OpenCodeReply(status: 0, json: nil, error: "Bad request path") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(OpenCodeServe.authorization(password: password), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body, JSONSerialization.isValidJSONObject(body) {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await Self.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.isEmpty ? nil : (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])).map(JSONBox.init)
            let error = (200..<300).contains(status) ? nil
                : (OpenCodeServe.errorMessage(json?.object) ?? "HTTP \(status)")
            return OpenCodeReply(status: status, json: json, error: error)
        } catch {
            return OpenCodeReply(status: 0, json: nil, error: error.localizedDescription)
        }
    }

    /// Requests go straight to the loopback server: no cookies, no cache, no proxy.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: configuration)
    }()

    /// What `--version` prints ("2.2.7"), read once per launch of the server; nil when it prints none in time.
    nonisolated private static func installedVersion(_ path: String) -> String? {
        let environment = AgentCommand.environment(base: ProcessInfo.processInfo.environment, executable: path, extra: [:])
        guard let result = try? ProcessRunner.run(path, ["--version"], environment: environment, timeout: 10) else { return nil }
        let text = String(decoding: result.stdoutData.prefix(4096), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).lazy.compactMap { CLIVersion(String($0)) }.first?.description
    }
}

/// The server's event stream (`GET /api/event`), read as it comes. Frames are decoded on the stream's own queue; the
/// host gets them in batches. Silence longer than the request timeout (heartbeats come every 10-15 s) ends the stream,
/// and the host opens it again.
final class OpenCodeEventStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let queue: OperationQueue
    private var session: URLSession?
    private var parser = SSEParser()
    private var pending = Data()
    private var failure: String?

    var onEvents: (@Sendable ([OpenCodeEvent]) -> Void)?
    var onEnd: (@Sendable (String?) -> Void)?

    init(url: URL, authorization: String) {
        var request = URLRequest(url: url)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        self.request = request
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "nook.opencode-events"
        super.init()
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        // The session keeps its delegate until it is invalidated (`cancel`, or the end of the stream).
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        session.dataTask(with: request).resume()
    }

    func cancel() {
        onEvents = nil
        onEnd = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            failure = "The OpenCode event stream answered HTTP \(status)."
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // What waits in `pending` holds no newline, so only the new bytes are searched: rescanning a multi-megabyte
        // event from its start for every chunk was quadratic in its size (as `AgentProcess.consume`).
        let waiting = pending.count
        pending.append(data)
        // Only whole lines: a character cut in two waits for its other half.
        guard let newline = data.lastIndex(of: 0x0A) else { return }
        let last = pending.index(pending.startIndex, offsetBy: waiting + data.distance(from: data.startIndex, to: newline))
        let chunk = pending[pending.startIndex...last]
        pending = Data(pending[pending.index(after: last)...])
        let events = parser.feed(String(decoding: chunk, as: UTF8.self)).compactMap { OpenCodeEvent.decode($0.data) }
        if !events.isEmpty { onEvents?(events) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let message = failure ?? error?.localizedDescription
        let end = onEnd
        session.finishTasksAndInvalidate()
        self.session = nil
        end?(message)
    }
}
