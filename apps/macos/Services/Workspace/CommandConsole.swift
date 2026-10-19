import Foundation

/// The terminal next to a session's conversation: the shell command the agent runs, and what it prints, as it arrives.
enum CommandConsole {
    /// A shell tool call: Bash, Codex's commands, Nook's `terminal_run`.
    static func isCommand(_ event: RunEvent) -> Bool {
        event.kind == .tool && ToolCategory.of(tool: event.tool ?? "") == .command
    }

    /// The command that runs now in the session's latest turn, or nil.
    static func running(_ events: [RunEvent]) -> RunEvent? {
        TimelinePresentation.split(events).last?.last { isCommand($0) && $0.state == .running }
    }

    /// "npm test": the command line itself, else the call's summary.
    static func commandLine(_ event: RunEvent) -> String {
        AgentActivity.command(event) ?? event.text
    }

    private static let escapes = try? NSRegularExpression(pattern: "\u{1B}(\\[[0-9;?]*[ -/]*[@-~]|\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|[()][A-Za-z0-9])")

    /// The output as plain text: colours and other escape codes out, and a line that a progress bar redraws with `\r`
    /// shows only how it ended.
    static func output(_ raw: String?) -> String {
        guard var text = raw, !text.isEmpty else { return "" }
        if text.contains("\u{1B}"), let escapes {
            text = escapes.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text), withTemplate: "")
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard text.contains("\r") else { return text }
        return text.components(separatedBy: "\n").map { line in
            let parts = line.components(separatedBy: "\r")
            return parts.last { !$0.isEmpty } ?? ""
        }.joined(separator: "\n")
    }
}
