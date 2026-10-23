import SwiftUI
import AppKit

/// Linking one chat app, or managing it once it is linked, in numbered steps: connect the chat service on this Mac (once),
/// then log in to the app the way it asks for it (a QR code to scan with your phone, a code, a phone number, or signing in
/// on its website in a window Nook opens). An app Nook can also link in its own way (WhatsApp through your phone,
/// Telegram, Teams, Slack, Instagram, Messages) shows that way below.
struct ChatAppSheet: View {
    let app: String
    let setCollecting: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var capture = ChatCaptureService.shared
    @ObservedObject private var linker = ChatLinker.shared
    @ObservedObject private var linked = ChatCaptureService.shared.beeperBridge
    @State private var unlinking: ChatLinkData.Account?
    @State private var showOwnWay = false

    private var name: String { MessagingApps.app(id: app)?.name ?? app }
    private var site: String? { MessagingApps.app(id: app)?.site }
    private var network: ChatLinkData.Network? { linker.networks.first { $0.app == app } }
    private var hasService: Bool { BeeperBridge.token != nil && linker.problem == nil && !linker.networks.isEmpty }
    /// A login of this app is under way.
    private var isLinking: Bool { linker.linking?.app == app && linker.session != nil }

    var body: some View {
        SetupSheet(title: name, subtitle: subtitle) {
            ServiceTile(domain: site, fallback: "bubble.left.and.bubble.right.fill", tint: NookTheme.iris, size: 48, source: app)
        } content: {
            if let network, !network.accounts.isEmpty {
                accounts(network)
            }
            if network?.accounts.isEmpty ?? true || isLinking {
                steps
            } else if let network, network.canLink {
                Button(tr("chats.link.another")) { Task { await linker.link(network) } }
            }
            if ChatAppsCatalog.ownWay.contains(app) {
                NookDivider()
                DisclosureGroup(isExpanded: $showOwnWay) {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.md) { ChatAppOwnWay(app: app, setCollecting: setCollecting) }
                        .padding(.top, NookTheme.Spacing.sm)
                } label: {
                    SettingLabel(tr("chats.link.ownWay"), detail: tr("chats.link.ownWay.\(app)"))
                }
            }
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
        .task {
            // Starting from a card shows the open steps already; the list may be older than the sheet.
            await linker.refresh()
            // Where the chat service cannot link the app, Nook's own way is the way: it shows open.
            showOwnWay = ChatAppsCatalog.ownWay.contains(app) && hasService && network == nil
        }
    }

    private var subtitle: String {
        if let network, !network.accounts.isEmpty { return tr("chats.link.subtitleLinked", name) }
        return tr("chats.link.subtitle", name)
    }

    // MARK: Accounts

    @ViewBuilder
    private func accounts(_ network: ChatLinkData.Network) -> some View {
        ForEach(network.accounts) { account in
            ServiceRowLayout(domain: site, symbol: "person.crop.circle", tint: NookTheme.iris, title: account.name,
                             detail: account.isConnected ? (linked.isLive ? tr("chats.linked.liveDetail") : tr("chats.beeper.connectedDetail"))
                                 : (account.status ?? tr("chats.apps.reconnect")),
                             status: account.isConnected ? .connected : .expired, source: app) {
                if !account.isConnected, network.canLink {
                    Button(tr("chats.apps.reconnect")) { Task { await linker.link(network) } }.controlSize(.small)
                }
                if account.login != nil {
                    Button(tr("chats.link.unlink"), role: .destructive) { unlinking = account }.controlSize(.small)
                }
            }
        }
    }

    // MARK: Linking in steps

    @ViewBuilder
    private var steps: some View {
        let serviceReady = hasService
        SetupStep(number: 1, title: tr("chats.link.step.service"), done: serviceReady) {
            if serviceReady {
                Text(tr("chats.link.step.serviceDone"))
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textSecondary)
            } else {
                Text(tr("chats.link.step.serviceDetail"))
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                BeeperSettingsRows(capture: capture)
                if let problem = linker.problem, BeeperBridge.token != nil {
                    SettingNote(problem, tone: .error)
                    Button(tr("chats.status.retry")) { Task { await linker.refresh() } }
                }
            }
        }
        SetupStep(number: 2, title: tr("chats.link.step.login", name), done: false) {
            if !serviceReady {
                Text(tr("chats.link.step.loginWaits"))
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textTertiary)
            } else if let network {
                ChatLinkSteps(network: network)
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
    @State private var window: ChatSignInWindow?

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
        .onDisappear { window?.close() }
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
        case .browser(_, let instructions, let url, _, _, _):
            instructionsText(instructions.isEmpty ? tr("chats.link.browser.detail", network.name) : instructions)
            Button {
                window?.close()
                window = ChatSignInWindow(step: step, title: tr("chats.link.browser.title", network.name)) { collected, last in
                    Task { await linker.submitBrowser(collected, lastURL: last) }
                }
                window?.show()
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
            if let image = QRCode.image(data) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .padding(NookTheme.Spacing.md)
                    .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.paper))
                    .accessibilityLabel(tr("chats.link.qr"))
            }
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

/// The way Nook links an app itself, in the sheet of that app: WhatsApp through your phone, Telegram with its own login,
/// Teams with Microsoft's code page, Slack with a token, Instagram with its website in Nook, Messages from this Mac.
struct ChatAppOwnWay: View {
    let app: String
    let setCollecting: (Bool) -> Void
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var capture = ChatCaptureService.shared
    @ObservedObject private var instagram = ChatCaptureService.shared.instagramBridge

    var body: some View {
        switch app {
        case "whatsapp":
            Form { WhatsAppLinkSection() }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(height: 420)
        case capture.telegramBridge.app:
            TelegramSettingsRows(telegram: capture.telegramBridge) { capture.bridgeChanged(capture.telegramBridge.app) }
        case capture.teamsBridge.app:
            TeamsSettingsRows(teams: capture.teamsBridge, problem: capture.bridgeProblems[capture.teamsBridge.app]) {
                if capture.teamsBridge.accounts.isEmpty { capture.bridgeChanged(capture.teamsBridge.app) } else { capture.loggedIn(capture.teamsBridge.app) }
            }
        case capture.slackBridge.app:
            SlackTokenRows(setCollecting: setCollecting)
        case instagram.app:
            if instagram.isReady {
                StatusRow(title: tr("chats.apps.own.instagram"), detail: tr("chats.link.ownWay.instagramDone"), state: .done) {
                    Button(tr("chats.link.unlink")) { Task { await instagram.signOut() } }
                }
            } else {
                Button(tr("chats.link.ownWay.instagramLogin")) {
                    guard let web = EmbeddedAppCatalog.all.first(where: { $0.id == instagram.app }) else { return }
                    instagram.watchSignIn()
                    model.openEmbeddedApp(web, mode: .web)
                    model.showChat()
                }
            }
        case capture.messagesBridge.app:
            if capture.status == .needsAccess || !capture.enabled {
                StatusRow(title: tr("chats.status.access"), detail: tr("chats.capture.needsAccess"), state: .warning) {
                    Button(tr("chats.capture.grant")) {
                        if !capture.enabled { setCollecting(true) }
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } else {
                StatusRow(title: tr("chats.apps.own.messages"), detail: tr("chats.link.ownWay.messagesDone"), state: .done) { EmptyView() }
            }
        default:
            EmptyView()
        }
    }
}
