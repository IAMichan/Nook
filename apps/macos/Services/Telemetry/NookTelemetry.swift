import Foundation
import Darwin
import Security

/// Where Settings keeps the OpenTelemetry export: the endpoints and protocol in UserDefaults, the headers (they often
/// carry an API key) in the Keychain through `SecretStore`.
enum OTLPSettings {
    static let headersAccount = "otlp.headers"
    static let protocolKey = "otlp.protocol"
    static func endpointKey(_ signal: OTLPSignal) -> String { "otlp.endpoint." + signal.rawValue }

    /// The saved settings. The headers are read only when there is an endpoint to send them to, so an unused export
    /// never touches the Keychain.
    static func load(defaults: UserDefaults = .standard, readHeaders: Bool) -> OTLPSaved {
        var saved = OTLPSaved()
        for signal in OTLPSignal.allCases {
            if let text = defaults.string(forKey: endpointKey(signal)), !text.isEmpty { saved.endpoints[signal] = text }
        }
        saved.protocolChoice = defaults.string(forKey: protocolKey).flatMap(OTLPProtocol.init(rawValue:)) ?? .httpProtobuf
        if readHeaders { saved.headers = SecretStore.read(headersAccount) ?? "" }
        return saved
    }

    static func saveEndpoint(_ text: String, for signal: OTLPSignal, defaults: UserDefaults = .standard) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { defaults.removeObject(forKey: endpointKey(signal)) } else { defaults.set(trimmed, forKey: endpointKey(signal)) }
    }

    static func saveProtocol(_ choice: OTLPProtocol, defaults: UserDefaults = .standard) {
        defaults.set(choice.rawValue, forKey: protocolKey)
    }

    /// Saves the headers; empty removes them. Returns false when the Keychain refused.
    @discardableResult
    static func saveHeaders(_ text: String) -> Bool {
        SecretStore.write(text, account: headersAccount) == errSecSuccess
    }

    static var hasSavedHeaders: Bool { SecretStore.read(headersAccount) != nil }
}

/// Nook's own OpenTelemetry export, and the receiver the agents are told about (`AgentTelemetry`).
///
/// Off by default and free when off: with no endpoint every call returns after one locked read, nothing is buffered,
/// no timer runs and no connection opens. When on, Nook records a few things of its own: each agent turn (a span with
/// the agent, model, outcome, duration and tokens, the same as sums, and a log record), each scheduled task run, and the
/// app's launch. Records wait in a `TelemetryBuffer` on a utility queue and go out together every few seconds as
/// OTLP/HTTP JSON. A receiver that does not answer loses that export and rests a minute; nothing is retried.
/// No prompts, answers, file contents, paths or session ids are sent.
final class NookTelemetry: @unchecked Sendable {
    static let shared = NookTelemetry()

    /// How long records wait before they go out together.
    static let flushDelay: TimeInterval = 10

    private let lock = NSLock()
    private var config = OTLPConfig()
    private var buffer = TelemetryBuffer()
    private var flushScheduled = false
    /// Per agent session: when its turn started and its usage then, so a turn's tokens are what it added.
    private var turnStarts: [UUID: (date: Date, usage: RunUsage)] = [:]
    private let queue = DispatchQueue(label: "nook.telemetry", qos: .utility)
    /// Made on first use (a Swift static is initialized once, thread-safely), so Nook without an endpoint never has one.
    private static let session: URLSession = makeSession()
    private var session: URLSession { Self.session }

    private init() {}

    /// The configuration in effect: Settings with Nook's environment on top.
    var current: OTLPConfig { lock.withLock { config } }

    /// What the agents Nook starts are told (empty when no endpoint is set).
    var agentConfig: OTLPConfig { current }

    /// Nook sends records of its own.
    var isExporting: Bool { lock.withLock { !config.isEmpty && !config.sdkDisabled } }

    /// Reads Settings and the environment again: at launch, and after a change in Settings.
    func reload(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let endpointsOnly = OTLPResolver.resolve(saved: OTLPSettings.load(readHeaders: false), environment: environment)
        let resolved = endpointsOnly.isEmpty
            ? endpointsOnly
            : OTLPResolver.resolve(saved: OTLPSettings.load(readHeaders: true), environment: environment)
        lock.withLock {
            config = resolved
            if resolved.isEmpty || resolved.sdkDisabled {
                buffer = TelemetryBuffer()
                turnStarts = [:]
            } else {
                // A changed receiver gets its chance at once.
                for signal in OTLPSignal.allCases { buffer.succeeded(signal) }
            }
        }
    }

    // MARK: What Nook records

    /// The app finished launching: a span from the process's start until now.
    func appLaunched(now: Date = Date()) {
        guard isExporting, let started = Self.processStart() else { return }
        let span = OTLPSpan(traceID: OTLPPayload.randomID(bytes: 16), spanID: OTLPPayload.randomID(bytes: 8),
                            name: "nook.app.launch", start: started, end: now)
        record { $0.add(span, now: now) }
    }

