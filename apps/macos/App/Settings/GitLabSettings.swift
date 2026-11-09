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

/// Not connected yet: three numbered steps (make a token, paste it, Nook checks it). Connected (`managing` a host): its
/// state and replacing the token, shown inside its opened `GitLabHostRow` (embedded, so without header and footer; the
/// row's "…" menu disconnects), or in a window of its own with Disconnect in the footer.
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
    @State private var confirmDisconnect = false

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
            if let managing {
                if confirmDisconnect {
                    Text(tr("connect.disconnectTitle", "GitLab"))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                    Button(tr("button.cancel")) { confirmDisconnect = false }
                        .keyboardShortcut(.cancelAction)
                    Button(tr("settings2.disconnect"), role: .destructive) {
                        GitLabCredentials.remove(host: managing)
                        dismiss()
                    }
                } else {
                    Button(tr("settings2.disconnect"), role: .destructive) { confirmDisconnect = true }
                }
            }
            Spacer()
            Button(tr("settings2.done")) { dismiss() }
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
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(isExpanded: $showSelfHosted) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    TextField(tr("gitlab.host"), text: $host)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    SettingNote(tr("gitlab.selfHostedDetail"))
                }
                .padding(.top, NookTheme.Spacing.sm)
            } label: {
                Text(tr("gitlab.selfHosted")).font(NookTheme.TextStyle.body)
            }
            Button {
                if let tokenPage { NSWorkspace.shared.open(tokenPage) }
                keyCatcher.watch()
            } label: {
                Label(tr("gitlab.openTokens"), systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            SettingNote(tr("brain.key.autoPaste"))
        }
        SetupStep(number: 2, title: tr("gitlab.step.paste"), done: saved) {
            tokenField
        }
        // The token copied on GitLab's page, picked up on the way back and checked at once.
        .onDisappear { keyCatcher.stop() }
        // perf: `caught` is set once per copied key and reset right after, so every value is a new key.
        .onReceive(keyCatcher.$caught.compactMap { $0 }) { copied in
            token = copied
            keyCatcher.caught = nil
            save()
        }
        SetupStep(number: 3, title: tr("gitlab.step.check"), done: check?.isValid ?? false) {
            result
        }
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
                    Label(tr("settings2.service.keySafe"), systemImage: "lock.fill")
                        .foregroundStyle(NookTheme.textSecondary)
                    Spacer()
                    Button(tr("settings2.service.replaceKey")) { withAnimation { replacing = true } }
                }
            }
        }
    }

    // MARK: Token and result

    private var tokenField: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
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
                SettingNote(note, tone: .error)
            }
        }
    }

    @ViewBuilder
    private var result: some View {
        if checking {
            HStack(spacing: NookTheme.Spacing.md) {
                ProgressView().controlSize(.small)
                Text(tr("settings2.step.checkBusy")).font(NookTheme.TextStyle.body)
            }
        } else {
            switch check {
            case .valid(let username):
                Label(tr("gitlab.checkOK", username, normalizedHost), systemImage: "checkmark.seal.fill")
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(ConnectionHealth.working.color)
            case .rejected:
                Label(tr("gitlab.rejected"), systemImage: "exclamationmark.triangle.fill")
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(ConnectionHealth.needsYou.color)
                    .fixedSize(horizontal: false, vertical: true)
            case .unreachable:
                Label(tr("gitlab.unreachable", normalizedHost), systemImage: "wifi.exclamationmark")
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(ConnectionHealth.broken.color)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                Text(tr("settings2.step.checkWaiting"))
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textSecondary)
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
