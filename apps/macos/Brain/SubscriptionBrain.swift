import Foundation

/// Reasoning through the coding agent you are already signed in to, with your own subscription instead of an API key:
/// Codex with your ChatGPT account (`codex exec`), Gemini CLI with your Google account (`gemini -p`). Claude Code, the
/// third member of this family, has its own `ClaudeCodeBrain` because it resumes sessions.
///
/// Both run locked down, as Claude Code does: no shell, no file reading or writing, no extensions, plugins or MCP servers
/// of your own, and web search only when the Web source is allowed for the request. They run in an empty folder of their
/// own, never Nook's support folder. Nook's own tools go through the same JSON text protocol as with Claude Code, and the
/// whole conversation is sent again each round, so nothing is kept on disk between calls.
@MainActor
enum SubscriptionBrain {
    /// The agent's program on this Mac, as the Agents page finds it.
    static func executable(_ provider: AIProvider) -> String? {
        guard let kind = provider.subscriptionAgent else { return nil }
        if provider == .claudeCode { return ClaudeCodeBrain.executable }
        return AppModel.shared.history.executables[kind]
    }

    /// Signed in with the agent's own login: the account the Agents page reads from its files.
    static func isSignedIn(_ provider: AIProvider) -> Bool {
        guard let kind = provider.subscriptionAgent else { return false }
        let app = AppModel.shared
        return app.history.profileAccounts[app.profiles.preferredProfile(kind).id] != nil
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
            guard let kind = provider.subscriptionAgent else { throw NookError(tr("brain.cli.notInstalled", provider.title)) }
            let fullSystem = system + "\n\n" + SubscriptionBrain.protocolText(tools, allowWebSearch: allowWebSearch)
            let profile = AppModel.shared.profiles.preferredProfile(kind)
            var environment = AgentCommand.environment(base: ProcessInfo.processInfo.environment, executable: path,
                                                        extra: profile.environment)
            // Nook's own thinking: the agent's hooks, if any, leave it out of the notch.
            environment["NOOK_INTERNAL"] = "1"
            let text = try await SubscriptionBrain.call(provider: provider, path: path, environment: environment, model: model,
                                                        system: fullSystem, message: transcript, allowWebSearch: allowWebSearch,
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
        if provider == .geminiCLI {
            answer = try geminiAnswer(output, provider: provider)
        } else {
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
