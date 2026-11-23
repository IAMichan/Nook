import Foundation

// The `/` list per agent: only commands the agent really has. Sources:
// - plan, fork, clear, new, btw, side: Nook's own (btw and side open a side chat, see `SideChat`).
// - compact: context compaction command for Claude and Codex.
// - goal: Codex and Claude.
// - mcp: Nook lists the agent's MCP servers itself for the agents that report them (`WorkspaceManager.showMcpStatus`).
// - status, help, model, effort, permissions, resume, rename, diff, memory, login, init, review: Nook's own for every
//   agent (`NookCommand`).
// - the agent's own (`offered`): what an ACP agent announces in `available_commands_update`, OpenCode's `/api/command`,
//   and Claude Code's `initialize` reply (its built-in commands, your skills and the project's commands).
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
        // Every agent: Nook forgets its conversation and the next message starts a new one (see `clearConversation`).
        if hasProject, surface == .agent {
            list.append(ComposerCommand(name: "clear", insertion: "", action: .clear))
        }
        // A side chat beside the session (`SideChat`): the question typed after it goes to a session of its own.
        if hasProject, surface == .agent {
            for name in SideChat.commands {
                list.append(ComposerCommand(name: name, insertion: "/" + name + " ", action: .insert))
            }
        }
        if surface == .chat {
            list.append(ComposerCommand(name: "new", insertion: "", action: .new))
        }
        if hasProject, hasBuiltInCompact(provider) {
            list.append(ComposerCommand(name: "compact", insertion: "/compact", action: .insert))
        }
        if hasProject, hasBuiltInGoal(provider) {
            list.append(ComposerCommand(name: "goal", insertion: "/goal ", action: .insert))
        }
        if hasProject, surface == .agent, reportsMcpStatus(provider) {
            list.append(ComposerCommand(name: "mcp", insertion: "", action: .mcp))
        }
        // Nook's own for every agent (`NookCommand`): what an agent's terminal app does on its own screen. `/init`,
        // `/review` and `/memory` only where the agent has no command of that name itself.
        if hasProject, surface == .agent {
            for command in NookCommand.allCases where !list.contains(where: { $0.name == command.name }) {
                if command.yieldsToAgent, offered.contains(where: { $0.name == command.name }) { continue }
                let insertion = "/" + command.name + (command.takesInput ? " " : "")
                let action: ComposerCommand.Action = command.isPrompt || command == .rename ? .insert : .session(command)
                list.append(ComposerCommand(name: command.name, insertion: insertion, action: action))
            }
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

    /// The `/` list of a session that has not started yet: Plan mode where the agent has it, and the agent's own commands
    /// and skills as it last offered them (`AgentCommandMemory`), which go to it as the start of the first prompt. Nook's
    /// session commands (`/fork`, `/status` …) need a running session and stay out.
    static func startCommands(for provider: RunProvider, offered: [AgentSlashCommand]) -> [ComposerCommand] {
        var list: [ComposerCommand] = []
        if provider.capabilities.planMode {
            list.append(ComposerCommand(name: "plan", insertion: "", action: .plan))
        }
        for command in offered where !list.contains(where: { $0.name == command.name }) {
            list.append(ComposerCommand(name: command.name, insertion: "/" + command.name + (command.takesInput ? " " : ""),
                                        action: .insert, detail: command.detail ?? ""))
        }
        return list
    }

    static func descriptionKey(for command: ComposerCommand) -> String { "composer.command.\(command.name).description" }

    /// Whether Nook can ask the agent for its MCP servers (`WorkspaceManager.showMcpStatus`): Claude Code's `mcp_status`,
    /// Codex's `mcpServerStatus/list`, OpenCode's `/api/mcp`. The others do not report them.
    static func reportsMcpStatus(_ provider: RunProvider) -> Bool {
        switch provider {
        case .claude, .codex, .opencode: return true
        case .gemini, .antigravity, .cursor, .grok, .pi, .acp: return false
        }
    }

    /// Claude Code and Codex always take `/compact` and `/goal`; an ACP agent has the commands it announces.
    static func hasBuiltInGoal(_ provider: RunProvider) -> Bool {
        switch provider {
        case .claude, .codex: return true
        case .gemini, .antigravity, .opencode, .cursor, .grok, .pi, .acp: return false
        }
    }

    /// Pi compacts through its own `compact` command, which Nook sends for `/compact` (`PiRPC.turnInput`).
    static func hasBuiltInCompact(_ provider: RunProvider) -> Bool {
        switch provider {
        case .claude, .codex, .pi: return true
        case .gemini, .antigravity, .opencode, .cursor, .grok, .acp: return false
        }
    }

    /// Whether the agent compacts its context on `/compact`: built in, or announced by the agent itself.
    static func canCompact(_ provider: RunProvider, offered: [AgentSlashCommand]) -> Bool {
        hasBuiltInCompact(provider) || offered.contains { $0.name == "compact" }
    }
}

/// A `/` command an agent offers itself (ACP `available_commands_update`): its name, what it does in the agent's words,
/// and whether it takes text after it.
struct AgentSlashCommand: Equatable, Hashable, Sendable, Codable {
    var name: String
    var detail: String?
    var takesInput: Bool

    /// Claude Code's own commands that Nook leaves out: the model, effort and speed are Nook's pickers (the agent would
    /// change them behind the session's back), and `focus` and `color` only change Claude Code's own terminal screen
    /// (headless it answers that focus "isn't available here yet").
    static let claudeLeftOut: Set<String> = ["model", "effort", "fast", "focus", "color"]

    /// The `commands` of Claude Code's `initialize` reply. Internal ones (`__name`) and removed ones are dropped.
    static func claude(_ raw: Any?) -> [AgentSlashCommand] {
        var seen = Set<String>()
        return ((raw as? [[String: Any]]) ?? []).compactMap { entry -> AgentSlashCommand? in
            guard var name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
            if name.hasPrefix("/") { name.removeFirst() }
            let detail = (entry["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.hasPrefix("_"), name.count <= 64, !name.contains(where: { $0.isWhitespace }),
                  !claudeLeftOut.contains(name), detail?.hasPrefix("(removed)") != true, seen.insert(name).inserted else { return nil }
            let hint = (entry["argumentHint"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            return AgentSlashCommand(name: name, detail: detail?.isEmpty == false ? String(detail!.prefix(200)) : nil,
                                     takesInput: !hint.isEmpty)
        }
    }

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

/// The `/` commands each agent last offered, kept across launches: a session that has not started has no agent process
/// to ask yet, so its box lists these (`AgentCommands.startCommands`). One list per agent: the most recent wins.
enum AgentCommandMemory {
    static func key(_ provider: RunProvider) -> String { "agentCommands." + provider.rawValue }

    static func remember(_ commands: [AgentSlashCommand], for provider: RunProvider, defaults: UserDefaults = .standard) {
        guard !commands.isEmpty, recalled(for: provider, defaults: defaults) != commands,
              let data = try? JSONEncoder().encode(commands) else { return }
        defaults.set(data, forKey: key(provider))
    }

    static func recalled(for provider: RunProvider, defaults: UserDefaults = .standard) -> [AgentSlashCommand] {
        guard let data = defaults.data(forKey: key(provider)) else { return [] }
        return (try? JSONDecoder().decode([AgentSlashCommand].self, from: data)) ?? []
    }
}
