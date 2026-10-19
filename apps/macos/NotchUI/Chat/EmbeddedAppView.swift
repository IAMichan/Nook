import SwiftUI
import WebKit

/// The app open next to Nook's chat ("@open whatsapp"). Each web app keeps its own sign-in across launches in a store of
/// its own; a Mac app is shown live by `MacAppMirror`. Nook only reads what it shows when you ask (a read tool), and
/// never types or clicks in it itself.
@MainActor
final class EmbeddedAppStore: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = EmbeddedAppStore()

    @Published private(set) var current: EmbeddedApp?
    @Published private(set) var loading = false
    /// Why the app did not load, if it did not.
    @Published private(set) var lastError: String?
    /// One web view per app opened this launch: switching back is instant and WhatsApp stays connected meanwhile.
    private var views: [String: WKWebView] = [:]

    var webView: WKWebView? { current.flatMap { views[$0.id] } }

    func open(_ app: EmbeddedApp) {
        lastError = nil
        if app.isMacApp {
            current = app
            loading = false
            MacAppMirror.shared.open(app)
            return
        }
        if current?.isMacApp == true { MacAppMirror.shared.close() }
        if views[app.id] == nil {
            let view = makeWebView(for: app)
            views[app.id] = view
            view.load(URLRequest(url: app.url))
        }
        current = app
        loading = views[app.id]?.isLoading ?? false
    }

    /// Hides the app; it stays signed in and keeps running until Nook quits, so opening it again is instant.
    func close() {
        if current?.isMacApp == true { MacAppMirror.shared.close() }
        current = nil
        loading = false
    }

    func reload() {
        if current?.isMacApp == true { return MacAppMirror.shared.restart() }
        guard let webView = webView else { return }
        if webView.url == nil, let app = current { webView.load(URLRequest(url: app.url)) } else { webView.reload() }
    }

    /// Signs out of the open app on this Mac: its web view and everything it stored (cookies, the WhatsApp link) go.
    func forget() async {
        guard let app = current else { return }
        close()
        guard !app.isMacApp else { return }
        // The store can only go once no web view uses it any more.
        views[app.id]?.removeFromSuperview()
        views[app.id] = nil
        try? await Task.sleep(nanoseconds: 300_000_000)
        try? await WKWebsiteDataStore.remove(forIdentifier: app.storeID)
    }

    /// The open app in the user's own browser.
    func openInDefaultBrowser() {
        if current?.isMacApp == true { return MacAppMirror.shared.bringToFront() }
        guard let url = webView?.url ?? current?.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// What the open app shows now, as text: for Nook to read when the user asks about it.
    func pageText() async throws -> (title: String, url: String, text: String) {
        if current?.isMacApp == true { return try await MacAppMirror.shared.text() }
        guard let app = current, let webView = webView else { throw NookError(tr("embedded.nothingOpen")) }
        let result = try await webView.evaluateJavaScript("document.body ? document.body.innerText : ''")
        let text = ((result as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (app.title, webView.url?.absoluteString ?? app.url.absoluteString, String(text.prefix(14_000)))
    }

    private func makeWebView(for app: EmbeddedApp) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: app.storeID)
        // Present as Safari: WhatsApp Web and others refuse browsers they do not know.
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    // MARK: Tools

    /// Reading the app beside the chat. Static, so offering it to the model does not start WebKit.
    static var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "read_open_app",
                description: "Reads what the app open next to the chat shows right now (opened with @open, for example WhatsApp Web or a Mac app such as WhatsApp): its visible text. Use it when the user asks about what is in that app (\"what did Arjan write?\", \"summarize this chat\").",
                schema: ["type": "object", "properties": [String: Any](), "required": [String]()],
                kind: .read,
                summarize: { _ in "Read the open app" },
                tag: { _ in ("", .neutral) },
                run: { _ in
                    let page = try await EmbeddedAppStore.shared.pageText()
                    return "## \(page.title) (open next to the chat)\n\n\(page.text)\n\n" + ReferenceParser.line(title: page.title, url: page.url, detail: "Nook")
                }
            )
        ]
    }

    // MARK: WKNavigationDelegate, WKUIDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { refresh(webView, loading: true) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { refresh(webView, loading: false) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { lastError = error.localizedDescription }
        refresh(webView, loading: false)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { lastError = error.localizedDescription }
        refresh(webView, loading: false)
    }

    /// Web pages open inside; mail, phone and app links go to the system, other schemes are refused.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["http", "https", "about", "blob", "data"].contains(scheme) { return .allow }
        if ["mailto", "tel", "whatsapp"].contains(scheme) { NSWorkspace.shared.open(url) }
        return .cancel
    }

    /// A link that wants a new window (a shared link in a chat) opens in the user's own browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    private func refresh(_ webView: WKWebView, loading: Bool) {
        guard webView === self.webView else { return }
        self.loading = loading
    }
}

