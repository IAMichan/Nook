import XCTest

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
}
