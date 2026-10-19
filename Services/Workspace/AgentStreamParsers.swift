import Foundation

/// A JSON object passed along as received (tool input, rule suggestions).
/// Comparable via sorted JSON text, allowing tests to verify it.
struct JSONBox: Equatable, @unchecked Sendable {
    let object: Any
    let json: String

    init(_ object: Any) {
        self.object = object
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            json = text
        } else {
            json = "null"
        }
    }

    var dictionary: [String: Any] { (object as? [String: Any]) ?? [:] }

    static func == (lhs: JSONBox, rhs: JSONBox) -> Bool { lhs.json == rhs.json }
}

/// Tokens from a single model call, as reported by the agent.
struct TokenCounts: Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    /// Tokens present in context during this call.
    var context: Int { input + cacheRead + cacheWrite }
}

// MARK: Claude Code

/// What Nook extracts from one line of Claude Code's `--output-format stream-json`.
enum ClaudeStreamEvent: Equatable, Sendable {
    case initialized(sessionID: String, model: String?)
    /// A text chunk while the response is streaming (`--include-partial-messages`).
    case textDelta(String)
    /// A complete text block from the assistant.
    case text(String)
    /// A complete thinking block (empty when the model kept it to itself).
    case thinking(String)
    /// Thinking as it streams: a new block starts, or more text for the current one.
    case thinkingDelta(String, starts: Bool)
    /// A streamed content block ended.
    case blockStopped
    case toolUse(id: String, name: String, input: JSONBox, nested: Bool)
    case toolResult(id: String, output: String, isError: Bool)
    case usage(messageID: String, tokens: TokenCounts, model: String?)
    /// The agent requests permission (`--permission-prompt-tool stdio`).
    case permissionRequest(requestID: String, tool: String, input: JSONBox, suggestions: JSONBox?, toolUseID: String?)
    case result(ClaudeTurnResult)
    case notice(String)
    /// Claude Code reports a change in the subscription limits (`rate_limit_event`).
    /// A limit changed; with the details when Claude Code gave them (a blocked window and when it resets).
    case rateLimits(UsageLimits.ClaudeEvent?)
}

struct ClaudeTurnResult: Equatable, Sendable {
    var isError: Bool
    var subtype: String
    var text: String
    var sessionID: String?
    var usage: TurnUsage
    var permissionDenials: Int
    /// Why the turn ended, e.g. `aborted_streaming` or `aborted_tools` when a steering message cut it short.
    var terminalReason: String? = nil
    /// The HTTP status of a failed API call (429: a usage limit).
    var apiErrorStatus: Int? = nil

    /// The end of a turn segment that a steering message (`priority: "now"`) cut off: the turn goes on.
    var endedBySteer: Bool { terminalReason == "aborted_streaming" || terminalReason == "aborted_tools" }
}

