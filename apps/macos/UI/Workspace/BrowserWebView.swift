import AppKit
import WebKit

/// The web view of Nook's browser and of the windows its pages open. While you are on the page it answers the keys every
/// browser has:
///
/// - ⌘R loads the page again, ⌘⇧R past the cache; ⌘. and Escape stop a page that is loading
/// - ⌘[ and ⌘] go back and forward
/// - ⌘+, ⌘- and ⌘0 zoom
/// - ⌘L goes to the address bar, ⌘F finds on the page (⌘G and ⌘⇧G to the next and previous match)
/// - ⌘T opens a tab, ⌘W closes this one (the last tab stays, so ⌘W then does what it does elsewhere), ⌘⇧T opens the tab
///   you closed last
/// - ⌘P prints the page
/// - ⌘Y shows your history, ⌥⌘B your bookmarks (`BrowserLibraryView`)
///
/// Its right-click menu opens a link in a new tab instead of a new window.
final class BrowserWebView: WKWebView {
    /// What the browser around the page does for a key; nil in a page's own window, where these keys do nothing.
    enum Request {
        case newTab, closeTab, reopenTab, focusAddress, history, bookmarks
        /// Finds on the page: 0 opens the find bar, 1 and -1 go to the next and previous match.
        case find(Int)
    }

    /// Asks the browser showing this web view for one of the `Request`s (`BrowserView`): the web view is the object,
    /// the request is under `requestKey`.
    static let request = Notification.Name("BrowserWebView.request")
    static let requestKey = "request"
    private static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    /// The tab keys (⌘T, ⌘W, ⌘⇧T); true when they did something. Set by the tab that owns this web view.
    var tabKey: ((Request) -> Bool)?
    /// Nook reloads the page (your button or key, or the crash reload), as opposed to the page's own `location.reload()`:
    /// the tab's `BrowserReloadGuard` starts counting again.
    var reloadedByNook: (() -> Void)?
    /// When "Open Link in New Tab" in the right-click menu was chosen: the window WebKit asks for next becomes a tab.
    private var tabWindowAsked: Date?
    /// The menu item WebKit put in the right-click menu for opening a link in a new window, which ours runs.
    private var openLinkItem: (target: AnyObject?, action: Selector)?

    override func reload() -> WKNavigation? {
        reloadedByNook?()
        return super.reload()
    }

    override func reloadFromOrigin() -> WKNavigation? {
        reloadedByNook?()
        return super.reloadFromOrigin()
    }

    // MARK: Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only for the page you are on: elsewhere in the window (the composer, another panel) these keys are theirs.
        if let responder = window?.firstResponder as? NSView, responder === self || responder.isDescendant(of: self),
           handle(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Escape stops a page that is loading, as in Safari; otherwise the page gets it.
        if event.keyCode == 53, isLoading, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            stopLoading()
            return
        }
        super.keyDown(with: event)
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command), !flags.contains(.control),
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let shift = flags.contains(.shift)
        // ⌥⌘B is the one key with Option: the bookmarks, as in Safari and Chrome.
        if flags.contains(.option) { return key == "b" && !shift ? ask(.bookmarks) : false }
        switch (key, shift) {
        case ("r", false): reload()
        case ("r", true): reloadFromOrigin()
        case ("[", false): if canGoBack { goBack() }
        case ("]", false): if canGoForward { goForward() }
        case ("=", _), ("+", _): zoom(by: 1)
        case ("-", false): zoom(by: -1)
        case ("0", false): pageZoom = 1
        case (".", false): stopLoading()
        case ("p", false): printPage()
        case ("l", false): return ask(.focusAddress)
        case ("f", false): return ask(.find(0))
        case ("y", false): return ask(.history)
        case ("g", let back): return ask(.find(back ? -1 : 1))
        case ("t", false): return tabKey?(.newTab) ?? false
        case ("t", true): return tabKey?(.reopenTab) ?? false
        case ("w", false): return tabKey?(.closeTab) ?? false
        default: return false
        }
        return true
    }

    /// Hands a request to the browser around the page; a page's own window has none, so the key goes on.
    private func ask(_ request: Request) -> Bool {
        guard tabKey != nil else { return false }
        NotificationCenter.default.post(name: Self.request, object: self, userInfo: [Self.requestKey: request])
        return true
    }

    private func zoom(by step: Int) {
        let steps = Self.zoomSteps
        let current = steps.enumerated().min { abs($0.element - pageZoom) < abs($1.element - pageZoom) }?.offset ?? 5
        pageZoom = steps[min(max(current + step, 0), steps.count - 1)]
    }

    /// The print panel for the page, as a sheet on its window.
    func printPage() {
        guard let window else { return }
        let operation = printOperation(with: NSPrintInfo.shared)
        // Without a frame the page prints blank.
        operation.view?.frame = bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: Right-click menu

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        openLinkItem = nil
        // Tabs only exist in the browser itself; a page's own window keeps WebKit's menu as it is.
        guard tabKey != nil else { return }
        for item in menu.items where item.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" {
            guard let action = item.action else { continue }
            openLinkItem = (item.target, action)
            item.title = tr("browser.menu.openLinkInNewTab")
            item.target = self
            item.action = #selector(openLinkInNewTab(_:))
        }
    }

    @objc private func openLinkInNewTab(_ sender: NSMenuItem) {
        guard let openLinkItem else { return }
        tabWindowAsked = Date()
        NSApp.sendAction(openLinkItem.action, to: openLinkItem.target, from: sender)
    }

    /// Whether the window WebKit asks for now is the link you chose to open in a new tab. Asked once: WebKit asks for
    /// the window within moments (via the page's process), and an old choice must not turn a later window into a tab.
    func takeTabWindowRequest() -> Bool {
        defer { tabWindowAsked = nil }
        return tabWindowAsked.map { Date().timeIntervalSince($0) < 3 } ?? false
    }
}
