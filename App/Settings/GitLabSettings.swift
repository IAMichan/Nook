import SwiftUI

/// GitLab hosts with a personal access token (gitlab.com or self-hosted), for merge requests from the Agents tab.
/// The token goes to the Keychain at once and is never shown again.
struct GitLabSettingsRows: View {
    @State private var hosts = GitLabCredentials.hosts
    @State private var host = "gitlab.com"
    @State private var token = ""
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("gitlab.title")).font(.headline)
            Text(tr("gitlab.hint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if hosts.isEmpty {
                Text(tr("gitlab.none")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(hosts, id: \.self) { saved in
                HStack {
                    Image(systemName: "key.fill").foregroundStyle(.secondary)
                    Text(saved)
                    Spacer()
                    Button(tr("gitlab.remove")) {
                        GitLabCredentials.remove(host: saved)
                        hosts = GitLabCredentials.hosts
                    }
                }
            }
            HStack {
                TextField(tr("gitlab.host"), text: $host).textFieldStyle(.roundedBorder)
                SecureField(tr("gitlab.token"), text: $token).textFieldStyle(.roundedBorder)
                Button(tr("gitlab.add")) {
                    failed = !GitLabCredentials.save(host: host, token: token)
                    if !failed { token = ""; hosts = GitLabCredentials.hosts }
                }
                .disabled(token.isEmpty)
            }
            if failed { Text(tr("gitlab.invalid")).font(.caption).foregroundStyle(.red) }
        }
    }
}
