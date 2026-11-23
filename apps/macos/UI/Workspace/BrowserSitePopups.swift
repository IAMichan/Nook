import AppKit
import WebKit

/// A window a page in Nook's browser opens of its own with `window.open`: above all the sign-in windows of "Continue with
/// Google" (or Apple, Microsoft, …). The window keeps its tie to the page that opened it (`window.opener`), which the
/// sign-in uses to hand its answer back, and closes when the page closes it (`window.close()`). A link that only asks for
/// a new tab (`target="_blank"`) opens as a tab instead (`BrowserPage.webView(_:createWebViewWith:…)`).
@MainActor
final class BrowserSitePopup: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    /// The windows open now; each holds itself here until it closes.
    private static var open: [BrowserSitePopup] = []

    private let window: NSWindow
    let webView: WKWebView
    private var titleWatch: NSKeyValueObservation?

    /// A window for `navigationAction`, with the configuration WebKit hands over (the opener's own, which it must use).
    /// WebKit loads the request in the web view returned.
    static func open(configuration: WKWebViewConfiguration, features: WKWindowFeatures,
                     over parent: NSWindow?) -> WKWebView {
        let popup = BrowserSitePopup(configuration: configuration, features: features, over: parent)
        open.append(popup)
        return popup.webView
    }

    /// Whether a request for a new window is a page's own window (sized, or opened from a script) rather than a link
    /// that asks for a new tab.
    static func isWindow(_ action: WKNavigationAction, features: WKWindowFeatures) -> Bool {
        if features.width != nil || features.height != nil { return true }
        if features.toolbarsVisibility?.boolValue == false || features.menuBarVisibility?.boolValue == false { return true }
        // `window.open` without sizes comes as `.other`; a clicked `target="_blank"` link as `.linkActivated`.
        return action.navigationType == .other
    }

    private init(configuration: WKWebViewConfiguration, features: WKWindowFeatures, over parent: NSWindow?) {
        let size = NSSize(width: min(max(features.width?.doubleValue ?? 500, 360), 1200),
                          height: min(max(features.height?.doubleValue ?? 640, 420), 1000))
        webView = BrowserWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = tr("browser.popup.title")
        // Over the window the page is in, where you clicked; the window floats when that one does (the notch, the popup).
        if let parent {
            window.level = parent.level
            let frame = parent.frame
            window.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                          y: min(frame.maxY - 40, frame.midY + size.height / 2) - size.height))
        } else {
            window.center()
        }
        titleWatch = webView.observe(\.title) { [weak self] web, _ in
            MainActor.assumeIsolated {
                guard let self, let title = web.title, !title.isEmpty else { return }
                self.window.title = title
            }
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: WKNavigationDelegate

    /// Web pages only, as in the browser; on Google's sign-in pages the window calls itself Firefox (`WebSignInAgent`).
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .download }
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        guard ["http", "https", "about", "blob", "data"].contains(scheme) else {
            if scheme == "mailto", let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
            return .cancel
        }
        return webView.presentsItself(for: navigationAction, otherwise: nil) ? .cancel : .allow
    }

    /// Downloads, dialogs and file fields work here as in the browser's tabs (`BrowserDownloads`, `BrowserPageDialogs`).
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        BrowserDownloads.policy(for: navigationResponse)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        BrowserDownloads.shared.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        BrowserDownloads.shared.track(download)
    }

    @objc(_webView:contextMenuDidCreateDownload:)
    func contextMenuDidCreate(_ webView: WKWebView, download: WKDownload) {
        BrowserDownloads.shared.track(download)
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        await BrowserPageDialogs.alert(message, frame: frame, in: webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await BrowserPageDialogs.confirm(message, frame: frame, in: webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        await BrowserPageDialogs.prompt(prompt, defaultText: defaultText, frame: frame, in: webView)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        await BrowserPageDialogs.chooseFiles(parameters, in: webView)
    }

    /// A window this window opens in turn (a second step of a sign-in) opens in this one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    /// The page closed its window, mostly once you signed in.
    func webViewDidClose(_ webView: WKWebView) {
        window.close()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        titleWatch = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        window.delegate = nil
        Self.open.removeAll { $0 === self }
    }
}
