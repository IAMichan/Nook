import SwiftUI
import WebKit

/// A page an agent showed in its timeline (`render_page`, see `RenderedPage`): its title, then the page at the height the
/// agent asked for (capped). The page runs as an MCP app's page does, in a sandboxed frame under a policy that lets nothing
/// load or connect, but with nothing to talk to: no message handler it can reach, no navigation, no popups. It folds like
/// a step.
/// A page wider than the conversation is zoomed out to fit it. Two buttons on its line show it whole: at its full height
/// right here (`fullSize`), or in the File tab of the session's side panel, where it gets the panel's room.
struct RenderedPageRow: View, Equatable {
    let event: RunEvent
    @State private var hidden = false
    /// The page, read from its file off the main thread; `missing` once that found nothing.
    @State private var html: String?
    @State private var missing = false
    /// The page's scripts run only while its row is on screen; otherwise the web view goes, so a page that animates or
    /// loops costs nothing out of sight. The energy plan has no say here: a page on screen is something you look at, not
    /// background work, and a build (when agents show pages) would leave an empty frame for as long as it keeps the Mac busy.
    @State private var onScreen = false
    /// Shown at the height the whole page takes, instead of the height the agent asked for.
    @State private var fullSize = false
    /// The height the whole page takes in the conversation's width, once it was drawn.
    @State private var measured: Double?
    @Environment(\.sessionSide) private var side

    static func == (lhs: RenderedPageRow, rhs: RenderedPageRow) -> Bool { lhs.event == rhs.event }

    /// The agent's height, or the page's own when it is shorter (no empty room under it) or shown at full size.
    private var height: Double {
        RenderedPage.shownHeight(asked: RenderedPage.height(of: event), measured: measured, fullSize: fullSize)
    }

