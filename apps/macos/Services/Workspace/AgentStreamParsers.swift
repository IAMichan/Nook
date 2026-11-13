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

/// What an agent says about a permission request besides the tool and its input: why it asks (Claude Code's
/// `decision_reason`, Codex's `reason`, OpenCode's `message`), whether its own safety check stopped it, and whether the
/// answer may become a standing rule. The reason is the agent's text: one line on the approval card, never instructions.
struct PermissionAsk: Equatable, Sendable {
    var reason = ""
    /// The agent's own safety check sent the request to you (Claude Code's `safetyCheck`): the card reads as dangerous.
    var safetyCheck = false
    /// The agent says the answer must not become a rule for later requests: the card offers no "Always".
    var noAlways = false

    static let maxReason = 400

    init(reason: String = "", safetyCheck: Bool = false, noAlways: Bool = false) {
        self.reason = Self.clean(reason)
        self.safetyCheck = safetyCheck
        self.noAlways = noAlways
    }

    /// Claude Code's `can_use_tool` request. A reason of the kind "mode" (the permission mode asks for every such tool)
    /// or "permissionPromptTool" (Nook itself was asked) says nothing new and is left out.
    static func claude(_ request: [String: Any]) -> PermissionAsk {
        let kind = request["decision_reason_type"] as? String
        let reason = ["mode", "permissionPromptTool"].contains(kind ?? "") ? "" : (request["decision_reason"] as? String) ?? ""
        // `classifier_approvable` is only there when a safety check took part, also inside a compound command.
        return PermissionAsk(reason: reason, safetyCheck: kind == "safetyCheck" || request["classifier_approvable"] != nil,
                             noAlways: (request["suppress_always_allow_rule"] as? Bool) == true)
    }

    /// One line of plain text: terminal escapes (Claude Code's reason may carry colors) and control characters out,
    /// whitespace collapsed, at most `maxReason` characters.
    static func clean(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\u{1B}" {
                // CSI (`ESC [ … final`) and OSC (`ESC ] … BEL` or `ESC \`): skip to their end; any other escape: one character.
                guard let next = iterator.next() else { break }
                if next == "[" {
                    while let c = iterator.next(), !(0x40...0x7E).contains(c.value) {}
                } else if next == "]" {
                    var previous: Unicode.Scalar = " "
                    while let c = iterator.next(), c != "\u{07}", !(previous == "\u{1B}" && c == "\\") { previous = c }
                }
                continue
            }
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        let words = String(scalars).split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        return words.count > maxReason ? String(words.prefix(maxReason - 1)) + "…" : words
    }
}

/// Tokens from a single model call, as reported by the agent.
struct TokenCounts: Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    /// Claude: how long what this call wrote to the cache stays there (`PromptCache.claudeTTL`).
    var cacheTTL: TimeInterval? = nil

    /// Tokens present in context during this call.
    var context: Int { input + cacheRead + cacheWrite }
}

// MARK: Claude Code

/// What Nook extracts from one line of Claude Code's `--output-format stream-json`.
enum ClaudeStreamEvent: Equatable, Sendable {
    case initialized(sessionID: String, model: String?)
    /// Claude Code said something about its `/goal`.
    case goal(SessionGoalUpdate)
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
    /// A subagent's own thought, message or tool call, for the call that started it (`parent_tool_use_id`).
    case subagentStep(parent: String, SubagentStep)
    case toolResult(id: String, output: String, isError: Bool)
    case usage(messageID: String, tokens: TokenCounts, model: String?)
    /// A request to the model started (`message_start`): its prompt cache lives from now, for this long when it wrote
    /// to the cache (see `PromptCacheWindow`).
    case requestStarted(cacheTTL: TimeInterval?)
    /// The agent requests permission (`--permission-prompt-tool stdio`).
    case permissionRequest(requestID: String, tool: String, input: JSONBox, suggestions: JSONBox?, toolUseID: String?,
                           ask: PermissionAsk = PermissionAsk())
    /// An MCP server asks you something through Claude Code (`elicitation`).
    case elicitation(ClaudeElicitation)
    case result(ClaudeTurnResult)
    case notice(String)
    /// Claude Code started compacting the conversation (`system/status` with `status: "compacting"`), or a compaction
    /// failed (`compact_result: "failed"`); the result itself is the `compact` notice (`compact_boundary`).
    case compaction(CompactionPhase)
    /// Claude Code reports a change in the subscription limits (`rate_limit_event`).
    /// A limit changed; with the details when Claude Code gave them (a blocked window and when it resets).
    case rateLimits(UsageLimits.ClaudeEvent?)
    /// How full a subscription window is, as Claude Code reports it in the same `rate_limit_event`.
    case planWindow(UsageLimits.PlanReading)
    /// Work Claude Code runs in the background (a subagent started with `run_in_background`) started or ended, from its
    /// `task_started` and `task_notification` messages or the `<task-notification>` it hands the model. `toolUseID` is
    /// the call that started it, `taskID` the id its launch output names; `status` is nil while it runs.
    case backgroundTask(BackgroundTaskUpdate)
    /// Claude Code's prediction of your next message, after a turn (`--prompt-suggestions`).
    case promptSuggestion(String)
    /// An entry of the main conversation chain (an assistant or user message's `uuid`): where `--resume-session-at` can
    /// pick the conversation up again.
    case chainEntry(String)
    /// The connectors (MCP servers) that wait for you to sign in, by name, as system/init lists them.
    case connectorsNeedingSignIn([String])
    /// Claude Code's answer to a control request Nook sent: its response, or the error it gave.
    case controlReply(requestID: String, response: JSONBox?, error: String?)
}

