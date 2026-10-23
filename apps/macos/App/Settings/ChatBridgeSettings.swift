import SwiftUI
import AppKit
import Security

/// Settings › Chats › Telegram: the app id and hash from my.telegram.org, then logging in as on a new device (your
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
            keysButton
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
            StatusRow(title: tr("chats.telegram.connected", telegram.account ?? "Telegram"),
                      detail: tr("chats.telegram.connectedDetail"), state: .done) {
                Button(tr("chats.telegram.logOut")) { telegram.logOut() }
            }
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

    private var keysButton: some View {
        Button(tr("chats.telegram.changeKeys")) {
            Keychain.remove(TelegramBridge.apiIDAccount)
            Keychain.remove(TelegramBridge.apiHashAccount)
            telegram.stop()
            telegram.resume()
        }
        .buttonStyle(.link)
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

/// Settings › Chats › Teams: every account you signed in with a code on Microsoft's own page, and a button to add one
/// more. Nook signs in as its own app, so signing in is all it takes.
struct TeamsSettingsRows: View {
    @ObservedObject var teams: TeamsBridge
    /// Why the last read failed, if it did for every account.
    let problem: String?
    let onSignedIn: () -> Void
    @ObservedObject private var web = TeamsWebSession.shared

    var body: some View {
        if let session = web.session {
            let title = session.name.isEmpty ? "Teams" : session.name
            if let why = teams.problems[TeamsBridge.webID] {
                StatusRow(title: tr("chats.teams.connected", title), detail: why, state: .error) {
                    Button(tr("chats.teams.signInAgainButton")) { signInOnWeb() }
                    Button(tr("chats.teams.signOut")) { web.signOut() }
                }
            } else {
                StatusRow(title: tr("chats.teams.connected", title), detail: tr("chats.teams.web.connectedDetail"), state: .done) {
                    Button(tr("chats.teams.signOut")) { web.signOut() }
                }
            }
        }
        ForEach(teams.accounts) { account in
            let title = account.name.isEmpty ? (account.email.isEmpty ? "Teams" : account.email) : account.name
            if let why = teams.problems[account.id] {
                StatusRow(title: tr("chats.teams.connected", title), detail: why, state: .error) {
                    Button(tr("chats.teams.signInAgainButton")) { teams.signIn() }
                    Button(tr("chats.teams.signOut")) { teams.signOut(account.id) }
                }
            } else {
                StatusRow(title: tr("chats.teams.connected", title),
                          detail: account.email.isEmpty || account.email == title ? tr("chats.teams.connectedDetail") : account.email,
                          state: .done) {
                    Button(tr("chats.teams.signOut")) { teams.signOut(account.id) }
                }
            }
        }
        if let problem, teams.problems.isEmpty, !teams.accounts.isEmpty {
            StatusRow(title: tr("chats.teams.problem"), detail: problem, state: .error) { EmptyView() }
        }
        if web.session == nil {
            HStack {
                SettingLabel(tr("chats.teams.web.signIn"), detail: tr("chats.teams.web.signInDetail"))
                Spacer()
                Button(tr("chats.teams.signIn")) { signInOnWeb() }
                    .buttonStyle(.borderedProminent)
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

    private func signInOnWeb() {
        web.signIn(title: tr("chats.link.browser.title", "Teams")) { onSignedIn() }
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

/// Settings › Chats › Linked chats: the token of the chat app's local API on this Mac (`BeeperBridge`), whether its
/// live line is up, which apps come in through it and what Nook can do in their chats. Named after what it does, not
/// after the app behind it.
struct BeeperSettingsRows: View {
    @ObservedObject var capture: ChatCaptureService
    @ObservedObject private var linked = ChatCaptureService.shared.beeperBridge
    @State private var token = ""
    @State private var saved = BeeperBridge.beeperToken != nil

    var body: some View {
        if WhatsAppSettings.enabled && WhatsAppSettings.gateway == .beeper {
            // Its chats already come in through the WhatsApp link, with answering in place.
            StatusRow(title: tr("chats.beeper.viaGateway"), detail: tr("chats.beeper.viaGatewayDetail"), state: .done) { EmptyView() }
        } else {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                SettingLabel(tr("chats.beeper.token"), detail: tr("chats.beeper.tokenDetail"))
                HStack(spacing: NookTheme.Spacing.sm) {
                    SecureField("", text: $token, prompt: Text(saved ? "••••••••" : tr("chats.beeper.token")))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .onSubmit { save() }
                    Button(tr("chats.slack.save")) { save() }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                    if saved {
                        Button(tr("chats.slack.disconnect")) {
                            Keychain.remove(BeeperBridge.tokenAccount)
                            saved = false
                            capture.beeperBridge.reset()
                            capture.bridgeChanged(capture.beeperBridge.app)
                        }
                    }
                }
            }
            if saved {
                if let problem = capture.bridgeProblems[capture.beeperBridge.app] {
                    StatusRow(title: tr("chats.beeper.problem"), detail: problem, state: .error) { EmptyView() }
                } else if capture.bridged.contains(capture.beeperBridge.app) {
                    StatusRow(title: tr("chats.beeper.connected"), detail: connectedDetail, state: .done) { EmptyView() }
                    StatusRow(title: tr(linked.isLive ? "chats.linked.live" : "chats.linked.polling"),
                              detail: tr(linked.isLive ? "chats.linked.liveDetail" : "chats.linked.pollingDetail"),
                              state: linked.isLive ? .done : .warning) { EmptyView() }
                    SettingNote(tr("chats.linked.actions"))
                }
            }
        }
    }

    /// Which apps come in, by their own names ("Linked: Instagram, Signal"), once their chats were read.
    private var connectedDetail: String {
        let names = Set(linked.chats.values.map(\.app)).compactMap { MessagingApps.app(id: $0)?.name }.sorted()
        return names.isEmpty ? tr("chats.beeper.connectedDetail") : tr("chats.linked.apps", names.joined(separator: ", "))
    }

    private func save() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, Keychain.write(value, account: BeeperBridge.tokenAccount) == errSecSuccess else {
            ToastCenter.shared.error(tr("chats.slack.notSaved"))
            return
        }
        token = ""
        saved = true
        capture.setSource(capture.beeperBridge.app, on: true)
        capture.beeperBridge.reset()
        capture.bridgeChanged(capture.beeperBridge.app)
    }
}

/// Slack with its history: signing in on slack.com, as with Teams, or a user token of an app of your own (kept in the
/// Keychain), and whether reading works. In Slack's sheet on Settings › Chats.
struct SlackSettingsRows: View {
    let setCollecting: (Bool) -> Void
    @ObservedObject private var capture = ChatCaptureService.shared
    @ObservedObject private var web = SlackWebSession.shared
    @State private var slackToken = ""
    @State private var slackSet = SlackBridge.token != nil
    @State private var usesToken = SlackBridge.token != nil

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            if let auth = web.auth {
                let title = auth.team.isEmpty ? "Slack" : auth.team
                if let problem = capture.bridgeProblems[capture.slackBridge.app] {
                    StatusRow(title: tr("chats.teams.connected", title), detail: problem, state: .error) {
                        Button(tr("chats.teams.signInAgainButton")) { signIn() }
                        Button(tr("chats.teams.signOut")) { signOut() }
                    }
                } else {
                    StatusRow(title: tr("chats.teams.connected", title),
                              detail: capture.enabled ? tr("chats.slack.web.connectedDetail") : tr("chats.slack.collectOff"),
                              state: capture.enabled ? .done : .todo) {
                        Button(tr("chats.teams.signOut")) { signOut() }
                    }
                }
            } else if !slackSet {
                HStack {
                    SettingLabel(tr("chats.slack.web.signIn"), detail: tr("chats.slack.web.signInDetail"))
                    Spacer()
                    Button(tr("chats.slack.signIn")) { signIn() }
                        .buttonStyle(.borderedProminent)
                        .disabled(web.isSigningIn)
                }
            }
            if web.auth == nil {
                DisclosureGroup(isExpanded: $usesToken) {
                    tokenRows
                } label: {
                    SettingLabel(tr("chats.slack.useToken"), detail: tr("chats.slack.useTokenDetail"))
                }
            }
        }
    }

    @ViewBuilder
    private var tokenRows: some View {
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
                    Button(tr("chats.slack.disconnect")) {
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

    private func signIn() {
        web.signIn(title: tr("chats.link.browser.title", "Slack")) { linked() }
    }

    private func signOut() {
        web.signOut()
        capture.slackTokenChanged()
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
