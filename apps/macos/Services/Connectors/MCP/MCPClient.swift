import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// A Model Context Protocol client: Nook can use the tools of any MCP server, local (a program it starts) or remote
// (an https address). The tools join Nook's own: they follow the source picker, read-only tools run during an answer,
// and everything else becomes an action that waits for the user's approval.

/// How to reach one MCP server. Holds no secrets: environment values and headers live in the Keychain.
struct MCPServerConfig: Codable, Identifiable, Equatable {
    enum Transport: Codable, Equatable {
        /// A local program speaking JSON-RPC over stdin/stdout, e.g. `npx -y @modelcontextprotocol/server-github`.
        case stdio(command: String, arguments: [String])
        /// A remote server over Streamable HTTP.
        case http(url: String)
    }

    var id: String
    var name: String
    var transport: Transport
    /// Names of environment variables (stdio) or headers (http) whose values are in the Keychain.
    var secretNames: [String] = []
    var enabled = true
    /// Signs in with OAuth (an https server that asked for it): the tokens are in the Keychain, refreshed by Nook.
    var usesOAuth: Bool?
    /// The built-in service this server was added for ("notion"), so Settings shows it under that service.
    var serviceID: String?

    var signsIn: Bool { usesOAuth == true }

    /// Source id in Nook's catalog: "mcp.linear".
    var sourceID: String { "mcp." + id }

    func secretKey(_ name: String) -> String { "connector.mcp.\(id).\(name)" }

    /// Parses a command line as typed by the user: `npx -y "@scope/server" --flag`.
    static func split(commandLine: String) -> (command: String, arguments: [String])? {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var hasWord = false
        for character in commandLine {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" { quote = character; hasWord = true; continue }
            if character == " " || character == "\t" {
                if hasWord || !current.isEmpty { words.append(current); current = ""; hasWord = false }
                continue
            }
            current.append(character)
        }
        if hasWord || !current.isEmpty { words.append(current) }
        guard let first = words.first, !first.isEmpty else { return nil }
        return (first, Array(words.dropFirst()))
    }
}

/// A tool as an MCP server describes it.
struct MCPTool: Equatable {
    var name: String
    var description: String
    var inputSchema: [String: Any]
    /// The server says this tool only reads. Anything else is treated as an action that needs approval.
    var readOnly: Bool

    static func == (a: MCPTool, b: MCPTool) -> Bool { a.name == b.name && a.description == b.description && a.readOnly == b.readOnly }

    init(name: String, description: String, inputSchema: [String: Any], readOnly: Bool) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
    }

    init?(_ object: [String: Any]) {
        guard let name = object["name"] as? String, !name.isEmpty else { return nil }
        self.name = name
        // Descriptions come from the server: treat them as untrusted text and keep them short.
        let raw = (object["description"] as? String) ?? (object["title"] as? String) ?? ""
        self.description = UntrustedText.neutralize(String(raw.prefix(400)))
        var schema = (object["inputSchema"] as? [String: Any]) ?? [:]
        if schema["type"] == nil { schema["type"] = "object" }
        if schema["properties"] == nil { schema["properties"] = [String: Any]() }
        self.inputSchema = schema
        let annotations = (object["annotations"] as? [String: Any]) ?? [:]
        self.readOnly = (annotations["readOnlyHint"] as? Bool) == true && (annotations["destructiveHint"] as? Bool) != true
    }

    /// The name Nook gives this tool: unique per server and valid for every model provider (`[a-z0-9_]`, ≤ 64).
    static func nookName(server: String, tool: String) -> String {
        func clean(_ text: String) -> String {
            let lowered = text.lowercased().map { ($0.isLetter && $0.isASCII) || $0.isNumber ? $0 : "_" }
            return String(lowered).split(separator: "_").joined(separator: "_")
        }
        return String("mcp_\(clean(server))_\(clean(tool))".prefix(64))
    }
}

/// Moves JSON-RPC messages to and from a server.
protocol MCPTransport: AnyObject {
    /// Sends a request and returns the matching response (by id).
    func request(_ message: [String: Any]) async throws -> [String: Any]
    /// Sends a notification (no response).
    func notify(_ message: [String: Any]) async throws
    func close()
}

