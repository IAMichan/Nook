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
        case .permission: return true
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
        case .userChunk, .plan, .usage, .permission, .commands, .configOptions, .currentMode, .unsupportedRequest:
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
    static func authMethodIDs(_ initialize: [String: Any]) -> [String] {
        ((initialize["authMethods"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
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
        case "user_message_chunk":
            return text(update["content"]).map { [.userChunk($0)] } ?? []
        case "agent_thought_chunk":
            return text(update["content"]).map { [.thoughtChunk($0)] } ?? []
        case "tool_call":
            return [.toolCall(toolCall(update))]
        case "tool_call_update":
            return [.toolCallUpdate(toolCall(update))]
        case "plan":
            let steps = RunTasks.acp(update)
            return steps.isEmpty ? [] : [.plan(steps)]
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
                guard let path = item["path"] as? String else { break }
                if !paths.contains(path) { paths.append(path) }
                if let newText = item["newText"] as? String {
                    diffs.append(AcpDiff(path: path, oldText: item["oldText"] as? String, newText: newText))
                }
            default: break
            }
        }
        for location in (raw["locations"] as? [[String: Any]]) ?? [] {
            if let path = location["path"] as? String, !paths.contains(path), (raw["kind"] as? String) == "edit" { paths.append(path) }
        }
        // Some agents (Antigravity) put a failed call's reason only in rawOutput: without it the call fails without a word.
        if output.isEmpty, let rawOutput = raw["rawOutput"].flatMap(Self.rawOutput) { output.append(rawOutput) }
        return AcpToolCall(id: (raw["toolCallId"] as? String) ?? UUID().uuidString, title: (raw["title"] as? String) ?? "",
                           kind: (raw["kind"] as? String) ?? "", status: raw["status"] as? String,
                           input: raw["rawInput"].map { JSONBox($0) }, output: output.joined(separator: "\n"), paths: paths,
                           diffs: diffs)
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
/// (`sessionCapabilities.resume`).
struct AcpSessionCapabilities: Equatable, Sendable {
    var load = false
    var list = false
    var resume = false
    /// The agent takes pictures in a prompt (`promptCapabilities.image`); otherwise they go as links to their files.
    var images = false

    init(load: Bool = false, list: Bool = false, resume: Bool = false, images: Bool = false) {
        self.load = load
        self.list = list
        self.resume = resume
        self.images = images
    }

    init(initialize: [String: Any]) {
        let agent = (initialize["agentCapabilities"] as? [String: Any]) ?? [:]
        let session = (agent["sessionCapabilities"] as? [String: Any]) ?? [:]
        // A capability is offered by an object ({}), and not by null or its absence.
        load = (agent["loadSession"] as? Bool) ?? false
        list = session["list"] is [String: Any]
        resume = session["resume"] is [String: Any]
        images = ((agent["promptCapabilities"] as? [String: Any])?["image"] as? Bool) ?? false
    }

    /// An earlier conversation can be continued: resumed, or loaded again.
    var continues: Bool { load || resume }
    /// The method that continues one: `session/resume` when offered (no history replayed, Nook keeps it), else `session/load`.
    var continueMethod: String { resume ? "session/resume" : "session/load" }
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
        return ["not found", "no such", "does not exist", "doesn't exist", "unknown", "no rollout", "invalid", "missing"]
            .contains { text.contains($0) }
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
/// answered before the prompt goes. Antigravity restarts its agent session to switch models: a prompt sent before that is
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
    private var _authMethods: [String] = []
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
        // Replayed history is dropped, except requests, which always need an answer, and what the session offers.
        let events = AcpMapper.events(message)
        if replaying, !keepsReplay, case .notification = message, !events.allSatisfy(\.isSessionState) { return }
        onMessage?(message, events)
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
