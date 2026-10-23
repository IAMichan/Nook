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
    @State private var clientID = ""

    var body: some View {
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
        signIn
            // A new account reads right away instead of at the next turn.
            .onChange(of: teams.accounts.map(\.id)) { _, _ in onSignedIn() }
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
            clientField
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

    /// A build without Nook's own app in Microsoft Entra: the id of one you registered, pasted once.
    private var clientField: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            SettingLabel(tr("chats.teams.unavailable"), detail: tr("chats.teams.unavailableDetail"))
            HStack(spacing: NookTheme.Spacing.sm) {
                TextField("", text: $clientID, prompt: Text("00000000-0000-0000-0000-000000000000"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveClient() }
                Button(tr("chats.slack.save")) { saveClient() }
                    .disabled(UUID(uuidString: clientID.trimmingCharacters(in: .whitespaces)) == nil)
            }
            Button(tr("chats.teams.openEntra")) {
                if let url = URL(string: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
        }
    }

    private func saveClient() {
        guard teams.setClientID(clientID) else {
            ToastCenter.shared.error(tr("chats.slack.notSaved"))
            return
        }
        clientID = ""
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

/// Slack with its history: a user token, kept in the Keychain, and whether reading with it works. In Slack's sheet on
/// Settings › Chats.
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
        capture.setSource(capture.slackBridge.app, on: true)
        if !capture.enabled { setCollecting(true) }
        capture.slackTokenChanged()
    }
}
