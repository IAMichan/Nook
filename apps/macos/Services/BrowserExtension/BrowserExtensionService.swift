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
    /// The browser profiles that have the extension, from their own preferences (`BrowserExtensionHost.extensionInstalls`),
    /// so Settings can say "found in Chrome" before the extension says hello, and skip the steps to load it.
    @Published private(set) var installs: [BrowserExtensionHost.Install] = []
    private var scanning = false
    /// Set by Connect until the first browser says hello, which then gets a toast: the user sees it worked.
    private var greetFirstBrowser = false

    weak var app: AppModel?
    private let server = UnixSocketServer(path: NookPaths.browserSocketURL.path)
    private var serving = false
    /// Side panels that follow a conversation: Nook pushes each change to them (`push` on the hub) instead of the panel
    /// asking every second, so an answer streams into the browser as fast as in Nook's own window.
    private var watches: [UUID: Watch] = [:]
    private var watching: AnyCancellable?
    /// The models Ollama and LM Studio offered when the side panel last asked, for its brain chip.
    private var servers: [ServerModel] = []

    /// The browsers that follow a conversation, each with the revision it has, so one browser reading the conversation
    /// never counts as another one having it.
    private struct Watch {
        var clients: [String: String]
        var until: Date
    }

    /// How long a side panel keeps getting a conversation's changes after it last asked for them.
    static let watchFor: TimeInterval = 10 * 60

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
    /// When no browser has the extension yet, it also opens its Chrome Web Store page in the user's browser, so the one
    /// thing left is "Add to Chrome"; the extension then connects by itself and Settings sees it.
    func connect() {
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        enabled = true
        greetFirstBrowser = connected.isEmpty
        install()
        app?.store.audit(tool: "browser_extension_connect", args: installedBrowsers.joined(separator: ", "), result: error ?? "ok")
        guard error == nil else { return }
        Task { @MainActor in
            // Its own scan: one Settings started at the same moment may still be reading.
            let found = await Self.readInstalls(applicationSupport)
            if found != installs { installs = found }
            guard enabled, connected.isEmpty, found.isEmpty else { return }
            openStorePage()
        }
    }

    /// Settings › Disconnect: the browsers can no longer start the host, and Nook stops listening.
    func disconnect() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        enabled = false
        greetFirstBrowser = false
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
        if now != connected {
            if greetFirstBrowser, connected.isEmpty, let first = now.first {
                greetFirstBrowser = false
                ToastCenter.shared.success(tr("browserExt.settings.connected", first.browser.isEmpty ? tr("browserExt.source.unnamed") : first.browser))
            }
            connected = now
        }
        let browsers = enabled ? BrowserExtensionHost.installedBrowsers(script: NookPaths.browserHostScriptURL, applicationSupport: applicationSupport) : []
        if browsers != installedBrowsers { installedBrowsers = browsers }
    }

    /// Reads which browser profiles have the extension, off the main thread (a profile's preferences run to a few MB).
    /// Settings asks again every few seconds while it waits, so loading the extension shows without a click.
    func scanInstalls() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let found = await Self.readInstalls(applicationSupport)
        if found != installs { installs = found }
    }

    private nonisolated static func readInstalls(_ support: URL) async -> [BrowserExtensionHost.Install] {
        await Task.detached(priority: .utility) {
            BrowserExtensionHost.extensionInstalls(applicationSupport: support)
        }.value
    }

    /// The browsers that have the extension, by name, once each; `enabled` picks the ones where it is switched on or off.
    func browsersWithExtension(enabled: Bool) -> [String] {
        var names: [String] = []
        for install in installs where install.enabled == enabled && !names.contains(install.browser) {
            names.append(install.browser)
        }
        return names
    }

    /// The extension's Chrome Web Store page, in the default browser when that is a Chromium one, else in the first
    /// Chromium browser on this Mac (Safari cannot add it).
    func openStorePage() {
        let url = BrowserExtensionHost.storeURL
        let chromium = Self.extensionPages.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundle) }
        let fallback = chromium.first
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { app in chromium.contains(app) ? app : nil }
        guard let browser = preferred ?? fallback else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
    }

    private static let extensionPages: [(name: String, bundle: String, address: String)] = [
        ("Google Chrome", "com.google.Chrome", "chrome://extensions"),
        ("Brave", "com.brave.Browser", "brave://extensions"),
        ("Microsoft Edge", "com.microsoft.edgemac", "edge://extensions"),
        ("Arc", "company.thebrowser.Browser", "arc://extensions"),
        ("Vivaldi", "com.vivaldi.Vivaldi", "vivaldi://extensions"),
        ("Chromium", "org.chromium.Chromium", "chrome://extensions")
    ]

    /// The address of the extensions page of a Chromium browser on this Mac ("chrome://extensions"), copied for the
    /// user to paste, and that browser brought to the front: the one named (where the extension is switched off), else
    /// the first one installed. Browsers do not open their own pages when another app asks, so pasting it is the one
    /// way that always works.
    func openExtensionsPage(in browser: String? = nil) {
        let pages = Self.extensionPages
        let installed = pages.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundle) != nil }
        let page = installed.first { $0.name == browser } ?? installed.first ?? pages[0]
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
            // The page's text goes with the question but stays on this Mac: only a brain that may see the user's
            // browser gets it (`answer` checks the privacy level and what the user keeps here). While the browser stays
            // here, the screen brain on this Mac reads it and hands the chosen brain a filtered note, or does what the
            // question asks on the page itself (`AppModel.ask`, `pageWorker`).
            let settings = app.settings
            let kept = settings.privateSources.contains(BrowserExtensionTools.sourceID)
            let privacy: BrowserExtensionPanel.Privacy = !kept ? .shared : settings.pageWorker != nil ? .readHere : .keptHere
            let reading = request.page?.reading.map { ScreenSnapshot(appName: $0.site, windowTitle: $0.title, text: $0.text) }
            // Pictures from the composer, scaled and encoded as every picture Nook sends a model (`ImageAttachment`).
            let images = request.images.enumerated().compactMap { index, image in
                NSImage(data: image.data).flatMap { ImageAttachment(image: $0, name: "browser-\(index + 1)") }
            }
            app.ask(text, images: images, in: id, reveal: false, note: BrowserExtensionPanel.note(page: request.page, browser: client.browser, privacy: privacy),
                    page: privacy == .keptHere ? nil : reading)
            app.store.audit(tool: "browser_extension_ask", args: client.browser, result: app.chat.conversation(id)?.title ?? "")
            return conversationReply(id, watchedBy: client.id)
        case "chat":
            guard let id = request.conversation.flatMap(UUID.init(uuidString:)), app.chat.conversation(id) != nil else {
                return ["ok": false, "error": "unknown"]
            }
            // Reading further back: the messages before the oldest one the panel has, without following.
            if let before = request.before.flatMap(UUID.init(uuidString:)) {
                guard let index = app.chat.conversation(id)?.messages.firstIndex(where: { $0.id == before }) else {
                    return ["ok": false, "error": "unknown"]
                }
                let (messages, earlier) = lines(id, before: index)
                return ["ok": true, "conversation": id.uuidString, "messages": messages, "earlier": earlier, "older": true]
            }
            return conversationReply(id, watchedBy: request.watch ? client.id : nil)
        case "chats":
            // The panel's "Earlier chats" menu: only the conversations it started itself (it sends their ids).
            let known = app.chat.conversations.map {
                BrowserExtensionPanel.Chat(id: $0.id, title: $0.title, updated: $0.updated, busy: $0.busy, messages: $0.messages.count)
            }
            return ["ok": true, "chats": BrowserExtensionPanel.chats(asked: request.conversations, known: known)]
        case "stopChat":
            guard let id = request.conversation.flatMap(UUID.init(uuidString:)), app.chat.conversation(id) != nil else {
                return ["ok": false, "error": "unknown"]
            }
            app.stop(conversation: id)
            return conversationReply(id, watchedBy: client.id)
        case "look":
            // The side panel draws Nook's theme, accent and density, so it reads as the same app as the main window.
            let settings = app.settings
            return BrowserExtensionLook.payload(choice: settings.themeChoice, themes: settings.themes,
                                                accent: settings.accentHex, defaultAccent: NookTheme.defaultAccentHex,
                                                density: settings.density, diffColors: settings.diffColors)
        case "brain":
            // The composer's brain chip: the same choices as the chip in Nook's own composer. The local servers answer
            // over the network, so their models come in the next time the panel asks.
            Task { [weak self] in self?.servers = await app.localServerModels() }
            return BrowserExtensionBrain.payload(app: app, servers: servers)
        case "setBrain":
            guard BrowserExtensionBrain.choose(request.choice, app: app, servers: servers) else {
                return ["ok": false, "error": tr("browserExt.panel.unknownModel")]
            }
            app.store.audit(tool: "browser_extension_brain", args: client.browser, result: app.settings.brainLabel)
            return BrowserExtensionBrain.payload(app: app, servers: servers)
        default:
            return ["ok": false, "error": "Nook does not know \"\(request.kind)\"."]
        }
    }

    /// The conversation for the side panel, and from now on its changes pushed to that browser (`live`).
    private func conversationReply(_ id: UUID, watchedBy client: String?) -> [String: Any] {
        let (messages, earlier) = lines(id)
        let revision = BrowserExtensionPanel.revision(messages)
        if let client { watch(id, client: client, revision: revision) }
        return ["ok": true, "conversation": id.uuidString, "messages": messages, "earlier": earlier, "revision": revision,
                "live": client != nil]
    }

    private func watch(_ id: UUID, client: String, revision: String) {
        var entry = watches[id] ?? Watch(clients: [:], until: .distantPast)
        entry.clients[client] = revision
        entry.until = Date().addingTimeInterval(Self.watchFor)
        watches[id] = entry
        guard watching == nil, let chat = app?.chat else { return }
        // A model streams many small changes a second; the browser gets the newest at most every 100 ms.
        watching = chat.$conversations
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                // `@Published` sends before it stores the new value: read it once this change is done.
                Task { @MainActor in self?.pushChanges() }
            }
    }

    /// Sends every followed conversation that changed to the browsers that follow it.
    private func pushChanges() {
        let now = Date()
        for (id, var entry) in watches {
            guard entry.until > now, app?.chat.conversation(id) != nil else {
                watches[id] = nil
                continue
            }
            let (messages, earlier) = lines(id)
            let revision = BrowserExtensionPanel.revision(messages)
            guard entry.clients.values.contains(where: { $0 != revision }) else { continue }
            let event: [String: Any] = ["kind": "chat", "conversation": id.uuidString, "messages": messages, "earlier": earlier,
                                        "revision": revision]
            for (client, has) in entry.clients where has != revision {
                entry.clients[client] = hub.push(event, to: client, key: "chat:" + id.uuidString) ? revision : nil
            }
            watches[id] = entry.clients.isEmpty ? nil : entry
        }
        if watches.isEmpty {
            watching?.cancel()
            watching = nil
        }
    }

    /// The conversation as the side panel shows it: the newest messages (or with `before` the page before that index),
    /// each clipped like on the iPhone companion, and how many come before them.
    private func lines(_ id: UUID, before: Int? = nil) -> (messages: [[String: Any]], earlier: Int) {
        guard let conversation = app?.chat.conversation(id) else { return ([], 0) }
        let page = BrowserExtensionPanel.page(count: conversation.messages.count, before: before)
        let messages = conversation.messages[page.range].map { message in
            var line: [String: Any] = [
                "id": message.id.uuidString,
                // When it was said, for the time beside it and to jump through the conversation (milliseconds).
                "at": Int(message.date.timeIntervalSince1970 * 1000),
                "fromNook": message.role == .nook,
                "text": CompanionPolicy.clip(message.text),
                "streaming": message.streaming,
                "status": CompanionPolicy.clip(message.status, limit: 120),
                "failed": message.isError,
                // What Nook says about how it answered ("read on this Mac, only a filtered note went out"), as on the Mac.
                "notice": CompanionPolicy.clip(message.notices.last ?? "", limit: 240),
                "onMac": !message.actions.isEmpty || !message.mails.isEmpty || !message.charts.isEmpty
            ]
            // Where Nook looked and the plan it keeps, drawn as in Nook's own window.
            if let sources = BrowserExtensionTranscript.sources(message) { line["sources"] = sources }
            let tasks = BrowserExtensionTranscript.tasks(message)
            if !tasks.isEmpty { line["tasks"] = tasks }
            return line
        }
        return (messages, page.earlier)
    }
}
