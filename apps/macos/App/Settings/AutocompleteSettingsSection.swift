import SwiftUI
import UniformTypeIdentifiers

/// Settings › Voice & sound › Autocomplete anywhere.
struct AutocompleteSettingsSection: View {
    @ObservedObject private var store = AutocompleteStore.shared
    @ObservedObject private var autocomplete = AutocompleteController.shared

    var body: some View {
        Section {
            SettingToggle(tr("autocomplete.enable"), detail: tr("autocomplete.enableDetail", store.acceptKey.symbol), isOn: $store.enabled)
                .onChange(of: store.enabled) { _, on in
                    if on, !autocomplete.trusted { autocomplete.askForAccessibility() }
                    autocomplete.refresh()
                }
            if store.enabled {
                status
                Picker(tr("autocomplete.model"), selection: $store.modelPath) {
                    Text(tr("autocomplete.modelAuto")).tag("")
                    ForEach(autocomplete.candidates) { model in
                        Text("\(model.title) · \(model.sizeText)").tag(model.url.path)
                    }
                    if !store.modelPath.isEmpty, !autocomplete.candidates.contains(where: { $0.url.path == store.modelPath }) {
                        Text(URL(fileURLWithPath: store.modelPath).lastPathComponent).tag(store.modelPath)
                    }
                }
                .onChange(of: store.modelPath) { _, _ in autocomplete.refresh() }
                LabeledContent(tr("autocomplete.modelFile")) {
                    HStack {
                        Button(tr("autocomplete.choose")) { chooseFile() }
                        Button(tr("autocomplete.rescan")) { autocomplete.refresh() }
                    }
                }
                Picker(tr("autocomplete.key"), selection: $store.acceptKey) {
                    ForEach(CompletionAcceptKey.allCases) { Text($0.symbol).tag($0) }
                }
            }
        } header: {
            Text(tr("autocomplete.title"))
        } footer: {
            Text(tr("autocomplete.privacy"))
        }
    }

    @ViewBuilder private var status: some View {
        switch autocomplete.state {
        case .noAccess:
            StatusRow(title: tr("autocomplete.access"), detail: tr("autocomplete.accessDetail"), state: .warning) {
                Button(tr("flow.settings.allow")) { autocomplete.openAccessibilitySettings() }
            }
        case .noModel:
            StatusRow(title: tr("autocomplete.noModel"), detail: tr("autocomplete.noModelDetail"), state: .warning) { EmptyView() }
        case .failed(let message):
            StatusRow(title: tr("autocomplete.failed"), detail: message, state: .error) { EmptyView() }
        case .loading:
            StatusRow(title: tr("autocomplete.loading"), detail: autocomplete.activeModel?.title ?? "", state: .todo) { EmptyView() }
        case .ready:
            StatusRow(title: tr("autocomplete.ready"), detail: autocomplete.activeModel.map { "\($0.title) · \($0.url.path)" } ?? "", state: .done) { EmptyView() }
        case .off:
            EmptyView()
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let gguf = UTType(filenameExtension: "gguf") { panel.allowedContentTypes = [gguf] }
        panel.directoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.modelPath = url.path
    }
}
