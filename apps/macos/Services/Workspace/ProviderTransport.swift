import Foundation

// The seam between `AgentProcess` and the agent's process: bytes to stdin, bytes from stdout and stderr, an exit and
// signals. In the app it is a real child process (`SpawnedProcess`); in tests a recorded transcript (`ReplayTransport`)
// plays the agent, so the real line handling and stream parsers run against what an agent really sent, without one
// installed.
//
// The transcript format is NDJSON, one entry per line; a traffic log (`ProviderTrafficLog`) writes the same format, so a
// recorded session can be saved as a fixture as it is:
//
//   {"type":"transcript_start","provider":"claude","scenario":"…"}
//   {"type":"expect_outbound","frame":{…}}   a line Nook writes to stdin (or "line":"…" for text that is not JSON)
//   {"type":"emit_inbound","frame":{…}}      a line the agent writes to stdout (or "line":"…")
//   {"type":"emit_stderr","text":"…"}
//   {"type":"expect_signal","signal":"SIGINT"}
//   {"type":"expect_close"}                  Nook closes stdin
//   {"type":"exit","status":0}
//   {"type":"truncated"}                     the log reached its size limit here

/// What `AgentProcess` needs from the process it talks to.
protocol ProviderTransport: AnyObject, Sendable {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    /// Starts it. stdout and stderr data arrive on background threads as it comes (empty data: end of stream); `onExit`
    /// gets the exit status (the signal number when a signal ended it).
    func start(_ options: SpawnedProcess.Options, onStdout: @escaping @Sendable (Data) -> Void,
               onStderr: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (Int32) -> Void) throws
    func write(_ data: Data) throws
    func closeInput()
    /// Signals the process and everything in its group.
    @discardableResult func signalGroup(_ signal: Int32) -> Bool
    /// Keeps the group signallable after the process exited, until `release()` (see `SpawnedProcess`).
    func hold()
    func release()
}

extension SpawnedProcess: ProviderTransport {
    func start(_ options: Options, onStdout: @escaping @Sendable (Data) -> Void, onStderr: @escaping @Sendable (Data) -> Void,
               onExit: @escaping @Sendable (Int32) -> Void) throws {
        try start(options, ledger: ProcessGroupLedger.current, onStdout: onStdout, onStderr: onStderr, onExit: onExit)
    }
}

// MARK: Transcript

/// A recorded conversation between Nook and an agent over stdio.
struct ProviderTranscript: Sendable {
    enum Entry: Equatable, Sendable {
        case start(provider: String, scenario: String)
        case inbound(String)
        /// What Nook must write next: a JSON frame that the written line must contain (`ProviderTranscript.matches`), or
        /// a plain line.
        case outbound(JSONBox?, line: String?)
        case stderr(String)
        case signal(Int32)
        case closeInput
        case exit(Int32)
        case truncated
    }

    var entries: [Entry]

    var provider: String {
        for case .start(let provider, _) in entries { return provider }
        return ""
    }

    struct ParseError: Error, Equatable {
        var line: Int
        var reason: String
    }

    static func parse(_ text: String) throws -> ProviderTranscript {
        var entries: [Entry] = []
        for (index, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let type = object["type"] as? String else { throw ParseError(line: index + 1, reason: "not a JSON entry") }
            let frame = object["frame"]
            let text = object["line"] as? String
            switch type {
            case "transcript_start":
                entries.append(.start(provider: object["provider"] as? String ?? "", scenario: object["scenario"] as? String ?? ""))
            case "emit_inbound":
                if let frame, JSONSerialization.isValidJSONObject(frame) {
                    entries.append(.inbound(JSONBox(frame).json))
                } else if let text {
                    entries.append(.inbound(text))
                } else {
                    throw ParseError(line: index + 1, reason: "emit_inbound without frame or line")
                }
            case "expect_outbound":
                guard frame != nil || text != nil else { throw ParseError(line: index + 1, reason: "expect_outbound without frame or line") }
                entries.append(.outbound(frame.map(JSONBox.init), line: text))
            case "emit_stderr":
                entries.append(.stderr(object["text"] as? String ?? ""))
            case "expect_signal":
                guard let name = object["signal"] as? String, let number = signalNumbers[name] else {
                    throw ParseError(line: index + 1, reason: "unknown signal")
                }
                entries.append(.signal(number))
            case "expect_close":
                entries.append(.closeInput)
            case "exit":
                entries.append(.exit(Int32((object["status"] as? Int) ?? (object["status"] as? NSNumber)?.intValue ?? 0)))
            case "truncated":
                entries.append(.truncated)
            default:
                // Notes and entries of a newer format are skipped.
                continue
            }
        }
        return ProviderTranscript(entries: entries)
    }

