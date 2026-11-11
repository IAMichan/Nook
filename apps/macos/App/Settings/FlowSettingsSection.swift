import SwiftUI

/// Settings › Dictation & voice › Dictate anywhere (Flow): turning it on, how it writes (and the language it translates
/// to), and what it remembers. Its key is chosen here, right under the switch.
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
                    Picker(selection: $store.key) {
                        ForEach(FlowKey.allCases) { key in
                            Text(key == .fn ? "fn" : tr("flow.settings.keyRight", key.symbol)).tag(key)
                        }
                    } label: {
                        SettingText("flow.settings.key")
                    }
                    .onChange(of: store.key) { _, _ in flow.refresh(); DoubleTap.shared.refresh() }
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
                    Picker(selection: $store.translateTo) {
                        Text(tr("flow.settings.asSpoken")).tag("")
                        // The stored choice is the language's own name, as `AppLanguage.displayName` writes it.
                        ForEach(AppLanguage.allCases) { lang in Text(lang.displayName).tag(lang.displayName) }
                    } label: {
                        SettingText("flow.settings.translate")
                    }
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                        SettingText("flow.settings.dictionary")
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
                                    CopyIconButton(tr("flow.settings.copy")) { entry.text }
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
            // One status row, as a model download on the Brain page: what it is and its state, the button on the right.
            StatusRow(title: tr("parakeet.title"), detail: detail, state: state) {
                switch parakeet.state {
                case .unsupported:
                    EmptyView()
                case .missing, .failed:
                    Button(tr("parakeet.download")) { parakeet.download() }
                case .downloading(let fraction):
                    ProgressView(value: fraction).frame(width: 90)
                    Text(tr("parakeet.downloading", Int(fraction * 100)))
                        .font(NookTheme.TextStyle.detail.monospacedDigit())
                        .foregroundStyle(NookTheme.textSecondary)
                case .ready:
                    ConfirmedButton(tr("parakeet.remove"), question: tr("confirm.remove", "Parakeet")) { parakeet.remove() }
                }
            }
            if parakeet.isReady {
                Toggle(tr("parakeet.use"), isOn: $parakeet.enabled)
            }
        }
    }

    private var detail: String {
        switch parakeet.state {
        case .unsupported: return tr("parakeet.unsupported")
        case .failed(let why): return why
        default: return tr("parakeet.detail")
        }
    }

    private var state: StatusState {
        switch parakeet.state {
        case .ready: return .done
        case .failed: return .warning
        default: return .todo
        }
    }
}
