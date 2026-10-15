import SwiftUI
import AppKit
import AVFoundation
import Speech
import EventKit

/// Settings sections, in the order of the sidebar.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, brain, connections, assistant, agents, usage, privacy, voice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return tr("settings.section.general")
        case .brain: return tr("settings.section.brain")
        case .assistant: return tr("settings.section.assistant")
        case .connections: return tr("settings.section.connections")
        case .agents: return tr("settings.section.agents")
        case .usage: return tr("settings.section.usage")
        case .voice: return tr("settings.section.voice")
        case .privacy: return tr("settings.section.privacy")
        }
    }

    var subtitle: String {
        switch self {
        case .general: return tr("settings.section.general.sub")
        case .brain: return tr("settings.section.brain.sub")
        case .assistant: return tr("settings.section.assistant.sub")
        case .connections: return tr("settings.section.connections.sub")
        case .agents: return tr("settings.section.agents.sub")
        case .usage: return tr("settings.section.usage.sub")
        case .voice: return tr("settings.section.voice.sub")
        case .privacy: return tr("settings.section.privacy.sub")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "checklist"
        case .brain: return "brain"
        case .assistant: return "sparkles"
        case .connections: return "link"
        case .agents: return "terminal"
        case .usage: return "chart.bar.xaxis"
        case .voice: return "waveform"
        case .privacy: return "lock.shield"
        }
    }
}

