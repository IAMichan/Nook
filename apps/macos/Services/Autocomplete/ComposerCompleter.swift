import Foundation

/// Asks the composer's model for the rest of the sentence (`ComposerCompletion`): a local model through autocomplete's
/// engines (`AutocompleteController.composerSuggestion`), or a model API of the brain's providers through the same request
/// as the session titles (`TextGeneratorAPI`). One request at a time: a newer key cancels the one before.
@MainActor
final class ComposerCompleter {
    static let shared = ComposerCompleter()

    private var work: Task<Void, Never>?
    private var store: AutocompleteStore { .shared }

    /// On in Settings › Autocomplete (it is by default), whatever autocomplete does in other apps.
    var isOn: Bool { store.prefs.composerSuggestions }

    var choice: ComposerCompletion.Choice { ComposerCompletion.Choice(stored: store.prefs.composerModel) }

    /// A local model answers a moment after the last key; an API, which costs a request, once you pause.
    private func delay(for choice: ComposerCompletion.Choice) -> UInt64 {
        if case .api = choice { return 450_000_000 }
        return 120_000_000
    }

    /// Asks for a suggestion for `before`, the text up to the caret, once typing pauses. `deliver` gets it on the main actor
    /// (nil: nothing to suggest), unless a newer request or `cancel()` came first.
    func suggest(before: String, after: String, situation: ComposerCompletion.Situation, hint: String?,
                 deliver: @escaping @MainActor (CompletionSuggestion?) -> Void) {
        cancel()
        guard isOn, ComposerCompletion.asks(before: before, after: after) else { return }
        let choice = self.choice
        let wait = delay(for: choice)
        work = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait)
            guard !Task.isCancelled, let self else { return }
            let suggestion = await self.ask(choice, before: before, after: after, situation: situation, hint: hint)
            guard !Task.isCancelled else { return }
            deliver(suggestion)
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        AutocompleteController.shared.cancelComposerSuggestion()
    }

    private func ask(_ choice: ComposerCompletion.Choice, before: String, after: String,
                     situation: ComposerCompletion.Situation, hint: String?) async -> CompletionSuggestion? {
        let prefs = store.prefs
        switch choice {
        case .sameAsAutocomplete, .local:
            let identity: String
            if case .local(let chosen) = choice { identity = chosen } else { identity = "" }
            let input = ComposerCompletion.context(before: before, after: after, situation: situation, hint: hint)
            return await AutocompleteController.shared.composerSuggestion(input, identity: identity)
        case .api(let raw, let model):
            guard let provider = AIProvider(rawValue: raw), !provider.isSubscription else { return nil }
            let route = TextGenerationRoute.resolve(.api(provider, model: model), key: { SecretStore.read($0.keyAccount) })
            guard case .api(let api, let name, let key) = route else { return nil }
            let prompt = ComposerCompletion.apiPrompt(before: before, situation: situation,
                                                      instructions: prefs.instructions(app: nil, site: nil))
            do {
                let request = try TextGeneratorAPI.request(provider: api, model: name, key: key, prompt: prompt, schema: nil,
                                                           maxTokens: 400, timeout: 10)
                let (data, status) = try await URLSessionTextTransport().send(request)
                let answer = try TextGeneratorAPI.answerText(provider: api, data: data, status: status)
                guard let rest = ComposerCompletion.continuation(of: answer, before: before) else { return nil }
                return CompletionSuggestion.make(raw: rest, before: before, after: after, maxWords: prefs.maxWords)
            } catch {
                Log.autocomplete.info("composer suggestion from \(api.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }
}
