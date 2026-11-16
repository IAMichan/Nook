import AppKit
import CoreGraphics

extension SessionFocus {
    /// What is in front of you now; nil while the screen is locked or Nook itself is in front.
    @MainActor
    static func current() -> Front? {
        if SystemLoad.isScreenLocked { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return Front(bundleID: bundleID, windowTitle: windowTitle(of: app.processIdentifier), idle: SystemLoad.idleSeconds)
    }

    /// The title of the app's front window. macOS only gives it with screen recording permission; otherwise nil.
    private static func windowTitle(of pid: pid_t) -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        // Front to back: the first normal window of the app is the one you look at.
        let window = list.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        guard let title = window?[kCGWindowName as String] as? String, !title.isEmpty else { return nil }
        return title
    }
}
