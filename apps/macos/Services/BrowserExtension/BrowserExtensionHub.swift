import Foundation

// Nook's side of its browser extension (apps/browser-extension). Each browser that runs the extension starts the host
// script (BrowserExtensionHost), which asks Nook over `browser.sock` for its next command with a long poll and passes
// the extension's own messages (hello, a question from its side panel, a command's result) as single requests. This file
// holds the bookkeeping: which browsers are there, which command waits for which browser, and which result belongs to
// which caller. It knows nothing of sockets or the app, depends only on Foundation, and so the core tests run it on Linux.

/// What a browser's extension answered to one command.
struct BrowserExtensionOutcome: Equatable, Sendable {
    var ok: Bool
    var text: String = ""
    var error: String = ""
    /// A screenshot as a data URL (`data:image/jpeg;base64,…`), only from `screenshot`.
    var image: String = ""

    /// What a tool hands back: the text, or what went wrong.
    var message: String { ok ? text : error }

    static let notConnected = BrowserExtensionOutcome(
        ok: false,
        error: "Nook's browser extension is not connected. The user can add it in Nook › Settings › Editor & browser › Nook in your browser; until then, use read_browser_tab to read the open page."
    )

    static func timedOut(after seconds: Int) -> BrowserExtensionOutcome {
        BrowserExtensionOutcome(ok: false, error: "The browser did not answer within \(seconds) s (it may be busy or asleep). Try again, or ask the user to look at the browser.")
    }
}

/// One browser that runs the extension, as its host told Nook.
struct BrowserExtensionClient: Equatable, Sendable {
    let id: String
    /// "Google Chrome", "Brave", "Microsoft Edge"…, from the extension's hello; empty until it said hello.
    var browser: String = ""
    var version: String = ""
    /// Its last request of any kind (a poll every half minute at the least, while it runs).
    var lastSeen: Date
    /// Its last hello or question: the browser the user used last, where a command goes when none is named.
    var lastActive: Date
}

final class BrowserExtensionHub: @unchecked Sendable {
    /// Sends one line back on the connection a request came in on; false when that connection is already gone.
    typealias Reply = (Data?) -> Bool

    /// The protocol version Nook speaks (`PROTOCOL_VERSION` in the extension's lib/core.js).
    static let protocolVersion = 1
    /// How long Nook holds a poll before it answers "idle"; the host asks again right away.
    static let pollHold: TimeInterval = 25
    /// A browser that has not polled for this long has quit, or its extension was turned off.
    static let staleAfter: TimeInterval = 70

    private struct Command {
        let id: String
        let line: Data
    }

    private let lock = NSLock()
    private var clients: [String: BrowserExtensionClient] = [:]
    private var polls: [String: (reply: Reply, token: Int)] = [:]
    private var queued: [String: [Command]] = [:]
    private var waiting: [String: (BrowserExtensionOutcome) -> Void] = [:]
    private var nextToken = 0
    private let timers: DispatchQueue
    private let clock: () -> Date

    /// Requests the hub does not answer itself (a question from the side panel, reading or stopping its conversation):
    /// the app answers them, once, through `reply`.
    var onRequest: ((_ client: BrowserExtensionClient, _ message: [String: Any], _ reply: @escaping Reply) -> Void)?
    /// A browser said hello (connected, or came back).
    var onClientsChanged: (() -> Void)?
    /// Nook's version, told to the extension in reply to its hello.
    var appVersion = ""

    init(clock: @escaping () -> Date = Date.init,
         timers: DispatchQueue = DispatchQueue(label: "app.nook.browser-extension.timers")) {
        self.clock = clock
        self.timers = timers
    }

    // MARK: - Browsers

    /// The browsers whose extension is connected now, the one used last first.
    var connected: [BrowserExtensionClient] {
        lock.lock()
        defer { lock.unlock() }
        return liveClients()
    }

    private func liveClients() -> [BrowserExtensionClient] {
        let now = clock()
        return clients.values
            .filter { now.timeIntervalSince($0.lastSeen) < Self.staleAfter }
            .sorted { $0.lastActive > $1.lastActive }
    }

    /// The browser a command goes to: the one named (by name, or part of it, or its id), else the one used last.
    private func target(_ preferred: String?) -> BrowserExtensionClient? {
        let live = liveClients()
        guard let preferred = preferred?.trimmingCharacters(in: .whitespacesAndNewlines), !preferred.isEmpty else { return live.first }
        return live.first { $0.id == preferred }
            ?? live.first { $0.browser.localizedCaseInsensitiveCompare(preferred) == .orderedSame }
            ?? live.first { !$0.browser.isEmpty && ($0.browser.localizedCaseInsensitiveContains(preferred) || preferred.localizedCaseInsensitiveContains($0.browser)) }
    }

