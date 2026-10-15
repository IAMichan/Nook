import Foundation

// One adapter per provider. Each keeps its own message format; the shared `ToolRunner` drives them all the same way.

/// Claude through the Anthropic Messages API: streaming, prompt caching, server-side web search.
@MainActor
final class AnthropicConversation: ModelConversation {
    typealias Stream = (_ body: [String: Any], _ onText: @escaping (String) -> Void) async throws -> [String: Any]

    private var messages: [[String: Any]]
    private let system: [[String: Any]]
    private let model: String
    private let webSearchTool: [String: Any]?
    private let maxTokens: Int
    private let stream: Stream

    init(model: String, system: String, history: [ChatTurn], prompt: String, webSearchTool: [String: Any]?, maxTokens: Int, stream: @escaping Stream) {
        self.model = model
        self.system = [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]]
        self.messages = BrainService.alternating(history, then: prompt).map { ["role": $0.role, "content": $0.text] }
        self.webSearchTool = webSearchTool
        self.maxTokens = maxTokens
        self.stream = stream
    }

    func next(tools: [LoopTool], onText: ((String) -> Void)?) async throws -> ModelTurn {
        var definitions: [[String: Any]] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] }
        if let webSearchTool { definitions.append(webSearchTool) }
        // Prompt caching: tools and system prompt do not need to be processed again on follow-ups.
        if !definitions.isEmpty { definitions[definitions.count - 1]["cache_control"] = ["type": "ephemeral"] }

        var text = ""
        while true {
            var body: [String: Any] = ["model": model, "max_tokens": maxTokens, "system": system, "messages": messages, "stream": true]
            BrainService.applySpeed(to: &body, model: model)
            if !definitions.isEmpty { body["tools"] = definitions }
            let before = text.isEmpty ? "" : text + "\n\n"
            let response = try await stream(body) { partial in onText?(before + partial) }
            guard let blocks = response["content"] as? [[String: Any]] else { throw NookError("Unexpected response from the model.") }
            let roundText = blocks.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
            if !roundText.isEmpty { text = before + roundText }

            let stopReason = response["stop_reason"] as? String
            // Long web searches are sometimes paused by the API: continue with the same messages.
            if stopReason == "pause_turn" {
                messages.append(["role": "assistant", "content": BrainService.passBack(blocks)])
                continue
            }
            if stopReason == "refusal", text.isEmpty { text = "I cannot help you with that." }
            let uses = blocks.filter { ($0["type"] as? String) == "tool_use" }
            guard stopReason == "tool_use", !uses.isEmpty else { return ModelTurn(text: text, calls: [], finished: true) }
            messages.append(["role": "assistant", "content": BrainService.passBack(blocks)])
            let calls = uses.map { use in
                ToolCallRequest(id: (use["id"] as? String) ?? UUID().uuidString, name: (use["name"] as? String) ?? "",
                                input: (use["input"] as? [String: Any]) ?? [:])
            }
            return ModelTurn(text: text, calls: calls)
        }
    }

    func addResults(_ results: [(call: ToolCallRequest, output: String, isError: Bool)]) {
        let content: [[String: Any]] = results.map { result in
            var block: [String: Any] = ["type": "tool_result", "tool_use_id": result.call.id, "content": result.output]
            if result.isError { block["is_error"] = true }
            return block
        }
        messages.append(["role": "user", "content": content])
    }

    func addInstruction(_ text: String) {
        if var last = messages.last, (last["role"] as? String) == "user", var content = last["content"] as? [[String: Any]] {
            content.append(["type": "text", "text": text])
            last["content"] = content
            messages[messages.count - 1] = last
        } else {
            messages.append(["role": "user", "content": text])
        }
    }
}

/// Every provider with an OpenAI-compatible `/chat/completions` endpoint (OpenAI, Gemini, Grok, Mistral, LM Studio…).
@MainActor
final class OpenAIConversation: ModelConversation {
    private var messages: [[String: Any]]
    private let provider: AIProvider
    private let model: String
    private let key: String?
    private let maxTokens: Int?

    init(provider: AIProvider, model: String, key: String?, system: String, history: [ChatTurn], prompt: String, maxTokens: Int?) {
        self.provider = provider
        self.model = model
        self.key = key
        self.maxTokens = maxTokens
        self.messages = [["role": "system", "content": system]]
            + BrainService.alternating(history, then: prompt).map { ["role": $0.role, "content": $0.text] }
    }

