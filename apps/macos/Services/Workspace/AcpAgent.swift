import Foundation

// Agents over ACP (Agent Client Protocol), OpenCode, Cursor, Grok and Antigravity: one
// process per session speaking JSON-RPC 2.0 over stdin/stdout. Nook starts or loads a session, sends prompts, shows
// the agent's messages, thoughts and tool calls live, and answers its permission requests. Shapes follow the ACP v1
// schema. Everything in this file depends only on Foundation so tests can use it independently.

/// How to start an agent's ACP server (the arguments the ACP registry lists for it).
enum AcpLaunch {
    static func arguments(_ provider: RunProvider, permission: PermissionPolicy) -> [String] {
        switch provider {
        case .gemini: return ["--acp"]
        case .opencode, .cursor: return ["acp"]
        // Grok decides on approvals itself with --always-approve; otherwise it asks Nook.
        case .grok: return permission == .bypass ? ["agent", "--always-approve", "stdio"] : ["agent", "stdio"]
        // Antigravity's server takes no arguments on the Mac; its account and harness come from the environment.
        case .antigravity, .claude, .codex: return []
        }
    }
}

/// What a session update or request becomes in Nook's timeline.
enum AcpEvent: Equatable, Sendable {
    case messageChunk(String)
    case thoughtChunk(String)
    case toolCall(AcpToolCall)
    case toolCallUpdate(AcpToolCall)
    case plan([String])
    case usage(used: Int, size: Int, costUSD: Double?)
    case permission(rpcID: RPCID, call: AcpToolCall, options: [AcpPermissionOption])
    /// A request Nook does not handle (`fs/…`, `terminal/…` are not advertised): answered with an error.
    case unsupportedRequest(RPCID)
}

struct AcpToolCall: Equatable, Sendable {
    var id: String
    var title: String
    /// read, edit, delete, move, search, execute, think, fetch, switch_mode, other.
    var kind: String
    /// pending, in_progress, completed, failed (nil in an update that does not change it).
    var status: String?
    var input: JSONBox?
    /// Text content of the call (its output), joined.
    var output: String
    /// Files the call changes (diff content) or touches (locations).
    var paths: [String]

    /// The tool name Nook's timeline groups by (see ToolCategory).
    var toolName: String {
        switch kind {
        case "execute": return "shell"
        case "edit", "delete", "move": return "edit"
        case "read": return "read"
        case "search": return "grep"
        case "fetch": return "webfetch"
        default: return kind.isEmpty ? "tool" : kind
        }
    }
}

struct AcpPermissionOption: Equatable, Sendable {
    var id: String
    var name: String
    /// allow_once, allow_always, reject_once, reject_always.
    var kind: String
}

enum AcpRPC {
    static let protocolVersion = 1

    static func parse(_ line: String) -> CodexRPCMessage? {
        // The same envelope as Codex's, plus "jsonrpc": "2.0"; reading it needs no difference.
        CodexRPC.parse(line)
    }

