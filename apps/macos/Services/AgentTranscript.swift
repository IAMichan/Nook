import Foundation

/// One thing the agent did between its messages: a command, a file it read or changed, a search, a subagent.
struct AgentToolStep: Identifiable, Equatable {
    enum State: Equatable {
        /// No result in the transcript yet: still going, or cut off.
        case running
        case done
        case failed
    }

    /// The agent's own call id, to match the result.
    let id: String
    /// "Bash", "Read", "Edit", or the bare tool name of an MCP tool.
    var name: String
    /// What it was about: the command's description, the file, the pattern.
    var summary: String
    var state: State = .running
    /// The command line of a shell step, to tell a test run or a build from other commands.
    var command: String? = nil
    /// The task list a step set (Claude Code's TodoWrite, Codex's update_plan).
    var tasks: [RunTaskStep]? = nil
    /// The file a step wrote or edited, as the agent named it.
    var path: String? = nil
    /// The plan a step proposed (Claude Code's ExitPlanMode), in Markdown.
    var plan: String? = nil
    /// The lines an edit added and removed.
    var lines: EditLines? = nil
}

/// A single message from an active session's conversation.
struct AgentChatMessage: Identifiable, Equatable {
    enum Kind: Equatable {
        case user
        case assistant
        /// The agent's reasoning. Empty text when the agent keeps it to itself (Claude Code may store only that it thought).
        case thinking
        /// Steps in a row, between the messages.
        case tools
    }

    let id: String
    let kind: Kind
    var text: String
    var steps: [AgentToolStep] = []
    /// When it was written, and when the last part of it (a later block, a step's result) came in: what the turn took.
    var date: Date?
    var updated: Date?

    var fromUser: Bool { kind == .user }
    var isThinking: Bool { kind == .thinking }
    var isTools: Bool { kind == .tools }

    init(id: String, fromUser: Bool, text: String) {
        self.id = id
        self.kind = fromUser ? .user : .assistant
        self.text = text
    }

    init(id: String, kind: Kind, text: String, steps: [AgentToolStep] = [], date: Date? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.steps = steps
        self.date = date
        self.updated = date
    }

    /// A later part of the same message came in at `date`.
    mutating func touch(_ date: Date?) {
        guard let date else { return }
        if self.date == nil { self.date = date }
        if updated.map({ date > $0 }) ?? true { updated = date }
    }
}

/// Reads a session's conversation from the agent's own transcript: user prompts, agent responses, thinking/reasoning
/// blocks and the steps in between (commands, files, searches), as the agent's own app shows them. System prompts and
/// tool output are excluded. Understands Claude Code, Codex and Antigravity (JSONL) and
/// Gemini CLI (one JSON file per chat).
enum AgentTranscript {
    /// Number of bytes to read from the end of a JSONL file: enough for the whole conversation of nearly every session.
    private static let tailBytes: UInt64 = 8_000_000
    private static let maxMessageLength = 24_000
    /// The whole conversation by default; a cap only guards against pathological files.
    static let fullLimit = 1_000

    private struct CacheEntry {
        let size: UInt64
        let modified: Date
        let limit: Int
        let messages: [AgentChatMessage]
        /// JSONL only: the messages of every complete line read so far, where those lines end in the file, and how many
        /// lines that was. A transcript an agent is writing grows every few seconds while the view polls it: it is read
        /// on from `parsedTo` instead of parsing up to eight megabytes again.
        var parsed: [AgentChatMessage] = []
        var parsedTo: UInt64 = 0
        var lines = 0
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: CacheEntry] = [:]

