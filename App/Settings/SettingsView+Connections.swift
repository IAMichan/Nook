import SwiftUI
import AppKit

/// Settings › Accounts & connections.
extension SettingsView {
    // MARK: Connectors

    /// Calm and in the order you need it: what is connected, what is on your Mac, and below that what you can add.
    /// Adding a service is one click on its card; agent accounts live under Agents, MCP servers under MCP.
    var connectionsSection: some View {
        // Collected once per redraw: every capability line below is derived from it.
        let tools: [(name: String, isAction: Bool)] = app.knownTools.map { (name: $0.name, isAction: $0.kind == .action) }
        let capabilityLine: (String) -> String = { SourceCapabilities.line($0, tools: tools) }
        let services = app.connectors.sources.filter { !($0 is MCPConnector) && matchesSearch($0, capabilityLine) }
        let connected = services.filter(isConnected)
        let available = services.filter { !isConnected($0) }
        let refresh = { app.connectors.refreshAll() }
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
            }
            if !connected.isEmpty {
                Section {
                    ForEach(connected.indices, id: \.self) { index in
                        CloudConnectorViews.row(connected[index], capabilities: capabilityLine(connected[index].id), onChange: refresh)
                    }
                } header: {
                    Text(tr("settings2.connections.connected", connected.count))
                } footer: {
                    Text(tr("settings2.connections.connectedFooter"))
                }
            }
            let sources = localSources(capabilityLine)
            if !sources.isEmpty {
                Section {
                    ForEach(sources.indices, id: \.self) { index in
                        localRow(sources[index], capabilityLine)
                    }
                } header: {
                    Text(tr("settings.connections.onYourMac"))
                } footer: {
                    Text(tr("settings.connections.footer"))
                }
            }
            if !available.isEmpty {
                Section {
                    GalleryGrid {
                        ForEach(available.indices, id: \.self) { index in
                            CloudConnectorViews.card(available[index], capabilities: capabilityLine(available[index].id), onChange: refresh)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                } header: {
                    Text(tr("settings2.connections.add"))
                } footer: {
                    Text(tr("settings2.connections.addFooter"))
                }
            }
            if matchesSearch(title: app.portfolio.title) {
                Section(tr("settings.connections.crypto")) {
                    PortfolioSettings(portfolio: app.portfolio)
                }
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
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                Text(item.how).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
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
