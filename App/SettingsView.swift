import SwiftUI
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
    @State private var ollamaRunning: Bool?
    @State private var installed: [String] = []
    @State private var pulling: String?
    @State private var pullStatus = ""
    @State private var pullFraction: Double?
    @State private var customModel = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?

    var body: some View {
        Form {
            brainSection
            watchSection
            permissionsSection
            agentsSection
            if !status.isEmpty {
                Section { Text(status).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .onAppear {
            refreshTick += 1
            Task { await refreshOllama() }
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
            .onChange(of: settings.useLocal) { _, _ in
                testResult = nil
                Task { await refreshOllama() }
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
            switch ollamaRunning {
            case .none:
                HStack { ProgressView().controlSize(.small); Text("Ollama zoeken…") }
            case .some(false):
                Label("Ollama draait nog niet", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Gratis modellen draaien via Ollama, een kleine app die ze op je Mac uitvoert. Installeer hem, open hem één keer, en kom hier terug.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Download Ollama") { NSWorkspace.shared.open(LocalModelService.downloadPage) }
                    Button("Opnieuw controleren") { Task { await refreshOllama() } }
                }
                Text("Of via Terminal: brew install ollama && brew services start ollama")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .some(true):
                Label("Ollama draait", systemImage: "checkmark.circle.fill").foregroundStyle(.green)

                if !installed.isEmpty {
                    Picker("Gebruik model", selection: $settings.localModel) {
                        if !installed.contains(settings.localModel) { Text("Kies…").tag(settings.localModel) }
                        ForEach(installed, id: \.self) { Text($0).tag($0) }
                    }
                }

                ForEach(LocalModelService.suggestions) { suggestion in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                            Text(suggestion.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if installed.contains(suggestion.id) {
                            Image(systemName: "checkmark").foregroundStyle(.green)
                        } else {
                            Button("Installeer") { Task { await install(suggestion.id) } }
                                .disabled(pulling != nil)
                        }
                    }
                }

                HStack {
                    TextField("Ander model, bijv. mistral-small", text: $customModel)
                        .onSubmit { Task { await install(customModel) } }
                    Button("Installeer") { Task { await install(customModel) } }
                        .disabled(customModel.trimmingCharacters(in: .whitespaces).isEmpty || pulling != nil)
                }

                if let pulling {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(pulling) downloaden… \(pullStatus)").font(.caption)
                        if let pullFraction { ProgressView(value: pullFraction) } else { ProgressView() }
                    }
                }
                Text("Gratis en privé: alles draait op je eigen Mac en niets gaat naar het internet. Het model moet tools kunnen aanroepen; kleine modellen zijn minder slim dan Claude. Zodra je een model kiest, gebruikt Nook dat in plaats van een API-sleutel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func refreshOllama() async {
        guard settings.useLocal else { return }
        do {
            installed = try await LocalModelService.installedModels()
            ollamaRunning = true
            if settings.localModel.isEmpty, let first = installed.first { settings.localModel = first }
        } catch {
            ollamaRunning = false
        }
    }

    private func install(_ raw: String) async {
        let model = raw.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty, pulling == nil else { return }
        pulling = model
        pullStatus = ""
        pullFraction = nil
        testResult = nil
        defer { pulling = nil }
        do {
            try await LocalModelService.pull(model) { status, fraction in
                Task { @MainActor in
                    pullStatus = status
                    pullFraction = fraction
                }
            }
            await refreshOllama()
            settings.localModel = model
            customModel = ""
            status = "\(model) is geïnstalleerd en wordt nu gebruikt."
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
            Button("Installeer hook-script") {
                do {
                    let url = try HookScript.install()
                    status = "Script staat in \(url.path)"
                } catch {
                    status = "Installeren mislukte: \(error.localizedDescription)"
                }
            }
            Button("Kopieer Claude Code-configuratie") {
                _ = try? HookScript.install()
                HookScript.copyToPasteboard(HookScript.claudeCodeConfig())
                status = "Gekopieerd. Voeg het samen met het \"hooks\"-deel van ~/.claude/settings.json."
            }
            Button("Kopieer Codex-configuratie") {
                _ = try? HookScript.install()
                HookScript.copyToPasteboard(HookScript.codexConfig())
                status = "Gekopieerd. Zet de regel in ~/.codex/config.toml."
            }
            Text("Nook past de instellingen van je agents nooit zelf aan. Bash-commando's die niet duidelijk onschuldig zijn, komen als vraag in de notch; de rest loopt zoals je agent het zelf al deed. Als Nook niet draait, doen de hooks niets.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