enum ClaudeStreamParser {
    static func parse(_ line: String) -> [ClaudeStreamEvent] {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        let nested = !(object["parent_tool_use_id"] is NSNull) && object["parent_tool_use_id"] != nil

        switch type {
        case "system":
            let subtype = (object["subtype"] as? String) ?? ""
            if subtype == "init", let session = object["session_id"] as? String {
                return [.initialized(sessionID: session, model: object["model"] as? String)]
            }
            if subtype == "compact_boundary" { return [.notice("compact")] }
            return []

        case "stream_event":
            guard !nested, let event = object["event"] as? [String: Any] else { return [] }
            switch event["type"] as? String {
            case "content_block_start":
                // Thinking shows while it is written, as T3Code streams it.
                guard let block = event["content_block"] as? [String: Any], (block["type"] as? String) == "thinking" else { return [] }
                return [.thinkingDelta((block["thinking"] as? String) ?? "", starts: true)]
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any] else { return [] }
                switch delta["type"] as? String {
                case "text_delta":
                    guard let text = delta["text"] as? String, !text.isEmpty else { return [] }
                    return [.textDelta(text)]
                case "thinking_delta":
                    guard let text = delta["thinking"] as? String, !text.isEmpty else { return [] }
                    return [.thinkingDelta(text, starts: false)]
                default:
                    return []
                }
            case "content_block_stop":
                return [.blockStopped]
            default:
                return []
            }

        case "assistant":
            guard let message = object["message"] as? [String: Any] else { return [] }
            var events: [ClaudeStreamEvent] = []
            for block in (message["content"] as? [[String: Any]]) ?? [] {
                switch block["type"] as? String {
                case "text":
                    if !nested, let text = block["text"] as? String,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        events.append(.text(text))
                    }
                case "thinking":
                    // Also when empty: it matches the streamed block, which keeps its text then.
                    if !nested { events.append(.thinking((block["thinking"] as? String) ?? "")) }
                case "tool_use":
                    if let id = block["id"] as? String, let name = block["name"] as? String {
                        events.append(.toolUse(id: id, name: name, input: JSONBox(block["input"] ?? [String: Any]()), nested: nested))
                    }
                default:
                    break
                }
            }
            if !nested, let id = message["id"] as? String, let usage = message["usage"] as? [String: Any] {
                events.append(.usage(messageID: id, tokens: tokens(usage), model: message["model"] as? String))
            }
            return events

        case "user":
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { block in
                guard (block["type"] as? String) == "tool_result", let id = block["tool_use_id"] as? String else { return nil }
                return .toolResult(id: id, output: resultText(block["content"]), isError: (block["is_error"] as? Bool) ?? false)
            }

        case "control_request":
            guard let requestID = object["request_id"] as? String,
                  let request = object["request"] as? [String: Any],
                  (request["subtype"] as? String) == "can_use_tool",
                  let tool = request["tool_name"] as? String else { return [] }
            return [.permissionRequest(
                requestID: requestID,
                tool: tool,
                input: JSONBox(request["input"] ?? [String: Any]()),
                suggestions: request["permission_suggestions"].flatMap { $0 is NSNull ? nil : JSONBox($0) },
                toolUseID: request["tool_use_id"] as? String
            )]

        case "rate_limit_event":
            return [.rateLimits((object["rate_limit_info"] as? [String: Any]).flatMap(UsageLimits.claudeEvent))]

        case "result":
            var usage = TurnUsage()
            if let raw = object["usage"] as? [String: Any] {
                let counts = tokens(raw)
                usage.inputTokens = counts.input
                usage.outputTokens = counts.output
                usage.cacheReadTokens = counts.cacheRead
                usage.cacheWriteTokens = counts.cacheWrite
            }
            usage.reportedCostUSD = number(object["total_cost_usd"])
            if let models = object["modelUsage"] as? [String: Any] {
                let windows = models.values.compactMap { ($0 as? [String: Any]).flatMap { number($0["contextWindow"]) } }
                if let window = windows.max(), window > 0 { usage.contextWindow = Int(window) }
            }
            usage.durationSeconds = number(object["duration_ms"]).map { $0 / 1000 }
            let subtype = (object["subtype"] as? String) ?? ""
            let text = (object["result"] as? String) ?? ((object["errors"] as? [String])?.joined(separator: "\n") ?? "")
            return [.result(ClaudeTurnResult(
                isError: (object["is_error"] as? Bool) ?? (subtype != "success"),
                subtype: subtype,
                text: text,
                sessionID: object["session_id"] as? String,
                usage: usage,
                permissionDenials: (object["permission_denials"] as? [Any])?.count ?? 0,
                terminalReason: object["terminal_reason"] as? String,
                apiErrorStatus: ClaudeStreamParser.number(object["api_error_status"]).map { Int($0) }
            ))]

