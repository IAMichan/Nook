import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence as Nook's brain (macOS 26): Apple's on-device model, already on every Mac with Apple Intelligence
/// turned on. Nothing to download, nothing leaves the Mac.
///
/// The model has a small window (about 4k tokens), so Nook gives it the smallest profile: a few tools, its own lookups
/// done first (Research), and a narrow second try for actions. Tools are described in the instructions and called as one
/// JSON object, the same way Nook already reads tool calls that small local models write as text; the shared ToolRunner
/// and ActionGate check them as for every brain.
enum AppleIntelligence {
    enum Status: Equatable {
        case available
        /// Apple Intelligence is off in System Settings.
        case notEnabled
        /// The model is still downloading or getting ready.
        case notReady
        /// Before macOS 26, an Intel Mac, or a Mac that cannot run it.
        case unsupported
    }

    static var status: Status {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
            case .unavailable(.modelNotReady): return .notReady
            default: return .unsupported
            }
        }
        #endif
        return .unsupported
    }

    static var isAvailable: Bool { status == .available }

    /// Why it cannot be used, for Settings and errors.
    static var unavailableReason: String {
        switch status {
        case .available: return ""
        case .notEnabled: return tr("brain.apple.notEnabled")
        case .notReady: return tr("brain.apple.notReady")
        case .unsupported: return tr("brain.apple.unsupported")
        }
    }

    /// The tools, described for a model without native tool calling, and how to call them.
    static func toolInstructions(_ tools: [LoopTool]) -> String {
        guard !tools.isEmpty else { return "" }
        let lines = tools.map { tool -> String in
            let properties = (tool.schema["properties"] as? [String: Any]) ?? [:]
            let required = Set((tool.schema["required"] as? [String]) ?? [])
            let arguments = properties.keys.sorted().map { name -> String in
                let field = properties[name] as? [String: Any]
                let type = (field?["type"] as? String) ?? "string"
                return "\(name) (\(type)\(required.contains(name) ? ", required" : ""))"
            }
            let summary = tool.description.split(separator: ".").first.map(String.init) ?? tool.description
            return "- \(tool.name): \(summary). Arguments: \(arguments.isEmpty ? "none" : arguments.joined(separator: ", "))."
        }
        return """


        Tools you can use. To use one, reply with ONLY one JSON object and nothing else, for example {"name": "tool_name", "arguments": {"field": "value"}}. You then get the result and answer the user.
        \(lines.joined(separator: "\n"))
        """
    }

    @MainActor
    static func run(system: String, prompt: String, profile: ModelProfile, runner: ToolRunner,
                    onText: ((String) -> Void)?) async throws -> BrainPlan {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard SystemLanguageModel.default.availability == .available else { throw NookError(unavailableReason) }
            let tools = runner.tools
            let known = Set(tools.map(\.name))
            let session = LanguageModelSession(instructions: system + toolInstructions(tools))
            let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: profile.maxOutputTokens)
            var text = try await stream(session, prompt, options: options, onText: onText)
            for _ in 0..<max(1, profile.rounds) {
                let found = ToolRunner.extractToolCalls(from: text, knownTools: known)
                guard !found.calls.isEmpty else { break }
                var results: [String] = []
                for call in found.calls {
                    results.append("\(call.name): \(await runner.handle(name: call.name, input: call.input).output)")
                }
                let followUp = "Tool results:\n\(results.joined(separator: "\n"))\n\nNow answer my request in natural language. Only if you really need another tool, reply with one JSON object again."
                text = try await stream(session, String(followUp.prefix(6_000)), options: options, onText: onText)
            }
            text = ToolRunner.extractToolCalls(from: text, knownTools: known).text
            return BrainPlan(text: text.trimmingCharacters(in: .whitespacesAndNewlines), actions: runner.actions)
        }
        #endif
        throw NookError(unavailableReason)
    }

    @MainActor
    static func test() async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard SystemLanguageModel.default.availability == .available else { throw NookError(unavailableReason) }
            let session = LanguageModelSession(instructions: "You are a test.")
            return try await session.respond(to: "Reply with only the word: ready").content
        }
        #endif
        throw NookError(unavailableReason)
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    @MainActor
    private static func stream(_ session: LanguageModelSession, _ prompt: String, options: GenerationOptions,
                               onText: ((String) -> Void)?) async throws -> String {
        var output = ""
        var lastEmit = Date.distantPast
        for try await snapshot in session.streamResponse(to: prompt, options: options) {
            try Task.checkCancellation()
            output = snapshot.content
            guard let onText, Date().timeIntervalSince(lastEmit) > 0.05 else { continue }
            lastEmit = Date()
            let visible = EmbeddedModel.visible(output)
            if !visible.isEmpty { onText(visible) }
        }
        if let onText {
            let visible = EmbeddedModel.visible(output)
            if !visible.isEmpty { onText(visible) }
        }
        return output
    }
    #endif
}
