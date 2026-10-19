import Foundation

// The `/` list per agent: only commands the agent really has. Sources:
// - plan, fork, new: Nook's own (: `/plan` and `/model` are "Code commands" that work on any line).
// - compact: COMPACT_SLASH_COMMAND for Claude and Codex (docs/user/composer.md).
// - goal: Codex and Claude (docs/user/composer.md "Goals"; CodexProvider.ts slashCommands).
// has no `/context` or `/usage` for Claude, so Nook offers none. Codex's `/feedback` is OpenAI-specific: left out.
enum AgentCommands {
    enum Surface: Sendable { case agent, chat }

    static func commands(for provider: RunProvider, hasProject: Bool, surface: Surface = .agent) -> [ComposerCommand] {
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
        if hasProject, provider == .claude || provider == .codex {
            list.append(ComposerCommand(name: "compact", insertion: "/compact", action: .insert))
            list.append(ComposerCommand(name: "goal", insertion: "/goal ", action: .insert))
        }
        return list
    }

    static func descriptionKey(for command: ComposerCommand) -> String { "composer.command.\(command.name).description" }
}
