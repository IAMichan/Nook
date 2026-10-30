import SwiftUI
import AppKit
import WebKit

/// Linking one chat app, or managing it once it is linked, in numbered steps. Nook links the apps it reads itself in its
/// own way, with nothing else needed: WhatsApp with a QR code from your phone, Teams with a code from Microsoft, Slack
/// with a token, Messages from this Mac, Snapchat from its website. Telegram, Instagram, Messenger, Signal, X and LinkedIn link through the chat
/// service on this Mac (Nook's own helper: your phone number and a code, logging in on the app's own website, or a QR
/// code), which is also offered as another way for the rest while it runs. A build without the helper
/// links Telegram itself, through TDLib.
struct ChatAppSheet: View {
    let app: String
    let setCollecting: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var capture = ChatCaptureService.shared
    @ObservedObject private var linker = ChatLinker.shared
    @ObservedObject private var linked = ChatCaptureService.shared.serviceBridge
    @State private var unlinking: ChatLinkData.Account?
    @State private var showService = false
    @State private var showAdvanced = false

    private var name: String { MessagingApps.app(id: app)?.name ?? app }
    private var site: String? { MessagingApps.app(id: app)?.site }
    private var network: ChatLinkData.Network? { linker.networks.first { $0.app == app } }
    private var ownWay: Bool { ChatAppsCatalog.ownWay.contains(app) }
    /// A login through the chat service of this app is under way.
    private var isLinking: Bool { linker.linking?.app == app && linker.session != nil }
    /// Linked: the sheet manages it in parts instead of walking through the steps that link it.
    private var isLinked: Bool { ChatAppStates.state(app)?.linked == true }

