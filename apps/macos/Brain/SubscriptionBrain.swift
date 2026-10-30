import Foundation

/// Reasoning through the coding agent you are already signed in to, with your own subscription or account instead of an
/// API key: Codex with your ChatGPT account (`codex exec`), Gemini CLI with your Google account (`gemini -p`), Grok with
/// your xAI account (`grok -p`), Kimi Code with your Kimi account (`kimi -p`) and Mistral Vibe with your Mistral account
/// (`vibe -p`). Claude Code, the first member of this family, has its own `ClaudeCodeBrain` because it resumes sessions.
///
/// All run locked down, as Claude Code does: no shell, no file reading or writing, no extensions, plugins, sub-agents or
/// MCP servers of your own, and web search only when the Web source is allowed for the request (Kimi and Vibe never
/// search: their search tools are not named in their documentation, so every tool stays off). They run in an empty folder of their
/// own, never Nook's support folder. Nook's own tools go through the same JSON text protocol as with Claude Code, and the
/// whole conversation is sent again each round, so nothing is kept on disk between calls.
@MainActor
enum SubscriptionBrain {
    /// The agent's program on this Mac: as the Agents page finds it for the agents Nook runs, else searched once.
    static func executable(_ provider: AIProvider) -> String? {
        guard let command = provider.cliCommand else { return nil }
        if provider == .claudeCode { return ClaudeCodeBrain.executable }
        if let kind = provider.subscriptionAgent, let path = AppModel.shared.history.executables[kind] { return path }
        if let cached = located[command] { return cached }
        if let hit = inFolders(command) {
            located[command] = .some(hit)
            return hit
        }
        searchInShell(command)
        return nil
    }

    /// Search again, e.g. after installing an agent.
    static func resetLocations() { located = [:] }

    private static var located: [String: String?] = [:]
    private static var searching: Set<String> = []

