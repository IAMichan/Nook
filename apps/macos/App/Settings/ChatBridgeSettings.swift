import SwiftUI
import AppKit
import Security

/// Settings › Connections › Telegram: the app id and hash from my.telegram.org, then logging in as on a new device (your
/// number, the code Telegram sends, your password when you set one). Telegram's own library has to be in this build.
struct TelegramSettingsRows: View {
    @ObservedObject var telegram: TelegramBridge
    let onReady: () -> Void
    @State private var apiID = ""
    @State private var apiHash = ""
    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""

    var body: some View {
        switch telegram.state {
        case .noLibrary:
            StatusRow(title: tr("chats.telegram.noLibrary"), detail: tr("chats.telegram.noLibraryDetail"), state: .todo) {
                Button(tr("chats.telegram.checkAgain")) { telegram.resume() }
            }
        case .noKeys:
            keys
        case .stopped, .failed:
            if case .failed(let why) = telegram.state {
                StatusRow(title: tr("chats.telegram.failed"), detail: why, state: .error) { EmptyView() }
            }
            HStack {
                SettingLabel(tr("chats.telegram.connect"), detail: tr("chats.telegram.connectDetail"))
                Spacer()
                Button(tr("chats.telegram.connect")) { telegram.start() }
            }
            TelegramKeysButton(telegram: telegram)
        case .starting:
            HStack(spacing: NookTheme.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(tr("chats.telegram.starting")).foregroundStyle(NookTheme.textSecondary)
            }
        case .login(let step):
            login(step)
        }
    }

    @ViewBuilder
    private func login(_ step: TelegramData.Authorization) -> some View {
        switch step {
        case .phone:
            field(tr("chats.telegram.phone"), detail: tr("chats.telegram.phoneDetail"), text: $phone, prompt: "+31 6 12345678",
                  button: tr("chats.telegram.sendCode")) { telegram.sendPhone(phone) }
        case .code(let number):
            field(tr("chats.telegram.code"), detail: tr("chats.telegram.codeDetail", number), text: $code, prompt: "12345",
                  button: tr("chats.telegram.logIn")) { telegram.sendCode(code) }
        case .password(let hint):
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                SettingLabel(tr("chats.telegram.password"),
                             detail: hint.isEmpty ? tr("chats.telegram.passwordDetail") : tr("chats.telegram.passwordHint", hint))
                HStack(spacing: NookTheme.Spacing.sm) {
                    SecureField("", text: $password).labelsHidden().textFieldStyle(.roundedBorder)
                        .onSubmit { telegram.sendPassword(password) }
                    Button(tr("chats.telegram.logIn")) { telegram.sendPassword(password) }.disabled(password.isEmpty)
                }
                loginError
            }
        case .ready:
            ChatLinkedAccountRow(app: telegram.app, title: telegram.account ?? "Telegram", detail: tr("chats.telegram.connectedDetail"),
                                 signOut: { telegram.logOut() })
                .onAppear(perform: onReady)
        case .loggingOut, .closed:
            Text(tr("chats.telegram.loggingOut")).foregroundStyle(NookTheme.textSecondary)
        case .parameters, .encryptionKey:
            ProgressView().controlSize(.small)
        case .other:
            StatusRow(title: tr("chats.telegram.failed"), detail: tr("chats.telegram.useApp"), state: .warning) { EmptyView() }
        }
    }

    private func field(_ title: String, detail: String, text: Binding<String>, prompt: String, button: String,
                       action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            SettingLabel(title, detail: detail)
            HStack(spacing: NookTheme.Spacing.sm) {
                TextField("", text: text, prompt: Text(prompt)).labelsHidden().textFieldStyle(.roundedBorder).onSubmit(action)
                Button(button, action: action).disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            loginError
        }
    }

    @ViewBuilder
    private var loginError: some View {
        if let error = telegram.loginError {
            SettingNote(error, tone: .error)
        }
    }

    /// The app id and hash: Telegram gives every app its own at my.telegram.org › API development tools.
    private var keys: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            SettingLabel(tr("chats.telegram.keys"), detail: tr("chats.telegram.keysDetail"))
            HStack(spacing: NookTheme.Spacing.sm) {
                TextField("", text: $apiID, prompt: Text("api_id")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 110)
                SecureField("", text: $apiHash, prompt: Text("api_hash")).labelsHidden().textFieldStyle(.roundedBorder)
                Button(tr("chats.slack.save")) { saveKeys() }
                    .disabled(Int(apiID.trimmingCharacters(in: .whitespaces)) == nil || apiHash.trimmingCharacters(in: .whitespaces).count < 16)
            }
            Button(tr("chats.telegram.openSite")) {
                if let url = URL(string: "https://my.telegram.org/apps") { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.link)
        }
    }

    private func saveKeys() {
        let id = apiID.trimmingCharacters(in: .whitespaces)
        let hash = apiHash.trimmingCharacters(in: .whitespaces)
        guard Int(id) != nil, Keychain.write(id, account: TelegramBridge.apiIDAccount) == errSecSuccess,
              Keychain.write(hash, account: TelegramBridge.apiHashAccount) == errSecSuccess else {
            ToastCenter.shared.error(tr("chats.slack.notSaved"))
            return
        }
        apiID = ""
        apiHash = ""
        telegram.start()
    }
}

