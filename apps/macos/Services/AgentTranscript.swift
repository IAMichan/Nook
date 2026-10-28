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
    /// The file a step read, wrote or edited, as the agent named it: what clicking the step opens in the side panel.
    var file: String? = nil
    /// Why a failed step failed, on one line, as the tool reported it.
    var error: String? = nil
    /// What an edit changed, as a unified diff made from the tool's input (see EditPatch), for the turn's diff.
    var patch: String? = nil
    /// What a command, search or other tool gave back, shortened: what the step shows when you open it. Nil for a step
    /// that read or changed a file (the file itself is a click away) and for one without a result yet.
    var output: String? = nil
}

/// Something that happened to the conversation rather than in it: the context was compacted, or the agent's run hit an
/// error or a usage limit. It stays in sight between the agent's work, also when a finished turn folds.
enum AgentNotice: Equatable {
    /// `tokens`: how many the context held before, when the agent says.
    case compacted(tokens: Int?)
    /// An error the agent's run reported (an API error), in its own words.
    case error(String)
    /// A usage limit stopped the agent; `resets`: when it can go on, when the agent says.
    case limit(String, resets: Date?)
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
        /// A compaction, an error or a usage limit (see `notice`).
        case notice
    }

    let id: String
    let kind: Kind
    var text: String
    var steps: [AgentToolStep] = []
    /// When it was written, and when the last part of it (a later block, a step's result) came in: what the turn took.
    var date: Date?
    var updated: Date?
    /// You stopped the agent right after this message: its turn ended without the agent finishing it.
    var interrupted = false
    /// Your message, sent while the agent was still working on the one before (it steered the turn).
    var queued = false
    /// What a `.notice` message stands for.
    var notice: AgentNotice? = nil

    var fromUser: Bool { kind == .user }
    var isThinking: Bool { kind == .thinking }
    var isTools: Bool { kind == .tools }
    var isNotice: Bool { kind == .notice }

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

    init(id: String, notice: AgentNotice, date: Date? = nil) {
        self.init(id: id, kind: .notice, text: "", date: date)
        self.notice = notice
        if case .error(let text) = notice { self.text = text }
        if case .limit(let text, _) = notice { self.text = text }
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
        var result = Array(messages.suffix(limit))
        // A long conversation is read from its tail (and capped): the prompt that started it is still part of it.
        if !isGemini, size > tailBytes || messages.count > limit, result.first?.kind != .user || messages.count > limit,
           let first = firstPrompt(path: path), !result.contains(where: { $0.id == first.id }) {
            result.insert(first, at: 0)
        }
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

    /// The first thing you typed in a JSONL transcript, read from its head (the tail read of a long file starts after it).
    private static func firstPrompt(path: String) -> AgentChatMessage? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard var data = try? handle.read(upToCount: 1_000_000), !data.isEmpty else { return nil }
        if let cut = data.lastIndex(of: 0x0A) { data = data[data.startIndex...cut] }
        return jsonl(data).first { $0.kind == .user }
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
                      // The summary written when the context was compacted is not something you typed.
                      (object["isCompactSummary"] as? Bool) != true,
                      let message = object["message"] as? [String: Any] else { continue }

                if type == "user" {
                    // Results of the agent's steps come back as user lines: they only mark a step done or failed.
                    for block in (message["content"] as? [[String: Any]]) ?? [] where block["type"] as? String == "tool_result" {
                        guard let callID = block["tool_use_id"] as? String else { continue }
                        let failed = (block["is_error"] as? Bool) == true
                        let result = Self.text(block["content"])
                        finish(step: callID, failed: failed, error: failed ? errorLine(result) : nil, output: result,
                               at: when, in: &messages)
                    }
                    let text = typedText(message["content"])
                    if isInterruption(text), !messages.isEmpty {
                        messages[messages.count - 1].interrupted = true
                        continue
                    }
                    guard !text.isEmpty, isTypedPrompt(text) else { continue }
                    messages.append(AgentChatMessage(id: id, kind: .user, text: clip(text), date: when))
                } else if (object["isApiErrorMessage"] as? Bool) == true {
                    // An API error Claude Code wrote in the place of an answer: an error, not something the agent said.
                    let text = text(message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    messages.append(AgentChatMessage(id: id, notice: notice(error: text), date: when))
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
                                                       lines: EditLines.of(tool: name, input: input),
                                                       file: opensFile(name) ? ToolSummary.path(input) : nil,
                                                       patch: EditPatch.make(tool: name, input: input)),
                                   at: when, to: &messages)
                        default:
                            continue
                        }
                    }
                    if let content = message["content"] as? String { append(reply: content, id: id, at: when, to: &messages) }
                }
            }
            // Claude Code: the context was compacted, by hand (/compact) or because it was full.
            else if type == "system" {
                guard object["subtype"] as? String == "compact_boundary", (object["isSidechain"] as? Bool) != true else { continue }
                let tokens = ((object["compactMetadata"] as? [String: Any])?["preTokens"] as? NSNumber)?.intValue
                append(compaction: tokens, id: id, at: when, to: &messages)
            }
            // Claude Code: a message you sent while the agent was working (in the CLI, the desktop app or Nook). It is
            // written as a queued command, never as a user line; task notifications and messages from other agents
            // use the same shape and are left out.
            else if type == "attachment" {
                guard let text = queuedPrompt(object) else { continue }
                var message = AgentChatMessage(id: id, kind: .user, text: clip(text), date: when)
                message.queued = true
                messages.append(message)
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
                    // Without an `<environment_context>` or other block of Codex's own in front, as in `AgentHistory`.
                    guard let text = InjectedPrompt.prompt((payload["message"] as? String) ?? "") else { continue }
                    messages.append(AgentChatMessage(id: id, kind: .user, text: clip(text), date: when))
                case "agent_message":
                    append(reply: (payload["message"] as? String) ?? "", id: id, at: when, to: &messages)
                case "agent_reasoning":
                    append(thinking: (payload["text"] as? String) ?? "", id: id, at: when, to: &messages)
                case "turn_aborted":
                    if !messages.isEmpty { messages[messages.count - 1].interrupted = true }
                case "context_compacted":
                    append(compaction: nil, id: id, at: when, to: &messages)
                case "error":
                    let text = ((payload["message"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    messages.append(AgentChatMessage(id: id, notice: notice(error: text), date: when))
                default:
                    continue
                }
            }
            // Codex: the context was compacted (older versions only write this line, newer ones an event as well).
            else if type == "compacted" {
                append(compaction: nil, id: id, at: when, to: &messages)
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
                                                   : nil,
                                               patch: name == "apply_patch"
                                                   ? (payload["input"] as? String) ?? EditPatch.make(tool: name, input: arguments)
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
                    let code = codexExitCode(payload["output"])
                    finish(step: callID, failed: (code ?? 0) != 0, output: codexOutput(payload["output"]), at: when, in: &messages)
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
                // The tools it called after writing, each with how it went: the same steps Claude Code and Codex show.
                for (callIndex, call) in ((message["toolCalls"] as? [[String: Any]]) ?? []).enumerated() {
                    let callID = (call["id"] as? String) ?? "\(id)-call-\(callIndex)"
                    let raw = (call["name"] as? String) ?? ""
                    let input = (call["args"] as? [String: Any]) ?? [:]
                    let callDate = date(call["timestamp"]) ?? when
                    let path = ToolSummary.path(input)
                    append(step: AgentToolStep(id: callID, name: geminiToolName(raw), summary: geminiSummary(raw, input),
                                               command: ToolSummary.command(input),
                                               path: ToolCategory.of(tool: raw) == .edit ? path : nil,
                                               lines: EditLines.of(tool: raw, input: input),
                                               file: opensFile(raw) ? path : nil,
                                               patch: EditPatch.make(tool: raw, input: input)),
                           at: callDate, to: &messages)
                    let display = call["resultDisplay"] as? String
                    switch call["status"] as? String {
                    case "success":
                        finish(step: callID, failed: false, output: display, at: callDate, in: &messages)
                    case "error", "cancelled":
                        finish(step: callID, failed: true, error: display.flatMap(errorLine), output: display, at: callDate, in: &messages)
                    default:
                        continue
                    }
                }
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
    /// `output`: what the tool gave back, kept (shortened) for a step that does not stand for a file.
    private static func finish(step callID: String, failed: Bool, error: String? = nil, output: String? = nil, at date: Date?,
                               in messages: inout [AgentChatMessage]) {
        for index in messages.indices.reversed().prefix(12) where messages[index].isTools {
            guard let position = messages[index].steps.lastIndex(where: { $0.id == callID }) else { continue }
            messages[index].steps[position].state = failed ? .failed : .done
            messages[index].steps[position].error = error
            let category = ToolCategory.of(tool: messages[index].steps[position].name)
            if category != .read && category != .edit { messages[index].steps[position].output = output.flatMap(Self.output) }
            messages[index].touch(date)
            return
        }
    }

    /// A compaction right after another (Codex writes both a line and an event for one) is the same one.
    private static func append(compaction tokens: Int?, id: String, at date: Date?, to messages: inout [AgentChatMessage]) {
        if let last = messages.last, case .compacted(let earlier) = last.notice {
            if earlier == nil, let tokens { messages[messages.count - 1].notice = .compacted(tokens: tokens) }
            return
        }
        messages.append(AgentChatMessage(id: id, notice: .compacted(tokens: tokens), date: date))
    }

    /// An error the agent reported, or the usage limit it ran into: "Claude AI usage limit reached|1760040000" (with when
    /// it resets), "5-hour limit reached ∙ resets 3pm", "You've hit your usage limit".
    static func notice(error text: String) -> AgentNotice {
        let lower = text.lowercased()
        guard lower.contains("limit reached") || lower.contains("hit your") && lower.contains("limit")
                || lower.contains("usage limit") || lower.contains("rate limit") else { return .error(errorLine(text) ?? text) }
        if let bar = text.lastIndex(of: "|"), let seconds = TimeInterval(text[text.index(after: bar)...].trimmingCharacters(in: .whitespaces)) {
            return .limit(String(text[..<bar]).trimmingCharacters(in: .whitespaces), resets: Date(timeIntervalSince1970: seconds))
        }
        return .limit(errorLine(text) ?? text, resets: nil)
    }

    /// What a Codex tool gave back: the `output` of the JSON it wraps it in, or what follows the "Output:" line of the
    /// header newer versions start with.
    static func codexOutput(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        if let data = text.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return object["output"] as? String
        }
        if text.hasPrefix("Exit code:"), let range = text.range(of: "Output:\n") { return String(text[range.upperBound...]) }
        return text
    }

    /// The most a step keeps of what its tool gave back: the start, where a command says what it does, and a note when
    /// there was more. Nil when it gave back nothing.
    private static let maxOutput = 3_000
    static func output(_ raw: String) -> String? {
        let text = raw.replacingOccurrences(of: "<tool_use_error>", with: "").replacingOccurrences(of: "</tool_use_error>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > maxOutput ? String(text.prefix(maxOutput - 1)) + "…" : text
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
    /// A step that read or wrote one file, which you can open from it (a folder listing names a folder, not a file).
    static func opensFile(_ name: String) -> Bool {
        let category = ToolCategory.of(tool: name)
        return (category == .read || category == .edit) && !["ls", "list_directory"].contains(name.lowercased())
    }

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

    /// Gemini CLI's tools by the names the other agents' steps use, so a step reads the same whichever agent ran it.
    private static func geminiToolName(_ raw: String) -> String {
        switch raw {
        case "run_shell_command": return "Shell"
        case "read_file", "read_many_files": return "Read"
        case "write_file": return "Write"
        case "replace": return "Edit"
        case "glob": return "Glob"
        case "search_file_content": return "Grep"
        case "google_web_search": return "WebSearch"
        case "web_fetch": return "WebFetch"
        default: return toolName(raw)
        }
    }

    /// Gemini CLI: what a step was about, from its own argument names.
    private static func geminiSummary(_ raw: String, _ input: [String: Any]) -> String {
        if let path = ToolSummary.path(input), raw != "run_shell_command" { return oneLine(URL(fileURLWithPath: path).lastPathComponent) }
        if let paths = input["paths"] as? [String], let first = paths.first {
            return oneLine(paths.count == 1 ? first : "\(first) +\(paths.count - 1)")
        }
        for key in ["description", "command", "pattern", "query", "url", "prompt"] {
            if let value = input[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return oneLine(value) }
        }
        return ""
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

    /// The exit code a Codex command reported: in the JSON it wraps its output in (`metadata.exit_code`) or on the
    /// "Exit code: 1" line newer versions start their output with. Nil when the output does not say.
    static func codexExitCode(_ output: Any?) -> Int? {
        guard let text = output as? String else { return nil }
        if let data = text.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let metadata = object["metadata"] as? [String: Any] {
            return (metadata["exit_code"] as? NSNumber)?.intValue
        }
        let first = text.prefix(while: { !$0.isNewline })
        guard first.hasPrefix("Exit code:") else { return nil }
        return Int(first.dropFirst("Exit code:".count).trimmingCharacters(in: .whitespaces))
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

    /// What you typed in a user line: the agent's own blocks in front of it (the Claude desktop app opens a chat with
    /// `<system-reminder>` blocks before the prompt) are left out, so the prompt that started the chat still shows.
    /// Your words in a user message: per text block, without the blocks the agent added (also used by `AgentHistory`).
    static func typedText(_ content: Any?) -> String {
        if let blocks = content as? [[String: Any]] {
            // A block that is nothing but the agent's own (a reminder in front of your words) stays whole in `typed`:
            // dropped here, or it would make the whole message look injected.
            let texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .map { InjectedPrompt.typed($0) }.filter { !$0.isEmpty }
            let yours = texts.filter { !InjectedPrompt.isInjected($0) }
            return (yours.isEmpty ? texts : yours).joined(separator: "\n")
        }
        return InjectedPrompt.typed(text(content))
    }

    /// Why a step failed, from the tool's result: its first line with words in it, without Claude Code's
    /// `<tool_use_error>` wrapper. Nil when the result says nothing.
    static func errorLine(_ result: String) -> String? {
        let clean = result.replacingOccurrences(of: "<tool_use_error>", with: "")
            .replacingOccurrences(of: "</tool_use_error>", with: "")
        guard let line = clean.split(whereSeparator: \.isNewline).lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }

    /// Claude Code's note that you stopped it: "[Request interrupted by user]", also "… for tool use".
    static func isInterruption(_ text: String) -> Bool {
        text.hasPrefix("[Request interrupted")
    }

    /// Filters to actual user prompts, excluding synthetic commands, output, or interruption notices.
    /// The words of a message a person sent while the agent worked, from Claude Code's `queued_command` attachment line;
    /// nil for anything else in that shape (task notifications, other agents, sidechains).
    static func queuedPrompt(_ object: [String: Any]) -> String? {
        guard object["type"] as? String == "attachment", (object["isSidechain"] as? Bool) != true,
              (object["isMeta"] as? Bool) != true,
              let attachment = object["attachment"] as? [String: Any],
              attachment["type"] as? String == "queued_command",
              ((attachment["commandMode"] as? String) ?? "prompt") == "prompt" else { return nil }
        if let origin = (attachment["origin"] as? [String: Any])?["kind"] as? String, origin != "human" { return nil }
        if (attachment["humanTurn"] as? Bool) == false { return nil }
        let text = Self.text(attachment["prompt"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isTypedPrompt(text) else { return nil }
        return text
    }

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
        "<environment_context", "<user_instructions", "<turn_aborted", "[Request interrupted",
        // Claude Code's note before the output of local commands; a prompt of yours may start with "Caveat:" too.
        "Caveat: The messages below were generated by the user while running local commands"
    ]
    /// A whole message wrapped in one tag of the agent's own (with a dash or underscore, which HTML tags do not have):
    /// `<some-tag …>…</some-tag>`.
    private static let wrapped = try? NSRegularExpression(pattern: #"^<([A-Za-z]\w*[-_][\w-]*)\b[^>]*>[\s\S]*</\1>$"#)
    /// A block of an agent's own tag and what is inside it.
    private static let block = try? NSRegularExpression(pattern: #"<([A-Za-z][\w]*[-_][\w-]*)\b[^>]*>[\s\S]*?</\1>"#)
    /// Any tag left over, also one cut off at the end.
    private static let tag = try? NSRegularExpression(pattern: #"</?[A-Za-z][\w:-]*\b[^>]*>?"#)

    /// An injected block of the agent's own at the start of a message.
    private static let leading = try? NSRegularExpression(
        pattern: #"^\s*<(system-reminder|environment_context|user_instructions|user-memory|[A-Za-z]\w*-[\w-]*)\b[^>]*>[\s\S]*?</\1>\s*"#)

    /// The message without the injected blocks in front of it; the message itself when it has none or is nothing but
    /// injected text (which `isInjected` then rejects).
    static func typed(_ text: String) -> String {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let leading, let match = leading.firstMatch(in: rest, range: NSRange(rest.startIndex..<rest.endIndex, in: rest)),
              let range = Range(match.range, in: rest) {
            let remainder = String(rest[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remainder.isEmpty else { return rest }
            rest = remainder
        }
        return rest
    }

    /// What you typed in a message, without the blocks the agent put in front of it (the Claude app opens the first
    /// message of a worktree session with a `<system-reminder>`); nil when the whole message is the agent's own.
    static func prompt(_ text: String) -> String? {
        let typed = typed(text)
        guard !typed.isEmpty, !isInjected(typed) else { return nil }
        return typed
    }

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
