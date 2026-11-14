import AppKit
import Combine
import WebKit

/// Web extensions in Nook's browser: added from the Chrome Web Store (the "Add to Nook" bar on an extension's store page,
/// or a link pasted in Settings › Browser) or from a file (a folder, a .zip or a .crx). WebKit runs them
/// (`WKWebExtensionController`, macOS 15.4 and later): their content scripts, background, storage and toolbar popup.
/// Every tab of every browser (Nook's own and each session's) is a tab they see, and every browser a window.
///
/// The extensions' files live in Application Support › Nook › BrowserExtensions, the list in `browserExtensions.json`
/// beside it; what an extension stores itself stays in the controller's own store between launches.
@MainActor
final class BrowserExtensions: ObservableObject {
    static let shared = BrowserExtensions()

    /// One extension you added.
    struct Installed: Codable, Equatable, Identifiable {
        /// The Chrome Web Store id, or a made-up one for an extension from a file.
        let id: String
        var name: String
        var version: String
        var fromStore: Bool
        var enabled: Bool
    }

    /// One extension's button in a browser's toolbar.
    struct Button: Identifiable {
        let id: String
        let name: String
        let icon: NSImage?
        let badge: String
    }

    @Published private(set) var installed: [Installed] = []
    /// The extension being added now (its store id, or the file's name), while it downloads and loads.
    @Published private(set) var installing: String?
    /// Bumped when an extension's button changes (its icon or badge), so toolbars draw again.
    @Published private(set) var actionsVersion = 0

    /// Whether this Mac's WebKit runs extensions (macOS 15.4 and later).
    static var isSupported: Bool {
        if #available(macOS 15.4, *) { return true }
        return false
    }

    private let folder = NookPaths.supportDirectory.appendingPathComponent("BrowserExtensions", isDirectory: true)
    private var listFile: URL { NookPaths.supportDirectory.appendingPathComponent("browserExtensions.json") }
    /// The WebKit side, made on first use (`Engine`), typed loosely so this class needs no availability check.
    private var engineBox: AnyObject?

    private init() {
        if let data = try? Data(contentsOf: listFile), let list = try? JSONDecoder().decode([Installed].self, from: data) {
            installed = list
        }
    }

    @available(macOS 15.4, *)
    private var engine: Engine {
        if let made = engineBox as? Engine { return made }
        let made = Engine(owner: self)
        engineBox = made
        made.loadAll(installed.filter(\.enabled), folder: folder)
        return made
    }

    /// A new web view's configuration: its pages get the extensions, also the ones you add while it is open. The
    /// extensions start the first time a browser opens.
    func configure(_ configuration: WKWebViewConfiguration) {
        guard #available(macOS 15.4, *) else { return }
        configuration.webExtensionController = engine.controller
    }

    // MARK: Adding and removing

