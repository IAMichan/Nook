import SwiftUI
import AppKit

/// Where a link elsewhere in Nook wants Settings › Accounts & connections to open: on the Add sheet (on one group), or
/// straight on one chat app's sheet.
@MainActor
final class ConnectionsRoute: ObservableObject {
    static let shared = ConnectionsRoute()

    enum Target: Equatable {
        case add(ConnectionCategory?)
        case chat(String)
    }

    @Published var pending: Target?
}

/// Settings › Chat apps and Settings › Connections: everything Nook is linked to, on two pages of the same shape.
///
/// - Chat apps: every linked chat app with what stopped working first, the apps Nook only knows from their
///   notifications, and how chats are read.
/// - Connections: online services and your own servers (searchable, as the list grows), the Mac's own apps, music.
/// - The header button adds one (`SettingsPageAction`): pick it, follow its steps.
///
/// The iPhone, the coding agents and the watched pull requests have pages of their own in the sidebar.
struct ConnectionsPage: View {
    enum Part { case chats, services }
    let part: Part
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var mcpStore = MCPServerStore.shared
    @ObservedObject private var mcpSignIn = MCPSignIn.shared
    @ObservedObject private var capture = ChatCaptureService.shared
    @ObservedObject private var linker = ChatLinker.shared
    @ObservedObject private var serviceBridge = ChatCaptureService.shared.serviceBridge
    @ObservedObject private var whatsApp = WhatsAppAccounts.shared
    @ObservedObject private var beeper = BeeperImporter.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var route = ConnectionsRoute.shared
    @ObservedObject private var pageAction = SettingsPageAction.shared
    @ObservedObject private var spotify = SpotifySignIn.shared
    @State private var query = ""
    @State private var sheet: Sheet?
    @State private var refreshTick = 0

    /// The one sheet this page shows at a time: the Add sheet, opened on a group or on one option.
    private struct Sheet: Identifiable {
        let id = UUID()
        var category: ConnectionCategory?
        var option: ConnectionOption?
    }

    var body: some View {
        let options = ConnectionCatalog.options(app)
        let chats = linkedChats
        // GitLab's tokens for pull requests live with the other code hosts on Code › Pull requests, not here twice.
        let services = Services(cloud: connectedCloud, remote: linkedRemote)
        let own = mcpStore.servers.filter { $0.serviceID == nil && matches($0.name) }
        let nothingLinked = query.isEmpty && services.isEmpty && own.isEmpty && !spotify.isSignedIn

        // Modifiers go on one section: on the Group they would be copied to every section in it.
        top(chats, options)
            .sheet(item: $sheet, onDismiss: refresh) { sheet in
                AddConnectionSheet(category: sheet.category, start: sheet.option)
            }
            .task { await linker.refresh() }
            // The helper started or stopped: what can be linked is listed again.
            .onChange(of: serviceBridge.isWorking) { _, _ in Task { await linker.refresh() } }
            .onAppear {
                follow(route.pending)
                act(pageAction.requested)
            }
            .onChange(of: route.pending) { _, target in follow(target) }
            .onChange(of: pageAction.requested) { _, section in act(section) }
        switch part {
        case .chats:
            if beeper.isOffered {
                BeeperImportSection(setCollecting: { ChatCollecting.set($0) })
            }
            ChatOptionsSection()
        case .services:
            if nothingLinked { popular(options) }
            Group {
                if !services.isEmpty || query.isEmpty { servicesSection(services) }
                if !own.isEmpty { ownSection(own) }
                if matches("Spotify " + tr("music.connect.title")) { musicSection }
            }
            Group {
                localSection
                if !query.isEmpty { moreSection(options) }
            }
        }
    }

    /// The first section of the page: the linked chat apps, or the search over the services (their list grows).
    @ViewBuilder
    private func top(_ chats: [ChatAppState], _ options: [ConnectionOption]) -> some View {
        switch part {
        case .chats:
            chatsSection(chats, options)
        case .services:
            Section {
                NookSearchField(prompt: tr("hub.search"), text: $query, style: .inline)
            }
        }
    }

    /// Spotify and Apple Music, and whether Nook may look up lyrics online for what plays.
    @ViewBuilder
    private var musicSection: some View {
        MusicConnectionSection()
        Section {
            SettingToggle(tr("settings.privacy.onlineLyrics"), detail: tr("settings.privacy.onlineLyricsDetail"),
                          isOn: $settings.onlineLyrics)
        }
    }

    /// The header's button: link a chat app on Chat apps, add any connection on Connections.
    private func act(_ section: SettingsSection?) {
        guard let section, section == (part == .chats ? .chats : .connections) else { return }
        pageAction.requested = nil
        sheet = Sheet(category: part == .chats ? .chats : nil)
    }

    /// The online services that are linked, each kind in its own row view.
    private struct Services {
        var cloud: [ContextSource]
        var remote: [MCPRemoteService]

        var isEmpty: Bool { cloud.isEmpty && remote.isEmpty }
    }

