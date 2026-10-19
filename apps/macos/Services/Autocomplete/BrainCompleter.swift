import Foundation
import MLX
import MLXLMCommon

/// Autocomplete on the model Nook's brain already downloaded (MLX), so nothing else has to be downloaded. It works like
/// `LlamaCompleter`: greedy with the certainty threshold, a bonus for the user's own words, other words to pick, and the
/// suggestion handed over word by word while it is being written.
///
/// Speed comes from checkpoints: the cache is copied at fixed points of the prompt (every 64 tokens, `KVCache.copy()`), and
/// each key continues from the newest checkpoint the new prompt still starts with. So a letter typed costs a few dozen
/// tokens, also on models whose cache cannot be cut back (hybrid models like Qwen 3.5, sliding windows like Gemma 4).
///
/// The brain's models are chat models: the prompt goes in their chat template as a request, with their answer begun by the
/// text typed so far (`CompletionChat`), instead of as a bare document they would answer instead of continue.
///
/// It only ever uses the model the brain itself uses, and never loads another one: the chat keeps its model in memory. A chat
/// answer always goes first: while the brain is writing one, autocomplete shows nothing.
final class BrainCompleter: CompletionEngine, @unchecked Sendable {
    let modelID: String
    var identity: String { CompletionSource.brainPrefix + modelID }

    /// Short lock: the request counter and the word bonus. Never held while the model runs.
    private let lock = NSLock()
    private var latest = 0
    private var favored: [String: Double] = [:]
    private var strength: Float = 0
    private var biasVersion = 0
    private var dropCheckpoint = false

    /// Held while the model runs: one generation at a time touches the checkpoint.
    private let work = NSLock()
    private var checkpoint: Checkpoint?
    private var biasCache: (owner: ObjectIdentifier, version: Int, bias: [Int: Float], array: MLXArray?)?
    /// The user's turn in the chat template for the last context, in tokens; nil tokens when the model has no template.
    private var request: (owner: ObjectIdentifier, context: String, tokens: [Int]?)?

    private struct Checkpoint {
        let owner: ObjectIdentifier
        let tokens: [Int]
        let layers: [KVCache]
    }

    /// Longest prompt read, in tokens.
    private static let maxPromptTokens = 2_048
    /// Checkpoints sit on multiples of this many tokens…
    private static let step = 64
    /// …and at least this far before the end, so typing a few letters stays after the newest one.
    private static let tail = 24
    /// A long prompt is read in pieces of this many tokens (a multiple of `step`): between pieces a newer request can stop it,
    /// and what was read is kept as a checkpoint for that request.
    private static let readChunk = 256

    init(modelID: String) { self.modelID = modelID }

    func cancel() { lock.withLock { latest += 1 } }
    private func begin() -> Int { lock.withLock { latest += 1; return latest } }
    private func superseded(_ id: Int) -> Bool { lock.withLock { latest != id } }

    func setPersonalization(words: [String: Double], strength: Double) {
        lock.withLock {
            favored = words
            self.strength = Float(strength)
            biasVersion += 1
        }
    }

    func complete(prompt: CompletionPrompt, options: CompletionOptions, partial: (@Sendable (String) -> Void)?) async -> CompletionResult? {
        let id = begin()
        guard let container = try? await EmbeddedModel.shared.completionContainer(modelID) else {
            // The model left memory (or the chat is busy with it): the checkpoint belongs to a model that may be gone.
            lock.withLock { dropCheckpoint = true }
            return nil
        }
        guard !superseded(id) else { return nil }
        let owner = ObjectIdentifier(container)
        let stopStrings = ModelAdvisor.catalog.first { $0.id == modelID }?.family.stopTokens ?? []
        return try? await container.perform { context -> CompletionResult? in
            self.work.withLock {
                self.generate(context: context, owner: owner, prompt: prompt, options: options, stops: stopStrings, partial: partial) {
                    self.superseded(id)
                }
            }
        }
    }

