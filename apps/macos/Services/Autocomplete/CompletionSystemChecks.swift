import AppKit
import Carbon.HIToolbox

/// Things elsewhere on the Mac that get in autocomplete's way, for Settings to point out.
enum CompletionSystemChecks {
    /// macOS's own inline text predictions (macOS 14 and later): they can show at the same spot as Nook's suggestion. On by
    /// default, so a missing setting counts as on.
    static var inlinePredictionsOn: Bool {
        (UserDefaults.standard.object(forKey: "NSAutomaticInlinePredictionEnabled") as? Bool) ?? true
    }

    /// Keyboard settings, where the predictions are turned off (Text Input › Edit).
    static let keyboardSettings = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")

    /// Whether macOS Secure Input is on (no key reaches Nook then, so no suggestions), and the app that turned it on when
    /// macOS says: the login session names the process holding it. Usually a password field left open in another app.
    static func secureInput() -> (on: Bool, holder: String?) {
        guard IsSecureEventInputEnabled() else { return (false, nil) }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, pid > 0,
              pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid) else { return (true, nil) }
        // The login window holds it while the screen is locked: nothing for the user to close.
        guard app.bundleIdentifier != "com.apple.loginwindow" else { return (true, nil) }
        return (true, app.localizedName ?? app.bundleIdentifier)
    }
}
