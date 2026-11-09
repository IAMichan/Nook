import SwiftUI
import AppKit

/// The code hosts besides GitHub whose pull requests open in Nook like one on GitHub: GitLab (`GitLabHostRow`) and the
/// hosts with a token in `ForgeCredentials` (Gitea, Forgejo, Codeberg, GitCafe, Bitbucket, Azure DevOps), each in the one
/// connection row, with "+ Add code host" in the header to pick which kind to add.
struct ForgeHostsSection: View {
    var onChange: () -> Void = {}
    @State private var gitLabHosts = GitLabCredentials.hosts
    @State private var hosts = ForgeCredentials.hosts
    @State private var adding: CodeHostKind?

    var body: some View {
        Section {
            if gitLabHosts.isEmpty, hosts.isEmpty {
                ConnectionListEmpty(title: tr("codeHost.empty.title"), detail: tr("codeHost.empty.detail"))
            }
            ForEach(gitLabHosts, id: \.self) { host in
                GitLabHostRow(host: host, onChange: reload)
            }
            ForEach(hosts, id: \.self) { host in
                ForgeHostRow(host: host, onChange: reload)
            }
        } header: {
            header
        }
        .sheet(item: $adding, onDismiss: reload) { kind in
            if kind == .gitlab {
                GitLabSetupSheet()
            } else {
                ForgeSetupSheet(kind: kind, onSaved: reload)
            }
        }
        .onAppear(perform: reload)
    }

