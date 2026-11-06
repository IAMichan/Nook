import SwiftUI

/// Tokens for the code hosts besides GitHub and GitLab (Gitea, Forgejo, Codeberg, GitCafe, Bitbucket, Azure DevOps): a
/// pull request there then opens in Nook like one on GitHub. One line per host, and the fields that add another.
struct ForgeHostsSection: View {
    var onChange: () -> Void = {}
    @State private var hosts = ForgeCredentials.hosts
    @State private var host = ""
    @State private var token = ""
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Text(tr("settings.forge.title")).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper)
            Text(tr("settings.forge.detail"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(hosts, id: \.self) { name in
                HStack(spacing: NookTheme.Spacing.sm) {
                    Text(name).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textStrong)
                    Spacer(minLength: NookTheme.Spacing.sm)
                    SmallGhostButton(title: tr("settings.forge.remove")) {
                        ForgeCredentials.remove(host: name)
                        reload()
                    }
                }
            }
            HStack(spacing: NookTheme.Spacing.sm) {
                TextField(tr("settings.forge.host"), text: $host).textFieldStyle(.roundedBorder)
                SecureField(tr("settings.forge.token"), text: $token).textFieldStyle(.roundedBorder)
                SmallPrimaryButton(title: tr("settings.forge.add")) {
                    failed = !ForgeCredentials.save(host: host, token: token)
                    guard !failed else { return }
                    host = ""
                    token = ""
                    reload()
                }
                .disabled(host.isEmpty || token.isEmpty)
            }
            if failed {
                Text(tr("settings.forge.failed")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.coralSoft)
            }
        }
    }

    private func reload() {
        hosts = ForgeCredentials.hosts
        onChange()
    }
}
