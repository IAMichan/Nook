import SwiftUI
import AppKit

/// A GitLab host in the one connection row every service uses: its account on the line under the name, Check again in
/// its "…" menu with Disconnect last, and once opened in place what the manage sheet used to show (the token, and
/// retrying an unreachable host). Adding one is `GitLabSetupSheet` in its numbered steps.
struct GitLabHostRow: View {
    let host: String
    var onChange: () -> Void = {}
    @State private var check: GitLabTokenCheck?

    var body: some View {
        ConnectionRow(
            title: "GitLab",
            status: GitLabStatus.health(check).status,
            statusText: GitLabStatus.rowState(check),
            detail: GitLabStatus.rowDetail(host: host, check: check),
            removal: ConnectionRemoval(title: tr("settings2.disconnect"), question: tr("connect.disconnectTitle", "GitLab"),
                                       detail: tr("codeHost.removeDetail", host)) {
                GitLabCredentials.remove(host: host)
                ToastCenter.shared.success(tr("connection.removed", "GitLab"))
                onChange()
            }
        ) {
            ServiceTile(domain: "gitlab.com", fallback: "key.fill", tint: NookTheme.iris)
        } menu: {
            Button(tr("codeHost.checkAgain")) { Task { await refresh() } }
                .disabled(check == nil)
        } expanded: {
            GitLabSetupSheet(managing: host) {
                onChange()
                Task { await refresh() }
            }
        }
        .task(id: host) { await refresh() }
    }

