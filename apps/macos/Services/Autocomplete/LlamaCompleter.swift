import Foundation
import LlamaSwift

/// Runs a GGUF model through llama.cpp (Metal on Apple Silicon) and continues text a few words at a time.
///
/// - Every llama call runs on one serial queue; a new request makes the one before it stop at its next token.
/// - The model's cache keeps the prompt of the last request: one more letter only has to read one more token.
/// - Greedy, with a certainty threshold: when the model is not sure, nothing is shown, and a suggestion ends where its
///   certainty drops.
/// - Words the user writes often get a small bonus, so suggestions lean toward their own phrasing.
///
/// The approach (threshold, word bonus, word alternatives) follows Typist's engine (MIT, © 2026 Brody Salvucci).
final class LlamaCompleter: @unchecked Sendable {
    let path: String

    private let queue = DispatchQueue(label: "nl.imdigital.nook.autocomplete", qos: .userInitiated)
    private let lock = NSLock()
    private var latest = 0

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let vocabSize: Int
    /// What sequence 0 of the cache holds now.
    private var cached: [llama_token] = []
    private var favored: [String: Double] = [:]
    private var strength: Float = 0
    private var bias: [llama_token: Float] = [:]

    static let contextLength: UInt32 = 4_096

    private static let backendReady: Void = {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    private init(path: String, model: OpaquePointer, context: OpaquePointer) {
        self.path = path
        self.model = model
        self.context = context
        vocab = llama_model_get_vocab(model)
        vocabSize = Int(llama_vocab_n_tokens(vocab))
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    /// Loads the model off the main thread (a second or two for a small one).
    static func load(path: String) async throws -> LlamaCompleter {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = backendReady
                var modelParams = llama_model_default_params()
                modelParams.n_gpu_layers = 999
                guard let model = llama_model_load_from_file(path, modelParams) else {
                    return continuation.resume(throwing: NookError(tr("autocomplete.error.load")))
                }
                var params = llama_context_default_params()
                params.n_ctx = contextLength
                params.n_batch = contextLength
                params.no_perf = true
                let threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
                params.n_threads = threads
                params.n_threads_batch = threads
                guard let context = llama_init_from_model(model, params) else {
                    llama_model_free(model)
                    return continuation.resume(throwing: NookError(tr("autocomplete.error.memory")))
                }
                continuation.resume(returning: LlamaCompleter(path: path, model: model, context: context))
            }
        }
    }

    /// Makes the running request stop at its next token.
    func cancel() { lock.withLock { latest += 1 } }

    private func begin() -> Int { lock.withLock { latest += 1; return latest } }
    private func superseded(_ id: Int) -> Bool { lock.withLock { latest != id } }

