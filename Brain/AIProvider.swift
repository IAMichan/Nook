import Foundation

/// The brain provider Nook reasons with. Claude is default; other providers speak the OpenAI protocol
/// (chat/completions with function calling), so a single client covers them all. Ollama and LM Studio run locally on your Mac.
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

    /// Runs locally on your Mac; no API key needed.
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

    /// Base URL for the OpenAI-compatible API (not used for Claude Anthropic API).
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

    /// A fast starter model. Use "Fetch models" to choose from what your key can access.
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

    /// Well-known models available for quick selection.
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

    /// Fetches the models this provider offers for the provided key.
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
            if isLocalServer { throw NookError("\(title) does not respond. Is the server running?") }
            throw NookError("\(title) returned status \(status). Is the API key valid?")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let list = (object["data"] as? [[String: Any]]) ?? (object["models"] as? [[String: Any]]) ?? []
        return list.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
            .map { $0.replacingOccurrences(of: "models/", with: "") }
            .sorted()
    }
}
