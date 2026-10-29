import SwiftUI
import AppKit
import AVFoundation
import Speech
import EventKit

/// Settings pages, in the order of the sidebar. Each subject lives in exactly one place, and everything you link or sign
/// in to (chat apps, online services, your own servers, the iPhone) lives on one page: `connections`.
enum SettingsSection: String, CaseIterable, Identifiable {
    case start, general, appearance, shortcuts, notifications, brain, assistant, autocomplete, connections, agents, workspace,
         privacy

    /// The sidebar groups: four, so the sidebar reads at a glance.
    enum Group: String, CaseIterable, Identifiable {
        case nook, intelligence, connect, security

        var id: String { rawValue }

        var title: String { tr("settings.group.\(rawValue)") }

        var sections: [SettingsSection] {
            switch self {
            case .nook: return [.start, .general, .appearance, .shortcuts, .notifications]
            // The AI Nook thinks with, what it does with it (and what it remembers), and how you type and talk to it.
            case .intelligence: return [.brain, .assistant, .autocomplete]
            // Everything Nook is linked to, then the coding agents and where their sessions run.
            case .connect: return [.connections, .agents, .workspace]
            case .security: return [.privacy]
            }
        }
    }

    var id: String { rawValue }

    var title: String { tr("settings.section.\(rawValue)") }

    var subtitle: String { tr("settings.section.\(rawValue).sub") }

    var symbol: String { tileSymbol }

    /// What a whole page is about and how it treats your data, behind the ⓘ next to its title; nil for most pages.
    var info: String? {
        switch self {
        case .connections: return tr("connect.intro")
        case .assistant: return tr("memory.settings.privacyFooter")
        default: return nil
        }
    }
}

/// Settings: sidebar navigation with sections. A one-sentence summary is displayed at the top of each view.
struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var settings = AppSettings.shared

    @State var keyDraft = ""
    @State var refreshTick = 0
    @ObservedObject var local = EmbeddedModel.shared
    @ObservedObject var permissions = PermissionMonitor.shared
    @ObservedObject var energy = EnergyMonitor.shared
    @State var installing: String?
    @State var installFraction: Double = 0
    @State var usingRecommendation = false
    @State var testing = false
    @State var testResult: (ok: Bool, message: String)?
    @State var pendingChange: AgentConfigInstaller.Change?
    @State var agentStates: [AgentConfigInstaller.Target: AgentConfigInstaller.State] = [:]
    @State var fetchedModels: [String] = []
    @State var fetchingModels = false
    @State var recommendations: [ModelAdvisor.Recommendation] = []
    /// What is typed in the search field above the sidebar.
    @State var searchQuery = ""
    /// The part of Typing & dictation on screen: completing (0) or dictation and voice (1).
    @AppStorage("settings.typingPart") var typingPart = 0
    /// The mood the large preview under Appearance shows.
    @State var lookPreviewMood: NookMood = .rest
    @ObservedObject var flowStore = FlowStore.shared
    @ObservedObject var doubleTap = DoubleTap.shared

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
            .background(NookTheme.surface)
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
            // Every row reads at the panel's body size; captions and notes set their own smaller style.
            .font(NookTheme.TextStyle.body)
            .scrollContentBackground(.hidden)
            .background(NookTheme.canvas)
            // Rebuilt for a new page or language. Not for the accent: Appearance is drawn in this view's own body and
            // `WardrobeSettingsSection` observes the settings, so both redraw in the new color without the Form being
            // rebuilt (which would scroll back to the top on every swatch click or color picker drag).
            .id("\(app.settingsSection.rawValue)-\(settings.appLanguage.rawValue)")
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
        case .start: return attention.count
        case .connections: return ConnectionProblems.current(app).count
        case .autocomplete: return AutocompleteController.shared.needsAttention ? 1 : 0
        default: return 0
        }
    }

    /// Nook looks satisfied when nothing needs you, otherwise calm.
    var headerMood: NookMood {
        attention.isEmpty ? .done : .rest
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
        // What Nook does, what it remembers of it, and Nook as a friend, on one page.
        case .assistant:
            assistantSection
            MemorySettingsSection()
            buddySection
        // Everything you type and say, in two parts: completing as you type, and dictating and talking to Nook.
        case .autocomplete:
            Section {
                Picker("", selection: $typingPart) {
                    Text(tr("typing.part.complete")).tag(0)
                    Text(tr("typing.part.dictate")).tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .listRowBackground(Color.clear)
            if typingPart == 0 {
                AutocompleteSettingsSection()
            } else {
                dictationSection
            }
        case .connections: ConnectionsPage()
        case .agents: agentsSection
        case .workspace: workspaceSection
        case .privacy: privacySection
        }
    }

    /// The search results in the sidebar: every setting by its own name, with the section it lives in.
    private var searchResults: some View {
        let hits = SettingsSearch.results(searchQuery)
        return Section(tr("settings.search.results")) {
            if hits.isEmpty {
                Text(tr("settings.search.none"))
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textSecondary)
            }
            ForEach(hits) { hit in
                Button {
                    app.settingsSection = hit.section
                    searchQuery = ""
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hit.title).lineLimit(1)
                            Text(hit.section.title).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
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