extension ClaudeStreamEvent {
    /// The agent is working: it writes, thinks, uses a tool or asks permission (not a notice, usage or limits).
    static func isWork(_ event: ClaudeStreamEvent) -> Bool {
        switch event {
        case .textDelta, .text, .thinking, .thinkingDelta, .toolUse, .subagentStep, .permissionRequest, .elicitation: return true
        default: return false
        }
    }
}

/// News about a task Claude Code runs in the background.
struct BackgroundTaskUpdate: Equatable, Sendable {
    /// `killed`: Claude Code ended it, at the agent's request (TaskStop) or because it ran past its time limit.
    enum Status: String, Sendable { case completed, failed, stopped, killed }

    var taskID: String?
    var toolUseID: String?
    /// nil: it started (or still runs).
    var status: Status?
    /// "Agent \"Audit the chats\" completed".
    var summary: String?
    /// What the subagent answered, when Claude Code passes it on.
    var result: String?

    /// Claude Code's `<task-notification>` block, as it hands it to the model when background work ended.
    static func notification(_ text: String) -> BackgroundTaskUpdate? {
        guard text.contains("<task-notification>") else { return nil }
        func tag(_ name: String) -> String? {
            guard let start = text.range(of: "<\(name)>"),
                  let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex) else { return nil }
            let value = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        let update = BackgroundTaskUpdate(taskID: tag("task-id"), toolUseID: tag("tool-use-id"),
                                          status: tag("status").flatMap(Status.init(rawValue:)) ?? .completed,
                                          summary: tag("summary"), result: tag("result"))
        return update.taskID == nil && update.toolUseID == nil ? nil : update
    }
}

/// An MCP server's question through Claude Code (`control_request` `elicitation`). Nook answers one it can put as Allow
/// or Deny: a confirmation without fields to fill in, as for Codex (`CodexAppServerMapper.mcpApproval`). A form with
/// fields or a page to open is declined at once, as Claude Code's own SDK does without a handler, so nothing waits on it.
struct ClaudeElicitation: Equatable, Sendable {
    /// Before the request's id in `PendingPermission.id`: its answer is an elicitation result, not a tool permission.
    static let pendingPrefix = "claude-elicitation-"

    var requestID: String
    var server: String
    var message: String
    /// The server's own title for the question (`_meta['anthropic/permissionDisplay']`), when it gave one.
    var title: String = ""
    var isConfirmation: Bool

    init(requestID: String, server: String, message: String, title: String = "", isConfirmation: Bool) {
        self.requestID = requestID
        self.server = server
        self.message = message
        self.title = title
        self.isConfirmation = isConfirmation
    }

    init?(requestID: String, _ request: [String: Any]) {
        guard (request["subtype"] as? String) == "elicitation" else { return nil }
        let mode = (request["mode"] as? String) ?? "form"
        let schema = (request["requested_schema"] as? [String: Any]) ?? [:]
        let fields = (schema["properties"] as? [String: Any]) ?? [:]
        self.init(requestID: requestID, server: (request["mcp_server_name"] as? String) ?? "",
                  message: String(((request["message"] as? String) ?? "").prefix(600)),
                  title: PermissionAsk.clean((request["title"] as? String) ?? ""),
                  isConfirmation: mode == "form" && fields.isEmpty)
    }
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
        let parent = object["parent_tool_use_id"] as? String

