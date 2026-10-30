import Foundation

/// Terminals: off for the shell, which has its own completion, but on in the prompt of a coding agent running there (Claude
/// Code, Codex, Gemini CLI, OpenCode…), where the user writes prose to the agent. Like Cotypist: only when such a prompt is on
/// screen, and only the text typed into it, without the frame, the status lines or the placeholder around it.
enum CompletionTerminal {
    /// Terminals whose text Nook can read through Accessibility, or may some day (Ghostty, kitty, Alacritty and WezTerm do not
    /// give their text yet; Warp does not give the cursor).
    static let apps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "org.alacritty", "com.github.wez.wezterm",
    ]

    /// The text typed into an agent's prompt, cut out of the terminal's whole screen.
    struct Prompt: Equatable {
        var before: String
        var after: String
    }

    /// Characters that start an agent's input line, after its frame: Claude Code and Gemini CLI use `>`, Codex `›`, others `❯`.
    static let markers: Set<Character> = [">", "›", "❯"]
    /// The sides of the box some agents draw around the input (Gemini CLI, older Claude Code), and Codex's bar.
    private static let frame: Set<Character> = ["│", "┃", "|", "▌", "▎"]
    /// Lines an agent shows right under its input: its keys and its state. Lower case.
    static let footerHints = [
        "? for shortcuts", "for shortcuts", "esc to interrupt", "context left", "⏎ send", "enter to send", "shift+tab", "auto-accept",
        "bypass permissions", "plan mode", "ctrl+j newline", "⌃j newline", "tokens used", "% context", "to cycle",
    ]

    /// The agent prompt the cursor is in, from the terminal's text before and after the cursor. Nil for a shell prompt, a
    /// heredoc's `> ` or anything else: the input line must start with a marker, and the agent's frame must be around it (a
    /// rule or box line above or a footer hint, and a rule, box line or footer hint below).
    static func agentPrompt(before: String, after: String) -> Prompt? {
        let lines = before.components(separatedBy: "\n")
        let below = after.components(separatedBy: "\n")
        // The input can run over a few lines (wrapped, or Shift-Return); its first line has the marker.
        let lowest = max(lines.count - 8, 0)
        guard let start = (lowest..<lines.count).reversed().first(where: { inputStart(lines[$0]) != nil }) else { return nil }
        let above = lines[..<start].suffix(2)
        let following = below.dropFirst().prefix(4)
        let footer = following.contains { line in footerHints.contains { line.lowercased().contains($0) } }
        let framedAbove = above.contains(where: isRule) || footer
        let framedBelow = following.prefix(2).contains(where: isRule) || footer
        guard framedAbove, framedBelow else { return nil }
        var parts: [String] = []
        for index in start..<lines.count {
            let last = index == lines.count - 1
            var text = index == start ? inputStart(lines[index]) ?? "" : String(stripLeadingFrame(lines[index]))
            // The cursor's own line keeps its spaces: a space just typed says the next word comes.
            if !last { text = stripTrailingFrame(text) }
            parts.append(text)
        }
        let typed = parts.filter { !$0.isEmpty }.joined(separator: " ")
        let rest = stripTrailingFrame(below.first ?? "")
        return Prompt(before: typed, after: rest)
    }

    /// What follows the marker on an input line, or nil when the line is not one.
    static func inputStart(_ line: String) -> String? {
        let body = stripLeadingFrame(line)
        guard let marker = body.first, markers.contains(marker) else { return nil }
        let rest = body.dropFirst()
        guard rest.isEmpty || rest.first == " " || rest.first == "\u{00A0}" else { return nil }
        return String(rest.dropFirst())
    }

    /// A horizontal rule or the top or bottom of a box: mostly box-drawing characters.
    static func isRule(_ line: String) -> Bool {
        let drawn = line.filter { "─━═╭╮╰╯┌┐└┘▔▁-".contains($0) }.count
        let visible = line.filter { !$0.isWhitespace }.count
        return drawn >= 8 && drawn * 10 >= visible * 8
    }

    // MARK: The terminal's font

    /// A font as a terminal's settings name it: a family ("JetBrains Mono") or PostScript name ("MesloLGS-NF-Regular").
    struct Font: Equatable {
        var name: String
        var size: Double?
    }

    /// The font set in a terminal's own settings, for when it does not say through Accessibility which font it draws in: a
    /// suggestion in another font would not line up with the monospaced text. Read again at most once a minute per app.
    static func configuredFont(for bundleID: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Font? {
        guard let bundleID else { return nil }
        if let cached = fontCache[bundleID], Date().timeIntervalSince(cached.read) < 60 { return cached.font }
        let font = readFont(for: bundleID, home: home)
        fontCache[bundleID] = (Date(), font)
        return font
    }

    private static var fontCache: [String: (read: Date, font: Font?)] = [:]

    private static func readFont(for bundleID: String, home: URL) -> Font? {
        func text(_ path: String) -> String? { try? String(contentsOf: home.appendingPathComponent(path), encoding: .utf8) }
        switch bundleID {
        case "com.googlecode.iterm2":
            let defaults = UserDefaults(suiteName: "com.googlecode.iterm2")
            let profiles = defaults?.array(forKey: "New Bookmarks") as? [[String: Any]] ?? []
            let defaultID = defaults?.string(forKey: "Default Bookmark Guid")
            let profile = profiles.first { $0["Guid"] as? String == defaultID } ?? profiles.first
            return (profile?["Normal Font"] as? String).flatMap(iTermFont)
        case "com.mitchellh.ghostty":
            let paths = [".config/ghostty/config", ".config/ghostty/config.ghostty", "Library/Application Support/com.mitchellh.ghostty/config",
                         "Library/Application Support/com.mitchellh.ghostty/config.ghostty"]
            return paths.lazy.compactMap { text($0).flatMap(ghosttyFont) }.first
        case "net.kovidgoyal.kitty":
            return text(".config/kitty/kitty.conf").flatMap(kittyFont)
        default:
            return nil
        }
    }

    /// iTerm2's "Normal Font": the PostScript name and the size, "MesloLGS-NF-Regular 13".
    static func iTermFont(_ value: String) -> Font? {
        let parts = value.split(separator: " ")
        guard let last = parts.last, let size = Double(last), parts.count >= 2 else { return value.isEmpty ? nil : Font(name: value) }
        return Font(name: parts.dropLast().joined(separator: " "), size: size)
    }

    /// Ghostty's `font-family = "JetBrains Mono"` and `font-size = 13` (the first family is the one it draws text in).
    static func ghosttyFont(_ config: String) -> Font? {
        var name: String?, size: Double?
        for line in config.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].hasPrefix("#") else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if parts[0] == "font-family", name == nil, !value.isEmpty { name = value }
            if parts[0] == "font-size" { size = Double(value) }
        }
        return name.map { Font(name: $0, size: size) }
    }

    /// kitty's `font_family JetBrains Mono` and `font_size 12.0`.
    static func kittyFont(_ config: String) -> Font? {
        var name: String?, size: Double?
        for line in config.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let space = trimmed.firstIndex(where: \.isWhitespace) else { continue }
            let key = trimmed[..<space], value = trimmed[space...].trimmingCharacters(in: .whitespaces)
            if key == "font_family", value != "monospace", value != "auto" { name = value }
            if key == "font_size" { size = Double(value) }
        }
        return name.map { Font(name: $0, size: size) }
    }

    private static func stripLeadingFrame(_ line: String) -> Substring {
        line.drop { $0.isWhitespace || frame.contains($0) }
    }

    private static func stripTrailingFrame(_ text: String) -> String {
        var text = Substring(text)
        while let last = text.last, last.isWhitespace || frame.contains(last) { text = text.dropLast() }
        return String(text)
    }
}
