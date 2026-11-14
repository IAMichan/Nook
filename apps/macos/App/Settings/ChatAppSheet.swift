import SwiftUI
import AppKit
import WebKit

/// Linking one chat app, or managing it once it is linked, in numbered steps. Nook links the apps it reads itself in its
/// own way, with nothing else needed: WhatsApp with a QR code from your phone, Teams with a code from Microsoft, Slack
/// with a token, Messages from this Mac, Snapchat from its website, mail from the Mail app with every account in it. Telegram, Instagram, Messenger, Signal, X and LinkedIn link through the chat
/// service on this Mac (Nook's own helper: your phone number and a code, logging in on the app's own website, or a QR
/// code), which is also offered as another way for the rest while it runs. A build without the helper
/// links Telegram itself, through TDLib.
struct ChatAppSheet: View {
    let app: String
    let setCollecting: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetEmbedded) private var embedded
    @ObservedObject private var capture = ChatCaptureService.shared
    @ObservedObject private var linker = ChatLinker.shared
    @ObservedObject private var linked = ChatCaptureService.shared.serviceBridge
    @State private var unlinking: ChatLinkData.Account?

    private var name: String { MessagingApps.app(id: app)?.name ?? app }
    private var site: String? { MessagingApps.app(id: app)?.site }
    private var network: ChatLinkData.Network? { linker.networks.first { $0.app == app } }
    private var ownWay: Bool { ChatAppsCatalog.ownWay.contains(app) }
    /// A login through the chat service of this app is under way.
    private var isLinking: Bool { linker.linking?.app == app && linker.session != nil }
    /// Linked: the sheet manages it in parts instead of walking through the steps that link it.
    private var isLinked: Bool { ChatAppStates.state(app)?.linked == true }

    var body: some View {
        SetupSheet(title: name, subtitle: subtitle, status: isLinked ? health : nil) {
            ServiceTile(domain: site, fallback: "bubble.left.and.bubble.right.fill", tint: NookTheme.iris, size: 48, source: app)
        } content: {
            if isLinked { manageParts } else { linkSteps }
        } footer: {
            if isLinking {
                Button(tr("chats.link.stop")) { Task { await linker.cancel() } }
            }
            Spacer()
            Button(tr("settings2.done")) {
                Task { if isLinking { await linker.cancel() } }
                dismiss()
            }
            .sheetPrimaryButton()
        }
        .confirmDelete($unlinking, question: { tr("chats.link.unlinkQuestion", $0.name) }, detail: tr("chats.link.unlinkDetail", name),
                       confirmTitle: tr("chats.link.unlink")) { account in
            guard let network else { return }
            Task { await linker.unlink(account, in: network) }
        }
        .task { await linker.refresh() }
        // Escape closes the sheet the way Done does; opened in a row there is no sheet to close.
        .onExitCommand {
            guard !embedded else { return }
            Task { if isLinking { await linker.cancel() } }
            dismiss()
        }
    }

    /// How the linked app is doing, from its accounts (`ChatAppStates`): an account that failed or needs signing in
    /// again shows here, never a fixed "Working".
    private var health: ConnectionHealth {
        switch ChatAppStates.state(app)?.status ?? .notLinked {
        case .connected: return .working
        case .connecting: return .busy
        case .expired: return .needsYou
        case .unreachable: return .broken
        case .off: return .off
        case .notLinked: return .notLinked
        }
    }

    // MARK: Managing a linked app

    /// Every linked app the same way: its accounts, what it does in Nook, then what is rarely needed, folded away.
    @ViewBuilder
    private var manageParts: some View {
        SheetPart(tr("chats.manage.accounts")) {
            if ownWay { ChatOwnAccounts(app: app, setCollecting: setCollecting) }
            if let network, !network.accounts.isEmpty {
                accounts(network)
                if isLinking {
                    ChatLinkSteps(network: network)
                } else if network.canLink {
                    Button(tr("chats.link.another")) { Task { await linker.link(network) } }
                }
            }
        }
        SheetPart(tr("chats.manage.inNook")) { ChatAppNoticeRows(app: app, setCollecting: setCollecting) }
        // Rarely needed, folded away last, each fold named for what it holds.
        if ChatOwnAdvanced.has(app) {
            SettingsFold(ChatOwnAdvanced.title(app)) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                    ChatOwnAdvanced(app: app, setCollecting: setCollecting)
                }
                .padding(.top, NookTheme.Spacing.sm)
            }
        }
        // Nook links it in its own way; the chat service on this Mac is the other way.
        if ownWay, linker.serviceRuns { serviceFold }
    }

    /// The chat service on this Mac as the other way to link an app Nook links itself: its own steps under a title that
    /// says so, so their numbers read as a flow of their own beside the app's.
    private var serviceFold: some View {
        SettingsFold(tr("chats.fold.viaService")) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                SettingNote(tr("chats.link.viaServiceDetail", name))
                serviceSteps
            }
            .padding(.top, NookTheme.Spacing.sm)
        }
    }

    // MARK: Linking an app

    /// The steps that link it, Nook's own first, then the chat service; until then its notifications can bring its chats.
    @ViewBuilder
    private var linkSteps: some View {
        if ownWay {
            ChatOwnLinkSteps(app: app, setCollecting: setCollecting)
        }
        if let network, !network.accounts.isEmpty {
            if ownWay { NookDivider() }
            accounts(network)
        }
        if linker.serviceRuns {
            if ownWay {
                NookDivider()
                serviceFold
            } else {
                serviceSteps
            }
        } else if !ownWay {
            // Not linkable in this Nook: still a step, in the same shape as every other app, that says so in plain
            // words and points at the way its chats come in anyway. What a developer would do sits behind the hover.
            SetupStep(number: 1, title: tr("chats.link.unavailableTitle", name)) {
                SettingNote(tr("chats.link.notYet", name, name))
                    .help(ChatHelper.apps.contains(app) && !ChatHelper.isBuilt ? tr("chats.link.helperMissing", name) : "")
            }
        }
        // Until it is linked, its chats come in by its notifications: switched here, as the overview shows no row.
        if capture.sources.apps.contains(where: { $0.id == app }) {
            SheetPart(tr("chats.manage.inNook")) {
                SettingToggle(tr("chats.link.notifications"), detail: tr("chats.settings.collectDetail"),
                              isOn: Binding(get: { capture.enabled && capture.sources.isOn(app) }, set: { on in
                                  capture.setSource(app, on: on)
                                  if on, !capture.enabled { setCollecting(true) }
                              }))
            }
        }
        // Then how Nook reads it and what is rarely needed, folded away last: the order of every connection sheet.
        if ownWay {
            // How Nook reads it, after the steps as on every connection sheet (only the apps that need saying).
            if let howItReads {
                SheetPart(tr("sheet.part.canDo")) { SettingNote(howItReads) }
            }
            // Rarely needed, folded away last, the same words as on the linked app.
            if let link = MessagingApps.known(app)?.ownLink {
                SettingsFold(ChatOwnAdvanced.title(app)) {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                        switch link {
                        case .whatsAppGateway: WhatsAppGatewayRows()
                        }
                    }
                    .padding(.top, NookTheme.Spacing.sm)
                }
            }
        }
    }

    /// What an app's link reads, for the apps where that is not obvious from its name.
    private var howItReads: String? {
        switch app {
        case "mail": return tr("chats.mail.howItReads")
        case "snapchat": return tr("chats.snapchat.howItReads")
        default: return nil
        }
    }

    private var subtitle: String {
        ChatAppStates.state(app)?.linked == true ? tr("chats.link.subtitleLinked", name) : tr("chats.link.subtitle", name)
    }

    // MARK: Accounts through the chat service

    @ViewBuilder
    private func accounts(_ network: ChatLinkData.Network) -> some View {
        ForEach(network.accounts) { account in
            ChatAccountRow(app: app, title: account.name,
                           detail: account.isConnected ? (linked.isLive ? tr("chats.linked.liveDetail") : tr("chats.service.connectedDetail"))
                               : (account.status ?? tr("chats.apps.reconnect")),
                           status: account.isConnected ? .connected : .expired) {
                if !account.isConnected, network.canLink {
                    Button(tr("chats.apps.reconnect")) { Task { await linker.link(network) } }.controlSize(.small)
                }
                if account.login != nil {
                    Button(tr("chats.link.unlink"), role: .destructive) { unlinking = account }.controlSize(.small)
                }
            }
        }
    }

    // MARK: Linking through the chat service

    /// The helper running (it starts by itself), then the app's login as the helper asks for it.
    @ViewBuilder
    private var serviceSteps: some View {
        let ready = ChatServiceBridge.token != nil && linker.problem == nil && !linker.networks.isEmpty
        if !ready {
            SetupStep(number: 1, title: tr("chats.link.step.service"), done: false) {
                if let problem = linker.problem ?? ChatHelper.shared.problem {
                    SettingNote(problem, tone: .error)
                }
                StepAction(detail: tr("chats.link.step.serviceDetail"), button: tr("chats.status.retry"), prominent: false) {
                    Task { await linker.refresh() }
                }
            }
        }
        SetupStep(number: ready ? 1 : 2, title: tr("chats.link.step.login", name), done: false) {
            if !ready {
                Text(tr("chats.link.step.loginWaits"))
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textTertiary)
            } else if let network {
                if ChatHelper.riskyApps.contains(app), network.accounts.isEmpty {
                    SettingNote(tr("chats.link.risk", name), tone: .warning)
                }
                if !network.accounts.isEmpty, network.canLink, !isLinking {
                    Button(tr("chats.link.another")) { Task { await linker.link(network) } }
                } else {
                    ChatLinkSteps(network: network)
                }
            } else {
                SettingNote(tr("chats.link.notOffered", name), tone: .info)
            }
        }
        ChatLinkCheckStep(app: app, number: ready ? 2 : 3)
    }
}

