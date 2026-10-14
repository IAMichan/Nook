import SwiftUI
import AppKit
import AVFoundation
import Speech
import EventKit

/// De onderdelen van Instellingen, in de volgorde van de zijbalk.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, brain, assistant, connections, agents, voice, privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Overzicht"
        case .brain: return "Brein"
        case .assistant: return "Assistent"
        case .connections: return "Koppelingen"
        case .agents: return "Agents"
        case .voice: return "Stem en geluid"
        case .privacy: return "Privacy en toegang"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Wat werkt er al, en wat nog niet"
        case .brain: return "Met welke AI Nook denkt"
        case .assistant: return "Wat Nook ziet en hoe hij zich gedraagt"
        case .connections: return "Agenda, mail, browser en je diensten"
        case .agents: return "Claude Code, Codex, Cursor en meer"
        case .voice: return "Praten, voorlezen en geluiden"
        case .privacy: return "Machtigingen en wat er je Mac verlaat"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "checklist"
        case .brain: return "brain"
        case .assistant: return "sparkles"
        case .connections: return "link"
        case .agents: return "terminal"
        case .voice: return "waveform"
        case .privacy: return "lock.shield"
        }
    }
}

/// Instellingen: een zijbalk met onderdelen, elk onderdeel een rustige lijst. Bovenaan staat steeds in één zin waar het over gaat.
struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var settings = AppSettings.shared

    @State private var keyDraft = ""
    @State private var status = ""
    @State private var refreshTick = 0
    @ObservedObject private var local = EmbeddedModel.shared
    @State private var installing: String?
    @State private var installFraction: Double = 0
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?
    @State private var pendingChange: AgentConfigInstaller.Change?
    @State private var agentStates: [AgentConfigInstaller.Target: AgentConfigInstaller.State] = [:]
    @State private var fetchedModels: [String] = []
    @State private var fetchingModels = false

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
            .id(app.settingsSection)
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
            if app.settingsSection == .agents { app.history.refresh() }
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

    /// Een getal in de zijbalk als er iets te doen is.
    private func badge(for section: SettingsSection) -> Int {
        switch section {
        case .general: return checklist.filter { !$0.done }.count
        case .connections: return app.connectors.sources.filter { if case .error = $0.status.state { return true }; return false }.count
        default: return 0
        }
    }

    /// Nook kijkt tevreden als alles klaarstaat, en wacht anders rustig.
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
        case .voice: voiceSection
        case .privacy: privacySection
        }
    }

    // MARK: Overzicht

    private struct Step: Identifiable {
        var id: String { title }
        var title: String
        var detail: String
        var done: Bool
        var button: String
        var section: SettingsSection
    }

    private var checklist: [Step] {
        let _ = refreshTick
        return [
            Step(title: "Kies een brein", detail: settings.brainReady ? "Nook denkt met \(settings.activeModelName)." : "Claude, een andere AI of gratis op je Mac.",
                 done: settings.brainReady, button: "Kies", section: .brain),
            Step(title: "Laat Nook je schermen lezen", detail: CGPreflightScreenCaptureAccess() ? "Nook ziet al je vensters, op al je schermen." : "Dan kan hij vragen beantwoorden over wat je ziet.",
                 done: CGPreflightScreenCaptureAccess(), button: "Toestaan", section: .privacy),
            Step(title: "Koppel je agenda", detail: app.calendar.hasEventAccess ? "Nook kent je afspraken." : "Voor vragen als \"wanneer ben ik vrij?\"",
                 done: app.calendar.hasEventAccess, button: "Toestaan", section: .privacy),
            Step(title: "Koppel je diensten", detail: "\(app.connectors.active.count) bronnen actief. Mail, browser, GitHub, Stripe…",
                 done: app.connectors.active.count >= 3, button: "Bekijk", section: .connections)
        ]
    }

    private var overviewSection: some View {
        Group {
            Section {
                ForEach(checklist) { step in
                    StatusRow(title: step.title, detail: step.detail, state: step.done ? .done : .todo) {
                        if !step.done {
                            Button(step.button) {
                                if step.section == .privacy, step.title.contains("schermen") {
                                    CGRequestScreenCaptureAccess()
                                } else if step.section == .privacy {
                                    Task { await app.calendar.requestEvents(); refreshTick += 1 }
                                }
                                app.settingsSection = step.section
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Klaar om te gebruiken")
                    Spacer()
                    Text("\(checklist.filter(\.done).count) van \(checklist.count)")
                        .monospacedDigit()
                }
            }
            Section {
                shortcutRow("Vraag iets (typen)", keys: ["⌥", "⌘", "spatie"])
                shortcutRow("Praat met Nook", keys: ["⌥", "spatie"])
                shortcutRow("Laat Nook meekijken", keys: ["⌥", "⌘", "N"])
                LabeledContent("Open het paneel") {
                    Text("wijs naar de notch").foregroundStyle(.secondary)
                }
            } header: {
                Text("Zo gebruik je Nook")
            } footer: {
                Text("Vraag gewoon wat je wilt: “wat staat er in die mail?”, “zet dit in mijn agenda”. Nook kijkt zelf op je schermen, in je agenda en in je koppelingen. Niets gebeurt zonder jouw klik.")
            }
            Section("Notch") {
                Picker("Scherm", selection: $settings.screenChoice) {
                    Text("Automatisch (met notch)").tag("auto")
                    Text("Hoofdscherm").tag("main")
                    Text("Volgt je muis").tag("mouse")
                    ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Toggle("Verberg Nook als er niets is", isOn: $settings.hideWhenIdle)
                Toggle("Open het paneel als ik naar de notch wijs", isOn: Binding(
                    get: { app.viewModel.openOnHover },
                    set: { app.viewModel.openOnHover = $0; refreshTick += 1 }
                ))
                Toggle("Voorbeelddata tonen (om rond te kijken)", isOn: $app.demoMode)
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

    // MARK: Brein

    private enum BrainKind: Hashable { case claude, other, local }

    private var brainKind: Binding<BrainKind> {
        Binding(
            get: { settings.useLocal ? .local : ([.claude, .claudeCode].contains(settings.provider) ? .claude : .other) },
            set: { kind in
                testResult = nil
                fetchedModels = []
                switch kind {
                case .local: settings.useLocal = true
                case .claude:
                    settings.useLocal = false
                    if settings.provider != .claudeCode { settings.provider = .claude }
                case .other:
                    settings.useLocal = false
                    if [.claude, .claudeCode].contains(settings.provider) { settings.provider = .openai }
                }
            }
        )
    }

    private var brainSection: some View {
        Group {
            Section {
                Picker("Nook denkt met", selection: brainKind) {
                    Text("Claude").tag(BrainKind.claude)
                    Text("Andere AI").tag(BrainKind.other)
                    Text("Gratis op je Mac").tag(BrainKind.local)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(brainExplanation)
            }

            if settings.useLocal {
                Section("Ingebouwd model") { localFields }
            } else {
                Section([.claude, .claudeCode].contains(settings.provider) ? "Claude" : "Aanbieder") { providerFields }
            }

            Section {
                Picker("Taal van antwoorden", selection: $settings.language) {
                    ForEach(AppSettings.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                HStack {
                    Button("Test verbinding") { Task { await testConnection() } }
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
    }

    private var brainExplanation: String {
        if settings.useLocal { return "Draait helemaal op je Mac, zonder internet en zonder sleutel. Minder slim dan Claude." }
        if [.claude, .claudeCode].contains(settings.provider) {
            return "Aanbevolen. Met een API-sleutel is Nook het snelst; met je Claude-abonnement (Pro of Max) werkt het via Claude Code op je Mac, zonder sleutel."
        }
        return "OpenAI, Gemini, DeepSeek, Qwen, Moonshot, of Ollama en LM Studio op je eigen Mac. Zoeken op het web werkt met elk brein."
    }

    private var providerFields: some View {
        Group {
            if [.claude, .claudeCode].contains(settings.provider) {
                Picker("Verbinden via", selection: $settings.provider) {
                    Text("API-sleutel").tag(AIProvider.claude)
                    Text("Mijn abonnement (Claude Code)").tag(AIProvider.claudeCode)
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.provider) { _, _ in testResult = nil }
            } else {
                Picker("Aanbieder", selection: $settings.provider) {
                    ForEach(AIProvider.allCases.filter { $0 != .claude && $0 != .claudeCode }) { Text($0.title).tag($0) }
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
                    Button("Bewaar", action: saveKey)
                        .disabled(keyDraft.isEmpty && !settings.hasKey(for: settings.provider))
                }
                HStack {
                    if settings.hasKey(for: settings.provider) {
                        Label(settings.provider == .claude ? "Sleutel opgeslagen: \(settings.maskedKey ?? "")" : "Sleutel opgeslagen in je Keychain", systemImage: "key.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Je sleutel blijft in je Keychain.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = settings.provider.keyURL {
                        Link("Maak een sleutel", destination: url).font(.caption)
                    }
                }
            } else if let url = settings.provider.keyURL {
                HStack {
                    Text("\(settings.provider.title) moet draaien met een geladen model.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Link("Download", destination: url).font(.caption)
                }
            }

            HStack {
                TextField("Model", text: Binding(
                    get: { settings.activeProviderModel },
                    set: { settings.setProviderModel($0) }
                ))
                Menu("Kies") {
                    let models = fetchedModels.isEmpty ? settings.provider.suggestedModels : fetchedModels
                    ForEach(models, id: \.self) { id in
                        Button(id) { settings.setProviderModel(id) }
                    }
                    Divider()
                    Button("Haal modellen op") { Task { await fetchModels() } }
                }
                .fixedSize()
                if fetchingModels { ProgressView().controlSize(.small) }
            }
            if settings.provider == .claude {
                Text("Haiku is het snelst en ruim slim genoeg voor de meeste vragen. Een Claude-abonnement (claude.ai) werkt hier niet: je hebt een API-sleutel met tegoed nodig.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Claude Code gevonden? Dan is er niets meer te doen dan testen.
    private var claudeCodeStatus: some View {
        let _ = refreshTick
        let path = ClaudeCodeBrain.executable
        return VStack(alignment: .leading, spacing: 6) {
            if let path {
                Label("Claude Code gevonden: \(path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Nook gebruikt je eigen login. Ben je nog niet ingelogd, typ dan eenmalig `claude` in de terminal. Antwoorden duren een paar tellen langer dan met een API-sleutel.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Claude Code staat niet op deze Mac", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Installeer het met `curl -fsSL https://claude.ai/install.sh | bash` in de terminal, log in met `claude` en klik dan op Zoek opnieuw.")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button("Zoek opnieuw") { ClaudeCodeBrain.resetLocation(); refreshTick += 1; settings.objectWillChange.send() }
                    if let url = settings.provider.keyURL { Link("Meer over Claude Code", destination: url) }
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
            status = fetchedModels.isEmpty ? "Geen modellen gevonden." : "\(fetchedModels.count) modellen gevonden. Kies er een via Kies."
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
                            Label("In gebruik", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Gebruik") { settings.localModel = option.id; testResult = nil }
                        }
                    } else if !option.fits {
                        Text("Te zwaar voor \(EmbeddedModel.memoryGB) GB").font(.caption).foregroundStyle(.orange)
                    } else {
                        Button("Download") { Task { await install(option.id) } }
                            .disabled(installing != nil)
                    }
                }
            }
            Text("Eén keer downloaden (een paar GB), daarna werkt het zonder internet. Deze Mac heeft \(EmbeddedModel.memoryGB) GB geheugen. Het model gaat na anderhalve minuut zonder vraag weer uit het geheugen.")
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
            settings.localModel = id
            status = "\(local.title(for: id)) is klaar en wordt nu gebruikt."
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
                    testResult = (false, "Dit lijkt geen Anthropic-sleutel: die begint met sk-ant-. Ik test hem toch.")
                }
                status = saved.keychainError.map { "Keychain weigerde de sleutel (\($0)). Hij werkt nu alleen tot je Nook afsluit." } ?? "Sleutel bewaard in de Keychain."
            } else {
                settings.saveAPIKey("")
                testResult = nil
                status = "Sleutel verwijderd."
                return
            }
        } else {
            let error = settings.saveProviderKey(keyDraft, for: provider)
            let removed = keyDraft.isEmpty
            keyDraft = ""
            status = error ?? (removed ? "Sleutel verwijderd." : "Sleutel bewaard in de Keychain.")
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

    // MARK: Assistent

    private var assistantSection: some View {
        Group {
            Section("Wat Nook ziet") {
                SettingToggle("Houd al mijn schermen bij", detail: "Nook leest de tekst van al je vensters op al je schermen, op je Mac. Daardoor is een antwoord direct klaar.", isOn: $settings.liveScreen)
                SettingToggle("Gebruik mijn schermen bij elke vraag", detail: "Uit: alleen als je naar iets verwijst (\"dit\", \"hier\", \"die mail\").", isOn: $settings.screenWithEveryQuestion)
                LabeledContent("Nu in beeld") {
                    Text(app.screenContext.windows.isEmpty ? "niets gelezen" : "\(app.screenContext.windows.count) vensters op \(max(1, app.screenContext.displayCount)) \(app.screenContext.displayCount == 1 ? "scherm" : "schermen")")
                        .foregroundStyle(.secondary)
                }
                if !CGPreflightScreenCaptureAccess() {
                    Button("Geef toestemming om je scherm te lezen") { CGRequestScreenCaptureAccess(); refreshTick += 1 }
                }
            }
            Section("Meedenken") {
                SettingToggle("Zoek op het web als dat nodig is", detail: "Voor nieuws, weer, uitslagen, prijzen en openingstijden. Werkt met elk brein.", isOn: $settings.webSearch)
                SettingToggle("Denk mee terwijl ik werk", detail: "Kan Nook iets overnemen of weet hij een slimmere aanpak, dan stelt hij het voor naast de notch. Zeg je vaker nee, dan houdt hij zich in. Stuurt af en toe de tekst van je voorste vensters naar je brein.", isOn: $settings.autoWatch)
                .disabled(settings.useLocal)
                if !app.thinkAlong.mutedApps.isEmpty {
                    LabeledContent("Niet meedenken in") {
                        HStack {
                            Text(app.thinkAlong.mutedApps.values.sorted().joined(separator: ", "))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Button("Wis") { app.thinkAlong.unmuteAll() }
                        }
                    }
                }
                SettingToggle("Kleine dingen meteen doen", detail: "Muziek, volume, een app, een herinnering of een open punt. Afspraken, mail, links, opdrachten en diensten vragen altijd eerst.", isOn: $settings.autoRunSafe)
            }
        }
    }

    // MARK: Koppelingen

    private var connectionsSection: some View {
        Group {
            Section {
                let sources = localSources
                ForEach(sources.indices, id: \.self) { index in
                    localRow(sources[index])
                }
            } header: {
                Text("Op je Mac")
            } footer: {
                Text("Mail en je browser leest Nook alleen als die apps open zijn. macOS vraagt de eerste keer om toestemming.")
            }
            Section("Diensten") {
                CloudConnectorSettings(connectors: app.connectors.sources) { app.connectors.refreshAll() }
            }
            Section("Crypto-portfolio") {
                PortfolioSettings(portfolio: app.portfolio)
            }
        }
    }

    private var localSources: [ContextSource] {
        let ids = ["calendar", "reminders", "mail", "browser", "files", "clipboard"]
        return ids.compactMap { app.connectors.source(id: $0) }
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
                Image(systemName: source.symbol)
                    .foregroundStyle(source.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title)
                    Text(localDetail(source)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func localDetail(_ source: ContextSource) -> String {
        if case .error(let message) = source.status.state { return message }
        switch source.id {
        case "calendar": return app.calendar.hasEventAccess ? (source.status.headline.isEmpty ? "Je afspraken" : source.status.headline) : "Geef toegang bij Privacy en toegang"
        case "reminders": return app.calendar.hasReminderAccess ? (source.status.headline.isEmpty ? "Je open herinneringen" : source.status.headline) : "Geef toegang bij Privacy en toegang"
        case "mail": return "Ongelezen mail en zoeken in je inbox (Mail)"
        case "browser": return "Open tabbladen in Safari, Chrome, Arc, Brave en Edge"
        case "files": return "Recente bestanden en zoeken met Spotlight"
        case "clipboard": return "Wat je net kopieerde. Wachtwoorden worden altijd overgeslagen."
        default: return source.status.detail
        }
    }

    // MARK: Agents

    private var agentsSection: some View {
        Group {
            Section {
                ForEach(AgentKind.allCases) { kind in
                    accountRow(kind)
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Eén klik koppelt alles voor dat account. Staat de agent nog niet op je Mac of ben je niet ingelogd, dan opent Nook Terminal om te installeren en in te loggen. Van elk bestand dat Nook aanpast, komt eerst een backup.")
            }
            Section {
                ForEach(AgentConfigInstaller.Target.allCases) { target in
                    agentRow(target)
                }
            } header: {
                Text("Koppel je agents")
            } footer: {
                Text("Nook laat eerst precies zien wat er verandert en maakt een backup voordat er iets wordt geschreven. Draait Nook niet, dan doen de koppelingen niets.")
            }
            Section("Abonnementen") {
                LabeledContent("Claude") {
                    Text(app.hub.planUsage.map { $0.label } ?? "koppel \"Claude-abonnement in de notch\"").foregroundStyle(.secondary)
                }
                LabeledContent("Codex") {
                    Text(app.codex.snapshot.flatMap { [$0.fiveHourLabel, $0.weeklyLabel].compactMap { $0 }.joined(separator: " · ") } ?? "niet gevonden")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Weekoverzicht") {
                HStack {
                    Button("Bekijk") { app.showWeekRecap() }
                    Button("Wis") { app.recap.clear(); status = "Weekoverzicht gewist." }
                }
            }
        }
    }

    private func accountRow(_ kind: AgentKind) -> some View {
        let _ = refreshTick
        let program = app.history.executables[kind] != nil
        let account = app.history.accounts[kind]
        let linkedAll = kind.targets.allSatisfy { (agentStates[$0] ?? .notInstalled) == .installed }
        let progress = app.agentConnect[kind]
        let complete = program && account != nil && linkedAll
        let detail: String = {
            if let progress, progress.isBusy || !complete { return progress.text }
            if !program { return "Nog niet op deze Mac" }
            guard let account else { return "Nog niet ingelogd" }
            let who = [account.name, account.plan].filter { !$0.isEmpty }.joined(separator: " · ")
            return linkedAll ? who : who + " · nog niet gekoppeld met Nook"
        }()
        return StatusRow(title: kind.name, detail: detail, state: complete ? .done : .todo) {
            if progress?.isBusy == true {
                ProgressView().controlSize(.small)
            } else if !complete {
                Button(!program ? "Installeer en koppel" : (account == nil ? "Log in en koppel" : "Koppel")) { app.connect(kind) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
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
                Button("Koppel…") { prepare(target, install: true) }
                    .controlSize(.small)
            case .outdated:
                Button("Werk bij…") { prepare(target, install: true) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Ontkoppel…") { prepare(target, install: false) }
                    .controlSize(.small)
            case .installed:
                Button("Ontkoppel…") { prepare(target, install: false) }
                    .controlSize(.small)
            case .unreadable:
                EmptyView()
            }
        }
    }

    private func stateText(_ state: AgentConfigInstaller.State, target: AgentConfigInstaller.Target) -> String {
        switch state {
        case .notInstalled: return target.detail
        case .installed: return "Gekoppeld · \(target.displayPath)"
        case .outdated: return "Gekoppeld met een oudere versie: werk bij voor toestemming en vragen in de notch"
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
            let verb = change.install ? "gekoppeld" : "ontkoppeld"
            status = "\(change.target.title) is \(verb)." + (backup.map { " Backup: \($0.lastPathComponent)" } ?? "")
                + (change.install && change.target != .claudeStatusLine ? " Start de agent opnieuw om het te laten werken." : "")
        } catch {
            status = error.localizedDescription
        }
        refreshAgentStates()
    }

    // MARK: Stem en geluid

    private var voiceSection: some View {
        Group {
            Section {
                Toggle("Lees antwoorden voor als ik iets zeg", isOn: $settings.speakAnswers)
                Toggle("Luister naar “Hé Nook”", isOn: $settings.wakeWord)
                    .disabled(!WakeWordService.supported)
            } header: {
                Text("Praten")
            } footer: {
                Text(WakeWordService.supported
                     ? "Met het wekwoord luistert Nook steeds mee, maar de herkenning gebeurt alleen op je Mac en er wordt niets bewaard. Je ziet dan het oranje microfoonlampje."
                     : "Deze Mac kan Nederlandse spraak niet zelf herkennen, dus het wekwoord kan niet aan (er gaat nooit geluid naar buiten). Met ⌥ spatie praat je altijd.")
            }
            Section {
                Toggle("Geluid als een agent op je wacht of klaar is", isOn: $settings.sounds)
                LabeledContent("Eigen geluiden") {
                    Button("Open map") { NookSound.openFolder() }
                }
            } header: {
                Text("Geluiden")
            } footer: {
                Text("Zet attention, done of error (.wav, .mp3, .aiff, .m4a) in de map om een eigen geluid te gebruiken.")
            }
        }
    }

    // MARK: Privacy en toegang

    private var privacySection: some View {
        Group {
            Section {
                permissionRow("Scherm lezen", detail: "Alle vensters op al je schermen", granted: CGPreflightScreenCaptureAccess()) {
                    CGRequestScreenCaptureAccess()
                    refreshTick += 1
                }
                permissionRow("Agenda", detail: "Afspraken lezen en maken", granted: app.calendar.hasEventAccess) {
                    Task { await app.calendar.requestEvents(); refreshTick += 1; app.connectors.refreshAll() }
                }
                permissionRow("Herinneringen", detail: "Open taken lezen en maken", granted: app.calendar.hasReminderAccess) {
                    Task { await app.calendar.requestReminders(); refreshTick += 1; app.connectors.refreshAll() }
                }
                permissionRow("Microfoon en spraak", detail: "Praten met Nook", granted: VoiceService.permissionsGranted) {
                    Task { _ = await app.voice.requestPermissions(); refreshTick += 1 }
                }
            } header: {
                Text("Machtigingen")
            } footer: {
                Text("Mail, je browser, Spotify en Muziek vraagt macOS zelf om toestemming zodra Nook ze voor het eerst gebruikt. Na een nieuwe build met een ad-hoc handtekening kan macOS het opnieuw vragen.")
            }
            .id(refreshTick)
            Section("Wat je Mac verlaat") {
                promise("eye.slash", "Schermbeelden nooit", "Alleen herkende tekst, en alleen als je iets vraagt.")
                promise("key", "Wachtwoorden blijven buiten beeld", "Wachtwoordmanagers en verborgen klembord-inhoud worden nooit gelezen.")
                promise("hand.raised", "Niets zonder jouw klik", "Nook verstuurt nooit zelf mail.")
                promise("lock", "Sleutels in je Keychain", "Alles wat Nook doet staat in een logboek op je Mac.")
                LabeledContent("Schermtekst") {
                    Button("Vergeet wat Nook nu zag") {
                        app.screenContext.clear()
                        status = "Schermtekst vergeten."
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

    private func permissionRow(_ title: String, detail: String, granted: Bool, request: @escaping () -> Void) -> some View {
        StatusRow(title: title, detail: detail, state: granted ? .done : .todo) {
            if granted {
                Text("Aan").foregroundStyle(.secondary)
            } else {
                Button("Toestaan", action: request)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}

/// Wat er in het instellingenbestand van een agent verandert, voordat het geschreven wordt.
private struct ConfigPreview: View {
    let change: AgentConfigInstaller.Change
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(change.install ? "\(change.target.title) koppelen" : "\(change.target.title) ontkoppelen")
                .font(.headline)
            Text("Dit verandert in \(change.target.displayPath). Je eigen instellingen blijven staan; er komt eerst een backup naast het bestand.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if change.preview.isEmpty {
                        Text("Er verandert niets.").foregroundStyle(.secondary)
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
                Button("Annuleer", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(change.install ? "Koppel" : "Ontkoppel", action: onConfirm)
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

// MARK: Bouwstenen

/// Kop van een onderdeel: Nook zelf bij het overzicht, anders het symbool van het onderdeel in één kleur.
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

/// Eén rij met een status links, naam en uitleg, en rechts de actie. Overal hetzelfde, zodat je in één blik ziet wat klaar is.
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

/// Aan/uit met een korte uitleg eronder.
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

/// Een toets, zoals op het toetsenbord.
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