    /// `ConnectionListHeader`'s shape, with a menu instead of a button because adding starts with which kind of host.
    private var header: some View {
        HStack {
            SettingsSectionTitle(tr("codeHost.title"), info: tr("codeHost.info"))
            Spacer()
            Menu {
                ForEach(CodeHostKind.allCases) { kind in
                    Button(kind.menuName) { adding = kind }
                }
            } label: {
                Label(tr("codeHost.add"), systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
        }
    }

    private func reload() {
        gitLabHosts = GitLabCredentials.hosts
        hosts = ForgeCredentials.hosts
        onChange()
    }
}

/// The kinds of code host Settings › Pull requests adds a token for. Gitea, Forgejo and Codeberg speak the same API, so
/// they are one choice; any host Nook cannot place by its name is shown as that kind too.
enum CodeHostKind: String, CaseIterable, Identifiable {
    case gitlab, gitea, gitcafe, bitbucket, azureDevOps

    var id: String { rawValue }

    /// The kind a stored host belongs to, by its name, the way pull request links are placed (`SourceControlHost`).
    init(host: String) {
        switch SourceControlHost.classify(hostName: host) {
        case .gitlab: self = .gitlab
        case .gitcafe: self = .gitcafe
        case .bitbucket: self = .bitbucket
        case .azureDevOps: self = .azureDevOps
        case .gitea, .forgejo, .github, .unknown: self = .gitea
        }
    }

    /// The brand name, as the forge itself writes it.
    var name: String {
        switch self {
        case .gitlab: return "GitLab"
        case .gitea: return "Gitea"
        case .gitcafe: return GitCafePullRequestForge.name
        case .bitbucket: return BitbucketPullRequestForge.name
        case .azureDevOps: return AzureDevOpsPullRequestForge.name
        }
    }

    var menuName: String { self == .gitea ? tr("codeHost.kind.gitea") : name }

    /// The host a token for this kind goes to when it has only one; nil asks for it (Gitea and Forgejo run anywhere).
    var fixedHost: String? {
        switch self {
        case .gitlab: return "gitlab.com"
        case .gitcafe: return "git.cafe"
        case .bitbucket: return "bitbucket.org"
        case .azureDevOps: return "dev.azure.com"
        case .gitea: return nil
        }
    }

    /// Where the brand icon comes from.
    var domain: String {
        switch self {
        case .gitlab: return "gitlab.com"
        case .gitea: return "gitea.com"
        case .gitcafe: return "git.cafe"
        case .bitbucket: return "bitbucket.org"
        case .azureDevOps: return "dev.azure.com"
        }
    }

    /// The page where the token is made, on `host`.
    func tokenPage(host: String) -> URL? {
        switch self {
        case .gitlab: return URL(string: "https://\(host)/-/user_settings/personal_access_tokens")
        case .gitea: return URL(string: "https://\(host)/user/settings/applications")
        case .gitcafe: return URL(string: "https://\(host)")
        // Atlassian replaced app passwords with API tokens with scopes (2025–2026); those are made on the Atlassian account.
        case .bitbucket: return URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")
        case .azureDevOps: return URL(string: "https://dev.azure.com/_usersSettings/tokens")
        }
    }

    /// How to make the token there, including the `user:token` form Bitbucket and Azure DevOps need.
    var tokenDetail: String { tr("codeHost.step.tokenDetail." + rawValue) }

    var tokenPrompt: String {
        switch self {
        case .bitbucket: return "username:token"
        case .azureDevOps: return ":token"
        case .gitlab: return "glpat-…"
        case .gitea, .gitcafe: return "token"
        }
    }
}

/// A host with a token in `ForgeCredentials`. Nook only learns whether the token works when a pull request there opens,
/// so the row says the token is saved rather than connected; opened, it shows the token and replacing it.
private struct ForgeHostRow: View {
    let host: String
    let onChange: () -> Void

    private var kind: CodeHostKind { CodeHostKind(host: host) }

    var body: some View {
        ConnectionRow(
            title: kind.fixedHost == nil ? host : kind.name,
            status: .connected,
            statusText: tr("codeHost.tokenSaved"),
            detail: kind.fixedHost == nil ? kind.name : host,
            removal: ConnectionRemoval(title: tr("settings.forge.remove"), question: tr("codeHost.removeQuestion", host),
                                       detail: tr("codeHost.removeDetail", host)) {
                ForgeCredentials.remove(host: host)
                ToastCenter.shared.success(tr("connection.removed", host))
                onChange()
            }
        ) {
            ServiceTile(domain: kind.domain, fallback: "chevron.left.forwardslash.chevron.right")
        } menu: {
            Button(tr("codeHost.openHost", host)) {
                if let url = URL(string: "https://\(host)") { NSWorkspace.shared.open(url) }
            }
        } expanded: {
            ForgeSetupSheet(kind: kind, managing: host, onSaved: onChange)
        }
    }
}

/// Adding a host's token in the numbered steps of every setup (make the token, paste it), with Cancel and Add on the
/// right. Managing one (`managing`), it shows only the token and replacing it, which its opened row embeds.
struct ForgeSetupSheet: View {
    let kind: CodeHostKind
    var managing: String? = nil
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var token = ""
    @State private var failed = false
    @State private var replacing = false

    private var target: String { managing ?? kind.fixedHost ?? host }
    private var canSave: Bool {
        GitLabCredentials.normalize(target) != nil && !ConnectorField.clean(token).isEmpty
    }

    var body: some View {
        SetupSheet(title: managing ?? kind.menuName,
                   subtitle: tr("codeHost.addSubtitle"),
                   status: managing != nil ? .working : nil) {
            ServiceTile(domain: kind.domain, fallback: "chevron.left.forwardslash.chevron.right", size: 48)
        } content: {
            if managing != nil { manageContent } else { connectContent }
        } footer: {
            Spacer()
            if managing != nil {
                Button(tr("settings2.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button(tr("button.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button(tr("settings.forge.add"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canSave)
            }
        }
        .onAppear { if kind == .gitea, host.isEmpty { host = "codeberg.org" } }
    }

    // MARK: Add (two steps)

    @ViewBuilder
    private var connectContent: some View {
        SetupStep(number: 1, title: tr("codeHost.step.token")) {
            Text(kind.tokenDetail)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if kind.fixedHost == nil {
                TextField(tr("settings.forge.host"), text: $host)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onChange(of: host) { _, _ in failed = false }
            }
            Button {
                if let page = GitLabCredentials.normalize(target).flatMap(kind.tokenPage) { NSWorkspace.shared.open(page) }
            } label: {
                Label(tr("codeHost.openTokens"), systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(GitLabCredentials.normalize(target) == nil)
        }
        SetupStep(number: 2, title: tr("codeHost.step.paste"), done: false) {
            tokenField
        }
    }

    // MARK: Manage

    @ViewBuilder
    private var manageContent: some View {
        SheetPart(tr("settings2.service.keyTitle")) {
            if replacing {
                tokenField
                HStack {
                    Spacer()
                    Button(tr("button.cancel")) { withAnimation(NookTheme.reveal) { replacing = false; token = "" } }
                    Button(tr("button.save"), action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSave)
                }
            } else {
                HStack {
                    Label(tr("settings2.service.keySafe"), systemImage: "lock.fill")
                        .foregroundStyle(NookTheme.textSecondary)
                    Spacer()
                    Button(tr("settings2.service.replaceKey")) { withAnimation(NookTheme.reveal) { replacing = true } }
                }
            }
            if kind == .bitbucket || kind == .azureDevOps {
                SettingNote(kind.tokenDetail)
            }
        }
    }

    // MARK: Token

    private var tokenField: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack {
                SecureField(tr("settings.forge.token"), text: $token, prompt: Text(kind.tokenPrompt))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if canSave { save() } }
                    .onChange(of: token) { _, _ in failed = false }
                Button { paste() } label: {
                    Label(tr("button.pasteClipboard"), systemImage: "doc.on.clipboard")
                }
            }
            if failed {
                SettingNote(tr("settings.forge.failed"), tone: .error)
            }
        }
    }

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !ConnectorField.clean(text).isEmpty else { return }
        token = text
    }

    /// Stores the token in the Keychain under the host; a host Nook cannot read is refused before anything is stored.
    private func save() {
        guard ForgeCredentials.save(host: target, token: token) else {
            failed = true
            return
        }
        token = ""
        onSaved()
        if managing == nil {
            ToastCenter.shared.success(tr("connection.added", GitLabCredentials.normalize(target) ?? target))
            dismiss()
        } else {
            withAnimation(NookTheme.reveal) { replacing = false }
        }
    }
}