        default:
            return []
        }
    }

    static func tokens(_ usage: [String: Any]) -> TokenCounts {
        TokenCounts(
            input: Int(number(usage["input_tokens"]) ?? 0),
            output: Int(number(usage["output_tokens"]) ?? 0),
            cacheRead: Int(number(usage["cache_read_input_tokens"]) ?? 0),
            cacheWrite: Int(number(usage["cache_creation_input_tokens"]) ?? 0)
        )
    }

    /// Tool result: text, or a list of blocks from which text is extracted.
    static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { block -> String? in
                if let text = block["text"] as? String { return text }
                if (block["type"] as? String) == "image" { return "[image]" }
                return nil
            }.joined(separator: "\n")
        }
        return ""
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            // JSON booleans are also NSNumber; they do not count as numbers (0 or 1 do).
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : number.doubleValue
        }
        if let text = value as? String { return Double(text) }
        return nil
    }

    // MARK: Messages to Claude Code (stdin)

    /// A user message in `--input-format stream-json` format. With `steer`, it has `priority: "now"`: Claude Code
    /// stops what it is doing in the running turn and takes the message in right away (T3Code's steering).
    static func userMessage(_ text: String, steer: Bool = false) -> String {
        var message: [String: Any] = ["type": "user", "message": ["role": "user", "content": text], "parent_tool_use_id": NSNull(), "session_id": ""]
        if steer { message["priority"] = "now" }
        return line(message)
    }

    /// Response to a permission prompt. On "allow", Claude Code sends back the original input.
    static func permissionResponse(requestID: String, allow: Bool, input: JSONBox, rules: JSONBox? = nil, message: String = "") -> String {
        var decision: [String: Any]
        if allow {
            decision = ["behavior": "allow", "updatedInput": input.object]
            if let rules { decision["updatedPermissions"] = rules.object }
        } else {
            decision = ["behavior": "deny", "message": message.isEmpty ? "Denied by user in Nook." : message]
        }
        return line(["type": "control_response",
                     "response": ["subtype": "success", "request_id": requestID, "response": decision]])
    }

    /// The answer to AskUserQuestion, given as permission to run the tool with the answers filled in (T3Code's way):
    /// `answers` maps each question's text to the chosen labels, joined.
    static func questionAnswer(requestID: String, input: JSONBox, questions: [RunQuestion], answers: [String: [String]]) -> String {
        var updated = input.dictionary
        var filled: [String: String] = [:]
        for question in questions { filled[question.question] = (answers[question.id] ?? []).joined(separator: ", ") }
        updated["answers"] = filled
        return line(["type": "control_response",
                     "response": ["subtype": "success", "request_id": requestID,
                                  "response": ["behavior": "allow", "updatedInput": updated]]])
    }

    /// Claude Code's AskUserQuestion input as questions Nook can show: one id per question (its index).
    static func questions(from input: JSONBox) -> [RunQuestion] {
        ((input.dictionary["questions"] as? [[String: Any]]) ?? []).enumerated().compactMap { index, raw in
            guard let text = raw["question"] as? String else { return nil }
            let options = ((raw["options"] as? [[String: Any]]) ?? []).compactMap { option -> RunQuestionOption? in
                guard let label = option["label"] as? String else { return nil }
                return RunQuestionOption(label: label, description: (option["description"] as? String) ?? "")
            }
            return RunQuestion(id: "q\(index)", header: (raw["header"] as? String) ?? "", question: text, options: options,
                               multiSelect: (raw["multiSelect"] as? Bool) ?? false, allowsOther: true)
        }
    }

    /// Requests Claude Code to interrupt the current turn.
    static func interruptRequest(id: String) -> String {
        line(["type": "control_request", "request_id": id, "request": ["subtype": "interrupt"]])
    }

    private static func line(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }
}

// MARK: Codex

