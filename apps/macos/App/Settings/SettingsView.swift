import SwiftUI
import AppKit
import AVFoundation
import Speech
import EventKit

/// The subjects of Settings. Each subject lives in exactly one place, but a page holds every subject that belongs
/// together, so a change never takes more than a click in the sidebar and a scroll: the sidebar lists 17 pages, and a
/// page that holds several subjects (`parts`) shows them under each other, each under a heading that says what it is,
/// with buttons at the top that jump to each. Never tabs, and never a page you can only reach from another page.
///
/// Every case stays addressable: opening a subject that lives on a larger page (`.sound`, `.permissions`) opens that
/// page (`host`) and scrolls to the subject's heading.
/// A page whose main step is adding something (a chat app, a connection, a machine) has that button in the header of
/// its list.
enum SettingsSection: String, CaseIterable, Identifiable {
    case start, general, appearance, notch, notifications, notificationApps, sound, shortcuts,
         brain, assistant, memory, instructions,
         autocomplete, autocompleteApps, autocompleteStyle, autocompletePlayground, autocompleteStats, dictation,
         agents, sessions, automation, usage, archive,
         projects, worktrees, openIn, pullRequests,
         chats, connections, iphone, machines,
         privacy, permissions, onDevice, activityLog,
         maintenance, about

    /// The sidebar groups, each a handful of pages. The first and the last have no heading: space alone sets them apart.
    enum Group: String, CaseIterable, Identifiable {
        case nook, intelligence, agents, connect, system

        var id: String { rawValue }

        /// The heading above the group, nil for the groups that stand on their own (the first and the last).
        var title: String? {
            switch self {
            case .nook, .system: return nil
            default: return tr("settings.group.\(rawValue)")
            }
        }

        /// The pages in the sidebar. Every other subject is a part of one of them (`SettingsSection.parts`).
        var sections: [SettingsSection] {
            switch self {
            // Nook itself: how it behaves and where it shows, how it looks, notifies and sounds, and its keys.
            case .nook: return [.start, .general, .appearance, .notifications, .shortcuts]
            // The AI Nook thinks with, what it does with it, and how it helps you type.
            case .intelligence: return [.brain, .assistant, .autocomplete]
            // The coding agents, their sessions, what runs by itself, and the projects they work in.
            case .agents: return [.agents, .sessions, .automation, .projects]
            // Everything Nook is linked to, and what it may see and send.
            case .connect: return [.chats, .connections, .iphone, .privacy]
            // Keeping Nook up to date and healthy, and what Nook is.
            case .system: return [.maintenance]
            }
        }
    }

    /// The subjects a sidebar page holds besides itself, in order; nil for a page of one subject.
    private var hostedParts: [SettingsSection]? {
        switch self {
        case .general: return [.general, .notch]
        case .notifications: return [.notifications, .notificationApps, .sound]
        case .assistant: return [.assistant, .memory, .instructions]
        case .autocomplete: return [.autocomplete, .autocompleteApps, .autocompleteStyle, .autocompletePlayground,
                                    .autocompleteStats, .dictation]
        case .agents: return [.agents, .usage]
        case .sessions: return [.sessions, .worktrees, .openIn, .archive]
        case .projects: return [.projects, .pullRequests]
        case .iphone: return [.iphone, .machines]
        case .privacy: return [.privacy, .permissions, .onDevice, .activityLog]
        case .maintenance: return [.maintenance, .about]
        default: return nil
        }
    }

    /// What this page shows, top to bottom: the page's own subject first, then the others that live on it.
    var parts: [SettingsSection] { hostedParts ?? [self] }

    /// The sidebar page this subject lives on: itself, or the page that holds it.
    var host: SettingsSection {
        SettingsSection.allCases.first { $0.hostedParts?.contains(self) == true } ?? self
    }

    /// Pages whose name says more than their first subject's ("Typing" holds autocomplete and dictation).
    private static let renamedPages: Set<SettingsSection> = [.autocomplete, .projects, .iphone, .privacy, .maintenance]

    /// The name of the page in the sidebar and over the page.
    var pageTitle: String { Self.renamedPages.contains(self) ? tr("settings.page.\(rawValue)") : title }

    /// What the whole page holds, in one line under its name.
    var pageSubtitle: String { hostedParts != nil ? tr("settings.page.\(rawValue).sub") : subtitle }

    /// Where a subject is, for a search result: its page, and the subject's own name when it is a part of a larger page.
    var trail: String {
        host == self ? pageTitle : "\(host.pageTitle) › \(title)"
    }

    /// The sidebar group of the page this subject lives on.
    var group: Group { Group.allCases.first { $0.sections.contains(host) } ?? .nook }

    var id: String { rawValue }

    var title: String { tr("settings.section.\(rawValue)") }

    var subtitle: String { tr("settings.section.\(rawValue).sub") }

    var symbol: String { tileSymbol }

    /// What a subject is about and how it treats your data, shown under its name; nil for most.
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
        // A subject that lives on a larger page shows that page (`settlePage` moves there and scrolls to it).
        let section = app.settingsSection.host
        // A sidebar of pages on the left, and on the right a bar with where you are over the page itself,
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
            takeProjectScope()
            settlePage()
        }
        .onChange(of: app.settingsProjectScope) { _, _ in takeProjectScope() }
        .onChange(of: app.settingsSection) { _, _ in
            settlePage()
            refreshTick += 1
            if app.settingsSection.host == .agents {
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

    /// The project a folder's menu in the Agents list asked Settings › Projects to show.
    private func takeProjectScope() {
        guard let path = app.settingsProjectScope else { return }
        sessionScope = ProjectOverrides.normalize(path)
        app.settingsProjectScope = nil
    }

    /// A subject that lives on a larger page was asked for (`.sound`, `.permissions`): show its page and scroll to the
    /// subject's heading, unless a search already asked for a setting on it.
    private func settlePage() {
        let asked = app.settingsSection
        guard asked.host != asked else { return }
        if SettingsHighlight.shared.key == nil {
            SettingsHighlight.shared.key = "settings.section.\(asked.rawValue)"
        }
        app.settingsSection = asked.host
    }

    /// One page: what it is and holds at the top, then each of its subjects under its own heading, in one column of
    /// readable width. A setting found with the search is scrolled to and lit.
    private func page(_ section: SettingsSection, attention needs: [AttentionItem], problems: Int) -> some View {
        // The first subject needs no heading of its own when the page already carries its name.
        let firstNamed = section.pageTitle != section.title
        return ScrollViewReader { proxy in
            Form {
                SettingsPageIntro(section: section, anchorsFirstPart: !firstNamed)
                ForEach(section.parts) { part in
                    if part != section || firstNamed {
                        SettingsPartHeader(part: part)
                    }
                    detail(for: part, attention: needs, problems: problems)
                }
            }
            .formStyle(SettingsFormStyle())
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
        case .instructions: InstructionsSettingsSection()
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
