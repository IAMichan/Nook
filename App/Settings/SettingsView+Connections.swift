import SwiftUI
import AppKit

/// Settings › Accounts & connections.
extension SettingsView {
    // MARK: Connectors

    var connectionsSection: some View {
        Group {
            Section {
                TextField(tr("settings.connections.search"), text: $connectionSearch, prompt: Text(tr("settings.connections.searchPrompt")))
                Text(tr("settings.connections.legend"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                let sources = localSources
                ForEach(sources.indices, id: \.self) { index in
                    localRow(sources[index])
                }
            } header: {
                Text(tr("settings.connections.onYourMac"))
            } footer: {
                Text(tr("settings.connections.footer"))
            }
            Section(tr("settings.connections.services")) {
                CloudConnectorSettings(connectors: app.connectors.sources.filter { !($0 is MCPConnector) && matchesSearch($0) }, capabilities: capabilityLine) {
                    app.connectors.refreshAll()
                }
            }
            MCPSettingsSection()
            // Agent accounts (Claude Code, Codex, Gemini): the same place as every other account.
            AccountsSettingsSection()
            Section {} footer: {
                Text(tr("accounts.isolationNote"))
            }
            if matchesSearch(title: app.portfolio.title) {
                Section(tr("settings.connections.crypto")) {
                    PortfolioSettings(portfolio: app.portfolio)
                }
            }
            Section {
                ForEach(NotYetBuiltIn.all.filter { matchesSearch(title: $0.name) }, id: \.name) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                        Text(item.how).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text(tr("settings.connections.notBuiltIn"))
            } footer: {
                Text(tr("settings.connections.notBuiltInFooter"))
            }
        }
    }

    var localSources: [ContextSource] {
        let ids = ["calendar", "reminders", "notes", "mail", "browser", "files", "clipboard"]
        return ids.compactMap { app.connectors.source(id: $0) }.filter { matchesSearch($0) }
    }

    func matchesSearch(_ source: ContextSource) -> Bool {
        matchesSearch(title: source.title + " " + capabilityLine(source.id))
    }

    func matchesSearch(title: String) -> Bool {
        let query = connectionSearch.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || title.localizedCaseInsensitiveContains(query)
    }

    /// How a connector is configured, its read capabilities, and actions requiring approval.
    func capabilityLine(_ id: String) -> String {
        SourceCapabilities.line(id, tools: app.knownTools.map { ($0.name, $0.kind == .action) })
    }

    func localRow(_ source: ContextSource) -> some View {
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
                    Text(localDetail(source)).font(.caption).foregroundStyle(.secondary)
                    Text(capabilityLine(source.id) + (source.status.updated.map { " · " + tr("context.updated", NookDates.ago($0)) } ?? ""))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
