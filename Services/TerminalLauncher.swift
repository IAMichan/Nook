import AppKit

/// Haalt het venster naar voren waarin een agent draait: de app uit de hook (Terminal, iTerm, VS Code…),
/// of anders de eerste bekende terminal die open staat.
enum TerminalLauncher {
    static let knownTerminals = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", "dev.zed.Zed"
    ]

    /// Volgorde waarin Nook het probeert: eerst de app van de sessie, dan de bekende terminals.
    static func candidates(sessionBundleID: String?) -> [String] {
        let own = sessionBundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !own.isEmpty else { return knownTerminals }
        return [own] + knownTerminals.filter { $0 != own }
    }

    /// Geeft false als er geen passende app open staat.
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

    /// "Terminal", "iTerm", "VS Code"… voor op een knop.
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