    var body: some View {
        SetupSheet(title: name, subtitle: subtitle) {
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
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .confirmDelete($unlinking, question: { tr("chats.link.unlinkQuestion", $0.name) }, detail: tr("chats.link.unlinkDetail", name),
                       confirmTitle: tr("chats.link.unlink")) { account in
            guard let network else { return }
            Task { await linker.unlink(account, in: network) }
        }
        .task { await linker.refresh() }
        // Escape closes the sheet the way Done does.
        .onExitCommand {
            Task { if isLinking { await linker.cancel() } }
            dismiss()
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
        NookDivider()
        SheetPart(tr("chats.manage.inNook")) { ChatAppNoticeRows(app: app, setCollecting: setCollecting) }
        if ChatOwnAdvanced.has(app) || (ownWay && linker.serviceRuns) {
            NookDivider()
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                    ChatOwnAdvanced(app: app, setCollecting: setCollecting)
                    // Nook links it in its own way; the chat service on this Mac is the other way.
                    if ownWay, linker.serviceRuns {
                        SettingLabel(tr("chats.link.viaService"), detail: tr("chats.link.viaServiceDetail", name))
                        serviceSteps
                    }
                }
                .padding(.top, NookTheme.Spacing.sm)
            } label: {
                SettingLabel(tr("chats.manage.advanced"), detail: tr("chats.manage.advancedDetail"))
            }
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
                DisclosureGroup(isExpanded: $showService) {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) { serviceSteps }
                        .padding(.top, NookTheme.Spacing.sm)
                } label: {
                    SettingLabel(tr("chats.link.viaService"), detail: tr("chats.link.viaServiceDetail", name))
                }
            } else {
                serviceSteps
            }
        } else if !ownWay, ChatHelper.apps.contains(app), !ChatHelper.isBuilt {
            SettingNote(tr("chats.link.helperMissing", name))
        } else if !ownWay {
            SettingNote(tr("chats.link.notYet", name, name))
        }
        // Until it is linked, its chats come in by its notifications: switched here, as the overview shows no row.
        if capture.sources.apps.contains(where: { $0.id == app }) {
            NookDivider()
            SettingToggle(tr("chats.link.notifications"), detail: tr("chats.settings.collectDetail"),
                          isOn: Binding(get: { capture.enabled && capture.sources.isOn(app) }, set: { on in
                              capture.setSource(app, on: on)
                              if on, !capture.enabled { setCollecting(true) }
                          }))
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
                Text(tr("chats.link.step.serviceDetail"))
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let problem = linker.problem ?? ChatHelper.shared.problem {
                    SettingNote(problem, tone: .error)
                }
                Button(tr("chats.status.retry")) { Task { await linker.refresh() } }
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
                Text(tr("chats.link.start.detail", network.name))
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(tr("chats.link.start", network.name)) { Task { await linker.link(network) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(linker.isSending)
            }
            if linker.isSending {
                HStack(spacing: NookTheme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(tr("chats.link.busy")).foregroundStyle(NookTheme.textSecondary)
                }
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
                .buttonStyle(.borderedProminent)
                .disabled(linker.isSending || fields.contains { !$0.isOptional && (values[$0.id] ?? $0.initial).trimmingCharacters(in: .whitespaces).isEmpty })
                .id(id)
        case .browser(_, let instructions, let url, _, _, _, _):
            instructionsText(instructions.isEmpty ? tr("chats.link.browser.detail", network.name) : instructions)
            Button {
                ChatSignInWindow.open(step: step, title: tr("chats.link.browser.title", network.name)) { collected, last in
                    Task { await linker.submitBrowser(collected, lastURL: last) }
                }
            } label: {
                Label(tr("chats.link.browser.open", url.host ?? network.name), systemImage: "person.badge.key")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            SettingNote(tr("chats.link.browser.privacy", network.name))
        case .display(_, let instructions, let show):
            instructionsText(instructions)
            display(show)
            HStack(spacing: NookTheme.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(tr("chats.link.waiting")).foregroundStyle(NookTheme.textSecondary)
            }
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
                ProgressView()
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

/// Nook's own way of linking an app, in numbered steps; nothing but Nook is needed for it.
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
    @State private var whatsAppOptions = false

    var body: some View {
        switch app {
        case "whatsapp": whatsAppSteps
        case telegram.app:
            SetupStep(number: 1, title: tr("chats.own.telegram.step"), done: telegram.isReady) {
                TelegramSettingsRows(telegram: telegram) { linked(telegram.app) }
            }
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
        NookDivider()
        DisclosureGroup(isExpanded: $whatsAppOptions) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) { WhatsAppGatewayRows() }
                .padding(.top, NookTheme.Spacing.sm)
        } label: {
            SettingLabel(tr("chats.manage.advanced"), detail: tr("chats.manage.advancedDetail"))
        }
    }

    @ViewBuilder
    private var whatsAppLinkSteps: some View {
        SetupStep(number: 1, title: tr("chats.own.whatsapp.install"), done: installed && !installer.busy) {
            if installed && !installer.busy {
                detail(tr("chats.own.whatsapp.installed"))
            } else {
                detail(tr("chats.own.whatsapp.installDetail"))
                HStack(spacing: NookTheme.Spacing.sm) {
                    if installer.busy {
                        ProgressView().controlSize(.small)
                        Text(installLine).foregroundStyle(NookTheme.textSecondary)
                    } else {
                        Button(tr("whatsapp.install.button")) { installer.install() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if case .failed(let why) = installer.step { SettingNote(why, tone: .error) }
            }
        }
        SetupStep(number: 2, title: tr("chats.own.whatsapp.scan"), done: false) {
            if !WhatsAppSettings.enabled {
                detail(tr("chats.own.whatsapp.scanDetail"))
                Button(tr("chats.own.whatsapp.showQR")) {
                    whatsAppAccounts.setEnabled(true)
                    capture.setSource("whatsapp", on: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!installed || installer.busy)
            } else if whatsApp.link == .needsQR, let data = whatsApp.qrPNG, let image = NSImage(data: data) {
                detail(tr("whatsapp.settings.scan"))
                QRCodeView(image: image, label: tr("chats.link.qr"))
            } else {
                HStack(spacing: NookTheme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(whatsApp.statusLine).foregroundStyle(NookTheme.textSecondary)
                }
                if whatsApp.link == .unreachable || whatsApp.link == .unauthorized {
                    Button(tr("whatsapp.settings.retry")) { whatsAppAccounts.settingsChanged() }
                }
            }
        }
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
                detail(tr("chats.snapchat.signInDetail"))
                SettingNote(tr("chats.link.risk", "Snapchat"), tone: .warning)
                Button(tr("chats.snapchat.signIn")) {
                    snapchat.signIn(title: tr("chats.link.browser.title", "Snapchat")) { linked(app) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(snapchat.isSigningIn)
            }
            SettingNote(tr("chats.snapchat.howItReads"))
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
                detail(tr("chats.capture.needsAccess"))
                Button(tr("chats.capture.grant")) {
                    if !capture.enabled { setCollecting(true) }
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
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
        default:
            EmptyView()
        }
    }
}

/// What a linked app has that is rarely needed, under Advanced: WhatsApp's gateway, Slack's token of an app of your own,
/// Telegram's keys from my.telegram.org.
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

    var body: some View {
        let capture = ChatCaptureService.shared
        switch app {
        case "whatsapp":
            WhatsAppGatewayRows()
        case capture.slackBridge.app:
            SlackTokenRows(setCollecting: setCollecting)
        case telegram.app:
            HStack {
                SettingLabel(tr("chats.telegram.keys"), detail: tr("chats.telegram.keysDetail"))
                Spacer()
                TelegramKeysButton(telegram: telegram)
            }
        default:
            EmptyView()
        }
    }
}
