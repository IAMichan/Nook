import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// A free language model running locally in Nook via MLX (Apple's framework for Apple Silicon).
/// Models are downloaded once from Hugging Face; afterwards everything runs completely offline.
///
/// Note: in this file, `ToolSpec` is Nook's native type; MLX's type is `MLXLMCommon.ToolSpec`.
@MainActor
final class EmbeddedModel: ObservableObject {
    static let shared = EmbeddedModel()

    /// Models Nook can run itself; the advisor picks the one that suits this Mac.
    static var options: [LocalModelOption] { ModelAdvisor.catalog }

    /// System memory of this Mac, in GB.
    nonisolated static let memoryGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)

    @Published private(set) var installed: Set<String>
    private var container: ModelContainer?
    private var loadedID: String?
    private var busy = false
    private var idleTask: Task<Void, Never>?
    private var pressureSource: DispatchSourceMemoryPressure?

    /// Unload model from memory after this many seconds of inactivity. High RAM: longer, keeping the next query instant.
    private static let idleSeconds: UInt64 = memoryGB >= 24 ? 300 : 90

    private init() {
        installed = Set(UserDefaults.standard.stringArray(forKey: "installedLocalModels") ?? [])
        // By default MLX retains extensive cache; limiting it prevents system lag.
        Memory.cacheLimit = 128 * 1024 * 1024

        // Under memory pressure, unload the model immediately.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in Task { @MainActor in self?.unload() } }
        source.resume()
        pressureSource = source
    }

    /// Pre-loads the model in the background (e.g. when opening panel or starting interaction).
    func preload(_ id: String) {
        guard !id.isEmpty, loadedID != id, !busy, installed.contains(id) else { return }
        Task {
            _ = try? await load(id)
            scheduleUnload()
        }
    }

    /// Unloads the model from memory.
    func unload() {
        idleTask?.cancel()
        guard container != nil else { return }
        container = nil
        loadedID = nil
        Memory.clearCache()
    }

    private func scheduleUnload() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }

    /// One query at a time: concurrent model runs require double the memory.
    private func exclusive<T>(_ work: () async throws -> T) async throws -> T {
        guard !busy else { throw NookError("I am still processing your previous query. Please try again shortly.") }
        busy = true
        idleTask?.cancel()
        defer {
            busy = false
            Memory.clearCache()
            scheduleUnload()
        }
        return try await work()
    }

    func title(for id: String) -> String {
        Self.options.first { $0.id == id }?.title ?? id
    }

    // MARK: Installation

    /// Downloads the model and loads it immediately so the first query does not wait.
    func install(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await load(id, progress: progress)
        installed.insert(id)
        UserDefaults.standard.set(Array(installed), forKey: "installedLocalModels")
        scheduleUnload()
    }

    var isLoaded: Bool { container != nil }
    private var loading: (id: String, task: Task<ModelContainer, Error>)?

    /// Loads the model, avoiding duplicate concurrent loads: subsequent callers await the first.
    private func load(_ id: String, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ModelContainer {
        if loadedID == id, let container { return container }
        if let loading, loading.id == id { return try await loading.task.value }

        let task = Task { try await Self.fetch(id, progress: progress) }
        loading = (id, task)
        defer { loading = nil }
        let loaded = try await task.value
        container = loaded
        loadedID = id
        return loaded
    }

    private nonisolated static func fetch(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws -> ModelContainer {
        do {
            // Nook downloads the files itself, so the progress follows every byte (see ModelDownload). A model installed by
            // an older version stays in the Hugging Face cache and loads from there. Only when the Hub's file list cannot
            // be read does the library download it.
            var configuration = ModelConfiguration(id: id)
            if let local = ModelDownload.completedDirectory(for: id) {
                configuration = ModelConfiguration(directory: local)
            } else if !ModelDownload.isInHubCache(id) {
                do {
                    configuration = ModelConfiguration(directory: try await ModelDownload.fetch(id, progress: progress))
                } catch let error as ModelDownload.ListingUnavailable {
                    Log.brain.error("own model download unavailable (\(error.reason, privacy: .public)), using the library")
                }
            }
            return try await #huggingFaceLoadModelContainer(
                configuration: configuration,
                progressHandler: { p in progress(p.fractionCompleted) }
            )
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut:
                throw NookError("Download failed: no connection to huggingface.co. The model is only downloaded once.")
            default:
                throw NookError("Download failed: \(error.localizedDescription)")
            }
        } catch {
            throw NookError("Failed to load model: \(error.localizedDescription)")
        }
    }

    // MARK: Inference

    /// Small test query without tools.
    func test(model id: String) async throws -> String {
        try await exclusive {
            let container = try await load(id)
            let session = ChatSession(container, generateParameters: GenerateParameters(maxTokens: 20, maxKVSize: 512, temperature: 0.1))
            let text = try await session.respond(to: "Reply with only the word: ready")
            return Self.stripThinking(text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// A single query with Nook's tools, through the shared tool loop: read tools run immediately, action tools are
    /// collected for the plan, invalid input is sent back for repair, and limits stop a model that keeps calling tools.
    /// `onText` receives the visible answer so far, so it appears while it is being written.
    func run(model id: String, system: String, prompt: String, profile: ModelProfile, runner: ToolRunner,
             onText: ((String) -> Void)? = nil) async throws -> BrainPlan {
        try await exclusive { try await runExclusive(model: id, system: system, prompt: prompt, profile: profile, runner: runner, onText: onText) }
    }

    private func runExclusive(model id: String, system: String, prompt: String, profile: ModelProfile, runner: ToolRunner,
                              onText: ((String) -> Void)?) async throws -> BrainPlan {
        let container = try await load(id)
        let tools = runner.tools
        let specs: [MLXLMCommon.ToolSpec] = tools.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": Self.sendable(tool.schema)
                ] as [String: any Sendable]
            ] as MLXLMCommon.ToolSpec
        }

        let session = ChatSession(
            container,
            instructions: system,
            generateParameters: GenerateParameters(maxTokens: profile.maxOutputTokens, maxKVSize: profile.contextTokens, temperature: 0.2),
            // Hybrid models (Qwen 3) think out loud by default: slow on a laptop and never shown, so it is switched off.
            additionalContext: ["enable_thinking": false],
            tools: specs.isEmpty ? nil : specs,
            toolDispatch: specs.isEmpty ? nil : { call in
                await runner.handle(name: call.function.name, input: call.function.arguments.mapValues { $0.anyValue }).output
            }
        )
        var text = Self.stripThinking(try await stream(session, prompt, onText: onText))

        // Small models sometimes write tool calls as JSON in their answer instead of calling them: run those too, and ask
        // for a natural-language answer.
        let known = Set(tools.map(\.name))
        for _ in 0..<2 {
            let found = ToolRunner.extractToolCalls(from: text, knownTools: known)
            guard !found.calls.isEmpty else { break }
            var results: [String] = []
            for call in found.calls {
                results.append("\(call.name): \(await runner.handle(name: call.name, input: call.input).output)")
            }
            text = Self.stripThinking(try await stream(
                session, "Tool results:\n\(results.joined(separator: "\n"))\n\nNow answer my request in natural language. Do not output JSON.",
                onText: onText
            ))
        }
        // If any tool call JSON remains in the text, strip it so it never appears in the output.
        text = ToolRunner.extractToolCalls(from: text, knownTools: known).text

        return BrainPlan(text: text.trimmingCharacters(in: .whitespacesAndNewlines), actions: runner.actions)
    }

    /// Generates one answer and hands the visible part to `onText` while it grows (at most ~20 times a second).
    /// Reasoning in <think> and tool calls written as JSON are never shown.
    private func stream(_ session: ChatSession, _ prompt: String, onText: ((String) -> Void)?) async throws -> String {
        var output = ""
        var lastEmit = Date.distantPast
        for try await chunk in session.streamResponse(to: prompt, role: .user, images: [], videos: [], audios: []) {
            try Task.checkCancellation()
            output += chunk
            guard let onText, Date().timeIntervalSince(lastEmit) > 0.05 else { continue }
            lastEmit = Date()
            let visible = Self.visible(output)
            if !visible.isEmpty { onText(visible) }
        }
        if let onText {
            let visible = Self.visible(output)
            if !visible.isEmpty { onText(visible) }
        }
        return output
    }

    /// The part of a partial answer that may be shown: without reasoning (also while it is still open) and without
    /// a tool call that is being written as JSON.
    nonisolated static func visible(_ partial: String) -> String {
        var text = stripThinking(partial)
        if let open = text.range(of: "<think>") { text = String(text[..<open.lowerBound]) }
        if let call = text.range(of: #"(```(json)?\s*)?\{\s*"(name|tool)"\s*:"#, options: .regularExpression) {
            text = String(text[..<call.lowerBound])
        }
        if let tag = text.range(of: "<tool_call>") { text = String(text[..<tag.lowerBound]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Kept for callers of the old name; the implementation lives in the shared tool loop.
    static func extractToolCalls(from text: String, knownTools: Set<String>) -> (text: String, calls: [(name: String, input: [String: Any])]) {
        ToolRunner.extractToolCalls(from: text, knownTools: knownTools)
    }

    // MARK: Helpers

    /// Some models output reasoning inside <think> tags; strip from final text.
    nonisolated private static func stripThinking(_ text: String) -> String {
        text.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
    }

    /// MLX expects Sendable values; Nook's schemas contain strings, numbers, arrays, and dictionaries.
    private static func sendable(_ value: Any) -> any Sendable {
        switch value {
        case let dict as [String: Any]: return dict.mapValues { sendable($0) } as [String: any Sendable]
        case let list as [Any]: return list.map { sendable($0) } as [any Sendable]
        case let text as String: return text
        case let flag as Bool: return flag
        case let number as Int: return number
        case let number as Double: return number
        default: return String(describing: value)
        }
    }
}

extension LocalModelOption {
    /// Does this model fit comfortably on this Mac?
    var fits: Bool { EmbeddedModel.memoryGB >= minMemoryGB }

    var detail: String {
        tr("brain.option.detail", String(format: "%.1f", sizeGB), minMemoryGB)
    }
}