        switch type {
        case "system":
            let subtype = (object["subtype"] as? String) ?? ""
            if subtype == "init", let session = object["session_id"] as? String {
                var events: [ClaudeStreamEvent] = [.initialized(sessionID: session, model: object["model"] as? String)]
                if object["mcp_servers"] != nil { events.append(.connectorsNeedingSignIn(ConnectorSignIns.claude(object["mcp_servers"]))) }
                return events
            }
            if subtype == "compact_boundary" { return [.notice("compact")] }
            if subtype == "status" {
                if object["status"] as? String == "compacting" { return [.compaction(.started)] }
                if object["compact_result"] as? String == "failed" { return [.compaction(.failed(object["compact_error"] as? String))] }
                return []
            }
            if subtype == "task_started" || subtype == "task_notification" {
                let update = BackgroundTaskUpdate(
                    taskID: object["task_id"] as? String, toolUseID: object["tool_use_id"] as? String,
                    status: subtype == "task_started" ? nil
                        : ((object["status"] as? String).flatMap(BackgroundTaskUpdate.Status.init(rawValue:)) ?? .completed),
                    summary: (object["summary"] as? String) ?? (object["description"] as? String), result: nil)
                return update.taskID == nil && update.toolUseID == nil ? [] : [.backgroundTask(update)]
            }
            return []

        case "stream_event":
            guard !nested, let event = object["event"] as? [String: Any] else { return [] }
            switch event["type"] as? String {
            case "content_block_start":
                // Thinking shows while it is written.
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
            case "message_start":
                let usage = ((event["message"] as? [String: Any])?["usage"] as? [String: Any]) ?? [:]
                return [.requestStarted(cacheTTL: PromptCache.claudeTTL(usage))]
            default:
                return []
            }

        case "assistant":
            guard let message = object["message"] as? [String: Any] else { return [] }
            var events: [ClaudeStreamEvent] = []
            for block in (message["content"] as? [[String: Any]]) ?? [] {
                switch block["type"] as? String {
                case "text":
                    guard let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                    // A subagent's message is its own, not the answer: it goes with the call that started it.
                    if let parent { events.append(.subagentStep(parent: parent, SubagentStep(kind: .text, text: text))) }
                    else if !nested {
                        events.append(.text(text))
                        if (message["model"] as? String) == "<synthetic>", let goal = SessionGoals.claude(synthetic: text) {
                            events.append(.goal(goal))
                        }
                    }
                case "thinking":
                    // Also when empty: it matches the streamed block, which keeps its text then.
                    if !nested { events.append(.thinking((block["thinking"] as? String) ?? "")) }
                    else if let parent, let text = block["thinking"] as? String, !text.isEmpty {
                        events.append(.subagentStep(parent: parent, SubagentStep(kind: .thinking, text: text)))
                    }
                case "tool_use":
                    if let id = block["id"] as? String, let name = block["name"] as? String {
                        let input = block["input"] ?? [String: Any]()
                        events.append(.toolUse(id: id, name: name, input: JSONBox(input), nested: nested))
                        if let parent {
                            let title = ToolSummary.describe(tool: name, input: (input as? [String: Any]) ?? [:])
                            events.append(.subagentStep(parent: parent, SubagentStep(kind: .tool, text: title, tool: name)))
                        }
                    }
                default:
                    break
                }
            }
            if !nested, let id = message["id"] as? String, let usage = message["usage"] as? [String: Any] {
                events.append(.usage(messageID: id, tokens: tokens(usage), model: message["model"] as? String))
            }
            if !nested, let uuid = object["uuid"] as? String, !uuid.isEmpty { events.append(.chainEntry(uuid)) }
            return events

        case "user":
            let entry: [ClaudeStreamEvent] = !nested ? ((object["uuid"] as? String).flatMap { $0.isEmpty ? nil : [.chainEntry($0)] } ?? []) : []
            guard let message = object["message"] as? [String: Any] else { return entry }
            let synthetic = !nested && (object["isSynthetic"] as? Bool) == true
            // The note Claude Code hands the model when background work ended.
            if !nested, let text = message["content"] as? String {
                let goal: [ClaudeStreamEvent] = synthetic ? (SessionGoals.claude(hookFeedback: text).map { [.goal($0)] } ?? []) : []
                return goal + (BackgroundTaskUpdate.notification(text).map { [.backgroundTask($0)] } ?? []) + entry
            }
            guard let content = message["content"] as? [[String: Any]] else { return entry }
            let goal: [ClaudeStreamEvent] = !synthetic ? [] : content.compactMap { block in
                (block["type"] as? String) == "text" ? (block["text"] as? String).flatMap(SessionGoals.claude(hookFeedback:)).map { .goal($0) } : nil
            }
            let notices: [ClaudeStreamEvent] = nested ? [] : content.compactMap { block in
                guard (block["type"] as? String) == "text", let text = block["text"] as? String else { return nil }
                return BackgroundTaskUpdate.notification(text).map { .backgroundTask($0) }
            }
            return goal + notices + content.compactMap { block in
                guard (block["type"] as? String) == "tool_result", let id = block["tool_use_id"] as? String else { return nil }
                return .toolResult(id: id, output: resultText(block["content"]), isError: (block["is_error"] as? Bool) ?? false)
            } + entry

        case "control_request":
            guard let requestID = object["request_id"] as? String,
                  let request = object["request"] as? [String: Any] else { return [] }
            if let elicitation = ClaudeElicitation(requestID: requestID, request) { return [.elicitation(elicitation)] }
            guard (request["subtype"] as? String) == "can_use_tool",
                  let tool = request["tool_name"] as? String else { return [] }
            return [.permissionRequest(
                requestID: requestID,
                tool: tool,
                input: JSONBox(request["input"] ?? [String: Any]()),
                suggestions: request["permission_suggestions"].flatMap { $0 is NSNull ? nil : JSONBox($0) },
                toolUseID: request["tool_use_id"] as? String,
                ask: PermissionAsk.claude(request)
            )]

        case "control_response":
            guard let response = object["response"] as? [String: Any], let requestID = response["request_id"] as? String else { return [] }
            if (response["subtype"] as? String) == "error" {
                return [.controlReply(requestID: requestID, response: nil, error: (response["error"] as? String) ?? "error")]
            }
            return [.controlReply(requestID: requestID, response: JSONBox(response["response"] ?? [String: Any]()), error: nil)]

        case "prompt_suggestion":
            let text = ((object["suggestion"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [.promptSuggestion(text)]

        case "rate_limit_event":
            let info = object["rate_limit_info"] as? [String: Any]
            var events: [ClaudeStreamEvent] = [.rateLimits(info.flatMap(UsageLimits.claudeEvent))]
            if let reading = info.flatMap(UsageLimits.planReading) { events.append(.planWindow(reading)) }
            return events

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
            cacheWrite: Int(number(usage["cache_creation_input_tokens"]) ?? 0),
            cacheTTL: PromptCache.claudeTTL(usage)
        )
    }

    /// Tool result: text, or a list of blocks from which text is extracted.
    static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { block -> String? in
                if let text = block["text"] as? String { return text }
                if (block["type"] as? String) == "image" { return "[image]" }
                return McpUI.encode(block)
            }.joined(separator: "\n")
        }
        return ""
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            // JSON booleans are also NSNumber; they do not count as numbers (0 or 1 do).
            #if canImport(Darwin)
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : number.doubleValue
            #else
            // swift-corelibs-foundation (the tests on Linux): a JSON boolean is an NSNumber of type "c".
            return String(cString: number.objCType) == "c" ? nil : number.doubleValue
            #endif
        }
        if let text = value as? String { return Double(text) }
        return nil
    }

    // MARK: Messages to Claude Code (stdin)

    /// A user message in `--input-format stream-json` format. With `steer`, it has `priority: "now"`: Claude Code
    /// stops what it is doing in the running turn and takes the message in right away.
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
            // The reason the user typed with the denial goes to the agent with it (`ProviderCapabilities.denyReason`).
            decision = ["behavior": "deny", "message": message.isEmpty ? "Denied by user in Nook." : "Denied by user in Nook: " + message]
        }
        return line(["type": "control_response",
                     "response": ["subtype": "success", "request_id": requestID, "response": decision]])
    }

    /// The answer to AskUserQuestion, given as permission to run the tool with the answers filled in:
    /// `answers` maps each question's text to the chosen labels, joined.
    static func questionAnswer(requestID: String, input: JSONBox, questions: [RunQuestion], answers: [String: [String]]) -> String {
        var updated = input.dictionary
        var filled: [String: String] = [:]
        for question in questions { filled[question.question] = (answers[question.id] ?? []).joined(separator: ", ") }
        updated["answers"] = filled
        // Which preview you picked, as Claude Code's own question dialog tells it.
        let annotations = QuestionPreview.annotations(questions.map { question in
            (question: question.question, options: question.options.map { (label: $0.label, preview: $0.preview) },
             chosen: answers[question.id] ?? [])
        })
        if !annotations.isEmpty { updated["annotations"] = annotations }
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
                return RunQuestionOption(label: label, description: (option["description"] as? String) ?? "",
                                         preview: QuestionPreview.read(option))
            }
            return RunQuestion(id: "q\(index)", header: (raw["header"] as? String) ?? "", question: text, options: options,
                               multiSelect: (raw["multiSelect"] as? Bool) ?? false, allowsOther: true)
        }
    }

    /// The answer to an MCP server's question (`elicitation`): accepted with nothing filled in, or declined.
    static func elicitationResponse(requestID: String, accept: Bool) -> String {
        var result: [String: Any] = ["action": accept ? "accept" : "decline"]
        if accept { result["content"] = [String: Any]() }
        return line(["type": "control_response", "response": ["subtype": "success", "request_id": requestID, "response": result]])
    }

    /// Stops one task Claude Code runs in the background (a subagent), by the id its launch named; the turn goes on.
    static func stopTaskRequest(id: String, taskID: String) -> String {
        line(["type": "control_request", "request_id": id, "request": ["subtype": "stop_task", "task_id": taskID]])
    }

    /// Requests Claude Code to interrupt the current turn.
    static func interruptRequest(id: String) -> String {
        line(["type": "control_request", "request_id": id, "request": ["subtype": "interrupt"]])
    }

    /// Changes the permission mode of a running Claude Code ("default", "acceptEdits", "bypassPermissions", "plan").
    static func setPermissionModeRequest(id: String, mode: String) -> String {
        line(["type": "control_request", "request_id": id, "request": ["subtype": "set_permission_mode", "mode": mode]])
    }

    /// Changes the model of a running Claude Code; an empty model goes back to its default.
    static func setModelRequest(id: String, model: String) -> String {
        var request: [String: Any] = ["subtype": "set_model"]
        if !model.isEmpty { request["model"] = model }
        return line(["type": "control_request", "request_id": id, "request": request])
    }

    /// Asks for a connector's sign-in page (`authUrl`). For a claude.ai connector it is claude.ai's own page; for an
    /// OAuth server Claude Code also waits for the page's answer itself (`callbackExpected`).
    static func mcpAuthenticateRequest(id: String, server: String) -> String {
        line(["type": "control_request", "request_id": id, "request": ["subtype": "mcp_authenticate", "serverName": server]])
    }

    /// Asks how each connector is doing (`mcpServers`, rows with `name` and `status`).
    static func mcpStatusRequest(id: String) -> String {
        line(["type": "control_request", "request_id": id, "request": ["subtype": "mcp_status"]])
    }

    /// Asks what fills the context window (`ContextUsage.claude`). `summary` answers from the last response's usage and
    /// local estimates, without the token-count calls of `full`.
    static func contextUsageRequest(id: String) -> String {
        line(["type": "control_request", "request_id": id, "request": ["subtype": "get_context_usage", "detail": "summary"]])
    }

    /// Connects a connector again, as after signing in to it on claude.ai.
    static func mcpReconnectRequest(id: String, server: String) -> String {
        line(["type": "control_request", "request_id": id, "request": ["subtype": "mcp_reconnect", "serverName": server]])
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
    /// A tool call (MCP, web search, a dynamic tool), with its arguments and what it returned when Codex says.
    case toolCall(id: String, name: String, detail: String, finished: Bool, failed: Bool, input: JSONBox? = nil, output: String? = nil)
    /// An MCP tool call that finished with an app (`ui://` page) to show (codex app-server): arguments and result as JSON.
    case mcpApp(id: String, server: String, tool: String, arguments: String?, result: String?, resourceUri: String)
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
    /// A question Codex asks while it goes on working (an `agentMessage` with `delivery: "async"`): nothing waits for
    /// the answer, which goes to Codex as a message of yours.
    case asyncQuestion(id: String, questions: [RunQuestion])
    /// Codex took a message of yours into a thread (`item/started` of a `userMessage` item): a turn's prompt, or a steer
    /// it reads now. Its text, and the thread when Codex named it (a subagent's has its own).
    case userMessage(text: String?, thread: String?)
    /// A server request Nook does not handle: answered with an error so Codex does not wait forever.
    case unsupportedRequest(RPCID)
    case plan(String)
    /// The agent's task list (`turn/plan/updated`).
    case tasks([RunTaskStep])
    /// Codex's goal changed (`thread/goal/updated`, `thread/goal/cleared`). A subagent's thread has goals of its own.
    case goal(SessionGoalUpdate, thread: String?)
    /// Codex started subagents (`collabAgentToolCall` with `spawnAgent`): the call, its task and the threads they run on.
    case subagentSpawned(id: String, prompt: String, model: String?, threads: [String], failed: Bool)
    /// How Codex's subagents are doing, per thread (from any `collabAgentToolCall`, `wait` above all).
    case subagentStates([String: CodexAgentState])
    case notice(String)
    /// The app-server started compacting the thread (`item/started` of a `contextCompaction` item); its
    /// `item/completed` is the `compact` notice.
    case compaction(CompactionPhase)
    case rateLimits(JSONBox)
    /// The turn stopped on a usage limit (`usageLimitExceeded`, `rateLimitExceeded`).
    case usageLimited
}

