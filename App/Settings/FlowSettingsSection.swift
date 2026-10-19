import SwiftUI

/// Settings › Voice & sound › Dictate anywhere (Flow).
struct FlowSettingsSection: View {
    @ObservedObject private var store = FlowStore.shared
    @ObservedObject private var flow = FlowDictation.shared
    @State private var dictionary = FlowStore.shared.dictionaryText

    var body: some View {
        Section {
            SettingToggle(tr("flow.settings.enable"), detail: tr("flow.settings.enableDetail", store.key.symbol), isOn: $store.enabled)
                .onChange(of: store.enabled) { _, on in
                    if on, !flow.trusted { flow.askForAccessibility() }
                    flow.refresh()
                }
            if store.enabled {
                Picker(tr("flow.settings.key"), selection: $store.key) {
                    ForEach(FlowKey.allCases) { key in
                        Text(key == .fn ? "fn" : tr("flow.settings.keyRight", key.symbol)).tag(key)
                    }
                }
                .onChange(of: store.key) { _, _ in flow.refresh() }
                if !flow.trusted {
                    StatusRow(title: tr("flow.settings.access"), detail: tr("flow.settings.accessDetail"), state: .warning) {
                        Button(tr("flow.settings.allow")) { flow.openAccessibilitySettings() }
                    }
                }
                SettingToggle(tr("flow.settings.cleanup"), detail: tr("flow.settings.cleanupDetail"), isOn: $store.cleanup)
                SettingToggle(tr("flow.settings.prompt"), detail: tr("flow.settings.promptDetail"), isOn: $store.promptMode)
                Picker(tr("flow.settings.translate"), selection: $store.translateTo) {
                    Text(tr("flow.settings.asSpoken")).tag("")
                    ForEach(["Nederlands", "English", "Deutsch", "Français", "Español"], id: \.self) { Text($0).tag($0) }
                }
                SettingToggle(tr("flow.settings.history"), detail: tr("flow.settings.historyDetail"), isOn: $store.keepHistory)
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("flow.settings.dictionary"))
                    TextEditor(text: $dictionary)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 90)
                        .onChange(of: dictionary) { _, value in store.dictionaryText = value }
                    Text(tr("flow.settings.dictionaryHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.stats.totalWords > 0 {
                    LabeledContent(tr("flow.settings.stats")) {
                        Text(tr("flow.settings.statsLine", store.stats.totalWords, store.wordsPerMinute, Int(store.minutesSaved.rounded()), store.streak))
                            .foregroundStyle(.secondary)
                    }
                }
                if !store.history.isEmpty {
                    DisclosureGroup(tr("flow.settings.recent")) {
                        ForEach(store.history.prefix(8)) { entry in
                            HStack(alignment: .top) {
                                Text(entry.text).lineLimit(2).font(.callout)
                                Spacer()
                                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.text, forType: .string) } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .help(tr("flow.settings.copy"))
                            }
                        }
                        Button(tr("flow.settings.clearHistory")) { store.clearHistory() }
                    }
                }
            }
        } header: {
            Text(tr("flow.settings.title"))
        } footer: {
            Text(tr("flow.settings.footer"))
        }
    }
}

/// Settings › Voice & sound › Parakeet: download, use or remove the offline speech recognition.
struct ParakeetSettingsSection: View {
    @ObservedObject private var parakeet = Parakeet.shared

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("parakeet.title"))
                    Text(parakeet.state == .unsupported ? tr("parakeet.unsupported") : tr("parakeet.detail"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                switch parakeet.state {
                case .unsupported:
                    EmptyView()
                case .missing:
                    Button(tr("parakeet.download")) { parakeet.download() }
                case .downloading(let fraction):
                    VStack(alignment: .trailing, spacing: 2) {
                        ProgressView(value: fraction).frame(width: 110)
                        Text(tr("parakeet.downloading", Int(fraction * 100))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                case .ready:
                    Button(tr("parakeet.remove"), role: .destructive) { parakeet.remove() }
                case .failed(let why):
                    VStack(alignment: .trailing, spacing: 2) {
                        Button(tr("parakeet.download")) { parakeet.download() }
                        Text(why).font(.caption).foregroundStyle(.orange).lineLimit(2)
                    }
                }
            }
            if parakeet.isReady {
                Toggle(tr("parakeet.use"), isOn: $parakeet.enabled)
            }
        }
    }
}
