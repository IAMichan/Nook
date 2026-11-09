import SwiftUI
import AppKit
import AVFoundation
import Speech
import EventKit

/// Settings pages, in the order of the sidebar, laid out lays out its settings: Nook's own pages first, then
/// what it thinks with, the coding agents, code, everything it is linked to, and maintenance and About last. Each subject
/// lives in exactly one place and each page holds one subject, short enough to take in at once: a page that grew past a
/// few groups is split into pages of its own (never tabs), and a list that grows with your data can be
/// searched.
/// A page whose main step is adding something (a chat app, a connection, a machine) has that button in its header
/// (`headerAction`).
enum SettingsSection: String, CaseIterable, Identifiable {
    case start, general, appearance, notch, notifications, notificationApps, sound, shortcuts,
         brain, assistant, memory,
         autocomplete, autocompleteApps, autocompleteStyle, autocompletePlayground, autocompleteStats, dictation,
         agents, sessions, automation, usage, archive,
         projects, worktrees, openIn, pullRequests,
         chats, connections, iphone, machines,
         privacy, permissions, onDevice, activityLog,
         maintenance, about

    /// The sidebar groups, each a handful of pages. The first and the last have no heading: space alone sets them apart.
    enum Group: String, CaseIterable, Identifiable {
        case nook, intelligence, typing, agents, code, connect, privacy, system

        var id: String { rawValue }

        /// The heading above the group, nil for the groups that stand on their own (the first and the last).
        var title: String? {
            switch self {
            case .nook, .system: return nil
            default: return tr("settings.group.\(rawValue)")
            }
        }

        var sections: [SettingsSection] {
            switch self {
            // Nook itself: how it behaves, where and how it shows, notifies and sounds, and its keys.
            case .nook: return [.start, .general, .appearance, .notch, .notifications, .notificationApps, .sound, .shortcuts]
            // The AI Nook thinks with, what it does with it, and what it remembers.
            case .intelligence: return [.brain, .assistant, .memory]
            // Completing what you type, one page per part, and dictating.
            case .typing: return [.autocomplete, .autocompleteApps, .autocompleteStyle, .autocompletePlayground,
                                  .autocompleteStats, .dictation]
            // The coding agents, how their sessions start and behave, what runs by itself, what they used, and what was put away.
            case .agents: return [.agents, .sessions, .automation, .usage, .archive]
            // Where the agents work and what comes out of it.
            case .code: return [.projects, .worktrees, .openIn, .pullRequests]
            // Everything Nook is linked to: chat apps, services, the iPhone and other machines.
            case .connect: return [.chats, .connections, .iphone, .machines]
            // What Nook may see and send, and what it did.
            case .privacy: return [.privacy, .permissions, .onDevice, .activityLog]
            // Keeping Nook up to date and healthy, and what it is.
            case .system: return [.maintenance, .about]
            }
        }
    }

