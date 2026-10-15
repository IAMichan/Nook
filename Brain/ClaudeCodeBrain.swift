import Foundation

/// Reasoning via Claude Code on your local Mac (`claude -p`). This uses your Claude subscription (Pro/Max) as a brain,
/// without requiring an API key. Claude Code runs locked down: no file access, no shell, no fetching of arbitrary URLs
/// (that is how untrusted text could leak data), and web search only when the Web source is allowed for the request.
///
/// Nook's native tools (calendar, email, files, actions) use a simple text protocol: the model responds with
/// JSON like {"name": "…", "parameters": {…}}. Read tools run immediately; actions are proposed as always.
@MainActor
enum ClaudeCodeBrain {
    /// Cached path to `claude`, searched once.
    private static var cachedPath: String??

    static var executable: String? {
        if let cachedPath { return cachedPath }
        let found = locate()
        cachedPath = .some(found)
        return found
    }

    /// Reset cached path (e.g. after newly installing Claude Code).
    static func resetLocation() { cachedPath = nil }

    private static func locate() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.volta/bin/claude"
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        // Via the user's shell, for environments managed by nvm, asdf, etc.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let output = try? SystemControl.runProcess(shell, ["-lc", "command -v claude"]) {
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).last ?? ""
            if path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static func run(model: String, system: String, prompt: String, tools: [ToolSpec], allowWebSearch: Bool, onText: ((String) -> Void)?) async throws -> BrainPlan {
        guard let path = executable else {
            throw NookError("Could not find Claude Code on your Mac. Install it (claude.com/product/claude-code), run `claude` in the terminal to log in, and try again.")
        }
        let known = Set(tools.map(\.name))
        var actions: [PlannedAction] = []
        var sessionID: String?
        var message = prompt
        var finalText = ""
        let fullSystem = system + "\n\n" + protocolText(tools, allowWebSearch: allowWebSearch)

        for _ in 0..<5 {
            let result = try await call(path: path, model: model, system: fullSystem, message: message, resume: sessionID, allowWebSearch: allowWebSearch)
            sessionID = result.session ?? sessionID
            let extracted = EmbeddedModel.extractToolCalls(from: result.text, knownTools: known)
            if !extracted.text.isEmpty {
                finalText = extracted.text
                onText?(finalText)
            }
            guard !extracted.calls.isEmpty else { break }

            var results: [String] = []
            for call in extracted.calls {
                guard let spec = tools.first(where: { $0.name == call.name }) else { continue }
                switch spec.kind {
                case .read:
                    do {
                        let output = try await spec.run(call.input)
                        results.append("Result of \(call.name):\n" + UntrustedText.wrap(output))
                    } catch {
                        results.append("Error in \(call.name): \(error.localizedDescription)")
                    }
                case .action:
                    actions.append(PlannedAction(tool: call.name, input: call.input))
                    results.append("\(call.name) has been proposed to the user and will only execute after confirmation.")
                }
            }
            // Actions only: finished, the plan is set. Otherwise continue with results.
            if results.allSatisfy({ $0.contains("has been proposed to the user") }) { break }
            message = results.joined(separator: "\n\n") + "\n\nNow respond to the request in natural language, or invoke another tool only if strictly necessary."
        }
        return BrainPlan(text: finalText.trimmingCharacters(in: .whitespacesAndNewlines), actions: actions)
    }

    private static func protocolText(_ tools: [ToolSpec], allowWebSearch: Bool) -> String {
        guard !tools.isEmpty else { return "" }
        var lines = [
            "You have these tools from Nook. To use one, reply ONLY with JSON for each tool call on its own line, like {\"name\": \"list_events\", \"parameters\": {\"from\": \"…\", \"to\": \"…\"}}. You will receive the result back. Actions (calendar, reminders, email, apps) are shown to the user first.",
            allowWebSearch
                ? "You may use your built-in tool WebSearch for web queries. To read a page, use Nook's read_webpage tool."
                : "Do not use the web for this request.",
            "Tools:"
        ]
        for tool in tools {
            let schema = (try? JSONSerialization.data(withJSONObject: tool.schema["properties"] ?? [:], options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            lines.append("- \(tool.name): \(tool.description) Parameters: \(schema)")
        }
        return lines.joined(separator: "\n")
    }

    private struct CallResult {
        var text: String
        var session: String?
    }

    /// Built-in Claude Code tools the brain may never use. File reads would expose Nook's own data (chat history, the
    /// audit log) and WebFetch could send it anywhere; Nook's own tools cover files and pages with their own checks.
    nonisolated static let blockedTools = [
        "Bash", "Edit", "Write", "MultiEdit", "NotebookEdit", "Task",
        "Read", "Glob", "Grep", "LS", "WebFetch", "TodoWrite"
    ]

    nonisolated static func arguments(message: String, model: String, system: String, resume: String?, allowWebSearch: Bool) -> [String] {
        var arguments = [
            "-p", message,
            "--output-format", "json",
            "--model", model.isEmpty ? "haiku" : model,
            "--append-system-prompt", system
        ]
        if allowWebSearch { arguments += ["--allowedTools", "WebSearch"] }
        arguments += ["--disallowedTools"] + blockedTools + (allowWebSearch ? [] : ["WebSearch"])
        arguments += [
            "--max-turns", "6",
            // Do not load the user's settings, hooks or MCP servers: this is Nook's brain, not an agent session.
            "--setting-sources", "local",
            "--strict-mcp-config"
        ]
        if let resume { arguments += ["--resume", resume] }
        return arguments
    }

    private static func call(path: String, model: String, system: String, message: String, resume: String?, allowWebSearch: Bool) async throws -> CallResult {
        let arguments = Self.arguments(message: message, model: model, system: system, resume: resume, allowWebSearch: allowWebSearch)
        let output = try await execute(path, arguments)
        // Never retry without the isolation flags: that would load the user's own hooks and permission rules.
        if output.status != 0, output.text.contains("setting-sources") || output.text.contains("strict-mcp-config") {
            throw NookError("This version of Claude Code is too old to run safely as Nook's brain. Update it (`claude update`) and try again.")
        }
        let object = output.text.split(separator: "\n").reversed().lazy.compactMap { line -> [String: Any]? in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }.first

        guard let object else {
            let detail = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.localizedCaseInsensitiveContains("login") || detail.localizedCaseInsensitiveContains("authenticat") {
                throw NookError("Claude Code is not logged in. Run `claude` in terminal, sign in with your subscription, and try again.")
            }
            throw NookError("Claude Code did not respond" + (detail.isEmpty ? "." : ": \(String(detail.prefix(200)))"))
        }
        let text = (object["result"] as? String) ?? ""
        if (object["is_error"] as? Bool) == true {
            if text.localizedCaseInsensitiveContains("limit") {
                throw NookError("Your Claude limit has been reached. \(text)")
            }
            throw NookError("Claude Code: \(text.isEmpty ? "something went wrong" : String(text.prefix(240)))")
        }
        return CallResult(text: text, session: object["session_id"] as? String)
    }

    private struct ProcessOutput: Sendable {
        var status: Int32
        var text: String
    }

    /// Runs `claude` off the main thread with a PATH containing node, capped at 2 minutes.
    private nonisolated static func execute(_ path: String, _ arguments: [String]) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                // An empty folder of its own: never Nook's support folder, which holds chat history and the audit log.
                process.currentDirectoryURL = NookPaths.brainScratchDirectory
                var environment = ProcessInfo.processInfo.environment
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let extra = [
                    URL(fileURLWithPath: path).deletingLastPathComponent().path,
                    "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.volta/bin"
                ]
                environment["PATH"] = (extra + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
                environment["NOOK_INTERNAL"] = "1"
                // Uses the Claude account configured as default in the Agents tab.
                if let home = UserDefaults.standard.string(forKey: AgentProfileStore.brainHomeKey), !home.isEmpty {
                    environment["CLAUDE_CONFIG_DIR"] = home
                }
                process.environment = environment
                let out = Pipe()
                process.standardOutput = out
                process.standardError = out
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: NookError("Failed to start Claude Code: \(error.localizedDescription)"))
                    return
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: deadline)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: ProcessOutput(status: process.terminationStatus, text: text))
            }
        }
    }
}