    /// Reads `prompt` up to its checkpoint without writing anything, so the next request only reads the last few tokens. Does
    /// not stop the running request; a newer request stops it between pieces and goes on from what it read.
    func warm(prompt: CompletionPrompt) {
        let id = lock.withLock { latest }
        Task {
            guard let container = try? await EmbeddedModel.shared.completionContainer(self.modelID), !self.superseded(id) else { return }
            let owner = ObjectIdentifier(container)
            _ = try? await container.perform { context -> Bool in
                self.work.withLock { (try? self.prime(context, owner: owner, prompt: prompt) { self.superseded(id) }) != nil }
            }
        }
    }

    func alternatives(prompt: CompletionPrompt, excluding: String, count: Int) async -> [String] {
        let id = begin()
        guard let container = try? await EmbeddedModel.shared.completionContainer(modelID), !superseded(id) else { return [] }
        let owner = ObjectIdentifier(container)
        return (try? await container.perform { context -> [String] in
            self.work.withLock {
                self.rankedWords(context: context, owner: owner, prompt: prompt, excluding: excluding, count: count) { self.superseded(id) }
            }
        }) ?? []
    }

    // MARK: Under the work lock

    /// The prompt in tokens: the user's turn in the model's chat template, then the text as the start of its answer. Without a
    /// template, the prompt as a document. Too long, the text is cut from the front, the request kept.
    private func tokens(_ context: ModelContext, owner: ObjectIdentifier, prompt: CompletionPrompt) -> [Int] {
        if request?.owner != owner || request?.context != prompt.context {
            let message: [String: any Sendable] = ["role": "user", "content": CompletionChat.request(context: prompt.context)]
            // No thinking first (Qwen 3): the answer has to start right away.
            let frame = try? context.tokenizer.applyChatTemplate(messages: [message], tools: nil, additionalContext: ["enable_thinking": false])
            request = (owner, prompt.context, frame)
        }
        guard let frame = request?.tokens, !frame.isEmpty else {
            let tokens = context.tokenizer.encode(text: prompt.document, addSpecialTokens: true)
            return Array(tokens.suffix(Self.maxPromptTokens))
        }
        let text = context.tokenizer.encode(text: prompt.text, addSpecialTokens: false)
        return frame + text.suffix(max(0, Self.maxPromptTokens - frame.count))
    }

    /// A cache that holds the prompt up to the newest usable checkpoint, and the tokens still to be read (at least one).
    private func prime(_ context: ModelContext, owner: ObjectIdentifier, prompt: CompletionPrompt,
                       isCancelled: () -> Bool) throws -> (layers: [KVCache], fresh: [Int], all: [Int])? {
        let tokens = self.tokens(context, owner: owner, prompt: prompt)
        guard !tokens.isEmpty else { return nil }
        if lock.withLock({ () -> Bool in defer { dropCheckpoint = false }; return dropCheckpoint }) { checkpoint = nil }

        var layers: [KVCache]
        var read = 0
        if let saved = checkpoint, saved.owner == owner, saved.tokens.count < tokens.count, tokens.starts(with: saved.tokens) {
            layers = saved.layers.map { $0.copy() }
            read = saved.tokens.count
        } else {
            checkpoint = nil
            layers = context.model.newCache(parameters: nil)
        }
        // Move the checkpoint forward when the prompt has grown a step past it (or there is none yet).
        let target = max(0, ((tokens.count - Self.tail) / Self.step) * Self.step)
        if target - read >= Self.step {
            // In pieces: when a newer request comes in, keep what was read as the checkpoint and stop.
            while read < target {
                let end = min(read + Self.readChunk, target)
                _ = try TokenIterator(input: LMInput(tokens: MLXArray(Array(tokens[read ..< end]))), model: context.model, cache: layers,
                                      processor: nil, sampler: ArgMaxSampler(), prefillStepSize: 512, maxTokens: 0)
                read = end
                if read < target, isCancelled() { break }
            }
            let copies = layers.map { $0.copy() }
            eval(copies.flatMap { $0.state })
            checkpoint = Checkpoint(owner: owner, tokens: Array(tokens[..<read]), layers: copies)
            if read < target { return nil }
        }
        return (layers, Array(tokens[read...]), tokens)
    }

