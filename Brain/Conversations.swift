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

        // Stream tokens in real time via SSE when onText is provided; fall back to standard POST if a server does not support SSE.
        if onText != nil {
            var streamBody = body
            streamBody["stream"] = true
            if let turn = try? await streamNext(url: url, body: streamBody, onText: onText) {
                return turn
            }
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

    private func streamNext(url: URL, body: [String: Any], onText: ((String) -> Void)?) async throws -> ModelTurn {
        let lines = try await LocalHTTP.stream(url, body: body, key: key, provider: provider, model: model)
        var text = ""
        struct PartialToolCall {
            var id: String = ""
            var name: String = ""
            var arguments: String = ""
        }
        var toolAcc: [Int: PartialToolCall] = [:]
        var received = false
        var lastEmit = Date.distantPast

        for try await rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix(":") else { continue }
            let payload: String
            if trimmed.hasPrefix("data:") {
                payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("{") {
                payload = trimmed
            } else {
                continue
            }
            if payload == "[DONE]" { break }
            guard let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
            if let err = (object["error"] as? [String: Any])?["message"] as? String {
                throw NookError("\(provider.title): \(err)")
            }
            guard let choice = (object["choices"] as? [[String: Any]])?.first else { continue }
            received = true

            // Handle both streamed `delta` chunks and non-streamed `message` responses.
            if let delta = choice["delta"] as? [String: Any] {
                if let piece = delta["content"] as? String, !piece.isEmpty {
                    text += piece
                    if let onText, Date().timeIntervalSince(lastEmit) > 0.04 {
                        lastEmit = Date()
                        let visible = EmbeddedModel.visible(text)
                        if !visible.isEmpty { onText(visible) }
                    }
                }
                if let deltaCalls = delta["tool_calls"] as? [[String: Any]] {
                    for dc in deltaCalls {
                        let idx = (dc["index"] as? Int) ?? 0
                        var entry = toolAcc[idx] ?? PartialToolCall()
                        if let id = dc["id"] as? String, !id.isEmpty { entry.id = id }
                        if let fn = dc["function"] as? [String: Any] {
                            if let name = fn["name"] as? String, !name.isEmpty { entry.name += name }
                            if let args = fn["arguments"] as? String { entry.arguments += args }
                        }
                        toolAcc[idx] = entry
                    }
                }
            } else if let message = choice["message"] as? [String: Any] {
                text += (message["content"] as? String) ?? ""
                if let rawCalls = message["tool_calls"] as? [[String: Any]] {
                    for (idx, rc) in rawCalls.enumerated() {
                        let fn = (rc["function"] as? [String: Any]) ?? [:]
                        toolAcc[idx] = PartialToolCall(
                            id: (rc["id"] as? String) ?? UUID().uuidString,
                            name: (fn["name"] as? String) ?? "",
                            arguments: (fn["arguments"] as? String) ?? "{}"
                        )
                    }
                }
            }
        }

        guard received else { throw NookError("Empty stream") }
        let visible = EmbeddedModel.visible(text)
        if !visible.isEmpty { onText?(visible) }

        let sortedIndices = toolAcc.keys.sorted()
        guard !sortedIndices.isEmpty else { return ModelTurn(text: text, calls: []) }

        var rawCalls: [[String: Any]] = []
        var calls: [ToolCallRequest] = []
        for idx in sortedIndices {
            guard let item = toolAcc[idx], !item.name.isEmpty else { continue }
            let callID = item.id.isEmpty ? UUID().uuidString : item.id
            let argsString = item.arguments.isEmpty ? "{}" : item.arguments
            rawCalls.append([
                "id": callID,
                "type": "function",
                "function": ["name": item.name, "arguments": argsString]
            ])
            let input = (try? JSONSerialization.jsonObject(with: Data(argsString.utf8))) as? [String: Any] ?? [:]
            calls.append(ToolCallRequest(id: callID, name: item.name, input: input))
        }
        guard !calls.isEmpty else { return ModelTurn(text: text, calls: []) }
        var assistantMsg: [String: Any] = ["role": "assistant", "tool_calls": rawCalls]
        if !text.isEmpty { assistantMsg["content"] = text }
        messages.append(assistantMsg)
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
            // Streamed, so the answer appears while it is written instead of after the whole answer is done.
            "stream": true,
            "options": ["num_ctx": profile.contextTokens, "num_predict": profile.maxOutputTokens, "temperature": 0.2]
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]] }
        }
        let lines = try await LocalHTTP.stream(url, body: body, provider: .ollama, model: model)
        var text = ""
        var rawCalls: [[String: Any]] = []
        var received = false
        var lastEmit = Date.distantPast
        for try await line in lines {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if let error = object["error"] as? String { throw NookError("Ollama: \(error)") }
            guard let message = object["message"] as? [String: Any] else { continue }
            received = true
            text += (message["content"] as? String) ?? ""
            rawCalls += (message["tool_calls"] as? [[String: Any]]) ?? []
            if let onText, Date().timeIntervalSince(lastEmit) > 0.05 {
                lastEmit = Date()
                let visible = EmbeddedModel.visible(text)
                if !visible.isEmpty { onText(visible) }
            }
        }
        guard received else { throw NookError("Unexpected response from Ollama.") }
        let visible = EmbeddedModel.visible(text)
        if !visible.isEmpty { onText?(visible) }
        guard !rawCalls.isEmpty else { return ModelTurn(text: text, calls: []) }
        messages.append(["role": "assistant", "content": text, "tool_calls": rawCalls])
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
        let request = try self.request(url, body: body, key: key, provider: provider)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw connectionError(error, provider: provider)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else { throw statusError(status, object: object, provider: provider, model: model) }
        return object
    }

    /// The same request, streamed: the response arrives line by line (Ollama sends one JSON object per line, OpenAI sends SSE `data:` lines).
    static func stream(_ url: URL, body: [String: Any], key: String? = nil, provider: AIProvider, model: String) async throws -> AsyncLineSequence<URLSession.AsyncBytes> {
        let request = try self.request(url, body: body, key: key, provider: provider)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let error as URLError {
            throw connectionError(error, provider: provider)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var raw = ""
            for try await line in bytes.lines { raw += line }
            let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
            throw statusError(status, object: object, provider: provider, model: model)
        }
        return bytes.lines
    }

    private static func request(_ url: URL, body: [String: Any], key: String?, provider: AIProvider) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = provider.isLocalServer ? 180 : 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func connectionError(_ error: URLError, provider: AIProvider) -> Error {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            if provider.isLocalServer { return NookError(tr("brain.unavailable.server", provider.title)) }
            return NookError("Cannot reach \(provider.title).")
        case .timedOut:
            return NookError(provider.isLocalServer
                ? "\(provider.title) took too long. A smaller model answers faster; choose one in Settings › Brain."
                : "\(provider.title) did not answer in time.")
        default:
            return error
        }
    }

    private static func statusError(_ status: Int, object: [String: Any], provider: AIProvider, model: String) -> NookError {
        let message = ((object["error"] as? [String: Any])?["message"] as? String) ?? (object["error"] as? String) ?? "status \(status)"
        switch status {
        case 401, 403: return NookError("\(provider.title) rejected the API key: \(message)")
        case 404: return NookError("Model \(model) was not found on \(provider.title). Select a different model in Settings › Brain.")
        case 429: return NookError("Rate limit reached on \(provider.title). Please wait a moment.")
        default: return NookError("\(provider.title): \(message)")
        }
    }
}
