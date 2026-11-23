import Foundation

/// Nook's own `/` commands, the same for every agent. An agent's terminal app has commands that only work on its own
/// screen (Claude Code headless answers "/status isn't available in this environment"); in Nook each of them does what
/// Nook has for it instead: a picker, a page, a panel, or a line in the session.
///
/// Two of them go to the agent as a prompt: `/init` and `/review`. They stand in only where the agent has no command of
/// that name itself (Claude Code, Gemini CLI and OpenCode have their own); Codex over its app-server reviews through
/// `review/start` (`SessionCommands.codexReviewTarget`).
enum NookCommand: String, CaseIterable, Sendable {
    case status, help, model, effort, permissions, resume, rename, diff, memory, login, review
    case initialize = "init"

    var name: String { rawValue }

    /// The agent's own command of this name wins: Nook's is only a stand-in where the agent has none. The others are
    /// Nook's in every session, because the agent would change what Nook shows behind its back (its model, its access,
    /// the session's name) or has no screen to show it on.
    var yieldsToAgent: Bool {
        switch self {
        case .memory, .review, .initialize: return true
        case .status, .help, .model, .effort, .permissions, .resume, .rename, .diff, .login: return false
        }
    }

    /// It goes to the agent as a prompt (`SessionCommands.prompt`); the others Nook does itself.
    var isPrompt: Bool { self == .review || self == .initialize }

    /// Words may follow it: a new name, or what to review.
    var takesInput: Bool { self == .rename || self == .review }
}

enum SessionCommands {
    /// The timeline event's `tool` for a `/status` report.
    static let statusTool = "status"

    /// A message that is one of Nook's commands Nook does itself (not a prompt), with the words after it. `/rename` takes
    /// a name after it; the others only stand alone, so `/memory add …` still goes to an agent that has its own.
    static func action(in text: String) -> (command: NookCommand, rest: String)? {
        guard let (command, rest) = parse(text), !command.isPrompt else { return nil }
        guard rest.isEmpty || command.takesInput else { return nil }
        return (command, rest)
    }

    /// The prompt that goes to the agent for `/init` or `/review`, where the agent has no such command itself; nil
    /// leaves the message as it is. `nativeReview`: the agent reviews itself (Codex's `review/start`).
    static func prompt(for text: String, provider: RunProvider, offered: [AgentSlashCommand], nativeReview: Bool) -> String? {
        guard let (command, rest) = parse(text), command.isPrompt, !builtIn(provider).contains(command),
              !offered.contains(where: { $0.name == command.name }) else { return nil }
        switch command {
        case .initialize:
            guard rest.isEmpty else { return nil }
            return initPrompt(file: instructionFiles(provider).first ?? "AGENTS.md")
        case .review:
            guard !nativeReview else { return nil }
            return rest.isEmpty ? reviewPrompt : reviewPrompt + "\n\nFocus: " + rest
        default:
            return nil
        }
    }

    /// The prompt commands an agent always has itself, also before it listed its commands (Claude Code lists them once
    /// its first turn started).
    static func builtIn(_ provider: RunProvider) -> Set<NookCommand> {
        switch provider {
        case .claude: return [.initialize, .review]
        case .codex, .gemini, .antigravity, .opencode, .cursor, .grok, .pi, .acp: return []
        }
    }

    /// Codex over its app-server: the `target` of `review/start` for a `/review` message. `/review` alone reviews the
    /// uncommitted changes, `/review base main` the branch against `main`, `/review commit abc123` one commit, and any
    /// other words are the review's own instructions.
    static func codexReviewTarget(_ text: String) -> [String: Any]? {
        guard let (command, rest) = parse(text), command == .review else { return nil }
        guard !rest.isEmpty else { return ["type": "uncommittedChanges"] }
        let words = rest.split(separator: " ", maxSplits: 1).map(String.init)
        if words.count == 2, !words[1].contains(" ") {
            switch words[0].lowercased() {
            case "base", "branch": return ["type": "baseBranch", "branch": words[1]]
            case "commit": return ["type": "commit", "sha": words[1]]
            default: break
            }
        }
        return ["type": "custom", "instructions": rest]
    }

    /// The files each agent reads its project instructions from, the one `/init` writes first.
    static func instructionFiles(_ provider: RunProvider) -> [String] {
        switch provider {
        case .claude: return ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"]
        case .gemini, .antigravity: return ["GEMINI.md", "AGENTS.md"]
        case .cursor: return ["AGENTS.md", ".cursorrules"]
        case .codex, .opencode, .grok, .pi, .acp: return ["AGENTS.md"]
        }
    }

