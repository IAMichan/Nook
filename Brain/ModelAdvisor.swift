import Foundation

/// What a model can handle, so prompts and tools are sized to fit instead of silently overflowing.
struct ModelProfile: Equatable {
    /// Tokens the model can read at once (prompt + answer).
    var contextTokens: Int
    /// Tokens reserved for the answer.
    var maxOutputTokens: Int
    /// Most tools offered in one round; small models pick worse from long lists.
    var maxTools: Int
    /// Only the first sentence of each tool description (shorter prompt, faster locally).
    var compactDescriptions: Bool
    /// Rounds of tool use before the model must answer.
    var rounds: Int
    /// Small models get a simpler prompt and fewer tools.
    var isSmall: Bool
    /// A strong local model (mixture of experts, 26B and up): the full instructions and tool set the external models get,
    /// so it can work the same way. It still runs on the Mac, with the conversation in the prompt.
    var richPrompt = false

    static let cloud = ModelProfile(contextTokens: 120_000, maxOutputTokens: 8_192, maxTools: 64, compactDescriptions: false, rounds: 10, isSmall: false)
    static let localLarge = ModelProfile(contextTokens: 16_384, maxOutputTokens: 1_200, maxTools: 14, compactDescriptions: true, rounds: 4, isSmall: true)
    static let localSmall = ModelProfile(contextTokens: 8_192, maxOutputTokens: 800, maxTools: 8, compactDescriptions: true, rounds: 3, isSmall: true)
    /// A compact model that is good with tools (Qwen 3, 4B): a few more tools and rounds, the same small window.
    static let localCompact = ModelProfile(contextTokens: 8_192, maxOutputTokens: 900, maxTools: 10, compactDescriptions: true, rounds: 4, isSmall: true)
    /// 12B and up: a larger window and more tools.
    static let localXL = ModelProfile(contextTokens: 24_576, maxOutputTokens: 1_500, maxTools: 18, compactDescriptions: true, rounds: 5, isSmall: true)
    /// Current small models (Qwen 3.5 4B): long native context and reliable tool calls, so a bigger window and more tools.
    static let localModernSmall = ModelProfile(contextTokens: 16_384, maxOutputTokens: 1_500, maxTools: 12, compactDescriptions: true, rounds: 5, isSmall: true)
    /// Current mid-size models (Qwen 3.5 9B, Gemma 4 12B, Qwen 3.6 27B): full tool descriptions, a 32k window, longer answers.
    static let localModern = ModelProfile(contextTokens: 32_768, maxOutputTokens: 2_500, maxTools: 20, compactDescriptions: false, rounds: 6, isSmall: true)
    /// Strong mixture-of-experts models (Qwen 3.6 35B-A3B, Gemma 4 26B-A4B): fast enough for the full prompt and tool set.
    static let localPro = ModelProfile(contextTokens: 32_768, maxOutputTokens: 4_096, maxTools: 40, compactDescriptions: false, rounds: 8,
                                       isSmall: true, richPrompt: true)

    /// Room for the answer when the model first reasons it out: reasoning takes tokens of its own.
    var thinkingOutputTokens: Int { min(max(maxOutputTokens * 3, 4_096), contextTokens / 2) }

    /// Rough token count (no tokenizer needed): about 3.5 characters per token for mixed Dutch/English text and JSON.
    static func estimateTokens(_ text: String) -> Int { (text.count * 2 + 6) / 7 }

    /// Characters of prompt that still fit after the answer and a margin.
    var promptCharacterBudget: Int { max(2_000, (contextTokens - maxOutputTokens - 256) * 7 / 2) }
}

/// Fits the parts of a prompt into a budget: parts with a lower priority are shortened first, and never below their minimum.
enum ContextBudget {
    struct Part {
        var text: String
        /// Higher is kept longer.
        var priority: Int
        /// Never cut below this many characters.
        var minimum: Int = 0
    }

    static func fit(_ parts: [Part], budget: Int) -> [String] {
        var texts = parts.map(\.text)
        var total = texts.reduce(0) { $0 + $1.count }
        guard total > budget else { return texts }
        for index in parts.indices.sorted(by: { parts[$0].priority < parts[$1].priority }) {
            guard total > budget else { break }
            let excess = total - budget
            let keep = max(parts[index].minimum, texts[index].count - excess)
            guard keep < texts[index].count else { continue }
            total -= texts[index].count - keep
            texts[index] = keep == 0 ? "" : String(texts[index].prefix(keep)) + "\n… (shortened)"
        }
        return texts
    }
}

