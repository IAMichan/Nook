import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

// MCP apps in the timeline (see McpApp), hosted hosts them: the page runs in an iframe with
// `sandbox="allow-scripts allow-forms"` (an opaque origin, no popups, no way into Nook) under its own Content-Security-
// Policy, inside a host page that relays its messages to Nook and nothing else. Calling a tool that changes something,
// sending a message, opening a link and saving a file each ask you first.

/// The app of one tool call: inline, sized to what the page reports, with fullscreen in a window of its own.
struct McpAppBlock: View {
    @EnvironmentObject private var app: AppModel
    let resource: McpUI.Resource
    let event: RunEvent
    @State private var height = McpApp.defaultHeight
    @State private var closed = false
    @State private var left = false
    @State private var reload = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let link = resource.link {
                Button(tr("ws.mcpApp.open")) { NSWorkspace.shared.open(link) }
                    .controlSize(.small)
                    .help(link.absoluteString)
            } else if closed || left {
                HStack(spacing: 8) {
                    Text(left ? tr("ws.mcpApp.left") : tr("ws.mcpApp.closed", reference.tool))
                        .font(NookTheme.font(11.5)).foregroundStyle(NookTheme.textTertiary)
                    Button(tr("ws.mcpApp.show")) {
                        closed = false
                        left = false
                        reload += 1
                    }
                    .controlSize(.small)
                }
            } else if let html {
                McpAppWebView(html: html, reference: reference, runID: runID, eventID: event.id, mode: .inline,
                              workspace: app.workspace, onHeight: { height = $0 }, onTeardown: { closed = true }, onLeft: { left = true })
                    .id(reload)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        if reference.prefersBorder != false {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(NookTheme.line2, lineWidth: 1)
                        }
                    }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.on.square.dashed").font(.system(size: 10, weight: .semibold))
            Text(reference.server.map { "\($0) · \(reference.tool)" } ?? tr("ws.mcpApp.title"))
                .font(NookTheme.font(11, .medium))
            Text(resource.uri).font(NookTheme.mono(10.5)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(NookTheme.textTertiary)
            Spacer(minLength: 4)
            if html != nil, !closed, !left {
                Button {
                    McpAppWindow.open(html: html ?? "", reference: reference, runID: runID, eventID: event.id, workspace: app.workspace)
                } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10)) }
                .buttonStyle(.plain)
                .help(tr("ws.mcpApp.fullscreen"))
            }
        }
        .foregroundStyle(NookTheme.textSecondary)
    }

    private var runID: UUID? { app.workspace.runID(containing: event.id) }

    /// The app as Nook saved it (Codex), or the page another agent put in its tool result.
    private var reference: McpApp.Reference {
        if let saved = resource.app { return saved }
        return McpApp.Reference(file: nil, server: nil, tool: event.tool ?? "app", resourceUri: resource.uri, csp: nil, permissions: nil,
                                prefersBorder: nil, arguments: event.detail, result: event.output.map(McpUI.stripped))
    }

    private var html: String? {
        if let file = resource.app?.file { return try? String(contentsOfFile: file, encoding: .utf8) }
        return resource.html.map { McpApp.prepared($0, csp: nil) }
    }
}

/// Fullscreen: the same app in a window of its own (the page loads again there, as on phone app).
enum McpAppWindow {
    @MainActor private static var windows: [NSWindow] = []

    @MainActor
    static func open(html: String, reference: McpApp.Reference, runID: UUID?, eventID: UUID, workspace: WorkspaceManager) {
        // One app fullscreen at a time, never while the agent waits for your answer.
        if let runID, workspace.approvals[runID]?.isEmpty == false { return }
        windows.forEach { $0.close() }
        windows = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = reference.server.map { "\($0) · \(reference.tool)" } ?? reference.tool
        window.isReleasedWhenClosed = false
        let view = McpAppWebView(html: html, reference: reference, runID: runID, eventID: eventID, mode: .fullscreen, workspace: workspace,
                                 onHeight: { _ in }, onTeardown: { window.close() }, onLeft: { window.close() })
        window.contentView = NSHostingView(rootView: view.frame(minWidth: 480, minHeight: 320))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windows.append(window)
    }

