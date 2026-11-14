import XCTest

/// Nook's browser extension on the Mac's side: the host script and the manifests the browsers read, the hub that hands
/// commands to the right browser and results to the right caller, and the chrome_* tools' arguments and approvals.
final class BrowserExtensionTests: XCTestCase {
    /// What a host got back on one connection.
    private final class Line: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        var alive = true

        lazy var reply: BrowserExtensionHub.Reply = { [unowned self] data in
            lock.lock()
            defer { lock.unlock() }
            guard alive, self.data == nil else { return false }
            self.data = data
            return true
        }

        var object: [String: Any]? {
            lock.lock()
            defer { lock.unlock() }
            return data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        }
    }

    private func request(_ client: String, _ message: [String: Any]) -> Data {
        BrowserExtensionHub.encode(["client": client, "message": message]) + Data([10])
    }

    @discardableResult
    private func send(_ hub: BrowserExtensionHub, _ client: String, _ message: [String: Any]) -> Line {
        let line = Line()
        hub.handle(request(client, message), reply: line.reply)
        return line
    }

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    // MARK: - Host

    func testTheManifestLetsOnlyNooksExtensionStartTheScript() throws {
        let data = BrowserExtensionHost.manifest(scriptPath: "/Users/x/Library/Application Support/Nook/nook-browser-host")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["name"] as? String, "app.nook.browser")
        XCTAssertEqual(object["type"] as? String, "stdio")
        XCTAssertEqual(object["path"] as? String, "/Users/x/Library/Application Support/Nook/nook-browser-host")
        XCTAssertEqual(object["allowed_origins"] as? [String], ["chrome-extension://\(BrowserExtensionHost.extensionID)/"])
        XCTAssertEqual(BrowserExtensionHost.extensionID.count, 32)
        XCTAssertTrue(BrowserExtensionHost.extensionID.allSatisfy { ("a"..."p").contains($0) }, "a Chromium extension id")
    }

    func testInstallWritesForInstalledBrowsersOnlyAndUninstallRemovesIt() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nook-browser-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        try fm.createDirectory(at: support.appendingPathComponent("Google/Chrome"), withIntermediateDirectories: true)
        try fm.createDirectory(at: support.appendingPathComponent("BraveSoftware/Brave-Browser"), withIntermediateDirectories: true)
        let script = root.appendingPathComponent("nook-browser-host")

        let installed = try BrowserExtensionHost.install(script: script, applicationSupport: support)
        XCTAssertEqual(installed, ["Google Chrome", "Brave"])
        XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), BrowserExtensionHost.contents)
        let permissions = try fm.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o755)
        let chrome = support.appendingPathComponent("Google/Chrome/NativeMessagingHosts/app.nook.browser.json")
        XCTAssertEqual(try Data(contentsOf: chrome), BrowserExtensionHost.manifest(scriptPath: script.path))
        XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("Microsoft Edge").path), "nothing for a browser that is not there")
        XCTAssertEqual(BrowserExtensionHost.installedBrowsers(script: script, applicationSupport: support), ["Google Chrome", "Brave"])
        XCTAssertEqual(try BrowserExtensionHost.install(script: script, applicationSupport: support), installed, "a second install changes nothing")

        BrowserExtensionHost.uninstall(script: script, applicationSupport: support)
        XCTAssertFalse(fm.fileExists(atPath: chrome.path))
        XCTAssertFalse(fm.fileExists(atPath: script.path))
        XCTAssertEqual(BrowserExtensionHost.installedBrowsers(script: script, applicationSupport: support), [])
    }

    func testTheScriptTalksToNooksSocketAndKeepsNoLogic() {
        let script = BrowserExtensionHost.contents
        XCTAssertTrue(script.hasPrefix("#!/usr/bin/perl\n"))
        XCTAssertTrue(script.contains("version \(BrowserExtensionHost.version)"))
        XCTAssertTrue(script.contains("Library/Application Support/Nook/browser.sock"))
        XCTAssertTrue(script.contains("kind => 'poll'"))
        XCTAssertFalse(script.contains("system("), "the host runs nothing")
        XCTAssertFalse(script.contains("exec "), "the host runs nothing")
    }

    // MARK: - Hub

    func testHelloRegistersTheBrowser() {
        let hub = BrowserExtensionHub()
        hub.appVersion = "1.2.3"
        let hello = send(hub, "42-1-ab", ["kind": "hello", "protocol": 1, "browser": "Google Chrome", "version": "1.0.0"])
        XCTAssertEqual(hello.object?["ok"] as? Bool, true)
        XCTAssertEqual(hello.object?["version"] as? String, "1.2.3")
        XCTAssertEqual(hub.connected.map(\.browser), ["Google Chrome"])
        XCTAssertEqual(hub.connected.first?.version, "1.0.0")
    }

    func testANewerExtensionIsToldToUpdateNook() {
        let hub = BrowserExtensionHub()
        let hello = send(hub, "42-1-ab", ["kind": "hello", "protocol": 99, "browser": "Brave"])
        XCTAssertEqual(hello.object?["ok"] as? Bool, false)
    }

    func testRequestsFromSomethingElseAreRefused() {
        let hub = BrowserExtensionHub()
        let line = Line()
        hub.handle(Data("{\"client\":\"../../etc\",\"message\":{\"kind\":\"hello\"}}\n".utf8), reply: line.reply)
        XCTAssertEqual(line.object?["ok"] as? Bool, false)
        let junk = Line()
        hub.handle(Data("not json\n".utf8), reply: junk.reply)
        XCTAssertEqual(junk.object?["ok"] as? Bool, false)
        XCTAssertTrue(hub.connected.isEmpty)
    }

    func testACommandGoesToTheWaitingPollAndItsResultToTheCaller() {
        let hub = BrowserExtensionHub()
        send(hub, "c1", ["kind": "hello", "protocol": 1, "browser": "Google Chrome"])
        let poll = send(hub, "c1", ["kind": "poll"])
        XCTAssertNil(poll.object, "the poll waits")

        var outcome: BrowserExtensionOutcome?
        hub.send("read", params: ["limit": 100], browser: nil, timeout: 5) { outcome = $0 }
        let command = poll.object
        XCTAssertEqual(command?["kind"] as? String, "command")
        XCTAssertEqual(command?["method"] as? String, "read")
        XCTAssertEqual((command?["params"] as? [String: Any])?["limit"] as? Int, 100)
        let id = command?["id"] as? String ?? ""

        let ack = send(hub, "c1", ["kind": "result", "id": id, "ok": true, "text": "# Example"])
        XCTAssertEqual(ack.object?["ok"] as? Bool, true)
        XCTAssertEqual(outcome, BrowserExtensionOutcome(ok: true, text: "# Example"))
    }

    func testACommandWaitsForTheNextPoll() {
        let hub = BrowserExtensionHub()
        send(hub, "c1", ["kind": "hello", "protocol": 1, "browser": "Brave"])
        var outcome: BrowserExtensionOutcome?
        hub.send("tabs", params: [:], browser: nil, timeout: 5) { outcome = $0 }
        let poll = send(hub, "c1", ["kind": "poll"])
        XCTAssertEqual(poll.object?["method"] as? String, "tabs", "queued, then handed to the poll right away")
        send(hub, "c1", ["kind": "result", "id": poll.object?["id"] as? String ?? "", "ok": false, "error": "No tab"])
        XCTAssertEqual(outcome?.ok, false)
        XCTAssertEqual(outcome?.message, "No tab")
    }

    func testAPollWhoseConnectionWentGivesTheCommandBack() {
        let hub = BrowserExtensionHub()
        send(hub, "c1", ["kind": "hello", "protocol": 1, "browser": "Arc"])
        let dead = send(hub, "c1", ["kind": "poll"])
        dead.alive = false
        hub.send("find", params: [:], browser: nil, timeout: 5) { _ in }
        let next = send(hub, "c1", ["kind": "poll"])
        XCTAssertEqual(next.object?["method"] as? String, "find")
    }

    func testANewPollFromTheSameHostAnswersTheOldOneIdle() {
        let hub = BrowserExtensionHub()
        let first = send(hub, "c1", ["kind": "poll"])
        send(hub, "c1", ["kind": "poll"])
        XCTAssertEqual(first.object?["kind"] as? String, "idle")
    }

    func testWithoutABrowserACallSaysHowToConnect() async {
        let hub = BrowserExtensionHub()
        let outcome = await hub.call("tabs")
        XCTAssertEqual(outcome, .notConnected)
        XCTAssertTrue(outcome.message.contains("Settings"))
    }

    func testACommandNobodyAnswersTimesOut() {
        let hub = BrowserExtensionHub()
        send(hub, "c1", ["kind": "hello", "protocol": 1, "browser": "Google Chrome"])
        var outcome: BrowserExtensionOutcome?
        hub.send("tabs", params: [:], browser: nil, timeout: 0.05) { outcome = $0 }
        waitUntil { outcome != nil }
        XCTAssertEqual(outcome, .timedOut(after: 0))
        let poll = send(hub, "c1", ["kind": "poll"])
        XCTAssertNil(poll.object, "a command that timed out is not delivered later")
    }

    func testACommandGoesToTheBrowserNamedElseTheOneUsedLast() {
        var now = Date(timeIntervalSince1970: 1_000)
        let hub = BrowserExtensionHub(clock: { now })
        send(hub, "chrome", ["kind": "hello", "protocol": 1, "browser": "Google Chrome"])
        now += 5
        send(hub, "brave", ["kind": "hello", "protocol": 1, "browser": "Brave"])
        let chrome = send(hub, "chrome", ["kind": "poll"])
        let brave = send(hub, "brave", ["kind": "poll"])

        hub.send("tabs", params: [:], browser: nil, timeout: 5) { _ in }
        XCTAssertNotNil(brave.object, "the browser used last")
        XCTAssertNil(chrome.object)
        hub.send("tabs", params: [:], browser: "chrome", timeout: 5) { _ in }
        XCTAssertNotNil(chrome.object, "named, in part")
    }

    func testABrowserThatStoppedPollingIsGone() {
        var now = Date(timeIntervalSince1970: 1_000)
        let hub = BrowserExtensionHub(clock: { now })
        send(hub, "c1", ["kind": "hello", "protocol": 1, "browser": "Vivaldi"])
        XCTAssertEqual(hub.connected.count, 1)
        now += BrowserExtensionHub.staleAfter + 1
        XCTAssertTrue(hub.connected.isEmpty)
    }

    func testSidePanelRequestsGoToTheApp() {
        let hub = BrowserExtensionHub()
        var seen: (BrowserExtensionClient, String)?
        hub.onRequest = { client, message, reply in
            seen = (client, message["text"] as? String ?? "")
            _ = reply(BrowserExtensionHub.encode(["ok": true]))
        }
        let line = send(hub, "c1", ["kind": "ask", "text": "Vat dit samen"])
        XCTAssertEqual(line.object?["ok"] as? Bool, true)
        XCTAssertEqual(seen?.0.id, "c1")
        XCTAssertEqual(seen?.1, "Vat dit samen")
    }

    // MARK: - Tools

    func testEveryToolHasAMethodTheExtensionKnows() {
        let methods: Set<String> = ["tabs", "read", "find", "screenshot", "wait", "console", "scroll", "open", "click", "type", "key", "close"]
        XCTAssertEqual(Set(BrowserExtensionTools.all.map(\.method)), methods)
        XCTAssertEqual(Set(BrowserExtensionTools.names).count, BrowserExtensionTools.all.count)
        for tool in BrowserExtensionTools.all {
            XCTAssertTrue(tool.name.hasPrefix("chrome_"), tool.name)
            let properties = tool.schema["properties"] as? [String: Any] ?? [:]
            XCTAssertNotNil(properties["tab"], tool.name)
            for key in tool.required { XCTAssertNotNil(properties[key], "\(tool.name).\(key)") }
        }
    }

    func testOnlyWhatChangesAPageNeedsApproval() {
        let actions = Set(BrowserExtensionTools.all.filter(\.isAction).map(\.name))
        XCTAssertEqual(actions, ["chrome_open", "chrome_click", "chrome_type", "chrome_key", "chrome_close"])
    }

    func testArgumentsAreCheckedBeforeTheBrowserIsAsked() throws {
        let click = try XCTUnwrap(BrowserExtensionTools.definition("chrome_click"))
        XCTAssertThrowsError(try BrowserExtensionTools.params(for: click, [:]).get())
        XCTAssertThrowsError(try BrowserExtensionTools.params(for: click, ["ref": "e1", "text": "Send"]).get())
        let params = try BrowserExtensionTools.params(for: click, ["ref": " e7 ", "tab": "12", "browser": "Brave", "junk": 1]).get()
        XCTAssertEqual(params["ref"] as? String, "e7")
        XCTAssertEqual(params["tab"] as? Int, 12)
        XCTAssertNil(params["browser"], "the browser picks where the command goes, it is not part of it")
        XCTAssertNil(params["junk"])

        let type = try XCTUnwrap(BrowserExtensionTools.definition("chrome_type"))
        XCTAssertThrowsError(try BrowserExtensionTools.params(for: type, ["ref": "e2"]).get(), "value is required")
        let typed = try BrowserExtensionTools.params(for: type, ["ref": "e2", "value": "  two spaces  ", "submit": true]).get()
        XCTAssertEqual(typed["value"] as? String, "  two spaces  ", "what to type stays as given")
        XCTAssertEqual(typed["submit"] as? Bool, true)

        let open = try XCTUnwrap(BrowserExtensionTools.definition("chrome_open"))
        XCTAssertThrowsError(try BrowserExtensionTools.params(for: open, [:]).get())
    }

    func testApprovalsNameTheElementAndTheSite() throws {
        let refs = BrowserExtensionRefs()
        refs.learn("""
        Inbox | https://www.mail.example.com/u/0
        h1 "Inbox"
        [e3] button "Send" (scroll to see)
        [e4] textbox "To" value="lisa@example.com"
        """, tab: 7)
        let click = try XCTUnwrap(BrowserExtensionTools.definition("chrome_click"))
        XCTAssertEqual(BrowserExtensionTools.summary(click, ["ref": "e3", "tab": 7], refs: refs), tr("browserExt.summary.click", "button “Send”") + " · mail.example.com")
        XCTAssertEqual(BrowserExtensionTools.elementName(["ref": "e3"], refs: refs), "button “Send”", "the tab looked at last")
        XCTAssertEqual(BrowserExtensionTools.elementName(["ref": "e99"], refs: refs), "e99")
        XCTAssertEqual(BrowserExtensionTools.elementName(["text": "Sign in"], refs: refs), "“Sign in”")

        let type = try XCTUnwrap(BrowserExtensionTools.definition("chrome_type"))
        XCTAssertEqual(BrowserExtensionTools.summary(type, ["ref": "e4", "value": "Hi Lisa"], refs: refs),
                       tr("browserExt.summary.type", "textbox “To”", "Hi Lisa") + " · mail.example.com", "the exact text is approved")
        let open = try XCTUnwrap(BrowserExtensionTools.definition("chrome_open"))
        XCTAssertEqual(BrowserExtensionTools.summary(open, ["url": "back"], refs: refs), tr("browserExt.summary.back") + " · mail.example.com")
    }

    func testTheSidePanelsPageGoesAlongAsANote() {
        let page = BrowserExtensionPanel.Page(["title": "Invoice 12", "url": "https://shop.example.com/invoice/12", "tab": 4])
        XCTAssertNotNil(page)
        let note = BrowserExtensionPanel.note(page: page, browser: "Google Chrome")
        XCTAssertTrue(note.contains("Google Chrome"))
        XCTAssertTrue(note.contains("(tab 4): Invoice 12 | https://shop.example.com/invoice/12"))
        XCTAssertTrue(note.contains("untrusted"))
        XCTAssertNil(BrowserExtensionPanel.Page(["title": "No address"]))
        XCTAssertTrue(BrowserExtensionPanel.note(page: nil, browser: "").contains("cannot read"))
    }

    // MARK: - The browser_* bridge tools in the user's own browser

    func testEveryBrowserBridgeToolCanGoToTheUsersBrowser() {
        let browserTools = BridgeTool.allCases.filter { $0.capability == .browser }
        XCTAssertEqual(browserTools.count, 7)
        for tool in browserTools {
            let name = BridgeUserBrowser.chromeTool(for: tool)
            XCTAssertNotNil(name.flatMap(BrowserExtensionTools.definition), "\(tool.rawValue) has a chrome_* tool")
            let properties = tool.schema["properties"] as? [String: Any]
            XCTAssertNotNil(properties?[BridgeUserBrowser.key], "\(tool.rawValue) offers in: user")
        }
        XCTAssertNil(BridgeUserBrowser.chromeTool(for: .terminalRun))
        XCTAssertNil(BridgeUserBrowser.nookUseArguments(for: .terminalRun, ["in": "user"]))
        XCTAssertNil((BridgeTool.terminalRun.schema["properties"] as? [String: Any])?[BridgeUserBrowser.key])
    }

    func testOnlyInUserGoesToTheUsersBrowser() {
        XCTAssertTrue(BridgeUserBrowser.wanted(["in": "user"]))
        XCTAssertTrue(BridgeUserBrowser.wanted(["in": " User "]))
        XCTAssertFalse(BridgeUserBrowser.wanted(["in": "nook"]))
        XCTAssertFalse(BridgeUserBrowser.wanted([:]))
        XCTAssertFalse(BridgeUserBrowser.wanted(["in": true]))
    }

    func testABrowserCallBecomesNookUseWithTheChromeToolsArguments() throws {
        let open = try XCTUnwrap(BridgeUserBrowser.nookUseArguments(for: .browserOpen, ["in": "user", "url": "https://example.com", "tab": 4]))
        XCTAssertEqual(open["tool"] as? String, "chrome_open")
        let openInput = try XCTUnwrap(open["arguments"] as? [String: Any])
        XCTAssertEqual(openInput["url"] as? String, "https://example.com")
        XCTAssertEqual(openInput["tab"] as? Int, 4)
        XCTAssertNil(openInput["in"], "the bridge's own argument stays behind")

        let wait = try XCTUnwrap(BridgeUserBrowser.nookUseArguments(for: .browserWaitFor, ["in": "user", "text": "Done", "timeout_seconds": 5]))
        let waitInput = try XCTUnwrap(wait["arguments"] as? [String: Any])
        XCTAssertEqual(wait["tool"] as? String, "chrome_wait")
        XCTAssertEqual(waitInput["timeout"] as? Int, 5, "chrome_wait counts in timeout")
        XCTAssertNil(waitInput["timeout_seconds"])
        let definition = try XCTUnwrap(BrowserExtensionTools.definition("chrome_wait"))
        guard case .success(let params) = BrowserExtensionTools.params(for: definition, waitInput) else { return XCTFail("valid") }
        XCTAssertEqual(params["timeout"] as? Int, 5)
        XCTAssertEqual(params["text"] as? String, "Done")

        let type = try XCTUnwrap(BridgeUserBrowser.nookUseArguments(for: .browserType, ["in": "user", "ref": "e3", "value": "hi", "submit": true]))
        XCTAssertEqual(type["tool"] as? String, "chrome_type")
        let typeDefinition = try XCTUnwrap(BrowserExtensionTools.definition("chrome_type"))
        guard case .success(let typed) = BrowserExtensionTools.params(for: typeDefinition, (type["arguments"] as? [String: Any]) ?? [:]) else {
            return XCTFail("valid")
        }
        XCTAssertEqual(typed["ref"] as? String, "e3")
        XCTAssertEqual(typed["submit"] as? Bool, true)

        let shot = try XCTUnwrap(BridgeUserBrowser.nookUseArguments(for: .browserScreenshot, ["in": "user", "max_width": 800]))
        XCTAssertEqual(shot["tool"] as? String, "chrome_screenshot")
        XCTAssertNil((shot["arguments"] as? [String: Any])?["max_width"])
        XCTAssertEqual(BridgeUserBrowser.nookUseArguments(for: .browserSnapshot, ["in": "user"])?["tool"] as? String, "chrome_find")
    }

    func testTheUsersBrowserKeepsTheNookUseRules() {
        let caller = BridgeCaller(kind: .external, agent: "Codex", title: "", directory: "/tmp", mode: nil, permission: .bypass)
        // An action in the user's own browser waits for them, whatever the session's rights; a read runs directly.
        XCTAssertEqual(BridgePolicy.verdict(tool: .nookUse, caller: caller, nookAction: true), .ask(.action))
        XCTAssertEqual(BridgePolicy.verdict(tool: .nookUse, caller: caller, nookAction: false), .allow)
        // Another machine never reaches the user's browser.
        XCTAssertFalse(RemoteBridge.allows(.nookUse))
    }
}