/// A local model Nook can run itself with MLX.
struct LocalModelOption: Identifiable, Equatable {
    let id: String        // repository on Hugging Face
    let title: String
    let sizeGB: Double
    /// Below this much memory the model stalls the Mac.
    let minMemoryGB: Int
    /// Strength at choosing and filling in tools (higher is better); measured with the evaluation questions.
    let toolSkill: Int
    let profile: ModelProfile
    var family: ModelFamily = .other
    /// Can reason before answering (Qwen 3.5 / 3.6): Nook switches that on for hard questions only.
    var canThink = false

    /// The sampling the model makers recommend; far better than one setting for every model (greedy decoding makes
    /// small quantized models repeat themselves, too much randomness makes their tool calls sloppy).
    func sampling(thinking: Bool) -> ModelSampling { family.sampling(thinking: thinking) }
}

/// Sampling settings for one answer.
struct ModelSampling: Equatable {
    var temperature: Float
    var topP: Float
    var topK: Int
}

/// The family a model belongs to: decides sampling and how a turn ends.
enum ModelFamily: String, Equatable {
    case qwen, gemma4, llama, other

    func sampling(thinking: Bool) -> ModelSampling {
        switch self {
        // Qwen's own advice: 0.7 / 0.8 / 20 for direct answers, 0.6 / 0.95 / 20 when reasoning first.
        case .qwen: return thinking ? ModelSampling(temperature: 0.6, topP: 0.95, topK: 20) : ModelSampling(temperature: 0.7, topP: 0.8, topK: 20)
        // Gemma's own advice.
        case .gemma4: return ModelSampling(temperature: 1.0, topP: 0.95, topK: 64)
        case .llama: return ModelSampling(temperature: 0.6, topP: 0.9, topK: 0)
        case .other: return ModelSampling(temperature: 0.6, topP: 0.9, topK: 0)
        }
    }

    /// End-of-turn markers that are not always in the model's own configuration.
    var stopTokens: Set<String> {
        switch self {
        case .qwen: return ["<|im_end|>"]
        case .gemma4: return ["<turn|>"]
        case .llama: return ["<|eot_id|>"]
        case .other: return []
        }
    }
}

/// When a model that can reason should do so: only for questions where it pays off, because reasoning on a laptop takes
/// seconds. Greetings, lookups and simple actions are answered directly.
enum ThinkingPolicy {
    private static let cues = [
        "waarom", "why", "warum", "leg uit", "uitleg", "explain", "erkläre", "analyse", "analyze", "analyseer", "vergelijk",
        "compare", "vergleich", "bereken", "calculate", "berechne", "strategie", "strategy",
        "hoe kan ik", "how can i", "how do i", "wie kann ich", "wat is beter", "which is better", "pros and cons", "voor- en nadelen",
        "bewijs", "prove", "debug", "fout in", "bug", "algoritme", "algorithm", "stap voor stap", "step by step", "afweging", "advies", "advice"
    ]

    static func wantsThinking(_ question: String) -> Bool {
        let text = question.lowercased()
        if text.count > 280 { return true }
        if text.contains("```") { return true }
        return cues.contains { text.contains($0) }
    }

    /// The visible answer of a model that reasoned first. Qwen's template opens the reasoning itself, so the output often
    /// holds only its end ("…</think>"). While the reasoning is still running nothing is visible.
    static func answer(from output: String, thinking: Bool) -> String {
        var text = output.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
        if let close = text.range(of: "</think>", options: .backwards) {
            text = String(text[close.upperBound...])
        } else if thinking {
            return ""
        }
        if let open = text.range(of: "<think>") { text = String(text[..<open.lowerBound]) }
        return text
    }
}

/// A model served by Ollama or LM Studio on this Mac.
struct ServerModel: Equatable {
    enum Server: String { case ollama, lmstudio }
    var server: Server
    var name: String
}

/// Picks the best local model for this particular Mac, so every user gets a sensible default without having to know models.
///
/// The choice weighs, in order: what runs at all on this hardware, what is already on the Mac (no download needed),
/// and how good the model is at using tools — the thing Nook needs most.
enum ModelAdvisor {
    struct Hardware: Equatable {
        var memoryGB: Int
        var appleSilicon: Bool