/// Settings: sidebar navigation with sections. A one-sentence summary is displayed at the top of each view.
struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var settings = AppSettings.shared

    @State private var keyDraft = ""
    @State private var status = ""
    @State private var refreshTick = 0
    @State private var connectionSearch = ""
    @ObservedObject private var local = EmbeddedModel.shared
    @State private var installing: String?
    @State private var installFraction: Double = 0
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?
    @State private var pendingChange: AgentConfigInstaller.Change?
    @State private var agentStates: [AgentConfigInstaller.Target: AgentConfigInstaller.State] = [:]
    @State private var fetchedModels: [String] = []
    @State private var fetchingModels = false
    @State private var recommendations: [ModelAdvisor.Recommendation] = []

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: Binding(
                get: { Optional(app.settingsSection) },
                set: { if let value = $0 { app.settingsSection = value } }
            )) { section in
                Label(section.title, systemImage: section.symbol)
                    .badge(badge(for: section))
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 240)
        } detail: {
            Form {
                Section {
                    SettingsHeader(section: app.settingsSection, mood: headerMood)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 0, trailing: 0))
                detail(for: app.settingsSection)
                if !status.isEmpty {
                    Section {
                        Label(status, systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .id("\(app.settingsSection.rawValue)-\(settings.appLanguage.rawValue)")
        }
        .tint(NookTheme.iris)
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            refreshTick += 1
            refreshAgentStates()
            app.history.refresh()
        }
        .onChange(of: app.settingsSection) { _, _ in
            status = ""
            refreshTick += 1
            if app.settingsSection == .agents {
                app.adoptAccounts()
                app.history.refresh()
            }
        }
        .onChange(of: app.agentConnect) { _, _ in refreshAgentStates() }
        .sheet(item: $pendingChange) { change in
            ConfigPreview(change: change) {
                pendingChange = nil
            } onConfirm: {
                write(change)
            }
        }
    }

    /// Sidebar badge count indicating pending actions.
    private func badge(for section: SettingsSection) -> Int {
        switch section {
        case .general: return checklist.filter { !$0.done }.count
        case .connections: return app.connectors.sources.filter { if case .error = $0.status.state { return true }; return false }.count
        default: return 0
        }
    }

    /// Nook looks satisfied when all checklist items are configured, otherwise calm.
    private var headerMood: NookMood {
        checklist.allSatisfy(\.done) ? .done : .rest
    }

    @ViewBuilder
    private func detail(for section: SettingsSection) -> some View {
        switch section {
        case .general: overviewSection
        case .brain: brainSection
        case .assistant: assistantSection
        case .connections: connectionsSection
        case .agents: agentsSection
        case .usage: usageSection
        case .voice: voiceSection
        case .privacy: privacySection
        }
    }

    // MARK: Overview

    private struct Step: Identifiable {
        var id: String { title }
        var title: String
        var detail: String
        var done: Bool
        var button: String
        var section: SettingsSection
        /// Permission request run in place; nil means the button navigates to `section`.
        var request: (@MainActor () async -> Void)? = nil
    }

    private var checklist: [Step] {
        let _ = refreshTick
        let _ = settings.appLanguage
        return [
            Step(title: tr("settings.checklist.brain"), detail: settings.brainReady ? tr("settings.checklist.brain.ready", settings.activeModelName) : tr("settings.checklist.brain.notReady"),
                 done: settings.brainReady, button: tr("button.choose"), section: .brain),
            Step(title: tr("settings.checklist.screen"), detail: CGPreflightScreenCaptureAccess() ? tr("settings.checklist.screen.granted") : tr("settings.checklist.screen.notGranted"),
                 done: CGPreflightScreenCaptureAccess(), button: tr("button.allow"), section: .privacy,
                 request: { _ = CGRequestScreenCaptureAccess() }),
            Step(title: tr("settings.checklist.calendar"), detail: app.calendar.hasEventAccess ? tr("settings.checklist.calendar.granted") : tr("settings.checklist.calendar.notGranted"),
                 done: app.calendar.hasEventAccess, button: tr("button.allow"), section: .privacy,
                 request: { _ = await app.calendar.requestEvents(); app.connectors.refreshAll() }),
            Step(title: tr("settings.checklist.connectors"), detail: tr("settings.checklist.connectors.detail", app.connectors.active.count),
                 done: app.connectors.active.count >= 3, button: tr("button.view"), section: .connections)
        ]
    }

    private var overviewSection: some View {
        Group {
            Section(tr("settings.overview.languageSection")) {
                Picker(tr("settings.overview.appLanguage"), selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
            }
            Section {
                StatusRow(title: tr("settings.overview.readyToUse"),
                          detail: tr("settings.overview.countOf", checklist.filter(\.done).count, checklist.count),
                          state: checklist.allSatisfy(\.done) ? .done : .todo) {
                    if !checklist.allSatisfy(\.done) {
                        Button(tr("settings.setup.open")) { app.startOnboarding() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }
            Section {
                shortcutRow(tr("settings.overview.askTyping"), keys: ["⌥", "⌘", tr("settings.overview.spaceKey")])
                shortcutRow(tr("settings.overview.talkNook"), keys: ["⌥", tr("settings.overview.spaceKey")])
                shortcutRow(tr("settings.overview.lookScreen"), keys: ["⌥", "⌘", "N"])
                LabeledContent(tr("settings.overview.openPanel")) {
                    Text(tr("settings.overview.pointToNotch")).foregroundStyle(.secondary)
                }
            } header: {
                Text(tr("settings.overview.howToUse"))
            } footer: {
                Text(tr("settings.overview.howToUseFooter"))
            }
            Section(tr("settings.notch.title")) {
                Picker(tr("settings.notch.placement"), selection: $settings.placement) {
                    Text(tr("settings.notch.placementNotch")).tag("notch")
                    Text(tr("settings.notch.placementFloating")).tag("floating")
                }
                if settings.placement == "floating" {
                    Text(tr("settings.notch.placementHint")).font(.caption).foregroundStyle(.secondary)
                } else {
                    SettingToggle(tr("settings.notch.allScreens"), detail: tr("settings.notch.allScreensDetail"), isOn: $settings.notchOnAllScreens)
                }
                Picker(tr("settings.notch.screen"), selection: $settings.screenChoice) {
                    Text(tr("settings.notch.auto")).tag("auto")
                    Text(tr("settings.notch.main")).tag("main")
                    Text(tr("settings.notch.mouse")).tag("mouse")
                    ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { name in
                        Text(name).tag(name)
                    }
                    // A previously chosen screen that is not connected right now stays selectable.
                    if !["auto", "main", "mouse"].contains(settings.screenChoice),
                       !NSScreen.screens.map(\.localizedName).contains(settings.screenChoice) {
                        Text(settings.screenChoice).tag(settings.screenChoice)
                    }
                }
                .disabled(settings.placement == "notch" && settings.notchOnAllScreens)
                Toggle(tr("settings.notch.hideWhenIdle"), isOn: $settings.hideWhenIdle)
                Toggle(tr("settings.notch.openOnHover"), isOn: Binding(
                    get: { app.viewModel.openOnHover },
                    set: { app.viewModel.openOnHover = $0; refreshTick += 1 }
                ))
                Toggle(tr("settings.notch.demoData"), isOn: $app.demoMode)
            }
        }
    }

    private func shortcutRow(_ title: String, keys: [String]) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { Keycap(label: $0) }
            }
        }
    }

    // MARK: Brain

    private enum BrainKind: Hashable { case local, external }
    private enum LocalRuntime: Hashable { case builtIn, ollama, lmstudio }
    private enum ExternalKind: Hashable { case claude, other }

    /// Local first: the built-in model, Ollama and LM Studio all keep everything on the Mac. External is a deliberate choice.
    private var brainKind: Binding<BrainKind> {
        Binding(
            get: { settings.isLocalBrain ? .local : .external },
            set: { kind in
                testResult = nil
                fetchedModels = []
                switch kind {
                case .local:
                    if !settings.isLocalBrain { settings.useLocal = true }
                case .external:
                    settings.useLocal = false
                    if settings.provider.isLocalServer { settings.provider = .claude }
                }
            }
        )
    }

    private var localRuntime: Binding<LocalRuntime> {
        Binding(
            get: { settings.useLocal ? .builtIn : (settings.provider == .ollama ? .ollama : .lmstudio) },
            set: { runtime in
                testResult = nil
                fetchedModels = []
                switch runtime {
                case .builtIn: settings.useLocal = true
                case .ollama: settings.useLocal = false; settings.provider = .ollama
                case .lmstudio: settings.useLocal = false; settings.provider = .lmstudio
                }
            }
        )
    }

    private var externalKind: Binding<ExternalKind> {
        Binding(
            get: { [.claude, .claudeCode].contains(settings.provider) ? .claude : .other },
            set: { kind in
                testResult = nil
                fetchedModels = []
                switch kind {
                case .claude: if settings.provider != .claudeCode { settings.provider = .claude }
                case .other: if [.claude, .claudeCode].contains(settings.provider) || settings.provider.isLocalServer { settings.provider = .openai }
                }
            }
        )
    }

    private var brainSection: some View {
        Group {
            Section {
                Picker(tr("settings.brain.where"), selection: brainKind) {
                    Text(tr("settings.brain.localChoice")).tag(BrainKind.local)
                    Text(tr("settings.brain.externalChoice")).tag(BrainKind.external)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(settings.isLocalBrain ? tr("settings.brain.localDefault") : tr("settings.brain.externalWarning"))
            }

            if settings.isLocalBrain {
                Section(tr("brain.advice.title")) { adviceRows }
                Section {
                    Picker(tr("settings.brain.localRuntime"), selection: localRuntime) {
                        Text(tr("settings.brain.builtIn")).tag(LocalRuntime.builtIn)
                        Text("Ollama").tag(LocalRuntime.ollama)
                        Text("LM Studio").tag(LocalRuntime.lmstudio)
                    }
                    .pickerStyle(.segmented)
                    if settings.useLocal { localFields } else { providerFields }
                }
            } else {
                Section {
                    Picker(tr("settings.brain.thinksWith"), selection: externalKind) {
                        Text(tr("settings.brain.claude")).tag(ExternalKind.claude)
                        Text(tr("settings.brain.otherAI")).tag(ExternalKind.other)
                    }
                    .pickerStyle(.segmented)
                    providerFields
                } footer: {
                    Text(brainExplanation)
                }
            }

            Section {
                Picker(tr("settings.brain.answerLanguage"), selection: $settings.language) {
                    ForEach(AppSettings.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                HStack {
                    Button(tr("button.testConnection")) { Task { await testConnection() } }
                        .disabled(!settings.brainReady || testing)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let result = testResult {
                    Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(result.ok ? Color.green : Color.red)
                        .textSelection(.enabled)
                }
            }
        }
        .task { recommendations = await app.brainRecommendations() }
    }

    /// The models Nook proposes for this Mac, best first, with one button to use or install each.
    private var adviceRows: some View {
        Group {
            Text(tr("brain.advice.memory", EmbeddedModel.memoryGB))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(recommendations.prefix(3).enumerated()), id: \.offset) { index, recommendation in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(AppModel.title(of: recommendation)).fontWeight(index == 0 ? .semibold : .regular)
                            if index == 0, recommendation.choice != .unavailable {
                                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                            }
                        }
                        Text(recommendation.reason).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    adviceButton(recommendation)
                }
            }
        }
    }

    @ViewBuilder
    private func adviceButton(_ recommendation: ModelAdvisor.Recommendation) -> some View {
        switch recommendation.choice {
        case .unavailable:
            EmptyView()
        case .mlx(let option) where installing == option.id:
            ProgressView(value: installFraction).frame(width: 90)
        case .mlx(let option) where settings.useLocal && settings.localModel == option.id:
            Label(tr("brain.advice.inUse"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .server(let model) where !settings.useLocal && settings.activeProviderModel == model.name
                && settings.provider == (model.server == .ollama ? .ollama : .lmstudio):
            Label(tr("brain.advice.inUse"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .mlx(let option) where !recommendation.ready:
            Button(tr("brain.advice.install")) { Task { await install(option.id) } }
                .disabled(installing != nil)
        default:
            Button(tr("brain.advice.use")) {
                Task {
                    try? await app.useRecommendation(recommendation)
                    testResult = nil
                }
            }
        }
    }

    private var brainExplanation: String {
        if [.claude, .claudeCode].contains(settings.provider) {
            return tr("settings.brain.claudeExplanation")
        }
        return tr("settings.brain.otherExplanation")
    }

    private var providerFields: some View {
        Group {
            if settings.provider.isLocalServer {
                EmptyView()
            } else if [.claude, .claudeCode].contains(settings.provider) {
                Picker(tr("settings.brain.connectVia"), selection: $settings.provider) {
                    Text(tr("settings.brain.apiKey")).tag(AIProvider.claude)
                    Text(tr("settings.brain.claudeCodeSub")).tag(AIProvider.claudeCode)
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.provider) { _, _ in testResult = nil }
            } else {
                Picker(tr("settings.brain.provider"), selection: $settings.provider) {
                    ForEach(AIProvider.allCases.filter { $0 != .claude && $0 != .claudeCode && !$0.isLocalServer }) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.provider) { _, _ in
                    fetchedModels = []
                    testResult = nil
                }
            }

            if settings.provider == .claudeCode {
                claudeCodeStatus
            } else if settings.provider.needsKey {
                HStack {
                    SecureField(settings.provider.keyPlaceholder, text: $keyDraft)
                        .onSubmit(saveKey)
                    Button(tr("button.save"), action: saveKey)
                        .disabled(keyDraft.isEmpty && !settings.hasKey(for: settings.provider))
                }
                HStack {
                    if settings.hasKey(for: settings.provider) {
                        Label(settings.provider == .claude ? "\(tr("settings.brain.keyInKeychain")): \(settings.maskedKey ?? "")" : tr("settings.brain.keyInKeychain"), systemImage: "key.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(tr("settings.brain.keyStaysInKeychain")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = settings.provider.keyURL {
                        Link(tr("settings.brain.createKey"), destination: url).font(.caption)
                    }
                }
            } else if let url = settings.provider.keyURL {
                HStack {
                    Text(tr("settings.brain.providerMustRun", settings.provider.title)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Link(tr("button.download"), destination: url).font(.caption)
                }
            }

            HStack {
                TextField(tr("settings.brain.model"), text: Binding(
                    get: { settings.activeProviderModel },
                    set: { settings.setProviderModel($0) }
                ))
                Menu(tr("button.choose")) {
                    let models = fetchedModels.isEmpty ? settings.provider.suggestedModels : fetchedModels
                    ForEach(models, id: \.self) { id in
                        Button(id) { settings.setProviderModel(id) }
                    }
                    Divider()
                    Button(tr("button.fetchModels")) { Task { await fetchModels() } }
                }
                .fixedSize()
                if fetchingModels { ProgressView().controlSize(.small) }
            }
            if settings.provider == .claude {
                Text(tr("settings.brain.haikuHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Claude Code detected? Nothing left to do except test.
    private var claudeCodeStatus: some View {
        let _ = refreshTick
        let path = ClaudeCodeBrain.executable
        return VStack(alignment: .leading, spacing: 6) {
            if let path {
                Label(tr("settings.brain.claudeFound", path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(tr("settings.brain.claudeLoginHint"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label(tr("settings.brain.claudeNotFound"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(tr("settings.brain.claudeInstallHint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button(tr("button.searchAgain")) { ClaudeCodeBrain.resetLocation(); refreshTick += 1; settings.objectWillChange.send() }
                    if let url = settings.provider.keyURL { Link(tr("settings.brain.moreAboutClaudeCode"), destination: url) }
                }
            }
        }
    }

    private func fetchModels() async {
        fetchingModels = true
        defer { fetchingModels = false }
        do {
            let key = settings.provider == .claude ? settings.apiKey : settings.providerKey
            fetchedModels = try await settings.provider.listModels(key: key)
            status = fetchedModels.isEmpty ? tr("settings.brain.noModelsFound") : tr("settings.brain.modelsFound", fetchedModels.count)
        } catch {
            status = error.localizedDescription
        }
    }

    private var localFields: some View {
        Group {
            ForEach(EmbeddedModel.options) { option in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.title)
                        Text(option.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if installing == option.id {
                        ProgressView(value: installFraction).frame(width: 90)
                        Text("\(Int(installFraction * 100))%").font(.caption.monospacedDigit())
                    } else if local.installed.contains(option.id) {
                        if settings.localModel == option.id {
                            Label(tr("settings.brain.inUse"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button(tr("settings.brain.use")) { settings.localModel = option.id; testResult = nil }
                        }
                    } else if !option.fits {
                        Text(tr("settings.brain.tooHeavyForMemory", EmbeddedModel.memoryGB)).font(.caption).foregroundStyle(.orange)
                    } else {
                        Button(tr("button.download")) { Task { await install(option.id) } }
                            .disabled(installing != nil)
                    }
                }
            }
            Text(tr("settings.brain.localModelDownloadHint", EmbeddedModel.memoryGB))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func install(_ id: String) async {
        guard installing == nil else { return }
        installing = id
        installFraction = 0
        testResult = nil
        defer { installing = nil }
        do {
            try await local.install(id) { fraction in
                Task { @MainActor in installFraction = fraction }
            }
            settings.useLocal = true
            settings.localModel = id
            recommendations = await app.brainRecommendations()
            status = "\(local.title(for: id)) is ready and currently active."
            await testConnection()
        } catch {
            testResult = (false, error.localizedDescription)
        }
    }

    private func saveKey() {
        let provider = settings.provider
        if provider == .claude {
            if !keyDraft.isEmpty {
                let saved = settings.saveAPIKey(keyDraft)
                keyDraft = ""
                if !saved.looksValid {
                    testResult = (false, "This does not look like an Anthropic key: it should start with sk-ant-. Testing anyway.")
                }
                status = saved.keychainError.map { "Keychain rejected the key (\($0)). It will only work until Nook quits." } ?? "Key saved in Keychain."
            } else {
                settings.saveAPIKey("")
                testResult = nil
                status = "Key removed."
                return
            }
        } else {
            let error = settings.saveProviderKey(keyDraft, for: provider)
            let removed = keyDraft.isEmpty
            keyDraft = ""
            status = error ?? (removed ? "Key removed." : "Key saved in Keychain.")
            if removed { return }
        }
        Task { await testConnection() }
    }

    private func testConnection() async {
        testing = true
        defer { testing = false }
        do {
            let reply = try await app.brain.test()
            testResult = (true, "Verbonden met \(settings.activeModelName). Antwoord: “\(reply)”")
        } catch {
            testResult = (false, error.localizedDescription)
        }
    }

    // MARK: Assistant

    private var assistantSection: some View {
        Group {
            Section(tr("settings.assistant.whatNookSees")) {
                SettingToggle(tr("settings.assistant.trackAllScreens"), detail: tr("settings.assistant.trackAllScreensDetail"), isOn: $settings.liveScreen)
                SettingToggle(tr("settings.assistant.useScreensEveryQuestion"), detail: tr("settings.assistant.useScreensEveryQuestionDetail"), isOn: $settings.screenWithEveryQuestion)
                LabeledContent(tr("settings.assistant.currentlyOnScreen")) {
                    Text(app.screenContext.windows.isEmpty ? tr("settings.assistant.nothingRead") : "\(app.screenContext.windows.count) vensters op \(max(1, app.screenContext.displayCount)) \(app.screenContext.displayCount == 1 ? "scherm" : "schermen")")
                        .foregroundStyle(.secondary)
                }
                if !CGPreflightScreenCaptureAccess() {
                    Button(tr("settings.assistant.grantScreenPermission")) { CGRequestScreenCaptureAccess(); refreshTick += 1 }
                }
            }
            Section(tr("settings.assistant.thinkAlong")) {
                SettingToggle(tr("settings.assistant.webSearch"), detail: tr("settings.assistant.webSearchDetail"), isOn: $settings.webSearch)
                SettingToggle(tr("settings.assistant.thinkAlongToggle"), detail: tr("settings.assistant.thinkAlongDetail"), isOn: $settings.autoWatch)
                .disabled(settings.useLocal)
                if !app.thinkAlong.mutedApps.isEmpty {
                    LabeledContent(tr("settings.assistant.mutedIn")) {
                        HStack {
                            Text(app.thinkAlong.mutedApps.values.sorted().joined(separator: ", "))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Button(tr("button.clear")) { app.thinkAlong.unmuteAll() }
                        }
                    }
                }
                SettingToggle(tr("settings.assistant.autoRunSafe"), detail: tr("settings.assistant.autoRunSafeDetail"), isOn: $settings.autoRunSafe)
            }
        }
    }

    // MARK: Connectors

    private var connectionsSection: some View {
        Group {
            Section {
                TextField(tr("settings.connections.search"), text: $connectionSearch, prompt: Text(tr("settings.connections.searchPrompt")))
                Text(tr("settings.connections.legend"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                let sources = localSources
                ForEach(sources.indices, id: \.self) { index in
                    localRow(sources[index])
                }
            } header: {
                Text(tr("settings.connections.onYourMac"))
            } footer: {
                Text(tr("settings.connections.footer"))
            }
            Section(tr("settings.connections.services")) {
                CloudConnectorSettings(connectors: app.connectors.sources.filter { !($0 is MCPConnector) && matchesSearch($0) }, capabilities: capabilityLine) {
                    app.connectors.refreshAll()
                }
            }
            MCPSettingsSection()
            // Agent accounts (Claude Code, Codex, Gemini): the same place as every other account.
            AccountsSettingsSection()
            Section {} footer: {
                Text(tr("accounts.isolationNote"))
            }
            if matchesSearch(title: app.portfolio.title) {
                Section(tr("settings.connections.crypto")) {
                    PortfolioSettings(portfolio: app.portfolio)
                }
            }
            Section {
                ForEach(NotYetBuiltIn.all.filter { matchesSearch(title: $0.name) }, id: \.name) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                        Text(item.how).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text(tr("settings.connections.notBuiltIn"))
            } footer: {
                Text(tr("settings.connections.notBuiltInFooter"))
            }
        }
    }

    private var localSources: [ContextSource] {
        let ids = ["calendar", "reminders", "notes", "mail", "browser", "files", "clipboard"]
        return ids.compactMap { app.connectors.source(id: $0) }.filter { matchesSearch($0) }
    }

    private func matchesSearch(_ source: ContextSource) -> Bool {
        matchesSearch(title: source.title + " " + capabilityLine(source.id))
    }

    private func matchesSearch(title: String) -> Bool {
        let query = connectionSearch.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || title.localizedCaseInsensitiveContains(query)
    }

    /// How a connector is configured, its read capabilities, and actions requiring approval.
    private func capabilityLine(_ id: String) -> String {
        SourceCapabilities.line(id, tools: app.knownTools.map { ($0.name, $0.kind == .action) })
    }

    private func localRow(_ source: ContextSource) -> some View {
        let fallback = source.id != "clipboard"
        return Toggle(isOn: Binding(
            get: { let _ = refreshTick; return ConnectorToggle.isOn(source.id, default: fallback) },
            set: { on in
                ConnectorToggle.set(source.id, on)
                refreshTick += 1
                app.connectors.refresh(source)
            }
        )) {
            HStack(spacing: 10) {
                SiteIcon(domain: source.iconDomain, fallback: source.symbol, tint: source.accent, size: 20)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title)
                    Text(localDetail(source)).font(.caption).foregroundStyle(.secondary)
                    Text(capabilityLine(source.id) + (source.status.updated.map { " · " + tr("context.updated", NookDates.ago($0)) } ?? ""))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func localDetail(_ source: ContextSource) -> String {
        if case .error(let message) = source.status.state { return message }
        switch source.id {
        case "calendar": return app.calendar.hasEventAccess ? (source.status.headline.isEmpty ? tr("settings.connections.calendarDetail") : source.status.headline) : tr("settings.connections.givePermission")
        case "reminders": return app.calendar.hasReminderAccess ? (source.status.headline.isEmpty ? tr("settings.connections.remindersDetail") : source.status.headline) : tr("settings.connections.givePermission")
        case "mail": return tr("settings.connections.mailDetail")
        case "browser": return tr("settings.connections.browserDetail")
        case "files": return tr("settings.connections.filesDetail")
        case "clipboard": return tr("settings.connections.clipboardDetail")
        default: return source.status.detail
        }
    }

    // MARK: Agents

    private var agentsSection: some View {
        Group {
            Section {
                ForEach(AgentConfigInstaller.Target.allCases) { target in
                    agentRow(target)
                }
            } header: {
                Text(tr("settings.agents.linkAgents"))
            } footer: {
                Text(tr("settings.agents.linkAgentsFooter"))
            }
            WorkspaceSettingsSection()
        }
    }

    // MARK: Usage

    /// All usage in one place: plan limits per account, tokens and reported costs of agent sessions.
    private var usageSection: some View {
        Group {
            Section(tr("settings.agents.subscriptions")) {
                ForEach(app.profiles.all.filter { $0.kind != .gemini }) { profile in
                    LabeledContent("\(profile.kind.shortName) · \(AccountLabel.name(profile, app: app))") {
                        Text(app.quota.summary(for: profile)
                             ?? tr(profile.kind == .claude ? "settings.usage.claudeMissing" : "settings.usage.codexMissing"))
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent(tr("settings.usage.brain")) {
                    Text(settings.isLocalBrain ? tr("settings.usage.brainLocal") : tr("settings.usage.brainExternal", settings.provider.title))
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                UsageView()
                    .environmentObject(app.workspace)
                    .frame(minHeight: 520)
                    .listRowInsets(EdgeInsets())
            }
        }
    }

    private func agentRow(_ target: AgentConfigInstaller.Target) -> some View {
        let state = agentStates[target] ?? .notInstalled
        let rowState: StatusState = {
            switch state {
            case .installed: return .done
            case .outdated: return .warning
            case .unreadable: return .error
            case .notInstalled: return .todo
            }
        }()
        return StatusRow(title: target.title, detail: stateText(state, target: target), state: rowState) {
            switch state {
            case .notInstalled:
                Button(tr("button.linkEllipsis")) { prepare(target, install: true) }
                    .controlSize(.small)
            case .outdated:
                Button(tr("button.updateEllipsis")) { prepare(target, install: true) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(tr("button.unlinkEllipsis")) { prepare(target, install: false) }
                    .controlSize(.small)
            case .installed:
                Button(tr("button.unlinkEllipsis")) { prepare(target, install: false) }
                    .controlSize(.small)
            case .unreadable:
                EmptyView()
            }
        }
    }

    private func stateText(_ state: AgentConfigInstaller.State, target: AgentConfigInstaller.Target) -> String {
        switch state {
        case .notInstalled: return target.detail
        case .installed: return "\(tr("agents.status.done")) · \(target.displayPath)"
        case .outdated: return "Connected with an older version: update for permissions and prompts in the notch"
        case .unreadable(let message): return message
        }
    }

    private func refreshAgentStates() {
        var states: [AgentConfigInstaller.Target: AgentConfigInstaller.State] = [:]
        for target in AgentConfigInstaller.Target.allCases {
            states[target] = AgentConfigInstaller.state(of: target)
        }
        agentStates = states
    }

    private func prepare(_ target: AgentConfigInstaller.Target, install: Bool) {
        do {
            pendingChange = try AgentConfigInstaller.prepare(target, install: install)
        } catch {
            status = error.localizedDescription
        }
    }

    private func write(_ change: AgentConfigInstaller.Change) {
        pendingChange = nil
        do {
            let backup = try AgentConfigInstaller.apply(change)
            let verb = change.install ? tr("button.link") : tr("button.unlink")
            status = "\(change.target.title): \(verb)." + (backup.map { " Backup: \($0.lastPathComponent)" } ?? "")
                + (change.install && change.target != .claudeStatusLine ? " Restart the agent for changes to take effect." : "")
        } catch {
            status = error.localizedDescription
        }
        refreshAgentStates()
    }

    // MARK: Voice and Sound

    private var voiceSection: some View {
        Group {
            Section {
                Toggle(tr("settings.voice.speakAnswers"), isOn: $settings.speakAnswers)
                Toggle(tr("settings.voice.wakeWord"), isOn: $settings.wakeWord)
                    .disabled(!WakeWordService.supported)
            } header: {
                Text(tr("settings.voice.speaking"))
            } footer: {
                Text(WakeWordService.supported
                     ? "With wake word enabled, Nook continuously listens on-device. Audio is never stored or transmitted. The orange microphone indicator will be visible."
                     : "This Mac cannot recognize speech on-device, so wake word cannot be enabled. Use ⌥ Space to talk anytime.")
            }
            Section {
                Toggle(tr("settings.voice.agentSound"), isOn: $settings.sounds)
                LabeledContent(tr("settings.voice.customSounds")) {
                    Button(tr("button.openFolder")) { NookSound.openFolder() }
                }
            } header: {
                Text(tr("settings.voice.sounds"))
            } footer: {
                Text(tr("settings.voice.customSoundsHint"))
            }
        }
    }

    // MARK: Privacy and Access

    private var privacySection: some View {
        Group {
            Section {
                permissionRow(tr("settings.privacy.screenReading"), detail: tr("settings.privacy.screenReadingDetail"), granted: CGPreflightScreenCaptureAccess()) {
                    _ = CGRequestScreenCaptureAccess()
                }
                permissionRow(tr("settings.privacy.calendar"), detail: tr("settings.privacy.calendarDetail"), granted: app.calendar.hasEventAccess) {
                    _ = await app.calendar.requestEvents(); app.connectors.refreshAll()
                }
                permissionRow(tr("settings.privacy.reminders"), detail: tr("settings.privacy.remindersDetail"), granted: app.calendar.hasReminderAccess) {
                    await app.calendar.requestReminders(); app.connectors.refreshAll()
                }
                permissionRow(tr("settings.privacy.micSpeech"), detail: tr("settings.privacy.micSpeechDetail"), granted: VoiceService.permissionsGranted) {
                    _ = await app.voice.requestPermissions()
                }
            } header: {
                Text(tr("settings.privacy.permissions"))
            } footer: {
                Text(tr("settings.privacy.permissionsFooter"))
            }
            .id(refreshTick)
            AuditLogSection()
            Section(tr("settings.privacy.whatLeavesMac")) {
                promise("eye.slash", tr("settings.privacy.noScreenshots"), tr("settings.privacy.noScreenshotsDetail"))
                promise("key", tr("settings.privacy.passwordsHidden"), tr("settings.privacy.passwordsHiddenDetail"))
                promise("hand.raised", tr("settings.privacy.nothingWithoutClick"), tr("settings.privacy.nothingWithoutClickDetail"))
                promise("lock", tr("settings.privacy.keysInKeychain"), tr("settings.privacy.keysInKeychainDetail"))
                LabeledContent(tr("settings.privacy.screenText")) {
                    Button(tr("settings.privacy.forgetScreenText")) {
                        app.screenContext.clear()
                        status = tr("settings.privacy.screenTextForgotten")
                    }
                }
            }
        }
    }

    private func promise(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(NookTheme.iris)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func permissionRow(_ title: String, detail: String, granted: Bool, request: @escaping @MainActor () async -> Void) -> some View {
        StatusRow(title: title, detail: detail, state: granted ? .done : .todo) {
            if granted {
                Text(tr("music.on")).foregroundStyle(.secondary)
            } else {
                Button(tr("button.allow")) {
                    app.requestPermission { await request(); refreshTick += 1 }
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}

/// Diff preview showing changes to an agent's configuration file before writing.
private struct ConfigPreview: View {
    let change: AgentConfigInstaller.Change
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(change.install ? "\(change.target.title) \(tr("button.link"))" : "\(change.target.title) \(tr("button.unlink"))")
                .font(.headline)
            Text(tr("settings.agents.changeNotice", change.target.displayPath))
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if change.preview.isEmpty {
                        Text(tr("settings.agents.noChange")).foregroundStyle(.secondary)
                    }
                    ForEach(change.preview) { line in
                        Text(line.text)
                            .foregroundStyle(color(line.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            HStack {
                Spacer()
                Button(tr("button.cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(change.install ? tr("button.link") : tr("button.unlink"), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
    }

    private func color(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .add: return .green
        case .remove: return .red
        case .context: return .secondary
        }
    }
}

// MARK: Building Blocks

/// Section header: Nook orb for overview, section symbol elsewhere.
private struct SettingsHeader: View {
    let section: SettingsSection
    let mood: NookMood

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                if section == .general {
                    NookOrb(mood: mood, size: 30, animated: false)
                } else {
                    Image(systemName: section.symbol)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(NookTheme.iris)
                }
            }
            .frame(width: 48, height: 48)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(NookTheme.iris.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title).font(.title.weight(.semibold))
                Text(section.subtitle).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

enum StatusState {
    case done, todo, warning, error

    var symbol: String {
        switch self {
        case .done: return "checkmark.circle.fill"
        case .todo: return "circle"
        case .warning: return "exclamationmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .done: return .green
        case .todo: return Color.secondary.opacity(0.55)
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// Standardized row with status icon on the left, label and description, and action button on the right.
private struct StatusRow<Trailing: View>: View {
    let title: String
    let detail: String
    let state: StatusState
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.symbol)
                .font(.system(size: 17))
                .foregroundStyle(state.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(state == .warning || state == .error ? state.color : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 2)
    }
}

/// Toggle switch with concise description below.
private struct SettingToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    init(_ title: String, detail: String, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Keycap representation matching keyboard styling.
private struct Keycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, label.count > 1 ? 9 : 0)
            .frame(minWidth: 24, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
                    .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
            )
    }
}



/// Workspace preferences: default settings for new sessions, worktree location, editor, and terminal.
private struct WorkspaceSettingsSection: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var ws = WorkspaceSettings.shared

    var body: some View {
        Section {
            Picker(tr("settings.ws.provider"), selection: $ws.defaultProvider) {
                ForEach(RunProvider.allCases) { Text($0.displayName).tag($0) }
            }
            ForEach(RunProvider.allCases) { provider in
                Picker(tr("settings.ws.model", provider.displayName), selection: Binding(
                    get: { ws.model(for: provider) },
                    set: { ws.setModel($0, for: provider) }
                )) {
                    ForEach(Array(Set(provider.suggestedModels + [ws.model(for: provider)])).sorted(), id: \.self) { model in
                        Text(model.isEmpty ? tr("ws.model.default") : model).tag(model)
                    }
                }
            }
            Picker(tr("settings.ws.mode"), selection: $ws.defaultMode) {
                ForEach(ExecutionMode.allCases) { Text($0.label).tag($0) }
            }
            Picker(tr("settings.ws.permission"), selection: $ws.defaultPermission) {
                ForEach(PermissionPolicy.allCases) { Text($0.label).tag($0) }
            }
            Picker(tr("settings.ws.isolation"), selection: $ws.defaultIsolation) {
                ForEach(IsolationMode.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent(tr("settings.ws.worktreeRoot")) {
                HStack {
                    Text(AgentPathFormat.tilde(ws.worktreeRoot)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button(tr("ws.new.change")) {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { ws.worktreeRoot = url.path }
                    }
                    .controlSize(.small)
                }
            }
            Picker(tr("settings.ws.editor"), selection: $ws.editorBundleID) {
                Text(tr("settings.ws.finder")).tag("")
                ForEach(WorkspaceSettings.installed(WorkspaceSettings.editorCandidates)) { Text($0.name).tag($0.bundleID) }
            }
            Picker(tr("settings.ws.terminal"), selection: $ws.terminalBundleID) {
                ForEach(WorkspaceSettings.installed(WorkspaceSettings.terminalCandidates)) { Text($0.name).tag($0.bundleID) }
            }
            Picker(tr("settings.ws.autoArchive"), selection: $ws.autoArchiveDays) {
                Text(tr("settings.ws.never")).tag(0)
                Text(tr("settings.ws.days", 7)).tag(7)
                Text(tr("settings.ws.days", 30)).tag(30)
                Text(tr("settings.ws.days", 90)).tag(90)
            }
            Toggle(tr("settings.ws.showCost"), isOn: $ws.showCost)
            Button(tr("settings.ws.open")) { app.openWorkspace() }
        } header: {
            Text(tr("settings.ws.title"))
        } footer: {
            Text(tr("settings.ws.footer"))
        }
    }
}
