import XCTest
#if canImport(WebKit)
import WebKit
#endif

/// Pages agents show inline with `render_page` (`RenderedPage`): arguments, where they are kept, and the sandbox.
final class RenderedPageTests: XCTestCase {
    func testArguments() throws {
        let page = try RenderedPage.parse(["html": "<h1>Hi</h1>", "title": " Sales\nby month ", "height": "5000"]).get()
        XCTAssertEqual(page, .init(html: "<h1>Hi</h1>", title: "Sales by month", height: RenderedPage.maxHeight))
        XCTAssertEqual(try RenderedPage.parse(["html": "<p>x</p>"]).get().title, "Page")
        XCTAssertEqual(try RenderedPage.parse(["html": "<p>x</p>", "height": 10]).get().height, RenderedPage.minHeight)
        XCTAssertEqual(try RenderedPage.parse(["html": "<p>x</p>", "height": true]).get().height, RenderedPage.defaultHeight)
        XCTAssertThrowsError(try RenderedPage.parse(["html": "  "]).get())
        XCTAssertThrowsError(try RenderedPage.parse(["title": "x"]).get())
        XCTAssertThrowsError(try RenderedPage.parse(["html": String(repeating: "a", count: RenderedPage.maxHTMLBytes + 1)]).get(),
                             "size-capped")
        let long = try RenderedPage.parse(["html": "x", "title": String(repeating: "t", count: 500)]).get()
        XCTAssertEqual(long.title.count, RenderedPage.maxTitleLength)
    }

    func testThePageIsKeptWithItsSession() {
        let run = UUID(), page = UUID()
        let base = URL(fileURLWithPath: "/Users/me/Library/Application Support/Nook")
        let file = RenderedPage.file(in: base, run: run, page: page)
        XCTAssertEqual(file.path, base.path + "/pages/" + run.uuidString.lowercased() + "/" + page.uuidString.lowercased() + ".html")
        XCTAssertTrue(RenderedPage.isOwnFile(file.path, base: base))
        XCTAssertFalse(RenderedPage.isOwnFile(base.path + "/pages/../nook.sqlite", base: base), "never a path out of the pages folder")
        XCTAssertFalse(RenderedPage.isOwnFile("/etc/passwd", base: base))
        let event = RenderedPage.event(id: page, title: "Chart", file: file.path, height: 512.4)
        XCTAssertEqual(event.kind, .page)
        XCTAssertEqual(event.id, page)
        XCTAssertEqual(event.detail, file.path)
        XCTAssertEqual(RenderedPage.height(of: event), 512)
        var damaged = event
        damaged.output = "lots"
        XCTAssertEqual(RenderedPage.height(of: damaged), RenderedPage.defaultHeight)
    }

