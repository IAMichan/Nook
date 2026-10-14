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

    static func recent(path: String, limit: Int = 10) -> [AgentChatMessage] {
        guard path.hasSuffix(".jsonl"), let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > tailBytes ? size - tailBytes : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd() else { return [] }
        // If reading started mid-line, skip the initial partial line.
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data = data[data.index(after: newline)...] }

        var messages: [AgentChatMessage] = []
        for (index, line) in data.split(separator: 0x0A).enumerated() {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = object["type"] as? String, type == "user" || type == "assistant",
                  (object["isMeta"] as? Bool) != true, (object["isSidechain"] as? Bool) != true,
                  let message = object["message"] as? [String: Any] else { continue }
            let text = text(message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let id = (object["uuid"] as? String) ?? "\(index)"

            if type == "user" {
                guard isTypedPrompt(text) else { continue }
                messages.append(AgentChatMessage(id: id, fromUser: true, text: clip(text)))
            } else if let last = messages.last, !last.fromUser {
                // Merge consecutive text chunks of an assistant turn across tool invocations.
                messages[messages.count - 1] = AgentChatMessage(id: last.id, fromUser: false, text: clip(last.text + "\n\n" + text))
            } else {
                messages.append(AgentChatMessage(id: id, fromUser: false, text: clip(text)))
            }
        }
        return Array(messages.suffix(limit))
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