    /// Downloads an extension from the Chrome Web Store (a store link or its id) and adds it.
    func installFromStore(_ input: String) async {
        guard let id = ChromeWebStore.extensionID(from: input) else {
            ToastCenter.shared.error(tr("browser.extensions.badLink"))
            return
        }
        guard #available(macOS 15.4, *) else { return unsupported() }
        if installed.contains(where: { $0.id == id }) {
            ToastCenter.shared.info(tr("browser.extensions.already"))
            return
        }
        guard installing == nil, let url = ChromeWebStore.downloadURL(id: id) else { return }
        installing = id
        defer { installing = nil }
        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(ChromeWebStore.chromeVersion) Safari/537.36",
                             forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) || data.isEmpty {
                throw NookError(tr("browser.extensions.downloadFailed"))
            }
            let zip = try ChromeWebStore.zip(fromPackage: data)
            try await add(zip: zip, id: id, fromStore: true)
        } catch {
            ToastCenter.shared.error(error, title: tr("browser.extensions.failed"))
        }
    }

    /// Adds an extension from a file you picked: a folder with a manifest.json, a .zip or a .crx.
    func installFromFile(_ url: URL) async {
        guard #available(macOS 15.4, *) else { return unsupported() }
        guard installing == nil else { return }
        installing = url.lastPathComponent
        defer { installing = nil }
        do {
            let id = "file-" + UUID().uuidString.lowercased()
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let copy = folder.appendingPathComponent(id, isDirectory: true)
                try FileManager.default.copyItem(at: url, to: copy)
                try await finishAdding(at: copy, id: id, fromStore: false)
            } else {
                let zip = try ChromeWebStore.zip(fromPackage: try Data(contentsOf: url))
                try await add(zip: zip, id: id, fromStore: false)
            }
        } catch {
            ToastCenter.shared.error(error, title: tr("browser.extensions.failed"))
        }
    }

    @available(macOS 15.4, *)
    private func add(zip: Data, id: String, fromStore: Bool) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(id + ".zip")
        try zip.write(to: file, options: .atomic)
        do {
            try await finishAdding(at: file, id: id, fromStore: fromStore)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    @available(macOS 15.4, *)
    private func finishAdding(at file: URL, id: String, fromStore: Bool) async throws {
        let loaded = try await engine.load(id: id, file: file)
        let entry = Installed(id: id, name: loaded.displayName ?? id, version: loaded.displayVersion ?? loaded.version ?? "",
                              fromStore: fromStore, enabled: true)
        installed.append(entry)
        saveList()
        ToastCenter.shared.success(tr("browser.extensions.added", entry.name), detail: tr("browser.extensions.addedDetail"))
    }

    /// Removes an extension and what it stored.
    func remove(_ id: String) {
        if #available(macOS 15.4, *), engineBox != nil { engine.unload(id: id, deleteData: true) }
        installed.removeAll { $0.id == id }
        saveList()
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id + ".zip"))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id, isDirectory: true))
        actionsVersion += 1
    }

    /// Turns an extension off (it stops running, keeps what it stored) or on again.
    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].enabled = enabled
        saveList()
        if #available(macOS 15.4, *) {
            if enabled { engine.loadAll([installed[index]], folder: folder) } else if engineBox != nil { engine.unload(id: id, deleteData: false) }
        }
        actionsVersion += 1
    }

    /// Whether the extension a store page is about is added already.
    func has(storeID id: String) -> Bool { installed.contains { $0.id == id } }

    private func unsupported() {
        ToastCenter.shared.error(tr("browser.extensions.unsupported"))
    }

    private func saveList() {
        guard let data = try? JSONEncoder().encode(installed) else { return }
        try? data.write(to: listFile, options: .atomic)
    }

    // MARK: Toolbar

    /// The buttons of the extensions running in a browser's tab, in the order you added them.
    func buttons(for page: BrowserPage) -> [Button] {
        guard #available(macOS 15.4, *), engineBox != nil else { return [] }
        _ = actionsVersion
        return engine.buttons(for: page, order: installed.filter(\.enabled).map(\.id))
    }

    /// An extension's button was clicked in a tab: its popup opens beside `anchor`, or it does its own action.
    func click(_ id: String, page: BrowserPage, anchor: NSView?) {
        guard #available(macOS 15.4, *), engineBox != nil else { return }
        engine.popupAnchor = anchor
        engine.perform(id: id, page: page)
    }

    /// The options page of an extension, opened in Nook's own browser.
    func openOptions(_ id: String) {
        guard #available(macOS 15.4, *), engineBox != nil, let url = engine.optionsURL(id: id) else { return }
        BrowserStore.show(url)
    }

    func hasOptions(_ id: String) -> Bool {
        guard #available(macOS 15.4, *), engineBox != nil else { return false }
        return engine.optionsURL(id: id) != nil
    }

    fileprivate func actionsChanged() { actionsVersion += 1 }

    // MARK: Tabs and windows

    /// A browser opened (its first tab included).
    func opened(_ store: BrowserStore) {
        guard #available(macOS 15.4, *), engineBox != nil else { return }
        engine.opened(store)
    }

    func openedTab(_ page: BrowserPage) {
        guard #available(macOS 15.4, *), engineBox != nil else { return }
        engine.openedTab(page)
    }

    func activated(_ page: BrowserPage, previous: BrowserPage?) {
        guard #available(macOS 15.4, *), engineBox != nil else { return }
        engine.activated(page, previous: previous)
    }

    func closedTab(_ page: BrowserPage, windowClosing: Bool = false) {
        guard #available(macOS 15.4, *), engineBox != nil else { return }
        engine.closedTab(page, windowClosing: windowClosing)
    }

    func changed(_ page: BrowserPage) {
        guard #available(macOS 15.4, *), engineBox != nil else { return }
        engine.changed(page)
    }

    func closed(_ store: BrowserStore) {
        guard #available(macOS 15.4, *), engineBox != nil else { return }
        engine.closed(store)
    }

    /// Every browser open now: Nook's own and the sessions'.
    fileprivate static var openBrowsers: [BrowserStore] {
        (BrowserStore.existing.map { [$0] } ?? []) + SessionBrowsers.shared.allStores
    }
}

