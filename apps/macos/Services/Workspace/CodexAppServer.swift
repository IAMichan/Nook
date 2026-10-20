import Foundation

// Codex through `codex app-server`: one long-lived process per session speaking newline-delimited
// JSON-RPC over stdin/stdout. Compared with one `codex exec --json` per turn this gives approvals and questions in Nook,
// steering a running turn, live reasoning and command output, and the context window.
// Message shapes follow the schema Codex generates itself. Everything in this file depends only
// on Foundation so tests can use it independently.

/// A JSON-RPC id as Codex sends it: a number or a string.
enum RPCID: Hashable, Sendable {
    case int(Int)
    case string(String)

    init?(_ value: Any?) {
        if let text = value as? String { self = .string(text) }
        else if let number = value as? NSNumber { self = .int(number.intValue) }
        else { return nil }
    }

    var json: Any {
        switch self {
        case .int(let value): return value
        case .string(let value): return value
        }
    }

    /// For use in Nook's own ids ("codex-7").
    var text: String {
        switch self {
        case .int(let value): return String(value)
        case .string(let value): return value
        }
    }
}

/// One line from `codex app-server`.
enum CodexRPCMessage: Equatable {
    case response(id: Int, result: JSONBox?, error: String?)
    case notification(method: String, params: JSONBox)
    case request(id: RPCID, method: String, params: JSONBox)
}

/// A question an agent asks you (Codex `item/tool/requestUserInput`, Claude Code's AskUserQuestion), one or more at a time.
struct RunQuestion: Equatable, Sendable {
    var id: String
    var header: String
    var question: String
    var options: [RunQuestionOption]
    var multiSelect: Bool
    /// The agent accepts an answer of your own besides the options.
    var allowsOther: Bool
}

struct RunQuestionOption: Equatable, Sendable {
    var label: String
    var description: String
}

/// Codex asks permission for a command or a file change.
struct CodexApprovalRequest: Equatable, Sendable {
    /// `mcpTool`: an MCP server asks (`mcpServer/elicitation/request`) whether a tool may run, or to confirm something.
    enum Kind: String, Sendable { case command, fileChange, legacyCommand, legacyPatch, mcpTool }

    var rpcID: RPCID
    var kind: Kind
    var itemID: String
    var command: String
    var cwd: String
    var reason: String
    /// For `mcpTool`: the server, the tool (empty for a plain confirmation), the arguments Codex shows, and whether
    /// Codex can remember the answer for this session.
    var server = ""
    var tool = ""
    var arguments: [String: String] = [:]
    var canRemember = false
}

/// Token counts Codex reports for the thread: the last model call, the running total, and the model's window.
struct CodexTokenUsage: Equatable, Sendable {
    var last: TokenCounts
    var total: TokenCounts
    var contextWindow: Int?
}

/// Building and reading the messages. Nothing runs here.
enum CodexRPC {
    static let clientName = "nook"