    static let signalNumbers: [String: Int32] = ["SIGINT": SIGINT, "SIGTERM": SIGTERM, "SIGKILL": SIGKILL]

    static func signalName(_ number: Int32) -> String {
        signalNumbers.first { $0.value == number }?.key ?? "\(number)"
    }

    /// Does a line Nook wrote satisfy an `expect_outbound` entry? A frame matches when every key it names has the same
    /// value in the written JSON (objects are compared the same way, recursively; arrays and values exactly), so a
    /// fixture leaves out what changes from run to run, such as generated ids.
    static func matches(_ written: String, frame: JSONBox?, line: String?) -> Bool {
        let trimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
        if let frame {
            guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else { return false }
            return contains(object, frame.object)
        }
        return trimmed == line?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func contains(_ actual: Any, _ expected: Any) -> Bool {
        if let expected = expected as? [String: Any] {
            guard let actual = actual as? [String: Any] else { return false }
            return expected.allSatisfy { key, value in actual[key].map { contains($0, value) } ?? false }
        }
        return JSONBox([actual]).json == JSONBox([expected]).json
    }
}

// MARK: Replay

/// Plays an agent from a transcript: emits its stdout lines in order, and waits at each `expect_*` entry until Nook
/// wrote, signalled or closed what the transcript expects. What did not match is collected in `mismatches`.
final class ReplayTransport: ProviderTransport, @unchecked Sendable {
    private let transcript: ProviderTranscript
    private let lock = NSLock()
    private var cursor = 0
    private var started = false
    private var exited = false
    private var inputClosed = false
    private var pendingWrites: [String] = []
    private var pendingSignals: [Int32] = []
    private var writeBuffer = Data()
    private var handlers: (stdout: @Sendable (Data) -> Void, stderr: @Sendable (Data) -> Void, exit: @Sendable (Int32) -> Void)?
    private(set) var written: [String] = []
    private(set) var signals: [Int32] = []
    private(set) var mismatches: [String] = []
    /// The options `start` was called with.
    private(set) var options: SpawnedProcess.Options?

    init(_ transcript: ProviderTranscript) {
        self.transcript = transcript
    }

    var pid: Int32 { 0 }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started && !exited
    }

    /// Has every entry been played?
    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cursor >= transcript.entries.count
    }

    func start(_ options: SpawnedProcess.Options, onStdout: @escaping @Sendable (Data) -> Void,
               onStderr: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (Int32) -> Void) throws {
        lock.lock()
        self.options = options
        started = true
        handlers = (onStdout, onStderr, onExit)
        lock.unlock()
        advance()
    }

    func write(_ data: Data) throws {
        lock.lock()
        guard !exited, !inputClosed else {
            lock.unlock()
            return
        }
        // Lines may arrive in pieces or several at once.
        writeBuffer.append(data)
        while let newline = writeBuffer.firstIndex(of: 0x0A) {
            let line = String(decoding: writeBuffer[writeBuffer.startIndex..<newline], as: UTF8.self)
            writeBuffer.removeSubrange(writeBuffer.startIndex...newline)
            written.append(line)
            pendingWrites.append(line)
        }
        lock.unlock()
        advance()
    }

    func closeInput() {
        lock.lock()
        inputClosed = true
        lock.unlock()
        advance()
    }

    @discardableResult
    func signalGroup(_ signal: Int32) -> Bool {
        lock.lock()
        guard started, !exited else {
            lock.unlock()
            return false
        }
        signals.append(signal)
        pendingSignals.append(signal)
        lock.unlock()
        advance()
        return true
    }

    func hold() {}
    func release() {}

    /// Plays entries until one waits for Nook. Called again whenever Nook writes, signals or closes stdin.
    private func advance() {
        while true {
            lock.lock()
            guard let handlers, !exited, cursor < transcript.entries.count else {
                lock.unlock()
                return
            }
            let entry = transcript.entries[cursor]
            var output: (() -> Void)?
            switch entry {
            case .start, .truncated:
                break
            case .inbound(let line):
                output = { handlers.stdout(Data((line + "\n").utf8)) }
            case .stderr(let text):
                output = { handlers.stderr(Data(text.utf8)) }
            case .outbound(let frame, let line):
                guard !pendingWrites.isEmpty else {
                    lock.unlock()
                    return
                }
                let actual = pendingWrites.removeFirst()
                if !ProviderTranscript.matches(actual, frame: frame, line: line) {
                    mismatches.append("entry \(cursor + 1): expected \(frame?.json ?? line ?? ""), Nook wrote \(actual)")
                }
            case .signal(let expected):
                guard !pendingSignals.isEmpty else {
                    lock.unlock()
                    return
                }
                let actual = pendingSignals.removeFirst()
                if actual != expected {
                    mismatches.append("entry \(cursor + 1): expected \(ProviderTranscript.signalName(expected)), got \(ProviderTranscript.signalName(actual))")
                }
            case .closeInput:
                guard inputClosed else {
                    lock.unlock()
                    return
                }
            case .exit(let status):
                exited = true
                output = {
                    handlers.stdout(Data())
                    handlers.exit(status)
                }
            }
            cursor += 1
            lock.unlock()
            output?()
        }
    }
}