/// The last step of linking every chat app, Nook's own way and the chat service's alike, as "Check the connection" is
/// for every service: Nook reads its chats once it is linked, and says so here.
struct ChatLinkCheckStep: View {
    let app: String
    let number: Int

    var body: some View {
        let name = MessagingApps.app(id: app)?.name ?? app
        SetupCheckStep(number: number, title: tr("chats.link.step.check"), detail: tr("chats.link.step.checkWaiting", name),
                       state: ChatAppStates.state(app)?.linked == true ? .passed(tr("chats.link.step.checkDone", name)) : .idle)
    }
}

/// The steps of one login as the chat service asks for them, one at a time.
struct ChatLinkSteps: View {
    let network: ChatLinkData.Network
    @ObservedObject private var linker = ChatLinker.shared
    @State private var values: [String: String] = [:]

    private var session: ChatLinkData.Session? { linker.linking?.id == network.id ? linker.session : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            if let step = session?.step {
                view(step)
            } else if !network.canLink {
                SettingNote(tr("chats.link.unavailable", network.name), tone: .warning)
            } else {
                StepAction(detail: tr("chats.link.start.detail", network.name), button: tr("chats.link.start", network.name),
                           disabled: linker.isSending) { Task { await linker.link(network) } }
            }
            if linker.isSending {
                BusyLine(tr("chats.link.busy"))
            }
            if let problem = linker.stepProblem, linker.linking?.id == network.id || session == nil {
                SettingNote(problem, tone: .error)
            }
        }
        .onDisappear { ChatSignInWindow.closeAll() }
        // The sign-in window belongs to its step: once the login moved on, or ended, it goes.
        .onChange(of: session?.step) { _, step in
            if case .browser = step { return }
            ChatSignInWindow.closeAll()
        }
    }

    @ViewBuilder
    private func view(_ step: ChatLinkData.Step) -> some View {
        switch step {
        case .input(let id, let instructions, let fields):
            instructionsText(instructions)
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                    Text(field.label).font(NookTheme.TextStyle.strong)
                    let binding = Binding(get: { values[field.id] ?? field.initial }, set: { values[field.id] = $0 })
                    Group {
                        if field.isSecret {
                            SecureField("", text: binding, prompt: Text(field.placeholder))
                        } else {
                            TextField("", text: binding, prompt: Text(field.placeholder))
                        }
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit(fields) }
                }
            }
            Button(tr("chats.link.continue")) { submit(fields) }
                .buttonStyle(.nookProminent)
                .disabled(linker.isSending || fields.contains { !$0.isOptional && (values[$0.id] ?? $0.initial).trimmingCharacters(in: .whitespaces).isEmpty })
                .id(id)
        case .browser(_, let instructions, let url, _, _, _, _):
            instructionsText(instructions.isEmpty ? tr("chats.link.browser.detail", network.name) : instructions)
            Button {
                ChatSignInWindow.open(step: step, title: tr("chats.link.browser.title", network.name)) { collected, last in
                    Task { await linker.submitBrowser(collected, lastURL: last) }
                }
            } label: {
                Label(tr("chats.link.browser.open", url.host ?? network.name), icon: "person.badge.key")
            }
            .buttonStyle(.nookProminent)
            .controlSize(.large)
            SettingNote(tr("chats.link.browser.privacy", network.name))
        case .display(_, let instructions, let show):
            instructionsText(instructions)
            display(show)
            BusyLine(tr("chats.link.waiting"))
        case .complete(let instructions):
            instructionsText(instructions.isEmpty ? tr("chats.link.done", network.name) : instructions)
        }
    }

    @ViewBuilder
    private func display(_ show: ChatLinkData.Display) -> some View {
        switch show {
        case .qr(let data):
            QRCodeView(text: data, label: tr("chats.link.qr"))
        case .code(let code):
            HStack(spacing: NookTheme.Spacing.sm) {
                Text(code)
                    .font(NookTheme.mono(22, .semibold))
                    .textSelection(.enabled)
                Button(tr("chats.teams.copyCode")) { Pasteboard.copy(code) }
            }
        case .image(let url):
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                PatientSpinner()
            }
            .frame(maxWidth: 240, maxHeight: 160)
        case .nothing:
            EmptyView()
        }
    }

    @ViewBuilder
    private func instructionsText(_ text: String) -> some View {
        if !text.isEmpty {
            Text(text)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func submit(_ fields: [ChatLinkData.Field]) {
        var answer: [String: String] = [:]
        for field in fields {
            let value = (values[field.id] ?? field.initial).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { answer[field.id] = value }
        }
        values = [:]
        Task { await linker.submit(answer) }
    }
}

/// Nook's own way of linking an app, in numbered steps ending in Nook's check; nothing but Nook is needed for it.
struct ChatOwnLinkSteps: View {
    let app: String
    let setCollecting: (Bool) -> Void
    @ObservedObject private var capture = ChatCaptureService.shared
    @ObservedObject private var telegram = ChatCaptureService.shared.telegramBridge
    @ObservedObject private var teams = ChatCaptureService.shared.teamsBridge
    @ObservedObject private var whatsApp = WhatsAppLink.shared
    @ObservedObject private var whatsAppAccounts = WhatsAppAccounts.shared
    @ObservedObject private var installer = WhatsAppGOWAInstaller.shared
    @ObservedObject private var snapchat = SnapchatWebSession.shared
    @ObservedObject private var mail = ChatCaptureService.shared.mailBridge

    var body: some View {
        steps
        ChatLinkCheckStep(app: app, number: stepCount + 1)
    }

    /// How many numbered steps the app's own way has now, so the check after them gets the next number (Telegram asks
    /// for a password only when one is set).
    private var stepCount: Int {
        switch app {
        case "whatsapp": return 2
        case telegram.app: return TelegramLinkSteps.count(telegram)
        default: return 1
        }
    }

    @ViewBuilder
    private var steps: some View {
        switch app {
        case "whatsapp": whatsAppSteps
        case telegram.app:
            TelegramLinkSteps(telegram: telegram) { linked(telegram.app) }
        case teams.app:
            SetupStep(number: 1, title: tr("chats.own.teams.step"), done: teams.isReady) {
                TeamsSettingsRows(teams: teams, problem: capture.bridgeProblems[teams.app]) {
                    if teams.accounts.isEmpty && !TeamsWebSession.shared.isSignedIn {
                        capture.bridgeChanged(teams.app)
                    } else {
                        linked(teams.app)
                    }
                }
            }
        case capture.slackBridge.app:
            SetupStep(number: 1, title: tr("chats.own.slack.step"), done: SlackBridge.auth != nil) {
                SlackSettingsRows(setCollecting: setCollecting)
            }
        case capture.messagesBridge.app:
            messagesStep
        case capture.snapchatBridge.app:
            snapchatStep
        case mail.app:
            mailStep
        default:
            EmptyView()
        }
    }

    /// The app is linked: its chats are switched on and read right away.
    private func linked(_ id: String) {
        capture.setSource(id, on: true)
        if !capture.enabled { setCollecting(true) }
        capture.loggedIn(id)
    }

    // MARK: WhatsApp

    private var usesOwnLink: Bool { WhatsAppSettings.gateway == .gowa }
    private var installed: Bool { !usesOwnLink || WhatsAppGOWAInstaller.isInstalled }

    /// WhatsApp not linked yet: the two steps that link it, with the gateway folded away below them. Once linked, the
    /// sheet manages it in parts (`ChatOwnAccounts`, `ChatAppNoticeRows`, `ChatOwnAdvanced`).
    @ViewBuilder
    private var whatsAppSteps: some View {
        whatsAppLinkSteps
    }

    @ViewBuilder
    private var whatsAppLinkSteps: some View {
        SetupStep(number: 1, title: tr("chats.own.whatsapp.install"), done: installed && !installer.busy) {
            if installed && !installer.busy {
                detail(tr("chats.own.whatsapp.installed"))
            } else {
                if installer.busy {
                    detail(tr("chats.own.whatsapp.installDetail"))
                    BusyLine(installLine)
                } else {
                    StepAction(detail: tr("chats.own.whatsapp.installDetail"), button: tr("whatsapp.install.button")) {
                        installer.install()
                    }
                }
                if case .failed(let why) = installer.step { SettingNote(why, tone: .error) }
            }
        }
        SetupStep(number: 2, title: tr("chats.own.whatsapp.scan"), done: false) {
            if !WhatsAppSettings.enabled {
                StepAction(detail: tr("chats.own.whatsapp.scanDetail"), button: tr("chats.own.whatsapp.showQR"),
                           disabled: !installed || installer.busy) {
                    whatsAppAccounts.setEnabled(true)
                    capture.setSource("whatsapp", on: true)
                }
            } else if whatsApp.link == .needsQR, let data = whatsApp.qrPNG, let image = NSImage(data: data) {
                detail(tr("whatsapp.settings.scan"))
                QRCodeView(image: image, label: tr("chats.link.qr"))
            } else {
                BusyLine(whatsApp.statusLine)
                if whatsApp.link == .unreachable || whatsApp.link == .unauthorized {
                    Button(tr("whatsapp.settings.retry")) { whatsAppAccounts.settingsChanged() }
                }
            }
        }
        // While this step shows, an unlinked gateway is asked every few seconds, so a scanned QR code links at once.
        .onAppear { whatsApp.linkViewAppeared() }
        .onDisappear { whatsApp.linkViewDisappeared() }
    }

    private var installLine: String {
        switch installer.step {
        case .downloading(let megabytes): return tr("whatsapp.install.downloading", megabytes)
        case .verifying: return tr("whatsapp.install.verifying")
        case .installing: return tr("whatsapp.install.installing")
        default: return tr("whatsapp.install.checking")
        }
    }

    // MARK: Snapchat

    @ViewBuilder
    private var snapchatStep: some View {
        let app = capture.snapchatBridge.app
        SetupStep(number: 1, title: tr("chats.own.snapchat.step"), done: snapchat.isSignedIn) {
            if snapchat.isSignedIn {
                ChatLinkedAccountRow(app: app, title: tr("chats.snapchat.connected"), detail: tr("chats.snapchat.connectedDetail"),
                                     signOut: { capture.signOutSnapchat() })
            } else {
                SettingNote(tr("chats.link.risk", "Snapchat"), tone: .warning)
                StepAction(detail: tr("chats.snapchat.signInDetail"), button: tr("chats.snapchat.signIn"),
                           disabled: snapchat.isSigningIn) {
                    snapchat.signIn(title: tr("chats.link.browser.title", "Snapchat")) { linked(app) }
                }
            }
        }
    }

    // MARK: Mail

    @ViewBuilder
    private var mailStep: some View {
        SetupStep(number: 1, title: tr("chats.own.mail.step"), done: mail.isLinked) {
            if mail.isLinked {
                MailAccountRows()
            } else {
                StepAction(detail: tr("chats.mail.linkDetail"), button: tr("chats.mail.link")) {
                    if !capture.enabled { setCollecting(true) }
                    capture.linkMail()
                }
            }
        }
    }

    // MARK: Messages

    @ViewBuilder
    private var messagesStep: some View {
        let ready = capture.enabled && capture.status != .needsAccess
        SetupStep(number: 1, title: tr("chats.own.messages.step"), done: ready) {
            if ready {
                detail(tr("chats.link.ownWay.messagesDone"))
            } else {
                StepAction(detail: tr("chats.capture.needsAccess"), button: tr("chats.capture.grant")) {
                    if !capture.enabled { setCollecting(true) }
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(NookTheme.TextStyle.body)
            .foregroundStyle(NookTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The accounts of an app Nook links in its own way, once it is linked: one `ChatAccountRow` each, and adding another
/// where the app has more than one (WhatsApp, Teams).
struct ChatOwnAccounts: View {
    let app: String
    let setCollecting: (Bool) -> Void
    @ObservedObject private var capture = ChatCaptureService.shared
    @ObservedObject private var telegram = ChatCaptureService.shared.telegramBridge
    @ObservedObject private var teams = ChatCaptureService.shared.teamsBridge

    var body: some View {
        switch app {
        case "whatsapp":
            WhatsAppAccountList()
        case telegram.app:
            TelegramSettingsRows(telegram: telegram) { capture.loggedIn(telegram.app) }
        case teams.app:
            TeamsSettingsRows(teams: teams, problem: capture.bridgeProblems[teams.app]) { capture.loggedIn(teams.app) }
        case capture.slackBridge.app:
            SlackSettingsRows(setCollecting: setCollecting, showsToken: false)
        case capture.messagesBridge.app:
            ChatLinkedAccountRow(app: app, title: tr("chats.manage.thisMac"), detail: tr("chats.link.ownWay.messagesDone"))
        case capture.snapchatBridge.app:
            ChatLinkedAccountRow(app: app, title: tr("chats.snapchat.connected"), detail: tr("chats.snapchat.connectedDetail"),
                                 signOut: { capture.signOutSnapchat() })
            SettingNote(tr("chats.snapchat.howItReads"))
        case capture.mailBridge.app:
            MailAccountRows()
        default:
            EmptyView()
        }
    }
}

/// Mail's accounts once it is linked: one row per account in the Mail app (whatever kind it is: iCloud, Gmail, Outlook,
/// Exchange, Yahoo, IMAP), a way to add another (in System Settings, where Mail takes its accounts from), and unlinking
/// Mail behind a confirmation. Mail itself and its accounts stay as they are.
struct MailAccountRows: View {
    @ObservedObject private var capture = ChatCaptureService.shared
    @ObservedObject private var mail = ChatCaptureService.shared.mailBridge

    var body: some View {
        let app = mail.app
        if mail.accounts.isEmpty {
            ChatLinkedAccountRow(app: app, title: tr("chats.mail.connected"), detail: tr("chats.mail.connectedDetail"))
        } else {
            ForEach(mail.accounts, id: \.name) { account in
                ChatLinkedAccountRow(app: app, title: account.name,
                                     detail: account.addresses.isEmpty ? tr("chats.mail.connectedDetail")
                                         : account.addresses.joined(separator: ", "))
            }
        }
        if !ScriptText.isRunning(MailSender.mailBundleID) {
            SettingNote(tr("chats.mail.openMail"), tone: .warning)
        }
        HStack(spacing: NookTheme.Spacing.sm) {
            Button(tr("chats.mail.addAccount")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            ConfirmedButton(tr("chats.mail.unlink"), question: tr("chats.mail.unlinkQuestion"), action: { capture.unlinkMail() })
        }
        .controlSize(.small)
        SettingNote(tr("chats.mail.howItReads"))
    }
}

/// What a linked app has that is rarely needed, folded under a name that says what it holds: WhatsApp's gateway, Slack's
/// token of an app of your own, Telegram's keys from my.telegram.org.
struct ChatOwnAdvanced: View {
    let app: String
    let setCollecting: (Bool) -> Void
    @ObservedObject private var telegram = ChatCaptureService.shared.telegramBridge

    /// Whether the app has anything here.
    @MainActor
    static func has(_ app: String) -> Bool {
        let capture = ChatCaptureService.shared
        return ["whatsapp", capture.slackBridge.app, capture.telegramBridge.app].contains(app)
    }

    /// The name of the fold it sits in, for what it holds.
    @MainActor
    static func title(_ app: String) -> String {
        let capture = ChatCaptureService.shared
        switch app {
        case "whatsapp": return tr("chats.fold.gateway")
        case capture.slackBridge.app: return tr("chats.fold.slackToken")
        case capture.telegramBridge.app: return tr("chats.telegram.keys")
        default: return tr("chats.manage.advanced")
        }
    }

    var body: some View {
        let capture = ChatCaptureService.shared
        switch app {
        case "whatsapp":
            WhatsAppGatewayRows()
        case capture.slackBridge.app:
            SlackTokenRows(setCollecting: setCollecting)
        case telegram.app:
            StepAction(detail: tr("chats.telegram.keysDetail"), button: tr("chats.telegram.changeKeys"), prominent: false) {
                TelegramKeysButton.reset(telegram)
            }
        default:
            EmptyView()
        }
    }
}
