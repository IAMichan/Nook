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
    @EnvironmentObject var app: AppModel
    @ObservedObject var settings = AppSettings.shared

    @State var keyDraft = ""
    @State var status = ""
    @State var refreshTick = 0
    @State var connectionSearch = ""
    @ObservedObject var local = EmbeddedModel.shared
    @State var installing: String?
    @State var installFraction: Double = 0
    @State var testing = false
    @State var testResult: (ok: Bool, message: String)?
    @State var pendingChange: AgentConfigInstaller.Change?
    @State var agentStates: [AgentConfigInstaller.Target: AgentConfigInstaller.State] = [:]
    @State var fetchedModels: [String] = []
    @State var fetchingModels = false
    @State var recommendations: [ModelAdvisor.Recommendation] = []

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
    func badge(for section: SettingsSection) -> Int {
        switch section {
        case .general: return checklist.filter { !$0.done }.count
        case .connections: return app.connectors.sources.filter { if case .error = $0.status.state { return true }; return false }.count
        default: return 0
        }
    }

    /// Nook looks satisfied when all checklist items are configured, otherwise calm.
    var headerMood: NookMood {
        checklist.allSatisfy(\.done) ? .done : .rest
    }

    @ViewBuilder
    func detail(for section: SettingsSection) -> some View {
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
}
