import Foundation

// The `/` list per agent: only commands the agent really has. Sources:
// - plan, fork, new: Nook's own.
// - compact: context compaction command for Claude and Codex.
// - goal: Codex and Claude.
// - the agent's own: what an ACP agent announces in `available_commands_update` (`offered`).
// Codex's `/feedback` is OpenAI-specific: left out.
enum AgentCommands {
    enum Surface: Sendable { case agent, chat }

    static func commands(for provider: RunProvider, hasProject: Bool, surface: Surface = .agent,
                         offered: [AgentSlashCommand] = []) -> [ComposerCommand] {
        var list: [ComposerCommand] = []
        if provider.capabilities.planMode {
            list.append(ComposerCommand(name: "plan", insertion: "", action: .plan))
        }
        if hasProject {
            list.append(ComposerCommand(name: "fork", insertion: "", action: .fork))
        }
        if surface == .chat {
            list.append(ComposerCommand(name: "new", insertion: "", action: .new))
        }
        if hasProject, hasBuiltInCompactAndGoal(provider) {
            list.append(ComposerCommand(name: "compact", insertion: "/compact", action: .insert))
            list.append(ComposerCommand(name: "goal", insertion: "/goal ", action: .insert))
        }
        // The agent's own commands go to it as the text of a prompt; one with Nook's name stays Nook's.
        if hasProject {
            for command in offered where !list.contains(where: { $0.name == command.name }) {
                list.append(ComposerCommand(name: command.name, insertion: "/" + command.name + (command.takesInput ? " " : ""),
                                            action: .insert, detail: command.detail ?? ""))
            }
        }
        return list
    }

    static func descriptionKey(for command: ComposerCommand) -> String { "composer.command.\(command.name).description" }

    /// Claude Code and Codex always take `/compact` and `/goal`; an ACP agent has the commands it announces.
    static func hasBuiltInCompactAndGoal(_ provider: RunProvider) -> Bool {
        switch provider {
        case .claude, .codex: return true
        case .gemini, .antigravity, .opencode, .cursor, .grok, .acp: return false
        }
    }

    /// Whether the agent compacts its context on `/compact`: built in, or announced by the agent itself.
    static func canCompact(_ provider: RunProvider, offered: [AgentSlashCommand]) -> Bool {
        hasBuiltInCompactAndGoal(provider) || offered.contains { $0.name == "compact" }
    }
}

/// A `/` command an agent offers itself (ACP `available_commands_update`): its name, what it does in the agent's words,
/// and whether it takes text after it.
struct AgentSlashCommand: Equatable, Hashable, Sendable {
    var name: String
    var detail: String?
    var takesInput: Bool

    /// The commands of an `availableCommands` list. A name is one word without the slash; anything else is dropped.
    static func acp(_ raw: Any?) -> [AgentSlashCommand] {
        var seen = Set<String>()
        return ((raw as? [[String: Any]]) ?? []).compactMap { entry -> AgentSlashCommand? in
            guard var name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
            if name.hasPrefix("/") { name.removeFirst() }
            guard !name.isEmpty, name.count <= 64, !name.contains(where: { $0.isWhitespace }), seen.insert(name).inserted else { return nil }
            let detail = (entry["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentSlashCommand(name: name, detail: detail?.isEmpty == false ? String(detail!.prefix(200)) : nil,
                                     takesInput: entry["input"] is [String: Any])
        }
    }
}
