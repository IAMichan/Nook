import SwiftUI
import AppKit
import Security
import UniformTypeIdentifiers

/// Settings › Chats: everything the Chats tab shows, on its own page. WhatsApp through the linked phone, and every other
/// chat app whose notifications Nook collects: switch each app on or off, or add your own (a website such as
/// linkedin.com/messaging, or a Mac app) in one line.
struct ChatsSettingsSection: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var capture = ChatCaptureService.shared
    @State private var typed = ""
    @State private var notice: String?
    /// The last thing typed could not be added: its note reads as a warning.
    @State private var noticeIsProblem = false
    @State private var slackToken = ""
    @State private var slackSet = SlackBridge.token != nil
    @State private var giphyKey = ""
    @State private var giphySet = Giphy.key != nil
    @AppStorage(ChatsTab.readOnOpenKey) private var readOnOpen = true

    var body: some View {
        // WhatsApp first, the app most chats come from; then the other apps and the list of them; then the bridges
        // that need a token or a login, each in its own short section.
        Group {
            WhatsAppLinkSection()

            Section {
                SettingToggle(tr("chats.settings.collect"), detail: tr("chats.settings.collectDetail"),
                              isOn: Binding(get: { capture.enabled }, set: { setCollecting($0) }))
                if capture.enabled { status }
            } header: {
                Text(tr("chats.settings.otherApps"))
            } footer: {
                Text(tr("chats.settings.privacy"))
            }

            Section {
                SettingToggle(tr("chats.settings.readOnOpen"), detail: tr("chats.settings.readOnOpenDetail"), isOn: $readOnOpen)
            } header: {
                Text(tr("chats.settings.reading"))
            }

            Section {
                ForEach(capture.sources.apps) { source in
                    row(source)
                }
                addRow
            } header: {
                Text(tr("chats.settings.sources"))
            } footer: {
                Text(tr("chats.settings.sourcesFooter"))
            }

            Section {
                giphyRow
            } header: {
                Text(tr("chats.giphy.title"))
            } footer: {
                Text(tr("chats.giphy.footer"))
            }

            Section {
                slackRow
            } header: {
                Text(tr("chats.slack.title"))
            } footer: {
                Text(tr("chats.slack.footer"))
            }

            Section {
                TelegramSettingsRows(telegram: capture.telegramBridge) { capture.bridgeChanged(capture.telegramBridge.app) }
            } header: {
                Text(tr("chats.telegram.title"))
            } footer: {
                Text(tr("chats.telegram.footer"))
            }

            Section {
                TeamsSettingsRows(teams: capture.teamsBridge, problem: capture.bridgeProblems[capture.teamsBridge.app]) {
                    // A new account switches Teams on and reads right away; one signed out reads again without it.
                    if capture.teamsBridge.accounts.isEmpty { capture.bridgeChanged(capture.teamsBridge.app) } else { capture.loggedIn(capture.teamsBridge.app) }
                }
            } header: {
                Text(tr("chats.teams.title"))
            } footer: {
                Text(tr("chats.teams.footer"))
            }

            Section {
                BeeperSettingsRows(capture: capture)
            } header: {
                Text(tr("chats.beeper.title"))
            } footer: {
                Text(tr("chats.beeper.footer"))
            }
        }
    }

    /// Whether collecting works, in one line: Full Disk Access missing, the database unreadable, or how many chats came in.
    @ViewBuilder
    private var status: some View {
        switch capture.status {
        case .needsAccess:
            StatusRow(title: tr("chats.status.access"), detail: tr("chats.capture.needsAccess"), state: .warning) {
                Button(tr("chats.capture.grant")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        case .failed(let why):
            StatusRow(title: tr("chats.status.failed"), detail: why, state: .error) {
                Button(tr("chats.status.retry")) { capture.start() }
            }
        case .running, .off:
            let count = capture.inbox.threads.count
            StatusRow(title: tr("chats.status.running"),
                      detail: count == 0 ? tr("chats.status.waiting") : tr("chats.status.count", count),
                      state: count == 0 ? .todo : .done) {
                EmptyView()
            }
        }
    }

    /// Slack with its history: a user token, kept in the Keychain, and whether reading with it works.
    @ViewBuilder
    private var slackRow: some View {
        SettingLabel(tr("chats.slack.token"), detail: tr("chats.slack.tokenDetail"))
        HStack(spacing: NookTheme.Spacing.sm) {
            SecureField("", text: $slackToken, prompt: Text(slackSet ? "••••••••" : "xoxp-…"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .onSubmit { saveSlackToken() }
            Button(tr("chats.slack.save")) { saveSlackToken() }
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
    }

    /// Your GIPHY key, for the GIFs the chat's "+" offers: pasted once, kept in the Keychain.
    @ViewBuilder
    private var giphyRow: some View {
        SettingLabel(tr("chats.giphy.key"), detail: tr("chats.giphy.keyDetail"))
        HStack(spacing: NookTheme.Spacing.sm) {
            SecureField("", text: $giphyKey, prompt: Text(giphySet ? "••••••••" : tr("chats.giphy.key")))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .onSubmit { saveGiphyKey() }
            Button(tr("chats.slack.save")) { saveGiphyKey() }
                .disabled(giphyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if giphySet {
                Button(tr("chats.giphy.remove")) {
                    Keychain.remove(Giphy.keyAccount)
                    giphySet = false
                }
            } else {
                Button(tr("chats.giphy.getKey")) {
                    if let url = URL(string: "https://developers.giphy.com/dashboard/") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    private func saveGiphyKey() {
        let key = giphyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard Keychain.write(key, account: Giphy.keyAccount) == errSecSuccess else {
            ToastCenter.shared.error(tr("chats.giphy.notSaved"))
            return
        }
        giphyKey = ""
        giphySet = true
        ToastCenter.shared.success(tr("chats.giphy.saved"))
    }

    private func saveSlackToken() {
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

    /// Adding a source: a website or an app's name typed in one field, or a Mac app picked from the Applications folder.
    private var addRow: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            SettingLabel(tr("chats.settings.addField"), detail: tr("chats.settings.addDetail"))
            HStack(spacing: NookTheme.Spacing.sm) {
                TextField("", text: $typed, prompt: Text(tr("chats.settings.addPrompt")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
                    .onSubmit { addTyped() }
                Button(tr("chats.settings.add")) { addTyped() }
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(tr("chats.settings.chooseApp")) { chooseMacApp() }
            }
            if let notice {
                SettingNote(notice, tone: noticeIsProblem ? .warning : .success)
            }
        }
        .padding(.vertical, NookTheme.Spacing.xxs)
    }

    /// One app: its icon, name and where its messages come from, with its switch (and a remove button when you added it).
    /// Instagram and Teams are read by logging in to them: their row has a Log in button until you did.
    @ViewBuilder
    private func row(_ source: MessagingApp) -> some View {
        // An app is only on while collecting is: switching one on switches collecting on with it.
        let isOn = Binding(get: { capture.enabled && capture.sources.isOn(source.id) },
                           set: { on in
                               capture.setSource(source.id, on: on)
                               if on, !capture.enabled { setCollecting(true) }
                           })
        switch source.id {
        case capture.instagramBridge.app:
            InstagramSourceRow(bridge: capture.instagramBridge, isOn: isOn, logIn: logInToInstagram) { label(source) }
        case capture.teamsBridge.app:
            TeamsSourceRow(teams: capture.teamsBridge, isOn: isOn) { label(source) }
        default:
            Toggle(isOn: isOn) { label(source) }
        }
    }

    /// Opens instagram.com beside the chat, signed in with Nook's own store, and waits until you logged in there.
    private func logInToInstagram() {
        guard let web = EmbeddedAppCatalog.all.first(where: { $0.id == capture.instagramBridge.app }) else { return }
        capture.instagramBridge.watchSignIn()
        app.openEmbeddedApp(web, mode: .web)
        app.showChat()
    }

    private func label(_ source: MessagingApp) -> some View {
        let custom = !MessagingApps.builtIn.contains { $0.id == source.id }
        return HStack(spacing: NookTheme.Spacing.md) {
            SiteIcon(domain: source.site, fallback: "bubble.left.fill", tint: NookTheme.textSecondary, size: 20, source: source.id)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                Text(origin(source))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
            }
            if custom {
                Spacer(minLength: NookTheme.Spacing.sm)
                Button { capture.removeSource(source.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(tr("chats.settings.remove", source.name))
            }
        }
    }

    /// "Mac app and telegram.org": where an app's notifications come from.
    private func origin(_ source: MessagingApp) -> String {
        let app = source.bundleIDs.isEmpty ? nil : tr("chats.settings.macApp")
        let sites = source.domains.isEmpty ? nil : source.domains.joined(separator: ", ")
        return [app, sites].compactMap { $0 }.joined(separator: " · ")
    }

    private func setCollecting(_ on: Bool) {
        capture.enabled = on
        if let source = app.connectors.source(id: ChatInboxConnector.sourceID) { app.connectors.refresh(source) }
    }

    private func addTyped() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        report(capture.addSource(text))
    }

    /// A Mac app from the Applications folder: its notifications are its messages.
    private func chooseMacApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        report(capture.addSource(bundleID: bundleID, name: name))
    }

    /// Says what adding did; anything added is collected from now on, so collecting is switched on with it.
    private func report(_ added: ChatSources.Added) {
        switch added {
        case .added(let source):
            noticeIsProblem = false
            typed = ""
            notice = tr("chats.settings.added", source.name)
            if !capture.enabled { setCollecting(true) }
        case .known(let source):
            noticeIsProblem = false
            typed = ""
            notice = tr("chats.settings.known", source.name)
            if !capture.enabled { setCollecting(true) }
        case .invalid:
            noticeIsProblem = true
            notice = tr("chats.settings.invalid")
        }
    }
}
