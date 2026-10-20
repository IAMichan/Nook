import SwiftUI
import AppKit
import Combine
import WebKit
import UniformTypeIdentifiers

// MCP apps in the timeline (see McpApp), hosted: the page runs in an iframe with
// `sandbox="allow-scripts allow-forms"` (an opaque origin, no popups, no way into Nook) under its own Content-Security-
// Policy, inside a host page that relays its messages to Nook and nothing else. Calling a tool that changes something,
// sending a message, opening a link and saving a file each ask you first. Fullscreen moves the same web view into a
// window that fills the screen, so the app keeps running and its state's web app.

/// The app of one tool call: inline, sized to what the page reports, or fullscreen.
struct McpAppBlock: View {
    @EnvironmentObject private var app: AppModel
    let resource: McpUI.Resource
    let event: RunEvent
    @StateObject private var session: McpAppSession

    init(resource: McpUI.Resource, event: RunEvent) {
        self.resource = resource
        self.event = event
        _session = StateObject(wrappedValue: McpAppSession(resource: resource, event: event))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let link = resource.link {
                Button(tr("ws.mcpApp.open")) { NSWorkspace.shared.open(link) }
                    .controlSize(.small)
                    .help(link.absoluteString)
            } else if session.closed || session.left {
                HStack(spacing: 8) {
                    Text(session.left ? tr("ws.mcpApp.left") : tr("ws.mcpApp.closed", session.reference.tool))
                        .font(NookTheme.font(11.5)).foregroundStyle(NookTheme.textTertiary)
                    Button(tr("ws.mcpApp.show")) { session.reload() }.controlSize(.small)
                }
            } else if session.html != nil {
                // The row keeps its inline height while the app is fullscreen, so the timeline does not jump.
                Group {
                    if session.mode == .fullscreen {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right").font(NookTheme.TextStyle.detail)
                            Text(tr("ws.mcpApp.isFullscreen")).font(NookTheme.font(11.5))
                            Button(tr("ws.mcpApp.exitFullscreen")) { session.exitFullscreen() }.controlSize(.small)
                        }
                        .foregroundStyle(NookTheme.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        McpAppSurface(session: session, mode: .inline)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: session.height)
                .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous))
                .overlay {
                    if session.reference.prefersBorder != false {
                        RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous).stroke(NookTheme.line2, lineWidth: 1)
                    }
                }
            }
        }
        .onAppear { session.attach(workspace: app.workspace) }
        .onReceive(app.workspace.$approvals) { approvals in
            // The agent waits for you: the app steps aside.
            if let runID = session.runID, approvals[runID]?.isEmpty == false, session.mode == .fullscreen { session.exitFullscreen() }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.on.square.dashed").font(NookTheme.font(10, .semibold))
            Text(session.reference.server.map { "\($0) · \(session.reference.tool)" } ?? tr("ws.mcpApp.title"))
                .font(NookTheme.font(11, .medium))
            Text(resource.uri).font(NookTheme.mono(10.5)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(NookTheme.textTertiary)
            Spacer(minLength: 4)
            if session.html != nil, !session.closed, !session.left, session.mode == .inline {
                ToolbarIconButton("arrow.up.left.and.arrow.down.right", tr("ws.mcpApp.fullscreen"), height: 20, width: 20) {
                    session.enterFullscreen()
                }
            }
        }
        .foregroundStyle(NookTheme.textSecondary)
    }
}