    /// Continues `prompt`; nil when superseded, not sure enough, or the model failed.
    func complete(prompt: String, options: CompletionOptions) async -> CompletionResult? {
        let id = begin()
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.generate(prompt: prompt, options: options) { self.superseded(id) }) }
        }
    }

    /// Words that could come next after `prompt`, most likely first, each with the space before it when the model would put
    /// one there. For other words for a selected word, and alternatives to the next suggested word.
    func alternatives(prompt: String, excluding: String, count: Int) async -> [String] {
        let id = begin()
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.rankedWords(prompt: prompt, excluding: excluding, count: count) { self.superseded(id) }) }
        }
    }

    /// Leans generation toward words the user writes often. Strength 0 turns it off.
    func setPersonalization(words: [String: Double], strength: Double) {
        queue.async {
            self.favored = words
            self.strength = Float(strength)
            self.rebuildBias()
        }
    }

    // MARK: On the queue

    private func rebuildBias() {
        bias = [:]
        guard strength > 0 else { return }
        for (word, weight) in favored {
            // In the middle of a sentence a word starts with a space in most vocabularies.
            guard let token = tokenize(" " + word, special: false).first else { continue }
            bias[token] = max(bias[token] ?? 0, Float(weight) * strength * 2.5)
        }
    }

    /// Reads `prompt` into the cache, reusing what it shares with the last one. Returns the prompt's length in tokens.
    private func prime(_ prompt: String, reserve: Int) -> Int? {
        var tokens = tokenize(prompt, special: true)
        let limit = Int(Self.contextLength) - reserve - 1
        if tokens.count > limit { tokens.removeFirst(tokens.count - limit) }
        guard !tokens.isEmpty else { return nil }
        // Read at least the last token again, for fresh logits.
        var shared = min(zip(tokens, cached).prefix { $0 == $1 }.count, tokens.count - 1)
        let memory = llama_get_memory(context)
        if !llama_memory_seq_rm(memory, 0, llama_pos(shared), -1) {
            llama_memory_clear(memory, true)
            shared = 0
        }
        cached = Array(tokens[..<shared])
        var pending = Array(tokens[shared...])
        return decode(&pending) ? tokens.count : nil
    }

    private func generate(prompt: String, options: CompletionOptions, isCancelled: () -> Bool) -> CompletionResult? {
        guard !isCancelled(), prime(prompt, reserve: options.maxTokens) != nil else { return nil }
        var bytes: [UInt8] = []
        var truncated = true
        for step in 0..<options.maxTokens {
            if isCancelled() { return nil }
            guard let logits = llama_get_logits_ith(context, -1) else { return nil }
            let (token, probability) = mostLikely(logits)
            if step == 0, probability < options.minFirstProbability { return nil }
            if probability < options.minProbability || llama_vocab_is_eog(vocab, token) || llama_vocab_is_control(vocab, token) {
                truncated = false
                break
            }
            let piece = self.piece(token)
            if let newline = piece.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                bytes += piece[..<newline]
                truncated = false
                break
            }
            bytes += piece
            if String(decoding: bytes, as: UTF8.self).completionWordCount > options.maxWords {
                truncated = false
                break
            }
            var next = [token]
            guard decode(&next) else { break }
        }
        // The generated tokens stay in the cache; the shared-prefix check trims them on the next request.
        let text = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\u{FFFD}", with: "")
        return CompletionResult(text: text, truncated: truncated)
    }

    private func rankedWords(prompt: String, excluding: String, count: Int, isCancelled: () -> Bool) -> [String] {
        var text = prompt
        while text.last == " " { text.removeLast() }
        guard !isCancelled(), let length = prime(text, reserve: 8), let logits = llama_get_logits_ith(context, -1) else { return [] }
        let candidates = topTokens(logits, count: count * 4)
        var results: [String] = []
        let excluded = excluding.lowercased()
        for candidate in candidates {
            if isCancelled() { return [] }
            if results.count == count { break }
            if llama_vocab_is_eog(vocab, candidate) || llama_vocab_is_control(vocab, candidate) { continue }
            // Back to the end of the prompt, then spell out the rest of the word.
            guard llama_memory_seq_rm(llama_get_memory(context), 0, llama_pos(length), -1) else { break }
            cached = Array(cached.prefix(length))
            var bytes = piece(candidate)
            var next = [candidate]
            for _ in 0..<4 {
                guard decode(&next), let logits = llama_get_logits_ith(context, -1) else { break }
                let token = mostLikely(logits).0
                let piece = self.piece(token)
                guard let first = piece.first, Character(UnicodeScalar(first)).isLetter || first >= 0x80 || first == UInt8(ascii: "'") else { break }
                bytes += piece
                next = [token]
            }
            let raw = String(decoding: bytes, as: UTF8.self)
            let word = raw.trimmingCharacters(in: .whitespaces)
            let entry = (raw.first == " " ? " " : "") + word
            guard word.count >= 2, word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }), word.lowercased() != excluded,
                  !results.contains(where: { $0.lowercased() == entry.lowercased() }) else { continue }
            results.append(entry)
        }
        return results
    }

    private func decode(_ tokens: inout [llama_token]) -> Bool {
        let count = Int32(tokens.count)
        let status = tokens.withUnsafeMutableBufferPointer { llama_decode(context, llama_batch_get_one($0.baseAddress, count)) }
        guard status == 0 else {
            llama_memory_clear(llama_get_memory(context), true)
            cached = []
            return false
        }
        cached += tokens
        return true
    }

    private func tokenize(_ text: String, special: Bool) -> [llama_token] {
        let bytes = Array(text.utf8CString.dropLast())
        guard !bytes.isEmpty else { return [] }
        var capacity = Int32(bytes.count + 8)
        var tokens = [llama_token](repeating: 0, count: Int(capacity))
        var count = llama_tokenize(vocab, bytes, Int32(bytes.count), &tokens, capacity, special, false)
        if count < 0 {
            capacity = -count
            tokens = [llama_token](repeating: 0, count: Int(capacity))
            count = llama_tokenize(vocab, bytes, Int32(bytes.count), &tokens, capacity, special, false)
        }
        return count > 0 ? Array(tokens.prefix(Int(count))) : []
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var capacity: Int32 = 64
        var buffer = [CChar](repeating: 0, count: Int(capacity))
        var length = llama_token_to_piece(vocab, token, &buffer, capacity, 0, false)
        if length < 0 {
            capacity = -length
            buffer = [CChar](repeating: 0, count: Int(capacity))
            length = llama_token_to_piece(vocab, token, &buffer, capacity, 0, false)
        }
        return buffer.prefix(Int(max(length, 0))).map { UInt8(bitPattern: $0) }
    }

    /// The most likely token after the word bonus, with its probability before the bonus (softmax over all tokens).
    private func mostLikely(_ logits: UnsafeMutablePointer<Float>) -> (llama_token, Float) {
        var best = 0
        var maximum = logits[0]
        for index in 1..<vocabSize where logits[index] > maximum {
            maximum = logits[index]
            best = index
        }
        var sum: Float = 0
        for index in 0..<vocabSize { sum += exp(logits[index] - maximum) }
        var score = maximum
        for (token, bonus) in bias where Int(token) < vocabSize && logits[Int(token)] + bonus > score {
            score = logits[Int(token)] + bonus
            best = Int(token)
        }
        return (llama_token(best), exp(logits[best] - maximum) / sum)
    }

    /// The `count` highest logits without sorting the whole vocabulary (often 150 000+ tokens).
    private func topTokens(_ logits: UnsafeMutablePointer<Float>, count: Int) -> [llama_token] {
        var top: [(Int, Float)] = []
        top.reserveCapacity(count + 1)
        for index in 0..<vocabSize {
            let value = logits[index]
            if top.count < count {
                top.append((index, value))
                if top.count == count { top.sort { $0.1 > $1.1 } }
            } else if value > top[count - 1].1 {
                var position = count - 1
                while position > 0, top[position - 1].1 < value { position -= 1 }
                top.insert((index, value), at: position)
                top.removeLast()
            }
        }
        if top.count < count { top.sort { $0.1 > $1.1 } }
        return top.map { llama_token($0.0) }
    }
}
