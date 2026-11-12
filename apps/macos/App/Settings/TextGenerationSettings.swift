import SwiftUI

/// Settings › Sessions › Text generation: per kind of text, who writes it (the coding agent's CLI or a model API with
/// its model), a Test that has the chosen model answer a tiny prompt, the key when the service needs one, and the
/// suggested next prompt.
struct TextGenerationSection: View {
    @ObservedObject private var ws = WorkspaceSettings.shared

    var body: some View {
        Section {
            SettingToggle(tr("textgen.next.setting"), detail: tr("textgen.next.setting.detail"), isOn: $ws.suggestNextPrompt)
            ForEach(TextTask.allCases) { task in
                TextGeneratorRow(task: task, generator: Binding(get: { ws.textGenerator(for: task) },
                                                                set: { ws.setTextGenerator($0, for: task) }))
            }
        } header: {
            SettingsSectionTitle(tr("textgen.section"), info: tr("textgen.section.info"))
        }
    }
}

/// One kind of text: the generator picker, and for an API its model, its key (saved on Return), and the same
/// "Connection" row as the Brain page.
private struct TextGeneratorRow: View {
    let task: TextTask
    @Binding var generator: TextGenerator
    @ObservedObject private var brain = AppSettings.shared
    @State private var modelDraft = ""
    @State private var keyDraft = ""
    @State private var testing = false
    @State private var result: (ok: Bool, message: String)?

    var body: some View {
        Picker(selection: Binding(get: { generator.provider }, set: { provider in
            generator = provider.map { .api($0, model: "") } ?? .agent
            result = nil
        })) {
            Text(tr("textgen.generator.agent")).tag(AIProvider?.none)
            Divider()
            ForEach(TextGenerator.apiProviders) { provider in
                Text(name(provider)).tag(AIProvider?.some(provider))
            }
        } label: {
            SettingText("textgen.task." + task.rawValue)
        }
        if let provider = generator.provider {
            TextField(tr("textgen.model"), text: $modelDraft,
                      prompt: Text(provider.defaultModel.isEmpty ? tr("textgen.model.loaded") : provider.defaultModel))
                .onSubmit { saveModel(provider) }
                .onChange(of: modelDraft) { _, _ in result = nil }
                .onAppear { modelDraft = currentModel }
                .onChange(of: generator) { _, _ in modelDraft = currentModel }
            if provider.needsKey && !brain.hasKey(for: provider) {
                SecureField(tr("textgen.key"), text: $keyDraft, prompt: Text(provider.keyPlaceholder))
                    .onSubmit { saveKey(provider) }
                SettingNote(tr("textgen.key.missing", name(provider)) + " " + tr("textgen.key.onReturn"))
            }
            ConnectionTestRow(testing: testing, result: result,
                              disabled: provider.needsKey && !brain.hasKey(for: provider)) {
                Task { await test(provider) }
            }
        }
    }

    private var currentModel: String {
        if case .api(_, let model) = generator { return model }
        return ""
    }

    private func name(_ provider: AIProvider) -> String {
        provider.textWire == .anthropicMessages ? tr("settings.brain.claude") + " · " + tr("settings.brain.apiKey") : provider.title
    }

    private func saveModel(_ provider: AIProvider) {
        let model = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if generator != .api(provider, model: model) { generator = .api(provider, model: model) }
    }

    private func saveKey(_ provider: AIProvider) {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let error = brain.saveProviderKey(key, for: provider)
        if let error {
            ToastCenter.shared.error(tr("settings.brain.keyNotSaved"), detail: error)
        } else {
            keyDraft = ""
            ToastCenter.shared.success(tr("settings.brain.keySaved"))
        }
    }

    private func test(_ provider: AIProvider) async {
        saveModel(provider)
        testing = true
        defer { testing = false }
        let route = TextGenerationRoute.resolve(generator, key: { SecretStore.read($0.keyAccount) })
        guard case .api(let api, let model, let key) = route else {
            result = (false, tr("textgen.key.missing", name(provider)))
            return
        }
        do {
            let answer = try await TextGeneratorAPI.test(provider: api, model: model, key: key)
            result = (true, tr("textgen.test.ok", model.isEmpty ? name(api) : model, String(answer.prefix(40))))
        } catch {
            result = (false, error.localizedDescription)
        }
    }
}
