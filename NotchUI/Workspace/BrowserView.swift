import SwiftUI
import WebKit

/// The browser in Nook's window. You browse as usual; Nook can read the open page when you ask (a read tool), and only
/// navigates on its own after your approval (an action). It keeps no history beyond the session and stores no passwords.
@MainActor
final class BrowserStore: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = BrowserStore()

    @Published var address = ""
    @Published private(set) var title = ""
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    let webView: WKWebView

    override init() {
        let configuration = WKWebViewConfiguration()
        // Nothing persists between launches: no cookies or storage on disk.
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    /// Opens what the user typed: an address, or otherwise a search.
    func go(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let url: URL?
        if text.contains("."), !text.contains(" "), let parsed = URL(string: text.hasPrefix("http") ? text : "https://" + text) {
            url = parsed
        } else {
            var components = URLComponents(string: "https://duckduckgo.com/")
            components?.queryItems = [URLQueryItem(name: "q", value: text)]
            url = components?.url
        }
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        webView.load(URLRequest(url: url))
    }

    /// The visible text of the open page (for Nook to read), with its address.
    func pageText() async throws -> (title: String, url: String, text: String) {
        guard let url = webView.url else { throw NookError(tr("workbench.browser.nothingOpen")) }
        let result = try await webView.evaluateJavaScript("document.body ? document.body.innerText : ''")
        let text = ((result as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (webView.title ?? url.absoluteString, url.absoluteString, String(text.prefix(14_000)))
    }

    // MARK: Tools

    /// Reading the open page runs right away; going somewhere is an action that waits for approval.
    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "read_nook_browser",
                description: "Reads the text of the page open in Nook's own browser (Workspace › Browser), with its title and address.",
                schema: ["type": "object", "properties": [String: Any](), "required": [String]()],
                kind: .read,
                summarize: { _ in "Read Nook's browser" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] _ in
                    guard let self else { throw NookError(tr("workbench.browser.nothingOpen")) }
                    let page = try await self.pageText()
                    return "## \(page.title)\nURL: \(page.url)\n\n\(page.text)\n\n" + ReferenceParser.line(title: page.title, url: page.url, detail: "Nook browser")
                }
            ),
            ToolSpec(
                name: "open_in_nook_browser",
                description: "Opens a web address in Nook's own browser so the user can look at it together with Nook. Only https addresses.",
                schema: ["type": "object", "properties": ["url": ["type": "string", "description": "The full https address."]], "required": ["url"]],
                kind: .action,
                summarize: { input in "Browser: open \((input["url"] as? String) ?? "")" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let raw = input["url"] as? String, let url = URL(string: raw), url.scheme?.lowercased() == "https" else {
                        throw NookError("Only https addresses can be opened.")
                    }
                    self?.webView.load(URLRequest(url: url))
                    AppModel.shared.openMainWindow(.workspace, tool: .browser)
                    return "Opened \(url.absoluteString) in Nook's browser"
                }
            )
        ]
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { refresh(loading: true) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { refresh(loading: false) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { refresh(loading: false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { refresh(loading: false) }

    /// Only web pages open inside; mail, phone and app links go to the system, other schemes are refused.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        if ["http", "https", "about", "blob", "data"].contains(scheme) { return .allow }
        if scheme == "mailto", let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return .cancel
    }

    private func refresh(loading: Bool) {
        self.loading = loading
        title = webView.title ?? ""
        if let url = webView.url?.absoluteString { address = url }
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
}

/// Hosts the browser's web view in a container without an intrinsic size, so the window's layout does not loop.
private final class WebViewContainer: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = WebViewContainer()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}

/// Workspace › Browser.
struct BrowserView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = BrowserStore.shared
    @State private var asking = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { store.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!store.canGoBack)
                Button { store.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!store.canGoForward)
                Button {
                    if store.loading { store.webView.stopLoading() } else { _ = store.webView.reload() }
                } label: {
                    Image(systemName: store.loading ? "xmark" : "arrow.clockwise")
                }
                TextField(tr("workbench.browser.address"), text: $store.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { store.go(store.address) }
                Button {
                    askAboutPage()
                } label: {
                    Label(tr("workbench.browser.ask"), systemImage: "sparkles")
                }
                .disabled(store.webView.url == nil || asking)
            }
            .buttonStyle(.borderless)
            .padding(10)
            Divider()
            if store.webView.url == nil && !store.loading {
                WSEmptyState(symbol: "safari", title: tr("workbench.browser.emptyTitle"), message: tr("workbench.browser.emptyMessage"), action: nil)
            }
            WebViewHost(webView: store.webView)
                .opacity(store.webView.url == nil && !store.loading ? 0 : 1)
        }
    }

    /// Hands the open page to the chat as an attachment, like dropping a file.
    private func askAboutPage() {
        asking = true
        Task {
            defer { asking = false }
            do {
                let page = try await store.pageText()
                app.attachText(name: page.title, text: "URL: \(page.url)\n\n\(page.text)")
                if WorkspaceWindowController.shared.isKey { app.openMainWindow(.chat) } else { app.showChat() }
            } catch {
                app.viewModel.present(app.errorCard(error.localizedDescription))
            }
        }
    }
}

/// Workspace: the tools that work alongside chats and agents.
struct WorkbenchView: View {
    enum Tool: String, CaseIterable, Identifiable {
        case terminals, browser, worktrees
        var id: String { rawValue }
        var title: String { tr("workbench." + rawValue) }
        var symbol: String {
            switch self {
            case .terminals: return "terminal"
            case .browser: return "safari"
            case .worktrees: return "arrow.triangle.branch"
            }
        }
    }

    @AppStorage("workbench.tool") private var tool: Tool = .terminals

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tool) {
                ForEach(Tool.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            .padding(.top, 10)
            Group {
                switch tool {
                case .terminals: TerminalsView()
                case .browser: BrowserView()
                case .worktrees: WorktreesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: .nookWorkbenchTool)) { note in
            if let raw = note.object as? String, let target = Tool(rawValue: raw) { tool = target }
        }
    }
}
