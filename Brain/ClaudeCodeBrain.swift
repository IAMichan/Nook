import Foundation

/// Denken via Claude Code op je eigen Mac (`claude -p`). Zo werkt je Claude-abonnement (Pro/Max) als brein,
/// zonder API-sleutel. Claude Code mag daarbij zelf op het web zoeken en pagina's lezen, maar niets op je Mac aanpassen.
///
/// Nooks eigen tools (agenda, mail, bestanden, acties) gaan via een eenvoudig tekstprotocol: het model antwoordt met
/// JSON als {"name": "…", "parameters": {…}}. Lees-tools draaien meteen, acties worden zoals altijd eerst voorgesteld.
@MainActor
enum ClaudeCodeBrain {
    /// Waar `claude` staat, eenmalig gezocht.
    private static var cachedPath: String??

    static var executable: String? {
        if let cachedPath { return cachedPath }
        let found = locate()
        cachedPath = .some(found)
        return found
    }

    /// Opnieuw zoeken (bijvoorbeeld nadat je Claude Code net hebt geïnstalleerd).
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
        // Via je eigen shell, voor installaties met nvm, asdf en dergelijke.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let output = try? SystemControl.runProcess(shell, ["-lc", "command -v claude"]) {
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).last ?? ""
            if path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static func run(model: String, system: String, prompt: String, tools: [ToolSpec], onText: ((String) -> Void)?) async throws -> BrainPlan {
        guard let path = executable else {
            throw NookError("Ik vind Claude Code niet op je Mac. Installeer het (claude.com/product/claude-code), log in met `claude` in de terminal en probeer opnieuw.")
        }
        let known = Set(tools.map(\.name))
        var actions: [PlannedAction] = []
        var sessionID: String?
        var message = prompt
        var finalText = ""
        let fullSystem = system + "\n\n" + protocolText(tools)

        for _ in 0..<5 {
            let result = try await call(path: path, model: model, system: fullSystem, message: message, resume: sessionID)
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
                        results.append("Resultaat van \(call.name):\n<tool_data>\n\(output)\n</tool_data>")
                    } catch {
                        results.append("Fout bij \(call.name): \(error.localizedDescription)")
                    }
                case .action:
                    actions.append(PlannedAction(tool: call.name, input: call.input))
                    results.append("\(call.name) is voorgesteld aan de gebruiker en wordt pas uitgevoerd na bevestiging.")
                }
            }
            // Alleen acties: klaar, het plan staat. Anders met de uitkomsten verder.
            if results.allSatisfy({ $0.contains("voorgesteld aan de gebruiker") }) { break }
            message = results.joined(separator: "\n\n") + "\n\nBeantwoord nu het verzoek in gewone taal, of roep nog een tool aan als dat echt nodig is."
        }
        return BrainPlan(text: finalText.trimmingCharacters(in: .whitespacesAndNewlines), actions: actions)
    }

    private static func protocolText(_ tools: [ToolSpec]) -> String {
        guard !tools.isEmpty else { return "" }
        var lines = [
            "Je hebt deze tools van Nook. Wil je er een gebruiken, antwoord dan met alleen JSON per aanroep, op een eigen regel, zoals {\"name\": \"list_events\", \"parameters\": {\"from\": \"…\", \"to\": \"…\"}}. Je krijgt de uitkomst terug. Acties (agenda, herinneringen, mail, apps) worden eerst aan de gebruiker getoond.",
            "Je eigen tools WebSearch en WebFetch mag je gebruiken voor dingen op het web.",
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

    private static func call(path: String, model: String, system: String, message: String, resume: String?) async throws -> CallResult {
        var arguments = [
            "-p", message,
            "--output-format", "json",
            "--model", model.isEmpty ? "haiku" : model,
            "--append-system-prompt", system,
            // Alleen kijken op het web; nooit iets op de Mac aanpassen of uitvoeren.
            "--allowedTools", "WebSearch", "WebFetch",
            "--disallowedTools", "Bash", "Edit", "Write", "MultiEdit", "NotebookEdit", "Task",
            "--max-turns", "6",
            // Je eigen hooks (ook die van Nook) niet laden: dit gesprek is geen agent-sessie die in de notch hoort.
            "--setting-sources", "local"
        ]
        if let resume { arguments += ["--resume", resume] }

        var output = try await execute(path, arguments)
        // Oudere versies kennen --setting-sources niet: dan zonder.
        if output.status != 0, output.text.contains("setting-sources") {
            if let index = arguments.firstIndex(of: "--setting-sources") { arguments.removeSubrange(index...(index + 1)) }
            output = try await execute(path, arguments)
        }
        let object = output.text.split(separator: "\n").reversed().lazy.compactMap { line -> [String: Any]? in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }.first

        guard let object else {
            let detail = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.localizedCaseInsensitiveContains("login") || detail.localizedCaseInsensitiveContains("authenticat") {
                throw NookError("Claude Code is niet ingelogd. Typ `claude` in de terminal, log in met je abonnement en probeer opnieuw.")
            }
            throw NookError("Claude Code gaf geen antwoord" + (detail.isEmpty ? "." : ": \(String(detail.prefix(200)))"))
        }
        let text = (object["result"] as? String) ?? ""
        if (object["is_error"] as? Bool) == true {
            if text.localizedCaseInsensitiveContains("limit") {
                throw NookError("Je Claude-limiet is bereikt. \(text)")
            }
            throw NookError("Claude Code: \(text.isEmpty ? "er ging iets mis" : String(text.prefix(240)))")
        }
        return CallResult(text: text, session: object["session_id"] as? String)
    }

    private struct ProcessOutput: Sendable {
        var status: Int32
        var text: String
    }

    /// Draait `claude` buiten de hoofdthread, met een PATH waarin ook node te vinden is, en hooguit twee minuten.
    private nonisolated static func execute(_ path: String, _ arguments: [String]) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.currentDirectoryURL = NookPaths.supportDirectory
                var environment = ProcessInfo.processInfo.environment
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let extra = [
                    URL(fileURLWithPath: path).deletingLastPathComponent().path,
                    "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.volta/bin"
                ]
                environment["PATH"] = (extra + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
                environment["NOOK_INTERNAL"] = "1"
                process.environment = environment
                let out = Pipe()
                process.standardOutput = out
                process.standardError = out
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: NookError("Claude Code starten lukte niet: \(error.localizedDescription)"))
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
