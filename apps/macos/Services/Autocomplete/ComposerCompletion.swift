import Foundation

/// Nook's own autocomplete in its composers: while you write to an agent (or to Nook), the rest of the sentence shows as gray
/// text after the caret, as autocomplete does in other apps. It works on its own, without the key tap or Accessibility and
/// whether or not autocomplete is on elsewhere, and it can write with any model Nook has: autocomplete's own, another local
/// model (a GGUF file, the brain's MLX model), or a model API of the brain's providers (`ComposerCompleter`).
enum ComposerCompletion {
    /// The model the composers write with, as kept in `CompletionPreferences.composerModel`.
    enum Choice: Equatable, Hashable {
        /// Autocomplete's own model (its choice in Settings, automatic included).
        case sameAsAutocomplete
        /// A local model: a `CompletionSource.identity` (a GGUF path, or "brain:" and the brain model's id).
        case local(String)
        /// A model API: the brain provider's raw value, and the model (empty: the provider's default).
        case api(provider: String, model: String)

        /// "", "local:<identity>" or "api:<provider>:<model>".
        var stored: String {
            switch self {
            case .sameAsAutocomplete: return ""
            case .local(let identity): return "local:" + identity
            case .api(let provider, let model): return "api:\(provider):\(model)"
            }
        }

        init(stored: String) {
            if stored.hasPrefix("local:"), stored.count > 6 {
                self = .local(String(stored.dropFirst(6)))
            } else if stored.hasPrefix("api:") {
                let rest = stored.dropFirst(4)
                let provider = rest.prefix { $0 != ":" }
                let model = rest.dropFirst(provider.count + 1)
                self = provider.isEmpty ? .sameAsAutocomplete
                    : .api(provider: String(provider), model: String(model).trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                self = .sameAsAutocomplete
            }
        }
    }

    /// What the message is written in: the agent it goes to, the project, and what the agent said last.
    struct Situation: Equatable {
        var recipient: String?
        var project: String?
        var lastAnswer: String?
    }

    /// Characters of the agent's last answer that go along: its end, where it asks or reports.
    static let answerLength = 1_500
    /// Characters of the message so far that a model API reads (and writes back): enough for the sentence and the one before.
    static let apiTextLength = 400

    /// Whether to ask for a suggestion: something typed, the caret at the end of its line, and not on a line that a list
    /// (`/` commands) or a name (`ComposerInlineName`) takes.
    static func asks(before: String, after: String) -> Bool {
        guard before.contains(where: { !$0.isWhitespace }), before.last?.isNewline != true else { return false }
        guard after.prefix(while: { !$0.isNewline }).allSatisfy(\.isWhitespace) else { return false }
        let line = before.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        if line.hasPrefix("/") { return false }
        // A word that starts a list (`@file`, `#12`, `$skill`) has its own list under the box.
        let word = line.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        if !(line.last?.isWhitespace ?? true), let first = word.first, "@#$".contains(first) { return false }
        return true
    }

    /// The context a local model reads (`PromptBuilder`): Nook as the app, the recipient as the window, the agent's last
    /// answer as the text on screen, so the suggestion fits the conversation.
    static func context(before: String, after: String, situation: Situation, hint: String?) -> CompletionContext {
        var input = CompletionContext(before: before)
        input.after = after
        input.appName = "Nook"
        input.windowTitle = title(situation)
        input.fieldHint = hint
        input.screenText = situation.lastAnswer.map { String($0.suffix(answerLength)) }
        return input
    }

    private static func title(_ situation: Situation) -> String? {
        switch (situation.recipient, situation.project) {
        case (let recipient?, let project?): return "Message to \(recipient) about \(project)"
        case (let recipient?, nil): return "Message to \(recipient)"
        case (nil, let project?): return "Message about \(project)"
        case (nil, nil): return nil
        }
    }

    /// The request to a chat model API. It answers with the end of the message written back and its continuation: an API
    /// trims the spaces around its answer, and echoing the text is what keeps the space (or none, in the middle of a word)
    /// between what you typed and what comes next.
    static func apiPrompt(before: String, situation: Situation, instructions: [String]) -> String {
        var lines = [
            "Someone is typing a message\(title(situation).map { " (\($0.prefix(1).lowercased() + $0.dropFirst()))" } ?? "").",
            "Guess how it goes on: a few words, at most the end of the sentence, in the same language and style.",
            "Answer with the TEXT below written out exactly as it is, character for character, followed directly by your continuation.",
            "No quotes, no explanation. If you cannot guess, answer with the TEXT unchanged.",
        ]
        let rules = instructions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !rules.isEmpty { lines.append("\nThe writer's own instructions:\n" + rules.joined(separator: "\n")) }
        if let answer = situation.lastAnswer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
            lines.append("\nWhat the message answers (the end of the last reply):\n" + String(answer.suffix(answerLength)))
        }
        lines.append("\nTEXT:\n" + apiText(before))
        return lines.joined(separator: "\n")
    }

    /// The end of the message an API reads and writes back.
    static func apiText(_ before: String) -> String { String(before.suffix(apiTextLength)) }

    /// The continuation in an API's answer to `apiPrompt`: what follows the text it wrote back. A model that did not write
    /// it back whole is still understood when its answer starts with the last words; nil when it only repeated the text or
    /// answered something else.
    static func continuation(of answer: String, before: String) -> String? {
        var text = answer
        // A code fence or quotes around the whole answer.
        if text.hasPrefix("```") {
            text = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if let fence = text.range(of: "```", options: .backwards) { text = String(text[..<fence.lowerBound]) }
        }
        let typed = apiText(before)
        let trimmedTyped = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        for quote in ["\"", "“", "'"] where text.hasPrefix(quote) && !trimmedTyped.hasPrefix(quote) {
            text.removeFirst()
            if text.hasSuffix(quote == "“" ? "”" : quote) { text.removeLast() }
        }
        var rest: Substring?
        if let range = text.range(of: typed, options: [.anchored]) {
            rest = text[range.upperBound...]
        } else if typed.last?.isWhitespace == true, let range = text.range(of: trimmedTyped, options: [.anchored]) {
            // The API took the space you typed off the end: what follows starts without it.
            rest = text[range.upperBound...].drop(while: { $0 == " " })
        } else {
            // Written back with small changes: find the last words where the answer has them.
            let tail = String(trimmedTyped.suffix(24))
            guard tail.count >= 4, let range = text.range(of: tail, options: [.backwards, .caseInsensitive]) else { return nil }
            rest = text[range.upperBound...]
            if typed.last?.isWhitespace == true { rest = rest?.drop(while: { $0 == " " }) }
        }
        guard let rest, rest.contains(where: { !$0.isWhitespace }) else { return nil }
        return String(rest)
    }

    /// Where the text stands after `inserted` was put in at `caret`: the suggestion goes on with what is left of it when the
    /// insertion is its beginning (typed through, or a word taken), nil otherwise.
    static func carried(_ suggestion: CompletionSuggestion, inserted: String) -> CompletionSuggestion? {
        guard !inserted.isEmpty, suggestion.remaining.hasPrefix(inserted) else { return nil }
        let rest = String(suggestion.remaining.dropFirst(inserted.count))
        guard rest.contains(where: { !$0.isWhitespace }) else { return nil }
        return CompletionSuggestion(rest)
    }
}
