import AppKit

/// Brings forward the window in which an agent is running: the app from the hook (Terminal, iTerm, VS Code…),
/// or otherwise the first known open terminal.
enum TerminalLauncher {
    static let knownTerminals = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", "dev.zed.Zed"
    ]

    /// Order in which Nook tries: first the session's app, then the known terminals.
    static func candidates(sessionBundleID: String?) -> [String] {
        let own = sessionBundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !own.isEmpty else { return knownTerminals }
        return [own] + knownTerminals.filter { $0 != own }
    }

    /// Returns false if no matching app is open.
    @MainActor
    @discardableResult
    static func activate(sessionBundleID: String?) -> Bool {
        for bundleID in candidates(sessionBundleID: sessionBundleID) {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                app.activate(options: [.activateAllWindows])
                return true
            }
        }
        return false
    }

    /// Opens a new Terminal window that runs `command` in `folder`, via your own shell (with your PATH, nvm, etc.).
    /// A .command file does not require extra permissions, unlike AppleScript.
    static func run(command: String, in folder: String, name: String) throws {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let script = """
        #!/bin/sh
        cd \(shellQuote(folder)) || exit 1
        clear
        exec \(shellQuote(shell)) -i -l -c \(shellQuote(command))

        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        guard NSWorkspace.shared.open(url) else { throw NookError("macOS refused to open the script.") }
    }

    /// Quotes text with single quotes for the shell.
    static func shellQuote(_ text: String) -> String {
        if !text.isEmpty, text.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@".contains($0) }) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// "Terminal", "iTerm", "VS Code"… for use on a button.
    static func name(for bundleID: String?) -> String {
        switch bundleID ?? "" {
        case "com.apple.Terminal": return "Terminal"
        case "com.googlecode.iterm2": return "iTerm"
        case "com.mitchellh.ghostty": return "Ghostty"
        case "dev.warp.Warp-Stable": return "Warp"
        case "com.microsoft.VSCode": return "VS Code"
        case "com.todesktop.230313mzl4w4u92": return "Cursor"
        case "dev.zed.Zed": return "Zed"
        default: return "terminal"
        }
    }
}
