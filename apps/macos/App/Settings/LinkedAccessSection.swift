import SwiftUI

/// Settings › Privacy › Access: everything Nook is signed in to, in one list next to the Mac's permissions, so you can
/// see at a glance what Nook can reach and take any of it back. Each row opens the connection's own sheet, where it is
/// switched off or removed (which deletes its key or token from the Keychain); nothing is managed twice.
struct LinkedAccessSection: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var mcpStore = MCPServerStore.shared

    var body: some View {
        let linked = ConnectionCatalog.options(app).filter(\.linked)
        // Servers you added yourself are not in the catalogue as linked: they are listed after it.
        let own = mcpStore.servers.filter { $0.serviceID == nil }
        Section {
            if linked.isEmpty && own.isEmpty {
                ListEmptyNote(tr("access.linked.none"))
            }
            ForEach(linked) { option in
                row(title: option.title, detail: detail(option),
                    icon: ServiceTile(domain: option.domain, fallback: option.symbol, tint: option.tint, size: 22, source: option.source)) {
                    app.openConnections(Self.target(option))
                }
            }
            ForEach(own) { server in
                row(title: server.name, detail: tr("access.linked.ownServer"),
                    icon: ServiceTile(domain: nil, fallback: "puzzlepiece.extension.fill", tint: MCPPreset.genericTint, size: 22, source: nil)) {
                    app.openConnections()
                }
            }
        } header: {
            SettingsSectionTitle(tr("access.linked.title"), info: tr("access.linked.info"))
        }
    }

    /// The group it belongs to, and whether only a brain on this Mac may read it.
    private func detail(_ option: ConnectionOption) -> String {
        let group = option.category.title
        guard let source = Self.sourceID(option), settings.keptOnMac.contains(source) else { return group }
        return group + " · " + tr("access.linked.onlyThisMac")
    }

    /// The id the privacy settings know this connection by.
    private static func sourceID(_ option: ConnectionOption) -> String? {
        switch option.destination {
        case .keyed(let source): return source.id
        case .signIn(let service, _): return service.id
        case .chat(let id): return id
        case .mcp, .iPhone: return option.source
        }
    }

    /// Where Manage goes: the chat app's own sheet, or the Add sheet opened on this option.
    static func target(_ option: ConnectionOption) -> ConnectionsRoute.Target {
        if case .chat(let id) = option.destination { return .chat(id) }
        return .option(option.id)
    }

    private func row(title: String, detail: String, icon: some View, manage: @escaping () -> Void) -> some View {
        HStack(spacing: NookTheme.Spacing.lg) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(title).lineLimit(1)
                Text(detail)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: NookTheme.Spacing.sm)
            Button(tr("access.linked.manage"), action: manage)
                .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
    }
}
