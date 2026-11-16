import SwiftUI
import AppKit
import Security

/// Linking Telegram in numbered steps, in the order Telegram asks: the app id and hash from my.telegram.org, your phone
/// number, the code Telegram sends, and your password only when you set one. The current step shows its part of
/// `TelegramSettingsRows`; the check after them is the sheet's (`ChatLinkCheckStep`).
struct TelegramLinkSteps: View {
    @ObservedObject var telegram: TelegramBridge
    let onReady: () -> Void

    /// How many steps there are now: one more while Telegram asks for your password.
    static func count(_ telegram: TelegramBridge) -> Int { stage(telegram) == 4 ? 4 : 3 }

    /// The current step: 1 the keys, 2 the phone number, 3 the code, 4 the password, 5 logged in.
    static func stage(_ telegram: TelegramBridge) -> Int {
        switch telegram.state {
        case .noLibrary, .noKeys: return 1
        case .stopped, .starting, .failed: return 2
        case .login(let step):
            switch step {
            case .code: return 3
            case .password: return 4
            case .ready: return 5
            case .parameters, .encryptionKey, .phone, .loggingOut, .closed, .other: return 2
            }
        }
    }

    var body: some View {
        let stage = Self.stage(telegram)
        SetupStep(number: 1, title: tr("chats.telegram.keys"), done: stage > 1) { current(stage == 1) }
            // Logged in: its chats are switched on and read right away.
            .onChange(of: telegram.isReady) { _, ready in if ready { onReady() } }
        SetupStep(number: 2, title: tr("chats.telegram.phone"), done: stage > 2) { current(stage == 2) }
        SetupStep(number: 3, title: tr("chats.telegram.code"), done: stage > 3) { current(stage == 3) }
        if stage == 4 {
            SetupStep(number: 4, title: tr("chats.telegram.password")) { current(true) }
        }
    }

    @ViewBuilder
    private func current(_ isCurrent: Bool) -> some View {
        if isCurrent {
            TelegramSettingsRows(telegram: telegram, inStep: true, onReady: onReady)
        }
    }
}

/// Telegram's link as it stands: the app id and hash from my.telegram.org, then logging in as on a new device (your
/// number, the code Telegram sends, your password when you set one), then the account. Telegram's own library has to be
/// in this build. Inside a numbered step (`inStep`) the step's title names the field, so only its line shows.
struct TelegramSettingsRows: View {
    @ObservedObject var telegram: TelegramBridge
    var inStep = false
    let onReady: () -> Void
    @State private var apiID = ""
    @State private var apiHash = ""
    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""