    static func recent(path: String, limit: Int = fullLimit) -> [AgentChatMessage] {
        let isGemini = path.hasSuffix(".json")
        guard path.hasSuffix(".jsonl") || isGemini else { return [] }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let attrSize = (attrs?[.size] as? NSNumber)?.uint64Value
        let attrMod = attrs?[.modificationDate] as? Date

        if let attrSize, let attrMod {
            cacheLock.lock()
            if let hit = cache[path], hit.size == attrSize, hit.modified == attrMod, hit.limit >= limit {
                let result = Array(hit.messages.suffix(limit))
                cacheLock.unlock()
                return result
            }
            cacheLock.unlock()
        }

        var messages: [AgentChatMessage]
        var size: UInt64 = attrSize ?? 0
        var progress: (parsed: [AgentChatMessage], to: UInt64, lines: Int)?
        if isGemini {
            guard let data = FileManager.default.contents(atPath: path) else { return [] }
            size = UInt64(data.count)
            messages = gemini(data)
        } else {
            guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
            defer { try? handle.close() }
            guard let end = try? handle.seekToEnd() else { return [] }
            size = end
            cacheLock.lock()
            let previous = cache[path]
            cacheLock.unlock()
            let base: (parsed: [AgentChatMessage], to: UInt64, lines: Int)
            var data: Data
            if let previous, previous.parsedTo > 0, end >= previous.parsedTo, end - previous.parsedTo <= tailBytes {
                // The file grew: only what was added since the last complete line.
                base = (previous.parsed, previous.parsedTo, previous.lines)
                try? handle.seek(toOffset: previous.parsedTo)
                guard let added = try? handle.readToEnd() else { return [] }
                data = added
            } else {
                let start = end > tailBytes ? end - tailBytes : 0
                try? handle.seek(toOffset: start)
                guard let read = try? handle.readToEnd() else { return [] }
                data = read
                var from = start
                // If reading started mid-line, skip the initial partial line.
                if start > 0, let newline = data.firstIndex(of: 0x0A) {
                    data = Data(data[data.index(after: newline)...])
                    from = start + UInt64(newline + 1)
                }
                base = ([], from, 0)
            }
            // Lines up to the last newline are final; a line still being written is parsed for this answer only, and
            // read again (complete) next time.
            let cut = data.lastIndex(of: 0x0A).map { data.index(after: $0) } ?? data.startIndex
            let complete = data[data.startIndex..<cut]
            let parsed = jsonl(complete, continuing: base.parsed, firstLine: base.lines)
            let lines = base.lines + complete.split(separator: 0x0A).count
            let rest = data[cut...]
            messages = rest.isEmpty ? parsed : jsonl(rest, continuing: parsed, firstLine: lines)
            // Bounded like a full read: the newest messages are all anyone sees.
            progress = (Array(parsed.suffix(fullLimit)), base.to + UInt64(cut - data.startIndex), lines)
        }
        let result = Array(messages.suffix(limit))
        if let attrMod {
            var entry = CacheEntry(size: attrSize ?? size, modified: attrMod, limit: limit, messages: result)
            if let progress {
                entry.parsed = progress.parsed
                entry.parsedTo = progress.to
                entry.lines = progress.lines
            }
            cacheLock.lock()
            if cache.count > 64 { cache.removeAll(keepingCapacity: true) }
            cache[path] = entry
            cacheLock.unlock()
        }
        return result
    }

    /// Claude Code, Antigravity and Codex: one JSON object per line.
    static func jsonl(_ data: Data) -> [AgentChatMessage] {
        jsonl(data, continuing: [], firstLine: 0)
    }

