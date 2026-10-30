import SwiftUI

/// Settings › Typing & dictation › Dictate anywhere (Flow): turning it on, how it writes (and the language it translates
/// to), and what it remembers. The key is set under Shortcuts.
struct FlowSettingsSection: View {
    @ObservedObject private var store = FlowStore.shared
    @ObservedObject private var flow = FlowDictation.shared
    /// Opens on an edit still waiting to be saved, so a quick switch away and back does not show (and then save over it)
    /// the text from before it.
    @State private var dictionary = FlowSettingsSection.pendingDictionary ?? FlowStore.shared.dictionaryText
    /// The pending save of the dictionary: parsing and publishing it on every keystroke would redraw Settings each time.
    @State private var dictionarySave: Task<Void, Never>?
    /// What was typed and not yet saved. Its save runs on when the editor goes, and clears it.
    @MainActor private static var pendingDictionary: String?

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
                SettingsSectionTitle(tr("flow.settings.title"), info: tr("flow.settings.footer"))
            }
            .onAppear { PermissionMonitor.shared.watch() }
            .onDisappear { PermissionMonitor.shared.unwatch() }
            if store.enabled {
                Section {
                    SettingToggle(tr("flow.settings.cleanup"), detail: tr("flow.settings.cleanupDetail"), isOn: $store.cleanup)
                    SettingToggle(tr("flow.settings.prompt"), detail: tr("flow.settings.promptDetail"), isOn: $store.promptMode)
                    Picker(tr("flow.settings.translate"), selection: $store.translateTo) {
                        Text(tr("flow.settings.asSpoken")).tag("")
                        // The stored choice is the language's own name, as `AppLanguage.displayName` writes it.
                        ForEach(AppLanguage.allCases) { lang in Text(lang.displayName).tag(lang.displayName) }
                    }
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                        Text(tr("flow.settings.dictionary"))
                        TextEditor(text: $dictionary)
                            .font(NookTheme.TextStyle.code)
                            .frame(minHeight: 90)
                            .onChange(of: dictionary) { _, value in
                                Self.pendingDictionary = value
                                dictionarySave?.cancel()
                                dictionarySave = Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 500_000_000)
                                    guard !Task.isCancelled else { return }
                                    FlowStore.shared.dictionaryText = value
                                    if Self.pendingDictionary == value { Self.pendingDictionary = nil }
                                }
                            }
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