/// Hands out the bearer token for a signed-in server, refreshing it when it is (nearly) expired or was refused.
protocol MCPAuthorizer: Sendable {
    func bearerToken(forceRefresh: Bool) async throws -> String
}

/// The protocol on top of a transport: handshake, listing tools, calling them.
final class MCPClient: @unchecked Sendable {
    static let protocolVersion = "2025-06-18"

    private let transport: MCPTransport
    private let lock = NSLock()
    private var nextID = 1
    private(set) var serverName = ""
    private(set) var initialized = false

    init(transport: MCPTransport) {
        self.transport = transport
    }

    private func newID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        return nextID
    }

    private func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let response = try await transport.request(["jsonrpc": "2.0", "id": newID(), "method": method, "params": params])
        if let error = response["error"] as? [String: Any] {
            throw NookError("MCP: \((error["message"] as? String) ?? "the server returned an error").")
        }
        return (response["result"] as? [String: Any]) ?? [:]
    }

    func initialize() async throws {
        let result = try await call("initialize", [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Nook", "version": "1.0"]
        ])
        serverName = ((result["serverInfo"] as? [String: Any])?["name"] as? String) ?? ""
        try await transport.notify(["jsonrpc": "2.0", "method": "notifications/initialized"])
        initialized = true
    }

    func listTools() async throws -> [MCPTool] {
        var tools: [MCPTool] = []
        var cursor: String?
        repeat {
            let result = try await call("tools/list", cursor.map { ["cursor": $0] } ?? [:])
            tools += ((result["tools"] as? [[String: Any]]) ?? []).compactMap(MCPTool.init)
            cursor = result["nextCursor"] as? String
        } while cursor != nil && tools.count < 500
        return tools
    }

    /// Calls a tool and returns its text. A tool that reports an error throws with that error's text.
    func callTool(_ name: String, arguments: [String: Any]) async throws -> String {
        let result = try await call("tools/call", ["name": name, "arguments": arguments])
        let text = Self.text(of: result)
        if (result["isError"] as? Bool) == true {
            throw NookError(text.isEmpty ? "The tool reported an error." : String(text.prefix(500)))
        }
        return text
    }

    /// Text from a tool result: text parts, resource text, and the structured result if there is nothing else.
    static func text(of result: [String: Any]) -> String {
        var parts: [String] = []
        for item in (result["content"] as? [[String: Any]]) ?? [] {
            switch item["type"] as? String {
            case "text":
                if let text = item["text"] as? String { parts.append(text) }
            case "resource":
                if let resource = item["resource"] as? [String: Any], let text = resource["text"] as? String { parts.append(text) }
            case "resource_link":
                let name = (item["name"] as? String) ?? "resource"
                parts.append("\(name): \((item["uri"] as? String) ?? "")")
            case "image", "audio":
                parts.append("(\((item["type"] as? String) ?? "media") omitted)")
            default:
                continue
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            parts.append(json)
        }
        return parts.joined(separator: "\n")
    }

    func close() { transport.close() }
}

// MARK: - Transports