// MARK: - WebKit

@available(macOS 15.4, *)
@MainActor
private final class Engine: NSObject, WKWebExtensionControllerDelegate {
    let controller: WKWebExtensionController
    weak var owner: BrowserExtensions?
    /// The loaded extensions by their id in the list.
    private var contexts: [String: WKWebExtensionContext] = [:]
    private var tabs: [ObjectIdentifier: ExtensionTab] = [:]
    private var windows: [ObjectIdentifier: ExtensionWindow] = [:]
    /// The button just clicked, for the popup to open beside.
    weak var popupAnchor: NSView?

    private static let identifierKey = "browser.extensions.controllerID"

    init(owner: BrowserExtensions) {
        self.owner = owner
        // A fixed identifier: what the extensions store (settings, lists) stays between launches.
        let saved = UserDefaults.standard.string(forKey: Self.identifierKey).flatMap(UUID.init(uuidString:))
        let id = saved ?? UUID()
        if saved == nil { UserDefaults.standard.set(id.uuidString, forKey: Self.identifierKey) }
        controller = WKWebExtensionController(configuration: WKWebExtensionController.Configuration(identifier: id))
        super.init()
        controller.delegate = self
    }

    func loadAll(_ list: [BrowserExtensions.Installed], folder: URL) {
        for entry in list where contexts[entry.id] == nil {
            let zip = folder.appendingPathComponent(entry.id + ".zip")
            let file = FileManager.default.fileExists(atPath: zip.path) ? zip : folder.appendingPathComponent(entry.id, isDirectory: true)
            Task { _ = try? await load(id: entry.id, file: file) }
        }
    }

    /// Loads an extension's files and starts it with the permissions it asks for: adding it is saying yes to them.
    func load(id: String, file: URL) async throws -> WKWebExtension {
        let webExtension = try await WKWebExtension(resourceBaseURL: file)
        if let known = contexts[id] { try? controller.unload(known) }
        let context = WKWebExtensionContext(for: webExtension)
        // A stable address per extension, so its storage and options are found again after a relaunch.
        context.uniqueIdentifier = id
        context.isInspectable = true
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in webExtension.requestedPermissionMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        try controller.load(context)
        contexts[id] = context
        // The browsers already open become its windows.
        for store in BrowserExtensions.openBrowsers { opened(store) }
        owner?.actionsChanged()
        return webExtension
    }

