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
struct LocalModelOption: Identifiable {
    let id: String        // repository on Hugging Face
    let title: String
    let detail: String
    let minMemoryGB: Int  // lower memory than this: too heavy, will stall the Mac

    /// Does this model fit comfortably on this Mac?
    var fits: Bool { EmbeddedModel.memoryGB >= minMemoryGB }
}

@MainActor
final class EmbeddedModel: ObservableObject {
    static let shared = EmbeddedModel()

    /// Models capable of tool calling as required by Nook.
    static let options: [LocalModelOption] = [
        LocalModelOption(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", title: "Llama 3.2 (3B)",
                         detail: "Lightweight · ± 1.8 GB · fast, low system impact · 8 GB+ memory", minMemoryGB: 8),
        LocalModelOption(id: "mlx-community/Qwen2.5-7B-Instruct-4bit", title: "Qwen 2.5 (7B)",
                         detail: "Smarter and more capable · ± 4.3 GB, heavier load · 24 GB+ memory", minMemoryGB: 24),
        LocalModelOption(id: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit", title: "Llama 3.1 (8B)",
                         detail: "± 4.5 GB, heavier load · 24 GB+ memory", minMemoryGB: 24)
    ]

    /// System memory of this Mac, in GB.
    static let memoryGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)

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
            return try await #huggingFaceLoadModelContainer(
                configuration: ModelConfiguration(id: id),
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

    /// A single query with Nook's tools. Read tools run immediately; action tools are collected for the plan.
    func run(model id: String, system: String, prompt: String, tools: [ToolSpec]) async throws -> BrainPlan {
        try await exclusive { try await runExclusive(model: id, system: system, prompt: prompt, tools: tools) }
    }

    private func runExclusive(model id: String, system: String, prompt: String, tools: [ToolSpec]) async throws -> BrainPlan {
        let container = try await load(id)
        let collector = ToolCollector(tools: tools)
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
            generateParameters: GenerateParameters(maxTokens: 450, maxKVSize: 4096, temperature: 0.2),
            tools: specs.isEmpty ? nil : specs,
            toolDispatch: specs.isEmpty ? nil : { call in await collector.handle(call) }
        )
        var text = Self.stripThinking(try await session.respond(to: prompt))

        // Small models sometimes output tool calls as raw JSON in their response text instead of dispatching natively.
        // We intercept, execute, and prompt the model to provide a natural language response.
        for _ in 0..<2 {
            let found = Self.extractToolCalls(from: text, knownTools: Set(tools.map(\.name)))
            guard !found.calls.isEmpty else { break }
            var results: [String] = []
            for call in found.calls {
                results.append("\(call.name): \(await collector.run(name: call.name, input: call.input))")
            }
            text = Self.stripThinking(try await session.respond(
                to: "Tool results:\n\(results.joined(separator: "\n"))\n\nNow answer my request in natural language. Do not output JSON."
            ))
        }
        // If any tool call JSON remains in the text, strip it so it never appears in the output.
        text = Self.extractToolCalls(from: text, knownTools: Set(tools.map(\.name))).text

        return BrainPlan(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            actions: collector.actions
        )
    }

    /// Extracts tool calls formatted as JSON from response text, such as {"name": "list_events", "parameters": {"from": "…"}}.
    /// Returns extracted calls and the cleaned text. Also handles truncated JSON objects (missing closing brace).
    static func extractToolCalls(from text: String, knownTools: Set<String>) -> (text: String, calls: [(name: String, input: [String: Any])]) {
        var remaining = text
        var calls: [(name: String, input: [String: Any])] = []
        var offset = 0  // search offset; String.Index is invalidated after removing substrings

        while let open = remaining[remaining.index(remaining.startIndex, offsetBy: offset)...].firstIndex(of: "{") {
            // Match closing brace; if missing, take remaining text and append closing braces.
            var depth = 0, inString = false, escaped = false
            var close: String.Index?
            for index in remaining[open...].indices {
                let character = remaining[index]
                if inString {
                    if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                    continue
                }
                if character == "\"" { inString = true }
                else if character == "{" { depth += 1 }
                else if character == "}" { depth -= 1; if depth == 0 { close = index; break } }
            }
            var candidate = close.map { String(remaining[open...$0]) } ?? (String(remaining[open...]) + String(repeating: "}", count: max(depth, 0)))
            if close == nil, inString { candidate += "\"" + String(repeating: "}", count: max(depth, 0)) }

            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = (object["name"] as? String) ?? (object["tool"] as? String),
                  knownTools.contains(name) else {
                offset = remaining.distance(from: remaining.startIndex, to: open) + 1
                continue
            }
            let input = (object["parameters"] as? [String: Any]) ?? (object["arguments"] as? [String: Any]) ?? (object["input"] as? [String: Any]) ?? [:]
            calls.append((name, input))
            let end = close.map { remaining.index(after: $0) } ?? remaining.endIndex
            offset = remaining.distance(from: remaining.startIndex, to: open)
            remaining.removeSubrange(open..<end)
        }
        return (remaining, calls)
    }

    // MARK: Helpers

    /// Some models output reasoning inside <think> tags; strip from final text.
    private static func stripThinking(_ text: String) -> String {
        guard let range = text.range(of: "<think>[\\s\\S]*?</think>", options: .regularExpression) else { return text }
        return text.replacingCharacters(in: range, with: "")
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

/// Executes tools invoked by the model: read tools immediately, action tools as proposals.
@MainActor
private final class ToolCollector {
    let tools: [ToolSpec]
    private(set) var actions: [PlannedAction] = []
    private var calls = 0

    init(tools: [ToolSpec]) { self.tools = tools }

    func handle(_ call: ToolCall) async -> String {
        // Small models can loop invoking tools; cap iterations to avoid stalling.
        calls += 1
        if calls > 5 { return "Sufficient information collected. Provide your answer now without calling further tools." }
        return await run(name: call.function.name, input: call.function.arguments.mapValues { $0.anyValue }, counted: true)
    }

    /// Executes a tool by name; also handles calls extracted as text from model output.
    func run(name: String, input: [String: Any], counted: Bool = false) async -> String {
        if !counted {
            calls += 1
            if calls > 5 { return "Sufficient information collected. Provide your answer now without calling further tools." }
        }
        guard let spec = tools.first(where: { $0.name == name }) else { return "Unknown tool." }
        switch spec.kind {
        case .read:
            do {
                return UntrustedText.wrap(try await spec.run(input))
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case .action:
            actions.append(PlannedAction(tool: name, input: input))
            return "Proposed to the user. Will only be executed after confirmation."
        }
    }
}