    func next(tools: [LoopTool], onText: ((String) -> Void)?) async throws -> ModelTurn {
        guard let url = URL(string: provider.baseURL + "/chat/completions") else {
            throw NookError("Invalid endpoint URL for \(provider.title).")
        }
        var body: [String: Any] = ["model": model, "messages": messages, "temperature": provider.isLocalServer ? 0.2 : 0.3]
        if let maxTokens { body["max_tokens"] = maxTokens }
        if !tools.isEmpty {
            body["tools"] = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]] }
        }
        let object = try await LocalHTTP.post(url, body: body, key: key, provider: provider, model: model)
        guard let choice = (object["choices"] as? [[String: Any]])?.first, let message = choice["message"] as? [String: Any] else {
            throw NookError("Unexpected response from \(provider.title).")
        }
        let text = (message["content"] as? String) ?? ""
        if !text.isEmpty { onText?(text) }
        let rawCalls = (message["tool_calls"] as? [[String: Any]]) ?? []
        guard !rawCalls.isEmpty else { return ModelTurn(text: text, calls: []) }
        messages.append(message)
        let calls = rawCalls.map { call -> ToolCallRequest in
            let function = (call["function"] as? [String: Any]) ?? [:]
            let raw = (function["arguments"] as? String) ?? "{}"
            let input = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
                ?? (function["arguments"] as? [String: Any]) ?? [:]
            return ToolCallRequest(id: (call["id"] as? String) ?? UUID().uuidString, name: (function["name"] as? String) ?? "", input: input)
        }
        return ModelTurn(text: text, calls: calls)
    }

    func addResults(_ results: [(call: ToolCallRequest, output: String, isError: Bool)]) {
        for result in results {
            messages.append(["role": "tool", "tool_call_id": result.call.id, "content": result.output])
        }
    }

    func addInstruction(_ text: String) {
        messages.append(["role": "user", "content": text])
    }
}

/// Ollama through its own `/api/chat`, so the context window can be set (`num_ctx`): its default is small and would
/// silently cut off Nook's prompt.
@MainActor
final class OllamaConversation: ModelConversation {
    private var messages: [[String: Any]]
    private let model: String
    private let profile: ModelProfile

    init(model: String, system: String, history: [ChatTurn], prompt: String, profile: ModelProfile) {
        self.model = model
        self.profile = profile
        self.messages = [["role": "system", "content": system]]
            + BrainService.alternating(history, then: prompt).map { ["role": $0.role, "content": $0.text] }
    }

    nonisolated static var baseURL: String { AIProvider.ollama.baseURL.replacingOccurrences(of: "/v1", with: "") }

    func next(tools: [LoopTool], onText: ((String) -> Void)?) async throws -> ModelTurn {
        guard let url = URL(string: Self.baseURL + "/api/chat") else { throw NookError("Invalid Ollama address.") }
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false,
            "options": ["num_ctx": profile.contextTokens, "num_predict": profile.maxOutputTokens, "temperature": 0.2]
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]] }
        }
        let object = try await LocalHTTP.post(url, body: body, key: nil, provider: .ollama, model: model)
        guard let message = object["message"] as? [String: Any] else { throw NookError("Unexpected response from Ollama.") }
        let text = (message["content"] as? String) ?? ""
        if !text.isEmpty { onText?(text) }
        let rawCalls = (message["tool_calls"] as? [[String: Any]]) ?? []
        guard !rawCalls.isEmpty else { return ModelTurn(text: text, calls: []) }
        messages.append(message)
        let calls = rawCalls.map { call -> ToolCallRequest in
            let function = (call["function"] as? [String: Any]) ?? [:]
            var input = (function["arguments"] as? [String: Any]) ?? [:]
            if input.isEmpty, let raw = function["arguments"] as? String {
                input = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
            }
            return ToolCallRequest(id: UUID().uuidString, name: (function["name"] as? String) ?? "", input: input)
        }
        return ModelTurn(text: text, calls: calls)
    }

    func addResults(_ results: [(call: ToolCallRequest, output: String, isError: Bool)]) {
        for result in results {
            messages.append(["role": "tool", "tool_name": result.call.name, "content": result.output])
        }
    }

    func addInstruction(_ text: String) {
        messages.append(["role": "user", "content": text])
    }
}

/// JSON POST with the error messages users need (server not running, wrong key, unknown model).
enum LocalHTTP {
    static func post(_ url: URL, body: [String: Any], key: String?, provider: AIProvider, model: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = provider.isLocalServer ? 180 : 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(error.code) {
            if provider.isLocalServer { throw NookError(tr("brain.unavailable.server", provider.title)) }
            throw NookError("Cannot reach \(provider.title).")
        } catch let error as URLError where error.code == .timedOut {
            throw NookError(provider.isLocalServer
                ? "\(provider.title) took too long. A smaller model answers faster; choose one in Settings › Brain."
                : "\(provider.title) did not answer in time.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let message = ((object["error"] as? [String: Any])?["message"] as? String) ?? (object["error"] as? String) ?? "status \(status)"
            switch status {
            case 401, 403: throw NookError("\(provider.title) rejected the API key: \(message)")
            case 404: throw NookError("Model \(model) was not found on \(provider.title). Select a different model in Settings › Brain.")
            case 429: throw NookError("Rate limit reached on \(provider.title). Please wait a moment.")
            default: throw NookError("\(provider.title): \(message)")
            }
        }
        return object
    }
}
