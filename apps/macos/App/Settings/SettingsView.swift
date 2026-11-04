import SwiftUI
import AppKit
import AVFoundation
import Speech
import EventKit

/// Settings pages, in the order of the sidebar. Each subject lives in exactly one place and each page holds one subject,
/// short enough to take in at once: a page that grew past a few groups is split into pages of its own or into tabs
/// (`tabs`), and a list that grows with your data can be searched. A page whose main step is adding something (a chat
/// app, a connection, a machine) has that button in its header (`headerAction`).
enum SettingsSection: String, CaseIterable, Identifiable {
    case start, general, notch, appearance, notifications, sound, shortcuts,
         brain, assistant, memory,
         autocomplete, dictation,
         chats, connections, iphone,
         agents, sessions, machines, automation, pullRequests, usage,
         privacy

    /// The sidebar groups, each a handful of pages.
    enum Group: String, CaseIterable, Identifiable {
        case nook, intelligence, typing, connect, agents, privacy

        var id: String { rawValue }

        var title: String { tr("settings.group.\(rawValue)") }

        var sections: [SettingsSection] {
            switch self {
            // Nook itself: how it behaves, where and how it shows, notifies and sounds, and its keys.
            case .nook: return [.start, .general, .notch, .appearance, .notifications, .sound, .shortcuts]
            // The AI Nook thinks with, what it does with it, and what it remembers.
            case .intelligence: return [.brain, .assistant, .memory]
            // Completing what you type, and dictating.
            case .typing: return [.autocomplete, .dictation]
            // Everything Nook is linked to: chat apps, online services and the Mac's own apps, the iPhone.
            case .connect: return [.chats, .connections, .iphone]
            // The coding agents, how their sessions start and where they run, what runs by itself, and what they used.
            case .agents: return [.agents, .sessions, .machines, .automation, .pullRequests, .usage]
            case .privacy: return [.privacy]
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
        case .connections, .chats: return tr("connect.intro")
        case .memory: return tr("memory.settings.privacyFooter")
        default: return nil
        }
    }

    /// The page's tabs (their names), for a page with more than one part; empty for a page that is one part.
    var tabs: [String] {
        let names: [String]
        switch self {
        case .notifications: names = ["how", "apps"]
        case .sessions: names = ["new", "openIn", "behavior", "tidy"]
        case .privacy: names = ["level", "access", "local", "log"]
        default: names = []
        }
        return names.map { tr("settings.tab.\(rawValue).\($0)") }
    }

    /// The page an `openConnections` target belongs on: chat apps on their own page, everything else with the services.
    static func page(for target: ConnectionsRoute.Target?) -> SettingsSection {
        switch target {
        case .chat, .add(.chats): return .chats
        default: return .connections
        }
    }
}

/// The button in a page's header that does the page's main step (link a chat app, add a connection, add a machine):
/// always in sight, however long the page. The page that owns the step listens and opens its sheet.
@MainActor
final class SettingsPageAction: ObservableObject {
    static let shared = SettingsPageAction()
    /// The page whose main step was asked for; the page clears it once it acted.
    @Published var requested: SettingsSection?

    /// The header button of `section`, if it has one: its title and symbol.
    static func button(for section: SettingsSection) -> (title: String, symbol: String)? {
        switch section {
        case .chats: return (tr("hub.chats.add"), "plus")
        case .connections: return (tr("hub.add"), "plus")
        case .machines: return (tr("remote.add"), "plus")
        default: return nil
        }
    }
}

/// Settings: sidebar navigation with sections. A one-sentence summary is displayed at the top of each view.
struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var settings = AppSettings.shared

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
    /// The searchable list of the service's models is open.
    @State var choosingModel = false
    @State var fetchingModels = false
    @State var recommendations: [ModelAdvisor.Recommendation] = []
    /// The mood the large preview under Appearance shows.
    @State var lookPreviewMood: NookMood = .rest
    @ObservedObject var openRouter = OpenRouterSignIn.shared
    /// Picks up a key copied on a service's own page when you come back to Nook.
    @StateObject var keyCatcher = ClipboardKeyCatcher()
    @ObservedObject var doubleTap = DoubleTap.shared
    @ObservedObject var workspace = WorkspaceSettings.shared
    /// What is typed above the sources under Privacy › Only on this Mac.
    @State var sourceQuery = ""

