import Foundation

/// For agents whose only hook that can allow a tool call runs before *every* call, not only before the ones the agent
/// would ask you about (Copilot CLI's `preToolUse`, whose `allow` skips its prompt since 1.0.18). Such a hook does not
/// say whether the agent would ask, so Nook asks only where an agent asks by default: a shell command that is not
/// clearly harmless, a file it changes, a page it fetches, an MCP tool. Everything else goes on untouched, and so does
/// every call of an agent started to allow everything.
enum PreToolGate {
    /// The agents Nook gates this way. Agents with a hook that fires only when they would ask (`PermissionRequest`:
    /// Claude Code, Codex, Muse Code) are answered there instead.
    static let agents: Set<String> = ["copilot"]

    /// Would the agent ask you before this call, by default?
    static func wouldAsk(tool: String, input: [String: Any]) -> Bool {
        if McpToolName(tool) != nil { return true }
        let canonical = CanonicalTool.of(tool)
        if canonical.kind == .shell {
            guard let command = command(input) else { return true }
            return CommandRisk.assess(command).level != .safe
        }
        return canonical.changesFiles || canonical.kind == .webFetch
    }

    /// What "Always" allows for the rest of the session: a shell command by its program ("git"), any other tool by name.
    static func grant(tool: String, input: [String: Any]) -> String {
        let name = tool.lowercased()
        if CanonicalTool.kind(tool) == .shell, let command = command(input),
           let program = command.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first {
            return "\(name):\(program)"
        }
        return name
    }

    /// Flags that start the agent allowing every tool, so it never asks: Nook does not ask either.
    private static let allowEverything: Set<String> = ["--allow-all-tools", "--allow-all", "--yolo"]

    static func allowsEverything(_ arguments: [String]) -> Bool {
        arguments.contains { allowEverything.contains($0) || $0.hasPrefix("--allow-all-tools=") }
    }

    private static func command(_ input: [String: Any]) -> String? {
        for key in ["command", "cmd", "CommandLine", "script"] {
            if let text = input[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        if let parts = input["command"] as? [String], !parts.isEmpty { return parts.joined(separator: " ") }
        return nil
    }
}