    /// Parses more lines of a transcript after `earlier` (what its first `firstLine` lines gave): the same messages as
    /// parsing all lines at once, since every line only adds to or finishes what came before.
    static func jsonl(_ data: Data, continuing earlier: [AgentChatMessage], firstLine: Int) -> [AgentChatMessage] {
        var messages = earlier
        for (offset, line) in data.split(separator: 0x0A).enumerated() {
            let index = firstLine + offset
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            let id = (object["uuid"] as? String) ?? (object["id"] as? String) ?? "\(object["step_index"] ?? index)"
            let type = (object["type"] as? String) ?? ""
            let when = date(object["timestamp"])

            // Claude Code
            if type == "user" || type == "assistant" {
                guard (object["isMeta"] as? Bool) != true, (object["isSidechain"] as? Bool) != true,
                      let message = object["message"] as? [String: Any] else { continue }

                if type == "user" {
                    // Results of the agent's steps come back as user lines: they only mark a step done or failed.
                    for block in (message["content"] as? [[String: Any]]) ?? [] where block["type"] as? String == "tool_result" {
                        guard let callID = block["tool_use_id"] as? String else { continue }
                        finish(step: callID, failed: (block["is_error"] as? Bool) == true, at: when, in: &messages)
                    }
                    let text = text(message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, isTypedPrompt(text) else { continue }
                    messages.append(AgentChatMessage(id: id, kind: .user, text: clip(text), date: when))
                } else {
                    // One line can hold several blocks; keep their order (thinking, text, steps).
                    for (offset, block) in ((message["content"] as? [[String: Any]]) ?? []).enumerated() {
                        let blockID = "\(id)-\(offset)"
                        switch block["type"] as? String {
                        case "thinking", "redacted_thinking":
                            append(thinking: (block["thinking"] as? String) ?? "", id: blockID, at: when, to: &messages, allowEmpty: true)
                        case "text":
                            append(reply: (block["text"] as? String) ?? "", id: blockID, at: when, to: &messages)
                        case "tool_use", "server_tool_use":
                            let name = (block["name"] as? String) ?? ""
                            let input = (block["input"] as? [String: Any]) ?? [:]
                            append(step: AgentToolStep(id: (block["id"] as? String) ?? blockID, name: toolName(name),
                                                       summary: toolSummary(name, input), command: ToolSummary.command(input),
                                                       tasks: SessionOutputs.taskList(tool: name, input: input),
                                                       path: ToolCategory.of(tool: name) == .edit ? ToolSummary.path(input) : nil,
                                                       plan: name == "ExitPlanMode" ? input["plan"] as? String : nil,
                                                       lines: EditLines.of(tool: name, input: input)),
                                   at: when, to: &messages)
                        default:
                            continue
                        }
                    }
                    if let content = message["content"] as? String { append(reply: content, id: id, at: when, to: &messages) }
                }
            }
            // Antigravity (USER_INPUT, PLANNER_RESPONSE)
            else if type == "USER_INPUT" {
                guard let raw = object["content"] as? String else { continue }
                let text = cleanAntigravityPrompt(raw)
                guard !text.isEmpty else { continue }
                messages.append(AgentChatMessage(id: id, kind: .user, text: clip(text), date: when))
            } else if type == "PLANNER_RESPONSE" {
                append(thinking: (object["thinking"] as? String) ?? "", id: id, at: when, to: &messages)
                append(reply: (object["content"] as? String) ?? "", id: id, at: when, to: &messages)
            }
            // Codex (event_msg): prompts, answers and the reasoning summaries it shows while it thinks.
            else if type == "event_msg", let payload = object["payload"] as? [String: Any],
                    let ptype = payload["type"] as? String {
                switch ptype {
                case "user_message":
                    let text = ((payload["message"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    messages.append(AgentChatMessage(id: id, kind: .user, text: clip(text), date: when))
                case "agent_message":
                    append(reply: (payload["message"] as? String) ?? "", id: id, at: when, to: &messages)
                case "agent_reasoning":
                    append(thinking: (payload["text"] as? String) ?? "", id: id, at: when, to: &messages)
                default:
                    continue
                }
            }
            // Codex (response_item): the commands and tools it runs.
            else if type == "response_item", let payload = object["payload"] as? [String: Any],
                    let ptype = payload["type"] as? String {
                let callID = (payload["call_id"] as? String) ?? (payload["id"] as? String) ?? "\(id)-call"
                switch ptype {
                case "function_call", "custom_tool_call":
                    let name = (payload["name"] as? String) ?? ""
                    let arguments = (payload["arguments"] as? String).flatMap {
                        (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
                    } ?? [:]
                    append(step: AgentToolStep(id: callID, name: codexToolName(name), summary: codexSummary(name, arguments),
                                               command: ToolSummary.command(arguments) ?? (arguments["cmd"] as? String),
                                               tasks: SessionOutputs.taskList(tool: name, input: arguments),
                                               // apply_patch arrives as a custom tool call with the patch as its input.
                                               lines: name == "apply_patch"
                                                   ? (payload["input"] as? String).flatMap(EditLines.of(patch:))
                                                       ?? EditLines.of(tool: name, input: arguments)
                                                   : nil),
                           at: when, to: &messages)
                case "local_shell_call":
                    let action = (payload["action"] as? [String: Any]) ?? [:]
                    append(step: AgentToolStep(id: callID, name: "Shell", summary: codexSummary("shell", action),
                                               command: ToolSummary.command(action)), at: when, to: &messages)
                case "web_search_call":
                    let action = (payload["action"] as? [String: Any]) ?? [:]
                    append(step: AgentToolStep(id: callID, name: "WebSearch", summary: oneLine((action["query"] as? String) ?? "")),
                           at: when, to: &messages)
                    finish(step: callID, failed: false, at: when, in: &messages)
                case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
                    finish(step: callID, failed: false, at: when, in: &messages)
                default:
                    continue
                }
            }
        }
        return messages
    }

    /// Gemini CLI: `{"messages": [{"type": "user" | "gemini", "content": …, "thoughts": [{"subject", "description"}]}]}`.
    static func gemini(_ data: Data) -> [AgentChatMessage] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["messages"] as? [[String: Any]] else { return [] }
        var messages: [AgentChatMessage] = []
        for (index, message) in list.enumerated() {
            let id = (message["id"] as? String) ?? "gemini-\(index)"
            let content = geminiText(message["content"])
            let when = date(message["timestamp"])
            switch message["type"] as? String {
            case "user":
                guard !content.isEmpty else { continue }
                messages.append(AgentChatMessage(id: id, kind: .user, text: clip(content), date: when))
            case "gemini":
                let thoughts = ((message["thoughts"] as? [[String: Any]]) ?? []).compactMap { thought -> String? in
                    let subject = ((thought["subject"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let description = ((thought["description"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if subject.isEmpty { return description.isEmpty ? nil : description }
                    return description.isEmpty ? "**\(subject)**" : "**\(subject)**\n\(description)"
                }
                append(thinking: thoughts.joined(separator: "\n\n"), id: id, at: when, to: &messages)
                append(reply: content, id: id, at: when, to: &messages)
            default:
                continue
            }
        }
        return messages
    }

    /// Thinking right after thinking joins one bubble. With `allowEmpty`, thinking the agent kept to itself still shows
    /// that it thought (as its own app does), without text.
    private static func append(thinking raw: String, id: String, at date: Date?, to messages: inout [AgentChatMessage],
                               allowEmpty: Bool = false) {
        let thinking = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !thinking.isEmpty || allowEmpty else { return }
        if let last = messages.last, last.isThinking {
            messages[messages.count - 1].touch(date)
            guard !thinking.isEmpty else { return }
            messages[messages.count - 1].text = clip(last.text.isEmpty ? thinking : last.text + "\n\n" + thinking)
        } else {
            messages.append(AgentChatMessage(id: "\(id)-think", kind: .thinking, text: clip(thinking), date: date))
        }
    }

    /// Answer text right after answer text joins one bubble.
    private static func append(reply raw: String, id: String, at date: Date?, to messages: inout [AgentChatMessage]) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let last = messages.last, last.kind == .assistant {
            messages[messages.count - 1].text = clip(last.text + "\n\n" + text)
            messages[messages.count - 1].touch(date)
        } else {
            messages.append(AgentChatMessage(id: id, kind: .assistant, text: clip(text), date: date))
        }
    }

    /// Steps right after steps join one list.
    private static func append(step: AgentToolStep, at date: Date?, to messages: inout [AgentChatMessage]) {
        if let last = messages.last, last.isTools {
            messages[messages.count - 1].steps = Array((last.steps + [step]).suffix(maxSteps))
            messages[messages.count - 1].touch(date)
        } else {
            messages.append(AgentChatMessage(id: "\(step.id)-steps", kind: .tools, text: "", steps: [step], date: date))
        }
    }

    /// Marks the step with this call id done or failed. Results follow their call closely, so only recent lists are searched.
    private static func finish(step callID: String, failed: Bool, at date: Date?, in messages: inout [AgentChatMessage]) {
        for index in messages.indices.reversed().prefix(12) where messages[index].isTools {
            guard let position = messages[index].steps.lastIndex(where: { $0.id == callID }) else { continue }
            messages[index].steps[position].state = failed ? .failed : .done
            messages[index].touch(date)
            return
        }
    }

    /// "2026-10-19T14:03:11.482Z", with or without the fraction, as the agents write it.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return fractionalStamp.date(from: text) ?? plainStamp.date(from: text)
    }

    // ISO8601DateFormatter is thread-safe; one each is enough for every transcript.
    private static let fractionalStamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainStamp = ISO8601DateFormatter()

    /// A long run of steps keeps its newest ones.
    private static let maxSteps = 200

    /// "mcp__github__create_issue" reads as "create_issue"; built-in tools keep their name.
    static func toolName(_ raw: String) -> String {
        guard raw.hasPrefix("mcp__") else { return raw.isEmpty ? "Tool" : raw }
        return raw.components(separatedBy: "__").last.flatMap { $0.isEmpty ? nil : $0 } ?? raw
    }

    /// What a Claude Code step was about, the way the Claude app shows it next to the tool's name.
    static func toolSummary(_ name: String, _ input: [String: Any]) -> String {
        func string(_ key: String) -> String? {
            guard let value = input[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        let fileName = string("file_path").map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? string("notebook_path").map { URL(fileURLWithPath: $0).lastPathComponent }
        let summary: String?
        switch name {
        case "Bash": summary = string("description") ?? string("command")
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit": summary = fileName
        case "Grep", "Glob": summary = string("pattern")
        case "WebFetch": summary = string("url")
        case "WebSearch", "web_search": summary = string("query")
        case "Task", "Agent": summary = string("description")
        case "Skill": summary = string("skill") ?? string("command")
        default:
            summary = ["description", "command", "query", "url", "pattern", "path", "title", "name", "prompt"]
                .lazy.compactMap { string($0) }.first ?? fileName
        }
        return oneLine(summary ?? "")
    }

    private static func codexToolName(_ raw: String) -> String {
        switch raw {
        case "shell", "exec_command", "shell_command", "container.exec": return "Shell"
        case "apply_patch": return "Edit"
        case "update_plan": return "Plan"
        default: return toolName(raw)
        }
    }

    /// Codex: the command it runs (`["bash", "-lc", "…"]` reads as the script), or the first telling argument.
    private static func codexSummary(_ name: String, _ arguments: [String: Any]) -> String {
        if let command = arguments["command"] as? [String] {
            if command.count >= 3, ["bash", "sh", "zsh"].contains(URL(fileURLWithPath: command[0]).lastPathComponent),
               command[1].hasPrefix("-") { return oneLine(command[2]) }
            return oneLine(command.joined(separator: " "))
        }
        for key in ["cmd", "command", "query", "path", "explanation"] {
            if let value = arguments[key] as? String, !value.isEmpty { return oneLine(value) }
        }
        return ""
    }

    /// The first line, shortened: a step reads on one line.
    private static func oneLine(_ text: String) -> String {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? ""
        return line.count > 160 ? String(line.prefix(159)) + "…" : line
    }

    private static func geminiText(_ content: Any?) -> String {
        if let string = content as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// Extracts the user request text from an Antigravity prompt, removing envelope tags and metadata.
    static func cleanAntigravityPrompt(_ raw: String) -> String {
        if let start = raw.range(of: "<USER_REQUEST>", options: .caseInsensitive),
           let end = raw.range(of: "</USER_REQUEST>", options: .caseInsensitive, range: start.upperBound..<raw.endIndex) {
            return raw[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var text = raw
        for tag in ["ADDITIONAL_METADATA", "USER_SETTINGS_CHANGE", "uploaded_files"] {
            while let start = text.range(of: "<\(tag)>", options: .caseInsensitive),
                  let end = text.range(of: "</\(tag)>", options: .caseInsensitive, range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func text(_ content: Any?) -> String {
        if let string = content as? String { return string }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }

    /// Filters to actual user prompts, excluding synthetic commands, output, or interruption notices.
    private static func isTypedPrompt(_ text: String) -> Bool {
        !InjectedPrompt.isInjected(text)
    }

    private static func clip(_ text: String) -> String {
        text.count > maxMessageLength ? String(text.prefix(maxMessageLength - 1)) + "…" : text
    }
}

/// What an agent puts into a conversation as if you typed it: a finished background task (`<task-notification>`), the
/// output of a slash command, reminders, the environment Codex describes. It is not a prompt of yours, so it never
/// becomes a session's title or "last prompt".
enum InjectedPrompt {
    private static let prefixes = [
        "<command-", "<local-command", "<system-reminder", "<bash-", "<user-memory", "<task-notification",
        "<environment_context", "<user_instructions", "<turn_aborted", "Caveat:", "[Request interrupted"
    ]
    /// A whole message wrapped in one tag of the agent's own (with a dash or underscore, which HTML tags do not have):
    /// `<some-tag …>…</some-tag>`.
    private static let wrapped = try? NSRegularExpression(pattern: #"^<([A-Za-z]\w*[-_][\w-]*)\b[^>]*>[\s\S]*</\1>$"#)
    /// A block of an agent's own tag and what is inside it.
    private static let block = try? NSRegularExpression(pattern: #"<([A-Za-z][\w]*[-_][\w-]*)\b[^>]*>[\s\S]*?</\1>"#)
    /// Any tag left over, also one cut off at the end.
    private static let tag = try? NSRegularExpression(pattern: #"</?[A-Za-z][\w:-]*\b[^>]*>?"#)

    static func isInjected(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if prefixes.contains(where: { trimmed.hasPrefix($0) }) { return true }
        return matches(wrapped, trimmed)
    }

    /// The first line with words in it, without the agent's tags and their blocks; empty when nothing of yours is left.
    static func title(_ text: String) -> String {
        var clean = text
        if clean.contains("<") {
            clean = replacing(block, in: clean, with: "\n")
            clean = replacing(tag, in: clean, with: " ")
        }
        for line in clean.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !words.isEmpty { return words }
        }
        return ""
    }

    private static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    private static func replacing(_ regex: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let regex else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text), withTemplate: template)
    }
}
