import SwiftUI

/// Above a session's composer: the connectors (MCP servers) its agent has but cannot use until you sign in. One
/// connector gets its own "Sign in"; several share one menu, since an agent can list dozens. Hiding it leaves out these
/// connectors in every session (the session menu still lists them, see `ConnectorSignInMenu`).
struct ConnectorSignInBanner: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    let runID: UUID
    @State private var dismissed = ConnectorSignIns.dismissed

    var body: some View {
        let shown = ConnectorSignIns.shown(workspace.connectorSignIns[runID] ?? [], dismissed: dismissed)
        if !shown.isEmpty {
            let waiting = shown.first(where: \.waiting)
            AdaptiveActionRow {
                HStack(alignment: .center, spacing: NookTheme.Spacing.md) {
                    Image(icon: "powerplug")
                        .font(NookTheme.font(12, .semibold))
                        .foregroundStyle(NookTheme.amber)
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        Text(tr("ws.connector.title")).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.textSecondary)
                        Text(waiting.map { tr("ws.connector.waiting", $0.title) }
                             ?? (shown.count == 1 ? tr("ws.connector.one", shown[0].title) : tr("ws.connector.many", shown.count)))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(waiting == nil ? "" : tr("ws.connector.waitingHelp"))
                    }
                }
            } actions: {
                if shown.count == 1 {
                    SmallGhostButton(title: tr("ws.connector.signIn")) { workspace.signInConnector(runID, name: shown[0].name) }
                        .disabled(shown[0].waiting)
                } else {
                    ConnectorSignInMenu(runID: runID, connectors: shown)
                }
                ToolbarIconButton("xmark", tr("ws.connector.hideHelp"), height: 22, width: 22) {
                    workspace.hideConnectorSignIns(runID, names: shown.map(\.name))
                    dismissed = ConnectorSignIns.dismissed
                }
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.md)
            .cardBackground(NookTheme.surface, stroke: NookTheme.fieldStroke, radius: NookTheme.Radius.panel, style: .continuous)
        }
    }
}

/// "Sign in" as a menu of the connectors that need you; one already waiting on its page is dimmed.
struct ConnectorSignInMenu: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    let runID: UUID
    let connectors: [ConnectorSignIn]
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(connectors) { connector in
                Button(connector.waiting ? tr("ws.connector.waiting", connector.title) : connector.title) {
                    workspace.signInConnector(runID, name: connector.name)
                }
                .disabled(connector.waiting)
            }
        } label: {
            HStack(spacing: NookTheme.Spacing.xs) {
                Text(tr("ws.connector.signIn"))
                Image(icon: "chevron.down").font(NookTheme.font(9, .semibold))
            }
            .font(NookTheme.TextStyle.strong)
            .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Capsule().fill(hovering ? NookTheme.smoke : Color.clear))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
    }
}
