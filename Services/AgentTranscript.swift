import Foundation

/// A single message from an active session's conversation.
struct AgentChatMessage: Identifiable, Equatable {
    let id: String
    let fromUser: Bool
    let text: String
}

/// Reads the tail of a Claude Code JSONL transcript and returns recent messages:
/// user prompts and agent responses. Tool invocations and system prompts are excluded.
enum AgentTranscript {
    /// Number of bytes to read from file tail; sufficient for recent turns.
    private static let tailBytes: UInt64 = 600_000
    private static let maxMessageLength = 6_000

    private struct CacheEntry {
        let size: UInt64
        let modified: Date
        let limit: Int
        let messages: [AgentChatMessage]
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: CacheEntry] = [:]

    static func recent(path: String, limit: Int = 10) -> [AgentChatMessage] {
        guard path.hasSuffix(".jsonl") else { return [] }
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

        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > tailBytes ? size - tailBytes : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd() else { return [] }
        // If reading started mid-line, skip the initial partial line.
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data = data[data.index(after: newline)...] }

        var messages: [AgentChatMessage] = []
        for (index, line) in data.split(separator: 0x0A).enumerated() {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            let id = (object["uuid"] as? String) ?? (object["id"] as? String) ?? "\(object["step_index"] ?? index)"
            let type = (object["type"] as? String) ?? ""

            // Claude Code
            if type == "user" || type == "assistant" {
                guard (object["isMeta"] as? Bool) != true, (object["isSidechain"] as? Bool) != true,
                      let message = object["message"] as? [String: Any] else { continue }
                let text = text(message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                if type == "user" {
                    guard isTypedPrompt(text) else { continue }
                    messages.append(AgentChatMessage(id: id, fromUser: true, text: clip(text)))
                } else if let last = messages.last, !last.fromUser {
                    messages[messages.count - 1] = AgentChatMessage(id: last.id, fromUser: false, text: clip(last.text + "\n\n" + text))
                } else {
                    messages.append(AgentChatMessage(id: id, fromUser: false, text: clip(text)))
                }
            }
            // Antigravity (USER_INPUT, PLANNER_RESPONSE)
            else if type == "USER_INPUT" {
                guard let raw = object["content"] as? String else { continue }
                let text = cleanAntigravityPrompt(raw)
                guard !text.isEmpty else { continue }
                messages.append(AgentChatMessage(id: id, fromUser: true, text: clip(text)))
            } else if type == "PLANNER_RESPONSE" {
                guard let content = object["content"] as? String else { continue }
                let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if let last = messages.last, !last.fromUser {
                    messages[messages.count - 1] = AgentChatMessage(id: last.id, fromUser: false, text: clip(last.text + "\n\n" + text))
                } else {
                    messages.append(AgentChatMessage(id: id, fromUser: false, text: clip(text)))
                }
            }
            // Codex (event_msg)
            else if type == "event_msg", let payload = object["payload"] as? [String: Any],
                    let ptype = payload["type"] as? String {
                let text = ((payload["message"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if ptype == "user_message" {
                    messages.append(AgentChatMessage(id: id, fromUser: true, text: clip(text)))
                } else if ptype == "agent_message" {
                    if let last = messages.last, !last.fromUser {
                        messages[messages.count - 1] = AgentChatMessage(id: last.id, fromUser: false, text: clip(last.text + "\n\n" + text))
                    } else {
                        messages.append(AgentChatMessage(id: id, fromUser: false, text: clip(text)))
                    }
                }
            }
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
        for prefix in ["<command-", "<local-command", "<system-reminder", "<bash-", "<user-memory", "Caveat:", "[Request interrupted"]
        where text.hasPrefix(prefix) { return false }
        return true
    }

    private static func clip(_ text: String) -> String {
        text.count > maxMessageLength ? String(text.prefix(maxMessageLength - 1)) + "…" : text
    }
}