    /// An agent turn started (`WorkspaceManager.turnStart`).
    func turnStarted(_ id: UUID, usage: RunUsage, now: Date = Date()) {
        guard isExporting else { return }
        lock.withLock { turnStarts[id] = (now, usage) }
    }

    /// An agent turn ended (`WorkspaceManager.turnDidFinish`): a span, sums and a log record for it.
    func turnFinished(_ run: WorkspaceRun, now: Date = Date()) {
        guard isExporting else { return }
        guard let start = lock.withLock({ turnStarts.removeValue(forKey: run.id) }) else { return }
        let records = TelemetryRecords.turn(run, started: start.date, before: start.usage, now: now)
        record { buffer in
            buffer.add(records.span, now: now)
            for sum in records.sums { buffer.add(sum, now: now) }
            buffer.add(records.log, now: now)
        }
    }

    /// A scheduled task's run ended (`ScheduledTaskStore`).
    func scheduledRunFinished(status: ScheduledRunStatus, trigger: ScheduleTrigger?, started: Date?, now: Date = Date()) {
        guard isExporting else { return }
        var attributes: [String: OTLPValue] = ["nook.task.status": .string(status.rawValue)]
        if let trigger { attributes["nook.task.trigger"] = .string(trigger.rawValue) }
        let span = OTLPSpan(traceID: OTLPPayload.randomID(bytes: 16), spanID: OTLPPayload.randomID(bytes: 8),
                            name: "nook.scheduled_task.run", start: started ?? now, end: now, attributes: attributes,
                            ok: status != .failed, statusMessage: status == .failed ? "failed" : nil)
        let sum = OTLPSum(name: "nook.scheduled_task.runs", unit: "{run}", description: "Scheduled task runs",
                          attributes: attributes, value: 1)
        record { buffer in
            buffer.add(span, now: now)
            buffer.add(sum, now: now)
        }
    }

    // MARK: Sending

    private func record(_ change: (inout TelemetryBuffer) -> Void) {
        let schedule: Bool = lock.withLock {
            change(&buffer)
            guard !flushScheduled, !buffer.isEmpty else { return false }
            flushScheduled = true
            return true
        }
        if schedule { queue.asyncAfter(deadline: .now() + Self.flushDelay) { [weak self] in self?.flush() } }
    }

    private func flush() {
        let now = Date()
        let (batch, config) = lock.withLock { () -> ((spans: [OTLPSpan], logs: [OTLPLogRecord], sums: [OTLPSum], sumsSince: Date?), OTLPConfig) in
            flushScheduled = false
            return (buffer.drain(), self.config)
        }
        guard !config.isEmpty, !config.sdkDisabled else { return }
        let resource = Self.resource()
        let version = Self.version
        if let url = config.endpoint(.traces), !batch.spans.isEmpty {
            send(OTLPPayload.traces(batch.spans, resource: resource, version: version), to: url, signal: .traces, config: config)
        }
        if let url = config.endpoint(.metrics), !batch.sums.isEmpty {
            send(OTLPPayload.metrics(batch.sums, resource: resource, version: version, start: batch.sumsSince ?? now, end: now),
                 to: url, signal: .metrics, config: config)
        }
        if let url = config.endpoint(.logs), !batch.logs.isEmpty {
            send(OTLPPayload.logs(batch.logs, resource: resource, version: version), to: url, signal: .logs, config: config)
        }
    }

    private func send(_ body: Data, to url: URL, signal: OTLPSignal, config: OTLPConfig) {
        let request = Self.request(url, body: body, headers: config.headers)
        session.dataTask(with: request) { [weak self] _, response, error in
            let ok = error == nil && ((response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false)
            guard let self else { return }
            self.lock.withLock {
                if ok { self.buffer.succeeded(signal) } else { self.buffer.failed(signal, now: Date()) }
            }
        }.resume()
    }

    // MARK: Test

    enum TestResult: Equatable, Sendable {
        case ok(Int)
        case rejected(Int)
        case unreachable(String)
    }

    /// Sends an empty export of `signal` to `url`, as Settings' Test does; redirects are not followed.
    func test(_ signal: OTLPSignal, url: URL, headers: [OTLPHeader]) async -> TestResult {
        let request = Self.request(url, body: OTLPPayload.empty(signal), headers: headers)
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(status) ? .ok(status) : .rejected(status)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    // MARK: Helpers

    static func request(_ url: URL, body: Data, headers: [OTLPHeader]) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.httpBody = body
        for header in headers { request.setValue(header.value, forHTTPHeaderField: header.name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    /// Headers can carry a key: they go to the endpoint you set, never to wherever it redirects.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func resource() -> [String: OTLPValue] {
        [
            "service.name": .string("nook"),
            "service.version": .string(version),
            "os.type": .string("darwin"),
            "os.version": .string(ProcessInfo.processInfo.operatingSystemVersionString),
        ]
    }

    /// When this process started, from the kernel.
    static func processStart() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
