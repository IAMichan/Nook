import SwiftUI

/// Settings › Automation › Nook in another app: the switch, the address for the assistant, sign-ins that wait for their code, and
/// the grants (each 30 days) with their access level and a revoke button. Read when the rows appear and when something
/// changes; nothing polls, so an open Settings window costs nothing.
struct RemoteMCPSettingsSection: View {
    /// The address button says "Copied" for a moment after a click.
    @StateObject private var copiedAddress = CopiedMoment()
    @ObservedObject var ws: WorkspaceSettings
    @ObservedObject private var server = RemoteMCPServer.shared

    var body: some View {
        Section {
            SettingToggle(tr("remotemcp.enable"), detail: tr("remotemcp.enable.help"), isOn: $ws.remoteMCPEnabled)
                .onChange(of: ws.remoteMCPEnabled) { _, on in server.set(wanted: on) }
            if ws.remoteMCPEnabled { rows }
        } header: {
            SettingsSectionTitle(tr("remotemcp.title"), info: tr("remotemcp.footer"))
        }
        .onAppear { server.refreshExpired() }
    }

    @ViewBuilder private var rows: some View {
        switch server.state {
        case .noRelay: SettingNote(tr("remotemcp.noRelay"), tone: .warning)
        case .connecting: SettingNote(tr("remotemcp.connecting"), tone: .info)
        case .connected: SettingNote(tr("remotemcp.connected"), tone: .success)
        case .off: EmptyView()
        }
        if let url = server.publicURL {
            LabeledContent {
                Button(copiedAddress.copied ? tr("button.copied") : tr("remotemcp.copy")) { copiedAddress.copy(url) }
                    .controlSize(.small)
            } label: {
                SettingLabel(tr("remotemcp.address"), detail: tr("remotemcp.address.detail"))
            }
        }
        ForEach(server.access.waiting) { signIn in
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                Text(tr("remotemcp.signin", signIn.clientName)).font(NookTheme.TextStyle.body)
                Text(RemoteMCP.display(code: signIn.code)).font(NookTheme.mono(22)).textSelection(.enabled)
                Text(tr("remotemcp.signin.help")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                HStack {
                    levelPicker(signIn.level) { server.setLevel($0, signIn: signIn.id) }
                    Button(tr("remotemcp.deny"), role: .destructive) { server.deny(signIn: signIn.id) }.controlSize(.small)
                }
            }
        }
        ForEach(server.access.grants) { grant in
            LabeledContent {
                HStack {
                    levelPicker(grant.level) { server.setLevel($0, grant: grant.id) }
                    Button(tr("remotemcp.revoke"), role: .destructive) { server.revoke(grant.id) }.controlSize(.small)
                }
            } label: {
                SettingLabel(grant.client, detail: tr("remotemcp.grant.until", grant.expires.formatted(date: .abbreviated, time: .omitted)))
            }
        }
        if server.access.grants.isEmpty && server.access.waiting.isEmpty {
            SettingNote(tr("remotemcp.none"), tone: .info)
        }
        ConfirmedButton(tr("remotemcp.reset"), question: tr("remotemcp.reset.confirm")) { server.resetEverything() }
            .controlSize(.small)
            .help(tr("remotemcp.reset.help"))
    }

    private func levelPicker(_ level: RemoteAccessLevel, set: @escaping (RemoteAccessLevel) -> Void) -> some View {
        Picker(tr("remotemcp.level"), selection: Binding(get: { level }, set: set)) {
            ForEach(RemoteAccessLevel.allCases, id: \.self) { Text(tr("remotemcp.level." + $0.rawValue)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .help(tr("remotemcp.level.help"))
    }
}
