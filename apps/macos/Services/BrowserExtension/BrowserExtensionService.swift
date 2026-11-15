import AppKit
import Combine

/// Nook's browser extension on the app's side: the socket its host talks to (`browser.sock`), the host script and the
/// browsers' host manifests (written once the user connects a browser in Settings › Editor & browser), the copy of the extension
/// a browser loads, and the side panel's questions, answered by the same assistant and conversations as Nook Chat.
/// The bookkeeping of commands lives in `BrowserExtensionHub`; the tools in `BrowserExtensionTools`.
@MainActor
final class BrowserExtensionService: ObservableObject {
    static let shared = BrowserExtensionService()

    /// The user connected Nook to their browsers (Settings › Editor & browser › Nook in your browser).
    nonisolated static let enabledKey = "browserExtension.enabled"

    let hub = BrowserExtensionHub()

    /// The browsers whose extension is connected now, the one used last first.
    @Published private(set) var connected: [BrowserExtensionClient] = []
    /// The browsers that have Nook's host manifest.
    @Published private(set) var installedBrowsers: [String] = []
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: BrowserExtensionService.enabledKey)
    @Published private(set) var error: String?

    weak var app: AppModel?
    private let server = UnixSocketServer(path: NookPaths.browserSocketURL.path)
    private var serving = false

    private var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private init() {
        hub.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        hub.onClientsChanged = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        hub.onRequest = { [weak self] client, message, reply in
            // The dictionary stays on this thread's copy; only what the app needs crosses to the main actor.
            let request = BrowserExtensionRequest(message)
            Task { @MainActor in
                guard let self else {
                    _ = reply(BrowserExtensionHub.encode(["ok": false, "error": "Nook is not ready."]))
                    return
                }
                _ = reply(BrowserExtensionHub.encode(self.answer(request, from: client)))
                self.refresh()
            }
        }
        // The socket's own thread hands each line to the hub, which is thread-safe; the main actor is not involved.
        let hub = self.hub
        server.onMessage = { data, connection in
            hub.handle(data) { connection.reply($0) }
        }
    }

    // MARK: - Lifecycle

    /// At launch: when the user connected before, the host is brought up to date and Nook listens.
    func start(app: AppModel) {
        self.app = app
        guard enabled else { return }
        install()
    }

    /// Settings › Connect: writes the host and its manifests, puts a copy of the extension where a browser can load it,
    /// and starts listening.
    func connect() {
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        enabled = true
        install()
        app?.store.audit(tool: "browser_extension_connect", args: installedBrowsers.joined(separator: ", "), result: error ?? "ok")
    }

    /// Settings › Disconnect: the browsers can no longer start the host, and Nook stops listening.
    func disconnect() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        enabled = false
        BrowserExtensionHost.uninstall(script: NookPaths.browserHostScriptURL, applicationSupport: applicationSupport)
        server.stop()
        serving = false
        BrowserExtensionRefs.shared.forget()
        refresh()
        app?.store.audit(tool: "browser_extension_disconnect", args: "", result: "ok")
    }

    private func install() {
        do {
            try BrowserExtensionHost.install(script: NookPaths.browserHostScriptURL, applicationSupport: applicationSupport)
            try copyExtension()
            if !serving {
                try server.start()
                serving = true
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
            Log.connectors.error("Browser extension: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    /// The extension as the app carries it (`apps/browser-extension`), copied to a folder that stays put across
    /// updates, so a browser that loaded it from there keeps finding it.
    private func copyExtension() throws {
        guard let bundled = Bundle.main.url(forResource: "browser-extension", withExtension: nil) else { return }
        let fm = FileManager.default
        let target = NookPaths.browserExtensionDirectory
        let staging = target.deletingLastPathComponent().appendingPathComponent(".browser-extension-new", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: bundled, to: staging)
        // Tests and their tooling stay in the repository.
        for leftover in ["test", "package.json", "README.md"] {
            try? fm.removeItem(at: staging.appendingPathComponent(leftover))
        }
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: target)
        }
    }

    /// Reads who is connected and which browsers have the host. Cheap: no browser is asked anything.
    func refresh() {
        let now = hub.connected
        if now != connected { connected = now }
        let browsers = enabled ? BrowserExtensionHost.installedBrowsers(script: NookPaths.browserHostScriptURL, applicationSupport: applicationSupport) : []
        if browsers != installedBrowsers { installedBrowsers = browsers }
    }

    /// Shows the extension's folder in Finder, for the browser's "Load unpacked".
    func revealExtension() {
        NSWorkspace.shared.activateFileViewerSelecting([NookPaths.browserExtensionDirectory])
    }

    /// The address of the extensions page of the first Chromium browser on this Mac ("chrome://extensions"), copied
    /// for the user to paste, and that browser brought to the front. Browsers do not open their own pages when another
    /// app asks, so pasting it is the one way that always works.
    func copyExtensionsAddress() {
        let pages: [(bundle: String, address: String)] = [
            ("com.google.Chrome", "chrome://extensions"),
            ("com.brave.Browser", "brave://extensions"),
            ("com.microsoft.edgemac", "edge://extensions"),
            ("company.thebrowser.Browser", "arc://extensions"),
            ("com.vivaldi.Vivaldi", "vivaldi://extensions"),
            ("org.chromium.Chromium", "chrome://extensions")
        ]
        let page = pages.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundle) != nil } ?? pages[0]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(page.address, forType: .string)
        ToastCenter.shared.success(tr("browserExt.settings.copied", page.address))
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: page.bundle) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - The side panel

    /// A question from the side panel, reading its conversation, or stopping Nook's answer.
    private func answer(_ request: BrowserExtensionRequest, from client: BrowserExtensionClient) -> [String: Any] {
        guard let app else { return ["ok": false, "error": "Nook is not ready."] }
        switch request.kind {
        case "ask":
            guard app.settings.brainReady else { return ["ok": false, "error": "nobrain"] }
            guard let text = CompanionPolicy.cleanMessage(request.text) else { return ["ok": false, "error": tr("browserExt.panel.empty")] }
            let id: UUID
            if let asked = request.conversation.flatMap(UUID.init(uuidString:)), app.chat.conversation(asked) != nil {
                id = asked
            } else {
                id = app.chat.startInBackground()
            }
            app.ask(text, in: id, reveal: false, note: BrowserExtensionPanel.note(page: request.page, browser: client.browser))
            app.store.audit(tool: "browser_extension_ask", args: client.browser, result: app.chat.conversation(id)?.title ?? "")
            return ["ok": true, "conversation": id.uuidString, "messages": lines(id)]
        case "chat":
            guard let id = request.conversation.flatMap(UUID.init(uuidString:)), app.chat.conversation(id) != nil else {
                return ["ok": false, "error": "unknown"]
            }
            return ["ok": true, "conversation": id.uuidString, "messages": lines(id)]
        case "stopChat":
            guard let id = request.conversation.flatMap(UUID.init(uuidString:)), app.chat.conversation(id) != nil else {
                return ["ok": false, "error": "unknown"]
            }
            app.stop(conversation: id)
            return ["ok": true, "conversation": id.uuidString, "messages": lines(id)]
        case "look":
            // The side panel draws Nook's theme, accent and density, so it reads as the same app as the main window.
            let settings = app.settings
            return BrowserExtensionLook.payload(choice: settings.themeChoice, themes: settings.themes,
                                                accent: settings.accentHex, defaultAccent: NookTheme.defaultAccentHex,
                                                density: settings.density, diffColors: settings.diffColors)
        default:
            return ["ok": false, "error": "Nook does not know \"\(request.kind)\"."]
        }
    }

    /// The conversation as the side panel shows it: the newest messages, each clipped like on the iPhone companion.
    private func lines(_ id: UUID) -> [[String: Any]] {
        guard let conversation = app?.chat.conversation(id) else { return [] }
        return conversation.messages.suffix(40).map { message in
            [
                "id": message.id.uuidString,
                "fromNook": message.role == .nook,
                "text": CompanionPolicy.clip(message.text),
                "streaming": message.streaming,
                "status": CompanionPolicy.clip(message.status, limit: 120),
                "failed": message.isError,
                "onMac": !message.actions.isEmpty || !message.mails.isEmpty || !message.charts.isEmpty
            ]
        }
    }
}

/// The parts of a side panel request the app reads, taken out of the JSON on the socket's thread.
struct BrowserExtensionRequest: Sendable {
    let kind: String
    let text: String
    let conversation: String?
    let page: BrowserExtensionPanel.Page?

    init(_ message: [String: Any]) {
        kind = (message["kind"] as? String) ?? ""
        text = (message["text"] as? String) ?? ""
        conversation = message["conversation"] as? String
        page = (message["page"] as? [String: Any]).flatMap(BrowserExtensionPanel.Page.init)
    }
}