    private func refresh() async {
        guard let token = GitLabCredentials.token(host: host) else { return }
        check = nil
        check = await GitLabCredentials.check(host: host, token: token)
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

    /// The state word of the row's line, where the plain state says too little; nil keeps `ServiceStatus.label`.
    static func rowState(_ check: GitLabTokenCheck?) -> String? {
        switch check {
        case nil: return tr("codeHost.checking")
        case .rejected: return tr("codeHost.rejected")
        case .valid, .unreachable: return nil
        }
    }

    /// What follows the state on the row's line: the account at its host once GitLab said whose token it is.
    static func rowDetail(host: String, check: GitLabTokenCheck?) -> String {
        if case .valid(let username) = check { return username + "@" + host }
        return host
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

/// Not connected yet: three numbered steps (make a token, paste it, Nook checks and saves it). Connected (`managing` a
/// host): its state and replacing the token, shown inside its opened `GitLabHostRow` (embedded, so without header and
/// footer; the row's "…" menu disconnects), or in a window of its own with Disconnect on the left of the footer.
struct GitLabSetupSheet: View {
    var managing: String? = nil
    /// After a token was stored, so whoever shows the sheet can check the host again.
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @StateObject private var keyCatcher = ClipboardKeyCatcher()
    @State private var host = "gitlab.com"
    @State private var showSelfHosted = false
    @State private var token = ""
    @State private var note: String?
    @State private var checking = false
    @State private var check: GitLabTokenCheck?
    @State private var saved = false
    @State private var replacing = false

    private var normalizedHost: String { GitLabCredentials.normalize(host) ?? host }

    private var tokenPage: URL? {
        URL(string: "https://\(GitLabCredentials.normalize(host) ?? "gitlab.com")/-/user_settings/personal_access_tokens")
    }

    private var health: ConnectionHealth { checking ? .busy : GitLabStatus.health(check) }

    var body: some View {
        SetupSheet(
            title: "GitLab",
            subtitle: managing.map { GitLabStatus.detail(host: $0, check: checking ? nil : check) } ?? tr("gitlab.hint"),
            status: managing != nil ? health : nil
        ) {
            ServiceTile(domain: "gitlab.com", fallback: "key.fill", tint: NookTheme.iris, size: 48)
        } content: {
            if managing != nil { manageContent } else { connectContent }
        } footer: {
            if managing != nil {
                ConfirmedButton(tr("settings2.disconnect"), question: tr("connect.disconnectTitle", "GitLab"),
                                detail: tr("codeHost.removeDetail", managing ?? normalizedHost)) {
                    guard let managing else { return }
                    GitLabCredentials.remove(host: managing)
                    dismiss()
                }
            }
            Spacer()
            Button(tr("settings2.done")) { dismiss() }
                .sheetPrimaryButton()
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
            DisclosureGroup(isExpanded: $showSelfHosted) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    TextField(tr("gitlab.host"), text: $host, prompt: Text(tr("gitlab.host")).foregroundStyle(NookTheme.textTertiary))
                        .settingsField()
                        .frame(maxWidth: 260)
                    SettingNote(tr("gitlab.selfHostedDetail"))
                }
                .padding(.top, NookTheme.Spacing.sm)
            } label: {
                Text(tr("gitlab.selfHosted")).font(NookTheme.TextStyle.body)
            }
            StepAction(detail: tr("gitlab.step.tokenDetail"), button: tr("gitlab.openTokens")) {
                if let tokenPage { NSWorkspace.shared.open(tokenPage) }
                keyCatcher.watch()
            }
            SettingNote(tr("brain.key.autoPaste"))
        }
        SetupStep(number: 2, title: tr("gitlab.step.paste"), done: saved) {
            SecureField(tr("gitlab.token"), text: $token, prompt: Text("glpat-…").foregroundStyle(NookTheme.textTertiary))
                .settingsField()
                .onSubmit(save)
            if let note {
                SettingNote(note, tone: .error)
            }
        }
        // The token copied on GitLab's page, picked up on the way back and checked at once.
        .onDisappear { keyCatcher.stop() }
        // perf: `caught` is set once per copied key and reset right after, so every value is a new key.
        .onReceive(keyCatcher.$caught.compactMap { $0 }) { copied in
            token = copied
            keyCatcher.caught = nil
            save()
        }
        SetupCheckStep(number: 3, title: tr("gitlab.step.check"), detail: tr("gitlab.check.detail"), state: checkState,
                       check: runCheck, disabled: ConnectorField.clean(token).isEmpty && !saved)
    }

    // MARK: Manage

    @ViewBuilder
    private var manageContent: some View {
        // How it is doing is the pill beside the title; the parts are the same as every sheet for something linked.
        if check == .unreachable, !checking, let managing, let stored = GitLabCredentials.token(host: managing) {
            SheetPart(tr("sheet.part.status")) {
                HStack {
                    Text(GitLabStatus.detail(host: managing, check: check)).foregroundStyle(NookTheme.textSecondary)
                    Spacer()
                    Button(tr("connector.retry")) { Task { await verify(stored) } }
                }
            }
        }
        SheetPart(tr("settings2.service.keyTitle")) {
            if replacing || check == .rejected {
                tokenField
            } else {
                HStack {
                    Label(tr("settings2.service.keySafe"), icon: "lock.fill")
                        .foregroundStyle(NookTheme.textSecondary)
                    Spacer()
                    Button(tr("settings2.service.replaceKey")) { withAnimation { replacing = true } }
                }
            }
        }
    }

    // MARK: Token

    private var tokenField: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            SecureField(tr("gitlab.token"), text: $token, prompt: Text("glpat-…").foregroundStyle(NookTheme.textTertiary))
                .settingsField()
                .onSubmit(save)
            HStack {
                Button { pasteFromClipboard() } label: {
                    Label(tr("button.pasteClipboard"), icon: "doc.on.clipboard")
                }
                .buttonStyle(.nookProminent)
                Button(tr("button.save"), action: save)
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                Spacer()
            }
            if let note {
                SettingNote(note, tone: .error)
            }
        }
    }

    /// The last step's state, from the check of the token that was pasted.
    private var checkState: SetupCheckState {
        if checking { return .checking }
        switch check {
        case .valid(let username): return .passed(tr("gitlab.checkOK", username, normalizedHost))
        case .rejected: return .failed(tr("gitlab.rejected"))
        case .unreachable: return .failed(tr("gitlab.unreachable", normalizedHost))
        case nil: return .idle
        }
    }

    // MARK: Actions

    /// The check step's button: checks and saves the pasted token, or checks the saved one again.
    private func runCheck() {
        if !ConnectorField.clean(token).isEmpty {
            save()
        } else if saved, let stored = GitLabCredentials.token(host: normalizedHost) {
            Task { await verify(stored) }
        }
    }

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
            // Announced once, when a new host was added; replacing a token is shown by the row's own line.
            if managing == nil, !saved { ToastCenter.shared.success(tr("connection.added", "GitLab")) }
            saved = true
            replacing = false
            onSaved()
        }
    }

    private func verify(_ candidate: String) async {
        checking = true
        check = await GitLabCredentials.check(host: managing ?? host, token: candidate)
        checking = false
    }
}
