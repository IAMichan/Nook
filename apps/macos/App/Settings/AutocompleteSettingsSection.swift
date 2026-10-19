import SwiftUI
import UniformTypeIdentifiers

/// Settings › Autocomplete: suggestions as you type in any app, with the model of Cotypist or one of Nook's own.
struct AutocompleteSettingsSection: View {
    @ObservedObject private var store = AutocompleteStore.shared
    @ObservedObject private var autocomplete = AutocompleteController.shared
    @ObservedObject private var downloads = CompletionDownloads.shared
    @State private var instructions = AutocompleteStore.shared.prefs.instructions
    @State private var editingApp: String?
    @State private var confirmForget = false

    var body: some View {
        Group {
            Section {
                IntroCard(symbol: "text.cursor", colors: SettingsSection.autocomplete.tileColors,
                          title: tr("autocomplete.hero.title"), text: tr("autocomplete.hero.detail"))
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))

            Section {
                SettingToggle(tr("autocomplete.enable"), detail: tr("autocomplete.enableDetail", store.prefs.acceptWord.label, store.prefs.acceptAll.label),
                              isOn: $store.prefs.enabled)
                    .onChange(of: store.prefs.enabled) { _, on in
                        if on, !autocomplete.trusted { autocomplete.askForAccessibility() }
                        autocomplete.refresh()
                    }
                if store.prefs.enabled { status }
            }
            if store.prefs.enabled {
                modelSection
                suggestionsSection
                keysSection
                contextSection
                personalSection
                appsSection
                extrasSection
                statsSection
            }
        }
    }

    // MARK: Status

    @ViewBuilder private var status: some View {
        switch autocomplete.state {
        case .noAccess:
            StatusRow(title: tr("autocomplete.access"), detail: tr("autocomplete.accessDetail"), state: .warning) {
                Button(tr("flow.settings.allow")) { autocomplete.openAccessibilitySettings() }
            }
        case .noModel:
            StatusRow(title: tr("autocomplete.noModel"), detail: tr("autocomplete.noModelDetail"), state: .warning) { EmptyView() }
        case .failed(let message):
            StatusRow(title: tr("autocomplete.failed"), detail: message, state: .error) {
                Button(tr("autocomplete.retry")) { autocomplete.refresh() }
            }
        case .loading:
            StatusRow(title: tr("autocomplete.loading"), detail: autocomplete.activeModel?.title ?? "", state: .todo) { ProgressView().controlSize(.small) }
        case .ready:
            StatusRow(title: autocomplete.isPausedEverywhere ? tr("autocomplete.paused") : tr("autocomplete.ready"),
                      detail: autocomplete.activeModel.map { "\($0.title) · \(sourceLabel($0.source))" } ?? "",
                      state: autocomplete.isPausedEverywhere ? .todo : .done) {
                Button(autocomplete.isPausedEverywhere ? tr("autocomplete.resume") : tr("autocomplete.pause")) { autocomplete.togglePauseEverywhere() }
            }
        case .off:
            EmptyView()
        }
    }

    private func sourceLabel(_ source: CompletionModelFile.Source) -> String {
        switch source {
        case .cotypist: return tr("autocomplete.source.cotypist")
        case .nook: return tr("autocomplete.source.nook")
        case .custom: return tr("autocomplete.source.custom")
        }
    }

    // MARK: Model

    private var modelSection: some View {
        Section {
            Picker(tr("autocomplete.model"), selection: $store.prefs.modelPath) {
                Text(tr("autocomplete.modelAuto")).tag("")
                ForEach(autocomplete.candidates) { model in
                    Text("\(model.title) · \(model.sizeText) · \(sourceLabel(model.source))").tag(model.url.path)
                }
                if !store.prefs.modelPath.isEmpty, !autocomplete.candidates.contains(where: { $0.url.path == store.prefs.modelPath }) {
                    Text(URL(fileURLWithPath: store.prefs.modelPath).lastPathComponent).tag(store.prefs.modelPath)
                }
            }
            .onChange(of: store.prefs.modelPath) { _, _ in autocomplete.refresh() }
            LabeledContent(tr("autocomplete.modelFile")) {
                HStack {
                    Button(tr("autocomplete.choose")) { chooseFile() }
                    Button(tr("autocomplete.rescan")) { autocomplete.refresh() }
                    Button(tr("button.openFolder")) { NSWorkspace.shared.open(AutocompleteStore.modelsFolder) }
                }
            }
            DisclosureGroup(tr("autocomplete.catalog")) {
                let recommended = CompletionCatalogModel.recommended(memoryGB: EmbeddedModel.memoryGB)
                ForEach(CompletionCatalogModel.catalog) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(model.name)
                                if model == recommended { Text(tr("autocomplete.recommended")).font(.caption).foregroundStyle(.tint) }
                            }
                            Text("\(String(format: "%.1f", model.sizeGB)) GB · \(tr(model.noteKey))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if downloads.downloading == model {
                            ProgressView(value: downloads.progress).frame(width: 80)
                            Button(tr("button.cancel")) { downloads.cancel() }
                        } else if downloads.isInstalled(model) {
                            Button(tr("autocomplete.use")) {
                                store.prefs.modelPath = AutocompleteStore.modelsFolder.appendingPathComponent(model.fileName).path
                            }
                        } else {
                            Button(tr("autocomplete.download")) {
                                downloads.download(model) { url in store.prefs.modelPath = url.path }
                            }
                            .disabled(downloads.downloading != nil)
                        }
                    }
                }
                if let error = downloads.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        } header: {
            Text(tr("autocomplete.section.model"))
        } footer: {
            Text(tr("autocomplete.modelFooter"))
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
        store.prefs.modelPath = url.path
    }

    // MARK: Suggestions

    private var suggestionsSection: some View {
        Section(tr("autocomplete.section.suggestions")) {
            Stepper(tr("autocomplete.maxWords", store.prefs.maxWords), value: $store.prefs.maxWords, in: 1...20)
            LabeledContent(tr("autocomplete.eagerness")) {
                HStack {
                    Text(tr("autocomplete.eagerness.careful")).font(.caption).foregroundStyle(.secondary)
                    Slider(value: $store.prefs.eagerness, in: 0...1).frame(width: 160)
                    Text(tr("autocomplete.eagerness.eager")).font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent(tr("autocomplete.delay")) {
                HStack {
                    Slider(value: Binding(get: { Double(store.prefs.delayMilliseconds) }, set: { store.prefs.delayMilliseconds = Int($0) }),
                           in: 40...600, step: 20).frame(width: 160)
                    Text("\(store.prefs.delayMilliseconds) ms").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            SettingToggle(tr("autocomplete.inline"), detail: tr("autocomplete.inlineDetail"), isOn: $store.prefs.inlineGhost)
            SettingToggle(tr("autocomplete.midLine"), detail: tr("autocomplete.midLineDetail"), isOn: $store.prefs.midLine)
            SettingToggle(tr("autocomplete.smallFields"), detail: tr("autocomplete.smallFieldsDetail"), isOn: $store.prefs.smallFields)
            Toggle(tr("autocomplete.trailingSpace"), isOn: $store.prefs.trailingSpace)
            Toggle(tr("autocomplete.punctuation"), isOn: $store.prefs.attachedPunctuation)
        }
    }

    // MARK: Keys

    private var keysSection: some View {
        Section(tr("autocomplete.section.keys")) {
            CompletionKeyRecorder(title: tr("autocomplete.key.word"), shortcut: Binding(get: { store.prefs.acceptWord }, set: { if let key = $0 { store.prefs.acceptWord = key } }),
                                  fallback: .tab, allowsOff: false)
            CompletionKeyRecorder(title: tr("autocomplete.key.all"), shortcut: Binding(get: { store.prefs.acceptAll }, set: { if let key = $0 { store.prefs.acceptAll = key } }),
                                  fallback: .shiftTab, allowsOff: false)
            CompletionKeyRecorder(title: tr("autocomplete.key.toggleAll"), shortcut: $store.prefs.toggleAll, fallback: nil, allowsOff: true)
            CompletionKeyRecorder(title: tr("autocomplete.key.toggleApp"), shortcut: $store.prefs.toggleApp, fallback: nil, allowsOff: true)
            Picker(tr("autocomplete.escape"), selection: $store.prefs.escape) {
                ForEach(CompletionEscape.allCases) { Text(tr("autocomplete.escape.\($0.rawValue)")).tag($0) }
            }
            Stepper(tr("autocomplete.pauseMinutes", store.prefs.pauseMinutes), value: $store.prefs.pauseMinutes, in: 1...240)
        }
    }

    // MARK: Context

    private var contextSection: some View {
        Section {
            SettingToggle(tr("autocomplete.context.window"), detail: tr("autocomplete.context.windowDetail"), isOn: $store.prefs.windowContext)
            SettingToggle(tr("autocomplete.context.memory"), detail: tr("autocomplete.context.memoryDetail"), isOn: $store.prefs.memoryContext)
            SettingToggle(tr("autocomplete.context.screen"), detail: tr("autocomplete.context.screenDetail"), isOn: $store.prefs.screenContext)
            SettingToggle(tr("autocomplete.context.clipboard"), detail: tr("autocomplete.context.clipboardDetail"), isOn: $store.prefs.clipboardContext)
        } header: {
            Text(tr("autocomplete.section.context"))
        } footer: {
            Text(tr("autocomplete.privacy"))
        }
    }

    // MARK: Personal

    private var personalSection: some View {
        Section(tr("autocomplete.section.personal")) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("autocomplete.instructions"))
                TextEditor(text: $instructions)
                    .font(.callout)
                    .frame(minHeight: 70)
                    .onChange(of: instructions) { _, value in store.prefs.instructions = value }
                Text(tr("autocomplete.instructionsHint")).font(.caption).foregroundStyle(.secondary)
            }
            SettingToggle(tr("autocomplete.learn"), detail: tr("autocomplete.learnDetail"), isOn: $store.prefs.learn)
                .onChange(of: store.prefs.learn) { _, _ in autocomplete.applyPersonalization() }
            if store.prefs.learn {
                LabeledContent(tr("autocomplete.strength")) {
                    Slider(value: $store.prefs.personalStrength, in: 0...1, onEditingChanged: { editing in
                        if !editing { autocomplete.applyPersonalization() }
                    })
                    .frame(width: 200)
                }
            }
            LabeledContent(tr("autocomplete.samples", store.samples.count)) {
                Button(tr("autocomplete.forget")) { confirmForget = true }.disabled(store.samples.count == 0)
            }
            .confirmationDialog(tr("autocomplete.forgetConfirm"), isPresented: $confirmForget) {
                Button(tr("autocomplete.forget"), role: .destructive) { store.forgetSamples(); autocomplete.applyPersonalization() }
            }
        }
    }

    // MARK: Apps and sites

    private var appsSection: some View {
        Section {
            SettingToggle(tr("autocomplete.everywhere"), detail: tr("autocomplete.everywhereDetail"), isOn: $store.prefs.enabledByDefault)
            ForEach(appIDs, id: \.self) { bundleID in
                DisclosureGroup(isExpanded: Binding(get: { editingApp == bundleID }, set: { editingApp = $0 ? bundleID : nil })) {
                    appRule(bundleID)
                } label: {
                    HStack {
                        Text(appName(bundleID))
                        Spacer()
                        Text(store.prefs.isEnabled(inApp: bundleID) ? tr("autocomplete.app.on") : tr("autocomplete.app.off"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let site = autocomplete.lastSite {
                Picker(tr("autocomplete.site", site), selection: siteBinding(site)) {
                    ForEach(CompletionTriState.allCases) { Text(tr("autocomplete.tri.\($0.rawValue)")).tag($0) }
                }
            }
        } header: {
            Text(tr("autocomplete.section.apps"))
        } footer: {
            Text(tr("autocomplete.appsFooter"))
        }
    }

    /// Apps with their own settings, and apps typed in since Nook started.
    private var appIDs: [String] {
        Set(store.prefs.apps.keys).union(autocomplete.seenApps.keys).sorted { appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending }
    }

    private func appName(_ bundleID: String) -> String {
        if let name = autocomplete.seenApps[bundleID] { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    private func rule(_ bundleID: String) -> Binding<CompletionAppRule> {
        Binding(get: { store.prefs.app(bundleID) }, set: { store.prefs.apps[bundleID] = $0 })
    }

    @ViewBuilder private func appRule(_ bundleID: String) -> some View {
        let rule = rule(bundleID)
        Picker(tr("autocomplete.app.suggestions"), selection: rule.enabled) {
            ForEach(CompletionTriState.allCases) { Text(tr("autocomplete.tri.\($0.rawValue)")).tag($0) }
        }
        Picker(tr("autocomplete.midLine"), selection: rule.midLine) {
            ForEach(CompletionTriState.allCases) { Text(tr("autocomplete.tri.\($0.rawValue)")).tag($0) }
        }
        Toggle(tr("autocomplete.app.leaveTab"), isOn: rule.leaveTab)
        Toggle(tr("autocomplete.app.learn"), isOn: rule.learn)
        TextField(tr("autocomplete.app.instructions"), text: rule.instructions, axis: .vertical).lineLimit(1...4)
        LabeledContent(tr("autocomplete.app.textSize")) {
            Slider(value: rule.fontScale, in: 0.6...1.6).frame(width: 160)
        }
        LabeledContent(tr("autocomplete.app.offset")) {
            Slider(value: rule.verticalOffset, in: -10...10, step: 1).frame(width: 160)
        }
        HStack {
            Button(store.isPaused(app: bundleID) ? tr("autocomplete.resume") : tr("autocomplete.app.pause", store.prefs.pauseMinutes)) {
                autocomplete.togglePause(app: bundleID)
            }
            Spacer()
            Button(tr("autocomplete.app.reset")) { store.prefs.apps[bundleID] = nil }.disabled(store.prefs.apps[bundleID] == nil)
        }
    }

    private func siteBinding(_ site: String) -> Binding<CompletionTriState> {
        Binding(get: { store.prefs.sites[site]?.enabled ?? .inherit },
                set: { value in
                    var rule = store.prefs.sites[site] ?? CompletionSiteRule()
                    rule.enabled = value
                    store.prefs.sites[site] = rule
                })
    }

    // MARK: Emoji, typos, battery, labs

    private var extrasSection: some View {
        Section(tr("autocomplete.section.extras")) {
            SettingToggle(tr("autocomplete.emoji"), detail: tr("autocomplete.emojiDetail"), isOn: $store.prefs.emoji)
            if store.prefs.emoji {
                Picker(tr("autocomplete.skinTone"), selection: $store.prefs.skinTone) {
                    ForEach(0...5, id: \.self) { tone in
                        Text(CompletionEmojiCatalog.render(CompletionEmoji(character: "👍", shortcodes: [], toneable: true), skinTone: tone)).tag(tone)
                    }
                }
            }
            SettingToggle(tr("autocomplete.typos"), detail: tr("autocomplete.typosDetail"), isOn: $store.prefs.typos)
            if store.prefs.typos { Toggle(tr("autocomplete.typoFixes"), isOn: $store.prefs.showTypoFixes) }
            Toggle(tr("autocomplete.battery.shorter"), isOn: $store.prefs.shorterOnBattery)
            Toggle(tr("autocomplete.battery.pause"), isOn: $store.prefs.pauseOnBattery)
            SettingToggle(tr("autocomplete.alternatives"), detail: tr("autocomplete.alternativesDetail"), isOn: $store.prefs.wordAlternatives)
            if store.prefs.wordAlternatives {
                Toggle(tr("autocomplete.alternativesAuto"), isOn: $store.prefs.autoAlternatives)
                CompletionKeyRecorder(title: tr("autocomplete.key.alternatives"), shortcut: $store.prefs.alternatives, fallback: nil, allowsOff: true)
            }
        }
    }

    // MARK: Statistics

    private var statsSection: some View {
        Section(tr("autocomplete.section.stats")) {
            let stats = store.stats
            LabeledContent(tr("autocomplete.stats.today")) { Text("\(stats.day().words)").monospacedDigit() }
            LabeledContent(tr("autocomplete.stats.total")) {
                Text(tr("autocomplete.stats.totalValue", stats.totalWords, Int(stats.minutesSaved.rounded()))).foregroundStyle(.secondary)
            }
            LabeledContent(tr("autocomplete.stats.acceptance")) { Text("\(Int((stats.acceptance * 100).rounded()))%").monospacedDigit() }
            let recent = stats.recent(14)
            let top = max(recent.map(\.day.words).max() ?? 0, 1)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(recent.enumerated()), id: \.offset) { _, entry in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(entry.day.words == 0 ? 0.15 : 0.8))
                        .frame(width: 12, height: max(3, 50 * CGFloat(entry.day.words) / CGFloat(top)))
                        .help("\(entry.date.formatted(date: .abbreviated, time: .omitted)): \(entry.day.words)")
                }
            }
            .frame(height: 54, alignment: .bottom)
            Button(tr("autocomplete.stats.reset")) { store.resetStats() }.disabled(stats.totalShown == 0)
        }
    }
}

/// One autocomplete key: click, press the new keys. Esc cancels, ⌫ turns it off when that is allowed.
struct CompletionKeyRecorder: View {
    let title: String
    @Binding var shortcut: CompletionShortcut?
    let fallback: CompletionShortcut?
    let allowsOff: Bool
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Button { recording ? stop() : start() } label: {
                    if recording { Text(tr("shortcut.record")).foregroundStyle(.secondary) }
                    else if let shortcut { Keycap(label: shortcut.label) }
                    else { Text(tr("shortcut.off")).foregroundStyle(.secondary) }
                }
                .buttonStyle(.borderless)
                if shortcut != fallback, !recording {
                    Button { shortcut = fallback } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .help(tr("shortcut.reset"))
                }
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop() }
            else if event.keyCode == 51, allowsOff { shortcut = nil; stop() }
            else if let key = Self.shortcut(from: event), !key.isTypingKey { shortcut = key; stop() }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func shortcut(from event: NSEvent) -> CompletionShortcut? {
        var modifiers = 0
        var label = ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { modifiers |= CompletionShortcut.control; label += "⌃" }
        if flags.contains(.option) { modifiers |= CompletionShortcut.option; label += "⌥" }
        if flags.contains(.shift) { modifiers |= CompletionShortcut.shift; label += "⇧" }
        if flags.contains(.command) { modifiers |= CompletionShortcut.command; label += "⌘" }
        let special: [UInt16: String] = [48: "⇥", 36: "↩", 49: "Space", 53: "⎋", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑", 50: "`",
                                         122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        if let name = special[event.keyCode] { label += name }
        else if let characters = event.charactersIgnoringModifiers?.uppercased(), !characters.isEmpty { label += characters }
        else { return nil }
        return CompletionShortcut(keyCode: Int(event.keyCode), modifiers: modifiers, label: label)
    }
}
