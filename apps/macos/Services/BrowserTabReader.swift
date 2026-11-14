import AppKit

/// Reads the page open in the user's browser for `read_browser_tab`: the browser the user works in first (the one whose
/// window is on top, also while Nook's own chat has the focus), then any other that runs. A page whose text the browser
/// does not hand over (Chromium without "Allow JavaScript from Apple Events") is read through the accessibility layer, the
/// way VoiceOver reads it. A page that is open is never reported as missing.
enum BrowserTabReader {
    /// The browsers Nook reads (`AppCatalog.readableBrowsers`), in the order it tries them.
    private static let browsers: [(name: String, bundle: String, safari: Bool)] = AppCatalog.readableBrowsers.map {
        ($0.name, $0.bundleID, $0.engine == .webkit)
    }

    /// `target`: a browser's name, or part of a tab's title or address ("FileSender", "bol.com"). Nil for the page shown
    /// in the browser the user works in.
    @MainActor static func read(target: String?) async -> String {
        let running = browsers.filter { ScriptText.isRunning($0.bundle) }
        guard !running.isEmpty else { return "No browser that Nook can read (Safari, Chrome, Edge, Brave, Arc) is running." }
        let query = (target ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // A browser's name picks that browser; anything else is a tab to look for in all of them.
        let named = query.isEmpty ? [] : running.filter { browser in
            browser.name.localizedCaseInsensitiveContains(query) || query.localizedCaseInsensitiveContains(browser.name)
                || (browser.name == "Google Chrome" && query.localizedCaseInsensitiveContains("chrome"))
                || (browser.name == "Microsoft Edge" && query.localizedCaseInsensitiveContains("edge"))
        }
        let match = named.isEmpty && !query.isEmpty ? query : nil
        var order = named.isEmpty ? running : named
        if let used = UIDriver.userBrowser()?.bundleIdentifier, let index = order.firstIndex(where: { $0.bundle == used }), index > 0 {
            order.insert(order.remove(at: index), at: 0)
        }
        for browser in order {
            let result = await ScriptText.run(OpenBrowserTab.script(app: browser.name, safari: browser.safari, match: match), timeout: 4)
            guard var tab = result.text.flatMap(OpenBrowserTab.parse) else { continue }
            if tab.text.isEmpty, tab.visible, let app = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundle).first {
                tab.text = await accessibleText(of: app)
            }
            return OpenBrowserTab.describe(tab, browser: browser.name) + "\n\n"
                + ReferenceParser.line(title: tab.title, url: tab.url.isEmpty ? nil : tab.url, detail: browser.name)
        }
        if let match {
            return "No open tab whose title or address contains \"\(match)\" in \(order.map(\.name).joined(separator: ", ")). Call read_browser_tab without a name for the page shown in the browser."
        }
        return "No open web page found in \(order.map(\.name).joined(separator: ", ")). If Nook may not control the browser, the user can allow it in System Settings › Privacy & Security › Automation."
    }

    /// The text of the browser's front window through the accessibility layer. A Chromium browser builds the tree of a
    /// page only once a client asks for it, so an empty first read is tried once more.
    private static func accessibleText(of app: NSRunningApplication) async -> String {
        guard AppTextReader.hasPermission else { return "" }
        AppTextReader.wake(pid: app.processIdentifier)
        let pid = app.processIdentifier
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 400_000_000) }
            let text = await Task.detached(priority: .userInitiated) {
                AppTextReader.focusedWindowText(pid: pid, limit: OpenBrowserTab.textLimit)
                    ?? AppTextReader.read(pid: pid, limit: OpenBrowserTab.textLimit).first?.text
            }.value
            if let text, !text.isEmpty { return text }
        }
        return ""
    }
}
