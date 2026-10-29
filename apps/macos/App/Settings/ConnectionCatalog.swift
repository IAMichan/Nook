import SwiftUI
import AppKit

// MARK: - What can be linked

/// The groups of the Add sheet, in the order people look for them: the chat apps first, the iPhone last.
enum ConnectionCategory: String, CaseIterable, Identifiable {
    case chats, work, development, business, automation, devices

    var id: String { rawValue }
    var title: String { tr("hub.cat.\(rawValue)") }

    /// Where a service of Settings' older grouping lands; the Mac's own apps are switches on the page, not something
    /// to add, so a preset that works with them (the filesystem server) sits with the other servers.
    init(_ category: ServiceCategory) {
        switch category {
        case .development: self = .development
        case .work: self = .work
        case .business: self = .business
        case .automation, .mac: self = .automation
        }
    }
}

/// One thing the Add sheet offers: a chat app, an online service, your own server, or the iPhone. Every option opens
/// the same kind of sheet whether it is linked or not: the steps while it is not, its management once it is.
struct ConnectionOption: Identifiable {
    enum Destination {
        /// A chat app, linked in `ChatAppSheet`.
        case chat(String)
        /// A built-in service set up with a key (and GitHub, whose sheet signs in first).
        case keyed(ContextSource)
        /// A service you sign in to on its own page, with the key it also takes as the other way.
        case signIn(MCPRemoteService, keyAlternative: ContextSource?)
        case gitLab
        /// An MCP server from a preset, or your own (nil).
        case mcp(MCPPreset?)
        case iPhone
    }

    let id: String
    let title: String
    let detail: String
    let category: ConnectionCategory
    let method: ConnectMethod
    var domain: String? = nil
    var symbol = "link"
    var source: String? = nil
    var tint: Color = NookTheme.iris
    var linked = false
    let destination: Destination

    func matches(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty || (title + " " + detail + " " + category.title).localizedCaseInsensitiveContains(text)
    }
}

/// Everything Nook can link, built from the catalogues that already describe each kind: the chat apps
/// (`ChatAppStates`), the built-in services (`CloudConnectorConfig`), the services you sign in to (`MCPRemoteService`),
/// GitLab, the MCP presets, and the iPhone.
@MainActor
enum ConnectionCatalog {
    /// The few shown on an empty page, so a first link is one click away.
    static let featured = ["chat.whatsapp", "chat.telegram", "chat.slack", "service.github", "signin.notion", "signin.linear"]

    static func options(_ app: AppModel) -> [ConnectionOption] {
        var options: [ConnectionOption] = []

        for chat in ChatAppStates.all() {
            options.append(ConnectionOption(id: "chat." + chat.id, title: chat.name, detail: chat.detail, category: .chats,
                                            method: .signIn, domain: chat.site, symbol: "bubble.left.and.bubble.right.fill",
                                            source: chat.id, linked: chat.linked, destination: .chat(chat.id)))
        }

        let cloud = app.connectors.sources.filter { !($0 is MCPConnector) && $0 is any CloudConnectorConfig }
        let signInIDs = Set(MCPRemoteService.all.map(\.id))
        let signedIn = Set(MCPServerStore.shared.servers.compactMap(\.serviceID))
        let configured = { (source: ContextSource) in (source as? any CloudConnectorConfig)?.isConfigured ?? false }

        for service in MCPRemoteService.all {
            let key = cloud.first { $0.id == service.id }
            options.append(ConnectionOption(id: "signin." + service.id, title: service.name, detail: service.tagline,
                                            category: ConnectionCategory(ServiceCategory.of(service)), method: .signIn,
                                            domain: service.domain, linked: signedIn.contains(service.id) || key.map(configured) == true,
                                            destination: .signIn(service, keyAlternative: key)))
        }
        // Services with their own sign-in are listed once, above; GitHub signs in from its own sheet.
        for source in cloud where !signInIDs.contains(source.id) {
            options.append(ConnectionOption(id: "service." + source.id, title: source.title, detail: ServiceState.tagline(source.id),
                                            category: ConnectionCategory(ServiceCategory.of(sourceID: source.id)),
                                            method: source.id == "github" ? .signIn : .key, domain: source.iconDomain,
                                            symbol: source.symbol, source: source.id, tint: source.accent, linked: configured(source),
                                            destination: .keyed(source)))
        }
        options.append(ConnectionOption(id: "gitlab", title: "GitLab", detail: tr("gitlab.tagline"), category: .development,
                                        method: .key, domain: "gitlab.com", symbol: "key.fill",
                                        linked: !GitLabCredentials.hosts.isEmpty, destination: .gitLab))

        for preset in MCPPreset.all {
            options.append(ConnectionOption(id: "mcp." + preset.id, title: preset.name, detail: preset.detail,
                                            category: ConnectionCategory(preset.category), method: .mcp, domain: preset.iconDomain,
                                            symbol: preset.fallbackIcon, source: preset.appSource, tint: preset.tint,
                                            destination: .mcp(preset)))
        }
        options.append(customServer)

        let companion = CompanionStore.shared
        options.append(ConnectionOption(id: "device.iphone", title: tr("settings.devices.iphone"), detail: tr("hub.iphone.tagline"),
                                        category: .devices, method: .signIn, symbol: "iphone",
                                        linked: companion.enabled && !companion.devices.isEmpty, destination: .iPhone))
        return options
    }