/// Other keys from my.telegram.org: the ones Nook keeps go, and Telegram asks for new ones. In Telegram's sheet while it is
/// not running, and under Advanced once it is.
struct TelegramKeysButton: View {
    @ObservedObject var telegram: TelegramBridge

    var body: some View {
        Button(tr("chats.telegram.changeKeys")) {
            Keychain.remove(TelegramBridge.apiIDAccount)
            Keychain.remove(TelegramBridge.apiHashAccount)
            telegram.stop()
            telegram.resume()
        }
        .buttonStyle(.link)
    }
}

/// Settings › Connections › Teams: every account you signed in with on teams.microsoft.com (or with a code on Microsoft's own
/// page), and a button to add one more. Signing in is all it takes.
struct TeamsSettingsRows: View {
    @ObservedObject var teams: TeamsBridge
    /// Why the last read failed, if it did for every account.
    let problem: String?
    let onSignedIn: () -> Void
    @ObservedObject private var web = TeamsWebSession.shared

    var body: some View {
        ForEach(web.accounts) { account in
            let title = account.label.isEmpty ? "Teams" : account.label
            let detail = account.session.email.flatMap { $0 == title ? nil : $0 } ?? tr("chats.teams.web.connectedDetail")
            let id = TeamsBridge.webID(account.id)
            ChatLinkedAccountRow(app: teams.app, title: title, detail: detail, problem: teams.problems[id],
                                 signedOut: teams.signedOutAccounts.contains(id),
                                 signInAgain: { signInOnWeb(account.id) }, signOut: { web.signOut(account.id) })
        }
        ForEach(teams.accounts) { account in
            let title = account.name.isEmpty ? (account.email.isEmpty ? "Teams" : account.email) : account.name
            let detail = account.email.isEmpty || account.email == title ? tr("chats.teams.connectedDetail") : account.email
            ChatLinkedAccountRow(app: teams.app, title: title, detail: detail, problem: teams.problems[account.id],
                                 signedOut: teams.signedOutAccounts.contains(account.id),
                                 signInAgain: { teams.signIn() }, signOut: { teams.signOut(account.id) })
        }
        if let problem, teams.problems.isEmpty, !teams.accounts.isEmpty {
            StatusRow(title: tr("chats.teams.problem"), detail: problem, state: .error) { EmptyView() }
        }
        if let why = web.problem, !web.isSigningIn {
            StatusRow(title: tr("chats.teams.failed"), detail: why, state: .error) { EmptyView() }
        }
        HStack {
            if web.accounts.isEmpty {
                SettingLabel(tr("chats.teams.web.signIn"), detail: tr("chats.teams.web.signInDetail"))
                Spacer()
                Button(tr("chats.teams.signIn")) { signInOnWeb() }
                    .buttonStyle(.borderedProminent)
                    .disabled(web.isSigningIn)
            } else {
                SettingLabel(tr("chats.teams.addAccount"), detail: tr("chats.teams.web.addAccountDetail"))
                Spacer()
                Button(tr("chats.teams.addAccount")) { signInOnWeb() }
                    .disabled(web.isSigningIn)
            }
        }
        // With Nook's own app in Microsoft Entra, accounts can also be added through Microsoft Graph with a code.
        if TeamsBridge.clientID != nil {
            signIn
                // A new account reads right away instead of at the next turn.
                .onChange(of: teams.accounts.map(\.id)) { _, _ in onSignedIn() }
        }
    }

    /// Signs in again for an account, or (with no id) adds one in a window of its own.
    private func signInOnWeb(_ id: String? = nil) {
        web.signIn(id, title: tr("chats.link.browser.title", "Teams")) { onSignedIn() }
    }

    @ViewBuilder
    private var signIn: some View {
        switch teams.state {
        case .code(let code):
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                SettingLabel(tr("chats.teams.typeCode"), detail: tr("chats.teams.typeCodeDetail", code.verificationURL.host ?? ""))
                HStack(spacing: NookTheme.Spacing.sm) {
                    Text(code.userCode)
                        .font(NookTheme.mono(18, .semibold))
                        .textSelection(.enabled)
                    Button(tr("chats.teams.copyCode")) { Pasteboard.copy(code.userCode) }
                    Button(tr("chats.teams.openPage")) { NSWorkspace.shared.open(code.verificationURL) }
                    Spacer()
                    ProgressView().controlSize(.small)
                    Button(tr("chats.teams.cancel")) { teams.cancelSignIn() }
                }
            }
        case .noClient:
            EmptyView()
        case .idle, .failed:
            if case .failed(let why) = teams.state {
                StatusRow(title: tr("chats.teams.failed"), detail: why, state: .error) { EmptyView() }
            }
            HStack {
                if teams.accounts.isEmpty {
                    SettingLabel(tr("chats.teams.signIn"), detail: tr("chats.teams.signInDetail"))
                } else {
                    SettingLabel(tr("chats.teams.addAccount"), detail: tr("chats.teams.addAccountDetail"))
                }
                Spacer()
                Button(teams.accounts.isEmpty ? tr("chats.teams.signIn") : tr("chats.teams.addAccount")) { teams.signIn() }
            }
        }
    }
}