/// What Nook extracts from one line of `codex exec --json`.
enum CodexStreamEvent: Equatable, Sendable {
    case threadStarted(String)
    case message(String)
    case reasoning(String)
    case commandStarted(id: String, command: String)
    case commandFinished(id: String, command: String, output: String, exitCode: Int?)
    case fileChanges(id: String, changes: [CodexFileChange])
    case toolCall(id: String, name: String, detail: String, finished: Bool, failed: Bool)
    case turnCompleted(TurnUsage)
    case failed(String)
    // `codex app-server` only (see CodexAppServer.swift).
    case turnStarted(String)
    case messageDelta(id: String, text: String)
    case messageCompleted(id: String, text: String)
    case reasoningDelta(id: String, text: String)
    case reasoningCompleted(id: String, text: String)
    case commandOutput(id: String, delta: String)
    case tokenUsage(CodexTokenUsage)
    case turnFinished(status: String, error: String?, durationSeconds: Double?)
    case approval(CodexApprovalRequest)
    case question(rpcID: RPCID, questions: [RunQuestion])
    /// A server request Nook does not handle: answered with an error so Codex does not wait forever.
    case unsupportedRequest(RPCID)
    case plan(String)
    case notice(String)
    case rateLimits(JSONBox)
    /// The turn stopped on a usage limit (`usageLimitExceeded`, `rateLimitExceeded`).
    case usageLimited
}

struct CodexFileChange: Equatable, Sendable {
    var path: String
    var kind: String
}

enum CodexStreamParser {
    static func parse(_ line: String) -> [CodexStreamEvent] {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        switch type {
        case "thread.started":
            return (object["thread_id"] as? String).map { [.threadStarted($0)] } ?? []
        case "turn.completed":
            var usage = TurnUsage()
            if let raw = object["usage"] as? [String: Any] {
                let cached = Int(ClaudeStreamParser.number(raw["cached_input_tokens"]) ?? 0)
                let input = Int(ClaudeStreamParser.number(raw["input_tokens"]) ?? 0)
                // Codex includes cached tokens in input_tokens; separated so they are not double-counted.
                usage.inputTokens = max(0, input - cached)
                usage.cacheReadTokens = cached
                usage.outputTokens = Int(ClaudeStreamParser.number(raw["output_tokens"]) ?? 0)
                usage.contextTokens = input
            }
            return [.turnCompleted(usage)]
        case "turn.failed":
            let message = ((object["error"] as? [String: Any])?["message"] as? String) ?? "Codex stopped with an error."
            return [.failed(message)]
        case "error":
            return [.failed((object["message"] as? String) ?? "Codex reported an error.")]
        case "item.started", "item.updated", "item.completed":
            guard let item = object["item"] as? [String: Any] else { return [] }
            return parseItem(item, finished: type == "item.completed")
        default:
            return []
        }
    }

    private static func parseItem(_ item: [String: Any], finished: Bool) -> [CodexStreamEvent] {
        let id = (item["id"] as? String) ?? UUID().uuidString
        // Older versions name the field "item_type".
        let kind = (item["type"] as? String) ?? (item["item_type"] as? String) ?? ""
        switch kind {
        case "agent_message", "assistant_message":
            guard finished, let text = item["text"] as? String, !text.isEmpty else { return [] }
            return [.message(text)]
        case "reasoning":
            guard finished, let text = item["text"] as? String, !text.isEmpty else { return [] }
            return [.reasoning(text)]
        case "command_execution":
            let command = (item["command"] as? String) ?? ""
            if finished {
                let exit = ClaudeStreamParser.number(item["exit_code"]).map { Int($0) }
                return [.commandFinished(id: id, command: command, output: (item["aggregated_output"] as? String) ?? "", exitCode: exit)]
            }
            return [.commandStarted(id: id, command: command)]
        case "file_change":
            guard finished else { return [] }
            let changes = ((item["changes"] as? [[String: Any]]) ?? []).compactMap { change -> CodexFileChange? in
                guard let path = change["path"] as? String else { return nil }
                return CodexFileChange(path: path, kind: (change["kind"] as? String) ?? "update")
            }
            return changes.isEmpty ? [] : [.fileChanges(id: id, changes: changes)]
        case "mcp_tool_call", "web_search":
            var name = (item["tool"] as? String) ?? (kind == "web_search" ? "web_search" : "mcp")
            var detail = (item["query"] as? String) ?? (item["server"] as? String) ?? ""
            // Nook's own workspace tools read as what they do: "Nook terminal · npm run dev".
            if (item["server"] as? String) == BridgeTool.serverName, let tool = BridgeTool.named(name) {
                name = tool.label
                detail = ((item["arguments"] as? [String: Any]).flatMap(BridgeTool.detail)).map { ToolSummary.oneLine($0, 120) } ?? ""
            }
            let failed = (item["status"] as? String) == "failed"
            return [.toolCall(id: id, name: name, detail: detail, finished: finished, failed: failed)]
        case "error":
            return [.failed((item["message"] as? String) ?? "Codex reported an error.")]
        default:
            return []
        }
    }
}