    /// The first instructions file of the agent that exists in `folder`, as a full path.
    static func existingInstructions(_ provider: RunProvider, folder: String,
                                     exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        instructionFiles(provider).map { (folder as NSString).appendingPathComponent($0) }.first(where: exists)
    }

    /// `/status`: the session's agent, model and settings, one label and value per row.
    static func statusRows(_ run: WorkspaceRun) -> [[String]] {
        let model = run.model.isEmpty ? (run.resolvedModel ?? tr("ws.status.defaultModel")) : run.model
        var rows: [[String]] = [
            [tr("ws.status.agent"), run.provider.displayName],
            [tr("ws.status.model"), model],
        ]
        if let effort = run.effort, !effort.isEmpty { rows.append([tr("ws.status.effort"), effort]) }
        rows.append([tr("ws.status.mode"), tr("ws.mode." + run.mode.rawValue)])
        rows.append([tr("ws.status.access"), tr("ws.permission." + run.permission.rawValue)])
        rows.append([tr("ws.status.folder"), tilde(run.workingDirectory)])
        if let branch = run.branch, !branch.isEmpty { rows.append([tr("ws.status.branch"), branch]) }
        if let remote = run.remote { rows.append([tr("ws.status.machine"), remote.name]) }
        if let session = run.providerSessionID, !session.isEmpty { rows.append([tr("ws.status.conversation"), session]) }
        return rows
    }

    static func statusEvent(_ run: WorkspaceRun) -> RunEvent {
        let rows = statusRows(run)
        let detail = (try? JSONEncoder().encode(rows)).flatMap { String(data: $0, encoding: .utf8) }
        let model = rows.first { $0.first == tr("ws.status.model") }?.last ?? ""
        return RunEvent(kind: .system, text: tr("ws.status.summary", run.provider.displayName, model), tool: statusTool, detail: detail)
    }

    static func statusRows(in event: RunEvent) -> [[String]] {
        guard event.tool == statusTool, let data = event.detail?.data(using: .utf8) else { return [] }
        return ((try? JSONDecoder().decode([[String]].self, from: data)) ?? []).filter { $0.count == 2 }
    }

    // MARK: Prompts

    /// Codex's own review request (its `/review` on the uncommitted changes), for the agents without a review command.
    static let reviewPrompt = "Review the current code changes (staged, unstaged, and untracked files) and provide prioritized findings."

    /// Codex's own `/init` prompt, for the agents without one, with the file the agent reads.
    static func initPrompt(file: String) -> String {
        """
        Generate a file named \(file) that serves as a contributor guide for this repository.
        Before writing, check whether \(file) already exists in the current working directory. If it does, do not overwrite or modify it.
        Your goal is to produce a clear, concise, and well-structured document with descriptive headings and actionable explanations for each section.
        Follow the outline below, but adapt as needed — add sections if relevant, and omit those that do not apply to this project.

        Document Requirements

        - Title the document "Repository Guidelines".
        - Use Markdown headings (#, ##, etc.) for structure.
        - Keep the document concise. 200-400 words is optimal.
        - Keep explanations short, direct, and specific to this repository.
        - Provide examples where helpful (commands, directory paths, naming patterns).
        - Maintain a professional, instructional tone.

        Recommended Sections

        Project Structure & Module Organization

        - Outline the project structure, including where the source code, tests, and assets are located.

        Build, Test, and Development Commands

        - List key commands for building, testing, and running locally (e.g., npm test, make build).
        - Briefly explain what each command does.

        Coding Style & Naming Conventions

        - Specify indentation rules, language-specific style preferences, and naming patterns.
        - Include any formatting or linting tools used.

        Testing Guidelines

        - Identify testing frameworks and coverage requirements.
        - State test naming conventions and how to run tests.

        Commit & Pull Request Guidelines

        - Summarize commit message conventions found in the project's Git history.
        - Outline pull request requirements (descriptions, linked issues, screenshots, etc.).

        (Optional) Add other sections if relevant, such as Security & Configuration Tips, Architecture Overview, or Agent-Specific Instructions.
        """
    }

    /// The home folder as `~` (NSString's `abbreviatingWithTildeInPath` is not in Foundation on Linux, where the core
    /// tests also run).
    static func tilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Parsing

    /// `/name rest` with a name of Nook's; the words after it trimmed.
    private static func parse(_ text: String) -> (NookCommand, String)? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("/") else { return nil }
        let body = clean.dropFirst()
        let name = body.prefix { !$0.isWhitespace }
        guard let command = NookCommand(rawValue: name.lowercased()) else { return nil }
        let rest = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (command, rest)
    }
}
