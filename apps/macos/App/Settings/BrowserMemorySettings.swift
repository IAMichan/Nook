import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Browser: whether Nook's browser remembers the pages you visit (for the address bar's suggestions), and a
/// way to clear them.
struct BrowserHistoryRow: View {
    @AppStorage(BrowserHistory.enabledKey) private var enabled = true
    @State private var count = 0

    var body: some View {
        SettingToggle(tr("settings.browser.history"), detail: tr("settings.browser.history.detail"), isOn: Binding(
            get: { enabled },
            set: {
                enabled = $0
                if !$0 { clear() }
            }))
        if enabled && count > 0 {
            HStack {
                SettingLabel(tr("settings.browser.history.kept"), detail: tr("settings.browser.history.count", count))
                Spacer()
                Button(tr("settings.browser.history.clear")) { clear() }
            }
        }
        Color.clear.frame(height: 0)
            .task { count = await Task.detached { BrowserHistory.shared.count }.value }
    }

    private func clear() {
        BrowserHistory.shared.clear()
        count = 0
    }
}

/// Settings › Browser › Saved passwords: the sign-ins the browser saved, with their site and user name, to copy or
/// remove, and the sites you said never to save for.
struct BrowserPasswordsRow: View {
    @ObservedObject private var passwords = BrowserPasswords.shared

    var body: some View {
        let book = passwords.book
        SettingsFold(tr("settings.browser.passwords"),
                     summary: book.credentials.isEmpty ? tr("settings.browser.passwords.detail") : tr("settings.browser.passwords.count", book.credentials.count)) {
            if book.credentials.isEmpty {
                SettingNote(tr("settings.browser.passwords.empty"))
            }
            ForEach(book.credentials.sorted { $0.site == $1.site ? $0.username < $1.username : $0.site < $1.site }) { credential in
                HStack(spacing: NookTheme.Spacing.sm) {
                    SiteIcon(domain: credential.site, fallback: "key", tint: NookTheme.textTertiary, size: 15)
                    SettingLabel(credential.site, detail: credential.username.isEmpty ? tr("browser.passwords.noUsername") : credential.username)
                    Spacer()
                    Button(tr("settings.browser.passwords.copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(credential.password, forType: .string)
                        ToastCenter.shared.success(tr("settings.browser.passwords.copied"))
                    }
                    Button(tr("settings.browser.passwords.remove")) { passwords.remove(credential.id) }
                }
            }
            if !book.neverSites.isEmpty {
                SettingNote(tr("settings.browser.passwords.never"))
                ForEach(book.neverSites, id: \.self) { site in
                    HStack {
                        Text(verbatim: site).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.paper)
                        Spacer()
                        Button(tr("settings.browser.passwords.allow")) { passwords.allowAgain(site) }
                    }
                }
            }
        }
        // Read from the Keychain vault only once the page is open, not while Settings draws its other pages.
        .onAppear { passwords.loadIfNeeded() }
    }
}

/// Settings › Browser › Extensions: the web extensions in Nook's browser, added from the Chrome Web Store (a link, or
/// the "Add to Nook" bar on a store page) or from a file, to turn off or remove.
struct BrowserExtensionsSettings: View {
    @ObservedObject private var extensions = BrowserExtensions.shared
    @State private var link = ""

    var body: some View {
        Section(tr("settings.browser.extensions")) {
            if !BrowserExtensions.isSupported {
                SettingNote(tr("browser.extensions.unsupported"), tone: .warning)
            } else {
                SettingNote(tr("settings.browser.extensions.detail"))
                ForEach(extensions.installed) { item in
                    HStack(spacing: NookTheme.Spacing.sm) {
                        SettingLabel(item.name, detail: item.version.isEmpty ? tr(item.fromStore ? "settings.browser.extensions.fromStore" : "settings.browser.extensions.fromFile")
                                     : tr("settings.browser.extensions.version", item.version))
                        Spacer()
                        if extensions.hasOptions(item.id) {
                            Button(tr("browser.extensions.options")) { extensions.openOptions(item.id) }
                        }
                        Toggle(tr("settings.browser.extensions.on"), isOn: Binding(
                            get: { item.enabled }, set: { extensions.setEnabled(item.id, $0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        Button(tr("browser.extensions.remove")) { extensions.remove(item.id) }
                    }
                }
                HStack(spacing: NookTheme.Spacing.sm) {
                    TextField(tr("settings.browser.extensions.link"), text: $link)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addLink)
                    Button(tr(extensions.installing == nil ? "browser.extensions.add" : "browser.extensions.adding"), action: addLink)
                        .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || extensions.installing != nil)
                }
                HStack {
                    Button(tr("settings.browser.extensions.openStore")) {
                        if let url = URL(string: "https://chromewebstore.google.com") { BrowserStore.show(url) }
                    }
                    Button(tr("settings.browser.extensions.fromFileButton"), action: pickFile)
                        .disabled(extensions.installing != nil)
                }
            }
        }
    }

    private func addLink() {
        let text = link
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            await extensions.installFromStore(text)
            if extensions.has(storeID: ChromeWebStore.extensionID(from: text) ?? "") { link = "" }
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder, UTType(filenameExtension: "crx") ?? .data]
        panel.message = tr("settings.browser.extensions.pickMessage")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await extensions.installFromFile(url) }
    }
}
