import SwiftUI
import AppKit
import AVFoundation
import Speech
import EventKit

/// Settings sections, in the order of the sidebar. Each subject lives in exactly one place.
enum SettingsSection: String, CaseIterable, Identifiable {
    case start, general, appearance, shortcuts, notifications, brain, assistant, memory, autocomplete, dictation, connections, agents,
         usage, workspace, devices, privacy

    /// The sidebar groups: what belongs together sits together.
    enum Group: String, CaseIterable, Identifiable {
        case nook, intelligence, input, connect, security

        var id: String { rawValue }

        var title: String { tr("settings.group.\(rawValue)") }

        var sections: [SettingsSection] {
            switch self {
            case .nook: return [.start, .general, .appearance, .shortcuts, .notifications]
            case .intelligence: return [.brain, .assistant, .memory]
            case .input: return [.autocomplete, .dictation]
            case .connect: return [.connections, .agents, .usage, .workspace, .devices]
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
    @State var refreshTick = 0
    @State var connectionSearch = ""
    /// The category chip under the connections search field; nil is All.
    @State var connectionCategory: ServiceCategory?
    /// The Add MCP sheet, opened from a preset card or the custom card.
    @State var mcpAdd: MCPAddRequest?
    @ObservedObject var local = EmbeddedModel.shared
    @ObservedObject var permissions = PermissionMonitor.shared
    @ObservedObject var energy = EnergyMonitor.shared
    @State var installing: String?
    @State var installFraction: Double = 0
    @State var testing = false
    @State var testResult: (ok: Bool, message: String)?
    @State var pendingChange: AgentConfigInstaller.Change?
    @State var agentStates: [AgentConfigInstaller.Target: AgentConfigInstaller.State] = [:]
    @State var fetchedModels: [String] = []
    @State var fetchingModels = false
    @State var recommendations: [ModelAdvisor.Recommendation] = []
    /// What is typed in the search field above the sidebar.
    @State var searchQuery = ""
    /// The mood the large preview under Appearance shows.
    @State var lookPreviewMood: NookMood = .rest
    @ObservedObject var flowStore = FlowStore.shared
    @ObservedObject var mcpStore = MCPServerStore.shared
    @ObservedObject var mcpSignIn = MCPSignIn.shared

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { Optional(app.settingsSection) },
                set: { value in
                    // The List writes its selection while SwiftUI is still updating the view; publish on the next turn.
                    guard let value, value != app.settingsSection else { return }
                    DispatchQueue.main.async { app.settingsSection = value }
                }
            )) {
                if searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
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
                } else {
                    searchResults
                }
            }
            .searchable(text: $searchQuery, placement: .sidebar, prompt: Text(tr("settings.search.prompt")))
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
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(NookTheme.canvas)
            .id("\(app.settingsSection.rawValue)-\(settings.appLanguage.rawValue)-\(settings.accentHex)")
        }
        .tint(NookTheme.iris)
        .preferredColorScheme(.dark)
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            refreshTick += 1
            refreshAgentStates()
            app.history.refresh()
        }
        .onChange(of: app.settingsSection) { _, _ in
            refreshTick += 1
            if app.settingsSection == .agents || app.settingsSection == .usage {
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
        case .start: return checklist.filter { !$0.done }.count
        case .connections: return broken.count
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
        case .start: startSection
        case .general: generalSection
        case .appearance: appearanceSection
        case .shortcuts: shortcutsSection
        case .notifications: notificationsSection
        case .brain: brainSection
        case .assistant: assistantSection
        case .memory: MemorySettingsSection()
        case .autocomplete: AutocompleteSettingsSection()
        case .dictation: dictationSection
        case .connections: connectionsSection
        case .agents: agentsSection
        case .usage: usageSection
        case .workspace: workspaceSection
        case .devices: devicesSection
        case .privacy: privacySection
        }
    }

    /// The search results in the sidebar: every setting by its own name, with the section it lives in.
    private var searchResults: some View {
        let hits = SettingsSearch.results(searchQuery)
        return Section(tr("settings.search.results")) {
            if hits.isEmpty {
                Text(tr("settings.search.none"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(hits) { hit in
                Button {
                    app.settingsSection = hit.section
                    searchQuery = ""
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hit.title).lineLimit(1)
                            Text(hit.section.title).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        SettingsTile(hit.section, size: 20)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