    private static func inFolders(_ command: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin",
                       "\(home)/.volta/bin", "\(home)/.cargo/bin", "\(home)/.kimi-code/bin", "\(home)/.grok/bin"]
        return folders.map { "\($0)/\(command)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Asks the user's login shell (nvm, asdf, uv and the like) off the main thread: a login shell can take seconds.
    /// Settings redraws once the program is found.
    private static func searchInShell(_ command: String) {
        guard !searching.contains(command) else { return }
        searching.insert(command)
        Task.detached(priority: .utility) {
            let found = shellLookup(command)
            await MainActor.run {
                located[command] = .some(found)
                searching.remove(command)
                if found != nil { AppSettings.shared.objectWillChange.send() }
            }
        }
    }

    private nonisolated static func shellLookup(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let output = try? SystemControl.runProcess(shell, ["-lc", "command -v \(command)"]) else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).last ?? ""
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Signed in with the agent's own login: the account the Agents page reads from its files, Vibe's saved sign-in, or
    /// for Kimi Code (which documents no way to tell) being installed.
    static func isSignedIn(_ provider: AIProvider) -> Bool {
        if let kind = provider.subscriptionAgent {
            let app = AppModel.shared
            return app.history.profileAccounts[app.profiles.brainProfile(kind).id] != nil
        }
        switch provider {
        case .vibeCLI:
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vibe/.env")
            return ((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains("MISTRAL_API_KEY=")
        default:
            return executable(provider) != nil
        }
    }

    /// The command that signs in, in the Terminal, for the agents Nook does not run itself.
    static func loginCommand(_ provider: AIProvider) -> String? {
        switch provider {
        case .kimiCLI: return "kimi login"
        case .vibeCLI: return "vibe --setup"
        default: return nil
        }
    }

    static func conversation(provider: AIProvider, model: String, system: String, prompt: String,
                             allowWebSearch: Bool) -> ModelConversation {
        CLIConversation(provider: provider, model: model, system: system, prompt: prompt, allowWebSearch: allowWebSearch)
    }

    @MainActor
    private final class CLIConversation: ModelConversation {
        let provider: AIProvider
        let model: String
        let system: String
        let allowWebSearch: Bool
        /// Everything said so far, sent whole every round.
        var transcript: String
        var images: [PromptImage] = []

        init(provider: AIProvider, model: String, system: String, prompt: String, allowWebSearch: Bool) {
            self.provider = provider
            self.model = model
            self.system = system
            self.transcript = prompt
            self.allowWebSearch = allowWebSearch
        }

        func next(tools: [LoopTool], onText: ((String) -> Void)?) async throws -> ModelTurn {
            guard let path = SubscriptionBrain.executable(provider) else {
                throw NookError(tr("brain.cli.notInstalled", provider.title))
            }
            let searches = allowWebSearch && provider.cliSearchesWeb
            let fullSystem = system + "\n\n" + SubscriptionBrain.protocolText(tools, allowWebSearch: searches)
            // The account picked for the brain in the chat's model picker, else the default under Settings › Agents.
            let extra = provider.subscriptionAgent.map { AppModel.shared.profiles.brainProfile($0).environment } ?? [:]
            var environment = AgentCommand.environment(base: ProcessInfo.processInfo.environment, executable: path, extra: extra)
            // Nook's own thinking: the agent's hooks, if any, leave it out of the notch.
            environment["NOOK_INTERNAL"] = "1"
            let text = try await SubscriptionBrain.call(provider: provider, path: path, environment: environment, model: model,
                                                        system: fullSystem, message: transcript, allowWebSearch: searches,
                                                        images: images)
            images = []
            transcript += "\n\nAssistant:\n" + text
            if !text.isEmpty { onText?(text) }
            // Tool calls are written as JSON in the text: the shared loop extracts them.
            return ModelTurn(text: text, calls: [])
        }

        func addResults(_ results: [(call: ToolCallRequest, output: String, isError: Bool)]) {
            transcript += "\n\n" + results.map { "Result of \($0.call.name):\n\($0.output)" }.joined(separator: "\n\n")
                + "\n\nNow respond to the request in natural language, or invoke another tool only if strictly necessary."
        }

        func addInstruction(_ text: String) {
            transcript += "\n\n" + text
        }

        func attach(_ images: [PromptImage]) {
            // Codex takes pictures with the prompt; Gemini CLI only reads them as files, which stays off.
            if provider.cliTakesImages { self.images = images }
        }
    }

    nonisolated static func protocolText(_ tools: [LoopTool], allowWebSearch: Bool) -> String {
        guard !tools.isEmpty else { return "" }
        var lines = [
            "You have these tools from Nook. To use one, reply ONLY with JSON for each tool call on its own line, like {\"name\": \"list_events\", \"parameters\": {\"from\": \"…\", \"to\": \"…\"}}. You will receive the result back. Actions (calendar, reminders, email, apps) are shown to the user first.",
            allowWebSearch
                ? "You may use your built-in web search for web queries. To read a page, use Nook's read_webpage tool."
                : "Do not use the web for this request.",
            "These are ALL your tools: you have no shell, no files and no other tools here. When a source's tools are not listed, call use_source; never tell the user a tool is missing before checking this list.",
            "Nook's tools are not function calls: never invoke them through tool use, always write the JSON line in your reply text.",
            "Tools:"
        ]
        for tool in tools {
            let schema = (try? JSONSerialization.data(withJSONObject: tool.schema["properties"] ?? [:], options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            lines.append("- \(tool.name): \(tool.description) Parameters: \(schema)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Codex

    /// `codex exec` that only answers: none of your config, rules, plugins, apps or MCP servers; read-only and without its
    /// shell, image reader or sub-agents; nothing saved; Nook's instructions as developer instructions; the prompt on stdin
    /// and the answer in a file. Your ChatGPT login still comes from `CODEX_HOME`.
    nonisolated static func codexArguments(model: String, system: String, allowWebSearch: Bool, answerPath: String,
                                           imagePaths: [String]) -> [String] {
        var arguments = ["exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check",
                         "-s", "read-only"]
        for feature in ["shell_tool", "unified_exec", "view_image", "plugins", "apps", "multi_agent"] {
            arguments += ["-c", "features.\(feature)=false"]
        }
        arguments += ["-c", allowWebSearch ? #"web_search="live""# : #"web_search="disabled""#,
                      "-c", "developer_instructions=" + tomlString(system),
                      "-c", #"model_reasoning_effort="low""#]
        if !model.isEmpty { arguments += ["-m", model] }
        arguments += ["--output-last-message", answerPath]
        for path in imagePaths { arguments += ["-i", path] }
        arguments.append("-")
        return arguments
    }

    /// A TOML basic string: JSON's escaping (quotes, backslashes, newlines, \uXXXX) is valid TOML too.
    nonisolated static func tomlString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    // MARK: Gemini CLI

    /// `gemini -p` that only answers: no extensions, the JSON reply, and the default approval mode, under which nothing
    /// that asks for approval can run headless. The rest is locked in the settings file of `geminiSettings`.
    nonisolated static func geminiArguments(model: String, prompt: String) -> [String] {
        var arguments = ["-p", prompt, "--output-format", "json", "-e", "none", "--approval-mode", "default"]
        if !model.isEmpty { arguments += ["-m", model] }
        return arguments
    }

    /// Gemini CLI's system settings (they override yours for this run only): no built-in tool but web search when allowed,
    /// the reading and writing tools excluded by name as well, no extensions, MCP servers or skills, and no GEMINI.md
    /// context files.
    nonisolated static func geminiSettings(allowWebSearch: Bool) -> [String: Any] {
        let blocked = ["run_shell_command", "read_file", "read_many_files", "write_file", "replace", "edit", "glob",
                       "search_file_content", "grep_search", "list_directory", "web_fetch", "save_memory", "write_todos",
                       "activate_skill"] + (allowWebSearch ? [] : ["google_web_search"])
        return [
            "tools": ["core": allowWebSearch ? ["google_web_search"] : ["nook_no_tools"], "exclude": blocked],
            "admin": ["extensions": ["enabled": false], "mcp": ["enabled": false], "skills": ["enabled": false]],
            "context": ["fileName": "NOOK-BRAIN-NO-CONTEXT.md"],
        ]
    }

    // MARK: Grok

    /// `grok -p` that only answers: no built-in tool but web search (and that one off unless allowed), every shell, file
    /// and MCP call denied as well, no sub-agents, plan mode or memory, and Nook's instructions as the whole system prompt.
    nonisolated static func grokArguments(model: String, system: String, prompt: String, allowWebSearch: Bool) -> [String] {
        var arguments = ["-p", prompt, "--output-format", "json", "--system-prompt-override", system,
                         "--tools", "web_search", "--disallowed-tools", "Agent", "--no-subagents", "--no-plan",
                         "--max-turns", "4", "--no-auto-update"]
        for rule in ["Bash", "Read", "Edit", "Write", "Grep", "MCPTool"] { arguments += ["--deny", rule] }
        if !allowWebSearch { arguments.append("--disable-web-search") }
        if !model.isEmpty { arguments += ["-m", model] }
        return arguments
    }

    // MARK: Kimi Code

    /// The agent file Kimi Code runs as: no tools and no sub-agents at all; its body is the whole system prompt.
    nonisolated static func kimiAgentFile(system: String) -> String {
        "---\nname: nook-brain\ndescription: Nook's brain, which only answers.\ntools: []\nsubagents: []\n---\n\n" + system + "\n"
    }

    nonisolated static func kimiArguments(model: String, prompt: String, agentFile: String) -> [String] {
        var arguments = ["-p", prompt, "--agent-file", agentFile, "--output-format", "stream-json"]
        if !model.isEmpty { arguments += ["-m", model] }
        return arguments
    }

    /// The last assistant message without tool calls in Kimi Code's stream-json lines.
    nonisolated static func kimiAnswer(_ output: String) -> String? {
        var answer: String?
        for line in output.split(separator: "\n") {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  (object["role"] as? String) == "assistant",
                  ((object["tool_calls"] as? [Any]) ?? []).isEmpty else { continue }
            if let text = object["content"] as? String, !text.isEmpty {
                answer = text
            } else if let parts = object["content"] as? [[String: Any]] {
                let text = parts.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty { answer = text }
            }
        }
        return answer
    }

    // MARK: Mistral Vibe

    /// `vibe -p` that only answers: only a tool that does not exist is enabled, which in programmatic mode switches every
    /// other tool off. Vibe has no system prompt flag, so Nook's instructions lead the prompt.
    nonisolated static func vibeArguments(system: String, prompt: String) -> [String] {
        ["-p", "<instructions>\n" + system + "\n</instructions>\n\n" + prompt, "--enabled-tools", "nook_no_tools",
         "--max-turns", "3", "--output", "text"]
    }

    // MARK: Running

    private static func call(provider: AIProvider, path: String, environment: [String: String], model: String, system: String,
                             message: String, allowWebSearch: Bool, images: [PromptImage]) async throws -> String {
        let folder = NookPaths.brainScratchDirectory
        let run = folder.appendingPathComponent("run-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: run) }
        var environment = environment
        let arguments: [String]
        var stdin: Data?
        let answerFile = run.appendingPathComponent("answer.txt")
        switch provider {
        case .grokCLI:
            environment["GROK_MEMORY"] = "0"
            arguments = grokArguments(model: model, system: system, prompt: message, allowWebSearch: allowWebSearch)
        case .kimiCLI:
            let agentFile = run.appendingPathComponent("nook-brain.md")
            try Data(kimiAgentFile(system: system).utf8).write(to: agentFile)
            arguments = kimiArguments(model: model, prompt: message, agentFile: agentFile.path)
        case .vibeCLI:
            arguments = vibeArguments(system: system, prompt: message)
        case .geminiCLI:
            let settingsFile = run.appendingPathComponent("settings.json")
            let systemFile = run.appendingPathComponent("system.md")
            let settings = try JSONSerialization.data(withJSONObject: geminiSettings(allowWebSearch: allowWebSearch))
            try settings.write(to: settingsFile)
            try Data(system.utf8).write(to: systemFile)
            environment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"] = settingsFile.path
            environment["GEMINI_SYSTEM_MD"] = systemFile.path
            arguments = geminiArguments(model: model, prompt: message)
        default:
            var imagePaths: [String] = []
            for (index, image) in images.enumerated() {
                guard let data = Data(base64Encoded: image.base64) else { continue }
                let suffix = image.mediaType.split(separator: "/").last.map(String.init) ?? "png"
                let file = run.appendingPathComponent("image-\(index).\(suffix)")
                if (try? data.write(to: file)) != nil { imagePaths.append(file.path) }
            }
            arguments = codexArguments(model: model, system: system, allowWebSearch: allowWebSearch,
                                       answerPath: answerFile.path, imagePaths: imagePaths)
            stdin = Data(message.utf8)
        }
        let output = try await execute(path, arguments, environment: environment, directory: run, stdin: stdin)
        let answer: String
        switch provider {
        case .geminiCLI:
            answer = try geminiAnswer(output, provider: provider)
        case .grokCLI:
            answer = try grokAnswer(output, provider: provider)
        case .kimiCLI:
            guard let text = kimiAnswer(output.stdout) else { throw failure(output, provider: provider) }
            answer = text
        case .vibeCLI:
            answer = output.stdout
            if output.status != 0 || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw failure(output, provider: provider)
            }
        default:
            answer = (try? String(contentsOf: answerFile, encoding: .utf8)) ?? ""
            if answer.isEmpty { throw failure(output, provider: provider) }
        }
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Gemini CLI's JSON reply: `response` holds the answer, `error` what went wrong.
    private static func geminiAnswer(_ output: ProcessOutput, provider: AIProvider) throws -> String {
        let text = output.stdout
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any] else {
            throw failure(output, provider: provider)
        }
        if let response = object["response"] as? String, !response.isEmpty { return response }
        let error = (object["error"] as? [String: Any])?["message"] as? String
        throw NookError(tr("brain.cli.failed", provider.title, String((error ?? output.stderr).prefix(240))))
    }

    /// Grok's JSON reply: `text` holds the answer.
    private static func grokAnswer(_ output: ProcessOutput, provider: AIProvider) throws -> String {
        let text = output.stdout
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any],
              let answer = (object["text"] as? String) ?? (object["result"] as? String), !answer.isEmpty else {
            throw failure(output, provider: provider)
        }
        return answer
    }

    /// What went wrong, in words: not signed in, a limit, a program too old for the safety flags, or its own message.
    private static func failure(_ output: ProcessOutput, provider: AIProvider) -> NookError {
        let detail = (output.stderr + "\n" + output.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = detail.lowercased()
        if lower.contains("login") || lower.contains("log in") || lower.contains("auth") || lower.contains("sign in") {
            return NookError(tr("brain.cli.signedOut", provider.title))
        }
        // Never retried without the isolation flags: that would load the user's own tools and rules.
        if lower.contains("unexpected argument") || lower.contains("unknown argument") || lower.contains("unknown option") {
            return NookError(tr("brain.cli.tooOld", provider.title))
        }
        if lower.contains("limit") || lower.contains("quota") {
            return NookError(tr("brain.cli.limit", provider.title, String(detail.suffix(200))))
        }
        return NookError(tr("brain.cli.failed", provider.title, String(detail.suffix(240))))
    }

    /// What the program wrote to stderr, read on another thread.
    private final class ErrorBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Data()
        func set(_ data: Data) { lock.withLock { stored = data } }
        var data: Data { lock.withLock { stored } }
    }

    private struct ProcessOutput: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// Runs the agent off the main thread in its own empty folder, capped at 2 minutes.
    private nonisolated static func execute(_ path: String, _ arguments: [String], environment: [String: String],
                                            directory: URL, stdin: Data?) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.currentDirectoryURL = directory
                process.environment = environment
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                let input = stdin == nil ? nil : Pipe()
                process.standardInput = input ?? FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: NookError(error.localizedDescription))
                    return
                }
                if let input, let stdin {
                    input.fileHandleForWriting.write(stdin)
                    try? input.fileHandleForWriting.close()
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: deadline)
                // Both pipes are read at once, so a full stderr never blocks the program.
                let errorData = ErrorBuffer()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errorData.set(err.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                deadline.cancel()
                continuation.resume(returning: ProcessOutput(status: process.terminationStatus,
                                                             stdout: String(decoding: data, as: UTF8.self),
                                                             stderr: String(decoding: errorData.data, as: UTF8.self)))
            }
        }
    }
}

extension AIProvider {
    /// The coding agent Nook already knows (and runs) whose own login this provider thinks with; nil for the APIs and for
    /// Kimi Code and Mistral Vibe, which Nook only uses as a brain.
    var subscriptionAgent: AgentKind? {
        switch self {
        case .claudeCode: return .claude
        case .codexCLI: return .codex
        case .geminiCLI: return .gemini
        case .grokCLI: return .grok
        default: return nil
        }
    }

    /// The provider that thinks through an agent's own login, nil for an agent the brain cannot think through.
    static func subscription(for kind: AgentKind) -> AIProvider? {
        allCases.first { $0.subscriptionAgent == kind }
    }

    /// Whether the agent may search the web for Nook when the Web source is allowed.
    var cliSearchesWeb: Bool {
        switch self {
        case .claudeCode, .codexCLI, .geminiCLI, .grokCLI: return true
        default: return false
        }
    }
}