/// A local server program: newline-delimited JSON-RPC over its stdin and stdout.
final class MCPStdioTransport: MCPTransport, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var waiting: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var closed = false
    private let timeout: TimeInterval

    init(command: String, arguments: [String], environment: [String: String], timeout: TimeInterval = 60) throws {
        self.timeout = timeout
        // Through the user's login shell, so `npx`, `uvx` and friends are found on their PATH.
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let line = ([command] + arguments).map(Self.quote).joined(separator: " ")
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "exec " + line]
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        env["NOOK_INTERNAL"] = "1"
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { self?.finish(NookError("The MCP server stopped.")) } else { self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in self?.finish(NookError("The MCP server stopped.")) }
        try process.run()
    }

    static func quote(_ text: String) -> String {
        if !text.isEmpty, text.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@+,".contains($0) }) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func request(_ message: [String: Any]) async throws -> [String: Any] {
        guard let id = message["id"].map({ "\($0)" }) else { throw NookError("MCP request without id.") }
        let data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: NookError("The MCP server is not running."))
                return
            }
            waiting[id] = continuation
            lock.unlock()
            write(data)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.fail(id, NookError("The MCP server did not answer in time."))
            }
        }
    }

    func notify(_ message: [String: Any]) async throws {
        write(try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]))
    }

    private func write(_ data: Data) {
        var line = data
        line.append(0x0A)
        try? input.fileHandleForWriting.write(contentsOf: line)
    }

    private func receive(_ data: Data) {
        lock.lock()
        // The rest of the buffer holds no newline: search the new bytes only, and drop the consumed lines in one go
        // (see AgentProcess.consume; a large tool result arrives in many chunks).
        var from = buffer.endIndex
        buffer.append(data)
        var start = buffer.startIndex
        var messages: [[String: Any]] = []
        while let newline = buffer[from...].firstIndex(of: 0x0A) {
            let line = buffer[start..<newline]
            if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { messages.append(object) }
            start = newline + 1
            from = start
        }
        if start > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
        lock.unlock()
        for message in messages {
            guard let id = message["id"].map({ "\($0)" }), message["method"] == nil else { continue }
            lock.lock()
            let continuation = waiting.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume(returning: message)
        }
    }

    private func fail(_ id: String, _ error: Error) {
        lock.lock()
        let continuation = waiting.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    private func finish(_ error: Error) {
        lock.lock()
        closed = true
        let pending = waiting
        waiting.removeAll()
        lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        for continuation in pending.values { continuation.resume(throwing: error) }
    }

    func close() {
        finish(NookError("Closed."))
        if process.isRunning { process.terminate() }
    }
}

/// A remote server over Streamable HTTP: each message is a POST; the answer is JSON or a short event stream.
final class MCPHTTPTransport: MCPTransport, @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]
    private let authorizer: MCPAuthorizer?
    private let lock = NSLock()
    private var sessionID: String?

    init(url: URL, headers: [String: String], authorizer: MCPAuthorizer? = nil) throws {
        guard url.scheme?.lowercased() == "https" || url.host == "localhost" || url.host == "127.0.0.1" else {
            throw NookError("An MCP server on the internet must use https.")
        }
        self.url = url
        self.headers = headers
        self.authorizer = authorizer
    }

    /// Sends one message. A signed-in server that refuses the token gets one retry with a refreshed token; refused
    /// again means the sign-in has expired.
    private func post(_ message: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        guard let authorizer else { return try await post(message, token: nil) }
        do {
            return try await post(message, token: try await authorizer.bearerToken(forceRefresh: false))
        } catch MCPOAuthError.expired {
            return try await post(message, token: try await authorizer.bearerToken(forceRefresh: true))
        }
    }

    private func post(_ message: [String: Any], token: String?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(MCPClient.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let session = lock.withLock { sessionID }
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NookError("No answer from the MCP server.") }
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            lock.withLock { sessionID = id }
        }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401 where token != nil: throw MCPOAuthError.expired
            case 401, 403: throw NookError("The MCP server refused access (\(http.statusCode)). Check the key in Settings › Connections.", kind: .auth)
            default: throw NookError("The MCP server returned an error (\(http.statusCode)).")
            }
        }
        return (data, http)
    }

    func request(_ message: [String: Any]) async throws -> [String: Any] {
        let (data, response) = try await post(message)
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let id = message["id"].map { "\($0)" }
        let candidates = type.contains("event-stream") ? Self.events(in: data) : [(try? JSONSerialization.jsonObject(with: data)) as? [String: Any]].compactMap { $0 }
        if let match = candidates.first(where: { $0["id"].map { "\($0)" } == id }) { return match }
        throw NookError("The MCP server sent no answer to the request.")
    }

    func notify(_ message: [String: Any]) async throws {
        _ = try await post(message)
    }

    /// JSON messages in a server-sent event stream ("data: {…}" lines, events separated by blank lines).
    static func events(in data: Data) -> [[String: Any]] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var result: [[String: Any]] = []
        for block in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
            let payload = block.split(separator: "\n")
                .filter { $0.hasPrefix("data:") }
                .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
            if let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] { result.append(object) }
        }
        return result
    }

    func close() {}
}
