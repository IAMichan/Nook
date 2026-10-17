import Foundation

/// A single message from an active session's conversation.
struct AgentChatMessage: Identifiable, Equatable {
    enum Kind: Equatable {
        case user
        case assistant
        case thinking
    }

    let id: String
    let kind: Kind
    let text: String

    var fromUser: Bool { kind == .user }
    var isThinking: Bool { kind == .thinking }

    init(id: String, fromUser: Bool, text: String) {
        self.id = id
        self.kind = fromUser ? .user : .assistant
        self.text = text
    }

    init(id: String, kind: Kind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

/// Reads a session's conversation from the agent's own transcript: user prompts, agent responses, and thinking/reasoning
/// blocks. Tool invocations and system prompts are excluded. Understands Claude Code, Codex and Antigravity (JSONL) and
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
        if isGemini {
            guard let data = FileManager.default.contents(atPath: path) else { return [] }
            size = UInt64(data.count)
            messages = gemini(data)
        } else {
            guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
            defer { try? handle.close() }
            guard let end = try? handle.seekToEnd() else { return [] }
            size = end
            let start = end > tailBytes ? end - tailBytes : 0
            try? handle.seek(toOffset: start)
            guard var data = try? handle.readToEnd() else { return [] }
            // If reading started mid-line, skip the initial partial line.
            if start > 0, let newline = data.firstIndex(of: 0x0A) { data = data[data.index(after: newline)...] }
            messages = jsonl(data)
        }
        let result = Array(messages.suffix(limit))
        if let attrMod {
            cacheLock.lock()
            if cache.count > 64 { cache.removeAll(keepingCapacity: true) }
            cache[path] = CacheEntry(size: attrSize ?? size, modified: attrMod, limit: limit, messages: result)
            cacheLock.unlock()
        }
        return result
    }

    /// Claude Code, Antigravity and Codex: one JSON object per line.
    static func jsonl(_ data: Data) -> [AgentChatMessage] {
        var messages: [AgentChatMessage] = []
        for (index, line) in data.split(separator: 0x0A).enumerated() {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            let id = (object["uuid"] as? String) ?? (object["id"] as? String) ?? "\(object["step_index"] ?? index)"
            let type = (object["type"] as? String) ?? ""

            // Claude Code
            if type == "user" || type == "assistant" {
                guard (object["isMeta"] as? Bool) != true, (object["isSidechain"] as? Bool) != true,
                      let message = object["message"] as? [String: Any] else { continue }

                if type == "user" {
                    let text = text(message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, isTypedPrompt(text) else { continue }
                    messages.append(AgentChatMessage(id: id, kind: .user, text: clip(text)))
                } else {
                    append(thinking: thinkingText(message["content"]), id: id, to: &messages)
                    append(reply: text(message["content"]), id: id, to: &messages)
                }
            }
            // Antigravity (USER_INPUT, PLANNER_RESPONSE)
            else if type == "USER_INPUT" {
                guard let raw = object["content"] as? String else { continue }
                let text = cleanAntigravityPrompt(raw)
                guard !text.isEmpty else { continue }
                messages.append(AgentChatMessage(id: id, kind: .user, text: clip(text)))
            } else if type == "PLANNER_RESPONSE" {
                append(thinking: (object["thinking"] as? String) ?? "", id: id, to: &messages)
                append(reply: (object["content"] as? String) ?? "", id: id, to: &messages)
            }
            // Codex (event_msg): prompts, answers and the reasoning summaries it shows while it thinks.
            else if type == "event_msg", let payload = object["payload"] as? [String: Any],
                    let ptype = payload["type"] as? String {
                switch ptype {
                case "user_message":
                    let text = ((payload["message"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    messages.append(AgentChatMessage(id: id, kind: .user, text: clip(text)))
                case "agent_message":
                    append(reply: (payload["message"] as? String) ?? "", id: id, to: &messages)
                case "agent_reasoning":
                    append(thinking: (payload["text"] as? String) ?? "", id: id, to: &messages)
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
            switch message["type"] as? String {
            case "user":
                guard !content.isEmpty else { continue }
                messages.append(AgentChatMessage(id: id, kind: .user, text: clip(content)))
            case "gemini":
                let thoughts = ((message["thoughts"] as? [[String: Any]]) ?? []).compactMap { thought -> String? in
                    let subject = ((thought["subject"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let description = ((thought["description"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if subject.isEmpty { return description.isEmpty ? nil : description }
                    return description.isEmpty ? "**\(subject)**" : "**\(subject)**\n\(description)"
                }
                append(thinking: thoughts.joined(separator: "\n\n"), id: id, to: &messages)
                append(reply: content, id: id, to: &messages)
            default:
                continue
            }
        }
        return messages
    }

    /// Thinking right after thinking joins one bubble.
    private static func append(thinking raw: String, id: String, to messages: inout [AgentChatMessage]) {
        let thinking = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !thinking.isEmpty else { return }
        if let last = messages.last, last.isThinking {
            messages[messages.count - 1] = AgentChatMessage(id: last.id, kind: .thinking, text: clip(last.text + "\n\n" + thinking))
        } else {
            messages.append(AgentChatMessage(id: "\(id)-think", kind: .thinking, text: clip(thinking)))
        }
    }

    /// Answer text right after answer text joins one bubble.
    private static func append(reply raw: String, id: String, to messages: inout [AgentChatMessage]) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let last = messages.last, !last.fromUser && !last.isThinking {
            messages[messages.count - 1] = AgentChatMessage(id: last.id, kind: .assistant, text: clip(last.text + "\n\n" + text))
        } else {
            messages.append(AgentChatMessage(id: id, kind: .assistant, text: clip(text)))
        }
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

    private static func thinkingText(_ content: Any?) -> String {
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["type"] as? String == "thinking" ? $0["thinking"] as? String : nil }.joined(separator: "\n")
    }

    /// Filters to actual user prompts, excluding synthetic commands, output, or interruption notices.
    private static func isTypedPrompt(_ text: String) -> Bool {
        for prefix in ["<command-", "<local-command", "<system-reminder", "<bash-", "<user-memory", "Caveat:", "[Request interrupted"]
        where text.hasPrefix(prefix) { return false }
        return true
    }

    private static func clip(_ text: String) -> String {
        text.count > maxMessageLength ? String(text.prefix(maxMessageLength - 1)) + "…" : text
    }
}
