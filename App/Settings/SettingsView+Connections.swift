import SwiftUI
import AppKit

/// Settings › Accounts & connections.
extension SettingsView {
    // MARK: Connectors

    /// Calm and in the order you need it: what is connected, what is on your Mac, and below that what you can add.
    /// Adding a service is one click on Connect; agent accounts live under Agents.
    var connectionsSection: some View {
        // Collected once per redraw: every capability line below is derived from it.
        let tools: [(name: String, isAction: Bool)] = app.knownTools.map { (name: $0.name, isAction: $0.kind == .action) }
        let capabilityLine: (String) -> String = { SourceCapabilities.line($0, tools: tools) }
        let services = app.connectors.sources.filter { !($0 is MCPConnector) && matchesSearch($0, capabilityLine) }
        let connected = services.filter(isConnected)
        let available = services.filter { !isConnected($0) }
        return Group {
            Section {
                TextField(tr("settings.connections.search"), text: $connectionSearch, prompt: Text(tr("settings.connections.searchPrompt")))
            }
            if !connected.isEmpty {
                Section(tr("settings.connections.connected")) {
                    CloudConnectorSettings(connectors: connected, capabilities: capabilityLine) {
                        app.connectors.refreshAll()
                    }
                }
            }
            Section {
                let sources = localSources(capabilityLine)
                ForEach(sources.indices, id: \.self) { index in
                    localRow(sources[index], capabilityLine)
                }
            } header: {
                Text(tr("settings.connections.onYourMac"))
            } footer: {
                Text(tr("settings.connections.footer"))
            }
            if !available.isEmpty {
                Section {
                    CloudConnectorSettings(connectors: available, capabilities: capabilityLine) {
                        app.connectors.refreshAll()
                    }
                } header: {
                    Text(tr("settings.connections.addService"))
                } footer: {
                    Text(tr("settings.connections.legend"))
                }
            }
            MCPSettingsSection()
            if matchesSearch(title: app.portfolio.title) {
                Section(tr("settings.connections.crypto")) {
                    PortfolioSettings(portfolio: app.portfolio)
                }
            }
            let others = NotYetBuiltIn.all.filter { matchesSearch(title: $0.name) }
            if !others.isEmpty {
                Section {
                    DisclosureGroup(tr("settings.connections.moreApps")) {
                        ForEach(others, id: \.name) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                Text(item.how).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } footer: {
                    Text(tr("settings.connections.notBuiltInFooter"))
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
                SiteIcon(domain: source.iconDomain, fallback: source.symbol, tint: source.accent, size: 20)
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
