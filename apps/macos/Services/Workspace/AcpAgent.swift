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
        case .antigravity, .claude, .codex, .pi: return []
        // An ACP agent you added starts with its own command line (see CustomAgents).
        case .acp: return []
        }
    }
}

/// What a session update or request becomes in Nook's timeline.
enum AcpEvent: Equatable, Sendable {
    case messageChunk(String)
    /// Your own words, as a loaded session replays them (`user_message_chunk`).
    case userChunk(String)
    case thoughtChunk(String)
    case toolCall(AcpToolCall)
    case toolCallUpdate(AcpToolCall)
    case plan([RunTaskStep])
    case usage(used: Int, size: Int, costUSD: Double?)
    case permission(rpcID: RPCID, call: AcpToolCall, options: [AcpPermissionOption])
    /// An MCP server asks you something through the agent (`elicitation/create`, form mode). `isConfirmation`: nothing to
    /// fill in, so Allow or Deny answers it; a form with fields is declined, as Claude Code's and Codex's are.
    case elicitation(rpcID: RPCID, server: String, message: String, isConfirmation: Bool)
    /// The agent's own `/` commands (`available_commands_update`).
    case commands([AgentSlashCommand])
    /// The session's config options changed (`config_option_update`), all of them: a new model can bring other levels.
    case configOptions(JSONBox)
    /// The agent switched its mode itself (`current_mode_update`).
    case currentMode(String)
    /// A request Nook does not handle (`fs/…`, `terminal/…` are not advertised): answered with an error.
    case unsupportedRequest(RPCID)
}