    @MainActor
    static func closeAll() {
        windows.forEach { $0.close() }
        windows = []
    }
}

/// The web view: a host page with the app's iframe, and the JSON-RPC host behind it.
struct McpAppWebView: NSViewRepresentable {
    let html: String
    let reference: McpApp.Reference
    let runID: UUID?
    let eventID: UUID
    let mode: McpAppHost.DisplayMode
    let workspace: WorkspaceManager
    let onHeight: (Double) -> Void
    let onTeardown: () -> Void
    let onLeft: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(WeakHandler(context.coordinator), name: "nookApp")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.attach(view)
        view.loadHTMLString(Self.hostPage(html: html, allow: McpApp.allowAttribute(reference.permissions)), baseURL: nil)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.host?.updateHostContext()
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.host?.teardown {}
        view.configuration.userContentController.removeScriptMessageHandler(forName: "nookApp")
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

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: McpAppWebView
        var host: McpAppHost?
        private weak var view: WKWebView?
        private var width: Double = 600

        init(_ parent: McpAppWebView) {
            self.parent = parent
        }

        @MainActor
        func attach(_ view: WKWebView) {
            self.view = view
            host = McpAppHost(reference: parent.reference, hostVersion: Self.version, actions: actions())
        }

        private static var version: String {
            (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            Task { @MainActor in
                switch body["nook"] as? String {
                case "left":
                    self.host?.dispose()
                    self.parent.onLeft()
                case "message":
                    if let data = body["data"] { self.host?.receive(data) }
                default:
                    break
                }
            }
        }

        /// The host page loads once; the app's own frame only its srcdoc. Everything else goes nowhere.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = navigationAction.request.url?.absoluteString ?? ""
            return url == "about:blank" || url == "about:srcdoc" ? .allow : .cancel
        }

        // MARK: What the app may ask

