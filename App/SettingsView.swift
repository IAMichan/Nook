import SwiftUI
import AppKit
import AVFoundation
import Speech
import EventKit

/// Instellingen: sleutel, meekijken, machtigingen en het koppelen van agents.
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

    var body: some View {
        Form {
            brainSection
            agentsSection
            notchSection
            voiceSection
            watchSection
            permissionsSection
            if !status.isEmpty {
                Section { Text(status).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 720)
        .onAppear {
            refreshTick += 1
            refreshAgentStates()
        }
        .sheet(item: $pendingChange) { change in
            ConfigPreview(change: change) {
                pendingChange = nil
            } onConfirm: {
                write(change)
            }
        }
    }

    // MARK: Brein

    private var brainSection: some View {
        Section("Brein") {
            Picker("Nook denkt met", selection: $settings.useLocal) {
                Text("Claude (API-sleutel)").tag(false)
                Text("Gratis model op je Mac").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: settings.useLocal) { _, _ in testResult = nil }

            Picker("Taal van antwoorden", selection: $settings.language) {
                ForEach(AppSettings.languages, id: \.code) { Text($0.name).tag($0.code) }
            }

            if settings.useLocal { localFields } else { claudeFields }

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

    private var claudeFields: some View {
        Group {
            HStack {
                SecureField("Anthropic API-sleutel (sk-ant-…)", text: $keyDraft)
                    .onSubmit(saveKey)
                Button("Bewaar en test", action: saveKey)
                    .disabled(keyDraft.isEmpty && !settings.hasAPIKey)
            }
            if let masked = settings.maskedKey {
                Label("Opgeslagen sleutel: \(masked)", systemImage: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Zonder sleutel kan Nook niet nadenken. Maak er een op console.anthropic.com › API keys. De sleutel blijft in je Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                TextField("Model", text: $settings.model)
                Menu("Kies") {
                    ForEach(["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"], id: \.self) { id in
                        Button(id) { settings.model = id }
                    }
                }
                .fixedSize()
            }
            Text("Wat je aan Nook vraagt, plus een korte samenvatting van je agenda en open punten, gaat naar de Claude API. Een Claude-abonnement (claude.ai) werkt hier niet: je hebt een API-sleutel met tegoed nodig.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var localFields: some View {
        Group {
            Text("Een gratis model dat in Nook zelf draait: je hoeft niets anders te installeren. Het wordt één keer gedownload (een paar GB) en werkt daarna zonder internet. Niets van wat je vraagt verlaat je Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)

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
            Text("Deze Mac heeft \(EmbeddedModel.memoryGB) GB geheugen. Het model gaat na anderhalve minuut zonder vraag weer uit het geheugen, en meekijken op de achtergrond staat uit zolang je een lokaal model gebruikt. Kleine modellen zijn minder slim dan Claude: een plan kan vaker net fout zijn, en de eerste vraag na het opstarten duurt even omdat het model dan geladen wordt. Zodra je een model gebruikt, heeft Nook geen API-sleutel nodig.")
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
        if !keyDraft.isEmpty {
            let saved = settings.saveAPIKey(keyDraft)
            keyDraft = ""
            if !saved.looksValid {
                testResult = (false, "Dit lijkt geen Anthropic-sleutel: die begint met sk-ant-. Ik test hem toch.")
            }
            if let keychainError = saved.keychainError {
                status = "Keychain weigerde de sleutel (\(keychainError)). Hij werkt nu alleen tot je Nook afsluit."
            } else {
                status = "Sleutel bewaard in de Keychain."
            }
        } else {
            settings.saveAPIKey("")
            testResult = nil
            status = "Sleutel verwijderd."
            return
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

    // MARK: Meekijken

    private var watchSection: some View {
        Section("Meekijken") {
            Toggle("Af en toe zelf meekijken met het scherm", isOn: $settings.autoWatch)
                .disabled(settings.useLocal)
            Text("Standaard uit. Aan: Nook leest elke anderhalve minuut de tekst van het voorste venster (op je Mac, niet het beeld) en stuurt alleen die tekst naar het brein om te zien of er iets te doen is. Wachtwoordmanagers en Nook zelf worden overgeslagen. Handmatig meekijken kan altijd met ⌥⌘N.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Machtigingen

    private var permissionsSection: some View {
        Section("Machtigingen") {
            permissionRow("Agenda", granted: app.calendar.hasEventAccess) {
                Task { await app.calendar.requestEvents(); refreshTick += 1 }
            }
            permissionRow("Herinneringen", granted: app.calendar.hasReminderAccess) {
                Task { await app.calendar.requestReminders(); refreshTick += 1 }
            }
            permissionRow("Microfoon en spraak", granted: VoiceService.permissionsGranted) {
                Task { _ = await app.voice.requestPermissions(); refreshTick += 1 }
            }
            permissionRow("Scherm lezen", granted: CGPreflightScreenCaptureAccess()) {
                CGRequestScreenCaptureAccess()
                refreshTick += 1
            }
            Text("Spotify en Muziek vraagt macOS zelf om toestemming zodra er muziek speelt. Na elke nieuwe build met een ad-hoc handtekening kan macOS de machtigingen opnieuw vragen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .id(refreshTick)
    }

    private func permissionRow(_ title: String, granted: Bool, request: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? Color.green : Color.secondary)
            Text(title)
            Spacer()
            if !granted {
                Button("Toestaan", action: request)
            }
        }
    }

    // MARK: Agents

    private var agentsSection: some View {
        Section("Agents") {
            ForEach(AgentConfigInstaller.Target.allCases) { target in
                agentRow(target)
            }
            Text("Nook laat eerst precies zien wat er in het instellingenbestand verandert en maakt een backup voordat er iets wordt geschreven. Toestemming vraagt Nook alleen als je agent het jou zelf ook zou vragen; antwoord je in de terminal, dan verdwijnt de vraag uit de notch. Als Nook niet draait, doen de hooks niets.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Weekoverzicht wissen") { app.recap.clear(); status = "Weekoverzicht gewist." }
                .font(.caption)
        }
    }

    private func agentRow(_ target: AgentConfigInstaller.Target) -> some View {
        let state = agentStates[target] ?? .notInstalled
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.title)
                Text(stateText(state, target: target))
                    .font(.caption)
                    .foregroundStyle(stateColor(state))
            }
            Spacer()
            switch state {
            case .notInstalled:
                Button("Koppel…") { prepare(target, install: true) }
            case .outdated:
                Button("Werk bij…") { prepare(target, install: true) }
                Button("Ontkoppel…") { prepare(target, install: false) }
            case .installed:
                Button("Ontkoppel…") { prepare(target, install: false) }
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

    private func stateColor(_ state: AgentConfigInstaller.State) -> Color {
        switch state {
        case .installed: return .green
        case .outdated: return .orange
        case .unreadable: return .red
        case .notInstalled: return .secondary
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

    // MARK: Notch

    private var notchSection: some View {
        Section("Notch") {
            Picker("Scherm", selection: $settings.screenChoice) {
                Text("Automatisch (met notch)").tag("auto")
                Text("Hoofdscherm").tag("main")
                Text("Volgt je muis").tag("mouse")
                ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            Toggle("Verberg Nook in rust", isOn: $settings.hideWhenIdle)
            Toggle("Geluid als een agent op je wacht of klaar is", isOn: $settings.sounds)
            Text("Verborgen zie je in rust alleen de notch; wijs ernaar om Nook te openen. Zonder notch blijft er een dun randje bovenaan het scherm.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Stem

    private var voiceSection: some View {
        Section("Stem") {
            Toggle("Antwoorden voorlezen als ik iets zeg", isOn: $settings.speakAnswers)
            Toggle("Luister naar “Hé Nook”", isOn: $settings.wakeWord)
                .disabled(!WakeWordService.supported)
            Text(WakeWordService.supported
                 ? "Met het wekwoord luistert Nook steeds mee, maar de herkenning gebeurt alleen op je Mac en er wordt niets bewaard. Je ziet dan het oranje microfoonlampje. Het kost wat batterij."
                 : "Deze Mac kan Nederlandse spraak niet zelf herkennen, dus het wekwoord kan niet aan (er gaat nooit geluid naar buiten). Met ⌥ spatie praat je altijd.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
