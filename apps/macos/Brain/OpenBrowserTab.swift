import Foundation

/// Reading a web page that is open in the user's browser: the AppleScript that finds the tab and its text, and what that
/// script returns. Foundation only, so it can be tested anywhere; `BrowserTabReader` runs it on the Mac and falls back to
/// the accessibility layer when the browser does not hand over the page's text.
///
/// Chromium browsers (Chrome, Edge, Brave, Arc) only give a page's text through JavaScript, which is off until the user
/// turns on "Allow JavaScript from Apple Events". The script never fails on that: the tab's title and address still come
/// back, so Nook knows which page is open and reads its text another way.
enum OpenBrowserTab {
    /// One tab as the script reports it.
    struct Tab: Equatable {
        var title: String
        var url: String
        /// The tab is the one shown in its window (the page the user sees), not a tab behind it.
        var visible: Bool
        var text: String
    }

    /// What separates the fields on the script's first line.
    static let separator = "|||"

    /// The longest page text handed to the brain.
    static let textLimit = 12_000

    /// The script for one browser. `match`: part of a tab's title or address to look for in every window; nil or empty
    /// for the tab shown in the front window. Returns "" when the browser has no window or no tab matches.
    static func script(app: String, safari: Bool, match: String?) -> String {
        let query = (match ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let titleKey = safari ? "name" : "title"
        let activeKey = safari ? "current tab" : "active tab"
        // Safari hands over a page's text itself; the others only through JavaScript, which may be switched off.
        let readText = safari
            ? "set docText to text of theTab"
            : "set docText to execute theTab javascript \"document.body.innerText\""
        return """
        tell application \(quote(app))
            if (count of windows) = 0 then return ""
            set q to \(quote(query))
            set theTab to missing value
            set theWin to front window
            if q is not "" then
                repeat with w in windows
                    repeat with t in tabs of w
                        set tabTitle to ""
                        set tabURL to ""
                        try
                            set tabTitle to \(titleKey) of t
                        end try
                        try
                            set tabURL to URL of t
                        end try
                        if tabTitle contains q or tabURL contains q then
                            set theTab to contents of t
                            set theWin to contents of w
                            exit repeat
                        end if
                    end repeat
                    if theTab is not missing value then exit repeat
                end repeat
                if theTab is missing value then return ""
            else
                set theTab to \(activeKey) of theWin
            end if
            set shown to "0"
            try
                if (URL of \(activeKey) of theWin) is (URL of theTab) then set shown to "1"
            end try
            set docTitle to ""
            set docURL to ""
            try
                set docTitle to \(titleKey) of theTab
            end try
            try
                set docURL to URL of theTab
            end try
            set docText to ""
            try
                \(readText)
            end try
            if docText is missing value then set docText to ""
            if (length of docText) > \(textLimit) then set docText to text 1 thru \(textLimit) of docText
            return docTitle & "\(separator)" & docURL & "\(separator)" & shown & linefeed & docText
        end tell
        """
    }

    /// The tab in what `script` returned; nil when it found none.
    static func parse(_ output: String) -> Tab? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lines = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let header = String(lines.first ?? "").components(separatedBy: separator)
        guard header.count >= 2 else { return nil }
        let title = header[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let url = header[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !url.isEmpty else { return nil }
        let visible = header.count < 3 || header[2].trimmingCharacters(in: .whitespaces) == "1"
        let body = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return Tab(title: title, url: url, visible: visible, text: String(body.prefix(textLimit)))
    }

    /// The tool's answer for a tab; `browser` is the browser's name.
    static func describe(_ tab: Tab, browser: String) -> String {
        var lines = ["## \(tab.title.isEmpty ? tab.url : tab.title) (\(browser))", "Bron: \(tab.url)"]
        lines.append(tab.visible
            ? "This tab is open and shown in the user's \(browser) window."
            : "This tab is open in \(browser) but behind another tab in its window.")
        lines.append("")
        if tab.text.isEmpty {
            lines.append("The page's text could not be read, but the page is open. Do not say it is not open or not on screen. To fill in, click or type anything on it, use take_over with the task.")
        } else {
            lines.append(tab.text)
        }
        return lines.joined(separator: "\n")
    }

    private static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