    static func parse(_ line: String) -> CodexRPCMessage? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let method = object["method"] as? String {
            let params = JSONBox(object["params"] ?? [String: Any]())
            if let id = RPCID(object["id"]) { return .request(id: id, method: method, params: params) }
            return .notification(method: method, params: params)
        }
        guard case .int(let id)? = RPCID(object["id"]) else { return nil }
        if let error = object["error"] as? [String: Any] {
            return .response(id: id, result: nil, error: (error["message"] as? String) ?? "Codex returned an error.")
        }
        return .response(id: id, result: object["result"].map { JSONBox($0) }, error: nil)
    }

    static func request(id: Int, method: String, params: [String: Any]? = nil) -> String {
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        return line(message)
    }

    static func notification(method: String, params: [String: Any]? = nil) -> String {
        var message: [String: Any] = ["method": method]
        if let params { message["params"] = params }
        return line(message)
    }

    static func response(id: RPCID, result: [String: Any]) -> String {
        line(["id": id.json, "result": result])
    }

    static func errorResponse(id: RPCID, code: Int, message: String) -> String {
        line(["id": id.json, "error": ["code": code, "message": message]])
    }

    // MARK: Requests

    static func initializeParams(version: String = "1") -> [String: Any] {
        [
            "clientInfo": ["name": clientName, "title": "Nook", "version": version],
            // Nook opts out of the per-turn diff stream and reads changes directly from git.
            "capabilities": ["experimentalApi": true, "optOutNotificationMethods": ["turn/diff/updated"]]
        ]
    }

    /// `thread/start` and `thread/resume`: the folder, the model, and the thread config (Nook's MCP bridge when on).
    static func threadParams(cwd: String, model: String, mcpServers: [String: Any]?, resumeID: String?,
                             instructions: String? = nil) -> [String: Any] {
        var config: [String: Any] = ["tools.update_plan.enabled": true, "mcp_optional_startup_grace_ms": 10_000]
        if let mcpServers { config["mcp_servers"] = mcpServers }
        var params: [String: Any] = ["cwd": cwd, "config": config]
        if !model.isEmpty { params["model"] = model }
        // Your session instructions (and the bridge note) as developer instructions, not mixed into the first prompt.
        if let instructions, !instructions.isEmpty { params["developerInstructions"] = instructions }
        if let resumeID {
            params["threadId"] = resumeID
            params["excludeTurns"] = true
        }
        return params
    }

    /// The approval policy, reviewer and sandbox for a turn.
    static func policy(mode: ExecutionMode, permission: PermissionPolicy) -> (approval: String, sandbox: [String: Any]) {
        if mode == .plan { return ("untrusted", ["type": "readOnly"]) }
        switch permission {
        case .ask: return ("untrusted", ["type": "readOnly"])
        case .acceptEdits: return ("on-request", ["type": "workspaceWrite"])
        case .bypass: return ("never", ["type": "dangerFullAccess"])
        }
    }

    static func turnStartParams(threadID: String, text: String, cwd: String, model: String, mode: ExecutionMode,
                                permission: PermissionPolicy, planModel: String?, effort: String? = nil) -> [String: Any] {
        let policy = policy(mode: mode, permission: permission)
        var params: [String: Any] = [
            "threadId": threadID,
            "input": [["type": "text", "text": text]],
            "cwd": cwd,
            // Model catalogues can default summaries to "none"; ask on every turn so the timeline shows the reasoning.
            "summary": "detailed",
            "approvalsReviewer": "user",
            "approvalPolicy": policy.approval,
            "sandboxPolicy": policy.sandbox
        ]
        if !model.isEmpty { params["model"] = model }
        params.merge(CodexTurnEffort.param(effort: effort)) { $1 }
        // Codex's own plan mode needs a model name; without one the read-only sandbox and the instruction keep it to a plan.
        if mode == .plan, let planModel, !planModel.isEmpty {
            params["collaborationMode"] = ["mode": "plan", "settings": ["model": planModel, "reasoning_effort": "medium"]]
        }
        return params
    }

    static func steerParams(threadID: String, turnID: String, text: String) -> [String: Any] {
        ["threadId": threadID, "expectedTurnId": turnID, "input": [["type": "text", "text": text]]]
    }

    static func interruptParams(threadID: String, turnID: String) -> [String: Any] {
        ["threadId": threadID, "turnId": turnID]
    }

    /// The answer to an approval request.
    static func decision(_ request: CodexApprovalRequest, allow: Bool, always: Bool) -> [String: Any] {
        switch request.kind {
        case .command, .fileChange:
            return ["decision": allow ? (always ? "acceptForSession" : "accept") : "decline"]
        case .legacyCommand, .legacyPatch:
            return ["decision": allow ? (always ? "approved_for_session" : "approved") : "denied"]
        case .mcpTool:
            guard allow else { return ["action": "decline"] }
            var answer: [String: Any] = ["action": "accept", "content": [String: Any]()]
            if always, request.canRemember { answer["_meta"] = ["persist": "session"] }
            return answer
        }
    }

    /// The answer to `item/tool/requestUserInput`: per question id, the chosen labels or your own text.
    static func answers(_ answers: [String: [String]]) -> [String: Any] {
        ["answers": answers.mapValues { ["answers": $0] }]
    }

    private static func line(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

/// From Codex's notifications and requests to the timeline events Nook already shows for Codex.
enum CodexAppServerMapper {
    static func events(_ message: CodexRPCMessage) -> [CodexStreamEvent] {
        switch message {
        case .response:
            return []
        case .notification(let method, let params):
            return notification(method, params.dictionary)
        case .request(let id, let method, let params):
            return request(id, method, params.dictionary)
        }
    }

    private static func notification(_ method: String, _ params: [String: Any]) -> [CodexStreamEvent] {
        switch method {
        case "thread/started":
            return ((params["thread"] as? [String: Any])?["id"] as? String).map { [.threadStarted($0)] } ?? []
        case "turn/started":
            return ((params["turn"] as? [String: Any])?["id"] as? String).map { [.turnStarted($0)] } ?? []
        case "item/agentMessage/delta":
            guard let id = params["itemId"] as? String, let delta = params["delta"] as? String, !delta.isEmpty else { return [] }
            return [.messageDelta(id: id, text: delta)]
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            guard let id = params["itemId"] as? String, let delta = params["delta"] as? String, !delta.isEmpty else { return [] }
            return [.reasoningDelta(id: id, text: delta)]
        case "item/commandExecution/outputDelta":
            guard let id = params["itemId"] as? String, let delta = params["delta"] as? String else { return [] }
            return [.commandOutput(id: id, delta: delta)]
        case "item/started":
            return item(params["item"] as? [String: Any], finished: false)
        case "item/completed":
            return item(params["item"] as? [String: Any], finished: true)
        case "thread/tokenUsage/updated":
            guard let usage = params["tokenUsage"] as? [String: Any] else { return [] }
            return [.tokenUsage(CodexTokenUsage(last: counts(usage["last"]), total: counts(usage["total"]),
                                                contextWindow: ClaudeStreamParser.number(usage["modelContextWindow"]).map { Int($0) }))]
        case "turn/completed":
            let turn = (params["turn"] as? [String: Any]) ?? [:]
            let error = (turn["error"] as? [String: Any])?["message"] as? String
            let limited = UsageLimits.isCodexUsageLimit((turn["error"] as? [String: Any])?["codexErrorInfo"])
            return (limited ? [.usageLimited] : []) + [.turnFinished(status: (turn["status"] as? String) ?? "completed", error: error,
                                  durationSeconds: ClaudeStreamParser.number(turn["durationMs"]).map { $0 / 1000 })]
        case "error":
            let message = ((params["error"] as? [String: Any])?["message"] as? String) ?? "Codex reported an error."
            if (params["willRetry"] as? Bool) == true { return [.notice(message)] }
            let limited = UsageLimits.isCodexUsageLimit((params["error"] as? [String: Any])?["codexErrorInfo"])
            return (limited ? [.usageLimited] : []) + [.failed(message)]
        case "thread/compacted":
            return [.notice("compact")]
        case "turn/plan/updated":
            return RunTasks.codex(params).map { [.tasks($0)] } ?? []
        case "account/rateLimits/updated":
            return [.rateLimits(JSONBox(params))]
        default:
            return []
        }
    }

    private static func item(_ item: [String: Any]?, finished: Bool) -> [CodexStreamEvent] {
        guard let item, let id = item["id"] as? String, let type = item["type"] as? String else { return [] }
        switch type {
        case "agentMessage":
            guard finished, let text = item["text"] as? String, !text.isEmpty else { return [] }
            return [.messageCompleted(id: id, text: text)]
        case "reasoning":
            guard finished else { return [] }
            let parts = ((item["summary"] as? [String]) ?? []).isEmpty ? ((item["content"] as? [String]) ?? []) : ((item["summary"] as? [String]) ?? [])
            let text = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [.reasoningCompleted(id: id, text: text)]
        case "commandExecution":
            let command = (item["command"] as? String) ?? ""
            guard finished else { return [.commandStarted(id: id, command: command)] }
            let status = (item["status"] as? String) ?? "completed"
            var exit = ClaudeStreamParser.number(item["exitCode"]).map { Int($0) }
            if exit == nil, status == "failed" || status == "declined" { exit = 1 }
            return [.commandFinished(id: id, command: command, output: (item["aggregatedOutput"] as? String) ?? "", exitCode: exit)]
        case "fileChange":
            guard finished, (item["status"] as? String) != "failed", (item["status"] as? String) != "declined" else { return [] }
            let changes = ((item["changes"] as? [[String: Any]]) ?? []).compactMap { change -> CodexFileChange? in
                guard let path = change["path"] as? String else { return nil }
                let kind = ((change["kind"] as? [String: Any])?["type"] as? String) ?? "update"
                return CodexFileChange(path: path, kind: kind)
            }
            return changes.isEmpty ? [] : [.fileChanges(id: id, changes: changes)]
        case "mcpToolCall":
            var name = (item["tool"] as? String) ?? "mcp"
            var detail = (item["server"] as? String) ?? ""
            if detail == BridgeTool.serverName, let tool = BridgeTool.named(name) {
                name = tool.label
                detail = ((item["arguments"] as? [String: Any]).flatMap(BridgeTool.detail)).map { ToolSummary.oneLine($0, 120) } ?? ""
            }
            var events: [CodexStreamEvent] = [.toolCall(id: id, name: name, detail: detail, finished: finished && (item["status"] as? String) != "inProgress",
                                                        failed: (item["status"] as? String) == "failed")]
            // A finished call with an app: Nook fetches its page (only for a call that completed without error).
            if finished, (item["status"] as? String) == "completed", item["error"] == nil || item["error"] is NSNull,
               let result = item["result"], !(result is NSNull), let uri = McpApp.resourceUri(codexItem: item),
               let server = item["server"] as? String, let tool = item["tool"] as? String {
                events.append(.mcpApp(id: id, server: server, tool: tool, arguments: item["arguments"].flatMap { McpApp.json($0) },
                                      result: McpApp.json(result), resourceUri: uri))
            }
            return events
        case "dynamicToolCall":
            return [.toolCall(id: id, name: (item["tool"] as? String) ?? "tool", detail: "",
                              finished: finished, failed: (item["success"] as? Bool) == false)]
        case "webSearch":
            return [.toolCall(id: id, name: "web_search", detail: (item["query"] as? String) ?? "", finished: finished, failed: false)]
        case "collabAgentToolCall":
            // Codex's subagents: spawning one, and every report of their state.
            var events: [CodexStreamEvent] = []
            if (item["tool"] as? String) == "spawnAgent" {
                events.append(.subagentSpawned(id: id, prompt: (item["prompt"] as? String) ?? "", model: item["model"] as? String,
                                               threads: (item["receiverThreadIds"] as? [String]) ?? [],
                                               failed: (item["status"] as? String) == "failed"))
            }
            var states: [String: CodexAgentState] = [:]
            for (thread, raw) in (item["agentsStates"] as? [String: Any]) ?? [:] {
                guard let state = raw as? [String: Any], let status = state["status"] as? String else { continue }
                states[thread] = CodexAgentState(status: status, message: state["message"] as? String)
            }
            if !states.isEmpty { events.append(.subagentStates(states)) }
            return events
        case "plan":
            guard finished, let text = item["text"] as? String, !text.isEmpty else { return [] }
            return [.plan(text)]
        case "contextCompaction":
            return finished ? [.notice("compact")] : []
        default:
            return []
        }
    }

    private static func request(_ id: RPCID, _ method: String, _ params: [String: Any]) -> [CodexStreamEvent] {
        switch method {
        case "item/commandExecution/requestApproval":
            return [.approval(CodexApprovalRequest(rpcID: id, kind: .command, itemID: (params["itemId"] as? String) ?? id.text,
                                                   command: (params["command"] as? String) ?? "", cwd: (params["cwd"] as? String) ?? "",
                                                   reason: (params["reason"] as? String) ?? ""))]
        case "item/fileChange/requestApproval":
            return [.approval(CodexApprovalRequest(rpcID: id, kind: .fileChange, itemID: (params["itemId"] as? String) ?? id.text,
                                                   command: "", cwd: (params["grantRoot"] as? String) ?? "",
                                                   reason: (params["reason"] as? String) ?? ""))]
        case "execCommandApproval":
            let command = (params["command"] as? [String]).map { ToolSummary.command(["command": $0]) ?? "" } ?? ""
            return [.approval(CodexApprovalRequest(rpcID: id, kind: .legacyCommand, itemID: (params["callId"] as? String) ?? id.text,
                                                   command: command, cwd: (params["cwd"] as? String) ?? "",
                                                   reason: (params["reason"] as? String) ?? ""))]
        case "applyPatchApproval":
            return [.approval(CodexApprovalRequest(rpcID: id, kind: .legacyPatch, itemID: (params["callId"] as? String) ?? id.text,
                                                   command: "", cwd: (params["grantRoot"] as? String) ?? "",
                                                   reason: (params["reason"] as? String) ?? ""))]
        case "mcpServer/elicitation/request":
            return mcpApproval(id, params).map { [.approval($0)] } ?? [.unsupportedRequest(id)]
        case "item/tool/requestUserInput":
            let questions = ((params["questions"] as? [[String: Any]]) ?? []).compactMap { raw -> RunQuestion? in
                guard let qid = raw["id"] as? String, let text = raw["question"] as? String else { return nil }
                let options = ((raw["options"] as? [[String: Any]]) ?? []).compactMap { option -> RunQuestionOption? in
                    guard let label = option["label"] as? String else { return nil }
                    return RunQuestionOption(label: label, description: (option["description"] as? String) ?? "")
                }
                return RunQuestion(id: qid, header: (raw["header"] as? String) ?? "", question: text, options: options,
                                   multiSelect: false, allowsOther: (raw["isOther"] as? Bool) ?? options.isEmpty)
            }
            return questions.isEmpty ? [.unsupportedRequest(id)] : [.question(rpcID: id, questions: questions)]
        default:
            return [.unsupportedRequest(id)]
        }
    }

    /// An MCP elicitation Nook can answer with Allow or Deny: Codex asking whether an MCP tool may run, or a server
    /// asking to confirm something without fields to fill in. A form with fields (or a sign-in link) is not one.
    static func mcpApproval(_ id: RPCID, _ params: [String: Any]) -> CodexApprovalRequest? {
        guard let mode = params["mode"] as? String, ["form", "openai/form", "openaiForm"].contains(mode) else { return nil }
        let schema = (params["requestedSchema"] as? [String: Any]) ?? [:]
        guard ((schema["properties"] as? [String: Any]) ?? [:]).isEmpty else { return nil }
        let meta = (params["_meta"] as? [String: Any]) ?? [:]
        let isToolCall = (meta["codex_approval_kind"] as? String) == "mcp_tool_call"
        let server = (params["serverName"] as? String) ?? ""
        let message = (params["message"] as? String) ?? ""
        // The tool by its title, else by the name Codex quotes in its question (`… to run tool "move_file"?`).
        let quoted = message.split(separator: "\"", omittingEmptySubsequences: false).dropFirst().first.map(String.init)
        let tool = isToolCall ? ((meta["tool_title"] as? String) ?? (meta["tool_name"] as? String) ?? quoted ?? "") : ""
        // Codex offers to remember the answer as one value or a list ("session", "always").
        let persist = (meta["persist"] as? [String]) ?? (meta["persist"] as? String).map { [$0] } ?? []
        return CodexApprovalRequest(rpcID: id, kind: .mcpTool, itemID: id.text, command: "", cwd: "",
                                    reason: String(message.prefix(600)),
                                    server: server, tool: tool, arguments: mcpArguments(meta["tool_params_display"]),
                                    canRemember: persist.contains("session"))
    }

    /// The arguments Codex shows with an MCP tool call: a list of `{name, value}` (or `display_name`), or an object.
    private static func mcpArguments(_ raw: Any?) -> [String: String] {
        func text(_ value: Any?) -> String {
            switch value {
            case let string as String: return string
            case let number as Int: return String(number)
            case let number as Double: return String(number)
            case nil: return ""
            case let other?: return ToolSummary.json(other)
            }
        }
        var arguments: [String: String] = [:]
        if let list = raw as? [[String: Any]] {
            for entry in list {
                guard let name = (entry["display_name"] as? String) ?? (entry["name"] as? String) else { continue }
                arguments[name] = text(entry["value"])
            }
        } else if let object = raw as? [String: Any] {
            for (name, value) in object { arguments[name] = text(value) }
        }
        return arguments
    }

    /// Codex counts cached input inside `inputTokens`; keep them apart like the other agents.
    static func counts(_ raw: Any?) -> TokenCounts {
        let object = (raw as? [String: Any]) ?? [:]
        let cached = Int(ClaudeStreamParser.number(object["cachedInputTokens"]) ?? 0)
        let input = Int(ClaudeStreamParser.number(object["inputTokens"]) ?? 0)
        return TokenCounts(input: max(0, input - cached), output: Int(ClaudeStreamParser.number(object["outputTokens"]) ?? 0),
                           cacheRead: cached, cacheWrite: Int(ClaudeStreamParser.number(object["cacheWriteInputTokens"]) ?? 0))
    }
}

/// One `codex app-server` process: requests with replies, notifications and server requests. Lines are handled on the
/// process's own queue; callers hop to the main actor themselves.
final class CodexAppServerClient: @unchecked Sendable {
    let process: AgentProcess
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: (Result<JSONBox, CodexAppServerError>) -> Void] = [:]

    /// Every notification and server request, already mapped, with the raw message for the rest.
    var onMessage: (@Sendable (CodexRPCMessage, [CodexStreamEvent]) -> Void)?
    /// The process ended: exit code and the last lines of stderr. Open requests have failed by then.
    var onExit: (@Sendable (Int32, String) -> Void)?

    /// The thread this session talks in, once started or resumed, and the turn that is running.
    var threadID: String? {
        get { lock.withLock { _threadID } }
        set { lock.withLock { _threadID = newValue } }
    }
    var turnID: String? {
        get { lock.withLock { _turnID } }
        set { lock.withLock { _turnID = newValue } }
    }
    private var _threadID: String?
    private var _turnID: String?

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

    func request(_ method: String, _ params: [String: Any]? = nil, completion: @escaping (Result<JSONBox, CodexAppServerError>) -> Void) {
        let id = lock.withLock { () -> Int in
            let id = nextID
            nextID += 1
            pending[id] = completion
            return id
        }
        process.send(CodexRPC.request(id: id, method: method, params: params))
    }

    func notify(_ method: String, _ params: [String: Any]? = nil) {
        process.send(CodexRPC.notification(method: method, params: params))
    }

    func respond(_ id: RPCID, _ result: [String: Any]) {
        process.send(CodexRPC.response(id: id, result: result))
    }

    func respondError(_ id: RPCID, code: Int = -32601, message: String) {
        process.send(CodexRPC.errorResponse(id: id, code: code, message: message))
    }

    func stop() {
        process.closeInput()
        process.stop(grace: 2)
    }

    private func handle(_ line: String) {
        guard let message = CodexRPC.parse(line) else { return }
        if case .response(let id, let result, let error) = message {
            let completion = lock.withLock { pending.removeValue(forKey: id) }
            if let error { completion?(.failure(.server(error))) } else { completion?(.success(result ?? JSONBox([String: Any]()))) }
            return
        }
        onMessage?(message, CodexAppServerMapper.events(message))
    }
}

enum CodexAppServerError: Error, Equatable, LocalizedError {
    case server(String)
    case exited(String)

    var errorDescription: String? {
        switch self {
        case .server(let message): return message
        case .exited(let stderr): return stderr.isEmpty ? "codex app-server stopped." : stderr
        }
    }

    /// Codex is too old for this method (or for `app-server` at all): use `codex exec` instead.
    var meansUnsupported: Bool {
        let text = (errorDescription ?? "").lowercased()
        return text.contains("method not found") || text.contains("unknown method") || text.contains("unknown variant")
            || text.contains("unrecognized subcommand") || text.contains("unexpected argument")
    }
}
