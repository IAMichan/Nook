import Foundation
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Een gratis taalmodel dat in Nook zelf draait (MLX, de motor van Apple voor Apple Silicon).
/// Modellen worden eenmalig van Hugging Face gedownload; daarna werkt alles zonder internet.
///
/// Let op: in dit bestand is `ToolSpec` Nooks eigen type; dat van MLX heet `MLXLMCommon.ToolSpec`.
struct LocalModelOption: Identifiable {
    let id: String        // repository op Hugging Face
    let title: String
    let detail: String
}

@MainActor
final class EmbeddedModel: ObservableObject {
    static let shared = EmbeddedModel()

    /// Modellen die tools kunnen aanroepen, zoals Nook nodig heeft.
    static let options: [LocalModelOption] = [
        LocalModelOption(id: "mlx-community/Qwen2.5-7B-Instruct-4bit", title: "Qwen 2.5 (7B)",
                         detail: "Aanbevolen · ± 4,3 GB · goed in Nederlands · vanaf 16 GB geheugen"),
        LocalModelOption(id: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit", title: "Llama 3.1 (8B)",
                         detail: "± 4,5 GB · degelijk allrounder · vanaf 16 GB geheugen"),
        LocalModelOption(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", title: "Llama 3.2 (3B)",
                         detail: "Licht · ± 1,8 GB · sneller maar minder slim · past op 8 GB geheugen")
    ]

    @Published private(set) var installed: Set<String>
    private var container: ModelContainer?
    private var loadedID: String?

    private init() {
        installed = Set(UserDefaults.standard.stringArray(forKey: "installedLocalModels") ?? [])
    }

    func title(for id: String) -> String {
        Self.options.first { $0.id == id }?.title ?? id
    }

    // MARK: Installeren

    /// Downloadt het model en laadt het meteen, zodat de eerste vraag niet hoeft te wachten.
    func install(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await load(id, progress: progress)
        installed.insert(id)
        UserDefaults.standard.set(Array(installed), forKey: "installedLocalModels")
    }

    private func load(_ id: String, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ModelContainer {
        if loadedID == id, let container { return container }
        do {
            let loaded = try await #huggingFaceLoadModelContainer(
                configuration: ModelConfiguration(id: id),
                progressHandler: { p in progress(p.fractionCompleted) }
            )
            container = loaded
            loadedID = id
            return loaded
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut:
                throw NookError("Downloaden mislukte: geen verbinding met huggingface.co. Het model wordt maar één keer gedownload.")
            default:
                throw NookError("Downloaden mislukte: \(error.localizedDescription)")
            }
        } catch {
            throw NookError("Het model laden mislukte: \(error.localizedDescription)")
        }
    }

    // MARK: Gebruiken

    /// Kleine testvraag zonder tools.
    func test(model id: String) async throws -> String {
        let container = try await load(id)
        let session = ChatSession(container, generateParameters: GenerateParameters(maxTokens: 20, temperature: 0.1))
        let text = try await session.respond(to: "Antwoord met alleen het woord: klaar")
        return Self.stripThinking(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Eén vraag met Nooks tools. Lees-tools draaien meteen; actie-tools worden alleen verzameld als plan.
    func run(model id: String, system: String, prompt: String, tools: [ToolSpec]) async throws -> BrainPlan {
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
            generateParameters: GenerateParameters(maxTokens: 900, temperature: 0.2),
            tools: specs,
            toolDispatch: { call in await collector.handle(call) }
        )
        let text = try await session.respond(to: prompt)
        return BrainPlan(
            text: Self.stripThinking(text).trimmingCharacters(in: .whitespacesAndNewlines),
            actions: collector.actions
        )
    }

    // MARK: Hulpjes

    /// Sommige modellen zetten hun denkwerk tussen <think>-tags; dat hoort niet in de kaart.
    private static func stripThinking(_ text: String) -> String {
        guard let range = text.range(of: "<think>[\\s\\S]*?</think>", options: .regularExpression) else { return text }
        return text.replacingCharacters(in: range, with: "")
    }

    /// MLX wil `Sendable`-waarden; Nooks schema's bestaan alleen uit tekst, getallen, lijsten en woordenboeken.
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

/// Voert de tools uit die het model aanroept: lezen meteen, acties alleen als voorstel.
@MainActor
private final class ToolCollector {
    let tools: [ToolSpec]
    private(set) var actions: [PlannedAction] = []

    init(tools: [ToolSpec]) { self.tools = tools }

    func handle(_ call: ToolCall) async -> String {
        let name = call.function.name
        let input = call.function.arguments.mapValues { $0.anyValue }
        guard let spec = tools.first(where: { $0.name == name }) else { return "Onbekende tool." }
        switch spec.kind {
        case .read:
            do {
                return "<tool_data>\n\(try await spec.run(input))\n</tool_data>"
            } catch {
                return "Fout: \(error.localizedDescription)"
            }
        case .action:
            actions.append(PlannedAction(tool: name, input: input))
            return "Voorgesteld aan de gebruiker. Wordt pas uitgevoerd na bevestiging."
        }
    }
}
