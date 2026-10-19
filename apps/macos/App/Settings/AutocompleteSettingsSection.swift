import SwiftUI
import Charts
import UniformTypeIdentifiers

/// Settings › Autocomplete: suggestions as you type in any app, with a GGUF model on this Mac or the brain's own model.
struct AutocompleteSettingsSection: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = AutocompleteStore.shared
    @ObservedObject private var autocomplete = AutocompleteController.shared
    @ObservedObject private var downloads = CompletionDownloads.shared
    @State private var instructions = AutocompleteStore.shared.prefs.instructions
    @State private var editingApp: String?
    @State private var confirmForget = false
    @State private var confirmReset = false
    @State private var installed: [InstalledApp] = []
    @State private var search = ""
    @State private var filter: AppFilter = .all
    @State private var newSite = ""
    @State private var customLink = ""
    @State private var pendingDelete: CompletionCatalogModel?

    enum AppFilter: String, CaseIterable, Identifiable {
        case all, on, off
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            Section {
                IntroCard(symbol: "text.cursor", colors: SettingsSection.autocomplete.tileColors,
                          title: tr("autocomplete.hero.title"), text: tr("autocomplete.hero.detail"))
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))

            Section {
                Picker("", selection: $store.settingsTab) {
                    ForEach(AutocompleteSettingsTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .listRowBackground(Color.clear)

            switch store.settingsTab {
            case .general:
                Section {
                    SettingToggle(tr("autocomplete.enable"), detail: tr("autocomplete.enableDetail", store.prefs.acceptWord.label, store.prefs.acceptAll.label),
                                  isOn: $store.prefs.enabled)
                        .onChange(of: store.prefs.enabled) { _, on in
                            if on, !autocomplete.trusted { autocomplete.askForAccessibility() }
                            autocomplete.refresh()
                        }
                    if store.prefs.enabled {
                        status
                        SettingToggle(tr("autocomplete.menuBarCount"), detail: tr("autocomplete.menuBarCountDetail"), isOn: $store.prefs.menuBarCount)
                    }
                }
                modelSection
                downloadSection
                suggestionsSection
                keysLink
            case .apps:
                appsSection
                sitesSection
            case .style:
                contextSection
                personalSection
                extrasSection
            case .stats:
                statsSection
            }
        }
        // Picks up Accessibility the moment it is switched on in System Settings.
        .onAppear { PermissionMonitor.shared.watch() }
        .onDisappear { PermissionMonitor.shared.unwatch() }
    }

    // MARK: Status

    @ViewBuilder private var status: some View {
        switch autocomplete.state {
        case .noAccess:
            StatusRow(title: tr("autocomplete.access"), detail: tr("autocomplete.accessDetail"), state: .warning) {
                Button(tr("flow.settings.allow")) { autocomplete.openAccessibilitySettings() }
            }
        case .noModel:
            StatusRow(title: tr("autocomplete.noModel"), detail: tr("autocomplete.noModelDetail"), state: .warning) {
                if let model = downloads.downloading {
                    ProgressView(value: downloads.progress).frame(width: 80).help(model.name)
                } else {
                    Button(tr("autocomplete.download.named", recommended.name)) { start(recommended) }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .failed(let message):
            StatusRow(title: tr("autocomplete.failed"), detail: message, state: .error) {
                Button(tr("autocomplete.retry")) { autocomplete.refresh() }
            }
        case .loading:
            StatusRow(title: tr("autocomplete.loading"), detail: autocomplete.activeModel?.title ?? "", state: .todo) { ProgressView().controlSize(.small) }
        case .ready:
            StatusRow(title: autocomplete.isPausedEverywhere ? tr("autocomplete.paused") : tr("autocomplete.ready"),
                      detail: autocomplete.activeModel.map { "\($0.title) · \(sourceLabel($0))" } ?? "",
                      state: autocomplete.isPausedEverywhere ? .todo : .done) {
                Button(autocomplete.isPausedEverywhere ? tr("autocomplete.resume") : tr("autocomplete.pause")) { autocomplete.togglePauseEverywhere() }
            }
        case .off:
            EmptyView()
        }
    }

    private func sourceLabel(_ source: CompletionModelFile.Source) -> String {
        switch source {
        case .found: return tr("autocomplete.source.found")
        case .nook: return tr("autocomplete.source.nook")
        case .custom: return tr("autocomplete.source.custom")
        }
    }

    private func sourceLabel(_ source: CompletionSource) -> String {
        switch source {
        case .gguf(let file): return sourceLabel(file.source)
        case .brain: return tr("autocomplete.source.brain")
        }
    }

    // MARK: Model

    private var modelSection: some View {
        Section {
            Picker(tr("autocomplete.model"), selection: $store.prefs.modelPath) {
                Text(tr("autocomplete.modelAuto")).tag("")
                ForEach(autocomplete.brainModels, id: \.id) { model in
                    Text("\(model.title) · \(tr("autocomplete.source.brain"))").tag(CompletionSource.brainPrefix + model.id)
                }
                ForEach(autocomplete.candidates) { model in
                    Text("\(model.title) · \(model.sizeText) · \(sourceLabel(model.source))").tag(model.url.path)
                }
                if !store.prefs.modelPath.isEmpty, !store.prefs.modelPath.hasPrefix(CompletionSource.brainPrefix),
                   !autocomplete.candidates.contains(where: { $0.url.path == store.prefs.modelPath }) {
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
        } header: {
            Text(tr("autocomplete.section.model"))
        } footer: {
            Text(tr("autocomplete.modelFooter"))
        }
    }

    // MARK: Downloading

    private var downloadSection: some View {
        Section {
            // What is already on this Mac comes first: no need to download it again.
            ForEach(autocomplete.candidates.filter { file in !CompletionCatalogModel.catalog.contains { $0.fileName == file.url.lastPathComponent } }) { file in
                presentRow(file)
            }
            ForEach(CompletionCatalogModel.catalog) { model in downloadRow(model) }
            HStack {
                TextField(tr("autocomplete.download.linkPlaceholder"), text: $customLink)
                    .onSubmit(downloadLink)
                Button(tr("autocomplete.download"), action: downloadLink)
                    .disabled(CompletionCatalogModel.custom(from: customLink) == nil || downloads.downloading != nil)
            }
            if let model = downloads.downloading, !CompletionCatalogModel.catalog.contains(model) { downloadRow(model) }
            if let error = downloads.error { Text(error).font(.caption).foregroundStyle(.red) }
        } header: {
            Text(tr("autocomplete.section.download"))
        } footer: {
            Text(tr("autocomplete.download.footer"))
        }
        .id(downloads.changes)
    }

    /// A GGUF model that is already here (found on this Mac or in Nook's folder): use it, or see that it is in use.
    private func presentRow(_ file: CompletionModelFile) -> some View {
        let inUse = autocomplete.activeModel?.identity == file.url.path
        return HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(file.title)
                Text("\(file.sizeText) · \(sourceLabel(file.source))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if inUse {
                Text(tr("autocomplete.download.inUse")).font(.caption).foregroundStyle(.secondary)
            } else {
                Button(tr("autocomplete.use")) { store.prefs.modelPath = file.url.path }
            }
        }
        .help(file.url.path)
    }

    /// The file of a catalog model when it is here: in Nook's folder, or found elsewhere on this Mac under the same name.
    private func presentFile(_ model: CompletionCatalogModel) -> URL? {
        if downloads.isInstalled(model) { return downloads.file(for: model) }
        return autocomplete.candidates.first { $0.url.lastPathComponent == model.fileName }?.url
    }

    private var recommended: CompletionCatalogModel { CompletionCatalogModel.recommended(memoryGB: EmbeddedModel.memoryGB) }

    private func downloadRow(_ model: CompletionCatalogModel) -> some View {
        let here = presentFile(model)
        let installed = here != nil
        let ownCopy = downloads.isInstalled(model)
        let inUse = here.map { autocomplete.activeModel?.identity == $0.path } ?? false
        return HStack(spacing: 10) {
            Image(systemName: installed ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(installed ? Color.green : Color.secondary)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name)
                    if model == recommended {
                        Text(tr("autocomplete.recommended"))
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    }
                }
                if downloads.downloading == model {
                    Text(downloads.progressText).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else if model.sizeGB > 0 {
                    Text("\(String(format: "%.1f", model.sizeGB)) GB · \(tr(model.noteKey))\(model.minimumMemoryGB > EmbeddedModel.memoryGB ? " · " + tr("autocomplete.download.tooBig", model.minimumMemoryGB) : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if downloads.downloading == model {
                ProgressView(value: downloads.progress).frame(width: 90)
                Button(tr("button.cancel")) { downloads.cancel() }
            } else if installed {
                if inUse {
                    Text(tr("autocomplete.download.inUse")).font(.caption).foregroundStyle(.secondary)
                } else if let here {
                    Button(tr("autocomplete.use")) { store.prefs.modelPath = here.path }
                }
                // Only Nook's own copies can be deleted here; a file of another app stays where it is.
                if ownCopy {
                    Button { pendingDelete = model } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help(tr("autocomplete.download.delete"))
                }
            } else {
                Button(tr("autocomplete.download")) { start(model) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(downloads.downloading != nil)
            }
        }
        .confirmationDialog(tr("autocomplete.download.deleteConfirm", model.name), isPresented: Binding(
            get: { pendingDelete == model }, set: { if !$0 { pendingDelete = nil } })) {
            Button(tr("autocomplete.download.delete"), role: .destructive) { delete(model) }
        }
    }

    /// Downloads a model and uses it as soon as it is there.
    private func start(_ model: CompletionCatalogModel) {
        downloads.download(model) { url in store.prefs.modelPath = url.path }
    }

    private func downloadLink() {
        guard let model = CompletionCatalogModel.custom(from: customLink) else { return }
        customLink = ""
        start(model)
    }

    private func delete(_ model: CompletionCatalogModel) {
        let path = downloads.file(for: model).path
        downloads.delete(model)
        pendingDelete = nil
        if store.prefs.modelPath == path { store.prefs.modelPath = "" } else { autocomplete.refresh() }
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

    /// The keys live under Shortcuts, with every other key of Nook.
    private var keysLink: some View {
        Section {
            Button { app.settingsSection = .shortcuts } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("autocomplete.section.keys")).foregroundStyle(.primary)
                        Text(tr("settings.autocomplete.keysMoved")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

    // MARK: Apps

    private var appsSection: some View {
        Group {
            Section {
                SettingToggle(tr("autocomplete.everywhere"), detail: tr("autocomplete.everywhereDetail"), isOn: $store.prefs.enabledByDefault)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(tr("autocomplete.apps.search"), text: $search).textFieldStyle(.plain)
                    Picker("", selection: $filter) {
                        ForEach(AppFilter.allCases) { Text(tr("autocomplete.apps.filter.\($0.rawValue)")).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            } header: {
                Text(tr("autocomplete.section.apps"))
            }
            Section {
                if apps.isEmpty {
                    Text(installed.isEmpty ? tr("autocomplete.loading.apps") : tr("autocomplete.apps.noMatch")).foregroundStyle(.secondary)
                }
                ForEach(apps) { app in appRow(app) }
            } footer: {
                Text(tr("autocomplete.appsFooter"))
            }
        }
        .task { if installed.isEmpty { installed = await InstalledApp.scan() } }
    }

    /// Installed apps, apps with their own settings and apps typed in, filtered and searched.
    private var apps: [InstalledApp] {
        var byID = Dictionary(installed.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        for bundleID in Set(store.prefs.apps.keys).union(autocomplete.seenApps.keys) where byID[bundleID] == nil {
            byID[bundleID] = InstalledApp(bundleID: bundleID, name: autocomplete.seenApps[bundleID] ?? bundleID, url: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID))
        }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return byID.values
            .filter { query.isEmpty || $0.name.lowercased().contains(query) || $0.bundleID.lowercased().contains(query) }
            .filter { app in
                switch filter {
                case .all: return true
                case .on: return isOn(app.bundleID)
                case .off: return !isOn(app.bundleID)
                }
            }
            // Alphabetical: a row must not jump away while you flip its switch. The Off filter gathers the excluded ones.
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// On or off for one app. Matching the default clears the rule, so a later change of the default still applies.
    private func enabledBinding(_ bundleID: String) -> Binding<Bool> {
        Binding(get: { isOn(bundleID) },
                set: { on in
                    var rule = store.prefs.app(bundleID)
                    rule.enabled = on == fallback(bundleID) ? .inherit : (on ? .on : .off)
                    store.prefs.apps[bundleID] = rule == CompletionAppRule() ? nil : rule
                })
    }

    /// Whether suggestions are on in this app, apart from the main switch.
    private func isOn(_ bundleID: String) -> Bool {
        store.prefs.app(bundleID).enabled.resolved(fallback(bundleID))
    }

    private func fallback(_ bundleID: String) -> Bool {
        store.prefs.enabledByDefault && !CompletionPreferences.offByDefault.contains(bundleID)
    }

    private func appRow(_ app: InstalledApp) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { editingApp == app.bundleID }, set: { editingApp = $0 ? app.bundleID : nil })) {
            appRule(app.bundleID)
        } label: {
            HStack(spacing: 10) {
                AppIcon(url: app.url)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                    if let note = note(for: app.bundleID) {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let uses = store.stats.apps[app.bundleID]?.takes, uses > 0 {
                    Text(tr("autocomplete.stats.timesShort", uses)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Toggle("", isOn: enabledBinding(app.bundleID)).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    /// Why an app is the way it is: off by default, paused, its own instructions.
    private func note(for bundleID: String) -> String? {
        if store.isPaused(app: bundleID) { return tr("autocomplete.apps.paused") }
        let rule = store.prefs.app(bundleID)
        if rule.enabled == .inherit, CompletionPreferences.offByDefault.contains(bundleID) { return tr("autocomplete.apps.defaultOff") }
        if !rule.instructions.isEmpty { return tr("autocomplete.apps.hasInstructions") }
        return nil
    }

    private func rule(_ bundleID: String) -> Binding<CompletionAppRule> {
        Binding(get: { store.prefs.app(bundleID) }, set: { store.prefs.apps[bundleID] = $0 })
    }

    @ViewBuilder private func appRule(_ bundleID: String) -> some View {
        let rule = self.rule(bundleID)
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

    // MARK: Websites

    private var sitesSection: some View {
        Section {
            ForEach(store.prefs.sites.keys.sorted(), id: \.self) { site in
                DisclosureGroup {
                    TextField(tr("autocomplete.app.instructions"), text: siteInstructions(site), axis: .vertical).lineLimit(1...4)
                    Button(tr("autocomplete.apps.removeSite"), role: .destructive) { store.prefs.sites[site] = nil }
                } label: {
                    HStack(spacing: 10) {
                        SiteIcon(domain: site, fallback: "globe", tint: .secondary, size: 18)
                        Text(site)
                        Spacer()
                        Toggle("", isOn: siteEnabled(site)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
            }
            HStack {
                TextField(tr("autocomplete.apps.siteAdd"), text: $newSite).onSubmit(addSite)
                Button(tr("autocomplete.apps.add"), action: addSite).disabled(cleanedSite(newSite) == nil)
                if let last = autocomplete.lastSite, store.prefs.sites[last] == nil {
                    Button(last) { store.prefs.sites[last] = CompletionSiteRule() }.help(tr("autocomplete.apps.addLast"))
                }
            }
        } header: {
            Text(tr("autocomplete.apps.sites"))
        } footer: {
            Text(tr("autocomplete.apps.sitesFooter"))
        }
    }

    private func cleanedSite(_ text: String) -> String? {
        var host = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let url = URL(string: host.contains("://") ? host : "https://" + host), let found = url.host { host = found }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.contains(".") && !host.contains(" ") ? host : nil
    }

    private func addSite() {
        guard let host = cleanedSite(newSite) else { return }
        if store.prefs.sites[host] == nil { store.prefs.sites[host] = CompletionSiteRule() }
        newSite = ""
    }

    private func siteEnabled(_ site: String) -> Binding<Bool> {
        Binding(get: { store.prefs.isEnabled(onSite: site) },
                set: { on in store.prefs.sites[site, default: CompletionSiteRule()].enabled = on ? .inherit : .off })
    }

    private func siteInstructions(_ site: String) -> Binding<String> {
        Binding(get: { store.prefs.sites[site]?.instructions ?? "" },
                set: { store.prefs.sites[site, default: CompletionSiteRule()].instructions = $0 })
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
        let stats = store.stats
        let today = stats.day()
        let week = stats.week()
        let recent = stats.recent(30)
        return Group {
            Section {
                HStack(spacing: 10) {
                    StatTile(title: tr("autocomplete.stats.today"), value: tr("autocomplete.stats.timesShort", today.takes),
                             detail: tr("autocomplete.stats.words", today.words), symbol: "sun.max.fill")
                    StatTile(title: tr("autocomplete.stats.week"), value: tr("autocomplete.stats.timesShort", week.takes),
                             detail: tr("autocomplete.stats.words", week.words), symbol: "calendar")
                    StatTile(title: tr("autocomplete.stats.total"), value: tr("autocomplete.stats.timesShort", stats.totalTakes),
                             detail: tr("autocomplete.stats.words", stats.totalWords), symbol: "sum")
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            .listRowBackground(Color.clear)

            Section(tr("autocomplete.stats.chart")) {
                if stats.totalTakes == 0 {
                    Text(tr("autocomplete.stats.empty")).foregroundStyle(.secondary)
                } else {
                    Chart(recent, id: \.date) { entry in
                        BarMark(x: .value("Dag", entry.date, unit: .day), y: .value("Keer", entry.day.takes))
                            .foregroundStyle(SettingsSection.autocomplete.tileColors.1.gradient)
                            .cornerRadius(3)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        }
                    }
                    .frame(height: 140)
                }
            }

            Section(tr("autocomplete.stats.details")) {
                LabeledContent(tr("autocomplete.stats.saved")) { Text(duration(stats.minutesSaved)).monospacedDigit() }
                LabeledContent(tr("autocomplete.stats.characters")) { Text("\(stats.totalCharacters)").monospacedDigit() }
                LabeledContent(tr("autocomplete.stats.acceptance")) { Text("\(Int((stats.acceptance * 100).rounded()))%").monospacedDigit() }
                LabeledContent(tr("autocomplete.stats.streakTitle")) { Text(tr("autocomplete.stats.streak", stats.streak())).monospacedDigit() }
            }

            let top = stats.topApps(6)
            if !top.isEmpty {
                Section(tr("autocomplete.stats.topApps")) {
                    let most = max(top.first?.count.takes ?? 1, 1)
                    ForEach(top, id: \.bundleID) { entry in
                        HStack(spacing: 10) {
                            AppIcon(url: NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID))
                            Text(appName(entry.bundleID)).frame(width: 140, alignment: .leading).lineLimit(1)
                            ProgressView(value: Double(entry.count.takes), total: Double(most)).tint(SettingsSection.autocomplete.tileColors.1)
                            Text(tr("autocomplete.stats.timesShort", entry.count.takes)).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                }
            }

            Section {
                Button(tr("autocomplete.stats.reset"), role: .destructive) { confirmReset = true }.disabled(stats.totalShown == 0 && stats.totalTakes == 0)
                    .confirmationDialog(tr("autocomplete.stats.resetConfirm"), isPresented: $confirmReset) {
                        Button(tr("autocomplete.stats.reset"), role: .destructive) { store.resetStats() }
                    }
            } footer: {
                Text(tr("autocomplete.stats.footer"))
            }
        }
    }

    private func appName(_ bundleID: String) -> String {
        if let app = installed.first(where: { $0.bundleID == bundleID }) { return app.name }
        if let name = autocomplete.seenApps[bundleID] { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    /// "12 min" or "1 h 20 min".
    private func duration(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        return total >= 60 ? tr("autocomplete.stats.hours", total / 60, total % 60) : tr("autocomplete.stats.minutes", total)
    }
}

/// One number on the statistics tab.
private struct StatTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

/// An app's own icon.
private struct AppIcon: View {
    let url: URL?

    var body: some View {
        Group {
            if let url { Image(nsImage: FileIcons.icon(url.path)).resizable() }
            else { Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary) }
        }
        .frame(width: 20, height: 20)
    }
}

/// An app on this Mac that you might type in.
struct InstalledApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let url: URL?

    var id: String { bundleID }

    /// The apps in /Applications, /System/Applications and ~/Applications (one folder deep), off the main thread.
    static func scan() async -> [InstalledApp] {
        await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let roots = ["/Applications", "/System/Applications", manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
            var found: [String: InstalledApp] = [:]
            func add(_ url: URL) {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, found[id] == nil else { return }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? manager.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                found[id] = InstalledApp(bundleID: id, name: name, url: url)
            }
            for root in roots {
                for item in (try? manager.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)) ?? [] {
                    if item.pathExtension == "app" { add(item); continue }
                    for inner in (try? manager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [] where inner.pathExtension == "app" {
                        add(inner)
                    }
                }
            }
            return Array(found.values)
        }.value
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

/// The keys of completing, shown under Settings › Shortcuts with the other keys of Nook.
struct AutocompleteKeysSection: View {
    @ObservedObject private var store = AutocompleteStore.shared

    var body: some View {
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
}
