import Foundation
import LlamaSwift

/// Runs a GGUF model through llama.cpp (Metal on Apple Silicon) and continues text a few words at a time.
///
/// - Every llama call runs on one serial queue; a new request makes the one before it stop at its next token.
/// - The model's cache keeps the prompt of the last request: one more letter only has to read one more token. It has a slot
///   (a sequence) per field for the last few fields, so going back to one does not read its whole context again.
/// - A certainty threshold: when the model is not sure, nothing is shown, and a suggestion ends where its certainty drops.
/// - After a space, the greedy suggestion and the ones that start with the next likeliest tokens are written side by side in
///   one batch, and the surest is shown (see `generateRanked`); mid-word, the greedy one alone.
/// - Words the user writes often get a small bonus, so suggestions lean toward their own phrasing.
/// - A chat model (one with a chat template that is not a base model) gets the prompt as a request in its own template, with
///   its answer begun by the text typed so far (`CompletionChat`); a base model reads it as a document.
final class LlamaCompleter: CompletionEngine, @unchecked Sendable {
    let path: String
    var identity: String { path }
    /// The greedy suggestion and `branchCount` others, in one batch (see `generateRanked`).
    var candidateLimit: Int { 1 + Int(Self.branchCount) }

    private let queue = DispatchQueue(label: "nl.imdigital.nook.autocomplete", qos: .userInteractive)
    private let lock = NSLock()
    private var latest = 0

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let vocabSize: Int
    /// The chat template's text before and after the user's turn, with the model's turn opened; nil for a base model.
    private let chat: (head: String, tail: String)?
    /// What comes before the text for the last context, in tokens: the user's turn for a chat model, the header for a base
    /// model (the context stays the same for every key in a field).
    private var request: (context: String, tokens: [llama_token])?

    /// One field's prompt in the cache: the sequence with the slot's index holds `tokens`.
    private struct Slot {
        var key = ""
        var tokens: [llama_token] = []
        var used = 0
        /// The first tokens of the text left out since the window last moved (see `shifted`): left out again while the
        /// prompt still starts with them, or the cache would not match.
        var skipped: [llama_token] = []
    }

    private var slots = Array(repeating: Slot(), count: Int(fieldSlots))
    private var active = 0
    private var clock = 0
    private var seq: llama_seq_id { llama_seq_id(active) }
    /// What the active slot's sequence of the cache holds now.
    private var cached: [llama_token] {
        get { slots[active].tokens }
        set { slots[active].tokens = newValue }
    }
    /// One batch for every decode, at most `readChunk` tokens.
    private var batch: llama_batch
    private var sampler: CompletionSampler
    /// For models whose cache cannot be cut back (recurrent and hybrid ones): a saved copy of sequence 0 at a point in the
    /// prompt, to go on from instead of reading the whole prompt again.
    private var checkpoint: (tokens: [llama_token], data: [UInt8])?
    private var needsCheckpoints = false
    /// Checkpoints sit on multiples of this many tokens, at least `checkpointTail` before the end.
    private static let checkpointStep = 64
    private static let checkpointTail = 24
    /// A long prompt is read in pieces of this many tokens: between pieces a newer request can stop it, and what was read
    /// stays in the cache for that request.
    private static let readChunk = 256
    /// Tokens at the end that may differ after a window move (see `shifted`): the last letters typed, and what the model wrote.
    private static let shiftSlack = 64
    private var favored: [String: Double] = [:]
    private var strength: Float = 0
    private var bias: [llama_token: Float] = [:]
    /// Every token's bytes, read once per model when first needed: a word the model did not see coming is spelled from the
    /// whole vocabulary (see `healed`).
    private lazy var pieces: [[UInt8]] = (0..<self.vocabSize).map { self.piece(llama_token($0)) }
    /// The tokens by the first byte (`tokensByFirstByte`) or the first two bytes (`tokensByFirstTwoBytes`) of their piece. A
    /// token fits a word still to be spelled only if it starts with the word's first byte, so `healed` searches these instead
    /// of the whole vocabulary. Two bytes where the word has them: half of the vocabulary starts with a space.
    private lazy var tokensByFirstByte: [[Int]] = {
        var buckets = [[Int]](repeating: [], count: 256)
        for (index, bytes) in pieces.enumerated() { if let first = bytes.first { buckets[Int(first)].append(index) } }
        return buckets
    }()
    private lazy var tokensByFirstTwoBytes: [UInt16: [Int]] = {
        var buckets: [UInt16: [Int]] = [:]
        for (index, bytes) in pieces.enumerated() where bytes.count >= 2 {
            buckets[UInt16(bytes[0]) << 8 | UInt16(bytes[1]), default: []].append(index)
        }
        return buckets
    }()