/// Slack with its history: signing in on slack.com, as with Teams, or a user token of an app of your own (kept in the
/// Keychain), and whether reading works. In Slack's sheet on Settings › Connections.
struct SlackSettingsRows: View {
    let setCollecting: (Bool) -> Void
    /// Whether the token of an app of your own is offered here (folded); a linked Slack's sheet has it under Advanced.
    var showsToken = true
    @ObservedObject private var capture = ChatCaptureService.shared
    @ObservedObject private var web = SlackWebSession.shared
    @State private var usesToken = SlackBridge.token != nil

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            if let auth = web.auth {
                ChatLinkedAccountRow(app: capture.slackBridge.app, title: auth.team.isEmpty ? "Slack" : auth.team,
                                     detail: tr("chats.slack.web.connectedDetail"), signInAgain: { signIn() }, signOut: { signOut() })
            } else if SlackBridge.token != nil, !showsToken {
                // Linked with a token of your own: the token itself is under Advanced, where a new one mends a lost one.
                ChatLinkedAccountRow(app: capture.slackBridge.app, title: tr("chats.slack.connected"),
                                     detail: tr("chats.slack.connectedDetail"))
            } else if SlackBridge.token == nil {
                HStack {
                    SettingLabel(tr("chats.slack.web.signIn"), detail: tr("chats.slack.web.signInDetail"))
                    Spacer()
                    Button(tr("chats.slack.signIn")) { signIn() }
                        .buttonStyle(.borderedProminent)
                        .disabled(web.isSigningIn)
                }
            }
            if web.auth == nil, showsToken {
                DisclosureGroup(isExpanded: $usesToken) {
                    SlackTokenRows(setCollecting: setCollecting)
                } label: {
                    SettingLabel(tr("chats.slack.useToken"), detail: tr("chats.slack.useTokenDetail"))
                }
            }
        }
    }

    private func signIn() {
        web.signIn(title: tr("chats.link.browser.title", "Slack")) {
            capture.setSource(capture.slackBridge.app, on: true)
            if !capture.enabled { setCollecting(true) }
            capture.slackTokenChanged()
        }
    }

    private func signOut() {
        web.signOut()
        capture.slackTokenChanged()
    }
}

/// Slack through a user token of an app of your own (kept in the Keychain), and whether reading with it works.
struct SlackTokenRows: View {
    let setCollecting: (Bool) -> Void
    @ObservedObject private var capture = ChatCaptureService.shared
    @State private var slackToken = ""
    @State private var slackSet = SlackBridge.token != nil

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            SettingLabel(tr("chats.slack.token"), detail: tr("chats.slack.tokenDetail"))
            HStack(spacing: NookTheme.Spacing.sm) {
                SecureField("", text: $slackToken, prompt: Text(slackSet ? "••••••••" : "xoxp-…"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .onSubmit { save() }
                Button(tr("chats.slack.save")) { save() }
                    .disabled(!slackToken.trimmingCharacters(in: .whitespaces).hasPrefix("xox"))
                if slackSet {
                    ConfirmedButton(tr("chats.slack.disconnect"), question: tr("confirm.logout", "Slack"),
                                    detail: tr("confirm.keychain.detail")) {
                        Keychain.remove(SlackBridge.tokenAccount)
                        slackSet = false
                        capture.slackTokenChanged()
                    }
                }
            }
            if slackSet {
                if let problem = capture.bridgeProblems[capture.slackBridge.app] {
                    StatusRow(title: tr("chats.slack.problem"), detail: problem, state: .error) { EmptyView() }
                } else if capture.bridged.contains(capture.slackBridge.app) {
                    StatusRow(title: tr("chats.slack.connected"), detail: tr("chats.slack.connectedDetail"), state: .done) { EmptyView() }
                } else if !capture.enabled {
                    StatusRow(title: tr("chats.slack.connected"), detail: tr("chats.slack.collectOff"), state: .todo) { EmptyView() }
                }
            }
            SettingNote(tr("chats.slack.footer"))
        }
        .padding(.top, NookTheme.Spacing.xs)
    }

    /// Slack is linked: its chats are switched on and read right away.
    private func linked() {
        capture.setSource(capture.slackBridge.app, on: true)
        if !capture.enabled { setCollecting(true) }
        capture.slackTokenChanged()
    }

    private func save() {
        let token = slackToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("xox") else { return }
        guard Keychain.write(token, account: SlackBridge.tokenAccount) == errSecSuccess else {
            ToastCenter.shared.error(tr("chats.slack.notSaved"))
            return
        }
        slackToken = ""
        slackSet = true
        linked()
    }
}
