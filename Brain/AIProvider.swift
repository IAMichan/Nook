import Foundation

/// Met wie Nook denkt. Claude is de standaard; de andere aanbieders praten allemaal het OpenAI-protocol
/// (chat/completions met function calling), dus één client dekt ze allemaal. Ollama en LM Studio draaien op je eigen Mac.
enum AIProvider: String, CaseIterable, Identifiable {
    case claude, claudeCode, openai, gemini, grok, mistral, groq, openrouter, deepseek, qwen, moonshot, ollama, lmstudio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .claudeCode: return "Claude Code (je abonnement)"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .grok: return "Grok (xAI)"
        case .mistral: return "Mistral"
        case .groq: return "Groq"
        case .openrouter: return "OpenRouter (alle modellen)"
        case .deepseek: return "DeepSeek"
        case .qwen: return "Qwen"
        case .moonshot: return "Moonshot (Kimi)"
        case .ollama: return "Ollama (op je Mac)"
        case .lmstudio: return "LM Studio (op je Mac)"
        }
    }

    /// Draait op je eigen Mac; geen sleutel nodig.
    var isLocalServer: Bool { self == .ollama || self == .lmstudio }
    var needsKey: Bool { !isLocalServer && self != .claudeCode }

    var keyAccount: String { self == .claude ? "anthropic-api-key" : "\(rawValue)-api-key" }

    var keyPlaceholder: String {
        switch self {
        case .claude: return "Anthropic API-sleutel (sk-ant-…)"
        case .openai: return "OpenAI API-sleutel (sk-…)"
        case .gemini: return "Google AI Studio-sleutel"
        case .grok: return "xAI API-sleutel (xai-…)"
        case .mistral: return "Mistral API-sleutel"
        case .groq: return "Groq API-sleutel (gsk_…)"
        case .openrouter: return "OpenRouter-sleutel (sk-or-…)"
        case .deepseek: return "DeepSeek API-sleutel"
        case .qwen: return "DashScope API-sleutel"
        case .moonshot: return "Moonshot API-sleutel"
        case .ollama, .lmstudio, .claudeCode: return ""
        }
    }

    var keyURL: URL? {
        switch self {
        case .claude: return URL(string: "https://console.anthropic.com/settings/keys")
        case .claudeCode: return URL(string: "https://claude.com/product/claude-code")
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .grok: return URL(string: "https://console.x.ai")
        case .mistral: return URL(string: "https://console.mistral.ai/api-keys")
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .openrouter: return URL(string: "https://openrouter.ai/settings/keys")
        case .deepseek: return URL(string: "https://platform.deepseek.com/api_keys")
        case .qwen: return URL(string: "https://dashscope.console.aliyun.com/apiKey")
        case .moonshot: return URL(string: "https://platform.moonshot.ai/console/api-keys")
        case .ollama: return URL(string: "https://ollama.com/download")
        case .lmstudio: return URL(string: "https://lmstudio.ai")
        }
    }

    /// Basisadres van de OpenAI-compatibele API (niet voor Claude).
    var baseURL: String {
        switch self {
        case .claude, .claudeCode: return "https://api.anthropic.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .grok: return "https://api.x.ai/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .qwen: return "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        case .moonshot: return "https://api.moonshot.ai/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .lmstudio: return "http://localhost:1234/v1"
        }
    }

    /// Een snel model als startpunt. Met "Haal modellen op" kies je uit wat jouw sleutel echt kan.
    var defaultModel: String {
        switch self {
        case .claude: return "claude-haiku-5-5"
        case .claudeCode: return "haiku"
        case .openai: return "gpt-4.1-mini"
        case .gemini: return "gemini-2.5-flash"
        case .grok: return "grok-3-mini"
        case .mistral: return "mistral-small-latest"
        case .groq: return "llama-3.3-70b-versatile"
        case .openrouter: return "openrouter/auto"
        case .deepseek: return "deepseek-chat"
        case .qwen: return "qwen-plus"
        case .moonshot: return "kimi-k2-turbo-preview"
        case .ollama: return "llama3.2"
        case .lmstudio: return ""
        }
    }

    /// Bekende modellen om meteen uit te kiezen.
    var suggestedModels: [String] {
        switch self {
        case .claude: return ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"]
        case .claudeCode: return ["haiku", "sonnet", "opus"]
        case .openai: return ["gpt-4.1-mini", "gpt-4.1", "gpt-4o-mini"]
        case .gemini: return ["gemini-2.5-flash", "gemini-2.5-pro"]
        case .grok: return ["grok-3-mini", "grok-3", "grok-4"]
        case .mistral: return ["mistral-small-latest", "mistral-medium-latest", "mistral-large-latest"]
        case .groq: return ["llama-3.3-70b-versatile", "llama-3.1-8b-instant"]
        case .openrouter: return ["openrouter/auto", "anthropic/claude-sonnet-4", "google/gemini-2.5-flash", "x-ai/grok-3-mini"]
        case .deepseek: return ["deepseek-chat", "deepseek-reasoner"]
        case .qwen: return ["qwen-plus", "qwen-max", "qwen-turbo"]
        case .moonshot: return ["kimi-k2-turbo-preview", "moonshot-v1-8k"]
        case .ollama, .lmstudio: return []
        }
    }

    /// Haalt de modellen op die deze aanbieder voor jouw sleutel heeft.
    func listModels(key: String?) async throws -> [String] {
        if self == .claudeCode { return suggestedModels }
        guard let url = URL(string: baseURL + "/models" + (self == .claude ? "?limit=100" : "")) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        if self == .claude {
            request.setValue(key ?? "", forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if let key, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if isLocalServer { throw NookError("\(title) reageert niet. Draait de server?") }
            throw NookError("\(title) gaf status \(status). Klopt de sleutel?")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let list = (object["data"] as? [[String: Any]]) ?? (object["models"] as? [[String: Any]]) ?? []
        return list.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
            .map { $0.replacingOccurrences(of: "models/", with: "") }
            .sorted()
    }
}

/// Eén client voor alle OpenAI-compatibele aanbieders, met tools (function calling).
/// Lees-tools draaien meteen, actie-tools worden alleen voorgesteld: precies zoals bij Claude.
@MainActor
enum OpenAICompatibleBrain {
    static func run(
        provider: AIProvider,
        model: String,
        key: String?,
        system: String,
        history: [ChatTurn] = [],
        prompt: String,
        tools: [ToolSpec],
        onText: ((String) -> Void)?
    ) async throws -> BrainPlan {
        guard let url = URL(string: provider.baseURL + "/chat/completions") else {
            throw NookError("Ongeldig adres voor \(provider.title).")
        }
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        messages += BrainService.alternating(history, then: prompt).map { ["role": $0.role, "content": $0.text] }
        let definitions: [[String: Any]] = tools.map {
            ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]]
        }
        var actions: [PlannedAction] = []
        var finalText = ""

        for _ in 0..<6 {
            var body: [String: Any] = ["model": model, "messages": messages, "temperature": 0.3]
            if !definitions.isEmpty { body["tools"] = definitions }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = provider.isLocalServer ? 120 : 60
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .cannotFindHost {
                if provider.isLocalServer {
                    throw NookError("\(provider.title) draait niet. Start de app en laad een model.")
                }
                throw NookError("Kan \(provider.title) niet bereiken.")
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard (200..<300).contains(status) else {
                let message = ((object["error"] as? [String: Any])?["message"] as? String) ?? "status \(status)"
                switch status {
                case 401, 403: throw NookError("\(provider.title) weigerde de sleutel: \(message)")
                case 404: throw NookError("Het model \(model) bestaat niet bij \(provider.title). Kies een ander model bij Instellingen.")
                case 429: throw NookError("Limiet bereikt bij \(provider.title). Wacht even.")
                default: throw NookError("\(provider.title): \(message)")
                }
            }
            guard let choice = (object["choices"] as? [[String: Any]])?.first,
                  let message = choice["message"] as? [String: Any] else {
                throw NookError("Onverwacht antwoord van \(provider.title).")
            }
            let text = (message["content"] as? String) ?? ""
            if !text.isEmpty {
                finalText = text
                onText?(text)
            }
            let calls = (message["tool_calls"] as? [[String: Any]]) ?? []
            guard !calls.isEmpty else { break }

            messages.append(message)
            for call in calls {
                let id = (call["id"] as? String) ?? UUID().uuidString
                let function = (call["function"] as? [String: Any]) ?? [:]
                let name = (function["name"] as? String) ?? ""
                let rawArguments = (function["arguments"] as? String) ?? "{}"
                let input = (try? JSONSerialization.jsonObject(with: Data(rawArguments.utf8))) as? [String: Any] ?? [:]
                var content: String
                if let spec = tools.first(where: { $0.name == name }) {
                    switch spec.kind {
                    case .read:
                        do {
                            let output = try await spec.run(input)
                            content = UntrustedText.wrap(output)
                        } catch { content = "Fout: \(error.localizedDescription)" }
                    case .action:
                        actions.append(PlannedAction(tool: name, input: input))
                        content = "Voorgesteld aan de gebruiker. Wordt pas uitgevoerd na bevestiging."
                    }
                } else {
                    content = "Onbekende tool."
                }
                messages.append(["role": "tool", "tool_call_id": id, "content": content])
            }
        }
        return BrainPlan(text: finalText.trimmingCharacters(in: .whitespacesAndNewlines), actions: actions)
    }
}