    /// The tokens that could fit `required` (see `CompletionHealing.fits`), a superset to test.
    private func candidates(for required: [UInt8]) -> [Int] {
        guard required.count >= 2 else { return tokensByFirstByte[Int(required.first ?? 0)] }
        // A one-byte piece fits when it is the word's first byte; longer ones need the first two bytes to match.
        let single = tokensByFirstByte[Int(required[0])].filter { pieces[$0].count == 1 }
        return single + (tokensByFirstTwoBytes[UInt16(required[0]) << 8 | UInt16(required[1])] ?? [])
    }

    /// The longest prompt, in tokens.
    static let contextLength: UInt32 = 4_096
    /// The cache the slots share: about two full prompts, or more shorter ones.
    static let cacheLength: UInt32 = 8_192
    static let fieldSlots: UInt32 = 4
    /// Other ways the text could go on, written alongside each suggestion (see `generateRanked`), in sequences after the field
    /// slots.
    static let branchCount: UInt32 = 2
    /// A branch starts with a token at least this likely where the suggestion starts.
    private static let minBranchProbability: Float = 0.03

    private static let backendReady: Void = {
        // Metal lets the model's buffers leave GPU residency after 180 s without work by default, and the first suggestion
        // after a pause then waits for them to come back. Keep them as long as the model stays loaded (see
        // `AutocompleteController.idleSeconds`). A value already set in the environment wins.
        setenv("GGML_METAL_RESIDENCY_KEEP_ALIVE_S", "300", 0)
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    private init(path: String, model: OpaquePointer, context: OpaquePointer) {
        self.path = path
        self.model = model
        self.context = context
        vocab = llama_model_get_vocab(model)
        vocabSize = Int(llama_vocab_n_tokens(vocab))
        sampler = CompletionSampler(vocabularySize: vocabSize)
        chat = Self.chatFrame(model)
        batch = llama_batch_init(Int32(Self.readChunk), 0, 1)
    }

    /// The model's chat template around one user message, split where the message goes, or nil when the model has no template
    /// llama.cpp knows or is a base model.
    private static func chatFrame(_ model: OpaquePointer) -> (head: String, tail: String)? {
        guard let template = llama_model_chat_template(model, nil) else { return nil }
        var buffer = [CChar](repeating: 0, count: 256)
        let name = llama_model_meta_val_str(model, "general.name", &buffer, buffer.count) > 0 ? String(cString: buffer) : ""
        let source = llama_model_meta_val_str(model, "general.source.url", &buffer, buffer.count) > 0 ? String(cString: buffer) : ""
        guard CompletionChat.isChatModel(name: name + " " + source, hasTemplate: true) else { return nil }
        let marker = "\u{E000}NOOK\u{E000}"
        let rendered: String? = marker.withCString { content in
            "user".withCString { role in
                var message = llama_chat_message(role: role, content: content)
                var output = [CChar](repeating: 0, count: 4_096)
                let length = llama_chat_apply_template(template, &message, 1, true, &output, Int32(output.count))
                guard length > 0, Int(length) < output.count else { return nil }
                return String(decoding: output.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        guard let rendered, let range = rendered.range(of: marker) else { return CompletionChat.frame(forTemplate: String(cString: template)) }
        return (String(rendered[..<range.lowerBound]), String(rendered[range.upperBound...]))
    }

    deinit {
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    /// Loads the model off the main thread (a second or two for a small one).
    /// - Parameter adapter: a LoRA adapter (GGUF) made for this model, applied at full strength. One that does not load
    ///   (made for another model) is left out, and the model runs without it.
    static func load(path: String, adapter: String? = nil) async throws -> LlamaCompleter {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = backendReady
                var modelParams = llama_model_default_params()
                modelParams.n_gpu_layers = 999
                guard let model = llama_model_load_from_file(path, modelParams) else {
                    return continuation.resume(throwing: NookError(tr("autocomplete.error.load")))
                }
                var params = llama_context_default_params()
                params.n_ctx = cacheLength
                params.n_batch = contextLength
                // One sequence per field slot, in one cache: a field's slot only takes the room its prompt needs.
                params.n_seq_max = fieldSlots + branchCount
                params.kv_unified = true
                params.no_perf = true
                // Sliding-window models (Gemma 3 and 4) keep a full cache: otherwise llama.cpp cannot cut it back, and every
                // key would read the whole prompt again.
                params.swa_full = true
                // Every layer runs on the GPU: more than four CPU threads only take cores from the apps you type in.
                let threads = Int32(max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)))
                params.n_threads = threads
                params.n_threads_batch = threads
                guard let context = llama_init_from_model(model, params) else {
                    llama_model_free(model)
                    return continuation.resume(throwing: NookError(tr("autocomplete.error.memory")))
                }
                if let adapter, !adapter.isEmpty {
                    if let lora = llama_adapter_lora_init(model, adapter) {
                        var adapters: [OpaquePointer?] = [lora]
                        var scales: [Float] = [1]
                        llama_set_adapters_lora(context, &adapters, 1, &scales)
                    } else {
                        Log.autocomplete.error("LoRA adapter did not load for this model; running without it")
                    }
                }
                let completer = LlamaCompleter(path: path, model: model, context: context)
                completer.prepareSpelling()
                continuation.resume(returning: completer)
            }
        }
    }

    /// Builds the tables `healed` spells unusual words from (every token's bytes, by their first bytes) right after loading,
    /// on the model's queue: built on the first name or rare word typed instead, they held up that suggestion by a few hundred
    /// milliseconds with a 262 000-token vocabulary (Gemma). A request that comes meanwhile waits for them, as it would anyway.
    private func prepareSpelling() {
        queue.async {
            _ = self.tokensByFirstByte
            _ = self.tokensByFirstTwoBytes
        }
    }

    /// Makes the running request stop at its next token.
    func cancel() { lock.withLock { latest += 1 } }

    private func begin() -> Int { lock.withLock { latest += 1; return latest } }
    private func superseded(_ id: Int) -> Bool { lock.withLock { latest != id } }

    /// Continues `prompt`; nil when superseded, not sure enough, or the model failed. With `options.candidates` above 1 (and
    /// not mid-word, nobody waiting for words one by one), writes the candidates side by side, returns the surest and hands the
    /// others to `branches` (see `generateRanked`).
    func complete(prompt: CompletionPrompt, options: CompletionOptions, partial: (@Sendable (String) -> Void)?,
                  branches: (@Sendable ([CompletionResult]) -> Void)?) async -> CompletionResult? {
        let id = begin()
        return await withCheckedContinuation { continuation in
            queue.async {
                let isCancelled = { self.superseded(id) }
                guard partial == nil, !options.heal, options.candidates > 1 else {
                    return continuation.resume(returning: self.generate(prompt: prompt, options: options, partial: partial, isCancelled: isCancelled))
                }
                let (result, others) = self.generateRanked(prompt: prompt, options: options, isCancelled: isCancelled)
                continuation.resume(returning: result)
                if let branches, !others.isEmpty, !isCancelled() { branches(others) }
            }
        }
    }

    /// Words that could come next after `prompt`, most likely first, each with the space before it when the model would put
    /// one there. For other words for a selected word, and alternatives to the next suggested word.
    func alternatives(prompt: CompletionPrompt, excluding: String, count: Int) async -> [String] {
        let id = begin()
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.rankedWords(prompt: prompt, excluding: excluding, count: count) { self.superseded(id) }) }
        }
    }

    /// Reads `prompt` into the cache without writing anything, so the next request only has to read its last few tokens.
    /// Does not stop the running request; a newer request stops it between pieces and goes on from what it read.
    func warm(prompt: CompletionPrompt) {
        let id = lock.withLock { latest }
        queue.async {
            let isCancelled = { self.superseded(id) }
            guard !isCancelled() else { return }
            _ = self.prime(prompt, reserve: 32, isCancelled: isCancelled)
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

    /// The prompt in tokens, laid out for this model, and how many of them come before the text (the frame). The template's
    /// own markers are read as control tokens; the context and the text never are, so they cannot open or close a turn. Too
    /// long, the text is cut from the front, the frame kept.
    private func tokens(for prompt: CompletionPrompt, limit: Int) -> (tokens: [llama_token], frame: Int) {
        if chat == nil, prompt.context.isEmpty {
            var tokens = tokenize(prompt.text, special: true)
            if tokens.count > limit { tokens.removeFirst(tokens.count - limit) }
            return (tokens, 0)
        }
        if request?.context != prompt.context {
            if let chat {
                var head = tokenize(chat.head, special: true, parse: true)
                // A template that writes its own <bos> after the one the tokenizer adds would give two.
                if head.count >= 2, head[0] == head[1], head[0] == llama_vocab_bos(vocab) { head.removeFirst() }
                request = (prompt.context, head + tokenize(CompletionChat.request(context: prompt.context), special: false)
                    + tokenize(chat.tail, special: false, parse: true))
            } else {
                // A base model reads a document: the context as its header (see `CompletionPrompt.document`).
                request = (prompt.context, tokenize(prompt.context + "\n\n", special: true))
            }
        }
        let frame = request?.tokens ?? []
        var text = tokenize(prompt.text, special: false)
        if frame.count + text.count > limit { text.removeFirst(min(text.count, frame.count + text.count - limit)) }
        return (frame + text, frame.count)
    }

    /// Makes the slot for the field whose context is `key` the active one: the slot it had, else an empty one, else the one
    /// used longest ago. A model whose cache cannot be cut back keeps one slot (see `checkpoint`).
    private func select(_ key: String) {
        clock += 1
        if needsCheckpoints {
            active = 0
        } else if let index = slots.firstIndex(where: { $0.key == key }) {
            active = index
        } else {
            active = slots.firstIndex { $0.tokens.isEmpty } ?? slots.indices.min { slots[$0].used < slots[$1].used } ?? 0
            slots[active].skipped = []
        }
        slots[active].key = key
        slots[active].used = clock
    }

    /// The slots share one cache: before `count` more tokens go into the active one, empties the others used longest ago
    /// until they fit.
    private func makeRoom(for count: Int) {
        let memory = llama_get_memory(context)
        while slots.reduce(0, { $0 + $1.tokens.count }) + count > Int(Self.cacheLength),
              let oldest = slots.indices.filter({ $0 != active && !slots[$0].tokens.isEmpty }).min(by: { slots[$0].used < slots[$1].used }) {
            _ = llama_memory_seq_rm(memory, llama_seq_id(oldest), -1, -1)
            slots[oldest] = Slot()
        }
    }

    /// The window over the text moved on (see `PromptBuilder.window`): the active slot holds the old window, whose start the
    /// prompt no longer has, so after the frame hardly anything matches. Rather than read the whole text again, the old start
    /// is dropped from the cache and the rest moved back to follow the frame (a RoPE shift). The first few tokens of the new
    /// window may be cut from the text differently than before; they are left out of the prompt (the far start of a long
    /// text). Returns the prompt to read instead, or nil when the cache cannot be reused this way.
    private func shifted(_ tokens: [llama_token], frame: Int) -> [llama_token]? {
        let old = cached
        let probe = 16
        let memory = llama_get_memory(context)
        guard !needsCheckpoints, frame > 0, old.count >= frame + 300, tokens.count > frame + probe + 8,
              old[..<frame] == tokens[..<frame], zip(tokens[frame...], old[frame...]).prefix(while: { $0 == $1 }).count < 8,
              llama_memory_can_shift(memory) else { return nil }
        for skip in 0..<8 {
            let start = frame + skip
            let wanted = tokens[start ..< start + probe]
            var position = start + 1
            while position + probe <= old.count {
                // The rest must line up to the end (the suggestion the model wrote last may follow), not only the probe:
                // text that repeats itself would otherwise match a few tokens off.
                if old[position ..< position + probe] == wanted,
                   zip(tokens[start...], old[position...]).prefix(while: { $0 == $1 }).count
                    >= min(tokens.count - start, old.count - position) - Self.shiftSlack {
                    guard llama_memory_seq_rm(memory, seq, llama_pos(frame), llama_pos(position)) else { return nil }
                    llama_memory_seq_add(memory, seq, llama_pos(position), -1, llama_pos(frame - position))
                    cached = Array(old[..<frame]) + Array(old[position...])
                    slots[active].skipped = Array(tokens[frame ..< start])
                    return Array(tokens[..<frame]) + Array(tokens[start...])
                }
                position += 1
            }
        }
        return nil
    }

    /// Reads `prompt` into the cache, reusing what it shares with the last one. Returns the prompt's length in tokens.
    private func prime(_ prompt: CompletionPrompt, reserve: Int, isCancelled: () -> Bool) -> Int? {
        let laidOut = self.tokens(for: prompt, limit: Int(Self.contextLength) - reserve - 1)
        var tokens = laidOut.tokens
        guard !tokens.isEmpty else { return nil }
        select(prompt.context)
        let frame = laidOut.frame
        let skipped = slots[active].skipped
        if !skipped.isEmpty, tokens.count > frame + skipped.count, tokens[frame ..< frame + skipped.count].elementsEqual(skipped) {
            tokens.removeSubrange(frame ..< frame + skipped.count)
        } else if let moved = shifted(tokens, frame: frame) {
            tokens = moved
        }
        // Read at least the last token again, for fresh logits.
        var shared = min(zip(tokens, cached).prefix { $0 == $1 }.count, tokens.count - 1)
        let memory = llama_get_memory(context)
        if !llama_memory_seq_rm(memory, seq, llama_pos(shared), -1) {
            // This cache cannot be cut back: one slot from now on, and go on from the checkpoint when the prompt still starts
            // with it.
            llama_memory_clear(memory, true)
            slots = Array(repeating: Slot(), count: slots.count)
            needsCheckpoints = true
            select(prompt.context)
            shared = 0
            if let saved = checkpoint, saved.tokens.count < tokens.count, tokens.starts(with: saved.tokens),
               saved.data.withUnsafeBufferPointer({ llama_state_seq_set_data(context, $0.baseAddress, $0.count, seq) }) > 0 {
                shared = saved.tokens.count
            } else {
                llama_memory_clear(memory, true)
            }
        }
        cached = Array(tokens[..<shared])
        makeRoom(for: tokens.count - shared + reserve)
        // Read up to a new checkpoint first and save it, when this model needs them and the prompt has grown a step.
        let target = max(0, ((tokens.count - Self.checkpointTail) / Self.checkpointStep) * Self.checkpointStep)
        if needsCheckpoints, target - shared >= Self.checkpointStep {
            guard read(Array(tokens[shared ..< target]), isCancelled: isCancelled) else { return nil }
            let size = llama_state_seq_get_size(context, seq)
            var data = [UInt8](repeating: 0, count: size)
            let written = data.withUnsafeMutableBufferPointer { llama_state_seq_get_data(context, $0.baseAddress, size, seq) }
            checkpoint = written > 0 ? (Array(tokens[..<target]), Array(data.prefix(written))) : nil
            shared = target
        }
        return read(Array(tokens[shared...]), isCancelled: isCancelled) ? tokens.count : nil
    }

    /// Decodes `tokens` in pieces of `readChunk`; false when it failed or was stopped (what was read stays in the cache).
    private func read(_ tokens: [llama_token], isCancelled: () -> Bool) -> Bool {
        var start = 0
        while start < tokens.count {
            if start > 0, isCancelled() { return false }
            let piece = Array(tokens[start ..< min(start + Self.readChunk, tokens.count)])
            guard decode(piece) else { return false }
            start += piece.count
        }
        return true
    }

    private func generate(prompt: CompletionPrompt, options: CompletionOptions, partial: (@Sendable (String) -> Void)?,
                          isCancelled: () -> Bool) -> CompletionResult? {
        // Mid-word, read the prompt without the word and let the model spell it again (see CompletionHealing). While you type
        // the rest of that word the prompt stays the same, so the cache has nothing new to read.
        let healing = options.heal ? prompt.healed() : (prompt: prompt, pending: "")
        var required = Array(healing.pending.utf8)
        guard !isCancelled(), prime(healing.prompt, reserve: options.maxTokens + 8, isCancelled: isCancelled) != nil else { return nil }
        var bytes: [UInt8] = []
        var candidate = CompletionCandidate()
        var reported = 0
        for _ in 0..<(options.maxTokens + (required.isEmpty ? 0 : 6)) {
            if isCancelled() { return nil }
            guard let logits = llama_get_logits_ith(context, -1) else { return nil }
            let choice: (llama_token, Float)? = required.isEmpty ? mostLikely(logits) : healed(logits, required: required)
            guard let choice else { return nil }
            let (token, probability) = choice
            let isEnd = llama_vocab_is_eog(vocab, token) || llama_vocab_is_control(vocab, token)
            var piece = isEnd ? [] : self.piece(token)
            if !required.isEmpty, !isEnd {
                // What spells the word that was already typed is not part of the suggestion.
                let spelled = min(piece.count, required.count)
                required.removeFirst(spelled)
                piece.removeFirst(spelled)
            }
            if isEnd || !piece.isEmpty {
                // Not sure any more: end here, and never in the middle of a word.
                guard candidate.keep(probability: probability, isEnd: isEnd, firstBar: options.minFirstProbability, options: options,
                                     continuesWord: CompletionHealing.continuesWord(String(decoding: piece, as: UTF8.self))) else { break }
            }
            if let newline = piece.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                bytes += piece[..<newline]
                candidate.end()
                break
            }
            bytes += piece
            let text = String(decoding: bytes, as: UTF8.self)
            if text.completionWordCount > options.maxWords {
                candidate.end()
                break
            }
            // Hand over each finished word right away, so the suggestion appears while the rest is still being written.
            let finished = CompletionStreaming.finishedWords(text)
            if finished > reported, let partial {
                reported = finished
                partial(text.replacingOccurrences(of: "\u{FFFD}", with: ""))
            }
            guard decode([token]) else { break }
        }
        // The generated tokens stay in the cache; the shared-prefix check trims them on the next request.
        return candidate.result(text: String(decoding: bytes, as: UTF8.self))
    }

    /// Writes the greedy suggestion and the ones that start with the next most likely tokens side by side, one batch per token
    /// (each in its own sequence, sharing the prompt in the cache): on the GPU a batch of three costs about what one token
    /// does. Returns the one to show (see `CompletionRanking`) and the others, for the memo (see `CompletionMemo`): when the
    /// user starts typing one of them instead, it shows at once.
    private func generateRanked(prompt: CompletionPrompt, options: CompletionOptions,
                                isCancelled: () -> Bool) -> (shown: CompletionResult?, others: [CompletionResult]) {
        struct Sequence {
            var seq: llama_seq_id
            /// The token to read next: the last one kept.
            var token: llama_token
            var bytes: [UInt8] = []
            var candidate = CompletionCandidate()
        }
        guard !isCancelled(), let length = prime(prompt, reserve: options.maxTokens + 8, isCancelled: isCancelled),
              let logits = llama_get_logits_ith(context, -1) else { return (nil, []) }
        let (mainToken, mainProbability) = mostLikely(logits)
        let mainText = String(decoding: piece(mainToken), as: UTF8.self).trimmingCharacters(in: .whitespaces)
        var sequences = [Sequence(seq: seq, token: mainToken)]
        var firsts: [Float] = [mainProbability]
        let others = min(options.candidates, candidateLimit) - 1
        if !needsCheckpoints, others > 0 {
            let starts = firstChoices(logits).filter { choice in
                let text = String(decoding: piece(choice.token), as: UTF8.self).trimmingCharacters(in: .whitespaces)
                // One that only spells the greedy word differently goes the same way. A greedy start that is only a space or
                // a line break says nothing about the others.
                return choice.token != mainToken && !text.isEmpty
                    && (mainText.isEmpty || (!mainText.hasPrefix(text) && !text.hasPrefix(mainText)))
            }.prefix(others)
            for (index, start) in starts.enumerated() {
                sequences.append(Sequence(seq: llama_seq_id(Self.fieldSlots) + llama_seq_id(index), token: start.token))
                firsts.append(start.probability)
            }
        }
        let memory = llama_get_memory(context)
        let branches = sequences.dropFirst()
        if !branches.isEmpty {
            makeRoom(for: branches.count * (options.maxTokens + 1))
            for branch in branches {
                _ = llama_memory_seq_rm(memory, branch.seq, -1, -1)
                llama_memory_seq_cp(memory, seq, branch.seq, 0, llama_pos(length))
            }
        }
        defer { for branch in sequences.dropFirst() { _ = llama_memory_seq_rm(memory, branch.seq, -1, -1) } }

        /// Takes `token` (with `probability`) as the next one of sequence `index`, or ends it there.
        func take(_ token: llama_token, _ probability: Float, into index: Int) {
            let isEnd = llama_vocab_is_eog(vocab, token) || llama_vocab_is_control(vocab, token)
            let piece = isEnd ? [] : self.piece(token)
            // The greedy one is shown only past the usual bar; the others were picked from the likeliest starts already.
            let bar = index == 0 ? options.minFirstProbability : Self.minBranchProbability
            guard sequences[index].candidate.keep(probability: probability, isEnd: isEnd, firstBar: bar, options: options,
                                                  continuesWord: CompletionHealing.continuesWord(String(decoding: piece, as: UTF8.self)))
            else { return }
            if let newline = piece.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                sequences[index].bytes += piece[..<newline]
                sequences[index].candidate.end()
                return
            }
            sequences[index].bytes += piece
            sequences[index].token = token
            if String(decoding: sequences[index].bytes, as: UTF8.self).completionWordCount > options.maxWords {
                sequences[index].candidate.end()
            }
        }

        for index in sequences.indices { take(sequences[index].token, firsts[index], into: index) }
        var position = length
        for _ in 1..<max(options.maxTokens, 2) {
            if isCancelled() { return (nil, []) }
            let running = sequences.indices.filter { !sequences[$0].candidate.done }
            guard !running.isEmpty else { break }
            guard decode(running.map { (sequences[$0].token, sequences[$0].seq) }, at: position) else {
                llama_memory_clear(memory, true)
                slots = Array(repeating: Slot(), count: slots.count)
                break
            }
            // The greedy one is in the field's own slot: its tokens stay in the cache like a single suggestion's.
            if running.first == 0 { cached.append(sequences[0].token) }
            position += 1
            for (row, index) in running.enumerated() {
                guard let logits = llama_get_logits_ith(context, Int32(row)) else {
                    sequences[index].candidate.end()
                    continue
                }
                let (token, probability) = mostLikely(logits)
                take(token, probability, into: index)
            }
        }
        let results = sequences.map { $0.candidate.result(text: String(decoding: $0.bytes, as: UTF8.self)) }
        guard let pick = CompletionRanking.best(results, minFirstProbability: options.minFirstProbability) else {
            return (nil, results.dropFirst().compactMap { $0 })
        }
        return (results[pick], results.indices.filter { $0 != pick }.compactMap { results[$0] })
    }

    /// The most likely token that fits the word still to be spelled, with its probability among the tokens that fit.
    private func healed(_ logits: UnsafeMutablePointer<Float>, required: [UInt8]) -> (llama_token, Float)? {
        var fitting: [(llama_token, Float)] = []
        for candidate in topTokens(logits, count: 64) where !llama_vocab_is_control(vocab, candidate) {
            if CompletionHealing.fits(piece(candidate), required) { fitting.append((candidate, logits[Int(candidate)])) }
        }
        // A name or a rare word: none of the likely tokens spells it. Look through the whole vocabulary rather than give up, or
        // a word would only be finished once it was common enough.
        if fitting.isEmpty {
            for index in candidates(for: required) where CompletionHealing.fits(pieces[index], required) {
                let token = llama_token(index)
                guard !llama_vocab_is_control(vocab, token), !llama_vocab_is_eog(vocab, token) else { continue }
                fitting.append((token, logits[index]))
            }
            fitting.sort { $0.1 > $1.1 }
        }
        guard let best = fitting.first else { return nil }
        let sum = fitting.reduce(Float(0)) { $0 + exp($1.1 - best.1) }
        return (best.0, 1 / sum)
    }

    /// The most likely tokens to start with, with their probabilities (softmax over all tokens).
    private func firstChoices(_ logits: UnsafeMutablePointer<Float>) -> [(token: llama_token, probability: Float)] {
        let (_, maximum, sum) = sampler.maximum(logits)
        return topTokens(logits, count: Int(Self.branchCount) + 2).compactMap { token in
            let probability = exp(logits[Int(token)] - maximum) / sum
            guard probability >= Self.minBranchProbability, !llama_vocab_is_eog(vocab, token), !llama_vocab_is_control(vocab, token) else { return nil }
            return (token, probability)
        }
    }

    private func rankedWords(prompt: CompletionPrompt, excluding: String, count: Int, isCancelled: () -> Bool) -> [String] {
        var text = prompt
        while text.text.last == " " { text.text.removeLast() }
        guard !isCancelled(), let length = prime(text, reserve: 8, isCancelled: isCancelled), let logits = llama_get_logits_ith(context, -1) else { return [] }
        let candidates = topTokens(logits, count: count * 4)
        var results: [String] = []
        for candidate in candidates {
            if isCancelled() { return [] }
            if results.count == count { break }
            if llama_vocab_is_eog(vocab, candidate) || llama_vocab_is_control(vocab, candidate) { continue }
            // Back to the end of the prompt, then spell out the rest of the word.
            guard llama_memory_seq_rm(llama_get_memory(context), seq, llama_pos(length), -1) else { break }
            cached = Array(cached.prefix(length))
            var bytes = piece(candidate)
            var next = [candidate]
            for _ in 0..<4 {
                guard decode(next), let logits = llama_get_logits_ith(context, -1) else { break }
                let token = mostLikely(logits).0
                let piece = self.piece(token)
                guard let first = piece.first, Character(UnicodeScalar(first)).isLetter || first >= 0x80 || first == UInt8(ascii: "'") else { break }
                bytes += piece
                next = [token]
            }
            if let entry = CompletionWords.acceptable(String(decoding: bytes, as: UTF8.self), excluding: excluding, among: results) {
                results.append(entry)
            }
        }
        return results
    }

    /// Reads `tokens` (at most `readChunk`) into the active slot's sequence, after what it holds; logits for the last one.
    private func decode(_ tokens: [llama_token]) -> Bool {
        guard !tokens.isEmpty, tokens.count <= Self.readChunk else { return false }
        let start = cached.count
        for (index, token) in tokens.enumerated() {
            batch.token[index] = token
            batch.pos[index] = llama_pos(start + index)
            batch.n_seq_id[index] = 1
            batch.seq_id[index]![0] = seq
            batch.logits[index] = index == tokens.count - 1 ? 1 : 0
        }
        batch.n_tokens = Int32(tokens.count)
        guard llama_decode(context, batch) == 0 else {
            llama_memory_clear(llama_get_memory(context), true)
            slots = Array(repeating: Slot(), count: slots.count)
            return false
        }
        cached += tokens
        return true
    }

    /// Reads one token for each of several sequences, all at `position`, with logits for each (in this order). The slots'
    /// bookkeeping is left alone: these are the branches' own sequences.
    private func decode(_ items: [(token: llama_token, seq: llama_seq_id)], at position: Int) -> Bool {
        guard !items.isEmpty, items.count <= Self.readChunk else { return false }
        for (index, item) in items.enumerated() {
            batch.token[index] = item.token
            batch.pos[index] = llama_pos(position)
            batch.n_seq_id[index] = 1
            batch.seq_id[index]![0] = item.seq
            batch.logits[index] = 1
        }
        batch.n_tokens = Int32(items.count)
        return llama_decode(context, batch) == 0
    }

    /// - Parameters:
    ///   - special: add the model's start token (BOS) when it wants one.
    ///   - parse: read control-token text ("<start_of_turn>") as those tokens: only for the chat template's own text.
    private func tokenize(_ text: String, special: Bool, parse: Bool = false) -> [llama_token] {
        let bytes = Array(text.utf8CString.dropLast())
        guard !bytes.isEmpty else { return [] }
        var capacity = Int32(bytes.count + 8)
        var tokens = [llama_token](repeating: 0, count: Int(capacity))
        var count = llama_tokenize(vocab, bytes, Int32(bytes.count), &tokens, capacity, special, parse)
        if count < 0 {
            capacity = -count
            tokens = [llama_token](repeating: 0, count: Int(capacity))
            count = llama_tokenize(vocab, bytes, Int32(bytes.count), &tokens, capacity, special, parse)
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
        let (index, maximum, sum) = sampler.maximum(logits)
        var best = index
        var score = maximum
        for (token, bonus) in bias where Int(token) < vocabSize && logits[Int(token)] + bonus > score {
            score = logits[Int(token)] + bonus
            best = Int(token)
        }
        return (llama_token(best), exp(logits[best] - maximum) / sum)
    }

    /// The `count` highest logits, highest first (see `CompletionSampler.top`).
    private func topTokens(_ logits: UnsafeMutablePointer<Float>, count: Int) -> [llama_token] {
        sampler.top(logits, k: count).map { llama_token($0) }
    }
}