    func unload(id: String, deleteData: Bool) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        try? controller.unload(context)
        if deleteData {
            controller.fetchDataRecord(ofTypes: WKWebExtensionController.allExtensionDataTypes, for: context) { [weak self] record in
                guard let record else { return }
                self?.controller.removeData(ofTypes: WKWebExtensionController.allExtensionDataTypes, from: [record]) {}
            }
        }
    }

    func optionsURL(id: String) -> URL? { contexts[id]?.optionsPageURL }

    // MARK: Toolbar

    func buttons(for page: BrowserPage, order: [String]) -> [BrowserExtensions.Button] {
        let tab = tabs[ObjectIdentifier(page)]
        return order.compactMap { id in
            guard let context = contexts[id] else { return nil }
            let action = context.action(for: tab)
            let name = context.webExtension.displayShortName ?? context.webExtension.displayName ?? id
            return BrowserExtensions.Button(id: id, name: action?.label.isEmpty == false ? action!.label : name,
                                            icon: action?.icon(for: CGSize(width: 16, height: 16))
                                                ?? context.webExtension.icon(for: CGSize(width: 16, height: 16)),
                                            badge: action?.badgeText ?? "")
        }
    }

    func perform(id: String, page: BrowserPage) {
        guard let context = contexts[id] else { return }
        context.performAction(for: tab(for: page))
    }

    // MARK: Tabs and windows

    private func window(for store: BrowserStore) -> ExtensionWindow {
        if let known = windows[ObjectIdentifier(store)] { return known }
        let made = ExtensionWindow(store: store, engine: self)
        windows[ObjectIdentifier(store)] = made
        return made
    }

    func tab(for page: BrowserPage) -> ExtensionTab {
        if let known = tabs[ObjectIdentifier(page)] { return known }
        let made = ExtensionTab(page: page, engine: self)
        tabs[ObjectIdentifier(page)] = made
        return made
    }

    func extensionWindow(for store: BrowserStore?) -> ExtensionWindow? {
        store.map(window(for:))
    }

    func opened(_ store: BrowserStore) {
        guard windows[ObjectIdentifier(store)] == nil else { return }
        controller.didOpenWindow(window(for: store))
        for page in store.pages { openedTab(page) }
    }

    func openedTab(_ page: BrowserPage) {
        guard tabs[ObjectIdentifier(page)] == nil else { return }
        controller.didOpenTab(tab(for: page))
    }

    func activated(_ page: BrowserPage, previous: BrowserPage?) {
        controller.didActivateTab(tab(for: page), previousActiveTab: previous.flatMap { tabs[ObjectIdentifier($0)] })
        owner?.actionsChanged()
    }

    func closedTab(_ page: BrowserPage, windowClosing: Bool) {
        guard let tab = tabs.removeValue(forKey: ObjectIdentifier(page)) else { return }
        controller.didCloseTab(tab, windowIsClosing: windowClosing)
    }

    func changed(_ page: BrowserPage) {
        guard let tab = tabs[ObjectIdentifier(page)] else { return }
        controller.didChangeTabProperties([.URL, .title, .loading], for: tab)
    }

    func closed(_ store: BrowserStore) {
        for page in store.pages { closedTab(page, windowClosing: true) }
        guard let window = windows.removeValue(forKey: ObjectIdentifier(store)) else { return }
        controller.didCloseWindow(window)
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        BrowserExtensions.openBrowsers.map(window(for:))
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        let store = SessionBrowsers.shared.shownInPanel ?? BrowserStore.existing
        return store.map(window(for:))
    }

    /// An extension opens a tab (its welcome page, a link): in Nook's own browser.
    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        let store = BrowserStore.shared
        let page = configuration.shouldBeActive ? store.newTab() : store.newBackgroundTab()
        if let url = configuration.url { page.open(url) }
        if configuration.shouldBeActive { BrowserPopup.shared.show() }
        completionHandler(tab(for: page), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        if let url = extensionContext.optionsPageURL { BrowserStore.show(url) }
        completionHandler(nil)
    }

    /// Permissions an extension asks for while it runs: only the ones its manifest names as optional, which you saw it
    /// could ask for when you added it.
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        completionHandler(permissions.intersection(extensionContext.webExtension.optionalPermissions), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let optional = extensionContext.webExtension.optionalPermissionMatchPatterns
        completionHandler(matchPatterns.filter { pattern in optional.contains { $0.matches(pattern) } }, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let optional = extensionContext.webExtension.optionalPermissionMatchPatterns
        completionHandler(urls.filter { url in optional.contains { $0.matches(url) } }, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        owner?.actionsChanged()
    }

    /// The extension's popup, under the button you clicked (or in the middle of the window in front).
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popover = action.popupPopover else {
            completionHandler(NookError(tr("browser.extensions.noPopup")))
            return
        }
        if let anchor = popupAnchor, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if let view = NSApp.keyWindow?.contentView {
            popover.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.maxY - 40, width: 1, height: 1), of: view, preferredEdge: .minY)
        }
        completionHandler(nil)
    }
}

/// A browser as the extensions see it: a window with its tabs.
@available(macOS 15.4, *)
@MainActor
private final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var store: BrowserStore?
    weak var engine: Engine?

    init(store: BrowserStore, engine: Engine) {
        self.store = store
        self.engine = engine
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let store, let engine else { return [] }
        return store.pages.map(engine.tab(for:))
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let store, let engine else { return nil }
        return engine.tab(for: store.page)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        store?.webView.window?.frame ?? .null
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if store?.session == nil { BrowserPopup.shared.show() }
        completionHandler(nil)
    }
}

/// A browser's tab as the extensions see it.
@available(macOS 15.4, *)
@MainActor
private final class ExtensionTab: NSObject, WKWebExtensionTab {
    weak var page: BrowserPage?
    weak var engine: Engine?

    init(page: BrowserPage, engine: Engine) {
        self.page = page
        self.engine = engine
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        engine?.extensionWindow(for: page?.store)
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let page, let store = page.store else { return 0 }
        return store.pages.firstIndex { $0 === page } ?? 0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { page?.webView }
    func title(for context: WKWebExtensionContext) -> String? { page?.title }
    func url(for context: WKWebExtensionContext) -> URL? { page?.webView.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(page?.loading ?? false) }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let page, let store = page.store else { return false }
        return store.page === page
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        page?.open(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { page?.webView.reloadFromOrigin() } else { page?.webView.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        page?.webView.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        page?.webView.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let page { page.store?.select(page.id) }
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let page { page.store?.close(page.id) }
        completionHandler(nil)
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
}