/// The pane beside the chat: the app's name and a few buttons on top, the app itself below.
struct EmbeddedAppPane: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = EmbeddedAppStore.shared
    @State private var asking = false

    var body: some View {
        if let current = store.current, current.isMacApp || store.webView != nil {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: current.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NookTheme.textSecondary)
                    Text(current.title)
                        .font(NookTheme.font(13, .semibold))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    if store.loading { ProgressView().controlSize(.small) }
                    Spacer(minLength: 8)
                    NookIconButton(systemName: "sparkles", label: tr("embedded.ask"), size: 28) { askAboutApp() }
                        .help(tr("embedded.ask"))
                        .disabled(asking)
                    NookIconButton(systemName: "arrow.clockwise", label: tr("embedded.reload"), size: 28) { store.reload() }
                        .help(tr("embedded.reload"))
                    let external = current.isMacApp ? tr("embedded.mac.bringToFront") : tr("browser.openExternal")
                    NookIconButton(systemName: "arrow.up.forward.app", label: external, size: 28) { store.openInDefaultBrowser() }
                        .help(external)
                    // A Mac app keeps its own sign-in; there is nothing of it in Nook to forget.
                    if !current.isMacApp {
                        Menu {
                            Button(tr("embedded.forget", current.title), role: .destructive) { Task { await app.closeEmbeddedApp(forget: true) } }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(NookTheme.textSecondary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .composerMenu()
                    }
                    NookIconButton(systemName: "xmark", label: tr("embedded.close"), size: 28) { Task { await app.closeEmbeddedApp() } }
                        .help(tr("embedded.close"))
                }
                .padding(.horizontal, 10)
                .frame(height: 38)
                Rectangle().fill(NookTheme.line).frame(height: 1)
                if current.isMacApp {
                    MacAppMirrorPane(app: current)
                } else if let webView = store.webView {
                    ZStack {
                        WebViewHost(webView: webView)
                        if let error = store.lastError, !store.loading {
                            WSEmptyState(symbol: "wifi.exclamationmark", title: tr("embedded.failed", current.title), message: error,
                                         action: (tr("embedded.reload"), { store.reload() }))
                                .background(NookTheme.field)
                        }
                    }
                }
            }
            .background(NookTheme.field)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(NookTheme.line2.opacity(0.6), lineWidth: 1))
        }
    }

    /// Hands what the app shows to the chat as an attachment, like dropping a file, so the next question is about it.
    private func askAboutApp() {
        asking = true
        Task {
            defer { asking = false }
            do {
                let page = try await store.pageText()
                app.attachText(name: page.title, text: "URL: \(page.url)\n\n\(page.text)")
            } catch {
                app.viewModel.present(app.errorCard(error.localizedDescription))
            }
        }
    }
}

/// The line between the chat and the app: drag it to give one more room than the other, double-click to reset.
struct EmbeddedSplitHandle: View {
    /// The horizontal distance dragged since the drag began.
    let onDrag: (Double) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(hovering || dragging ? NookTheme.line2 : Color(hex: 0x19191B))
                .frame(width: 1)
            Capsule()
                .fill(hovering || dragging ? NookTheme.textSecondary : NookTheme.line2)
                .frame(width: 4, height: 36)
        }
        .frame(width: EmbeddedSplit.handle)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else if !dragging { NSCursor.pop() }
        }
        .gesture(
            // Global coordinates: the line itself moves while you drag it.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    dragging = true
                    onDrag(Double(value.translation.width))
                }
                .onEnded { _ in
                    dragging = false
                    if !hovering { NSCursor.pop() }
                    onEnd()
                }
        )
        .onTapGesture(count: 2) { onReset() }
        .help(tr("embedded.resize"))
        .accessibilityLabel(tr("embedded.resize"))
    }
}
