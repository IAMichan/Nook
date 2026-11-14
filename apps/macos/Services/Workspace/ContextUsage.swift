import Foundation

/// What fills an agent's context window, part by part: the card behind the composer's context ring. Claude Code says it
/// itself (`get_context_usage`, the same breakdown as its `/context`); for an agent that only reports how many tokens
/// the conversation takes, the card shows that, the room kept for summarizing, and what is left (`estimate`).
struct ContextUsage: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// In every request now.
        case used
        /// Known to the agent but only loaded when it asks for it (tool search): not in the window.
        case deferred
        /// Kept free so the agent can summarize before the window is full.
        case buffer
        case free
    }

    struct Category: Equatable, Identifiable, Sendable {
        /// The agent's id (`messages`, `mcp_tools`, …); `ContextUsage.conversation` for an estimate.
        var id: String
        /// The agent's own label, used when Nook has no translation for the id.
        var name: String
        var tokens: Int
        var kind: Kind
    }

    var categories: [Category]
    /// Tokens in the window now.
    var usedTokens: Int
    var window: Int
    /// How many MCP tools, memory files, custom agents and skills there are; nil when the agent does not say.
    var mcpTools: Int?
    var memoryFiles: Int?
    var agents: Int?
    var skills: Int?
    /// False for an estimate: then only the conversation as a whole is known, not its parts.
    var detailed: Bool

    static let conversation = "conversation"

    var fraction: Double { window > 0 ? min(1, Double(usedTokens) / Double(window)) : 0 }

    /// The parts in the window, the buffer and the free space, in the agent's order: the bar and the first list.
    var inWindow: [Category] { categories.filter { $0.kind != .deferred && $0.tokens > 0 } }
    /// The parts the agent knows of but loads only when needed.
    var deferred: [Category] { categories.filter { $0.kind == .deferred && $0.tokens > 0 } }

    /// The category's share of the window, 0…1.
    func share(_ category: Category) -> Double { window > 0 ? Double(category.tokens) / Double(window) : 0 }

    /// Claude Code's answer to `get_context_usage`. Nil when it holds no window.
    static func claude(_ answer: [String: Any]) -> ContextUsage? {
        guard let window = int(answer["maxTokens"]), window > 0 else { return nil }
        let categories = ((answer["categories"] as? [[String: Any]]) ?? []).compactMap { raw -> Category? in
            guard let id = raw["id"] as? String, let tokens = int(raw["tokens"]) else { return nil }
            let kind = (raw["kind"] as? String).flatMap(Kind.init(rawValue:))
                ?? ((raw["isDeferred"] as? Bool) == true ? .deferred : .used)
            return Category(id: id, name: (raw["name"] as? String) ?? id, tokens: tokens, kind: kind)
        }
        let skills = (answer["skills"] as? [String: Any]).flatMap { int($0["includedSkills"]) ?? int($0["totalSkills"]) }
        return ContextUsage(categories: categories,
                            usedTokens: int(answer["totalTokens"]) ?? categories.filter { $0.kind == .used }.reduce(0) { $0 + $1.tokens },
                            window: window,
                            mcpTools: (answer["mcpTools"] as? [Any])?.count,
                            memoryFiles: (answer["memoryFiles"] as? [Any])?.count,
                            agents: (answer["agents"] as? [Any])?.count,
                            skills: skills,
                            detailed: true)
    }

    /// For an agent that reports only how many tokens the conversation takes: that, the room between the auto-compact
    /// point and the end of the window, and the rest.
    static func estimate(used: Int, window: Int, autoCompactAt: Int?) -> ContextUsage {
        let used = max(0, min(used, window))
        let buffer = autoCompactAt.map { max(0, window - max($0, used)) } ?? 0
        return ContextUsage(categories: [
            Category(id: conversation, name: "Conversation", tokens: used, kind: .used),
            Category(id: "autocompact_buffer", name: "Autocompact buffer", tokens: buffer, kind: .buffer),
            Category(id: "free_space", name: "Free space", tokens: max(0, window - used - buffer), kind: .free),
        ], usedTokens: used, window: window, detailed: false)
    }

    private static func int(_ value: Any?) -> Int? { JSONNumber.int(value) }
}
