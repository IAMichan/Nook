import Foundation

/// The one table of every coding agent's tool names: Claude Code, Codex, Gemini CLI, Antigravity, OpenCode, Cursor,
/// Copilot, Pi, Grok and the ACP agents (by the names `AcpToolCall.toolName` gives their kinds). Every place that asks
/// "is this a command, an edit, a subagent?" or "what do we call this step?" reads it here, case-insensitively, so a
/// tool one agent spells differently never falls through in one view and not in another.
struct CanonicalTool: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Runs a shell command.
        case shell
        /// Watches or stops a command that runs in the background (Claude Code's BashOutput, KillShell).
        case shellControl
        /// Changes part of a file.
        case edit
        /// Writes a whole file.
        case write
        case delete
        /// A patch over one or more files (Codex's `apply_patch`).
        case patch
        case read
        /// Lists a folder.
        case list
        /// Searches files by name or content.
        case search
        case webSearch
        case webFetch
        /// Starts a subagent.
        case subagent
        /// Sets the task list (Claude Code's TodoWrite, Codex's update_plan, Gemini CLI's write_todos).
        case tasks
        /// Proposes a plan to approve (Claude Code's ExitPlanMode).
        case plan
        case skill
        case other
    }

    let kind: Kind
    /// The name a step shows under: Claude Code's own names, which the other agents' tools map onto ("Shell" for a
    /// command of any agent but Claude Code, whose own tool keeps "Bash").
    let name: String

    /// What the timeline counts it as.
    var category: ToolCategory {
        switch kind {
        case .shell, .shellControl: return .command
        case .edit, .write, .delete, .patch: return .edit
        case .read, .list: return .read
        case .search, .webSearch, .webFetch: return .search
        case .subagent, .tasks, .plan, .skill, .other: return .other
        }
    }

    /// The call changes files.
    var changesFiles: Bool { category == .edit }

    /// The name subagents of agents that pass no own name are shown under (ACP: `AcpToolCall.toolName`).
    static let subagentName = "Agent"

    static func of(_ raw: String) -> CanonicalTool {
        let lower = raw.lowercased()
        if raw.hasPrefix(BridgeTool.toolPrefix) {
            return CanonicalTool(kind: BridgeTool.named(raw) == .terminalRun ? .shell : .other, name: raw)
        }
        guard let entry = table[lower] else { return CanonicalTool(kind: .other, name: raw.isEmpty ? "Tool" : raw) }
        // Claude Code's own command tool keeps its name; every other agent's command reads "Shell".
        if entry.kind == .shell, raw == "Bash" { return CanonicalTool(kind: .shell, name: raw) }
        return CanonicalTool(kind: entry.kind, name: entry.name ?? raw)
    }

    static func kind(_ raw: String) -> Kind { of(raw).kind }

    /// The tool starts a subagent (Claude Code's Task and Agent, OpenCode's task, an ACP agent's call Nook named "Agent").
    static func isSubagent(_ raw: String) -> Bool { kind(raw) == .subagent }

    /// Every agent's spelling, lowercased, with its kind and the name its step shows (nil: its own).
    private static let table: [String: (kind: Kind, name: String?)] = {
        var table: [String: (kind: Kind, name: String?)] = [:]
        func add(_ kind: Kind, _ name: String?, _ aliases: [String]) {
            for alias in aliases { table[alias] = (kind, name) }
        }
        add(.shell, "Shell", [
            "bash", "shell", "shell_command", "exec_command", "container.exec", "local_shell", "local_shell_call",
            "run_shell_command", "powershell", "run_command", "run_in_terminal", "run_terminal_cmd", "terminal",
            "nook terminal"
        ])
        add(.shellControl, nil, ["killshell", "bashoutput", "kill_shell", "bash_output"])
        add(.edit, "Edit", [
            "edit", "replace", "str_replace", "str_replace_editor", "str_replace_based_edit_tool", "strreplace",
            "search_replace", "edit_file", "insert"
        ])
        add(.edit, "MultiEdit", ["multiedit"])
        add(.edit, "NotebookEdit", ["notebookedit"])
        add(.write, "Write", ["write", "write_file", "create", "create_file"])
        add(.delete, "Delete", ["delete", "delete_file"])
        add(.patch, "Edit", ["apply_patch", "patch"])
        add(.read, "Read", ["read", "read_file", "read_many_files", "view_file", "view"])
        add(.read, "NotebookRead", ["notebookread"])
        // Codex looks at a picture with view_image (`imageView` in its app server); the step keeps that name.
        add(.read, nil, ["view_image"])
        add(.list, "LS", ["ls", "list_directory", "list", "list_dir"])
        add(.search, "Grep", ["grep", "search_file_content", "grep_search", "codebase_search", "codesearch", "search"])
        add(.search, "Glob", ["glob", "find_by_name", "file_search"])
        add(.webSearch, "WebSearch", ["websearch", "web_search", "google_web_search"])
        add(.webFetch, "WebFetch", ["webfetch", "web_fetch", "fetch", "fetch_url", "url", "read_url_content"])
        add(.subagent, "Task", ["task"])
        add(.subagent, "Agent", ["agent"])
        add(.tasks, "TodoWrite", ["todowrite", "todo_write", "write_todos"])
        add(.tasks, "Plan", ["update_plan", "plan"])
        add(.plan, "ExitPlanMode", ["exitplanmode"])
        add(.skill, "Skill", ["skill"])
        return table
    }()
}