    func testThePageRunsSandboxedWithoutNetwork() {
        let host = RenderedPage.hostPage(#"<script>fetch("https://evil.example")</script><a href="x">"&amp;"</a>"#)
        XCTAssertTrue(host.contains(#"<iframe sandbox="allow-scripts" "#), "scripts only: no same origin, forms, popups or top navigation")
        XCTAssertFalse(host.contains("allow-same-origin"))
        XCTAssertTrue(host.contains("connect-src &#39;none&#39;") || host.contains("connect-src 'none'"), "nothing connects anywhere")
        XCTAssertTrue(host.contains("default-src 'none'"))
        XCTAssertFalse(host.contains("messageHandlers"), "no way to talk to Nook")
        XCTAssertFalse(host.contains(#"srcdoc="<!doctype html><meta http-equiv="Content"#), "the page is escaped inside srcdoc")
        XCTAssertTrue(host.contains("&quot;https://evil.example&quot;"))
        XCTAssertTrue(host.contains("&amp;amp;"))
    }

    func testTheToolIsListedAndRefusedInPlanMode() {
        XCTAssertEqual(BridgeTool.named("mcp__nook__render_page"), .renderPage)
        XCTAssertTrue(BridgeLaunch.instructions.contains("render_page"))
        let caller = BridgeCaller(kind: .run(UUID()), agent: "Codex", title: "", directory: "/p", mode: .agent, permission: .ask)
        XCTAssertEqual(BridgePolicy.verdict(tool: .renderPage, caller: caller), .allow, "showing a page asks nothing")
        var plan = caller
        plan.mode = .plan
        XCTAssertEqual(BridgePolicy.verdict(tool: .renderPage, caller: plan), .refuse(.planMode))
    }

    func testShownHeightFollowsThePageOnceMeasured() {
        XCTAssertEqual(RenderedPage.shownHeight(asked: 360, measured: nil, fullSize: true), 360, "the agent's height until drawn")
        XCTAssertEqual(RenderedPage.shownHeight(asked: 360, measured: 200.4, fullSize: false), 201, "no empty room under a short page")
        XCTAssertEqual(RenderedPage.shownHeight(asked: 360, measured: 900, fullSize: false), 360, "a long page keeps the agent's height")
        XCTAssertEqual(RenderedPage.shownHeight(asked: 360, measured: 900, fullSize: true), 900, "full size shows the whole page")
        XCTAssertEqual(RenderedPage.shownHeight(asked: 360, measured: 99_999, fullSize: true), RenderedPage.maxFullHeight)
        XCTAssertEqual(RenderedPage.shownHeight(asked: 360, measured: 10, fullSize: false), RenderedPage.minHeight)
        XCTAssertEqual(RenderedPage.shownHeight(asked: 360, measured: .nan, fullSize: true), 360)
    }

    func testMeasureSizeAndZoom() {
        XCTAssertNil(RenderedPage.Measure.Size(["w": 500, "v": 0, "h": 300]))
        let fit = RenderedPage.Measure.Size(["w": 600, "v": 600, "h": 400])!
        XCTAssertEqual(RenderedPage.Measure.zoom(current: 1, fit), 1)
        let wide = RenderedPage.Measure.Size(["w": 1000, "v": 500, "h": 400])!
        XCTAssertEqual(RenderedPage.Measure.zoom(current: 1, wide), 0.5, accuracy: 0.001)
        let huge = RenderedPage.Measure.Size(["w": 5000, "v": 500, "h": 400])!
        XCTAssertEqual(RenderedPage.Measure.zoom(current: 1, huge), RenderedPage.Measure.minZoom, accuracy: 0.001)
    }

    #if canImport(WebKit)
    @MainActor
    func testFullSizeExpansionDoesNotLoopOnViewportRelativeMockups() async throws {
        // A mock-up like "Chat-apps: nu en voorstel": a 60px top bar + a `calc(100vh - 56px)` flex shell whose
        // `.page` pane (`overflow: auto`) holds 1000px of content. Naively `scrollHeight` is `100vh + 4` at every
        // frame height, which would grow by 4px every 16ms forever when expanded to `fullSize`.
        let mockupHTML = """
        <!doctype html><html><head><style>
        *{box-sizing:border-box}body{margin:0}
        .top{height:60px}
        .win{display:flex;height:calc(100vh - 56px)}
        .side{width:180px}
        .page{flex:1;overflow:auto}
        .content{height:1000px}
        </style></head><body>
        <div class="top"></div>
        <div class="win"><div class="side"></div><div class="page"><div class="content"></div></div></div>
        </body></html>
        """
        let harness = MeasureHarness(width: 700, asked: 560, html: mockupHTML)
        let first = try await harness.nextHeight()
        XCTAssertEqual(first, 1060, accuracy: 2, "measures the full content height including the inner scroll pane")

        // Simulate clicking the top-right full-size button: resize the web view to `shownHeight(..., fullSize: true)`
        // and verify no runaway growth reports follow.
        harness.expandToFullSize()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(harness.reports.count, 1, "resizing the frame height to fullSize must not trigger a feedback loop")
        XCTAssertEqual(harness.view.frame.height, 1060, accuracy: 2)

        // Also check a short page (no viewport units): shrinks to its own content height instead of `clientHeight`.
        let shortHarness = MeasureHarness(width: 700, asked: 360, html: "<body style='margin:0'><div style='height:140px'></div></body>")
        let shortHeight = try await shortHarness.nextHeight()
        XCTAssertEqual(shortHeight, 140, accuracy: 2)
    }

    @MainActor
    private final class MeasureHarness: NSObject, WKScriptMessageHandler {
        let view: WKWebView
        let asked: Double
        var reports: [Double] = []
        private var reported: Double?
        private var continuation: CheckedContinuation<Double, Error>?

        init(width: Double, asked: Double, html: String) {
            self.asked = asked
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let world = WKContentWorld.world(name: "NookPageMeasureTest")
            view = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: asked), configuration: configuration)
            super.init()
            configuration.userContentController.add(self, contentWorld: world, name: RenderedPage.Measure.handler)
            configuration.userContentController.addUserScript(
                WKUserScript(source: RenderedPage.Measure.source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world)
            )
            view.loadHTMLString(RenderedPage.hostPage(html), baseURL: nil)
        }

        func nextHeight() async throws -> Double {
            if let first = reports.first { return first }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }

        func expandToFullSize() {
            let target = RenderedPage.shownHeight(asked: asked, measured: reported, fullSize: true)
            view.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: target)
            view.layoutSubtreeIfNeeded()
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !message.frameInfo.isMainFrame, let size = RenderedPage.Measure.Size(message.body) else { return }
            let zoom = RenderedPage.Measure.zoom(current: Double(view.pageZoom), size)
            if abs(zoom - Double(view.pageZoom)) > 0.01 {
                view.pageZoom = CGFloat(zoom)
                return
            }
            let height = size.height * Double(view.pageZoom)
            guard reported.map({ abs($0 - height) > 1 }) ?? true else { return }
            reported = height
            reports.append(height)
            if reports.count > 1 {
                // If a feedback loop occurs, each new height would keep expanding the frame when fullSize is on.
                let target = RenderedPage.shownHeight(asked: asked, measured: reported, fullSize: true)
                view.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: target)
                view.layoutSubtreeIfNeeded()
            }
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: height)
            }
        }
    }
    #endif
}