/// One Codex subagent's state: pendingInit, running, interrupted, completed, errored, shutdown, notFound.
struct CodexAgentState: Equatable, Sendable {
    var status: String
    var message: String?

    var isFinished: Bool { !["pendingInit", "running"].contains(status) }
    var isFailure: Bool { ["errored", "interrupted", "notFound"].contains(status) }
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
            return [.toolCall(id: id, name: name, detail: detail, finished: finished, failed: failed,
                              input: CodexToolResult.arguments(item), output: finished ? CodexToolResult.text(item) : nil)]
        case "error":
            return [.failed((item["message"] as? String) ?? "Codex reported an error.")]
        default:
            return []
        }
    }
}

/// What a Codex tool call (exec or app-server) was given and returned, in the shape the timeline shows for every agent.
enum CodexToolResult {
    /// The call's arguments, when they are an object.
    static func arguments(_ item: [String: Any]) -> JSONBox? {
        (item["arguments"] as? [String: Any]).map { JSONBox($0) }
    }

    /// The result's text blocks, or the error's message; nil when the call says neither.
    static func text(_ item: [String: Any]) -> String? {
        if let error = item["error"] as? [String: Any], let message = error["message"] as? String, !message.isEmpty { return message }
        if let error = item["error"] as? String, !error.isEmpty { return error }
        guard let result = item["result"], !(result is NSNull) else { return nil }
        let content = (result as? [String: Any])?["content"] ?? result
        let text = ClaudeStreamParser.resultText(content)
        return text.isEmpty ? nil : text
    }
}