extension AcpEvent {
    /// After a turn, a sign the agent is really working again: text it writes, a tool call that
    /// finished, or a question for you; not an empty chunk, usage or a stray notice.
    var isWakeEvidence: Bool {
        switch self {
        case .messageChunk(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .toolCall(let call), .toolCallUpdate(let call): return call.status == "completed" || call.status == "failed"
        case .permission, .elicitation: return true
        default: return false
        }
    }

    /// What the session offers rather than work it does: kept also outside a turn and while a loaded session replays.
    var isSessionState: Bool {
        switch self {
        case .commands, .configOptions, .currentMode: return true
        default: return false
        }
    }
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
    /// What the call changed (`diff` content): the text it replaced (nil for a new file) and what it wrote.
    var diffs: [AcpDiff] = []
    /// The agent's own name for the tool, when its ACP adapter passes it on (Claude Code's `_meta.claudeCode.toolName`).
    var metaToolName: String? = nil

    /// The call starts a subagent: Claude Code over ACP names its Task or Agent tool in `_meta` (its first report may
    /// come without input), and a call whose input hands a task to another agent (`subagentInput`) does too.
    var launchesSubagent: Bool { Subagents.tools.contains(metaToolName ?? "") || subagentInput != nil }

    /// The input of a call that starts a subagent, in the shape Nook's subagent rows read (Claude Code's Task:
    /// `description`, `prompt`, `subagent_type`): Claude Code over ACP passes its Task input as it is, Copilot names the
    /// agent in `agent_type`. Nil for any other call.
    var subagentInput: JSONBox? {
        guard var raw = input?.object as? [String: Any], let prompt = raw["prompt"] as? String, !prompt.isEmpty else { return nil }
        let type = (raw["subagent_type"] as? String) ?? (raw["agent_type"] as? String)
        guard type != nil || Subagents.tools.contains(metaToolName ?? "") else { return nil }
        raw["subagent_type"] = type ?? "agent"
        return JSONBox(raw)
    }

    /// The call's input with its changes in the form Nook's edit rows read (`old_string`/`new_string`, `edits` when it
    /// changed more than one place), as Claude Code's Edit has them: the line count and the diff panel then work for every
    /// ACP agent. Nil when the call changed nothing it said.
    var editInput: JSONBox? {
        guard !diffs.isEmpty else { return nil }
        var input = (input?.object as? [String: Any]) ?? [:]
        let edits: [[String: Any]] = diffs.map { ["file_path": $0.path, "old_string": $0.oldText ?? "", "new_string": $0.newText] }
        if edits.count == 1 {
            input.merge(edits[0]) { _, new in new }
        } else {
            input["file_path"] = diffs[0].path
            input["edits"] = edits
        }
        return JSONBox(input)
    }

    /// The call's input, with the file a read reported only in its locations put in as `path`: the step then opens that
    /// file, and a picture it looked at shows under it (`ViewedImages`), as for every other agent.
    var readInput: JSONBox? {
        guard kind == "read", let first = paths.first else { return input }
        var object = input?.dictionary ?? [:]
        guard ToolSummary.path(object) == nil else { return input }
        object["path"] = first
        return JSONBox(object)
    }

    /// The tool name Nook's timeline groups by (see ToolCategory). A subagent's call is "Agent", as Claude Code's, so it
    /// gets the subagent rows, the bar above the composer and the Subagents tab.
    var toolName: String {
        if launchesSubagent { return "Agent" }
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

/// File reads the agent left open after it moved on. Antigravity's server (1.3.0) reads files with a host tool of its
/// own in place of the built-in `view_file`, and closes such a call only when the turn ends, without its output: every
/// read would spin for the whole turn. A model only goes on once its tool results are in, so a read announced before
/// the agent wrote again (text, a thought) or started a later batch of tool calls is done. Calls announced in one go
/// form a batch and may still run side by side; only reads are settled, since a command can keep running in the
/// background.
struct AcpOpenReads: Equatable, Sendable {
    /// Reads of earlier batches, and of the batch being announced now.
    private var earlier: [String] = []
    private var batch: [String] = []

    /// Takes in the next event; returns the reads that are now done.
    mutating func settle(after event: AcpEvent) -> [String] {
        switch event {
        case .toolCall(let call):
            let done = earlier
            earlier = []
            if call.kind == "read", call.status != "completed", call.status != "failed" { batch.append(call.id) }
            return done
        case .toolCallUpdate(let call):
            guard call.status == "completed" || call.status == "failed" else { return [] }
            earlier.removeAll { $0 == call.id }
            batch.removeAll { $0 == call.id }
            endBatch()
            return []
        case .messageChunk(let text), .thoughtChunk(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            let done = earlier + batch
            earlier = []
            batch = []
            return done
        case .userChunk, .plan, .usage, .permission, .elicitation, .commands, .configOptions, .currentMode, .unsupportedRequest:
            endBatch()
            return []
        }
    }

    private mutating func endBatch() {
        earlier += batch
        batch = []
    }
}

struct AcpDiff: Equatable, Sendable {
    var path: String
    var oldText: String?
    var newText: String
}

struct AcpPermissionOption: Equatable, Sendable {
    var id: String
    var name: String
    /// allow_once, allow_always, reject_once, reject_always.
    var kind: String
}

/// A way an ACP agent lets you sign in (`initialize`'s `authMethods`).
struct AcpAuthMethod: Equatable, Sendable {
    /// The agent signs in when asked (`authenticate`): a page in your browser, a key it finds itself.
    static let agent = "agent"
    /// Nook runs the agent's own program with `args` (and `env`) in a Terminal window, where you sign in; the agent reads
    /// the saved login when it starts again.
    static let terminal = "terminal"

    var id: String
    var name: String
    var type: String
    var args: [String] = []
    var env: [String: String] = [:]

    init(id: String, name: String = "", type: String = AcpAuthMethod.agent, args: [String] = [], env: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.type = type
        self.args = args
        self.env = env
    }

    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String, !id.isEmpty, id.count <= 128 else { return nil }
        // `env` is a list of `{name, value}` in the schema; some agents send an object.
        var env: [String: String] = [:]
        if let list = raw["env"] as? [[String: Any]] {
            for entry in list { if let name = entry["name"] as? String, let value = entry["value"] as? String { env[name] = value } }
        } else if let object = raw["env"] as? [String: Any] {
            for (name, value) in object { if let value = value as? String { env[name] = value } }
        }
        self.init(id: id, name: String(((raw["name"] as? String) ?? id).prefix(160)),
                  type: (raw["type"] as? String) ?? Self.agent,
                  args: ((raw["args"] as? [Any]) ?? []).compactMap { $0 as? String }.prefix(32).map { String($0.prefix(512)) },
                  env: env.filter { CustomAgents.isEnvironmentName($0.key) && $0.value.count <= 4096 })
    }
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

    /// Which generation of ACP an `initialize` answer is in, read from its shape and not from its `protocolVersion`: some
    /// agents report version 2 in the v1 shape (`agentCapabilities`, `agentInfo`; Kiro 2.32, Antigravity), and only a
    /// v2 answer has `info`. Nook speaks v1.
    static func generation(_ initialize: [String: Any]) -> Int {
        initialize["info"] != nil ? 2 : 1
    }

    /// An `initialize` answer in the v1 shape Nook reads: a v1-shaped answer as it is, whatever version it reports; a v2
    /// answer with its capabilities moved to where v1 has them (`capabilities.session` becomes `agentCapabilities`).
    static func v1Initialize(_ initialize: [String: Any]) -> [String: Any] {
        guard generation(initialize) == 2 else { return initialize }
        let session = ((initialize["capabilities"] as? [String: Any])?["session"]).flatMap { $0 is NSNull ? nil : $0 as? [String: Any] }
        let prompt = (session?["prompt"] as? [String: Any]) ?? [:]
        var agent: [String: Any] = ["loadSession": session != nil,
                                    "promptCapabilities": ["image": prompt["image"].map { !($0 is NSNull) } ?? false]]
        if let session {
            var sessions: [String: Any] = ["list": [String: Any](), "resume": [String: Any](), "close": [String: Any]()]
            if let delete = session["delete"], !(delete is NSNull) { sessions["delete"] = [String: Any]() }
            agent["sessionCapabilities"] = sessions
        }
        var shaped = initialize
        shaped["agentCapabilities"] = agent
        shaped["agentInfo"] = initialize["info"]
        return shaped
    }

    /// The id after `id` for Nook's next request, kept inside a signed 32-bit integer: the Kotlin ACP SDK (and other
    /// JSON-RPC libraries) reject a larger one.
    static func nextRequestID(after id: Int) -> Int {
        id < 1 || id >= Int(Int32.max) ? 1 : id + 1
    }

    /// The first request id of a client that attaches to a kept agent (`SessionKeeper`): far from the ids an earlier
    /// Nook used, so an answer to one of those never matches a new request, and well inside a signed 32-bit integer.
    static func reattachedFirstID() -> Int {
        1 + Int.random(in: 1_000_000...2_000_000)
    }

    /// Whether a stdout line that is not JSON-RPC was meant as a protocol frame (a JSON object that did not parse, or
    /// one Nook cannot read), rather than text an agent prints between its frames (Antigravity's "Open the following
    /// link to authenticate the ACP server: …", a log line). Text is skipped; a broken frame is reported.
    static func isBrokenFrame(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("{")
    }

    /// How long `session/load` may stay silent after its replay before it counts as done: some agents replay the
    /// conversation and never answer the request.
    static let loadReplayQuiet: TimeInterval = 2

    /// Nook neither reads files nor runs terminals for the agent: it does that itself. No `session.notices` either: Nook
    /// has nothing to show from them. MCP servers may ask you to confirm something (`elicitation`, form mode), and an agent may sign you in
    /// in a Terminal window (`auth.terminal`, `AcpAuthMethod.terminal`).
    static func initializeParams() -> [String: Any] {
        [
            "protocolVersion": protocolVersion,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false,
                                   "elicitation": ["form": [String: Any]()], "auth": ["terminal": true]],
            "clientInfo": ["name": "nook", "title": "Nook", "version": "1"]
        ]
    }

    /// `session/new` or, to continue a conversation, `session/load` (or `session/fork` to copy it), with Nook's MCP bridge
    /// as a stdio server.
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

    static func promptParams(sessionID: String, text: String, attachments: [[String: Any]] = []) -> [String: Any] {
        ["sessionId": sessionID, "prompt": [["type": "text", "text": text]] + attachments]
    }

    /// The pictures of a prompt as content blocks: the picture itself (`image`, base64) for an agent that takes them and a
    /// type it knows, else a `resource_link` to its file, which every ACP agent reads. `read` gives a file's bytes.
    static func attachments(_ files: [URL], images: Bool, read: (URL) -> Data?) -> [[String: Any]] {
        files.map { file in
            let type = mimeType(file)
            if images, let type, let data = read(file), data.count <= maxImageBytes {
                return ["type": "image", "mimeType": type, "data": data.base64EncodedString(), "uri": file.absoluteString]
            }
            var link: [String: Any] = ["type": "resource_link", "uri": file.absoluteString, "name": file.lastPathComponent]
            if let type { link["mimeType"] = type }
            return link
        }
    }

    /// Larger pictures go as a link: a prompt is one JSON line.
    static let maxImageBytes = 8 * 1024 * 1024

    /// The picture types models read; others (HEIC, TIFF, BMP) go as a link to the file.
    static func mimeType(_ file: URL) -> String? {
        switch file.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return nil
        }
    }

    /// The answer to a permission request the turn no longer waits for (Stop, a failed turn): the spec asks for one.
    static let cancelledOutcome: [String: Any] = ["outcome": ["outcome": "cancelled"]]

    /// `session/list` params: one page, from `cursor` on.
    static func listParams(cursor: String?) -> [String: Any] {
        cursor.map { ["cursor": $0] } ?? [:]
    }

    /// The sign-in methods `initialize` offers, in the agent's order.
    static func authMethods(_ initialize: [String: Any]) -> [AcpAuthMethod] {
        ((initialize["authMethods"] as? [[String: Any]]) ?? []).prefix(32).compactMap(AcpAuthMethod.init)
    }

    /// The methods `authenticate` takes: the agent signs in itself. A terminal method is run for you instead
    /// (`AcpAuthMethod.terminal`), and one that wants keys in the environment cannot be asked for.
    static func authMethodIDs(_ initialize: [String: Any]) -> [String] {
        authMethods(initialize).filter { $0.type == AcpAuthMethod.agent }.map(\.id)
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

    /// The kind Nook gives an MCP server's question in `acpRequests`: answered with an elicitation result, never allowed
    /// by the session's rights.
    static let elicitationKind = "elicitation"

    /// The answer to an MCP server's question: accepted with nothing filled in, declined, or cancelled (the turn ended).
    static func elicitationOutcome(_ decision: Bool?) -> [String: Any] {
        switch decision {
        case true?: return ["action": "accept", "content": [String: Any]()]
        case false?: return ["action": "decline"]
        case nil: return ["action": "cancel"]
        }
    }

    /// Whether a request may be allowed without asking, under the session's rights.
    static func autoAllows(_ call: AcpToolCall, permission: PermissionPolicy, mode: ExecutionMode) -> Bool {
        // An MCP server's question waits for you, as for Claude Code and Codex.
        if call.kind == elicitationKind { return false }
        if mode == .plan { return ["read", "search", "think", "fetch"].contains(call.kind) }
        switch permission {
        case .bypass: return true
        // No ACP agent offers "auto" (see `RunProvider.capabilities`); an old setting allows edits only.
        case .acceptEdits, .auto: return ["read", "search", "think", "fetch", "edit", "move"].contains(call.kind)
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
            if method == "elicitation/create" || method == "session/elicitation" {
                let raw = params.dictionary
                let fields = ((raw["requestedSchema"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
                let meta = (raw["_meta"] as? [String: Any]) ?? [:]
                return [.elicitation(rpcID: id, server: (meta["serverName"] as? String) ?? (meta["mcpServerName"] as? String) ?? "",
                                     message: String(((raw["message"] as? String) ?? "").prefix(600)),
                                     isConfirmation: ((raw["mode"] as? String) ?? "form") == "form" && fields.isEmpty)]
            }
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
        case "user_message_chunk":
            return text(update["content"]).map { [.userChunk($0)] } ?? []
        case "agent_thought_chunk":
            return text(update["content"]).map { [.thoughtChunk($0)] } ?? []
        case "tool_call":
            return [.toolCall(toolCall(update))]
        case "tool_call_update":
            return [.toolCallUpdate(toolCall(update))]
        case "plan":
            // An empty plan clears the list: it goes through, and `setTasks` takes it as a clear.
            guard update["entries"] is [Any] else { return [] }
            return [.plan(RunTasks.acp(update))]
        case "usage_update":
            let cost = (update["cost"] as? [String: Any]).flatMap { cost -> Double? in
                guard (cost["currency"] as? String)?.uppercased() ?? "USD" == "USD" else { return nil }
                return ClaudeStreamParser.number(cost["amount"])
            }
            return [.usage(used: Int(ClaudeStreamParser.number(update["used"]) ?? 0),
                           size: Int(ClaudeStreamParser.number(update["size"]) ?? 0), costUSD: cost)]
        case "available_commands_update":
            return [.commands(AgentSlashCommand.acp(update["availableCommands"]))]
        case "config_option_update":
            guard let options = update["configOptions"] as? [[String: Any]] else { return [] }
            return [.configOptions(JSONBox(options))]
        case "current_mode_update":
            return (update["currentModeId"] as? String).map { [.currentMode($0)] } ?? []
        default:
            return []
        }
    }

    private static func toolCall(_ raw: [String: Any]) -> AcpToolCall {
        var output: [String] = []
        var paths: [String] = []
        var diffs: [AcpDiff] = []
        for item in (raw["content"] as? [[String: Any]]) ?? [] {
            switch item["type"] as? String {
            case "content":
                if let text = text(item["content"]) ?? (item["content"] as? [String: Any]).flatMap(McpUI.encode) { output.append(text) }
            case "diff":
                guard let path = (item["path"] as? String).map(filePath) else { break }
                if !paths.contains(path) { paths.append(path) }
                if let newText = item["newText"] as? String {
                    diffs.append(AcpDiff(path: path, oldText: item["oldText"] as? String, newText: newText))
                }
            default: break
            }
        }
        for location in (raw["locations"] as? [[String: Any]]) ?? [] {
            if let path = (location["path"] as? String).map(filePath), !paths.contains(path), (raw["kind"] as? String) == "edit" {
                paths.append(path)
            }
        }
        // Some agents (Antigravity) put a failed call's reason only in rawOutput: without it the call fails without a word.
        if output.isEmpty, let rawOutput = raw["rawOutput"].flatMap(Self.rawOutput) { output.append(rawOutput) }
        return AcpToolCall(id: (raw["toolCallId"] as? String) ?? UUID().uuidString, title: (raw["title"] as? String) ?? "",
                           kind: (raw["kind"] as? String) ?? "", status: raw["status"] as? String,
                           input: raw["rawInput"].map { JSONBox($0) }, output: output.joined(separator: "\n"), paths: paths,
                           diffs: diffs,
                           metaToolName: ((raw["_meta"] as? [String: Any])?["claudeCode"] as? [String: Any])?["toolName"] as? String)
    }

    /// A file as a path. The schema asks for an absolute path, but some agents (Kiro 2.32) name a diff's file as a
    /// `file://` URL: the edit row and the diff panel would then look for a file of that name.
    static func filePath(_ value: String) -> String {
        guard value.hasPrefix("file://") else { return value }
        if let url = URL(string: value), url.isFileURL, !url.path.isEmpty { return url.path }
        let rest = String(value.dropFirst("file://".count))
        return rest.removingPercentEncoding ?? rest
    }

    /// rawOutput as text: a string as is, an object's error or output field, otherwise the object as JSON.
    static func rawOutput(_ value: Any) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let object = value as? [String: Any] {
            for key in ["error", "message", "output", "stderr", "result"] {
                if let text = object[key] as? String, !text.isEmpty { return text }
                if let nested = object[key] as? [String: Any], let text = nested["message"] as? String, !text.isEmpty { return text }
            }
            if object.isEmpty { return nil }
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func text(_ block: Any?) -> String? {
        guard let block = block as? [String: Any], (block["type"] as? String) == "text",
              let text = block["text"] as? String, !text.isEmpty else { return nil }
        return text
    }
}

/// What an ACP agent can do with its sessions, from `initialize`: load one again with its history replayed
/// (`agentCapabilities.loadSession`), list them (`sessionCapabilities.list`) and resume one without the replay
/// (`sessionCapabilities.resume`), and copy one into a new session (`sessionCapabilities.fork`).
struct AcpSessionCapabilities: Equatable, Sendable {
    var load = false
    var list = false
    var resume = false
    /// The agent takes pictures in a prompt (`promptCapabilities.image`); otherwise they go as links to their files.
    var images = false
    /// A session can be removed (`session/delete`) or ended (`session/close`).
    var delete = false
    var close = false
    /// A session can be copied into a new one that goes on apart from it (`session/fork`): Nook's Fork keeps the
    /// conversation instead of starting from a summary.
    var fork = false

    init(load: Bool = false, list: Bool = false, resume: Bool = false, images: Bool = false, delete: Bool = false, close: Bool = false,
         fork: Bool = false) {
        self.load = load
        self.list = list
        self.resume = resume
        self.images = images
        self.delete = delete
        self.close = close
        self.fork = fork
    }

    init(initialize: [String: Any]) {
        let agent = (AcpRPC.v1Initialize(initialize)["agentCapabilities"] as? [String: Any]) ?? [:]
        let session = (agent["sessionCapabilities"] as? [String: Any]) ?? [:]
        // A capability is offered by an object ({}), and not by null or its absence.
        load = (agent["loadSession"] as? Bool) ?? false
        list = session["list"] is [String: Any]
        resume = session["resume"] is [String: Any]
        delete = session["delete"] is [String: Any]
        close = session["close"] is [String: Any]
        fork = session["fork"] is [String: Any]
        images = ((agent["promptCapabilities"] as? [String: Any])?["image"] as? Bool) ?? false
    }

    /// An earlier conversation can be continued: resumed, or loaded again.
    var continues: Bool { load || resume }
    /// The method that continues one: `session/resume` when offered (no history replayed, Nook keeps it), else `session/load`.
    var continueMethod: String { resume ? "session/resume" : "session/load" }
}

/// Asking an ACP agent for its models outside a session (`WorkspaceManager.probeAcpModels`): most name them only in a
/// session, so Nook opens one in an empty folder of its own and removes it again.
enum AcpModelProbe {
    enum SignIn: Equatable, Sendable {
        /// Straight to `session/new`: the agent uses the sign-in it keeps itself, or answers that you need to sign in.
        case direct
        /// `authenticate` with the agent's own method first (`AntigravityAcp.authMethod`); it returns at once with the
        /// saved sign-in.
        case savedLogin
        /// Not asked: signing in would open a sign-in page.
        case skip
    }

    /// Antigravity always authenticates first, which opens Google's sign-in page unless its token is saved: then it is
    /// asked only with that token. The others never `authenticate` for this.
    static func signIn(_ provider: RunProvider, savedLogin: Bool) -> SignIn {
        switch provider {
        case .antigravity: return savedLogin ? .savedLogin : .skip
        case .claude, .codex, .gemini, .opencode, .cursor, .grok, .pi, .acp: return .direct
        }
    }

    /// How the session is taken away again: removed when the agent can, else ended; nil when it offers neither (the
    /// session holds no message, and Nook leaves the probe folder out of the sessions it lists).
    static func cleanup(_ capabilities: AcpSessionCapabilities) -> String? {
        capabilities.delete ? "session/delete" : capabilities.close ? "session/close" : nil
    }

    /// A session in the probe folder is one of these probes, never one of yours.
    static func isProbe(_ cwd: String, folder: String) -> Bool {
        let clean = { (path: String) in path.hasSuffix("/") ? String(path.dropLast()) : path }
        let path = clean(cwd)
        let probe = clean(folder)
        return path == probe || path == "/private" + probe || "/private" + path == probe
    }
}

/// A session an ACP agent lists (`session/list`): its id, folder, title and when it last changed.
struct AcpListedSession: Equatable, Sendable {
    var id: String
    var cwd: String
    var title: String
    var updated: Date?

    /// One page of `session/list`, and the cursor of the next one. A session without id or folder is left out.
    static func page(_ result: [String: Any]) -> (sessions: [AcpListedSession], next: String?) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let sessions = ((result["sessions"] as? [[String: Any]]) ?? []).compactMap { entry -> AcpListedSession? in
            guard let id = entry["sessionId"] as? String, !id.isEmpty, let cwd = entry["cwd"] as? String, !cwd.isEmpty else { return nil }
            let updated = (entry["updatedAt"] as? String).flatMap { formatter.date(from: $0) ?? plain.date(from: $0) }
            return AcpListedSession(id: id, cwd: cwd, title: (entry["title"] as? String) ?? "", updated: updated)
        }
        let next = (result["nextCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (sessions, next)
    }
}

/// What an agent's error says, read from its text (the JSON-RPC code does not reach Nook in every case).
enum AgentErrorText {
    /// The agent wants you to sign in first (ACP's "Authentication required", -32000).
    static func needsSignIn(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["authentication required", "auth required", "auth_required", "unauthenticated", "not authenticated",
                "please authenticate", "requires authentication", "not logged in", "login required"].contains { text.contains($0) }
    }

    /// The conversation to continue is gone (cleared, made on another machine, or by an older version of the agent).
    static func sessionGone(_ message: String) -> Bool {
        let text = message.lowercased()
        guard ["session", "thread", "conversation", "rollout"].contains(where: { text.contains($0) }) else { return false }
        // Claude Code says "No conversation found with session ID: …" when `--resume` names one it does not have.
        return ["not found", "no such", "does not exist", "doesn't exist", "unknown", "no rollout", "invalid", "missing",
                "no conversation found"]
            .contains { text.contains($0) }
    }

    /// The conversation no longer fits the model's context window (Claude Code's "Prompt is too long", OpenAI's
    /// `context_length_exceeded`, Gemini's token limit).
    static func contextFull(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["prompt is too long", "context_length_exceeded", "context length exceeded", "exceeds the context window",
                "maximum context length", "context window exceeded", "exceeds the maximum number of tokens",
                "input is too long", "too many input tokens"].contains { text.contains($0) }
    }
}

/// What decides whether a message starts a new conversation, and which failures one recovers from (for every agent, see
/// `WorkspaceManager+FreshConversation`).
enum FreshConversation {
    /// `/clear` on its own, the way you type or send it.
    static func isCommand(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/clear"
    }

    enum Recovery: Equatable, Sendable {
        /// The agent no longer has the conversation to continue (deleted, made on another machine, or by an older version).
        case gone
        /// The conversation no longer fits the model's context window.
        case full
    }

    /// The failure a new conversation fixes, read from the agent's error; nil for every other failure.
    /// Stricter than `AgentErrorText.sessionGone`, which reads only the answer to a resume: this reads any failed turn's
    /// error, and a wrong guess would cost the agent a conversation it still has.
    static func recovery(for error: String) -> Recovery? {
        if AgentErrorText.contextFull(error) { return .full }
        let text = error.lowercased()
        let gone = ["no conversation found", "conversation not found", "session not found", "thread not found",
                    "no rollout found", "unknown session", "session does not exist", "no such session"]
        return gone.contains { text.contains($0) } ? .gone : nil
    }
}

/// What an agent wrote to stderr, without its own log. Lines in glog's form ("I1029 16:35:47.481079 8387 agent.py:109]
/// Starting…", as Antigravity's server writes) are that log, not the error: info and warnings are dropped, an error
/// keeps only its message.
enum AgentLogLines {
    static func withoutLog(_ lines: [String]) -> [String] {
        lines.compactMap { line in
            guard let regex = glogRegex,
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
                  let level = Range(match.range(at: 1), in: line), let message = Range(match.range(at: 2), in: line) else { return line }
            guard line[level] == "E" || line[level] == "F" else { return nil }
            let text = line[message].trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
    }

    private static let glogRegex = try? NSRegularExpression(pattern: #"^([IWEF])\d{4} \d{2}:\d{2}:\d{2}\.\d+\s+\d+\s+[^\]\s]+:\d+\]\s?(.*)$"#)
}

/// The requests that bring an ACP session's model, effort and mode in line with the run, sent one after the other and
/// answered before the prompt goes, or right away when you change them during a turn. Antigravity restarts its agent session to switch models: a prompt sent before that is
/// done ends at once without a word.
enum AcpSessionSettings {
    enum Target: Equatable, Sendable {
        case model(String)
        case effort(String)
        case mode(String)
    }

    struct Step: Equatable, Sendable {
        var method: String
        var params: [String: String]
        var target: Target
    }

    /// The model first, then the effort (a new model can bring other levels), then the mode; only what differs from what
    /// the session already uses, and an effort or mode only when the agent offers it.
    static func steps(session: String, info: [String: Any], model: String, appliedModel: String?,
                      effort: String? = nil, appliedEffort: String? = nil,
                      mode: String?, appliedMode: String?) -> [Step] {
        var steps: [Step] = []
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty, model != appliedModel {
            if let option = AgentModelCatalog.acpModelOptionID(info) {
                steps.append(Step(method: "session/set_config_option", params: ["sessionId": session, "configId": option, "value": model],
                                  target: .model(model)))
            } else {
                steps.append(Step(method: "session/set_model", params: ["sessionId": session, "modelId": model], target: .model(model)))
            }
        }
        if let effort, !effort.isEmpty, effort != appliedEffort, let option = effortOption(info),
           let configID = option["id"] as? String, values(option).contains(effort) {
            steps.append(Step(method: "session/set_config_option", params: ["sessionId": session, "configId": configID, "value": effort],
                              target: .effort(effort)))
        }
        if let mode, mode != appliedMode {
            if let option = modeOption(info), let configID = option["id"] as? String {
                let values = values(option)
                if values.isEmpty || values.contains(mode) {
                    steps.append(Step(method: "session/set_config_option", params: ["sessionId": session, "configId": configID, "value": mode],
                                      target: .mode(mode)))
                }
            } else if modeIDs(info).contains(mode) {
                steps.append(Step(method: "session/set_mode", params: ["sessionId": session, "modeId": mode], target: .mode(mode)))
            }
        }
        return steps
    }

    /// The thinking levels the session offers (its config option of category "thought_level"), in the agent's order and
    /// under its own names; the current one is the default.
    static func effortLevels(_ info: [String: Any]) -> [AgentModel] {
        guard let option = effortOption(info) else { return [] }
        let current = option["currentValue"] as? String
        var seen = Set<String>()
        return options(option).compactMap { entry -> AgentModel? in
            guard let value = entry["value"] as? String, !value.isEmpty, seen.insert(value).inserted else { return nil }
            let name = (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? value
            return AgentModel(id: value, name: name, isDefault: value == current)
        }
    }

    /// The thinking level the session started with.
    static func currentEffort(_ info: [String: Any]) -> String? {
        effortOption(info)?["currentValue"] as? String
    }

    /// `info` with the config options the agent sent since (in a reply to `session/set_config_option` or in
    /// `config_option_update`): always the complete list.
    static func updating(_ info: [String: Any], configOptions: [[String: Any]]?) -> [String: Any] {
        guard let configOptions else { return info }
        var info = info
        info["configOptions"] = configOptions
        return info
    }

    /// The model the session started with.
    static func currentModel(_ info: [String: Any]) -> String? {
        AgentModelCatalog.acp(info).first(where: \.isDefault)?.id
    }

    /// The mode the session started with: the mode config option's value, else `modes.currentModeId`.
    static func currentMode(_ info: [String: Any]) -> String? {
        (modeOption(info)?["currentValue"] as? String) ?? ((info["modes"] as? [String: Any])?["currentModeId"] as? String)
    }

    /// The mode for a run that is not Antigravity's (whose modes follow its rights): the agent's plan mode in Plan mode,
    /// otherwise the mode the session started with (`starting`: `info` follows the agent, and is in plan mode by then).
    static func mode(plan: Bool, info: [String: Any], starting: String? = nil) -> String? {
        guard plan else { return starting ?? currentMode(info) }
        return (values(modeOption(info) ?? [:]) + modeIDs(info)).first { $0.lowercased().contains("plan") }
    }

    private static func modeOption(_ info: [String: Any]) -> [String: Any]? {
        ((info["configOptions"] as? [[String: Any]]) ?? [])
            .first { ($0["category"] as? String) == "mode" && ($0["type"] as? String ?? "select") == "select" }
    }

    private static func effortOption(_ info: [String: Any]) -> [String: Any]? {
        ((info["configOptions"] as? [[String: Any]]) ?? [])
            .first { ($0["category"] as? String) == "thought_level" && ($0["type"] as? String ?? "select") == "select" }
    }

    /// A select option's choices, groups flattened.
    private static func options(_ option: [String: Any]) -> [[String: Any]] {
        ((option["options"] as? [[String: Any]]) ?? []).flatMap { ($0["options"] as? [[String: Any]]) ?? [$0] }
    }

    private static func values(_ option: [String: Any]) -> [String] {
        options(option).compactMap { $0["value"] as? String }
    }

    private static func modeIDs(_ info: [String: Any]) -> [String] {
        (((info["modes"] as? [String: Any])?["availableModes"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
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
    /// What the agent can do with its sessions (see `AcpSessionCapabilities`).
    var sessionCapabilities: AcpSessionCapabilities {
        get { lock.withLock { _capabilities } }
        set { lock.withLock { _capabilities = newValue } }
    }
    /// While `session/load` replays the conversation, its updates are not new: Nook already keeps the timeline, unless
    /// `keepsReplay` (a session Nook has no timeline of yet, which the replay then fills).
    var replaying: Bool {
        get { lock.withLock { _replaying } }
        set { lock.withLock { _replaying = newValue } }
    }
    var keepsReplay: Bool {
        get { lock.withLock { _keepsReplay } }
        set { lock.withLock { _keepsReplay = newValue } }
    }
    private var _keepsReplay = false
    /// The session was just created: the next prompt carries the session instructions.
    var freshSession: Bool {
        get { lock.withLock { _fresh } }
        set { lock.withLock { _fresh = newValue } }
    }
    /// What `session/new` or `session/load` answered (its modes, models and config options), and the model and mode Nook
    /// set on the session since: a change in the run is sent before the next prompt.
    var sessionInfo: [String: Any] {
        get { lock.withLock { _info } }
        set { lock.withLock { _info = newValue } }
    }
    var appliedModel: String? {
        get { lock.withLock { _model } }
        set { lock.withLock { _model = newValue } }
    }
    var appliedMode: String? {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }
    /// The thinking level set on the session, and the one it started with (a run back on "Default" returns to it).
    var appliedEffort: String? {
        get { lock.withLock { _effort } }
        set { lock.withLock { _effort = newValue } }
    }
    var startingEffort: String? {
        get { lock.withLock { _startingEffort } }
        set { lock.withLock { _startingEffort = newValue } }
    }
    /// The mode the session started with: leaving Plan mode returns to it.
    var startingMode: String? {
        get { lock.withLock { _startingMode } }
        set { lock.withLock { _startingMode = newValue } }
    }
    /// How the agent lets you sign in (`initialize`'s `authMethods`): asked for once when a session needs it.
    var authMethods: [String] {
        get { lock.withLock { _authMethods } }
        set { lock.withLock { _authMethods = newValue } }
    }
    /// The agent's first terminal sign-in (`AcpAuthMethod.terminal`), for when it has no method `authenticate` takes.
    var terminalSignIn: AcpAuthMethod? {
        get { lock.withLock { _terminalSignIn } }
        set { lock.withLock { _terminalSignIn = newValue } }
    }
    private var _authMethods: [String] = []
    private var _terminalSignIn: AcpAuthMethod?
    private var _effort: String?
    private var _startingEffort: String?
    private var _startingMode: String?
    private var _info: [String: Any] = [:]
    private var _model: String?
    private var _mode: String?
    private var _fresh = false
    private var _sessionID: String?
    private var _capabilities = AcpSessionCapabilities()
    private var _replaying = false
    /// Used on the main actor (`WorkspaceManager+Acp`) to serialize `applyAcpSettings` calls across prewarm and send.
    var applyingSettings = false
    var afterSettings: [() -> Void] = []

    /// `transport` and `scheduler` replace the agent's process and the clock in tests (a recorded agent, `ReplayTransport`).
    init(spec: LaunchSpec, transport: ProviderTransport? = nil, scheduler: ProcessScheduler = DispatchProcessScheduler()) {
        process = AgentProcess(spec: spec, transport: transport, scheduler: scheduler)
        self.scheduler = scheduler
        if spec.keeper?.offset != nil { nextID = AcpRPC.reattachedFirstID() }
    }

    private let scheduler: ProcessScheduler
    /// Held while a line is written, with the id it takes: requests, answers and notifications reach the agent in the
    /// order Nook sent them, so a `session/cancel` never overtakes the prompt it cancels.
    private let writeLock = NSLock()
    /// Requests that were settled without their answer (a `session/load` whose replay went quiet): a late answer is dropped.
    private var settled: Set<Int> = []
    /// Bumped by every `config_option_update`, on the process's queue: a `session/set_config_option` answer that comes
    /// after one is older than it (see `request(_:_:tracksConfig:completion:)`).
    private var configUpdates = 0
    /// Replayed updates seen while a `session/load` waits for its answer, and whether a quiet check is scheduled.
    private var replayActivity = 0
    private var loadWaiting: Int?
    private var quietCheckScheduled = false
    /// Lines that looked like a frame but were not one Nook could read.
    private(set) var brokenFrames: Int {
        get { lock.withLock { _brokenFrames } }
        set { lock.withLock { _brokenFrames = newValue } }
    }
    private var _brokenFrames = 0

    /// An answer to a request of an earlier Nook (see `SessionKeeper`): how a kept turn ends, since its request went with it.
    var onOrphanAnswer: (@Sendable (JSONBox) -> Void)?

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
                self.loadWaiting = nil
                return list
            }
            for completion in waiting { completion(.failure(.exited(stderr))) }
            self.onExit?(status, stderr)
        }
        try process.start()
    }

    func request(_ method: String, _ params: [String: Any], completion: @escaping (Result<JSONBox, CodexAppServerError>) -> Void) {
        send(method, params, completion: completion)
    }

    /// A request whose answer may bring the session's config options (`session/set_config_option`, `set_model`,
    /// `set_mode`): `superseded` is true when the agent pushed a `config_option_update` while it was on its way, which is
    /// then newer than the options in the answer (Kiro answers a model change without the model, then announces it).
    func request(_ method: String, _ params: [String: Any], tracksConfig: Bool,
                 completion: @escaping (Result<JSONBox, CodexAppServerError>, _ superseded: Bool) -> Void) {
        let before = lock.withLock { configUpdates }
        send(method, params) { [weak self] result in
            let now = self?.lock.withLock { self?.configUpdates } ?? before
            completion(result, tracksConfig && now != before)
        }
    }

    /// `session/load`, which also counts as answered once the conversation it replays has gone quiet for `quiet` seconds:
    /// some agents replay it and never answer. Such a load answers with no fields (the session keeps its id); the agent's
    /// late answer is dropped.
    func load(_ method: String, _ params: [String: Any], quiet: TimeInterval = AcpRPC.loadReplayQuiet,
              completion: @escaping (Result<JSONBox, CodexAppServerError>) -> Void) {
        send(method, params, completion: completion) { id in
            self.loadWaiting = id
            self.replayActivity = 0
            self.quiet = quiet
        }
    }

    private var quiet: TimeInterval = AcpRPC.loadReplayQuiet

    /// Writes a request; `before` runs under the lock with its id, before the line goes out.
    @discardableResult
    private func send(_ method: String, _ params: [String: Any], completion: @escaping (Result<JSONBox, CodexAppServerError>) -> Void,
                      before: ((Int) -> Void)? = nil) -> Int {
        writeLock.withLock {
            let id = lock.withLock { () -> Int in
                let id = nextID
                nextID = AcpRPC.nextRequestID(after: id)
                pending[id] = completion
                before?(id)
                return id
            }
            process.send(AcpRPC.request(id: id, method: method, params: params))
            return id
        }
    }

    /// A notification: no `id` (an agent drops a notification that has one), in order with everything else Nook writes.
    func notify(_ method: String, _ params: [String: Any]) {
        writeLock.withLock { process.send(AcpRPC.notification(method: method, params: params)) }
    }

    func respond(_ id: RPCID, _ result: [String: Any]) {
        writeLock.withLock { process.send(AcpRPC.response(id: id, result: result)) }
    }

    func respondError(_ id: RPCID, code: Int = -32601, message: String) {
        writeLock.withLock { process.send(AcpRPC.errorResponse(id: id, code: code, message: message)) }
    }

    func stop() {
        process.closeInput()
        process.stop(grace: 2)
    }

    /// A line that is not JSON-RPC (Antigravity prints its sign-in link this way): skipped, after this has seen it.
    var onText: (@Sendable (String) -> Void)?
    /// A line that looked like a frame but was not one Nook can read: reported (logged), and the session goes on.
    var onBrokenFrame: (@Sendable (String) -> Void)?

    private func handle(_ line: String) {
        guard let message = AcpRPC.parse(line) else {
            if AcpRPC.isBrokenFrame(line) {
                brokenFrames += 1
                onBrokenFrame?(line)
            }
            onText?(line)
            return
        }
        if case .response(let id, let result, let error) = message {
            let (completion, late) = lock.withLock { () -> (((Result<JSONBox, CodexAppServerError>) -> Void)?, Bool) in
                if loadWaiting == id { loadWaiting = nil }
                return (pending.removeValue(forKey: id), settled.remove(id) != nil)
            }
            if late { return }
            if completion == nil, error == nil, let result { onOrphanAnswer?(result) }
            if let error { completion?(.failure(.server(error))) } else { completion?(.success(result ?? JSONBox([String: Any]()))) }
            return
        }
        let events = AcpMapper.events(message)
        if events.contains(where: { if case .configOptions = $0 { return true } else { return false } }) {
            lock.withLock { configUpdates += 1 }
        }
        if case .notification = message { noteReplayActivity() }
        // Replayed history is dropped, except requests, which always need an answer, and what the session offers.
        if replaying, !keepsReplay, case .notification = message, !events.allSatisfy(\.isSessionState) { return }
        onMessage?(message, events)
    }

    /// A replayed update while a load waits: the load is done once they stop for `quiet` seconds.
    private func noteReplayActivity() {
        let schedule = lock.withLock { () -> Bool in
            guard loadWaiting != nil else { return false }
            replayActivity += 1
            guard !quietCheckScheduled else { return false }
            quietCheckScheduled = true
            return true
        }
        if schedule { scheduleQuietCheck(seen: lock.withLock { replayActivity }) }
    }

    private func scheduleQuietCheck(seen: Int) {
        scheduler.schedule(after: lock.withLock { quiet }) { [weak self] in
            guard let self else { return }
            enum Next { case done, again(Int), settle(Int, (Result<JSONBox, CodexAppServerError>) -> Void) }
            let next = self.lock.withLock { () -> Next in
                guard let id = self.loadWaiting else {
                    self.quietCheckScheduled = false
                    return .done
                }
                if self.replayActivity != seen { return .again(self.replayActivity) }
                self.quietCheckScheduled = false
                self.loadWaiting = nil
                guard let completion = self.pending.removeValue(forKey: id) else { return .done }
                self.settled.insert(id)
                return .settle(id, completion)
            }
            switch next {
            case .done: break
            case .again(let count): self.scheduleQuietCheck(seen: count)
            case .settle(_, let completion): completion(.success(JSONBox([String: Any]())))
            }
        }
    }
}

/// The conversation a loaded session replays, as messages for a timeline that has none yet: consecutive chunks of one
/// side join into one message.
struct AcpReplay: Equatable, Sendable {
    enum Side: Equatable, Sendable { case user, agent }
    private(set) var messages: [(side: Side, text: String)] = []

    mutating func add(_ event: AcpEvent) {
        switch event {
        case .userChunk(let text): add(.user, text)
        case .messageChunk(let text): add(.agent, text)
        default: break
        }
    }

    private mutating func add(_ side: Side, _ text: String) {
        if let last = messages.last, last.side == side {
            messages[messages.count - 1].text += text
        } else {
            messages.append((side, text))
        }
    }

    /// The messages with text, trimmed.
    var finished: [(side: Side, text: String)] {
        messages.map { ($0.side, $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }.filter { !$0.text.isEmpty }
    }

    static func == (lhs: AcpReplay, rhs: AcpReplay) -> Bool {
        lhs.messages.map(\.side) == rhs.messages.map(\.side) && lhs.messages.map(\.text) == rhs.messages.map(\.text)
    }
}
