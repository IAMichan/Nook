import SwiftUI

/// Settings › Dictation and voice › Dictate anywhere (Flow). The key is set under Shortcuts, the language under General.
struct FlowSettingsSection: View {
    @ObservedObject private var store = FlowStore.shared
    @ObservedObject private var flow = FlowDictation.shared
    @State private var dictionary = FlowStore.shared.dictionaryText

    var body: some View {
        // Three short groups instead of one long one: turning it on, how it writes, and what it remembers.
        Group {
            Section {
                SettingToggle(tr("flow.settings.enable"), detail: tr("flow.settings.enableDetail", store.key.symbol), isOn: $store.enabled)
                    .onChange(of: store.enabled) { _, on in
                        if on, !flow.trusted { flow.askForAccessibility() }
                        flow.refresh()
                    }
                if store.enabled {
                    LabeledContent(tr("flow.settings.key")) {
                        Text(store.key == .fn ? "fn" : tr("flow.settings.keyRight", store.key.symbol)).foregroundStyle(NookTheme.textSecondary)
                    }
                    if !flow.trusted {
                        StatusRow(title: tr("flow.settings.access"), detail: tr("flow.settings.accessDetail"), state: .warning) {
                            Button(tr("flow.settings.allow")) { flow.openAccessibilitySettings() }
                        }
                    }
                }
            } header: {
                Text(tr("flow.settings.title"))
            } footer: {
                Text(tr("flow.settings.footer"))
            }
            .onAppear { PermissionMonitor.shared.watch() }
            .onDisappear { PermissionMonitor.shared.unwatch() }
            if store.enabled {
                Section {
                    SettingToggle(tr("flow.settings.cleanup"), detail: tr("flow.settings.cleanupDetail"), isOn: $store.cleanup)
                    SettingToggle(tr("flow.settings.prompt"), detail: tr("flow.settings.promptDetail"), isOn: $store.promptMode)
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                        Text(tr("flow.settings.dictionary"))
                        TextEditor(text: $dictionary)
                            .font(NookTheme.TextStyle.code)
                            .frame(minHeight: 90)
                            .onChange(of: dictionary) { _, value in store.dictionaryText = value }
                        SettingNote(tr("flow.settings.dictionaryHint"))
                    }
                }
                Section {
                    SettingToggle(tr("flow.settings.history"), detail: tr("flow.settings.historyDetail"), isOn: $store.keepHistory)
                    if store.stats.totalWords > 0 {
                        LabeledContent(tr("flow.settings.stats")) {
                            Text(tr("flow.settings.statsLine", store.stats.totalWords, store.wordsPerMinute, Int(store.minutesSaved.rounded()), store.streak))
                                .foregroundStyle(NookTheme.textSecondary)
                        }
                    }
                    if !store.history.isEmpty {
                        DisclosureGroup(tr("flow.settings.recent")) {
                            ForEach(store.history.prefix(8)) { entry in
                                HStack(alignment: .top) {
                                    Text(entry.text).lineLimit(2).font(NookTheme.TextStyle.body)
                                    Spacer()
                                    Button { Pasteboard.copy(entry.text) } label: {
                                        Image(systemName: "doc.on.doc")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(tr("flow.settings.copy"))
                                    .accessibilityLabel(tr("flow.settings.copy"))
                                }
                            }
                            ConfirmedButton(tr("flow.settings.clearHistory"), question: tr("confirm.clearFlow")) { store.clearHistory() }
                        }
                    }
                }
            }
        }
    }
}

/// Settings › Voice & sound › Parakeet: download, use or remove the offline speech recognition.
struct ParakeetSettingsSection: View {
    @ObservedObject private var parakeet = Parakeet.shared

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: NookTheme.Spacing.lg) {
                SettingLabel(tr("parakeet.title"), detail: parakeet.state == .unsupported ? tr("parakeet.unsupported") : tr("parakeet.detail"))
                Spacer()
                switch parakeet.state {
                case .unsupported:
                    EmptyView()
                case .missing:
                    Button(tr("parakeet.download")) { parakeet.download() }
                case .downloading(let fraction):
                    VStack(alignment: .trailing, spacing: NookTheme.Spacing.xxs) {
                        ProgressView(value: fraction).frame(width: 110)
                        Text(tr("parakeet.downloading", Int(fraction * 100))).font(NookTheme.TextStyle.detail.monospacedDigit()).foregroundStyle(NookTheme.textSecondary)
                    }
                case .ready:
                    ConfirmedButton(tr("parakeet.remove"), question: tr("confirm.remove", "Parakeet")) { parakeet.remove() }
                case .failed(let why):
                    VStack(alignment: .trailing, spacing: NookTheme.Spacing.xxs) {
                        Button(tr("parakeet.download")) { parakeet.download() }
                        SettingNote(why, tone: .warning).lineLimit(2)
                    }
                }
            }
            if parakeet.isReady {
                Toggle(tr("parakeet.use"), isOn: $parakeet.enabled)
            }
        }
    }
}