    var body: some View {
        switch telegram.state {
        case .noLibrary:
            StepAction(title: tr("chats.telegram.noLibrary"), detail: tr("chats.telegram.noLibraryDetail"),
                       button: tr("chats.telegram.checkAgain"), prominent: false) { telegram.resume() }
        case .noKeys:
            keys
        case .stopped, .failed:
            if case .failed(let why) = telegram.state {
                StatusRow(title: tr("chats.telegram.failed"), detail: why, state: .error) { EmptyView() }
            }
            StepAction(detail: tr("chats.telegram.connectDetail"), button: tr("chats.telegram.connect")) { telegram.start() }
            TelegramKeysButton(telegram: telegram)
        case .starting:
            BusyLine(tr("chats.telegram.starting"))
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
                heading(tr("chats.telegram.password"),
                        detail: hint.isEmpty ? tr("chats.telegram.passwordDetail") : tr("chats.telegram.passwordHint", hint))
                SecureField("", text: $password).labelsHidden().settingsField()
                    .onSubmit { telegram.sendPassword(password) }
                Button(tr("chats.telegram.logIn")) { telegram.sendPassword(password) }
                    .buttonStyle(.nookProminent)
                    .disabled(password.isEmpty)
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
            heading(title, detail: detail)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(NookTheme.textTertiary)).labelsHidden().settingsField().onSubmit(action)
            // The step's button, under its field.
            Button(button, action: action)
                .buttonStyle(.nookProminent)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            loginError
        }
    }

    /// What a field asks for: its name and line, or only the line inside a step whose title is the name.
    @ViewBuilder
    private func heading(_ title: String, detail: String) -> some View {
        if inStep {
            Text(detail)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            SettingLabel(title, detail: detail)
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
            heading(tr("chats.telegram.keys"), detail: tr("chats.telegram.keysDetail"))
            Button(tr("chats.telegram.openSite")) {
                if let url = URL(string: "https://my.telegram.org/apps") { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.nookLink)
            HStack(spacing: NookTheme.Spacing.sm) {
                TextField("", text: $apiID, prompt: Text("api_id").foregroundStyle(NookTheme.textTertiary)).labelsHidden().settingsField().frame(width: 110)
                SecureField("", text: $apiHash, prompt: Text("api_hash").foregroundStyle(NookTheme.textTertiary)).labelsHidden().settingsField()
                    .onSubmit { saveKeys() }
            }
            // The step's button, under its fields.
            Button(tr("chats.slack.save")) { saveKeys() }
                .buttonStyle(.nookProminent)
                .disabled(!keysValid)
        }
    }

    private var keysValid: Bool {
        Int(apiID.trimmingCharacters(in: .whitespaces)) != nil && apiHash.trimmingCharacters(in: .whitespaces).count >= 16
    }

    private func saveKeys() {
        guard keysValid else { return }
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
        Button(tr("chats.telegram.changeKeys")) { Self.reset(telegram) }
            .buttonStyle(.nookLink)
    }

    /// Forgets the keys Nook keeps, so Telegram asks for new ones.
    static func reset(_ telegram: TelegramBridge) {
        Keychain.remove(TelegramBridge.apiIDAccount)
        Keychain.remove(TelegramBridge.apiHashAccount)
        telegram.stop()
        telegram.resume()
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
        if web.accounts.isEmpty {
            StepAction(detail: tr("chats.teams.web.signInDetail"),
                       button: tr("chats.teams.signIn"), disabled: web.isSigningIn) { signInOnWeb() }
        } else {
            StepAction(detail: tr("chats.teams.web.addAccountDetail"), button: tr("chats.teams.addAccount"),
                       prominent: false, disabled: web.isSigningIn) { signInOnWeb() }
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
                // The code with its copy button, then what to do with it under them.
                HStack(spacing: NookTheme.Spacing.sm) {
                    Text(code.userCode)
                        .font(NookTheme.mono(18, .semibold))
                        .textSelection(.enabled)
                    Button(tr("chats.teams.copyCode")) { Pasteboard.copy(code.userCode) }
                }
                HStack(spacing: NookTheme.Spacing.sm) {
                    Button(tr("chats.teams.openPage")) { NSWorkspace.shared.open(code.verificationURL) }
                        .buttonStyle(.nookProminent)
                    Button(tr("chats.teams.cancel")) { teams.cancelSignIn() }
                    ProgressView().controlSize(.small)
                }
            }
        case .noClient:
            EmptyView()
        case .idle, .failed:
            if case .failed(let why) = teams.state {
                StatusRow(title: tr("chats.teams.failed"), detail: why, state: .error) { EmptyView() }
            }
            StepAction(detail: tr(teams.accounts.isEmpty ? "chats.teams.signInDetail" : "chats.teams.addAccountDetail"),
                       button: teams.accounts.isEmpty ? tr("chats.teams.signIn") : tr("chats.teams.addAccount"),
                       prominent: false) { teams.signIn() }
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
                StepAction(detail: tr("chats.slack.web.signInDetail"),
                           button: tr("chats.slack.signIn"), disabled: web.isSigningIn) { signIn() }
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
            SecureField("", text: $slackToken, prompt: Text(slackSet ? "••••••••" : "xoxp-…").foregroundStyle(NookTheme.textTertiary))
                .labelsHidden()
                .settingsField()
                .frame(maxWidth: .infinity)
                .onSubmit { save() }
            // Save under the field; disconnecting is its own line under the token's state, never beside Save.
            Button(tr("chats.slack.save")) { save() }
                .buttonStyle(.nookProminent)
                .disabled(!slackToken.trimmingCharacters(in: .whitespaces).hasPrefix("xox"))
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
            if slackSet {
                ConfirmedButton(tr("chats.slack.disconnect"), question: tr("confirm.logout", "Slack"),
                                detail: tr("confirm.keychain.detail")) {
                    Keychain.remove(SlackBridge.tokenAccount)
                    slackSet = false
                    capture.slackTokenChanged()
                }
            }
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
