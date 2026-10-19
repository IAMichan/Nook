import Foundation

/// Every Mac app exposes its commands in its menu bar, so the chat can act in any app the same way: list what the menus
/// offer (list_app_menu), then propose one command (app_menu_command) that runs only after the user approved it.
/// Foundation only, so the parsing and the AppleScript can be tested on their own; NookTools runs the scripts through
/// System Events, which needs Accessibility permission for Nook.
enum AppMenu {
    /// Menus deeper than this are not listed or clicked: real commands live at most two levels below the menu bar.
    static let maxDepth = 3

    /// A menu path from a tool call: an array of titles, or one string like "File > New Folder" (also "›", "→", "/").
    static func path(_ value: Any?) -> [String] {
        let parts: [String]
        if let list = value as? [Any] {
            parts = list.compactMap { $0 as? String }
        } else if let text = value as? String {
            let separators = [" > ", " › ", " → ", " -> ", ">", "›", "→"]
            let separator = separators.first { text.contains($0) }
            parts = separator.map { text.components(separatedBy: $0) } ?? [text]
        } else {
            parts = []
        }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// What is wrong with a command, in plain language (empty = fine).
    static func problems(app: String, path: [String]) -> [String] {
        var problems: [String] = []
        if app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("the app name is missing") }
        if path.count < 2 { problems.append("give the full menu path, from the menu bar to the item, e.g. [\"File\", \"New Folder\"]") }
        if path.count > maxDepth { problems.append("a menu path has at most \(maxDepth) levels") }
        return problems
    }

    /// Lists every enabled item as "Top > Item" or "Top > Sub > Item", one per line, separators and the Apple menu left out.
    static func listScript(process: String) -> String {
        """
        tell application "System Events"
            tell process \(quote(process))
                set out to ""
                repeat with top in (menu bar items of menu bar 1)
                    set topName to name of top
                    if topName is not missing value and topName is not "Apple" then
                        try
                            repeat with mi in (menu items of menu 1 of top)
                                set itemName to name of mi
                                if itemName is not missing value and itemName is not "" then
                                    set subNames to {}
                                    try
                                        set subNames to name of (menu items of menu 1 of mi)
                                    end try
                                    if (count of subNames) > 0 then
                                        repeat with subName in subNames
                                            if subName is not missing value and (subName as string) is not "" then
                                                set out to out & topName & " > " & itemName & " > " & subName & linefeed
                                            end if
                                        end repeat
                                    else if enabled of mi then
                                        set out to out & topName & " > " & itemName & linefeed
                                    end if
                                end if
                            end repeat
                        end try
                    end if
                end repeat
                return out
            end tell
        end tell
        """
    }

    /// Clicks the item. The caller brings the app to the front first: menu commands act on its front window.
    static func clickScript(process: String, path: [String]) -> String {
        var reference = "menu bar item \(quote(path[0])) of menu bar 1"
        for title in path.dropFirst() {
            reference = "menu item \(quote(title)) of menu 1 of " + reference
        }
        return """
        delay 0.4
        tell application "System Events"
            tell process \(quote(process))
                set target to \(reference)
                if not (enabled of target) then return "DISABLED"
                click target
                return "OK"
            end tell
        end tell
        """
    }

    /// The listing for the model: matches for `filter` first (case-insensitive), at most `limit` lines.
    static func describe(_ raw: String, app: String, filter: String?, limit: Int = 150) -> String {
        var lines = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var seen = Set<String>()
        lines = lines.filter { seen.insert($0).inserted }
        guard !lines.isEmpty else { return "\(app) shows no menu commands right now." }
        if let filter = filter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty {
            let words = filter.lowercased().split(separator: " ").map(String.init)
            let hits = lines.filter { line in words.contains { line.lowercased().contains($0) } }
            if !hits.isEmpty { lines = hits }
        }
        let shown = lines.prefix(limit)
        let more = lines.count > limit ? "\n… \(lines.count - limit) more; pass a filter word to narrow the list." : ""
        return "Menu commands of \(app) (use app_menu_command with one of these paths):\n"
            + shown.map { "- \($0)" }.joined(separator: "\n") + more
    }

    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