    /// Your own MCP server, from a pasted command, config, or web address.
    static var customServer: ConnectionOption {
        ConnectionOption(id: "mcp.custom", title: tr("mcp.custom.button"), detail: tr("mcp.custom.detail"), category: .automation,
                         method: .mcp, symbol: "puzzlepiece.extension.fill", tint: MCPPreset.genericTint, destination: .mcp(nil))
    }
}

/// Switches collecting chats on or off, and has the chat inbox read again: what every chat app's sheet calls when a
/// switch in it needs collecting on.
@MainActor
enum ChatCollecting {
    static func set(_ on: Bool) {
        let app = AppModel.shared
        ChatCaptureService.shared.enabled = on
        if let source = app.connectors.source(id: ChatInboxConnector.sourceID) { app.connectors.refresh(source) }
    }
}

// MARK: - Problems

/// What stopped working among everything linked, in one list: the Overview shows it, the sidebar counts it, and the
/// connections page puts these rows first.
@MainActor
enum ConnectionProblems {
    struct Problem: Identifiable {
        let id: String
        let title: String
        let detail: String
        let state: StatusState
    }

    static func current(_ app: AppModel) -> [Problem] {
        var problems: [Problem] = app.connectors.sources.compactMap { source in
            guard source.isActive, case .error(let message) = source.status.state else { return nil }
            let relink = (source.status.errorKind ?? .other).needsReconnect
            return Problem(id: source.id, title: source.title, detail: relink ? tr("settings2.service.relinkDetail") : message,
                           state: relink ? .warning : .error)
        }
        let known = Set(problems.map(\.id))
        for chat in ChatAppStates.all() where chat.linked && !known.contains(chat.id) {
            guard chat.status == .expired || chat.status == .unreachable else { continue }
            problems.append(Problem(id: chat.id, title: chat.name, detail: chat.detail,
                                    state: chat.status == .expired ? .warning : .error))
        }
        return problems
    }
}

// MARK: - The Add sheet

/// Adding a connection, in two steps: pick what (search, or browse by group), then follow its steps in the same sheet.
/// Done closes the sheet, and the new connection is on the page behind it.
struct AddConnectionSheet: View {
    var category: ConnectionCategory?
    /// Opens straight on one option (from a row's Manage, a link elsewhere in Nook, or a featured tile).
    var start: ConnectionOption?

    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var mcpStore = MCPServerStore.shared
    @ObservedObject private var linker = ChatLinker.shared
    @State private var query = ""
    @State private var filter: ConnectionCategory?
    @State private var chosen: ConnectionOption?

    init(category: ConnectionCategory? = nil, start: ConnectionOption? = nil) {
        self.category = category
        self.start = start
        _filter = State(initialValue: category)
        _chosen = State(initialValue: start)
    }

    var body: some View {
        Group {
            if let chosen {
                VStack(alignment: .leading, spacing: 0) {
                    // Opened on one option from elsewhere: Done closes it, there is no list to go back to.
                    if start == nil {
                        Button { self.chosen = nil } label: {
                            Label(tr("hub.picker.back"), systemImage: "chevron.left")
                        }
                        .buttonStyle(.link)
                        .padding(.horizontal, NookTheme.Spacing.xl)
                        .padding(.top, NookTheme.Spacing.lg)
                    }
                    ConnectionDestinationView(option: chosen) { dismiss() }
                }
            } else {
                picker
            }
        }
    }

