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
            StatusRow(title: tr("chats.teams.unavailable"), detail: tr("chats.teams.unavailableDetail"), state: .todo) { EmptyView() }
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

/// Settings › Chats › Beeper: the token of Beeper Desktop's local API, for every network linked in Beeper.
struct BeeperSettingsRows: View {
    @ObservedObject var capture: ChatCaptureService
    @State private var token = ""
    @State private var saved = BeeperBridge.token != nil

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
                    StatusRow(title: tr("chats.beeper.connected"), detail: tr("chats.beeper.connectedDetail"), state: .done) { EmptyView() }
                }
            }
        }
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

/// Where logging in to an app from its row stands.
enum LoginStep { case signedOut, waiting, signedIn }

/// An app in Settings › Chats that Nook reads after you log in to it from its own row: a Log in button until you did,
/// then its switch, with Log out beside it. While the sign-in runs, the row says so (with Teams' code to type).
struct LoginSourceRow<Label: View, Waiting: View>: View {
    let step: LoginStep
    @Binding var isOn: Bool
    let logIn: () -> Void
    let cancel: () -> Void
    let logOut: () -> Void
    @ViewBuilder let label: () -> Label
    @ViewBuilder let waiting: () -> Waiting

    var body: some View {
        switch step {
        case .signedIn:
            Toggle(isOn: $isOn) {
                HStack(spacing: NookTheme.Spacing.md) {
                    label()
                    Spacer(minLength: NookTheme.Spacing.sm)
                    Button(tr("chats.login.logOut"), action: logOut)
                        .buttonStyle(.link)
                }
            }
        case .waiting:
            HStack(spacing: NookTheme.Spacing.md) {
                label()
                Spacer(minLength: NookTheme.Spacing.sm)
                waiting()
                ProgressView().controlSize(.small)
                Button(tr("chats.teams.cancel"), action: cancel)
            }
        case .signedOut:
            HStack(spacing: NookTheme.Spacing.md) {
                label()
                Spacer(minLength: NookTheme.Spacing.sm)
                Button(tr("chats.login.button"), action: logIn)
            }
        }
    }
}

/// Instagram's row: Log in opens instagram.com beside the chat, and the row waits until you signed in there.
/// Once signed in and switched on, the row says whether reading works: how many chats came in, or why none did.
struct InstagramSourceRow<Label: View>: View {
    @ObservedObject var bridge: InstagramBridge
    @Binding var isOn: Bool
    /// Why the last read failed, if it did.
    let problem: String?
    /// How many Instagram chats the Chats tab has, once a read worked; nil before.
    let loaded: Int?
    let logIn: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            LoginSourceRow(step: step, isOn: $isOn, logIn: logIn, cancel: { bridge.cancelSignIn() },
                           logOut: { Task { await bridge.signOut() } }, label: label) {
                Text(tr("chats.login.waiting"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
            }
            if step == .signedIn, isOn { status }
        }
        // A sign-in made meanwhile elsewhere in Nook (Instagram beside the chat) shows here too.
        .task { await bridge.refresh() }
    }

    @ViewBuilder
    private var status: some View {
        if let problem {
            StatusRow(title: tr("chats.instagram.problem"), detail: problem, state: .error) { EmptyView() }
        } else if let loaded {
            StatusRow(title: tr("chats.instagram.loaded", loaded), detail: tr("chats.instagram.loadedDetail"), state: .done) { EmptyView() }
        } else {
            StatusRow(title: tr("chats.instagram.loading"), detail: tr("chats.instagram.loadingDetail"), state: .todo) { EmptyView() }
        }
    }

    private var step: LoginStep {
        switch bridge.state {
        case .signedOut: return .signedOut
        case .waiting: return .waiting
        case .signedIn: return .signedIn
        }
    }
}

/// Teams' row: Log in signs in with a code on Microsoft's own page; the code shows in the row while Nook waits.
struct TeamsSourceRow<Label: View>: View {
    @ObservedObject var teams: TeamsBridge
    @Binding var isOn: Bool
    @ViewBuilder let label: () -> Label

    var body: some View {
        LoginSourceRow(step: step, isOn: $isOn, logIn: logIn, cancel: { teams.cancelSignIn() }, logOut: logOut, label: label) {
            if case .code(let code) = teams.state {
                Text(code.userCode)
                    .font(NookTheme.mono(13, .semibold))
                    .textSelection(.enabled)
                Button(tr("chats.teams.copyCode")) { Pasteboard.copy(code.userCode) }
            }
        }
    }

    private var step: LoginStep {
        if teams.isReady { return .signedIn }
        if case .code = teams.state { return .waiting }
        return .signedOut
    }

    private func logIn() {
        guard TeamsBridge.clientID != nil else {
            ToastCenter.shared.error(tr("chats.teams.unavailable"), detail: tr("chats.teams.unavailableDetail"))
            return
        }
        teams.signIn()
    }

    private func logOut() {
        for account in teams.accounts { teams.signOut(account.id) }
    }
}