// MARK: Gemini CLI

/// What Nook extracts from one line of Gemini CLI's `--output-format stream-json`. It has no thoughts: the stream does
/// not carry them (the ACP mode does, see docs/INTEGRATIONS.md).
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

/// One line of an agent's output, parsed on the queue that read it. Every agent's stdout is read on a queue of its own
/// (`AgentProcess`), so parsing there costs the main thread nothing however many agents stream at once; the main thread
/// only applies the events. Codex's app-server and the ACP agents parse their messages on their own queues already.
enum ParsedStreamLine: Sendable, Equatable {
    case claude([ClaudeStreamEvent])
    case codex([CodexStreamEvent])
    case gemini([GeminiStreamEvent])
    case pi([PiStreamEvent])
    /// An agent whose output Nook does not read line by line here (the ACP agents read their own messages).
    case none

    static func parse(_ line: String, provider: RunProvider) -> ParsedStreamLine {
        switch provider {
        case .claude: return .claude(ClaudeStreamParser.parse(line))
        case .codex: return .codex(CodexStreamParser.parse(line))
        case .gemini: return .gemini(GeminiStreamParser.parse(line))
        case .pi: return .pi(PiStreamParser.parse(line))
        case .opencode, .cursor, .grok, .antigravity, .acp: return .none
        }
    }

    static func parse(_ lines: [String], provider: RunProvider) -> [ParsedStreamLine] {
        lines.map { parse($0, provider: provider) }
    }
}