    // MARK: Sections

    /// Nothing linked yet: what the page is for, and the links most people make first.
    private func popular(_ options: [ConnectionOption]) -> some View {
        Section {
            IntroCard(title: tr("hub.empty.title"), text: tr("hub.empty.text"))
            ConnectionOptionGrid(options: ConnectionCatalog.featured.compactMap { id in options.first { $0.id == id } }) {
                sheet = Sheet(option: $0)
            }
            .padding(.vertical, NookTheme.Spacing.xs)
        } header: {
            Text(tr("hub.popular"))
        }
    }

    private func chatsSection(_ chats: [ChatAppState], _ options: [ConnectionOption]) -> some View {
        Section {
            // Nothing linked yet: what the page is for, and the header's button links the first one.
            if chats.isEmpty {
                ConnectionListEmpty(title: tr("hub.empty.title"), detail: tr("connection.emptyChats"))
            }
            ForEach(chats) { chatRow($0, options) }
        } header: {
            ConnectionListHeader(title: tr("hub.chats"), add: (tr("hub.chats.add"), { sheet = Sheet(category: .chats) }))
        }
    }

    private func servicesSection(_ services: Services) -> some View {
        Section {
            if services.isEmpty {
                ConnectionListEmpty(title: tr("connection.emptyServices.title"), detail: tr("connection.emptyServices"))
            }
            ForEach(services.cloud.indices, id: \.self) { index in
                CloudConnectorViews.row(services.cloud[index], capabilities: capabilityLine(services.cloud[index].id), onChange: refresh)
            }
            ForEach(services.remote) { service in
                MCPServiceRow(service: service, keyAlternative: cloudSource(service.id),
                              capabilities: capabilityLine(service.id), onChange: refresh)
            }
        } header: {
            ConnectionListHeader(title: tr("hub.services"), add: (tr("hub.add"), { sheet = Sheet() }))
        }
    }

    private func ownSection(_ own: [MCPServerConfig]) -> some View {
        Section {
            ForEach(own) { MCPServerCardRow(config: $0) }
        } header: {
            ConnectionListHeader(title: tr("hub.own"), info: tr("settings2.connections.missingDetail"),
                                 add: (tr("hub.own.add"), { sheet = Sheet(option: ConnectionCatalog.customServer) }))
        }
    }

    @ViewBuilder
    private var localSection: some View {
        let local = localSources
        if !local.isEmpty {
            Section {
                ForEach(local.indices, id: \.self) { index in
                    localRow(local[index])
                }
            } header: {
                SettingText("settings.connections.onYourMac")
            }
        }
    }

    /// Searching also finds what is not linked yet, one click from its steps.
    private func moreSection(_ options: [ConnectionOption]) -> some View {
        let more = options.filter { !$0.linked && $0.matches(query) }
        return Section {
            if more.isEmpty {
                SettingNote(tr("settings.connections.noMatch", query))
            } else {
                ConnectionOptionGrid(options: more) { sheet = Sheet(option: $0) }
                    .padding(.vertical, NookTheme.Spacing.xs)
            }
        } header: {
            SettingText("hub.add")
        }
    }

    // MARK: Rows

    /// A linked chat app in the one connection row: the switch shows its chats in Chats (off keeps the link), and opening
    /// it manages it in place: its accounts, what it does in Nook, troubleshooting.
    private func chatRow(_ state: ChatAppState, _ options: [ConnectionOption]) -> some View {
        ConnectionRow(title: state.name, status: state.status, detail: state.detail,
                      isOn: Binding(get: { state.isOn }, set: { on in
                          capture.setSource(state.id, on: on)
                          if on, !capture.enabled { ChatCollecting.set(true) }
                      }),
                      startsOpen: route.pending.map { if case .chat(state.id) = $0 { return true } else { return false } } ?? false) {
            ServiceTile(domain: state.site, fallback: "bubble.left.and.bubble.right.fill", tint: NookTheme.iris, size: 28,
                        source: state.id)
        } menu: {
            Button(tr("chats.link.another")) { sheet = Sheet(option: options.first { $0.id == "chat." + state.id }) }
        } expanded: {
            ChatAppSheet(app: state.id, setCollecting: { ChatCollecting.set($0) })
        }
    }

    // MARK: What is linked

    /// Linked chat apps, the ones that need you first.
    private var linkedChats: [ChatAppState] {
        ChatAppStates.all().filter { $0.linked && matches($0.name) }.sorted { rank($0.status) < rank($1.status) }
    }

    private var cloudSources: [ContextSource] {
        app.connectors.sources.filter { !($0 is MCPConnector) && $0 is any CloudConnectorConfig }
    }

    private func cloudSource(_ id: String) -> ContextSource? { cloudSources.first { $0.id == id } }

    private func isConnected(_ source: ContextSource) -> Bool {
        (source as? any CloudConnectorConfig)?.isConfigured ?? false
    }