    /// The group a page is in, for its breadcrumb.
    var group: Group { Group.allCases.first { $0.sections.contains(self) } ?? .nook }

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
    /// None any more:, adding sits in the header of the list it adds to ("+ Add machine"), once per page.
    /// `requested` stays, so a link elsewhere in Nook can still open a page's add sheet.
    static func button(for section: SettingsSection) -> (title: String, symbol: String)? {
        nil
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
    /// The project folder Settings › Projects shows ("" until one is chosen: the first one then).
    @State var sessionScope = ""
    /// What is typed above the sources under Privacy › Only on this Mac.
    @State var sourceQuery = ""

    var body: some View {
        // Once per redraw: both read every linked source and chat app, and the sidebar, header and Overview all use them.
        let problems = ConnectionProblems.current(app)
        let needs = attention(problems: problems)
        let section = app.settingsSection
        //: a sidebar of pages on the left, and on the right a bar with where you are over the page itself,
        // a centered column of titled groups.
        HStack(spacing: 0) {
            SettingsSidebar(badges: [
                .start: needs.count,
                .chats: problems.filter(\.isChat).count,
                .connections: problems.filter { !$0.isChat }.count,
                .autocomplete: AutocompleteController.shared.needsAttention ? 1 : 0
            ])
            .frame(width: SettingsLayout.sidebarWidth)
            NookDivider(vertical: true)
            VStack(spacing: 0) {
                SettingsPageBar(section: section)
                NookDivider()
                page(section, attention: needs, problems: problems.filter { !$0.isChat }.count)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NookTheme.canvas)
        }
        // The bars run up into the title bar, as the window has a full-size content view; the traffic lights sit over
        // the sidebar's top.
        .ignoresSafeArea(.container, edges: .top)
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

    /// One page: its groups, in one column of readable width. A setting found with the search is scrolled to and lit.
    private func page(_ section: SettingsSection, attention needs: [AttentionItem], problems: Int) -> some View {
        ScrollViewReader { proxy in
            Form {
                detail(for: section, attention: needs, problems: problems)
            }
            .formStyle(.grouped)
            // Every row reads at the panel's body size; captions and notes set their own smaller style.
            .font(NookTheme.TextStyle.body)
            .scrollContentBackground(.hidden)
            .settingsHighlightScroll(proxy)
        }
        .frame(maxWidth: SettingsLayout.pageWidth)
        .frame(maxWidth: .infinity)
        // Rebuilt for a new page or language. Not for the accent: Appearance is drawn in this view's own body, so it
        // redraws in the new color without the Form being rebuilt (which would scroll back to the top on every swatch click or color picker drag).
        .id("\(section.rawValue)-\(settings.appLanguage.rawValue)")
    }

    /// `attention` and `problems` are what the body worked out once for this redraw.
    @ViewBuilder
    func detail(for section: SettingsSection, attention: [AttentionItem], problems: Int) -> some View {
        switch section {
        case .start: startSection(attention: attention, problems: problems)
        case .general: generalSection
        case .notch: notchSection
        case .appearance: appearanceSection
        case .shortcuts: shortcutsSection
        case .notifications: NoticeRulesSettings(settings: settings, thinkAlong: app.thinkAlong, part: .how)
        case .notificationApps: NoticeRulesSettings(settings: settings, thinkAlong: app.thinkAlong, part: .apps)
        case .sound: soundSection
        case .brain: brainSection
        case .assistant: assistantSection
        case .memory: MemorySettingsSection()
        case .autocomplete: AutocompleteSettingsSection(page: .general)
        case .autocompleteApps: AutocompleteSettingsSection(page: .apps)
        case .autocompleteStyle: AutocompleteSettingsSection(page: .style)
        case .autocompletePlayground: AutocompleteSettingsSection(page: .playground)
        case .autocompleteStats: AutocompleteSettingsSection(page: .stats)
        case .dictation: FlowSettingsSection()
        case .chats: ConnectionsPage(part: .chats)
        case .connections: ConnectionsPage(part: .services)
        case .iphone: CompanionSettingsRows()
        case .machines: RemoteMachinesSection()
        case .agents: agentsSection
        case .sessions: WorkspaceSettingsSection(part: .sessions, scope: $sessionScope)
        case .automation: WorkspaceSettingsSection(part: .automation, scope: $sessionScope)
        // What an agent costs, and how to spend fewer tokens: one subject, one page.
        case .usage:
            usageSettingsSection
            TokenSettingsSection()
        case .archive: ArchiveSettingsSection()
        case .projects: WorkspaceSettingsSection(part: .projects, scope: $sessionScope)
        case .worktrees: WorkspaceSettingsSection(part: .worktrees, scope: $sessionScope)
        // Where things open: the editor and terminal of a session, and Nook's browser.
        case .openIn:
            WorkspaceSettingsSection(part: .openIn, scope: $sessionScope)
            WorkspaceSettingsSection(part: .browser, scope: $sessionScope)
        case .pullRequests:
            WatchedPullRequestsSection()
            ForgeHostsSection()
            WorkspaceSettingsSection(part: .commits, scope: $sessionScope)
        case .privacy: privacySection(.level)
        case .permissions: privacySection(.access)
        case .onDevice: privacySection(.onDevice)
        case .activityLog: privacySection(.log)
        case .maintenance: maintenanceSection
        case .about: aboutSection
        }
    }
}
