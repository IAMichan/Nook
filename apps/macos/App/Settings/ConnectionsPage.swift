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

/// Settings › Accounts & connections: everything Nook is linked to, on one page, in one order.
///
/// - One button adds anything (a chat app, a service, your own server, the iPhone): pick it, follow its steps.
/// - What you have is listed by kind, each in the same row shape, with what stopped working first and its Fix button.
/// - The Mac's own apps are switches; chat options and watched pull requests come last.
///
/// The coding agents and the AI Nook thinks with have pages of their own; a row here leads to each.
struct ConnectionsPage: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var mcpStore = MCPServerStore.shared
    @ObservedObject private var mcpSignIn = MCPSignIn.shared
    @ObservedObject private var capture = ChatCaptureService.shared
    @ObservedObject private var linker = ChatLinker.shared
    @ObservedObject private var serviceBridge = ChatCaptureService.shared.serviceBridge
    @ObservedObject private var whatsApp = WhatsAppAccounts.shared
    @ObservedObject private var companion = CompanionStore.shared
    @ObservedObject private var beeper = BeeperImporter.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var route = ConnectionsRoute.shared
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
        let services = Services(cloud: connectedCloud, remote: linkedRemote,
                                gitLab: GitLabCredentials.hosts.filter { matches("GitLab " + $0) })
        let own = mcpStore.servers.filter { $0.serviceID == nil && matches($0.name) }
        let nothingLinked = query.isEmpty && chats.isEmpty && services.isEmpty && own.isEmpty && !companion.enabled

        // Modifiers go on one section: on the Group they would be copied to every section in it.
        searchAndAdd
            .sheet(item: $sheet, onDismiss: refresh) { sheet in
                AddConnectionSheet(category: sheet.category, start: sheet.option)
            }
            .task { await linker.refresh() }
            // The helper started or stopped: what can be linked is listed again.
            .onChange(of: serviceBridge.isWorking) { _, _ in Task { await linker.refresh() } }
            .onAppear { follow(route.pending) }
            .onChange(of: route.pending) { _, target in follow(target) }
        if nothingLinked { popular(options) }
        if beeper.isOffered && query.isEmpty {
            BeeperImportSection(setCollecting: { ChatCollecting.set($0) })
        }
        Group {
            if !chats.isEmpty || query.isEmpty { chatsSection(chats, options) }
            if !services.isEmpty || query.isEmpty { servicesSection(services) }
            // Watched pull requests are searched with your GitHub accounts, so they sit with them once GitHub is connected.
            if query.isEmpty && services.cloud.contains(where: { $0.id == "github" }) {
                WatchedPullRequestsSection()
            }
            if !own.isEmpty { ownSection(own) }
            if matches(tr("settings.devices.iphone")) { devicesSection(options) }
        }
        Group {
            if query.isEmpty { elsewhereSection }
            localSection
            if query.isEmpty {
                ChatOptionsSection()
            } else {
                moreSection(options)
            }
        }
    }

    /// The online services that are linked, each kind in its own row view.
    private struct Services {
        var cloud: [ContextSource]
        var remote: [MCPRemoteService]
        var gitLab: [String]

        var isEmpty: Bool { cloud.isEmpty && remote.isEmpty && gitLab.isEmpty }
    }

    // MARK: Sections

    private var searchAndAdd: some View {
        Section {
            HStack(spacing: NookTheme.Spacing.md) {
                NookSearchField(prompt: tr("hub.search"), text: $query, style: .inline)
                Button {
                    sheet = Sheet()
                } label: {
                    Label(tr("hub.add"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

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
            ForEach(chats) { chatRow($0, options) }
            addRow(tr("hub.chats.add"), category: .chats)
        } header: {
            Text(tr("hub.chats"))
        }
    }

    private func servicesSection(_ services: Services) -> some View {
        Section {
            ForEach(services.cloud.indices, id: \.self) { index in
                CloudConnectorViews.row(services.cloud[index], capabilities: capabilityLine(services.cloud[index].id), onChange: refresh)
            }
            ForEach(services.remote) { service in
                MCPServiceRow(service: service, keyAlternative: cloudSource(service.id),
                              capabilities: capabilityLine(service.id), onChange: refresh)
            }
            ForEach(services.gitLab, id: \.self) { host in
                GitLabHostRow(host: host) { refreshTick += 1 }
            }
            addRow(tr("hub.services.add"), category: nil)
        } header: {
            Text(tr("hub.services"))
        }
    }

    private func ownSection(_ own: [MCPServerConfig]) -> some View {
        Section {
            ForEach(own) { MCPServerCardRow(config: $0) }
            Button {
                sheet = Sheet(option: ConnectionCatalog.customServer)
            } label: {
                Label(tr("hub.own.add"), systemImage: "plus")
            }
            .buttonStyle(.link)
        } header: {
            SettingsSectionTitle(tr("hub.own"), info: tr("settings2.connections.missingDetail"))
        }
    }

    private func devicesSection(_ options: [ConnectionOption]) -> some View {
        Section {
            iPhoneRow(options)
        } header: {
            Text(tr("hub.cat.devices"))
        }
    }

    /// The AI Nook thinks with and the coding agents are signed in to on their own pages: a row leads to each.
    private var elsewhereSection: some View {
        Section {
            SettingsLinkRow(title: SettingsSection.brain.title,
                            detail: settings.brainReady ? settings.activeModelName : tr("settings.checklist.brain.notReady"),
                            section: .brain, state: settings.brainReady ? .done : .todo) {
                app.settingsSection = .brain
            }
            SettingsLinkRow(title: SettingsSection.agents.title, detail: tr("hub.agents.detail"), section: .agents) {
                app.settingsSection = .agents
            }
        } header: {
            Text(tr("hub.elsewhere"))
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
                Text(tr("settings.connections.onYourMac"))
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
            Text(tr("hub.add"))
        }
    }

    // MARK: Rows

    /// A linked chat app: its state, the switch that shows its chats, and Manage (its sheet).
    private func chatRow(_ state: ChatAppState, _ options: [ConnectionOption]) -> some View {
        ServiceRowLayout(domain: state.site, symbol: "bubble.left.and.bubble.right.fill", tint: NookTheme.iris, title: state.name,
                         detail: state.detail, status: state.status, detailIsError: state.detailIsError, source: state.id) {
            Toggle("", isOn: Binding(get: { state.isOn }, set: { on in
                capture.setSource(state.id, on: on)
                if on, !capture.enabled { ChatCollecting.set(true) }
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(tr("chats.apps.showInChats", state.name))
            let needsYou = state.status == .expired || state.status == .unreachable
            Button(needsYou ? tr("settings2.fix") : tr("settings2.manage")) {
                sheet = Sheet(option: options.first { $0.id == "chat." + state.id })
            }
            .buttonStyle(.bordered)
            .tint(needsYou ? NookTheme.amber : nil)
            .controlSize(.small)
        }
    }

    /// The iPhone companion: whether it is on and how many phones are paired, and the sheet that pairs one.
    private func iPhoneRow(_ options: [ConnectionOption]) -> some View {
        let paired = companion.devices.count
        let status: ServiceStatus = !companion.enabled ? .notLinked : (paired > 0 ? .connected : .off)
        let detail = !companion.enabled ? tr("hub.iphone.tagline")
            : (paired > 0 ? tr("hub.iphone.paired", paired) : tr("hub.iphone.waiting"))
        return ServiceRowLayout(domain: nil, symbol: "iphone", tint: NookTheme.iris, title: tr("settings.devices.iphone"),
                                detail: detail, status: status) {
            Button(companion.enabled ? tr("settings2.manage") : tr("hub.setUp")) {
                sheet = Sheet(option: options.first { $0.id == "device.iphone" })
            }
            .controlSize(.small)
        }
    }

    /// The last row of a group: adds another of its kind, through the Add sheet opened on that group.
    private func addRow(_ title: String, category: ConnectionCategory?) -> some View {
        Button {
            sheet = Sheet(category: category)
        } label: {
            Label(title, systemImage: "plus")
        }
        .buttonStyle(.link)
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

    private func localRow(_ source: ContextSource) -> some View {
        // The clipboard and the chats from every notification are yours to turn on.
        let fallback = source.id != "clipboard" && source.id != ChatInboxConnector.sourceID
        return Toggle(isOn: Binding(
            get: { let _ = refreshTick; return ConnectorToggle.isOn(source.id, default: fallback) },
            set: { on in
                ConnectorToggle.set(source.id, on)
                refreshTick += 1
                app.connectors.refresh(source)
            }
        )) {
            HStack(spacing: 10) {
                SiteIcon(domain: source.iconDomain, fallback: source.symbol, tint: source.accent, size: 20, source: source.id)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(source.title)
                    Text(localDetail(source))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(isFailing(source) ? NookTheme.coral : NookTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            // The details (what Nook reads, what needs approval) on hover: the list itself stays quiet.
            .help(capabilityLine(source.id) + (source.status.updated.map { " · " + tr("context.updated", NookDates.ago($0)) } ?? ""))
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
