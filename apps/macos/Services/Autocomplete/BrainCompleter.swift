import Foundation
import MLX
import MLXLMCommon

/// Autocomplete on the model Nook's brain already downloaded (MLX), so nothing else has to be downloaded. It works like
/// `LlamaCompleter`:
/// - greedy, with the certainty threshold: when the model is not sure, nothing is shown, and a suggestion ends where its
///   certainty drops;
/// - the prompt stays in its own key-value cache, and the next request only reads what changed (models whose cache cannot
///   be cut back, like hybrid ones, read the whole prompt again);
/// - words the user writes often get a bonus;
/// - other words to pick.
///
/// A chat answer always goes first: while the brain is writing one, autocomplete waits it out (and shows nothing).
/// Chat models continue plain text well, but base models are better at it; a GGUF base model stays the best choice.
final class BrainCompleter: CompletionEngine, @unchecked Sendable {
    let modelID: String
    var identity: String { CompletionSource.brainPrefix + modelID }

    private let lock = NSLock()
    private var latest = 0
    /// Only one generation touches the cache at a time.
    private let work = NSLock()
    private var cache: CacheState?
    private var favored: [String: Double] = [:]
    private var strength: Float = 0
    /// Longest prompt read, in tokens.
    private static let maxPromptTokens = 3_000

    /// What this completer's cache holds, for which loaded model.
    private final class CacheState {
        let owner: ObjectIdentifier
        var layers: [KVCache]
        var tokens: [Int]
        var bias: [Int: Float]?

        init(owner: ObjectIdentifier, layers: [KVCache]) {
            self.owner = owner
            self.layers = layers
            tokens = []
        }
    }

    init(modelID: String) { self.modelID = modelID }

    func cancel() { lock.withLock { latest += 1 } }
    private func begin() -> Int { lock.withLock { latest += 1; return latest } }
    private func superseded(_ id: Int) -> Bool { lock.withLock { latest != id } }

    func setPersonalization(words: [String: Double], strength: Double) {
        work.withLock {
            favored = words
            self.strength = Float(strength)
            cache?.bias = nil
        }
    }

    func complete(prompt: String, options: CompletionOptions) async -> CompletionResult? {
        let id = begin()
        guard let container = try? await EmbeddedModel.shared.completionContainer(modelID), !superseded(id) else { return nil }
        let owner = ObjectIdentifier(container)
        let stopStrings = ModelAdvisor.catalog.first { $0.id == modelID }?.family.stopTokens ?? []
        return try? await container.perform { context -> CompletionResult? in
            self.work.withLock {
                self.generate(context: context, owner: owner, prompt: prompt, options: options, stops: stopStrings) { self.superseded(id) }
            }
        }
    }