    static func request(id: Int, method: String, params: [String: Any]) -> String {
        line(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    static func notification(method: String, params: [String: Any]) -> String {
        line(["jsonrpc": "2.0", "method": method, "params": params])
    }

    static func response(id: RPCID, result: [String: Any]) -> String {
        line(["jsonrpc": "2.0", "id": id.json, "result": result])
    }

    static func errorResponse(id: RPCID, code: Int, message: String) -> String {
        line(["jsonrpc": "2.0", "id": id.json, "error": ["code": code, "message": message]])
    }

    /// Nook neither reads files nor runs terminals for the agent: it does that itself.
    static func initializeParams() -> [String: Any] {
        [
            "protocolVersion": protocolVersion,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
            "clientInfo": ["name": "nook", "title": "Nook", "version": "1"]
        ]
    }

    /// `session/new` or, to continue a conversation, `session/load`, with Nook's MCP bridge as a stdio server.
    static func sessionParams(cwd: String, bridge: (command: String, args: [String], env: [String: String])?, loadID: String?) -> [String: Any] {
        var servers: [[String: Any]] = []
        if let bridge {
            servers.append([
                "name": BridgeTool.serverName,
                "command": bridge.command,
                "args": bridge.args,
                "env": bridge.env.sorted { $0.key < $1.key }.map { ["name": $0.key, "value": $0.value] }
            ])
        }
        var params: [String: Any] = ["cwd": cwd, "mcpServers": servers]
        if let loadID { params["sessionId"] = loadID }
        return params
    }

    static func promptParams(sessionID: String, text: String) -> [String: Any] {
        ["sessionId": sessionID, "prompt": [["type": "text", "text": text]]]
    }

    /// The option to answer a permission request with: the kind you chose, or the closest one the agent offers.
    static func permissionOutcome(_ options: [AcpPermissionOption], allow: Bool, always: Bool) -> [String: Any] {
        let wanted = allow ? (always ? ["allow_always", "allow_once"] : ["allow_once", "allow_always"]) : ["reject_once", "reject_always"]
        for kind in wanted {
            if let option = options.first(where: { $0.kind == kind }) {
                return ["outcome": ["outcome": "selected", "optionId": option.id]]
            }
        }
        return ["outcome": ["outcome": "cancelled"]]
    }

    /// Whether a request may be allowed without asking, under the session's rights.
    static func autoAllows(_ call: AcpToolCall, permission: PermissionPolicy, mode: ExecutionMode) -> Bool {
        if mode == .plan { return ["read", "search", "think", "fetch"].contains(call.kind) }
        switch permission {
        case .bypass: return true
        case .acceptEdits: return ["read", "search", "think", "fetch", "edit", "move"].contains(call.kind)
        case .ask: return ["read", "search", "think"].contains(call.kind)
        }
    }

    /// The prompt response: how the turn ended, and its tokens when the agent reports them.
    static func stop(_ result: [String: Any]) -> (reason: String, usage: TurnUsage) {
        var usage = TurnUsage()
        if let raw = result["usage"] as? [String: Any] {
            let cached = Int(ClaudeStreamParser.number(raw["cachedReadTokens"]) ?? 0)
            usage.inputTokens = Int(ClaudeStreamParser.number(raw["inputTokens"]) ?? 0)
            usage.outputTokens = Int(ClaudeStreamParser.number(raw["outputTokens"]) ?? 0) + Int(ClaudeStreamParser.number(raw["thoughtTokens"]) ?? 0)
            usage.cacheReadTokens = cached
            usage.cacheWriteTokens = ClaudeStreamParser.number(raw["cachedWriteTokens"]).map { Int($0) }
        }
        return ((result["stopReason"] as? String) ?? "end_turn", usage)
    }

    private static func line(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

enum AcpMapper {
    static func events(_ message: CodexRPCMessage) -> [AcpEvent] {
        switch message {
        case .response:
            return []
        case .notification(let method, let params):
            guard method == "session/update", let update = params.dictionary["update"] as? [String: Any] else { return [] }
            return self.update(update)
        case .request(let id, let method, let params):
            guard method == "session/request_permission" else { return [.unsupportedRequest(id)] }
            let raw = params.dictionary
            let call = toolCall((raw["toolCall"] as? [String: Any]) ?? [:])
            let options = ((raw["options"] as? [[String: Any]]) ?? []).compactMap { option -> AcpPermissionOption? in
                guard let id = option["optionId"] as? String else { return nil }
                return AcpPermissionOption(id: id, name: (option["name"] as? String) ?? id, kind: (option["kind"] as? String) ?? "")
            }
            return [.permission(rpcID: id, call: call, options: options)]
        }
    }

    private static func update(_ update: [String: Any]) -> [AcpEvent] {
        switch update["sessionUpdate"] as? String {
        case "agent_message_chunk":
            return text(update["content"]).map { [.messageChunk($0)] } ?? []
        case "agent_thought_chunk":
            return text(update["content"]).map { [.thoughtChunk($0)] } ?? []
        case "tool_call":
            return [.toolCall(toolCall(update))]
        case "tool_call_update":
            return [.toolCallUpdate(toolCall(update))]
        case "plan":
            let entries = ((update["entries"] as? [[String: Any]]) ?? []).compactMap { entry -> String? in
                guard let content = entry["content"] as? String else { return nil }
                let done = (entry["status"] as? String) == "completed"
                return (done ? "☑ " : "☐ ") + content
            }
            return entries.isEmpty ? [] : [.plan(entries)]
        case "usage_update":
            let cost = (update["cost"] as? [String: Any]).flatMap { cost -> Double? in
                guard (cost["currency"] as? String)?.uppercased() ?? "USD" == "USD" else { return nil }
                return ClaudeStreamParser.number(cost["amount"])
            }
            return [.usage(used: Int(ClaudeStreamParser.number(update["used"]) ?? 0),
                           size: Int(ClaudeStreamParser.number(update["size"]) ?? 0), costUSD: cost)]
        default:
            return []
        }
    }

    private static func toolCall(_ raw: [String: Any]) -> AcpToolCall {
        var output: [String] = []
        var paths: [String] = []
        for item in (raw["content"] as? [[String: Any]]) ?? [] {
            switch item["type"] as? String {
            case "content": if let text = text(item["content"]) { output.append(text) }
            case "diff": if let path = item["path"] as? String { paths.append(path) }
            default: break
            }
        }
        for location in (raw["locations"] as? [[String: Any]]) ?? [] {
            if let path = location["path"] as? String, !paths.contains(path), (raw["kind"] as? String) == "edit" { paths.append(path) }
        }
        return AcpToolCall(id: (raw["toolCallId"] as? String) ?? UUID().uuidString, title: (raw["title"] as? String) ?? "",
                           kind: (raw["kind"] as? String) ?? "", status: raw["status"] as? String,
                           input: raw["rawInput"].map { JSONBox($0) }, output: output.joined(separator: "\n"), paths: paths)
    }

    private static func text(_ block: Any?) -> String? {
        guard let block = block as? [String: Any], (block["type"] as? String) == "text",
              let text = block["text"] as? String, !text.isEmpty else { return nil }
        return text
    }
}

/// One ACP agent process: requests with replies, session updates and the agent's requests, on the process's queue.
final class AcpClient: @unchecked Sendable {
    let process: AgentProcess
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: (Result<JSONBox, CodexAppServerError>) -> Void] = [:]

    var onMessage: (@Sendable (CodexRPCMessage, [AcpEvent]) -> Void)?
    var onExit: (@Sendable (Int32, String) -> Void)?

    /// The agent's session id once created or loaded, and whether it can load earlier sessions.
    var sessionID: String? {
        get { lock.withLock { _sessionID } }
        set { lock.withLock { _sessionID = newValue } }
    }
    var canLoadSessions: Bool {
        get { lock.withLock { _canLoad } }
        set { lock.withLock { _canLoad = newValue } }
    }
    /// While `session/load` replays the conversation, its updates are not new: Nook already keeps the timeline.
    var replaying: Bool {
        get { lock.withLock { _replaying } }
        set { lock.withLock { _replaying = newValue } }
    }
    /// The session was just created: the next prompt carries the session instructions.
    var freshSession: Bool {
        get { lock.withLock { _fresh } }
        set { lock.withLock { _fresh = newValue } }
    }
    private var _fresh = false
    private var _sessionID: String?
    private var _canLoad = false
    private var _replaying = false

    init(spec: LaunchSpec) {
        process = AgentProcess(spec: spec)
    }

    var isRunning: Bool { process.isRunning }

    func start() throws {
        process.onLines = { [weak self] lines in
            for line in lines { self?.handle(line) }
        }
        process.onExit = { [weak self] status, stderr in
            guard let self else { return }
            let waiting = self.lock.withLock { () -> [(Result<JSONBox, CodexAppServerError>) -> Void] in
                let list = Array(self.pending.values)
                self.pending.removeAll()
                return list
            }
            for completion in waiting { completion(.failure(.exited(stderr))) }
            self.onExit?(status, stderr)
        }
        try process.start()
    }

    func request(_ method: String, _ params: [String: Any], completion: @escaping (Result<JSONBox, CodexAppServerError>) -> Void) {
        let id = lock.withLock { () -> Int in
            let id = nextID
            nextID += 1
            pending[id] = completion
            return id
        }
        process.send(AcpRPC.request(id: id, method: method, params: params))
    }

    func notify(_ method: String, _ params: [String: Any]) {
        process.send(AcpRPC.notification(method: method, params: params))
    }

    func respond(_ id: RPCID, _ result: [String: Any]) {
        process.send(AcpRPC.response(id: id, result: result))
    }

    func respondError(_ id: RPCID, code: Int = -32601, message: String) {
        process.send(AcpRPC.errorResponse(id: id, code: code, message: message))
    }

    func stop() {
        process.closeInput()
        process.stop(grace: 2)
    }

    /// A line that is not JSON-RPC (Antigravity prints its sign-in link this way).
    var onText: (@Sendable (String) -> Void)?

    private func handle(_ line: String) {
        guard let message = AcpRPC.parse(line) else {
            onText?(line)
            return
        }
        if case .response(let id, let result, let error) = message {
            let completion = lock.withLock { pending.removeValue(forKey: id) }
            if let error { completion?(.failure(.server(error))) } else { completion?(.success(result ?? JSONBox([String: Any]()))) }
            return
        }
        // Replayed history is dropped, except requests, which always need an answer.
        if replaying, case .notification = message { return }
        onMessage?(message, AcpMapper.events(message))
    }
}