    private var picker: some View {
        let all = ConnectionCatalog.options(app).filter { $0.matches(query) && (filter == nil || $0.category == filter) }
        return SetupSheet(title: tr("hub.picker.title"), subtitle: tr("hub.picker.subtitle")) {
            SettingsTile(.connections, size: 48)
        } content: {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                NookSearchField(prompt: tr("hub.picker.search"), text: $query, style: .inline)
                ConnectionCategoryChips(selection: $filter)
            }
            if all.isEmpty {
                SettingNote(tr("settings.connections.noMatch", query))
            }
            ForEach(ConnectionCategory.allCases) { group in
                let options = all.filter { $0.category == group }
                if !options.isEmpty {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                        NookSectionLabel(group.title, inset: 0)
                        ConnectionOptionGrid(options: options) { chosen = $0 }
                    }
                }
            }
            if filter == nil || filter == .automation {
                notListed
            }
        } footer: {
            Spacer()
            Button(tr("button.close")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
        }
    }

    /// What Nook does not link by itself yet, and how to get it in anyway: folded away at the end.
    private var notListed: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                SettingNote(tr("settings2.connections.missingDetail"))
                ForEach(NotYetBuiltIn.all, id: \.name) { item in
                    HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
                        HStack(spacing: -4) {
                            ForEach(item.domains, id: \.self) { domain in
                                ServiceTile(domain: domain, fallback: "app.dashed", size: 22)
                            }
                        }
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                            Text(item.name)
                            Text(item.how)
                                .font(NookTheme.TextStyle.detail)
                                .foregroundStyle(NookTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Button(tr("mcp.custom.button")) { chosen = ConnectionCatalog.customServer }
            }
            .padding(.top, NookTheme.Spacing.sm)
        } label: {
            Text(tr("connect.notListed"))
        }
    }
}

/// The category chips of the Add sheet: All, then one per group.
struct ConnectionCategoryChips: View {
    @Binding var selection: ConnectionCategory?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NookTheme.Spacing.sm) {
                chip(nil, title: tr("connect.category.all"))
                ForEach(ConnectionCategory.allCases) { category in
                    chip(category, title: category.title)
                }
            }
            .padding(.vertical, NookTheme.Spacing.xxs)
        }
    }

    private func chip(_ category: ConnectionCategory?, title: String) -> some View {
        let active = selection == category
        return Button {
            selection = category
        } label: {
            Text(title)
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(active ? NookTheme.onIris : NookTheme.textStrong)
                .padding(.horizontal, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
                .padding(.vertical, NookTheme.Spacing.xs + 1)
                .background(Capsule().fill(active ? NookTheme.iris : NookTheme.smoke))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Options in two columns, each a compact tile: its icon, its name and one line, and how it links (or that it is).
struct ConnectionOptionGrid: View {
    let options: [ConnectionOption]
    let choose: (ConnectionOption) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: NookTheme.Spacing.md)],
                  spacing: NookTheme.Spacing.md) {
            ForEach(options) { option in
                ConnectionOptionTile(option: option) { choose(option) }
            }
        }
    }
}

struct ConnectionOptionTile: View {
    let option: ConnectionOption
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.md) {
                ServiceTile(domain: option.domain, fallback: option.symbol, tint: option.tint, size: 28, source: option.source)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(option.title)
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    Text(option.detail)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: NookTheme.Spacing.xs)
                if option.linked {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(NookTheme.mint)
                        .help(tr("hub.picker.linked"))
                        .accessibilityLabel(tr("hub.picker.linked"))
                } else {
                    ConnectMethodBadge(method: option.method)
                }
            }
            .padding(NookTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous)
                    .fill(hovering ? NookTheme.smoke : NookTheme.graphite)
            )
            .contentShape(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
    }
}

/// The sheet of one option: its steps while it is not linked, its management once it is. Each kind keeps the sheet it
/// already had, so linking from the Add sheet and managing from a row are the same screens.
struct ConnectionDestinationView: View {
    let option: ConnectionOption
    let done: () -> Void
    @EnvironmentObject private var app: AppModel

    var body: some View {
        switch option.destination {
        case .chat(let id):
            ChatAppSheet(app: id, setCollecting: { ChatCollecting.set($0) })
        case .keyed(let source):
            CloudConnectorViews.setupSheet(source, capabilities: capabilities(source.id), onChange: refresh)
        case .signIn(let service, let keyAlternative):
            ServiceSignInSheet(service: service, keyAlternative: keyAlternative, capabilities: capabilities(service.id))
        case .gitLab:
            GitLabSetupSheet()
        case .mcp(let preset):
            AddMCPServerWizardSheet(preset: preset, done: done)
        case .iPhone:
            IPhoneSheet()
        }
    }

    private func capabilities(_ id: String) -> String {
        SourceCapabilities.line(id, tools: app.knownTools.map { (name: $0.name, isAction: $0.kind == .action) })
    }

    private func refresh() { app.connectors.refreshAll() }
}

// MARK: - Signing in to a service

/// A service you sign in to on its own page, in two steps: sign in, and Nook checks the link. The key the service also
/// takes stays one click away for whoever prefers it.
struct ServiceSignInSheet: View {
    let service: MCPRemoteService
    var keyAlternative: ContextSource?
    var capabilities = ""

    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var signIn = MCPSignIn.shared
    @ObservedObject private var store = MCPServerStore.shared
    /// Whether this sheet started the sign-in, so only its own failure shows.
    @State private var started = false
    @State private var showKey = false
    @State private var confirmDisconnect = false