        @MainActor
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
                    guard let self, let runID = self.parent.runID else { return done(.failure(McpAppHost.Refusal(message: tr("ws.mcpApp.sessionStopped")))) }
                    guard self.confirm(tr("ws.mcpApp.confirmMessage", self.parent.reference.tool), detail: text) else {
                        return done(.failure(McpAppHost.Refusal(message: tr("ws.mcpApp.declined"))))
                    }
                    self.parent.workspace.mcpAppSendMessage(runID, text: text)
                    done(.success(()))
                },
                updateModelContext: { [weak self] text, done in
                    guard let self, let runID = self.parent.runID else { return done(.success(())) }
                    self.parent.workspace.mcpAppSetContext(runID, key: String(self.parent.eventID.uuidString.prefix(8)).lowercased(), text: text)
                    done(.success(()))
                },
                requestDisplayMode: { [weak self] mode, done in
                    guard let self else { return done(.inline) }
                    switch (self.parent.mode, mode) {
                    case (.inline, .fullscreen):
                        if let runID = self.parent.runID, self.parent.workspace.approvals[runID]?.isEmpty == false { return done(.inline) }
                        McpAppWindow.open(html: self.parent.html, reference: self.parent.reference, runID: self.parent.runID,
                                          eventID: self.parent.eventID, workspace: self.parent.workspace)
                        done(.fullscreen)
                    case (.fullscreen, .inline):
                        done(.inline)
                        McpAppWindow.closeAll()
                    default:
                        done(self.parent.mode)
                    }
                },
                downloadFiles: { [weak self] files, done in self?.download(files, done) },
                onSizeChanged: { [weak self] _, height in
                    guard let self, self.parent.mode == .inline, let height else { return }
                    self.parent.onHeight(McpApp.clampHeight(height))
                },
                onRequestTeardown: { [weak self] in
                    self?.host?.teardown {}
                    self?.parent.onTeardown()
                }
            )
        }

        @MainActor
        private func deliver(_ message: [String: Any]) {
            guard let json = McpApp.json(message) else { return }
            view?.evaluateJavaScript("window.__nookDeliver(\(json))", completionHandler: nil)
        }

        @MainActor
        private func hostContext() -> [String: Any] {
            let size = view?.bounds.size ?? CGSize(width: width, height: McpApp.defaultHeight)
            width = max(1, Double(size.width))
            let dimensions: [String: Any] = parent.mode == .inline
                ? ["width": width, "maxHeight": McpApp.maxHeight]
                : ["width": width, "height": Double(size.height)]
            return [
                "theme": "dark",
                "styles": ["variables": Self.styleVariables],
                "displayMode": parent.mode.rawValue,
                "availableDisplayModes": ["inline", "fullscreen"],
                "containerDimensions": dimensions,
                "platform": "desktop",
                "locale": Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
                "timeZone": TimeZone.current.identifier,
                "userAgent": "nook/\(Self.version)",
                "deviceCapabilities": ["touch": false, "hover": true],
                "toolInfo": ["tool": ["name": parent.reference.tool]],
            ]
        }

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

        @MainActor
        private func callTool(_ name: String, _ arguments: [String: Any], _ done: @escaping (Result<[String: Any], Error>) -> Void) {
            guard let server = parent.reference.server, let runID = parent.runID else {
                return done(.failure(McpAppHost.Refusal(message: tr("ws.mcpApp.noTools"))))
            }
            let workspace = parent.workspace
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

        @MainActor
        private func readResource(_ uri: String, _ done: @escaping (Result<[String: Any], Error>) -> Void) {
            guard let server = parent.reference.server, let runID = parent.runID else {
                return done(.failure(McpAppHost.Refusal(message: tr("ws.mcpApp.noTools"))))
            }
            let workspace = parent.workspace
            Task { @MainActor in
                do { done(.success(try await workspace.mcpAppReadResource(runID, server: server, uri: uri))) } catch { done(.failure(error)) }
            }
        }

        /// Files the app offers: after you agree, each saved where you choose (at most 25 MB each).
        @MainActor
        private func download(_ files: [McpAppHost.Download], _ done: @escaping (Result<Void, Error>) -> Void) {
            let names = files.map { file -> String in
                switch file {
                case .embedded(let name, _, _): return name
                case .link(let name, _): return name
                }
            }
            guard confirm(tr("ws.mcpApp.confirmDownload", parent.reference.tool), detail: names.joined(separator: "\n")) else {
                return done(.failure(McpAppHost.Refusal(message: tr("ws.mcpApp.declined"))))
            }
            Task { @MainActor in
                do {
                    for file in files {
                        switch file {
                        case .embedded(let name, _, let data):
                            try self.save(data, name: name)
                        case .link(let name, let uri):
                            guard let server = self.parent.reference.server, let runID = self.parent.runID else {
                                throw McpAppHost.Refusal(message: tr("ws.mcpApp.noTools"))
                            }
                            let read = try await self.parent.workspace.mcpAppReadResource(runID, server: server, uri: uri)
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

        @MainActor
        private func save(_ data: Data, name: String) throws {
            guard data.count <= 25 * 1024 * 1024 else { throw McpAppHost.Refusal(message: tr("ws.mcpApp.downloadTooLarge")) }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            guard panel.runModal() == .OK, let url = panel.url else { throw McpAppHost.Refusal(message: tr("ws.mcpApp.declined")) }
            try data.write(to: url, options: .atomic)
        }

        @MainActor
        private func confirm(_ title: String, detail: String) -> Bool {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail
            alert.addButton(withTitle: tr("ws.mcpApp.allow"))
            alert.addButton(withTitle: tr("button.cancel"))
            return alert.runModal() == .alertFirstButtonReturn
        }
    }
}

/// The content controller keeps its handler alive; this keeps it from keeping the coordinator (and the view) alive.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