// MARK: Gemini CLI

/// What Nook extracts from one line of Gemini CLI's `--output-format stream-json`.
enum GeminiStreamEvent: Equatable, Sendable {
    case initialized(sessionID: String, model: String?)
    /// An answer chunk (`delta: true`) or a whole answer.
    case text(String, delta: Bool)
    case toolUse(id: String, name: String, input: JSONBox)
    case toolResult(id: String, output: String, isError: Bool)
    case warning(String)
    case failed(String)
    case result(isError: Bool, message: String?, usage: TurnUsage)
}

enum GeminiStreamParser {
    static func parse(_ line: String) -> [GeminiStreamEvent] {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        switch type {
        case "init":
            guard let session = object["session_id"] as? String, !session.isEmpty else { return [] }
            return [.initialized(sessionID: session, model: object["model"] as? String)]
        case "message":
            // The prompt is echoed as a user message; only the answer matters.
            guard (object["role"] as? String) == "assistant", let content = object["content"] as? String, !content.isEmpty else { return [] }
            return [.text(content, delta: (object["delta"] as? Bool) ?? false)]
        case "tool_use":
            let id = (object["tool_id"] as? String) ?? UUID().uuidString
            let name = (object["tool_name"] as? String) ?? "tool"
            return [.toolUse(id: id, name: name, input: JSONBox((object["parameters"] as? [String: Any]) ?? [:]))]
        case "tool_result":
            let id = (object["tool_id"] as? String) ?? ""
            let failed = (object["status"] as? String) == "error"
            let error = (object["error"] as? [String: Any])?["message"] as? String
            return [.toolResult(id: id, output: (object["output"] as? String) ?? error ?? "", isError: failed)]
        case "error":
            let message = (object["message"] as? String) ?? "Gemini CLI reported an error."
            return [(object["severity"] as? String) == "warning" ? .warning(message) : .failed(message)]
        case "result":
            var usage = TurnUsage()
            if let stats = object["stats"] as? [String: Any] {
                // `input_tokens` includes the cached part; keep them apart like the other agents.
                let cached = ClaudeStreamParser.number(stats["cached"]).map { Int($0) }
                let input = ClaudeStreamParser.number(stats["input"]).map { Int($0) }
                    ?? ClaudeStreamParser.number(stats["input_tokens"]).map { Int($0) - (cached ?? 0) }
                usage.inputTokens = input
                usage.cacheReadTokens = cached
                usage.outputTokens = ClaudeStreamParser.number(stats["output_tokens"]).map { Int($0) }
                usage.contextTokens = ClaudeStreamParser.number(stats["input_tokens"]).map { Int($0) }
                usage.durationSeconds = ClaudeStreamParser.number(stats["duration_ms"]).map { $0 / 1000 }
            }
            let isError = (object["status"] as? String) == "error"
            let message = (object["error"] as? [String: Any])?["message"] as? String
            return [.result(isError: isError, message: message, usage: usage)]
        default:
            return []
        }
    }
}
