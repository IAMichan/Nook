import SwiftUI
import AppKit

/// GitLab in Settings › Connections, in the same shapes as every other service: a connected host is a row under
/// "Your connections" that opens its manage sheet, and the card in the catalogue opens the step-by-step setup
/// (make a token, paste it, Nook checks it with GitLab).
struct GitLabHostRow: View {
    let host: String
    var onChange: () -> Void = {}
    @State private var check: GitLabTokenCheck?
    @State private var showManage = false

    var body: some View {
        Button { showManage = true } label: {
            HStack(spacing: 12) {
                ServiceTile(domain: "gitlab.com", fallback: "key.fill", tint: NookTheme.iris, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("GitLab")
                    Text(GitLabStatus.detail(host: host, check: check))
                        .font(.caption)
                        .foregroundStyle(check == .rejected ? ConnectionHealth.needsYou.color : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                HealthPill(health: GitLabStatus.health(check))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("settings2.service.manageHelp", "GitLab"))
        .padding(.vertical, 3)
        .task(id: host) { await refresh() }
        .sheet(isPresented: $showManage, onDismiss: {
            onChange()
            Task { await refresh() }
        }) {
            GitLabSetupSheet(managing: host)
        }
    }

    private func refresh() async {
        guard let token = GitLabCredentials.token(host: host) else { return }
        check = nil
        check = await GitLabCredentials.check(host: host, token: token)
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

/// The words and colors for a GitLab host's state, shared by the row and the sheet.
enum GitLabStatus {
    /// nil while Nook is still asking GitLab.
    static func health(_ check: GitLabTokenCheck?) -> ConnectionHealth {
        switch check {
        case nil: return .busy
        case .valid: return .working
        case .rejected: return .needsYou
        case .unreachable: return .broken
        }
    }

    static func detail(host: String, check: GitLabTokenCheck?) -> String {
        switch check {
        case .valid(let username): return host + " · @" + username
        case .rejected: return tr("gitlab.rejected")
        case .unreachable: return tr("gitlab.unreachable", host)
        case nil: return host + " · " + tr("gitlab.tagline")
        }
    }
}

/// Not connected yet: three numbered steps (make a token, paste it, Nook checks it). Connected (`managing` a host): its
/// state, replacing the token, and disconnecting, laid out like every other service's sheet.
struct GitLabSetupSheet: View {
    var managing: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var host = "gitlab.com"
    @State private var showSelfHosted = false
    @State private var token = ""
    @State private var note: String?
    @State private var checking = false
    @State private var check: GitLabTokenCheck?
    @State private var saved = false
    @State private var replacing = false
    @State private var confirmDisconnect = false

    private var normalizedHost: String { GitLabCredentials.normalize(host) ?? host }

    private var tokenPage: URL? {
        URL(string: "https://\(GitLabCredentials.normalize(host) ?? "gitlab.com")/-/user_settings/personal_access_tokens")
    }

    private var health: ConnectionHealth { checking ? .busy : GitLabStatus.health(check) }

    var body: some View {
        SetupSheet(
            title: "GitLab",
            subtitle: managing.map { GitLabStatus.detail(host: $0, check: checking ? nil : check) } ?? tr("gitlab.hint")
        ) {
            ServiceTile(domain: "gitlab.com", fallback: "key.fill", tint: NookTheme.iris, size: 48)
        } content: {
            if managing != nil { manageContent } else { connectContent }
        } footer: {
            if let managing {
                if confirmDisconnect {
                    Text(tr("settings2.service.disconnectConfirm"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(tr("button.cancel")) { confirmDisconnect = false }
                    Button(tr("settings2.disconnect"), role: .destructive) {
                        GitLabCredentials.remove(host: managing)
                        dismiss()
                    }
                } else {
                    Button(tr("settings2.disconnect"), role: .destructive) { confirmDisconnect = true }
                }
            }
            Spacer()
            Button(saved || managing != nil ? tr("settings2.done") : tr("button.close")) { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .task {
            guard let managing, let stored = GitLabCredentials.token(host: managing) else { return }
            host = managing
            await verify(stored)
        }
    }

    // MARK: Connect (three steps)

    @ViewBuilder
    private var connectContent: some View {
        SetupStep(number: 1, title: tr("gitlab.step.token"), done: saved) {
            Text(tr("gitlab.step.tokenDetail"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(isExpanded: $showSelfHosted) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(tr("gitlab.host"), text: $host)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Text(tr("gitlab.selfHostedDetail"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            } label: {
                Text(tr("gitlab.selfHosted")).font(.callout)
            }
            Button {
                if let tokenPage { NSWorkspace.shared.open(tokenPage) }
            } label: {
                Label(tr("gitlab.openTokens"), systemImage: "arrow.up.forward.app")
            }
            .controlSize(.large)
        }
        SetupStep(number: 2, title: tr("gitlab.step.paste"), done: saved) {
            tokenField
        }
        SetupStep(number: 3, title: tr("gitlab.step.check"), done: check?.isValid ?? false) {
            result
        }
    }

    // MARK: Manage

    @ViewBuilder
    private var manageContent: some View {
        HStack(spacing: 10) {
            HealthPill(health: health)
            Spacer()
            if check == .unreachable, !checking, let managing, let stored = GitLabCredentials.token(host: managing) {
                Button(tr("connector.retry")) { Task { await verify(stored) } }
            }
        }

        Divider()

        VStack(alignment: .leading, spacing: 10) {
            Text(tr("settings2.service.keyTitle")).font(.headline)
            if replacing || check == .rejected {
                tokenField
            } else {
                HStack {
                    Label(tr("settings2.service.keySafe"), systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("settings2.service.replaceKey")) { withAnimation { replacing = true } }
                }
            }
        }
    }

    // MARK: Token and result

    private var tokenField: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField(tr("gitlab.token"), text: $token, prompt: Text("glpat-…"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Button { pasteFromClipboard() } label: {
                    Label(tr("button.pasteClipboard"), systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.borderedProminent)
                Button(tr("button.save"), action: save)
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                Spacer()
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(NookTheme.coral)
            }
        }
    }

    @ViewBuilder
    private var result: some View {
        if checking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(tr("settings2.step.checkBusy")).font(.callout)
            }
        } else {
            switch check {
            case .valid(let username):
                Label(tr("gitlab.checkOK", username, normalizedHost), systemImage: "checkmark.seal.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(ConnectionHealth.working.color)
            case .rejected:
                Label(tr("gitlab.rejected"), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(ConnectionHealth.needsYou.color)
                    .fixedSize(horizontal: false, vertical: true)
            case .unreachable:
                Label(tr("gitlab.unreachable", normalizedHost), systemImage: "wifi.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(ConnectionHealth.broken.color)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                Text(tr("settings2.step.checkWaiting"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Actions

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !ConnectorField.clean(text).isEmpty else {
            note = tr("connector.nothingOnClipboard")
            return
        }
        token = text
        save()
    }

    /// Checks the token with GitLab first: a refused token is never stored; one Nook cannot check yet (offline, VPN) is.
    private func save() {
        let target = managing ?? host
        guard GitLabCredentials.normalize(target) != nil, !ConnectorField.clean(token).isEmpty else {
            note = tr("gitlab.invalid")
            return
        }
        note = nil
        let typed = token
        Task {
            await verify(typed)
            guard check != .rejected, GitLabCredentials.save(host: target, token: typed) else { return }
            token = ""
            saved = true
            replacing = false
        }
    }

    private func verify(_ candidate: String) async {
        checking = true
        check = await GitLabCredentials.check(host: managing ?? host, token: candidate)
        checking = false
    }
}