    /// The word bonus as token ids, and the vocabulary-sized array for it, rebuilt only when the words or the model change.
    private func bias(_ tokenizer: MLXLMCommon.Tokenizer, owner: ObjectIdentifier) -> (bias: [Int: Float], array: MLXArray?) {
        let (words, power, version) = lock.withLock { (favored, strength, biasVersion) }
        if let cached = biasCache, cached.owner == owner, cached.version == version { return (cached.bias, cached.array) }
        var result: [Int: Float] = [:]
        if power > 0 {
            for (word, weight) in words {
                // In the middle of a sentence a word starts with a space in most vocabularies.
                guard let token = tokenizer.encode(text: " " + word, addSpecialTokens: false).first else { continue }
                result[token] = max(result[token] ?? 0, Float(weight) * power * 2.5)
            }
        }
        biasCache = (owner, version, result, nil)
        return (result, nil)
    }

    private func keepBiasArray(_ array: MLXArray?, owner: ObjectIdentifier) {
        guard let array, var cached = biasCache, cached.owner == owner, cached.array == nil else { return }
        cached.array = array
        biasCache = cached
    }

    /// Text of `tokens` as it follows `anchor`. SentencePiece tokenizers drop the space at the start of a decoded text, so
    /// decoding the new tokens alone would glue the first word to the word before it.
    private func decode(_ tokenizer: MLXLMCommon.Tokenizer, _ tokens: [Int], after anchor: Int?) -> String {
        guard let anchor else { return tokenizer.decode(tokenIds: tokens, skipSpecialTokens: true) }
        let base = tokenizer.decode(tokenIds: [anchor], skipSpecialTokens: true)
        let whole = tokenizer.decode(tokenIds: [anchor] + tokens, skipSpecialTokens: true)
        return whole.hasPrefix(base) ? String(whole.dropFirst(base.count)) : tokenizer.decode(tokenIds: tokens, skipSpecialTokens: true)
    }

    private func stopIDs(_ context: ModelContext, _ stops: Set<String>) -> Set<Int> {
        var ids = context.configuration.eosTokenIds
        if let eos = context.tokenizer.eosTokenId { ids.insert(eos) }
        for stop in stops { if let id = context.tokenizer.convertTokenToId(stop) { ids.insert(id) } }
        return ids
    }