    /// Services with their keys in place (switched on or not), the ones that need you first.
    private var connectedCloud: [ContextSource] {
        cloudSources.filter { isConnected($0) && matches($0.title) }.sorted { health($0) < health($1) }
    }

    /// Services you signed in to on their own page; one also set up with a key is listed once, as that.
    private var linkedRemote: [MCPRemoteService] {
        // A service whose sign-in is running stays out of the list until it is connected: its sheet shows the progress.
        let linked = Set(mcpStore.servers.filter { !mcpSignIn.isConnecting($0.id) }.compactMap(\.serviceID))
        return MCPRemoteService.all.filter { service in
            linked.contains(service.id) && !(cloudSource(service.id).map(isConnected) ?? false) && matches(service.name)
        }
    }

    private func rank(_ status: ServiceStatus) -> Int {
        switch status {
        case .unreachable, .expired: return 0
        case .connecting: return 1
        case .connected: return 2
        case .off, .notLinked: return 3
        }
    }

    private func health(_ source: ContextSource) -> Int {
        guard case .error = source.status.state, ConnectorToggle.isOn(source.id) else { return 1 }
        return 0
    }

    // MARK: On this Mac

    private var localSources: [ContextSource] {
        let ids = ["calendar", "reminders", "notes", "mail", "browser", "files", "clipboard", "messages", "whatsapp", "bear", "things"]
        // Apps that are not on this Mac are not worth a row.
        return ids.compactMap { app.connectors.source(id: $0) }
            .filter { ($0 as? AppDatabaseConnector)?.isInstalled ?? true }
            .filter { matches($0.title) }
    }

    /// An app on this Mac in the one connection row: the switch lets Nook read it, and opening it says what Nook can do
    /// with it and when it last looked.
    private func localRow(_ source: ContextSource) -> some View {
        // The clipboard and the chats from every notification are yours to turn on.
        let fallback = source.id != "clipboard" && source.id != ChatInboxConnector.sourceID
        let on = ConnectorToggle.isOn(source.id, default: fallback)
        let _ = refreshTick
        return ConnectionRow(title: source.title,
                             status: isFailing(source) ? .unreachable : (on ? .connected : .off),
                             statusText: isFailing(source) ? tr("settings2.health.broken") : (on ? tr("connection.reads") : nil),
                             detail: localDetail(source),
                             isOn: Binding(
                                 get: { let _ = refreshTick; return ConnectorToggle.isOn(source.id, default: fallback) },
                                 set: { on in
                                     ConnectorToggle.set(source.id, on)
                                     refreshTick += 1
                                     app.connectors.refresh(source)
                                 })) {
            SiteIcon(domain: source.iconDomain, fallback: source.symbol, tint: source.accent, size: 22, source: source.id)
        } menu: {
            Button(tr("connector.retry")) { app.connectors.refresh(source) }
        } expanded: {
            SheetPart(tr("sheet.part.canDo")) {
                SettingNote(capabilityLine(source.id).isEmpty ? tr("connection.canDoUnknown") : capabilityLine(source.id))
            }
            if let updated = source.status.updated {
                SettingNote(tr("context.updated", NookDates.ago(updated)))
            }
        }
    }

    /// A source on this Mac that could not be read: its line says why, in the error color.
    private func isFailing(_ source: ContextSource) -> Bool {
        if case .error = source.status.state { return true }
        return false
    }

    private func localDetail(_ source: ContextSource) -> String {
        if case .error(let message) = source.status.state { return message }
        switch source.id {
        case "calendar": return app.calendar.hasEventAccess ? (source.status.headline.isEmpty ? tr("settings.connections.calendarDetail") : source.status.headline) : tr("settings.connections.givePermission")
        case "reminders": return app.calendar.hasReminderAccess ? (source.status.headline.isEmpty ? tr("settings.connections.remindersDetail") : source.status.headline) : tr("settings.connections.givePermission")
        case "mail": return tr("settings.connections.mailDetail")
        case "browser": return tr("settings.connections.browserDetail")
        case "files": return tr("settings.connections.filesDetail")
        case "clipboard": return tr("settings.connections.clipboardDetail")
        default: return source.status.detail
        }
    }

    // MARK: Helpers

    private func matches(_ title: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty || title.localizedCaseInsensitiveContains(text)
    }

    private func capabilityLine(_ id: String) -> String {
        SourceCapabilities.line(id, tools: app.knownTools.map { (name: $0.name, isAction: $0.kind == .action) })
    }

    private func refresh() {
        app.connectors.refreshAll()
        refreshTick += 1
    }

    /// Opens what a link elsewhere in Nook asked for, once.
    private func follow(_ target: ConnectionsRoute.Target?) {
        guard let target else { return }
        route.pending = nil
        switch target {
        case .add(let category):
            sheet = Sheet(category: category)
        case .chat(let id):
            sheet = Sheet(category: .chats, option: ConnectionCatalog.options(app).first { $0.id == "chat." + id })
        }
    }
}