    private var config: MCPServerConfig? { store.servers.first { $0.serviceID == service.id } }

    private var status: ServiceStatus {
        guard let config else { return .notLinked }
        if signIn.isConnecting(config.id) { return .connecting }
        if let source = app.connectors.source(id: config.sourceID), case .error = source.status.state,
           (source.status.errorKind ?? .other).needsReconnect {
            return .expired
        }
        return .connected
    }

    private var failure: String? {
        guard started, case .failed(_, let message) = signIn.phase else { return nil }
        return message
    }

    var body: some View {
        SetupSheet(title: service.name, subtitle: tr("hub.signIn.subtitle", service.name)) {
            ServiceTile(domain: service.domain, fallback: "link", tint: NookTheme.iris, size: 48)
        } content: {
            SetupStep(number: 1, title: tr("hub.signIn.step", service.name), done: status == .connected) {
                Text(service.tagline)
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                switch status {
                case .connecting:
                    HStack(spacing: NookTheme.Spacing.md) {
                        ProgressView().controlSize(.small)
                        Text(tr("connect.waiting", service.name))
                            .font(NookTheme.TextStyle.detail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(tr("button.cancel")) { signIn.cancel() }
                case .connected:
                    EmptyView()
                default:
                    Button {
                        started = true
                        if let config, status == .expired { signIn.signIn(config, app: app) } else { signIn.connect(service, app: app) }
                    } label: {
                        Label(status == .expired ? tr("connect.reauthorize") : tr("hub.signIn.button", service.name),
                              systemImage: "person.badge.key.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                if let failure {
                    SettingNote(failure, tone: .error)
                }
            }
            SetupStep(number: 2, title: tr("settings2.step.check"), done: status == .connected) {
                if status == .connected {
                    Label(tr("connect.justConnected", service.name), systemImage: "checkmark.seal.fill")
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(NookTheme.mint)
                } else {
                    Text(tr("settings2.step.checkWaiting"))
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(NookTheme.textSecondary)
                }
            }
            if keyAlternative != nil, status == .notLinked {
                NookDivider()
                HStack(spacing: NookTheme.Spacing.md) {
                    SettingNote(tr("hub.signIn.keyInstead"))
                    Spacer(minLength: 0)
                    Button(tr("connect.useKey")) { showKey = true }
                }
            }
            if !capabilities.isEmpty {
                SettingNote(capabilities)
            }
        } footer: {
            if config != nil, status != .connecting {
                Button(tr("connect.disconnect"), role: .destructive) { confirmDisconnect = true }
            }
            Spacer()
            Button(status == .connected ? tr("settings2.done") : tr("button.close")) {
                if status == .connecting { signIn.cancel() }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .confirmationDialog(tr("connect.disconnectTitle", service.name), isPresented: $confirmDisconnect) {
            Button(tr("connect.disconnect"), role: .destructive) {
                guard let target = config else { return }
                Task {
                    await MCPSignIn.shared.signOut(target)
                    MCPServerStore.shared.remove(target.id)
                }
            }
            Button(tr("button.cancel"), role: .cancel) {}
        } message: {
            Text(tr("connect.disconnectDetail", service.name))
        }
        .sheet(isPresented: $showKey, onDismiss: { app.connectors.refreshAll() }) {
            if let keyAlternative {
                CloudConnectorViews.setupSheet(keyAlternative, capabilities: capabilities) { app.connectors.refreshAll() }
            }
        }
    }
}

// MARK: - Sheets with settings rows

/// A sheet whose content is plain settings rows (the iPhone's pairing, push and relay): the header and footer of
/// `SetupSheet`, with a grouped form in between instead of a scroll view.
struct SettingsFormSheet<Icon: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                icon()
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(title).font(NookTheme.TextStyle.heading)
                    Text(subtitle)
                        .foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            Divider()
            Form { content() }
                .formStyle(.grouped)
                .font(NookTheme.TextStyle.body)
                .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Spacer()
                Button(tr("settings2.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(NookTheme.Spacing.xl)
        }
        .frame(width: 560, height: 640)
    }
}

/// The iPhone companion: switching it on, pairing a phone, push, and reaching it away from home.
struct IPhoneSheet: View {
    var body: some View {
        SettingsFormSheet(title: tr("settings.devices.iphone"), subtitle: tr("hub.iphone.tagline")) {
            SettingsTile(symbol: "iphone", colors: (NookTheme.smoke, NookTheme.graphite), size: 48)
        } content: {
            CompanionSettingsRows()
        }
    }
}