/// One running app: its web view, its JSON-RPC host and where it is shown. Lives as long as its row; the web view moves
/// between the row and the fullscreen window without loading again.
@MainActor
final class McpAppSession: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    @Published private(set) var mode: McpAppHost.DisplayMode = .inline
    @Published private(set) var height = McpApp.defaultHeight
    @Published private(set) var closed = false
    @Published private(set) var left = false

    let reference: McpApp.Reference
    let html: String?
    let eventID: UUID
    private(set) var runID: UUID?
    private(set) weak var workspace: WorkspaceManager?
    private(set) var webView: WKWebView?
    private(set) var host: McpAppHost?

    /// One app fullscreen at a time.
    private static weak var fullscreenSession: McpAppSession?
    private var window: McpAppWindow?

    init(resource: McpUI.Resource, event: RunEvent) {
        eventID = event.id
        if let saved = resource.app {
            reference = saved
            html = saved.file.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        } else {
            reference = McpApp.Reference(file: nil, server: nil, tool: event.tool ?? "app", resourceUri: resource.uri, csp: nil,
                                         permissions: nil, prefersBorder: nil, arguments: event.detail,
                                         result: event.output.map(McpUI.stripped))
            html = resource.html.map { McpApp.prepared($0, csp: nil) }
        }
        super.init()
    }

    func attach(workspace: WorkspaceManager) {
        self.workspace = workspace
        if runID == nil { runID = workspace.runID(containing: eventID) }
        if webView == nil { load() }
    }

    /// The web view, made once (and again after "Show app").
    private func load() {
        guard let html else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(WeakHandler(self), name: "nookApp")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        webView = view
        host = McpAppHost(reference: reference, hostVersion: Self.version, actions: actions())
        view.loadHTMLString(Self.hostPage(html: html, allow: McpApp.allowAttribute(reference.permissions)), baseURL: nil)
    }

    func reload() {
        dispose()
        closed = false
        left = false
        load()
    }

    private func dispose() {
        host?.dispose()
        host = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "nookApp")
        webView?.removeFromSuperview()
        webView = nil
    }

    private static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    // MARK: Fullscreen

    /// The same app over the whole screen; refused while the agent waits for you or another app is fullscreen.
    @discardableResult
    func enterFullscreen() -> Bool {
        guard mode == .inline, webView != nil else { return false }
        if let runID, workspace?.approvals[runID]?.isEmpty == false { return false }
        if let other = Self.fullscreenSession, other !== self { return false }
        Self.fullscreenSession = self
        mode = .fullscreen
        let window = McpAppWindow(session: self)
        self.window = window
        window.show()
        host?.updateHostContext()
        return true
    }

    /// Back in the row (Esc, the button, the window losing focus, the app's own request, or an approval).
    func exitFullscreen() {
        guard mode == .fullscreen else { return }
        mode = .inline
        if Self.fullscreenSession === self { Self.fullscreenSession = nil }
        let window = self.window
        self.window = nil
        window?.dismiss()
        host?.updateHostContext()
    }

    // MARK: Web view

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch body["nook"] as? String {
        case "left":
            exitFullscreen()
            host?.dispose()
            left = true
        case "message":
            if let data = body["data"] { host?.receive(data) }
        default:
            break
        }
    }

    /// The host page loads once; the app's own frame only its srcdoc. Everything else goes nowhere.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url?.absoluteString ?? ""
        return url == "about:blank" || url == "about:srcdoc" ? .allow : .cancel
    }

    /// The page around the app: relays only what the app's own frame posts, and notices when it leaves its page.
    static func hostPage(html: String, allow: String) -> String {
        let source = McpApp.json([html]).map { String($0.dropFirst().dropLast()) } ?? "\"\""
        let safe = source.replacingOccurrences(of: "</", with: "<\\/")
        let allowAttribute = allow.replacingOccurrences(of: "\"", with: "")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;height:100%;background:transparent;overflow:hidden}iframe{border:0;width:100%;height:100%;display:block}</style>
        </head><body><iframe id="app" sandbox="allow-scripts allow-forms" allow="\(allowAttribute)"></iframe>
        <script>
        (()=>{const frame=document.getElementById("app");let loads=0;
        frame.addEventListener("load",()=>{loads+=1;if(loads>1)window.webkit.messageHandlers.nookApp.postMessage({nook:"left"});});
        window.addEventListener("message",(event)=>{if(event.source!==frame.contentWindow)return;
        window.webkit.messageHandlers.nookApp.postMessage({nook:"message",data:event.data});});
        window.__nookDeliver=(message)=>{if(frame.contentWindow)frame.contentWindow.postMessage(message,"*");};
        frame.srcdoc=\(safe);})();
        </script></body></html>
        """
    }

    // MARK: What the app may ask

    private func actions() -> McpAppHost.Actions {
        McpAppHost.Actions(
            post: { [weak self] message in self?.deliver(message) },
            hostContext: { [weak self] in self?.hostContext() ?? [:] },
            callTool: { [weak self] name, arguments, done in self?.callTool(name, arguments, done) },
            readResource: { [weak self] uri, done in self?.readResource(uri, done) },
            openLink: { [weak self] url, done in
                guard let self else { return }
                guard self.confirm(tr("ws.mcpApp.confirmLink"), detail: url.absoluteString) else {
                    return done(.failure(McpAppHost.Refusal(message: tr("ws.mcpApp.declined"))))
                }
                NSWorkspace.shared.open(url)
                done(.success(()))
            },
            sendMessage: { [weak self] text, done in
                guard let self, let runID = self.runID, let workspace = self.workspace else {
                    return done(.failure(McpAppHost.Refusal(message: tr("ws.mcpApp.sessionStopped"))))
                }
                guard self.confirm(tr("ws.mcpApp.confirmMessage", self.reference.tool), detail: text) else {
                    return done(.failure(McpAppHost.Refusal(message: tr("ws.mcpApp.declined"))))
                }
                workspace.mcpAppSendMessage(runID, text: text)
                done(.success(()))
            },
            updateModelContext: { [weak self] text, done in
                guard let self, let runID = self.runID else { return done(.success(())) }
                self.workspace?.mcpAppSetContext(runID, key: String(self.eventID.uuidString.prefix(8)).lowercased(), text: text)
                done(.success(()))
            },
            requestDisplayMode: { [weak self] mode, done in
                guard let self else { return done(.inline) }
                switch mode {
                case .fullscreen: done(self.enterFullscreen() ? .fullscreen : self.mode)
                case .inline:
                    self.exitFullscreen()
                    done(.inline)
                }
            },
            downloadFiles: { [weak self] files, done in self?.download(files, done) },
            onSizeChanged: { [weak self] _, height in
                // Fullscreen is a fixed box: what the app reports there would leave the row its fullscreen height.
                guard let self, self.mode == .inline, let height else { return }
                self.height = McpApp.clampHeight(height)
            },
            onRequestTeardown: { [weak self] in
                guard let self else { return }
                if self.mode == .fullscreen { return self.exitFullscreen() }
                self.host?.teardown { [weak self] in self?.closed = true }
            }
        )
    }

    private func deliver(_ message: [String: Any]) {
        guard let json = McpApp.json(message) else { return }
        webView?.evaluateJavaScript("window.__nookDeliver(\(json))", completionHandler: nil)
    }

    private func hostContext() -> [String: Any] {
        let size = webView?.bounds.size ?? .zero
        let width = max(1, Double(size.width))
        let dimensions: [String: Any] = mode == .inline
            ? ["width": width, "maxHeight": McpApp.maxHeight]
            : ["width": width, "height": max(1, Double(size.height))]
        return [
            "theme": "dark",
            "styles": ["variables": Self.styleVariables],
            "displayMode": mode.rawValue,
            "availableDisplayModes": ["inline", "fullscreen"],
            "containerDimensions": dimensions,
            "platform": "desktop",
            "locale": Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
            "timeZone": TimeZone.current.identifier,
            "userAgent": "nook/\(Self.version)",
            "deviceCapabilities": ["touch": false, "hover": true],
            "toolInfo": ["tool": ["name": reference.tool]],
        ]
    }

    /// The size changed (the window was resized): the app hears it.
    func containerResized() { host?.updateHostContext() }

    /// Nook's colours and fonts for the app to match.
    private static let styleVariables: [String: String] = [
        "--color-background-primary": "#0F0F13", "--color-background-secondary": "#17171C",
        "--color-background-tertiary": "#1F1F26", "--color-background-inverse": "#F4F3F7",
        "--color-text-primary": "#F4F3F7", "--color-text-secondary": "#9C9AA8", "--color-text-tertiary": "#6F6D7C",
        "--color-text-inverse": "#0F0F13", "--color-text-danger": "#FF8A8A", "--color-text-success": "#5FE3B0",
        "--color-text-warning": "#FFB84D", "--color-border-primary": "#2C2C36", "--color-border-secondary": "#2C2C36",
        "--color-border-danger": "#FF6B6B", "--color-ring-primary": "#8B7CF6",
        "--font-sans": "-apple-system, BlinkMacSystemFont, sans-serif", "--font-mono": "ui-monospace, SFMono-Regular, Menlo, monospace",
        "--border-radius-md": "8px",
    ]

    private func callTool(_ name: String, _ arguments: [String: Any], _ done: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let server = reference.server, let runID, let workspace else {
            return done(.failure(McpAppHost.Refusal(message: tr("ws.mcpApp.noTools"))))
        }
        Task { @MainActor in
            do {
                let info = try await workspace.mcpAppToolInfo(runID, server: server, name: name)
                guard info.callable else { throw McpAppHost.Refusal(message: tr("ws.mcpApp.notCallable", name)) }
                // A tool that changes something runs only when you agree, with what it will be given.
                if !info.readOnly {
                    let detail = McpApp.json(arguments) ?? "{}"
                    guard self.confirm(tr("ws.mcpApp.confirmTool", server, info.title ?? name), detail: String(detail.prefix(2000))) else {
                        throw McpAppHost.Refusal(message: tr("ws.mcpApp.declined"))
                    }
                }
                done(.success(try await workspace.mcpAppCallTool(runID, server: server, name: name, arguments: arguments)))
            } catch {
                done(.failure(error))
            }
        }
    }

    private func readResource(_ uri: String, _ done: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let server = reference.server, let runID, let workspace else {
            return done(.failure(McpAppHost.Refusal(message: tr("ws.mcpApp.noTools"))))
        }
        Task { @MainActor in
            do { done(.success(try await workspace.mcpAppReadResource(runID, server: server, uri: uri))) } catch { done(.failure(error)) }
        }
    }

    /// Files the app offers: after you agree, each saved where you choose (at most 25 MB each).
    private func download(_ files: [McpAppHost.Download], _ done: @escaping (Result<Void, Error>) -> Void) {
        let names = files.map { file -> String in
            switch file {
            case .embedded(let name, _, _): return name
            case .link(let name, _): return name
            }
        }
        guard confirm(tr("ws.mcpApp.confirmDownload", reference.tool), detail: names.joined(separator: "\n")) else {
            return done(.failure(McpAppHost.Refusal(message: tr("ws.mcpApp.declined"))))
        }
        Task { @MainActor in
            do {
                for file in files {
                    switch file {
                    case .embedded(let name, _, let data):
                        try self.save(data, name: name)
                    case .link(let name, let uri):
                        guard let server = self.reference.server, let runID = self.runID, let workspace = self.workspace else {
                            throw McpAppHost.Refusal(message: tr("ws.mcpApp.noTools"))
                        }
                        let read = try await workspace.mcpAppReadResource(runID, server: server, uri: uri)
                        let first = ((read["contents"] as? [Any]) ?? []).first as? [String: Any]
                        let data = (first?["text"] as? String).map { Data($0.utf8) }
                            ?? (first?["blob"] as? String).flatMap { Data(base64Encoded: $0) }
                        guard let data else { throw McpAppHost.Refusal(message: tr("ws.mcpApp.downloadEmpty")) }
                        try self.save(data, name: name)
                    }
                }
                done(.success(()))
            } catch {
                done(.failure(error))
            }
        }
    }

    private func save(_ data: Data, name: String) throws {
        guard data.count <= 25 * 1024 * 1024 else { throw McpAppHost.Refusal(message: tr("ws.mcpApp.downloadTooLarge")) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { throw McpAppHost.Refusal(message: tr("ws.mcpApp.declined")) }
        try data.write(to: url, options: .atomic)
    }

    private func confirm(_ title: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: tr("ws.mcpApp.allow"))
        alert.addButton(withTitle: tr("button.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Where the app's web view is shown: the row, or the fullscreen window. The view moves in when this place is the
/// one in use, without loading again.
struct McpAppSurface: NSViewRepresentable {
    @ObservedObject var session: McpAppSession
    let mode: McpAppHost.DisplayMode

    func makeNSView(context: Context) -> McpAppContainer {
        let container = McpAppContainer()
        container.session = session
        return container
    }

    func updateNSView(_ container: McpAppContainer, context: Context) {
        container.session = session
        if session.mode == mode { container.adopt(session.webView) }
    }
}

final class McpAppContainer: NSView {
    weak var session: McpAppSession?

    func adopt(_ view: WKWebView?) {
        guard let view, view.superview !== self else { return }
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    override func layout() {
        super.layout()
        session?.containerResized()
    }
}

/// The fullscreen window: the app over the screen with a thin bar to leave; Esc, or clicking outside it, brings it back
/// to its row.
@MainActor
final class McpAppWindow: NSObject, NSWindowDelegate {
    private weak var session: McpAppSession?
    private let window: NSWindow

    init(session: McpAppSession) {
        self.session = session
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovable = false
        window.backgroundColor = NSColor(NookTheme.field)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(button)?.isHidden = true }
        window.delegate = self
        window.contentView = NSHostingView(rootView: McpAppFullscreenView(session: session))
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        window.delegate = nil
        window.orderOut(nil)
        window.close()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Focus went elsewhere; a confirmation of the app's own keeps it.
        guard NSApp.modalWindow == nil else { return }
        session?.exitFullscreen()
    }
}

private struct McpAppFullscreenView: View {
    @ObservedObject var session: McpAppSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.reference.server ?? session.reference.tool).font(NookTheme.font(13, .medium)).lineLimit(1)
                Spacer()
                Button { session.exitFullscreen() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .buttonStyle(.borderless)
                    .help(tr("ws.mcpApp.exitFullscreen"))
                    .keyboardShortcut(.cancelAction)
            }
            .foregroundStyle(NookTheme.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 40)
            Divider()
            McpAppSurface(session: session, mode: .fullscreen)
        }
    }
}

/// The content controller keeps its handler alive; this keeps it from keeping the session (and the view) alive.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