    /// A host's id: letters, digits and dashes, as the script makes it. Anything else is not a host of Nook's.
    static func validClient(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    // MARK: - Requests from a host

    /// One request line from a host (`{"client": …, "message": {…}}`); answered exactly once through `reply`.
    func handle(_ data: Data, reply: @escaping Reply) {
        let line = data.split(separator: 10, maxSplits: 1, omittingEmptySubsequences: true).first.map { Data($0) } ?? Data()
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let client = object["client"] as? String, Self.validClient(client),
              let message = object["message"] as? [String: Any], let kind = message["kind"] as? String else {
            _ = reply(Self.encode(["ok": false, "error": "Not a message Nook knows."]))
            return
        }
        let seen = touch(client, active: kind != "poll" && kind != "result")
        switch kind {
        case "poll":
            poll(client, reply)
        case "result":
            finish(message)
            _ = reply(Self.encode(["ok": true]))
        case "hello":
            _ = reply(Self.encode(hello(client, message)))
            onClientsChanged?()
        default:
            if let onRequest {
                onRequest(seen, message, reply)
            } else {
                _ = reply(Self.encode(["ok": false, "error": "Nook is not ready."]))
            }
        }
    }

    @discardableResult
    private func touch(_ id: String, active: Bool) -> BrowserExtensionClient {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        var client = clients[id] ?? BrowserExtensionClient(id: id, lastSeen: now, lastActive: .distantPast)
        client.lastSeen = now
        if active { client.lastActive = now }
        clients[id] = client
        return client
    }

    private func hello(_ id: String, _ message: [String: Any]) -> [String: Any] {
        let version = (message["protocol"] as? Int) ?? 0
        guard version <= Self.protocolVersion else {
            return ["ok": false, "error": "This extension is newer than Nook. Update Nook to use it."]
        }
        lock.lock()
        if var client = clients[id] {
            client.browser = Self.short(message["browser"], limit: 60)
            client.version = Self.short(message["version"], limit: 20)
            clients[id] = client
        }
        lock.unlock()
        return ["ok": true, "name": "Nook", "version": appVersion, "protocol": Self.protocolVersion]
    }

    private static func short(_ value: Any?, limit: Int) -> String {
        let text = ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(limit).map(Character.init))
    }

    /// A host waits for its next command. A poll already waiting for the same host is answered "idle" (the host gave
    /// up on it); one that waits too long is answered "idle" too, and the host asks again.
    private func poll(_ client: String, _ reply: @escaping Reply) {
        lock.lock()
        nextToken += 1
        let token = nextToken
        let previous = polls.updateValue((reply, token), forKey: client)
        lock.unlock()
        _ = previous?.reply(Self.idle)
        deliver(client)
        timers.asyncAfter(deadline: .now() + Self.pollHold) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let expired = self.polls[client]?.token == token ? self.polls.removeValue(forKey: client) : nil
            self.lock.unlock()
            _ = expired?.reply(Self.idle)
        }
    }

    /// Hands queued commands to the host's waiting poll, one per poll. A poll whose connection is gone gives its
    /// command back to the queue.
    private func deliver(_ client: String) {
        while true {
            lock.lock()
            guard var queue = queued[client], !queue.isEmpty, let poll = polls.removeValue(forKey: client) else {
                lock.unlock()
                return
            }
            let command = queue.removeFirst()
            queued[client] = queue.isEmpty ? nil : queue
            lock.unlock()
            if poll.reply(command.line) { continue }
            lock.lock()
            if waiting[command.id] != nil { queued[client, default: []].insert(command, at: 0) }
            lock.unlock()
            return
        }
    }

    private func finish(_ message: [String: Any]) {
        guard let id = message["id"] as? String else { return }
        lock.lock()
        let completion = waiting.removeValue(forKey: id)
        lock.unlock()
        completion?(BrowserExtensionOutcome(ok: (message["ok"] as? Bool) ?? false, text: (message["text"] as? String) ?? "",
                                            error: (message["error"] as? String) ?? "", image: (message["image"] as? String) ?? ""))
    }

    // MARK: - Commands to a browser

    /// Sends a command to a browser's extension and waits for its result. `browser`: a browser's name or id; nil for
    /// the one the user used last.
    func call(_ method: String, params: [String: Any] = [:], browser: String? = nil, timeout: TimeInterval = 30) async -> BrowserExtensionOutcome {
        await withCheckedContinuation { continuation in
            send(method, params: params, browser: browser, timeout: timeout) { continuation.resume(returning: $0) }
        }
    }

    /// The same as `call`, with a completion handler that runs exactly once.
    func send(_ method: String, params: [String: Any], browser: String?, timeout: TimeInterval,
              completion: @escaping (BrowserExtensionOutcome) -> Void) {
        let id = UUID().uuidString
        let line = Self.encode(["kind": "command", "id": id, "method": method, "params": params])
        lock.lock()
        guard let client = target(browser) else {
            lock.unlock()
            completion(.notConnected)
            return
        }
        waiting[id] = completion
        queued[client.id, default: []].append(Command(id: id, line: line))
        lock.unlock()
        deliver(client.id)
        timers.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let expired = self.waiting.removeValue(forKey: id)
            if var queue = self.queued[client.id] {
                queue.removeAll { $0.id == id }
                self.queued[client.id] = queue.isEmpty ? nil : queue
            }
            self.lock.unlock()
            expired?(.timedOut(after: Int(timeout)))
        }
    }

    // MARK: - Lines

    static let idle = encode(["kind": "idle"])

    static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
    }
}
