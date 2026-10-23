import SwiftUI
import AppKit
import Security
import UniformTypeIdentifiers

/// Settings › Chats: every chat app at a glance first (which are linked, as whom, and the others with a Link button that
/// walks a link through its steps in `ChatAppSheet`), then the notifications Nook collects from any other app, how
/// reading works, and the GIF key. Someone coming from Beeper first sees what Nook can bring over from it.
struct ChatsSettingsSection: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var capture = ChatCaptureService.shared
    @ObservedObject private var beeper = BeeperImporter.shared
    @State private var typed = ""
    @State private var notice: String?
    /// The last thing typed could not be added: its note reads as a warning.
    @State private var noticeIsProblem = false
    @State private var giphyKey = ""
    @State private var giphySet = Giphy.ownKey != nil
    @AppStorage(ChatsTab.readOnOpenKey) private var readOnOpen = true

    var body: some View {
        Group {
            if beeper.isOffered {
                BeeperImportSection(setCollecting: setCollecting)
            }

            ChatAppsSection(setCollecting: setCollecting)

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
                giphyRow
            } header: {
                Text(tr("chats.giphy.title"))
            } footer: {
                Text(tr("chats.giphy.footer"))
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

    /// One app whose notifications Nook collects: its icon, name and where its messages come from, with its switch (and a
    /// remove button when you added it). The chat apps Nook links are in the overview above instead.
    private func row(_ source: MessagingApp) -> some View {
        // An app is only on while collecting is: switching one on switches collecting on with it.
        let isOn = Binding(get: { capture.enabled && capture.sources.isOn(source.id) },
                           set: { on in
                               capture.setSource(source.id, on: on)
                               if on, !capture.enabled { setCollecting(true) }
                           })
        return Toggle(isOn: isOn) { label(source) }
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