    /// The page has more to show than its frame: only then does full size mean something.
    private var cutOff: Bool { (measured ?? 0) > RenderedPage.height(of: event) + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            HStack(spacing: NookTheme.Spacing.xxs) {
                TranscriptWorkLine(symbol: "macwindow", label: event.text, open: !hidden) {
                    withAnimation(NookTheme.reveal) { hidden.toggle() }
                }
                .help(tr("ws.page.help"))
                if !hidden, html != nil { actions }
            }
            if !hidden, !missing || html != nil {
                if let html, onScreen {
                    SandboxedPageView(html: html) { measured = $0 }
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
                            .stroke(NookTheme.line2, lineWidth: 1))
                        .padding(.leading, TranscriptStyle.workIndent)
                } else {
                    // Being read: the room it will take, so the timeline does not jump when it arrives.
                    Color.clear.frame(height: height)
                }
            } else if !hidden {
                Text(tr("ws.page.gone"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .padding(.leading, TranscriptStyle.workIndent)
            }
        }
        .padding(.vertical, NookTheme.Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .task(id: event.detail) {
            let path = event.detail
            let base = NookPaths.supportDirectory
            let read = await Task.detached(priority: .utility) { Self.html(path, base: base) }.value
            html = read
            missing = read == nil
        }
    }

    /// Full size here, and the side panel where the session has one.
    @ViewBuilder private var actions: some View {
        if cutOff || fullSize {
            ToolbarIconButton(fullSize ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                              tr(fullSize ? "ws.page.fit" : "ws.page.fullSize"), selected: fullSize) {
                withAnimation(NookTheme.reveal) { fullSize.toggle() }
            }
        }
        if side.hasPanel, let path = event.detail {
            ToolbarIconButton("sidebar.right", tr(side.shownFile == path ? "ws.page.closeSide" : "ws.page.openSide"),
                              selected: side.shownFile == path) { side.showFile(path) }
        }
    }

    /// The page's file, only from the folder Nook keeps pages in; nil when it is missing or points elsewhere.
    private nonisolated static func html(_ path: String?, base: URL) -> String? {
        guard let path, RenderedPage.isOwnFile(path, base: base),
              let data = FileManager.default.contents(atPath: path), data.count <= RenderedPageFile.maxPageBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// A web view for an untrusted page: a non-persistent store, no window opening, and every navigation after the first load
/// cancelled (a link in the page goes nowhere). The page itself has no message handler: the one handler lives in a content
/// world of Nook's own (`PageMeasure`), which the page's scripts cannot see, and only reports how large the page is drawn.
/// A page wider than its frame (a mock-up of a whole window) is zoomed out to fit its width, so nothing is cut off at the
/// side; `onHeight` gets the height the whole page takes at that zoom, in points.
struct SandboxedPageView: NSViewRepresentable {
    let html: String
    var onHeight: (Double) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FittingWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        PageMeasure.install(in: configuration.userContentController, reporting: context.coordinator)
        let view = FittingWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.view = view
        context.coordinator.onHeight = onHeight
        view.onWidthChange = { [weak coordinator = context.coordinator] in coordinator?.refit() }
        view.loadHTMLString(RenderedPage.hostPage(html), baseURL: nil)
        context.coordinator.loaded = html
        return view
    }

    func updateNSView(_ view: FittingWebView, context: Context) {
        context.coordinator.onHeight = onHeight
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        context.coordinator.reset()
        view.pageZoom = 1
        view.loadHTMLString(RenderedPage.hostPage(html), baseURL: nil)
    }

    static func dismantleNSView(_ view: FittingWebView, coordinator: Coordinator) {
        PageMeasure.uninstall(from: view.configuration.userContentController)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loaded: String?
        weak var view: FittingWebView?
        var onHeight: (Double) -> Void = { _ in }
        private var reported: Double?

        func reset() { reported = nil }

        /// The page Nook loads and its own frame's srcdoc; everything else (links, redirects, forms) goes nowhere.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = navigationAction.request.url?.absoluteString ?? ""
            return url == "about:blank" || url == "about:srcdoc" ? .allow : .cancel
        }

        /// macOS can end the page's process (memory pressure, a crash); the frame would stay empty until the row is rebuilt.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard let loaded else { return }
            reported = nil
            webView.pageZoom = 1
            webView.loadHTMLString(RenderedPage.hostPage(loaded), baseURL: nil)
        }

        /// The page's size, from the frame it is drawn in (never the host page around it): zoom out until it fits the
        /// width, then report its height at that zoom.
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !message.frameInfo.isMainFrame, let view, let size = RenderedPage.Measure.Size(message.body) else { return }
            let zoom = RenderedPage.Measure.zoom(current: Double(view.pageZoom), size)
            if abs(zoom - Double(view.pageZoom)) > 0.01 {
                view.pageZoom = CGFloat(zoom)
                return  // Measured again at the new zoom.
            }
            let height = size.height * Double(view.pageZoom)
            guard reported.map({ abs($0 - height) > 1 }) ?? true else { return }
            reported = height
            onHeight(height)
        }

        /// Another width: start again at full size, so a page that fits now is no longer drawn smaller than it has to be.
        func refit() {
            guard let view, view.pageZoom != 1 else { return }
            view.pageZoom = 1
        }
    }
}

/// A web view that says when its width changes, so the page in it is fitted again.
final class FittingWebView: WKWebView {
    var onWidthChange: () -> Void = {}
    private var lastWidth: CGFloat = 0

    override func layout() {
        super.layout()
        guard abs(bounds.width - lastWidth) > 1 else { return }
        lastWidth = bounds.width
        onWidthChange()
    }
}

/// Installs `RenderedPage.Measure` in a content world of Nook's own: the page's scripts share its document
/// but not its world, so they can neither see the handler nor send through it.
enum PageMeasure {
    static let world = WKContentWorld.world(name: "NookPageMeasure")

    static func install(in controller: WKUserContentController, reporting handler: WKScriptMessageHandler) {
        controller.add(WeakHandler(handler), contentWorld: world, name: RenderedPage.Measure.handler)
        controller.addUserScript(WKUserScript(source: RenderedPage.Measure.source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
    }

    static func uninstall(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: RenderedPage.Measure.handler, contentWorld: world)
        controller.removeAllUserScripts()
    }

    /// The controller keeps its handlers; this one does not keep the view's coordinator alive with it.
    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ target: WKScriptMessageHandler) { self.target = target }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(controller, didReceive: message)
        }
    }
}
