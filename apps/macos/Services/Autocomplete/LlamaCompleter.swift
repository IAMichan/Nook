import Foundation
import LlamaSwift

/// Lets a running completion be stopped from outside, as soon as the text it was made for has changed.
final class CompletionCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

/// Runs a GGUF model through llama.cpp (Metal on Apple Silicon) and continues a piece of text with a few words.
///
/// llama.cpp's contexts are not thread-safe, so every call runs on one serial queue. The prompt of the previous call stays in
/// the model's cache: typing one more letter only has to read that letter, which keeps a suggestion fast.
final class LlamaCompleter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "nl.imdigital.nook.autocomplete", qos: .userInitiated)
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let contextSize: Int
    /// What the model's cache holds now: the prompt of the last call and the words it generated.
    private var cached: [llama_token] = []

    let path: String

    private static let backendReady: Void = {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    private init(path: String, model: OpaquePointer, context: OpaquePointer, contextSize: Int) {
        self.path = path
        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
        self.contextSize = contextSize
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    /// Loads the model (a second or two for a small one) off the main thread.
    static func load(path: String, contextSize: Int = 1_024) async throws -> LlamaCompleter {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = backendReady
                var modelParams = llama_model_default_params()
                modelParams.n_gpu_layers = 99
                guard let model = llama_model_load_from_file(path, modelParams) else {
                    continuation.resume(throwing: NookError("The model file could not be loaded. It may not be a GGUF model that llama.cpp supports."))
                    return
                }
                var params = llama_context_default_params()
                params.n_ctx = UInt32(contextSize)
                params.n_batch = UInt32(contextSize)
                params.no_perf = true
                let threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
                params.n_threads = threads
                params.n_threads_batch = threads
                guard let context = llama_init_from_model(model, params) else {
                    llama_model_free(model)
                    continuation.resume(throwing: NookError("The model loaded, but there is not enough memory to run it."))
                    return
                }
                continuation.resume(returning: LlamaCompleter(path: path, model: model, context: context, contextSize: contextSize))
            }
        }
    }

    /// Continues `prompt` with at most `maxTokens` tokens, stopping at the end of the line. Greedy, so the same text always
    /// gets the same suggestion.
    func complete(prompt: String, maxTokens: Int, cancel: CompletionCancel) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.run(prompt: prompt, maxTokens: maxTokens, cancel: cancel))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func run(prompt: String, maxTokens: Int, cancel: CompletionCancel) throws -> String {
        if cancel.isCancelled { return "" }
        var tokens = tokenize(prompt)
        let budget = max(16, contextSize - maxTokens - 1)
        if tokens.count > budget { tokens = Array(tokens.suffix(budget)) }
        guard !tokens.isEmpty else { return "" }

        let memory = llama_get_memory(context)
        // Keep what the cache already has of this prompt; read only the rest. At least one token must be read for the logits.
        var shared = zip(cached, tokens).prefix { $0 == $1 }.count
        if shared == tokens.count { shared -= 1 }
        if shared > 0, !llama_memory_seq_rm(memory, 0, Int32(shared), -1) { shared = 0 }
        if shared == 0 { llama_memory_clear(memory, true) }
        cached = Array(tokens.prefix(shared))

        var fresh = Array(tokens[shared...])
        guard decode(&fresh) else { cached = []; throw NookError("The model could not read the text.") }
        cached = tokens

        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        defer { llama_sampler_free(chain) }

        var bytes: [UInt8] = []
        for _ in 0..<maxTokens {
            if cancel.isCancelled { break }
            var token = llama_sampler_sample(chain, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            bytes += piece(token)
            if bytes.contains(10) { break }
            guard decode(&token) else { cached = []; break }
            cached.append(token)
        }
        var text = String(decoding: bytes, as: UTF8.self)
        // A word cut off in the middle of a character leaves a replacement mark at the end.
        while text.last == "\u{FFFD}" { text.removeLast() }
        return text
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let count = text.utf8.count
        var tokens = [llama_token](repeating: 0, count: count + 8)
        let addBOS = llama_vocab_get_add_bos(vocab)
        var written = llama_tokenize(vocab, text, Int32(count), &tokens, Int32(tokens.count), addBOS, false)
        if written < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-written))
            written = llama_tokenize(vocab, text, Int32(count), &tokens, Int32(tokens.count), addBOS, false)
        }
        return written > 0 ? Array(tokens.prefix(Int(written))) : []
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        let length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        guard length > 0 else { return [] }
        return buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
    }

    private func decode(_ tokens: inout [llama_token]) -> Bool {
        tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count))) == 0
        }
    }

    private func decode(_ token: inout llama_token) -> Bool {
        withUnsafeMutablePointer(to: &token) { llama_decode(context, llama_batch_get_one($0, 1)) == 0 }
    }
}