        static var current: Hardware {
            #if arch(arm64)
            let arm = true
            #else
            let arm = false
            #endif
            return Hardware(memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824), appleSilicon: arm)
        }
    }

    /// Built-in choices (MLX, 4-bit), newest generation first. Qwen 3.5 / 3.6 are preferred for their reliable tool calling,
    /// long context and Dutch; the 35B-A3B model is a mixture of experts with 3B active parameters, so it answers about as
    /// fast as a 4B model on a Mac with enough memory. Gemma 4 is a strong alternative. Older models stay listed so an
    /// installed one keeps working; the advisor no longer proposes them.
    static let catalog: [LocalModelOption] = [
        LocalModelOption(id: "mlx-community/Qwen3.5-4B-4bit", title: "Qwen 3.5 (4B)", sizeGB: 3.1, minMemoryGB: 8, toolSkill: 6,
                         profile: .localModernSmall, family: .qwen, canThink: true),
        LocalModelOption(id: "mlx-community/Qwen3.5-9B-4bit", title: "Qwen 3.5 (9B)", sizeGB: 6.0, minMemoryGB: 16, toolSkill: 8,
                         profile: .localModern, family: .qwen, canThink: true),
        LocalModelOption(id: "mlx-community/gemma-4-12B-it-4bit", title: "Gemma 4 (12B)", sizeGB: 6.8, minMemoryGB: 16, toolSkill: 7,
                         profile: .localModern, family: .gemma4),
        LocalModelOption(id: "mlx-community/Qwen3.6-27B-4bit", title: "Qwen 3.6 (27B)", sizeGB: 16.1, minMemoryGB: 32, toolSkill: 9,
                         profile: .localModern, family: .qwen, canThink: true),
        LocalModelOption(id: "mlx-community/gemma-4-26b-a4b-it-4bit", title: "Gemma 4 (26B-A4B)", sizeGB: 15.4, minMemoryGB: 32, toolSkill: 8,
                         profile: .localPro, family: .gemma4),
        LocalModelOption(id: "mlx-community/Qwen3.6-35B-A3B-4bit", title: "Qwen 3.6 (35B-A3B)", sizeGB: 20.4, minMemoryGB: 36, toolSkill: 10,
                         profile: .localPro, family: .qwen, canThink: true),
        LocalModelOption(id: "mlx-community/Qwen3-4B-Instruct-2507-4bit", title: "Qwen 3 (4B)", sizeGB: 2.3, minMemoryGB: 8, toolSkill: 4,
                         profile: .localCompact, family: .qwen),
        LocalModelOption(id: "mlx-community/Qwen3-8B-4bit", title: "Qwen 3 (8B)", sizeGB: 4.6, minMemoryGB: 16, toolSkill: 5, profile: .localLarge, family: .qwen),
        LocalModelOption(id: "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit", title: "Qwen 3 (30B-A3B)", sizeGB: 17.2, minMemoryGB: 32, toolSkill: 7,
                         profile: ModelProfile(contextTokens: 24_576, maxOutputTokens: 2_000, maxTools: 24, compactDescriptions: false, rounds: 6, isSmall: true),
                         family: .qwen),
        LocalModelOption(id: "mlx-community/Qwen2.5-3B-Instruct-4bit", title: "Qwen 2.5 (3B)", sizeGB: 1.9, minMemoryGB: 8, toolSkill: 2, profile: .localSmall, family: .qwen),
        LocalModelOption(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", title: "Llama 3.2 (3B)", sizeGB: 1.8, minMemoryGB: 8, toolSkill: 1, profile: .localSmall, family: .llama),
        LocalModelOption(id: "mlx-community/Qwen2.5-7B-Instruct-4bit", title: "Qwen 2.5 (7B)", sizeGB: 4.3, minMemoryGB: 16, toolSkill: 3, profile: .localLarge, family: .qwen),
        LocalModelOption(id: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit", title: "Llama 3.1 (8B)", sizeGB: 4.5, minMemoryGB: 16, toolSkill: 3, profile: .localLarge, family: .llama),
        LocalModelOption(id: "mlx-community/Qwen2.5-14B-Instruct-4bit", title: "Qwen 2.5 (14B)", sizeGB: 8.3, minMemoryGB: 32, toolSkill: 4, profile: .localXL, family: .qwen)
    ]

    struct Recommendation: Equatable {
        enum Choice: Equatable {
            case mlx(LocalModelOption)
            case server(ServerModel)
            /// Nothing local runs well here; explain why.
            case unavailable
        }
        var choice: Choice
        /// Already on this Mac: usable right away.
        var ready: Bool
        /// One sentence for the user.
        var reason: String
    }

    /// Ranked, best first. The first entry is what Nook proposes.
    static func recommend(hardware: Hardware, installedMLX: Set<String>, serverModels: [ServerModel]) -> [Recommendation] {
        var result: [Recommendation] = []
        let fitting = hardware.appleSilicon ? catalog.filter { $0.minMemoryGB <= hardware.memoryGB } : []
        // Leave room for the user's own apps: on the smallest Macs prefer the lightest model.
        let best = fitting.sorted { ($0.toolSkill, -$0.sizeGB) > ($1.toolSkill, -$1.sizeGB) }

        let installed = best.filter { installedMLX.contains($0.id) }
        let usableServer = serverModels.sorted { serverScore($0.name, memory: hardware.memoryGB) > serverScore($1.name, memory: hardware.memoryGB) }
            .filter { serverScore($0.name, memory: hardware.memoryGB) > 0 }

        // 1. The best model that fits, if it is already installed.
        if let top = best.first, installed.first == top {
            result.append(Recommendation(choice: .mlx(top), ready: true, reason: "Best fit for \(hardware.memoryGB) GB and already on your Mac."))
        }
        // 2. A good model already served by Ollama / LM Studio: no download.
        if let server = usableServer.first {
            result.append(Recommendation(choice: .server(server), ready: true,
                                         reason: "Already available in \(server.server == .ollama ? "Ollama" : "LM Studio"), no download needed."))
        }
        // 3. The best fitting built-in model (download once).
        if let top = best.first, !result.contains(where: { $0.choice == .mlx(top) }) {
            result.append(Recommendation(choice: .mlx(top), ready: installedMLX.contains(top.id),
                                         reason: "Best balance of quality and speed for \(hardware.memoryGB) GB memory (download of ±\(formatted(top.sizeGB)) GB, once)."))
        }
        // 4. Other installed models, then the remaining fitting ones.
        for option in installed where !result.contains(where: { $0.choice == .mlx(option) }) {
            result.append(Recommendation(choice: .mlx(option), ready: true, reason: "Already on your Mac."))
        }
        for server in usableServer.dropFirst() {
            result.append(Recommendation(choice: .server(server), ready: true, reason: "Available in \(server.server == .ollama ? "Ollama" : "LM Studio")."))
        }
        for option in best where !result.contains(where: { $0.choice == .mlx(option) }) {
            result.append(Recommendation(choice: .mlx(option), ready: false, reason: "Download of ±\(formatted(option.sizeGB)) GB."))
        }
        if result.isEmpty {
            let reason = hardware.appleSilicon
                ? "This Mac has too little memory for a local model. Install Ollama with a small model, or choose an external AI."
                : "The built-in model needs Apple Silicon. Install Ollama or LM Studio to think locally, or choose an external AI."
            result.append(Recommendation(choice: .unavailable, ready: false, reason: reason))
        }
        return result
    }

    /// Profile for a model served by Ollama or LM Studio, from its name (size hints like "7b", "14b").
    static func profile(forServerModel name: String) -> ModelProfile {
        let size = parameterBillions(name) ?? 3
        if size >= 12 { return .localXL }
        return size >= 6 ? .localLarge : .localSmall
    }

    /// How suitable a server model is: families known for tool calling score higher; too large for memory scores zero.
    static func serverScore(_ name: String, memory: Int) -> Int {
        let lower = name.lowercased()
        if lower.contains("embed") || lower.contains("whisper") || lower.contains("vision") && !lower.contains("instruct") { return 0 }
        let size = parameterBillions(lower) ?? 4
        // 4-bit weights take about 0.6 GB per billion parameters; keep half the memory free for the Mac.
        if Double(size) * 0.6 > Double(memory) / 2 { return 0 }
        var score = 1
        if lower.contains("qwen") { score += 3 }
        if lower.contains("llama3") || lower.contains("llama-3") || lower.contains("mistral") || lower.contains("gemma3") || lower.contains("gemma-3") { score += 2 }
        if lower.contains("instruct") || lower.contains("chat") || !lower.contains("base") { score += 1 }
        score += min(size, 14) / 4
        return score
    }

    static func parameterBillions(_ name: String) -> Int? {
        guard let range = name.lowercased().range(of: #"(\d+(?:\.\d+)?)b\b"#, options: .regularExpression) else { return nil }
        return Double(name.lowercased()[range].dropLast()).map { Int($0.rounded()) }
    }

    private static func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
