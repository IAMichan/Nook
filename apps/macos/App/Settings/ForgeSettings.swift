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
        ConnectionListMenuHeader(title: tr("codeHost.title"), info: tr("codeHost.info"), add: tr("codeHost.add")) {
            ForEach(CodeHostKind.allCases) { kind in
                Button(kind.menuName) { adding = kind }
            }
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

/// Adding a host's token in the numbered steps of every setup: make the token, paste it, and Nook checks it with the
/// host and saves it (Done on the right), or, for a host Nook cannot ask whose token it is, says it is ready to add
/// (Cancel and Add on the right). Managing one (`managing`), it shows the host's state and replacing the token, which
/// its opened row embeds.
struct ForgeSetupSheet: View {
    let kind: CodeHostKind
    var managing: String? = nil
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var token = ""
    @State private var failed = false
    @State private var replacing = false
    @State private var checking = false
    @State private var check: ForgeTokenCheck?
    @State private var saved = false

    private var target: String { managing ?? kind.fixedHost ?? host }
    private var normalizedTarget: String { GitLabCredentials.normalize(target) ?? target }
    private var canSave: Bool {
        GitLabCredentials.normalize(target) != nil && !ConnectorField.clean(token).isEmpty
    }

    /// The pill beside the title: what the host said about the stored token; nil where Nook cannot ask it.
    private var status: ConnectionHealth? {
        guard managing != nil, kind.canCheckToken else { return nil }
        if checking { return .busy }
        switch check {
        case nil: return .busy
        case .valid: return .working
        case .rejected: return .needsYou
        case .unreachable: return .broken
        }
    }

    var body: some View {
        SetupSheet(title: managing ?? kind.menuName,
                   subtitle: tr("codeHost.addSubtitle"),
                   status: status) {
            ServiceTile(domain: kind.domain, fallback: "chevron.left.forwardslash.chevron.right", size: 48)
        } content: {
            if managing != nil { manageContent } else { connectContent }
        } footer: {
            Spacer()
            if managing != nil || kind.canCheckToken {
                Button(tr("settings2.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.nookProminent)
                    .controlSize(.large)
            } else {
                Button(tr("button.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button(tr("settings.forge.add"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.nookProminent)
                    .controlSize(.large)
                    .disabled(!canSave)
            }
        }
        .onAppear { if kind == .gitea, host.isEmpty { host = "codeberg.org" } }
        .task {
            guard let managing, kind.canCheckToken, let stored = ForgeCredentials.token(host: managing) else { return }
            await verify(stored)
        }
    }

    // MARK: Add (three steps)

    @ViewBuilder
    private var connectContent: some View {
        SetupStep(number: 1, title: tr("codeHost.step.token"), done: saved) {
            if kind.fixedHost == nil {
                TextField(tr("settings.forge.host"), text: $host)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onChange(of: host) { _, _ in failed = false; check = nil }
            }
            StepAction(detail: kind.tokenDetail, button: tr("codeHost.openTokens"),
                       disabled: GitLabCredentials.normalize(target) == nil) {
                if let page = GitLabCredentials.normalize(target).flatMap(kind.tokenPage) { NSWorkspace.shared.open(page) }
            }
        }
        SetupStep(number: 2, title: tr("codeHost.step.paste"), done: saved) {
            SecureField(tr("settings.forge.token"), text: $token, prompt: Text(kind.tokenPrompt))
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canSave { submit() } }
                .onChange(of: token) { _, _ in failed = false }
            if failed {
                SettingNote(tr("settings.forge.failed"), tone: .error)
            }
        }
        if kind.canCheckToken {
            SetupCheckStep(number: 3, title: tr("gitlab.step.check"),
                           detail: tr("codeHost.check.detail", normalizedTarget), state: checkState,
                           check: runCheck, disabled: !canSave && !saved)
        } else {
            SetupCheckStep(number: 3, title: tr("setup.ready.title"),
                           detail: tr("codeHost.ready.detail", kind.name), state: .idle)
        }
    }

    // MARK: Manage

    @ViewBuilder
    private var manageContent: some View {
        if check == .unreachable, !checking, let managing, let stored = ForgeCredentials.token(host: managing) {
            SheetPart(tr("sheet.part.status")) {
                SettingNote(tr("codeHost.check.unreachable", managing), tone: .error)
                Button(tr("connector.retry")) { Task { await verify(stored) } }
            }
        }
        SheetPart(tr("settings2.service.keyTitle")) {
            if replacing || check == .rejected {
                if check == .rejected, !replacing, let managing {
                    SettingNote(tr("codeHost.check.rejected", managing), tone: .error)
                }
                tokenField
                HStack {
                    Spacer()
                    if replacing {
                        Button(tr("button.cancel")) { withAnimation(NookTheme.reveal) { replacing = false; token = "" } }
                    }
                    Button(tr("button.save"), action: submit)
                        .buttonStyle(.nookProminent)
                        .disabled(!canSave || checking)
                }
            } else {
                HStack {
                    Label(tr("settings2.service.keySafe"), icon: "lock.fill")
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

    /// The token field of a host that is already added, with pasting from the clipboard beside it.
    private var tokenField: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack {
                SecureField(tr("settings.forge.token"), text: $token, prompt: Text(kind.tokenPrompt))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if canSave { submit() } }
                    .onChange(of: token) { _, _ in failed = false }
                Button { paste() } label: {
                    Label(tr("button.pasteClipboard"), icon: "doc.on.clipboard")
                }
            }
            if failed {
                SettingNote(tr("settings.forge.failed"), tone: .error)
            }
        }
    }

    /// The last step's state, from what the host said about the pasted token.
    private var checkState: SetupCheckState {
        if checking { return .checking }
        switch check {
        case .valid(let account?): return .passed(tr("codeHost.check.ok", account, normalizedTarget))
        case .valid(.none): return .passed(tr("codeHost.check.okNoName", normalizedTarget))
        case .rejected: return .failed(tr("codeHost.check.rejected", normalizedTarget))
        case .unreachable: return .failed(tr("codeHost.check.unreachable", normalizedTarget))
        case nil: return .idle
        }
    }

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !ConnectorField.clean(text).isEmpty else { return }
        token = text
    }

    /// Return in the token field, or Save while replacing it: checked first where the host can be asked.
    private func submit() {
        if kind.canCheckToken { runCheck() } else { save() }
    }

    /// The check step's button: asks the host about the pasted token and saves it unless the host refuses it, or asks
    /// again about the saved one.
    private func runCheck() {
        let typed = token
        if ConnectorField.clean(typed).isEmpty {
            guard saved, let stored = ForgeCredentials.token(host: normalizedTarget) else { return }
            Task { await verify(stored) }
            return
        }
        guard GitLabCredentials.normalize(target) != nil else {
            failed = true
            return
        }
        Task {
            await verify(typed)
            guard check != .rejected else { return }
            store(typed)
        }
    }

    /// Saves the pasted token without asking the host (a host Nook cannot ask whose token it is).
    private func save() {
        if store(token), managing == nil { dismiss() }
    }

    /// Stores the token in the Keychain under the host; a host Nook cannot read is refused before anything is stored.
    @discardableResult
    private func store(_ candidate: String) -> Bool {
        guard ForgeCredentials.save(host: target, token: candidate) else {
            failed = true
            return false
        }
        token = ""
        onSaved()
        if managing == nil {
            if !saved { ToastCenter.shared.success(tr("connection.added", normalizedTarget)) }
            saved = true
        } else {
            withAnimation(NookTheme.reveal) { replacing = false }
        }
        return true
    }

    private func verify(_ candidate: String) async {
        checking = true
        check = await kind.checkToken(host: managing ?? normalizedTarget, token: candidate)
        checking = false
    }
}

/// What a code host said when Nook asked whose a token is.
enum ForgeTokenCheck: Equatable {
    /// The host took the token; the account when it was allowed to say (a token without the user scope gets a 403,
    /// which still means the token itself is good).
    case valid(String?)
    case rejected
    /// No answer Nook could read: offline, VPN, or not that kind of host.
    case unreachable
}

extension CodeHostKind {
    /// Whether the host's API says whose a token is. Azure DevOps tokens belong to one organization and GitCafe's API
    /// has no such call Nook knows, so those are saved without a check and first used when a pull request opens.
    var canCheckToken: Bool { self == .gitea || self == .bitbucket }

    /// Asks the host's API whose `token` is (GET /user), over https only, with the same header its pull requests use.
    func checkToken(host: String, token: String) async -> ForgeTokenCheck {
        let clean = ConnectorField.clean(token)
        let url: URL?
        let authorization: String
        switch self {
        case .gitea:
            url = URL(string: "https://\(host)/api/v1/user")
            authorization = "token " + clean
        case .bitbucket:
            url = URL(string: BitbucketPullRequestForge.api + "/user")
            authorization = "Basic " + Data(clean.utf8).base64EncodedString()
        case .gitlab, .gitcafe, .azureDevOps:
            return .unreachable
        }
        guard !clean.isEmpty, let url else { return .unreachable }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await ConnectorHTTP.session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .unreachable }
        switch status {
        case 401: return .rejected
        case 403: return .valid(nil)
        case 200:
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let account = (json?["login"] as? String) ?? (json?["username"] as? String) ?? (json?["display_name"] as? String)
            return .valid(account)
        default: return .unreachable
        }
    }
}
