import SwiftUI

/// Settings › Autocomplete › General › In Nook's composers: the suggested next prompt in an empty composer (the same switch
/// as Settings › Sessions › Text generation), the rest of the sentence while you write to an agent or to Nook
/// (`ComposerCompleter`) on its own switch, and the model it writes with: autocomplete's own, any local model on this Mac
/// (the brain's MLX models, GGUF files), your subscription (Claude Code or Codex), or a model API of the brain's
/// providers, with its model name and key as on the Text generation page.
struct ComposerAutocompleteSection: View {
    @ObservedObject private var store = AutocompleteStore.shared
    @ObservedObject private var autocomplete = AutocompleteController.shared
    @ObservedObject private var brain = AppSettings.shared
    @ObservedObject private var ws = WorkspaceSettings.shared
    @State private var modelDraft = ""

    private var choice: ComposerCompletion.Choice { ComposerCompletion.Choice(stored: store.prefs.composerModel) }

    var body: some View {
        Section {
            SettingToggle(tr("textgen.next.setting"), detail: tr("textgen.next.setting.detail"), isOn: $ws.suggestNextPrompt)
            SettingToggle(tr("autocomplete.composer.enable"), detail: tr("autocomplete.composer.enableDetail"),
                          isOn: $store.prefs.composerSuggestions)
            if store.prefs.composerSuggestions {
                Picker(selection: pickerSelection) {
                    Text(sameLabel).tag("")
                    Section(tr("autocomplete.composer.local")) {
                        ForEach(autocomplete.brainModels, id: \.id) { model in
                            Text("\(model.title) · \(tr("autocomplete.source.brain"))")
                                .tag(ComposerCompletion.Choice.local(CompletionSource.brainPrefix + model.id).stored)
                        }
                        ForEach(autocomplete.candidates) { model in
                            Text("\(model.title) · \(model.sizeText)").tag(ComposerCompletion.Choice.local(model.url.path).stored)
                        }
                        if case .local(let identity) = choice, !knownLocal(identity) {
                            Text((identity as NSString).lastPathComponent).tag(choice.stored)
                        }
                    }
                    Section(tr("autocomplete.composer.subscription")) {
                        Text(tr("autocomplete.composer.agent")).tag(ComposerCompletion.Choice.agent.stored)
                    }
                    Section(tr("autocomplete.composer.api")) {
                        ForEach(TextGenerator.apiProviders) { provider in
                            Text(apiLabel(provider)).tag(ComposerCompletion.Choice.api(provider: provider.rawValue, model: "").stored)
                        }
                    }
                } label: {
                    SettingText("autocomplete.composer.model")
                }
                if case .api(let raw, _) = choice, let provider = AIProvider(rawValue: raw) {
                    TextField(tr("textgen.model"), text: $modelDraft,
                              prompt: Text(provider.defaultModel.isEmpty ? tr("textgen.model.loaded") : provider.defaultModel))
                        .onSubmit { saveModel(provider) }
                        .onAppear { modelDraft = currentModel }
                        .onChange(of: store.prefs.composerModel) { _, _ in modelDraft = currentModel }
                    if provider.needsKey && !brain.hasKey(for: provider) {
                        SettingNote(tr("autocomplete.composer.keyMissing", name(provider)), tone: .warning)
                    }
                    SettingNote(tr("autocomplete.composer.apiNote", name(provider)))
                } else if case .agent = choice {
                    SettingNote(tr("autocomplete.composer.agentNote"))
                } else if autocomplete.brainModels.isEmpty, autocomplete.candidates.isEmpty {
                    SettingNote(tr("autocomplete.composer.noLocal"), tone: .warning)
                }
            }
        } header: {
            SettingsSectionTitle(tr("autocomplete.composer.section"), info: tr("autocomplete.composer.info"))
        }
        .task {
            // With autocomplete off elsewhere it has not looked for models yet.
            if autocomplete.candidates.isEmpty, autocomplete.brainModels.isEmpty { await autocomplete.scanModels() }
        }
    }

    /// The picker's tag for the choice: an API by its provider only (its model is typed below).
    private var pickerSelection: Binding<String> {
        Binding(get: {
            if case .api(let provider, _) = choice { return ComposerCompletion.Choice.api(provider: provider, model: "").stored }
            return choice.stored
        }, set: { tag in
            let picked = ComposerCompletion.Choice(stored: tag)
            // The same provider again keeps the model typed for it.
            if case .api(let provider, _) = picked, case .api(provider, _) = choice { return }
            store.prefs.composerModel = picked.stored
        })
    }

    private var sameLabel: String {
        let model = autocomplete.activeModel?.title ?? tr("autocomplete.modelAuto")
        return tr("autocomplete.composer.same", model)
    }

    private func knownLocal(_ identity: String) -> Bool {
        if identity.hasPrefix(CompletionSource.brainPrefix) {
            return autocomplete.brainModels.contains { CompletionSource.brainPrefix + $0.id == identity }
        }
        return autocomplete.candidates.contains { $0.url.path == identity }
    }

    private var currentModel: String {
        if case .api(_, let model) = choice { return model }
        return ""
    }

    private func saveModel(_ provider: AIProvider) {
        let model = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        store.prefs.composerModel = ComposerCompletion.Choice.api(provider: provider.rawValue, model: model).stored
    }

    private func name(_ provider: AIProvider) -> String {
        provider.textWire == .anthropicMessages ? tr("settings.brain.claude") + " · " + tr("settings.brain.apiKey") : provider.title
    }

    /// The provider, and whether it can answer yet: a key is missing, or it runs on this Mac.
    private func apiLabel(_ provider: AIProvider) -> String {
        if provider.needsKey && !brain.hasKey(for: provider) { return name(provider) + " · " + tr("autocomplete.composer.noKey") }
        if provider.isLocalServer { return name(provider) + " · " + tr("autocomplete.composer.onThisMac") }
        return name(provider)
    }
}