    func alternatives(prompt: String, excluding: String, count: Int) async -> [String] {
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

    /// Puts the prompt in the cache, reusing what it shares with the last one, and returns the tokens still to be read
    /// (at least one, for fresh logits).
    private func prime(_ context: ModelContext, owner: ObjectIdentifier, prompt: String) -> (state: CacheState, fresh: [Int], all: [Int])? {
        var tokens = context.tokenizer.encode(text: prompt, addSpecialTokens: true)
        if tokens.count > Self.maxPromptTokens { tokens.removeFirst(tokens.count - Self.maxPromptTokens) }
        guard !tokens.isEmpty else { return nil }

        var state: CacheState
        var shared = 0
        if let cached = cache, cached.owner == owner, cached.layers.first?.offset == cached.tokens.count {
            state = cached
            shared = min(zip(tokens, cached.tokens).prefix { $0 == $1 }.count, tokens.count - 1)
            let excess = cached.tokens.count - shared
            if excess > 0 {
                if cached.layers.allSatisfy(\.isTrimmable) {
                    for layer in cached.layers { layer.trim(excess) }
                } else {
                    state = CacheState(owner: owner, layers: context.model.newCache(parameters: nil))
                    shared = 0
                }
            }
        } else {
            state = CacheState(owner: owner, layers: context.model.newCache(parameters: nil))
        }
        state.tokens = Array(tokens[..<shared])
        if state.bias == nil { state.bias = bias(context.tokenizer) }
        cache = state
        return (state, Array(tokens[shared...]), tokens)
    }

    private func bias(_ tokenizer: MLXLMCommon.Tokenizer) -> [Int: Float] {
        guard strength > 0 else { return [:] }
        var result: [Int: Float] = [:]
        for (word, weight) in favored {
            // In the middle of a sentence a word starts with a space in most vocabularies.
            guard let token = tokenizer.encode(text: " " + word, addSpecialTokens: false).first else { continue }
            result[token] = max(result[token] ?? 0, Float(weight) * strength * 2.5)
        }
        return result
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

    private func generate(context: ModelContext, owner: ObjectIdentifier, prompt: String, options: CompletionOptions, stops: Set<String>,
                          isCancelled: () -> Bool) -> CompletionResult? {
        guard !isCancelled(), let (state, fresh, all) = prime(context, owner: owner, prompt: prompt) else { return nil }
        let sampler = ConfidenceSampler(bias: state.bias ?? [:])
        let stopIDs = stopIDs(context, stops)
        var generated: [Int] = []
        var kept: [Int] = []
        var truncated = true
        var text = ""
        do {
            var iterator = try TokenIterator(input: LMInput(tokens: MLXArray(fresh)), model: context.model, cache: state.layers,
                                             processor: nil, sampler: sampler, prefillStepSize: 512, maxTokens: options.maxTokens)
            var step = 0
            while let token = iterator.next() {
                generated.append(token)
                let probability = step < sampler.probabilities.count ? sampler.probabilities[step] : 0
                step += 1
                if isCancelled() { state.tokens = all + generated; return nil }
                if step == 1, probability < options.minFirstProbability { state.tokens = all + generated; return nil }
                if probability < options.minProbability || stopIDs.contains(token) { truncated = false; break }
                kept.append(token)
                text = decode(context.tokenizer, kept, after: all.last)
                if let newline = text.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                    text = String(text[..<newline])
                    truncated = false
                    break
                }
                if text.completionWordCount > options.maxWords { truncated = false; break }
            }
        } catch {
            cache = nil
            return nil
        }
        // Every token the iterator handed out has been read into the cache.
        state.tokens = all + generated
        return CompletionResult(text: text.replacingOccurrences(of: "\u{FFFD}", with: ""), truncated: truncated)
    }

    private func rankedWords(context: ModelContext, owner: ObjectIdentifier, prompt: String, excluding: String, count: Int,
                             isCancelled: () -> Bool) -> [String] {
        var text = prompt
        while text.last == " " { text.removeLast() }
        guard !isCancelled(), let (state, fresh, all) = prime(context, owner: owner, prompt: text) else { return [] }
        let first = ConfidenceSampler(bias: state.bias ?? [:], candidates: count * 4)
        do {
            var iterator = try TokenIterator(input: LMInput(tokens: MLXArray(fresh)), model: context.model, cache: state.layers,
                                             processor: nil, sampler: first, prefillStepSize: 512, maxTokens: 1)
            if let token = iterator.next() { state.tokens = all + [token] } else { state.tokens = all }
        } catch {
            cache = nil
            return []
        }
        let length = all.count
        let canRewind = state.layers.allSatisfy(\.isTrimmable)
        var results: [String] = []
        for candidate in first.candidates {
            if isCancelled() || results.count == count { break }
            if context.configuration.eosTokenIds.contains(candidate) || candidate == context.tokenizer.eosTokenId { continue }
            var pieces = [candidate]
            if canRewind {
                // Back to the end of the prompt, then spell out the rest of the word.
                let excess = (state.layers.first?.offset ?? length) - length
                if excess > 0 { for layer in state.layers { layer.trim(excess) } }
                state.tokens = all
                if var iterator = try? TokenIterator(input: LMInput(tokens: MLXArray([candidate])), model: context.model, cache: state.layers,
                                                     processor: nil, sampler: ConfidenceSampler(bias: [:]), prefillStepSize: 512, maxTokens: 4) {
                    while let next = iterator.next() {
                        let piece = context.tokenizer.decode(tokenIds: [next], skipSpecialTokens: true)
                        guard let character = piece.first, character.isLetter || character == "'" else { break }
                        pieces.append(next)
                    }
                    state.tokens = all + [candidate]
                }
                // What the cache holds after this is uncertain; let the next request start clean.
                cache = nil
            }
            let raw = decode(context.tokenizer, pieces, after: all.last)
            if let entry = CompletionWords.acceptable(raw, excluding: excluding, among: results) { results.append(entry) }
        }
        return results
    }
}

/// Greedy choice with the word bonus, remembering how sure the model was of each token (before the bonus) and, when asked,
/// the most likely first tokens.
private final class ConfidenceSampler: LogitSampler {
    let bias: [Int: Float]
    let wanted: Int
    private var biasArray: MLXArray?
    private(set) var probabilities: [Float] = []
    private(set) var candidates: [Int] = []

    init(bias: [Int: Float], candidates: Int = 0) {
        self.bias = bias
        wanted = candidates
    }

    func sample(logits: MLXArray) -> MLXArray {
        let raw = logits.asType(.float32)
        var scores = raw
        if !bias.isEmpty {
            if biasArray == nil {
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
        let probability = (shifted[0, id] / shifted.sum()).item(Float.self)
        probabilities.append(probability)
        if wanted > 0, candidates.isEmpty {
            let order = argSort(-scores, axis: -1)[0, 0 ..< wanted]
            candidates = order.asType(.int32).asArray(Int32.self).map(Int.init)
        }
        return token
    }
}
