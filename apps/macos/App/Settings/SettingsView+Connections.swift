import SwiftUI
import AppKit

/// Settings › Accounts & connections.
extension SettingsView {
    // MARK: Connectors

    /// Every service in one calm list, grouped by what it is for. Each row says its state in plain words (Not connected,
    /// Connecting, Connected, Sign-in expired) and has one obvious button. Services with an official MCP server sign in
    /// with OAuth; the rest use a key with a step-by-step guide. Agent accounts live under Agents, raw MCP under MCP.
    var connectionsSection: some View {
        // Collected once per redraw: every capability line below is derived from it.
        let tools: [(name: String, isAction: Bool)] = app.knownTools.map { (name: $0.name, isAction: $0.kind == .action) }
        let capabilityLine: (String) -> String = { SourceCapabilities.line($0, tools: tools) }
        let refresh = { app.connectors.refreshAll() }
        let oauthIDs = Set(MCPRemoteService.all.map(\.id))
        let cloud = app.connectors.sources.filter { !($0 is MCPConnector) && $0 is any CloudConnectorConfig }
        let expired = expiredServices()
        return Group {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(tr("settings.connections.search"), text: $connectionSearch, prompt: Text(tr("settings.connections.searchPrompt")))
                        .textFieldStyle(.plain)
                    if !connectionSearch.isEmpty {
                        Button { connectionSearch = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain)
                    }
                }
                categoryChips
            } footer: {
                Text(tr("connect.intro"))
            }

            if !expired.isEmpty {
                Section {
                    ForEach(expired, id: \.self) { name in
                        Label(tr("connect.expiredBanner", name), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(NookTheme.amber)
                            .font(.callout)
                    }
                }
            }

            ForEach(ServiceCategory.allCases.filter { connectionCategory == nil || connectionCategory == $0 }) { category in
                let builtIn = cloud.filter { ServiceCategory.of(sourceID: $0.id) == category && matchesSearch($0, capabilityLine) }
                let remote = MCPRemoteService.all.filter { ServiceCategory.of($0) == category && matchesSearch(title: $0.name + " " + $0.tagline) }
                let local = category == .mac ? localSources(capabilityLine) : []
                if !builtIn.isEmpty || !remote.isEmpty || !local.isEmpty {
                    Section {
                        // A built-in service that also has an OAuth server shows once: the key row when a key is set,
                        // otherwise the sign-in row with the key as the alternative.
                        ForEach(builtIn.indices, id: \.self) { index in
                            let source = builtIn[index]
                            if !oauthIDs.contains(source.id) || isConnected(source) {
                                serviceRow(source, capabilityLine, refresh)
                            }
                        }
                        ForEach(remote) { service in
                            let keyed = builtIn.first { $0.id == service.id }
                            if keyed.map({ !isConnected($0) }) ?? true {
                                MCPServiceRow(service: service, keyAlternative: keyed,
                                              capabilities: keyed.map { capabilityLine($0.id) } ?? "", onChange: refresh)
                            }
                        }
                        ForEach(local.indices, id: \.self) { index in
                            localRow(local[index], capabilityLine)
                        }
                    } header: {
                        Text(category.title)
                    } footer: {
                        if category == .mac { Text(tr("settings.connections.footer")) }
                    }
                }
            }

            if connectionCategory == nil || connectionCategory == .mac,
               connectionSearch.isEmpty || "whatsapp".contains(connectionSearch.lowercased()) || connectionSearch.lowercased().contains("whats") {
                WhatsAppLinkSection()
            }

            Section {
                Button { app.settingsSection = .mcp } label: {
                    HStack(spacing: 12) {
                        SettingsTile(.mcp, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("settings2.connections.missing")).foregroundStyle(.primary)
                            Text(tr("settings2.connections.missingDetail"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
            }
        }
    }

    /// The category filter: All, then one chip per group.
    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(tr("connect.category.all"), selected: connectionCategory == nil) { connectionCategory = nil }
                ForEach(ServiceCategory.allCases) { category in
                    chip(category.title, selected: connectionCategory == category) { connectionCategory = category }
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .foregroundStyle(selected ? NookTheme.onIris : Color.primary)
                .background(Capsule().fill(selected ? NookTheme.iris : Color.primary.opacity(0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

    /// Names of signed-in services whose sign-in has expired: shown on top, so nobody has to go looking.
    func expiredServices() -> [String] {
        MCPServerStore.shared.servers.filter(\.signsIn).compactMap { config in
            guard let source = app.connectors.source(id: config.sourceID), source.isActive,
                  case .error = source.status.state, (source.status.errorKind ?? .other).needsReconnect else { return nil }
            return config.name
        }
    }

    /// A service with its keys in place (switched on or not): it belongs at the top, under Connected.
    func isConnected(_ source: ContextSource) -> Bool {
        (source as? any CloudConnectorConfig)?.isConfigured ?? false
    }

    func localSources(_ capabilityLine: (String) -> String) -> [ContextSource] {
        let ids = ["calendar", "reminders", "notes", "mail", "browser", "files", "clipboard", "messages", "whatsapp", "bear", "things"]
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
        let fallback = source.id != "clipboard"
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