// MARK: Traffic Log

/// An opt-in, size-capped log of everything an agent and Nook said to each other over stdio, per session process. Off by
/// default (Settings › Workspace). It holds your prompts and the agent's answers as they were sent, so it stays on this
/// Mac (`workspace/provider-traffic`, folder 0700, files 0600); the environment, where keys and tokens live, is never
/// written. Its format is the replay transcript format, so a log can be copied into the test fixtures to reproduce a bug.
final class ProviderTrafficLog: @unchecked Sendable {
    static let enabledKey = "ws.providerTrafficLog"
    /// Per process; what comes after is left out, marked with a `truncated` entry.
    static let defaultMaxBytes = 4 * 1_048_576

    static var directory: URL {
        NookPaths.supportDirectory.appendingPathComponent("workspace", isDirectory: true)
            .appendingPathComponent("provider-traffic", isDirectory: true)
    }

    let url: URL
    private let maxBytes: Int
    private let lock = NSLock()
    private var handle: FileHandle?
    private var bytes = 0
    private var truncated = false

    /// A log for a session's agent when the setting is on; nil otherwise, and for processes that belong to no session.
    static func forLaunch(_ spec: LaunchSpec, defaults: UserDefaults = .standard, directory: URL? = nil,
                          now: Date = Date()) -> ProviderTrafficLog? {
        guard defaults.bool(forKey: enabledKey), let run = spec.extraEnvironment["NOOK_RUN_ID"], UUID(uuidString: run) != nil else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let folder = directory ?? Self.directory
        let provider = (spec.executable as NSString).lastPathComponent
        return ProviderTrafficLog(url: folder.appendingPathComponent("\(run)-\(formatter.string(from: now)).ndjson"), provider: provider)
    }

    init?(url: URL, provider: String, maxBytes: Int = defaultMaxBytes) {
        self.url = url
        self.maxBytes = maxBytes
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        guard fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = FileHandle(forWritingAtPath: url.path) else { return nil }
        self.handle = handle
        let recorded = ISO8601DateFormatter().string(from: Date())
        append(Self.entry(["type": "transcript_start", "provider": provider, "protocol": "stdio-ndjson", "recorded": recorded]))
    }

    deinit { try? handle?.close() }

    func inbound(_ line: String) { append(Self.frameEntry("emit_inbound", line)) }
    func outbound(_ line: String) { append(Self.frameEntry("expect_outbound", line.trimmingCharacters(in: .whitespacesAndNewlines))) }
    func stderr(_ text: String) { append(Self.entry(["type": "emit_stderr", "text": text])) }
    func signal(_ signal: Int32) { append(Self.entry(["type": "expect_signal", "signal": ProviderTranscript.signalName(signal)])) }
    func closedInput() { append(Self.entry(["type": "expect_close"])) }
    func exit(_ status: Int32) { append(Self.entry(["type": "exit", "status": Int(status)])) }

    /// A JSON line is embedded as it is (`frame`), anything else as text (`line`).
    static func frameEntry(_ type: String, _ line: String) -> String {
        if (try? JSONSerialization.jsonObject(with: Data(line.utf8))) is [String: Any] {
            return #"{"type":"\#(type)","frame":\#(line)}"#
        }
        return entry(["type": type, "line": line])
    }

    private static func entry(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func append(_ entry: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle, !truncated else { return }
        let data = Data((entry + "\n").utf8)
        if bytes + data.count > maxBytes {
            truncated = true
            try? handle.write(contentsOf: Data((Self.entry(["type": "truncated"]) + "\n").utf8))
            return
        }
        bytes += data.count
        try? handle.write(contentsOf: data)
    }
}