    var body: some View {
        // Once per redraw: both read every linked source and chat app, and the sidebar, header and Overview all use them.
        let problems = ConnectionProblems.current(app)
        let needs = attention(problems: problems)
        let section = app.settingsSection
        let tab = app.settingsTab(section)
        NavigationSplitView {
            SettingsSidebar(badges: [
                .start: needs.count,
                .chats: problems.filter(\.isChat).count,
                .connections: problems.filter { !$0.isChat }.count,
                .autocomplete: AutocompleteController.shared.needsAttention ? 1 : 0
            ])
        } detail: {
            Form {
                Section {
                    // Nook looks satisfied when nothing needs you, otherwise calm.
                    SettingsHeader(section: section, mood: needs.isEmpty ? .done : .rest)
                    // A page in parts shows one part at a time: never one long page.
                    if !section.tabs.isEmpty {
                        Picker("", selection: Binding(get: { tab }, set: { app.setSettingsTab($0, for: section) })) {
                            ForEach(Array(section.tabs.enumerated()), id: \.offset) { index, name in
                                Text(name).tag(index)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(.bottom, NookTheme.Spacing.sm)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 0, trailing: 0))
                detail(for: section, tab: tab, attention: needs, problems: problems.filter { !$0.isChat }.count)
            }
            .formStyle(.grouped)
            // Every row reads at the panel's body size; captions and notes set their own smaller style.
            .font(NookTheme.TextStyle.body)
            .scrollContentBackground(.hidden)
            .background(NookTheme.canvas)
            // Rebuilt for a new page or language. Not for the accent: Appearance is drawn in this view's own body, so it
            // redraws in the new color without the Form being rebuilt (which would scroll back to the top on every swatch click or color picker drag).
            .id("\(section.rawValue)-\(tab)-\(settings.appLanguage.rawValue)")
        }
        .tint(NookTheme.iris)
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

    /// `attention` and `problems` are what the body worked out once for this redraw.
    @ViewBuilder
    func detail(for section: SettingsSection, tab: Int, attention: [AttentionItem], problems: Int) -> some View {
        switch section {
        case .start: startSection(attention: attention, problems: problems)
        case .general: generalSection
        case .notch: notchSection
        case .appearance: appearanceSection
        case .shortcuts: shortcutsSection
        case .notifications: NoticeRulesSettings(settings: settings, thinkAlong: app.thinkAlong, part: tab == 0 ? .how : .apps)
        case .sound: soundSection
        case .brain: brainSection
        case .assistant: assistantSection
        case .memory: MemorySettingsSection()
        // Completing as you type and dictating are pages of their own, so a page never holds tabs within tabs.
        case .autocomplete: AutocompleteSettingsSection()
        case .dictation: FlowSettingsSection()
        case .chats: ConnectionsPage(part: .chats)
        case .connections: ConnectionsPage(part: .services)
        case .iphone: CompanionSettingsRows()
        case .agents: agentsSection
        case .sessions: WorkspaceSettingsSection(part: .sessions(tab))
        case .machines: RemoteMachinesSection()
        case .automation: WorkspaceSettingsSection(part: .automation)
        case .pullRequests: WatchedPullRequestsSection()
        case .usage: usageSettingsSection
        case .privacy: privacySection(tab: tab)
        }
    }
}

/// The sidebar with its search field. A view of its own, so a keystroke in the search redraws only the sidebar, not
/// every page and count of Settings.
private struct SettingsSidebar: View {
    @EnvironmentObject var app: AppModel
    /// The count on each section's row; a section without one shows none.
    var badges: [SettingsSection: Int]
    /// What is typed in the search field above the sidebar.
    @State private var searchQuery = ""

    var body: some View {
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
                            .badge(badges[section] ?? 0)
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
                    app.openSettings(section: hit.section, tab: hit.tab)
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
