import SwiftUI
import AppKit
import AVFoundation
import Speech
import EventKit

/// Settings sections, in the order of the sidebar.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, display, brain, assistant, autocomplete, memory, connections, mcp, agents, privacy

    /// The sidebar groups: what belongs together sits together.
    enum Group: String, CaseIterable, Identifiable {
        case nook, intelligence, connect, security

        var id: String { rawValue }

        var title: String { tr("settings.group.\(rawValue)") }

        var sections: [SettingsSection] {
            switch self {
            case .nook: return [.general, .display]
            case .intelligence: return [.brain, .assistant, .autocomplete, .memory]
            case .connect: return [.connections, .mcp, .agents]
            case .security: return [.privacy]
            }
        }
    }

    var id: String { rawValue }

    var title: String { tr("settings.section.\(rawValue)") }

    var subtitle: String { tr("settings.section.\(rawValue).sub") }

    var symbol: String { tileSymbol }
}

/// Settings: sidebar navigation with sections. A one-sentence summary is displayed at the top of each view.
struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var settings = AppSettings.shared

    @State var keyDraft = ""
    @State var status = ""
    @State var refreshTick = 0
    @State var connectionSearch = ""
    /// The category chip on Connected services; nil shows all of them.
    @State var connectionCategory: ServiceCategory?
    @ObservedObject var local = EmbeddedModel.shared
    @State var installing: String?
    @State var installFraction: Double = 0
    @State var testing = false
    @State var testResult: (ok: Bool, message: String)?
    @State var pendingChange: AgentConfigInstaller.Change?
    @State var agentTab: AgentSettingsTab = .link
    @State var agentStates: [AgentConfigInstaller.Target: AgentConfigInstaller.State] = [:]
    @State var fetchedModels: [String] = []
    @State var fetchingModels = false
    @State var recommendations: [ModelAdvisor.Recommendation] = []

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { Optional(app.settingsSection) },
                set: { if let value = $0 { app.settingsSection = value } }
            )) {
                ForEach(SettingsSection.Group.allCases) { group in
                    Section(group.title) {
                        ForEach(group.sections) { section in
                            Label {
                                Text(section.title)
                            } icon: {
                                SettingsTile(section, size: 20)
                            }
                            .badge(badge(for: section))
                            .tag(section)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(NookTheme.graphite)
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 250)
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
            .scrollContentBackground(.hidden)
            .background(Color(hex: 0x0B0B0E))
            .id("\(app.settingsSection.rawValue)-\(settings.appLanguage.rawValue)-\(settings.accentHex)")
        }
        .tint(NookTheme.iris)
        .preferredColorScheme(.dark)
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
        let broken = app.connectors.sources.filter { if case .error = $0.status.state { return $0.isActive }; return false }
        switch section {
        case .general: return checklist.filter { !$0.done }.count
        case .connections: return broken.filter { !($0 is MCPConnector) }.count
        case .mcp: return broken.filter { $0 is MCPConnector }.count
        case .autocomplete: return AutocompleteController.shared.needsAttention ? 1 : 0
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
        case .display: displaySection
        case .brain: brainSection
        case .assistant: assistantSection
        case .autocomplete: AutocompleteSettingsSection()
        case .memory: MemorySettingsSection()
        case .connections: connectionsSection
        case .mcp: MCPSettingsSection()
        case .agents: agentsSection
        case .privacy: privacySection
        }
    }
}
