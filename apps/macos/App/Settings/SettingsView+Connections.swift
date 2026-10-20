import SwiftUI
import AppKit

/// Settings › Accounts & connections.
extension SettingsView {
    // MARK: Connectors

    /// Every way to connect on one page, in one layout: a search field with category chips, what needs you, what you
    /// already have (one row shape for every service), the apps on this Mac (switches), and one catalogue of everything
    /// you can add (one card shape, with a badge that says how: sign in, a key, or MCP). Agent accounts live under Agents.
    var connectionsSection: some View {
        // Collected once per redraw: every capability line below is derived from it.
        let tools: [(name: String, isAction: Bool)] = app.knownTools.map { (name: $0.name, isAction: $0.kind == .action) }
        let capabilityLine: (String) -> String = { SourceCapabilities.line($0, tools: tools) }
        let refresh = { app.connectors.refreshAll() }
        let oauthIDs = Set(MCPRemoteService.all.map(\.id))
        let cloud = app.connectors.sources.filter { !($0 is MCPConnector) && $0 is any CloudConnectorConfig }
        let expired = expiredConfigs()
        // A service whose sign-in is running stays a card, with its spinner, until it is connected.
        let linkedServices = Set(mcpStore.servers.filter { !mcpSignIn.isConnecting($0.id) }.compactMap(\.serviceID))
        let keyed = { (id: String) in cloud.first { $0.id == id }.map(isConnected) ?? false }
        let category = connectionCategory
        let inCategory = { (value: ServiceCategory) in category == nil || category == value }

        // Yours: every connected service, whatever way it was connected.
        let connectedCloud = cloud.filter { isConnected($0) && matchesSearch($0, capabilityLine) && inCategory(ServiceCategory.of(sourceID: $0.id)) }
        let linkedRemote = MCPRemoteService.all.filter {
            linkedServices.contains($0.id) && !keyed($0.id) && matchesSearch(title: $0.name + " " + $0.tagline) && inCategory(ServiceCategory.of($0))
        }
        let ownServers = mcpStore.servers.filter { $0.serviceID == nil && matchesSearch(title: $0.name) && inCategory(.automation) }
        let gitLabHosts = inCategory(.development) && matchesSearch(title: "GitLab") ? GitLabCredentials.hosts : []
        let hasYours = !connectedCloud.isEmpty || !linkedRemote.isEmpty || !ownServers.isEmpty || !gitLabHosts.isEmpty
        // Watched pull requests are searched with your GitHub accounts, so they sit with them once GitHub is connected.
        let showWatchedPulls = keyed("github") && inCategory(.development) && matchesSearch(title: "GitHub " + tr("settings.pulls.title"))

        // The catalogue: everything you can add, sign-in first because that is the easiest.
        let oneClick = MCPRemoteService.all.filter {
            !linkedServices.contains($0.id) && !keyed($0.id) && matchesSearch(title: $0.name + " " + $0.tagline) && inCategory(ServiceCategory.of($0))
        }
        // GitHub signs in too (its own login page, or the GitHub CLI login): never a key you have to make first.
        let gitHub = cloud.first { $0.id == "github" && !isConnected($0) && matchesSearch($0, capabilityLine) && inCategory(.development) }
        let withKey = cloud.filter {
            !isConnected($0) && !oauthIDs.contains($0.id) && $0.id != "github" && matchesSearch($0, capabilityLine)
                && inCategory(ServiceCategory.of(sourceID: $0.id))
        }
        let showGitLab = gitLabHosts.isEmpty && inCategory(.development) && matchesSearch(title: "GitLab")
        let presets = MCPPreset.all.filter { matchesSearch(title: $0.name + " " + $0.detail + " MCP") && inCategory($0.category) }
        let showCustomMCP = inCategory(.automation) && matchesSearch(title: tr("mcp.custom.button") + " MCP")
        let hasCatalogue = gitHub != nil || !oneClick.isEmpty || !withKey.isEmpty || showGitLab || !presets.isEmpty || showCustomMCP

        let local = inCategory(.mac) ? localSources(capabilityLine) : []
        let query = connectionSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let whatsApp = inCategory(.mac) && (query.isEmpty || "whatsapp".contains(query) || query.contains("whats"))

        return Group {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(tr("settings.connections.search"), text: $connectionSearch, prompt: Text(tr("settings.connections.searchPrompt")))
                        .textFieldStyle(.plain)
                    if !connectionSearch.isEmpty {
                        Button { connectionSearch = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain)
                            .help(tr("button.close"))
                    }
                }
                ServiceCategoryChips(selection: $connectionCategory)
            } footer: {
                Text(tr("connect.intro"))
            }