/// What a tool's input names, under the keys every agent uses.
enum ToolInput {
    /// The keys a file path comes under, most specific first: Claude Code's `file_path` and `notebook_path`, Gemini CLI's
    /// `absolute_path`, Codex's and OpenCode's `path`, Cursor's `target_file`, and the camel-case spellings.
    static let pathKeys = ["file_path", "notebook_path", "absolute_path", "path", "filePath", "target_file", "abs_path", "file"]

    /// The one file a call is about, if it names one.
    static func path(_ input: [String: Any]) -> String? {
        for key in pathKeys {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// The command a call runs, also when the agent passes it as an argument list (Codex: `["bash", "-lc", "npm test"]`
    /// reads as the script) or under `cmd`.
    static func command(_ input: [String: Any]) -> String? {
        if let text = input["command"] as? String { return text }
        if let parts = input["command"] as? [String], !parts.isEmpty {
            if parts.count >= 3, ["bash", "sh", "zsh"].contains((parts[0] as NSString).lastPathComponent),
               parts[1].hasPrefix("-") {
                return parts[2...].joined(separator: " ")
            }
            return parts.joined(separator: " ")
        }
        if let text = input["cmd"] as? String, !text.isEmpty { return text }
        return nil
    }

    /// What one step was about, in a few words: the command (or what it says it does), the file, the pattern, the
    /// address, the subagent's task. One answer for every agent and view (`ToolSummary.describe`, the approval line,
    /// a transcript's steps). `describedCommand`: a command's own description comes before the command line.
    static func subject(tool: String, input: [String: Any], describedCommand: Bool = false) -> String {
        func string(_ key: String) -> String? {
            guard let value = input[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        let canonical = CanonicalTool.of(tool)
        let fileName = path(input).map { ($0 as NSString).lastPathComponent }
        let found: String?
        switch canonical.kind {
        case .shell:
            found = describedCommand ? (string("description") ?? command(input)) : (command(input) ?? string("description"))
        case .edit, .write, .delete, .read:
            if let fileName { found = fileName } else if let paths = input["paths"] as? [String], let first = paths.first {
                found = paths.count == 1 ? first : "\(first) +\(paths.count - 1)"
            } else {
                found = nil
            }
        case .patch:
            let patch = (input["input"] as? String) ?? (input["patch"] as? String) ?? ""
            let files = SessionProjects.patchFiles(patch).map { ($0 as NSString).lastPathComponent }
            found = files.isEmpty ? fileName : (files.count == 1 ? files[0] : "\(files[0]) +\(files.count - 1)")
        case .list:
            found = path(input) ?? string("dir_path") ?? string("directory")
        case .search:
            found = string("pattern") ?? string("query")
        case .webSearch:
            found = string("query")
        case .webFetch:
            found = string("url") ?? string("prompt")
        case .subagent:
            found = string("description") ?? string("prompt")
        case .skill:
            found = string("skill") ?? string("command")
        case .tasks, .plan, .shellControl, .other:
            found = nil
        }
        if let found { return found }
        return ["description", "command", "cmd", "query", "url", "pattern", "path", "title", "name", "prompt", "explanation"]
            .lazy.compactMap { string($0) }.first ?? command(input) ?? fileName ?? ""
    }
}