    private func generate(context: ModelContext, owner: ObjectIdentifier, prompt: CompletionPrompt, options: CompletionOptions, stops: Set<String>,
                          partial: (@Sendable (String) -> Void)?, isCancelled: () -> Bool) -> CompletionResult? {
        guard !isCancelled() else { return nil }
        do {
            guard let (layers, fresh, all) = try prime(context, owner: owner, prompt: prompt, isCancelled: isCancelled), !isCancelled() else { return nil }
            let bonus = bias(context.tokenizer, owner: owner)
            let sampler = ConfidenceSampler(bias: bonus.bias, biasArray: bonus.array)
            let stopIDs = stopIDs(context, stops)
            var kept: [Int] = []
            var truncated = true
            var text = ""
            var reported = 0
            var unfinished = false
            var sure: Float = 1
            var iterator = try TokenIterator(input: LMInput(tokens: MLXArray(fresh)), model: context.model, cache: layers,
                                             processor: nil, sampler: sampler, prefillStepSize: 512, maxTokens: options.maxTokens)
            defer { keepBiasArray(sampler.biasArray, owner: owner) }
            var step = 0
            while let token = iterator.next() {
                let probability = step < sampler.probabilities.count ? sampler.probabilities[step] : 0
                step += 1
                sure *= probability
                if isCancelled() { return nil }
                if step == 1, probability < options.minFirstProbability || sure < options.minSequenceProbability || stopIDs.contains(token) {
                    return nil
                }
                if stopIDs.contains(token) { truncated = false; break }
                if probability < options.minProbability || sure < options.minSequenceProbability {
                    // Not sure any more: end here, and never in the middle of a word.
                    unfinished = CompletionHealing.continuesWord(decode(context.tokenizer, [token], after: kept.last ?? all.last))
                    truncated = false
                    break
                }
                kept.append(token)
                text = decode(context.tokenizer, kept, after: all.last)
                if let newline = text.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                    text = String(text[..<newline])
                    truncated = false
                    break
                }
                if text.completionWordCount > options.maxWords { truncated = false; break }
                // Hand over each finished word right away, so the suggestion appears while the rest is still being written.
                let finished = CompletionStreaming.finishedWords(text)
                if finished > reported, let partial {
                    reported = finished
                    partial(text)
                }
            }
            return CompletionResult(text: text.replacingOccurrences(of: "\u{FFFD}", with: ""), truncated: truncated, unfinished: unfinished)
        } catch {
            checkpoint = nil
            return nil
        }
    }

    private func rankedWords(context: ModelContext, owner: ObjectIdentifier, prompt: CompletionPrompt, excluding: String, count: Int,
                             isCancelled: () -> Bool) -> [String] {
        var text = prompt
        while text.text.last == " " { text.text.removeLast() }
        do {
            guard !isCancelled(), let (layers, fresh, all) = try prime(context, owner: owner, prompt: text, isCancelled: isCancelled) else { return [] }
            let bonus = bias(context.tokenizer, owner: owner)
            let first = ConfidenceSampler(bias: bonus.bias, biasArray: bonus.array, candidates: count * 4)
            // Reading the prompt leaves the cache at its end (the sampled token is not read yet): a starting point for every
            // candidate word.
            _ = try TokenIterator(input: LMInput(tokens: MLXArray(fresh)), model: context.model, cache: layers,
                                  processor: nil, sampler: first, prefillStepSize: 512, maxTokens: 1)
            let start = layers.map { $0.copy() }
            let stopIDs = stopIDs(context, [])
            var results: [String] = []
            for candidate in first.candidates {
                if isCancelled() || results.count == count { break }
                if stopIDs.contains(candidate) { continue }
                var pieces = [candidate]
                var iterator = try TokenIterator(input: LMInput(tokens: MLXArray([candidate])), model: context.model,
                                                 cache: start.map { $0.copy() }, processor: nil, sampler: ArgMaxSampler(),
                                                 prefillStepSize: 512, maxTokens: 4)
                while let next = iterator.next() {
                    // The rest of the same word: letters, and no space before them.
                    let piece = decode(context.tokenizer, [next], after: pieces.last)
                    guard let character = piece.first, character.isLetter || character == "'" else { break }
                    pieces.append(next)
                }
                if let entry = CompletionWords.acceptable(decode(context.tokenizer, pieces, after: all.last), excluding: excluding, among: results) {
                    results.append(entry)
                }
            }
            return results
        } catch {
            checkpoint = nil
            return []
        }
    }
}

/// Greedy choice with the word bonus, remembering how sure the model was of each token (before the bonus) and, when asked,
/// the most likely first tokens.
private final class ConfidenceSampler: LogitSampler {
    let bias: [Int: Float]
    let wanted: Int
    private(set) var biasArray: MLXArray?
    private(set) var probabilities: [Float] = []
    private(set) var candidates: [Int] = []

    init(bias: [Int: Float], biasArray: MLXArray?, candidates: Int = 0) {
        self.bias = bias
        self.biasArray = biasArray
        wanted = candidates
    }

    func sample(logits: MLXArray) -> MLXArray {
        let raw = logits.asType(.float32)
        var scores = raw
        if !bias.isEmpty {
            if biasArray == nil || biasArray?.dim(-1) != raw.dim(-1) {
                var values = [Float](repeating: 0, count: raw.dim(-1))
                for (token, bonus) in bias where token >= 0 && token < values.count { values[token] = bonus }
                biasArray = MLXArray(values)
            }
            if let biasArray { scores = raw + biasArray }
        }
        let token = argMax(scores, axis: -1)
        let id = token.item(Int.self)
        // Softmax over the raw logits, for the chosen token only.
        let shifted = exp(raw - raw.max(axis: -1, keepDims: true))
        probabilities.append((shifted[0, id] / shifted.sum()).item(Float.self))
        if wanted > 0, candidates.isEmpty {
            let order = argSort(-scores, axis: -1)[0, 0 ..< wanted]
            candidates = order.asType(.int32).asArray(Int32.self).map(Int.init)
        }
        return token
    }
}