            if !expired.isEmpty {
                Section(tr("settings.connections.needsYou")) {
                    ForEach(expired) { config in
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(NookTheme.amber)
                            Text(tr("connect.expiredBanner", config.name)).font(.callout)
                            Spacer(minLength: 8)
                            Button(tr("settings.connections.signInAgain")) { mcpSignIn.signIn(config, app: app) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                    }
                }
            }

            if hasYours {
                Section(tr("settings.connections.yours")) {
                    ForEach(connectedCloud.indices, id: \.self) { index in
                        serviceRow(connectedCloud[index], capabilityLine, refresh)
                    }
                    ForEach(linkedRemote) { service in
                        MCPServiceRow(service: service, keyAlternative: cloud.first { $0.id == service.id },
                                      capabilities: capabilityLine(service.id), onChange: refresh)
                    }
                    ForEach(gitLabHosts, id: \.self) { host in
                        GitLabHostRow(host: host) { refreshTick += 1 }
                    }
                    ForEach(ownServers) { config in
                        MCPServerCardRow(config: config)
                    }
                }
            }

            if showWatchedPulls {
                WatchedPullRequestsSection()
            }

            if !local.isEmpty {
                Section {
                    ForEach(local.indices, id: \.self) { index in
                        localRow(local[index], capabilityLine)
                    }
                } header: {
                    Text(tr("settings.connections.onYourMac"))
                } footer: {
                    Text(tr("settings.connections.footer"))
                }
            }

            if whatsApp {
                WhatsAppLinkSection()
            }

            if hasCatalogue {
                Section {
                    GalleryGrid {
                        if let gitHub {
                            GitHubSignInCard(keyAlternative: gitHub, capabilities: capabilityLine(gitHub.id), onChange: refresh)
                        }
                        ForEach(oneClick) { service in
                            OneClickServiceCard(service: service, keyAlternative: cloud.first { $0.id == service.id },
                                                capabilities: capabilityLine(service.id), onChange: refresh)
                        }
                        ForEach(withKey.indices, id: \.self) { index in
                            CloudConnectorViews.card(withKey[index], capabilities: capabilityLine(withKey[index].id), onChange: refresh)
                        }
                        if showGitLab {
                            GitLabCard { refreshTick += 1 }
                        }
                        ForEach(presets) { preset in
                            MCPPresetCard(preset: preset) { mcpAdd = $0 }
                        }
                        if showCustomMCP {
                            MCPCustomCard { mcpAdd = $0 }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                } header: {
                    Text(tr("settings.connections.add"))
                } footer: {
                    Text(tr("settings.connections.addFooter"))
                }
                .sheet(item: $mcpAdd) { request in
                    AddMCPServerWizardSheet(preset: request.preset) { mcpAdd = nil }
                }
            } else if !hasYours && !showWatchedPulls && local.isEmpty && !whatsApp {
                Section {
                    Text(tr("settings.connections.noMatch", connectionSearch))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if category == nil {
                Section {
                    let others = NotYetBuiltIn.all.filter { matchesSearch(title: $0.name) }
                    if !others.isEmpty {
                        DisclosureGroup(tr("settings.connections.moreApps")) {
                            ForEach(others, id: \.name) { item in
                                HStack(alignment: .top, spacing: 10) {
                                    HStack(spacing: -4) {
                                        ForEach(item.domains, id: \.self) { domain in
                                            ServiceTile(domain: domain, fallback: "app.dashed", size: 22)
                                        }
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                        Text(item.how).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                } header: {
                    Text(tr("connect.notListed"))
                } footer: {
                    Text(tr("settings2.connections.missingDetail"))
                }
            }
        }
    }

    /// A built-in service: the manage row once a key is set, otherwise a row with Connect.
    @ViewBuilder
    private func serviceRow(_ source: ContextSource, _ capabilityLine: (String) -> String, _ refresh: @escaping () -> Void) -> some View {
        if isConnected(source) {
            CloudConnectorViews.row(source, capabilities: capabilityLine(source.id), onChange: refresh)
        } else {
            CloudConnectorViews.linkRow(source, capabilities: capabilityLine(source.id), onChange: refresh)
        }
    }

    /// Signed-in services whose sign-in has expired: shown on top with one button, so nobody has to go looking.
    func expiredConfigs() -> [MCPServerConfig] {
        mcpStore.servers.filter(\.signsIn).filter { config in
            guard let source = app.connectors.source(id: config.sourceID), source.isActive,
                  case .error = source.status.state else { return false }
            return (source.status.errorKind ?? .other).needsReconnect
        }
    }

    /// A service with its keys in place (switched on or not): it belongs at the top, under Connected.
    func isConnected(_ source: ContextSource) -> Bool {
        (source as? any CloudConnectorConfig)?.isConfigured ?? false
    }

    func localSources(_ capabilityLine: (String) -> String) -> [ContextSource] {
        let ids = ["calendar", "reminders", "notes", "mail", "browser", "files", "clipboard", "messages", "whatsapp", "chats", "bear", "things"]
        // Apps that are not on this Mac are not worth a row.
        return ids.compactMap { app.connectors.source(id: $0) }
            .filter { ($0 as? AppDatabaseConnector)?.isInstalled ?? true }
            .filter { matchesSearch($0, capabilityLine) }
    }

    func matchesSearch(_ source: ContextSource, _ capabilityLine: (String) -> String) -> Bool {
        // Without a query everything matches: building the capability line means collecting every tool of every
        // connector, which made this page crawl on each redraw.
        let query = connectionSearch.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return true }
        return (source.title + " " + capabilityLine(source.id)).localizedCaseInsensitiveContains(query)
    }

    func matchesSearch(title: String) -> Bool {
        let query = connectionSearch.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || title.localizedCaseInsensitiveContains(query)
    }

    func localRow(_ source: ContextSource, _ capabilityLine: @escaping (String) -> String) -> some View {
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title)
                    Text(localDetail(source)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            // The details (what Nook reads, what needs approval) on hover: the list itself stays quiet.
            .help(capabilityLine(source.id) + (source.status.updated.map { " · " + tr("context.updated", NookDates.ago($0)) } ?? ""))
        }
    }

    func localDetail(_ source: ContextSource) -> String {
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
}
