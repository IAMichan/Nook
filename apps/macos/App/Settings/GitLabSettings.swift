import SwiftUI
import AppKit

/// GitLab in Settings › Connections, in the same shapes as every other service: a connected host is a row under
/// "Your connections", and the card in the catalogue opens the step-by-step setup (make a token, paste it, done).
struct GitLabHostRow: View {
    let host: String
    var onChange: () -> Void = {}
    @State private var confirmRemove = false

    var body: some View {
        ServiceRowLayout(domain: host, symbol: "key.fill", tint: NookTheme.iris, title: "GitLab",
                         detail: host + " · " + tr("gitlab.tagline"), status: .connected) {
            Menu {
                Button(tr("gitlab.remove"), role: .destructive) { confirmRemove = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("connect.manage", "GitLab"))
        }
        .confirmationDialog(tr("connect.disconnectTitle", host), isPresented: $confirmRemove) {
            Button(tr("gitlab.remove"), role: .destructive) {
                GitLabCredentials.remove(host: host)
                onChange()
            }
            Button(tr("button.cancel"), role: .cancel) {}
        }
    }
}

/// The GitLab card in the catalogue: click, and the setup sheet walks through the token.
struct GitLabCard: View {
    var onChange: () -> Void = {}
    @State private var showSetup = false

    var body: some View {
        GalleryCard(title: "GitLab", detail: tr("gitlab.tagline")) {
            ServiceTile(domain: "gitlab.com", fallback: "key.fill", tint: NookTheme.iris, size: 34)
        } accessory: {
            ConnectMethodBadge(method: .key)
        } action: {
            showSetup = true
        }
        .sheet(isPresented: $showSetup, onDismiss: onChange) {
            GitLabSetupSheet()
        }
    }
}

/// Three numbered steps: open GitLab's token page, paste the token (and the host when it is not gitlab.com), done.
struct GitLabSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host = "gitlab.com"
    @State private var token = ""
    @State private var failed = false
    @State private var saved = false

    private var tokenPage: URL? {
        URL(string: "https://\(GitLabCredentials.normalize(host) ?? "gitlab.com")/-/user_settings/personal_access_tokens")
    }

    var body: some View {
        SetupSheet(title: "GitLab", subtitle: tr("gitlab.hint")) {
            ServiceTile(domain: "gitlab.com", fallback: "key.fill", tint: NookTheme.iris, size: 44)
        } content: {
            SetupStep(number: 1, title: tr("gitlab.step.token"), done: saved) {
                Text(tr("gitlab.step.tokenDetail"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField(tr("gitlab.host"), text: $host)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                    Button(tr("gitlab.openTokens")) {
                        if let tokenPage { NSWorkspace.shared.open(tokenPage) }
                    }
                }
            }
            SetupStep(number: 2, title: tr("gitlab.step.paste"), done: saved) {
                SecureField(tr("gitlab.token"), text: $token)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                if failed {
                    Text(tr("gitlab.invalid")).font(.caption).foregroundStyle(NookTheme.coral)
                }
            }
            SetupStep(number: 3, title: tr("gitlab.step.done"), done: saved) {
                Text(saved ? tr("gitlab.doneDetail", GitLabCredentials.normalize(host) ?? host) : tr("gitlab.step.doneDetail"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Spacer()
            if saved {
                Button(tr("button.ok")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(tr("button.cancel")) { dismiss() }
                Button(tr("gitlab.add"), action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func save() {
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        failed = !GitLabCredentials.save(host: host, token: token)
        if !failed {
            token = ""
            saved = true
        }
    }
}
