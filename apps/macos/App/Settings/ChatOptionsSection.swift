import SwiftUI
import AppKit
import Security
import UniformTypeIdentifiers

/// The chat options at the end of Settings › Accounts & connections: the notifications Nook collects from apps it does
/// not link, how reading works, and the GIF key. The chat apps themselves are linked above, like everything else.
struct ChatOptionsSection: View {
    @ObservedObject private var capture = ChatCaptureService.shared
    @State private var typed = ""
    @State private var notice: String?
    /// The last thing typed could not be added: its note reads as a warning.
    @State private var noticeIsProblem = false
    @State private var giphyKey = ""
    @State private var giphySet = Giphy.ownKey != nil
    @AppStorage(ChatsTab.readOnOpenKey) private var readOnOpen = true

    var body: some View {
        Group {
            Section {
                SettingToggle(tr("chats.settings.collect"), detail: tr("chats.settings.collectDetail"),
                              isOn: Binding(get: { capture.enabled }, set: { setCollecting($0) }))
                if capture.enabled { status }
                // The apps in the overview are switched on and off there (or in their sheet while not linked); this lists
                // only the apps Nook knows by their notifications alone.
                let overview = Set(ChatAppStates.all().map(\.id))
                ForEach(capture.sources.apps.filter { !overview.contains($0.id) }) { source in
                    row(source)
                }
                addRow
            } header: {
                SettingsSectionTitle(tr("chats.settings.otherApps"), info: tr("chats.settings.privacy"))
            }

            Section {
                SettingToggle(tr("chats.settings.readOnOpen"), detail: tr("chats.settings.readOnOpenDetail"), isOn: $readOnOpen)
            } header: {
                Text(tr("chats.settings.reading"))
            }

            // GIFs work with Nook's own key; a key of your own is only for whoever runs into its limit, folded away.
            SettingsFold(tr("chats.giphy.title"), summary: tr("chats.giphy.summary"), keys: ["chats.giphy.title"]) {
                giphyRow
                SettingNote(tr("chats.giphy.footer"))
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

    /// Your GIPHY key, for the GIFs the chat's "+" offers: pasted once, kept in the Keychain.
    @ViewBuilder
    private var giphyRow: some View {
        SettingLabel(tr("chats.giphy.key"), hint: tr("chats.giphy.keyDetail"))
        HStack(spacing: NookTheme.Spacing.sm) {
            SecureField("", text: $giphyKey, prompt: Text(giphySet ? "••••••••" : tr("chats.giphy.key")).foregroundStyle(NookTheme.textTertiary))
                .labelsHidden()
                .settingsField()
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

    /// Adding a source: a website or an app's name typed in one field, or a Mac app picked from the Applications folder.
    private var addRow: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            SettingLabel(tr("chats.settings.addField"), hint: tr("chats.settings.addDetail"))
            HStack(spacing: NookTheme.Spacing.sm) {
                TextField("", text: $typed, prompt: Text(tr("chats.settings.addPrompt")).foregroundStyle(NookTheme.textTertiary))
                    .labelsHidden()
                    .settingsField()
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

    /// Another chat app whose notifications bring its chats, in the one connection row: the switch, and for an app you
    /// added yourself Remove in its "…" menu.
    private func row(_ source: MessagingApp) -> some View {
        // An app is only on while collecting is: switching one on switches collecting on with it.
        let isOn = Binding(get: { capture.enabled && capture.sources.isOn(source.id) },
                           set: { on in
                               capture.setSource(source.id, on: on)
                               if on, !capture.enabled { setCollecting(true) }
                           })
        let custom = !MessagingApps.builtIn.contains { $0.id == source.id }
        return ConnectionRow(title: source.name, status: isOn.wrappedValue ? .connected : .off,
                             statusText: isOn.wrappedValue ? tr("connection.fromNotifications") : nil,
                             detail: origin(source), isOn: isOn,
                             removal: custom ? ConnectionRemoval(title: tr("chats.settings.remove", source.name),
                                                                 question: tr("confirm.remove", source.name),
                                                                 detail: tr("connection.removeSourceDetail")) {
                                 capture.removeSource(source.id)
                             } : nil) {
            SiteIcon(domain: source.site, fallback: "bubble.left.fill", tint: NookTheme.textSecondary, size: 22, source: source.id)
        } menu: {
            EmptyView()
        }
    }

    /// "Mac app and telegram.org": where an app's notifications come from.
    private func origin(_ source: MessagingApp) -> String {
        let app = source.bundleIDs.isEmpty ? nil : tr("chats.settings.macApp")
        let sites = source.domains.isEmpty ? nil : source.domains.joined(separator: ", ")
        return [app, sites].compactMap { $0 }.joined(separator: " · ")
    }

    private func setCollecting(_ on: Bool) {
        ChatCollecting.set(on)
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
