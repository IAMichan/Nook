import Foundation

/// A model that continues text for autocomplete. Two kinds: `LlamaCompleter` (a GGUF file through llama.cpp) and
/// `BrainCompleter` (the model Nook's brain downloaded, through MLX). Both work the same way: greedy, with a certainty
/// threshold, the prompt kept in the model's cache between keys, a bonus for the user's own words, and other words to pick.
protocol CompletionEngine: AnyObject, Sendable {
    /// The source it runs (`CompletionSource.identity`).
    var identity: String { get }
    /// Makes the running request stop at its next token.
    func cancel()
    /// Continues `prompt`; nil when superseded, not sure enough, busy, or failed. `partial` gets the text so far each time
    /// another word is finished, so the suggestion can show before the model is done.
    func complete(prompt: String, options: CompletionOptions, partial: (@Sendable (String) -> Void)?) async -> CompletionResult?
    /// Words that could come next, most likely first, each with the space before it when the model would put one there.
    func alternatives(prompt: String, excluding: String, count: Int) async -> [String]
    /// Leans generation toward words the user writes often. Strength 0 turns it off.
    func setPersonalization(words: [String: Double], strength: Double)
}

enum CompletionWords {
    /// Whether a generated piece of word is fine as an alternative: letters, an apostrophe or a hyphen, at least two letters,
    /// not the word it replaces, not one already listed.
    static func acceptable(_ raw: String, excluding: String, among results: [String]) -> String? {
        let word = raw.trimmingCharacters(in: .whitespaces)
        let entry = (raw.first == " " ? " " : "") + word
        guard word.count >= 2, word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }), word.lowercased() != excluding.lowercased(),
              !results.contains(where: { $0.lowercased() == entry.lowercased() }) else { return nil }
        return entry
    }
}
