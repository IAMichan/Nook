import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings › Chats: everything the Chats tab shows, on its own page. WhatsApp through the linked phone, and every other
/// chat app whose notifications Nook collects: switch each app on or off, or add your own (a website such as
/// linkedin.com/messaging, or a Mac app) in one line.
struct ChatsSettingsSection: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var capture = ChatCaptureService.shared
    @State private var typed = ""
    @State private var notice: String?

    var body: some View {
        Group {
            Section {
                SettingToggle(tr("chats.settings.collect"), detail: tr("chats.settings.collectDetail"),
                              isOn: Binding(get: { capture.enabled }, set: { setCollecting($0) }))
                if capture.status == .needsAccess {
                    HStack(spacing: NookTheme.Spacing.md) {
                        Image(systemName: "lock.fill").foregroundStyle(NookTheme.amber)
                        Text(tr("chats.capture.needsAccess"))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: NookTheme.Spacing.sm)
                        Button(tr("chats.capture.grant")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            } header: {
                Text(tr("chats.settings.otherApps"))
            } footer: {
                Text(tr("chats.settings.privacy"))
            }

            Section {
                HStack(spacing: NookTheme.Spacing.sm) {
                    TextField(tr("chats.settings.addField"), text: $typed, prompt: Text(tr("chats.settings.addPrompt")))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addTyped() }
                    Button(tr("chats.settings.add")) { addTyped() }
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(tr("chats.settings.chooseApp")) { chooseMacApp() }
                }
                if let notice {
                    Text(notice)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                }
                ForEach(capture.sources.apps) { source in
                    row(source)
                }
            } header: {
                Text(tr("chats.settings.sources"))
            } footer: {
                Text(tr("chats.settings.sourcesFooter"))
            }

            WhatsAppLinkSection()
        }
    }

    /// One app: its icon, name and where its messages come from, with its switch (and a remove button when you added it).
    private func row(_ source: MessagingApp) -> some View {
        let custom = !MessagingApps.builtIn.contains { $0.id == source.id }
        return Toggle(isOn: Binding(get: { capture.sources.isOn(source.id) },
                                    set: { capture.setSource(source.id, on: $0) })) {
            HStack(spacing: NookTheme.Spacing.md) {
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
            typed = ""
            notice = tr("chats.settings.added", source.name)
            if !capture.enabled { setCollecting(true) }
        case .known(let source):
            typed = ""
            notice = tr("chats.settings.known", source.name)
            if !capture.enabled { setCollecting(true) }
        case .invalid:
            notice = tr("chats.settings.invalid")
        }
    }
}
