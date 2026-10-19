import Foundation
import AppKit
import ApplicationServices

/// Reads an app's text through the macOS accessibility layer (the one VoiceOver uses) instead of a screenshot.
/// That also works when the app is hidden or behind other windows, so Nook can read an app entirely in the background
/// without the user seeing anything. Asks once for Accessibility permission.
enum AppTextReader {
    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Asks macOS for the permission (opens the system prompt once).
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// All text in the app's windows, largest window first, within `limit` characters. Empty if there is nothing to read.
    static func text(pid: pid_t, limit: Int) async -> [(title: String, text: String)] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: read(pid: pid, limit: limit))
            }
        }
    }

    /// Electron and Chromium apps (Slack, Teams, WhatsApp, Chrome) only build their accessibility tree when someone asks for it.
    static func wake(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// The text of the app's focused window, within `limit` characters; nil when there is nothing to read. Synchronous: call it
    /// off the main thread.
    static func focusedWindowText(pid: pid_t, limit: Int) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let focused = value(app, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var lines: [String] = []
        var budget = 5000
        var count = 0
        collect(focused as! AXUIElement, depth: 0, into: &lines, budget: &budget, count: &count, chars: limit)
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(limit))
    }

    private static func read(pid: pid_t, limit: Int) -> [(title: String, text: String)] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.5)
        let windows = (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var result: [(String, String)] = []
        var remaining = limit
        for window in windows.prefix(3) where remaining > 200 {
            var lines: [String] = []
            var budget = 5000
            var count = 0
            collect(window, depth: 0, into: &lines, budget: &budget, count: &count, chars: remaining)
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let chunk = String(text.prefix(remaining))
            remaining -= chunk.count
            result.append(((value(window, kAXTitleAttribute) as? String) ?? "", chunk))
        }
        return result
    }

    private static func collect(_ element: AXUIElement, depth: Int, into lines: inout [String], budget: inout Int, count: inout Int, chars: Int) {
        guard depth < 60, budget > 0, count < chars else { return }
        budget -= 1
        let role = (value(element, kAXRoleAttribute) as? String) ?? ""
        // Never password fields.
        if role == "AXSecureTextField" { return }
        var parts: [String] = []
        if let text = value(element, kAXValueAttribute) as? String { parts.append(text) }
        if ["AXButton", "AXLink", "AXCell", "AXRow", "AXHeading", "AXMenuButton", "AXRadioButton", "AXTab", "AXImage"].contains(role)
            || parts.isEmpty {
            if let title = value(element, kAXTitleAttribute) as? String { parts.append(title) }
            if role != "AXGroup", let description = value(element, kAXDescriptionAttribute) as? String { parts.append(description) }
        }
        for part in parts {
            let clean = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, lines.last != clean {
                lines.append(clean)
                count += clean.count + 1
            }
        }
        // Menus and toolbars are not content.
        if ["AXMenuBar", "AXMenu", "AXToolbar", "AXScrollBar"].contains(role) { return }
        for child in (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            collect(child, depth: depth + 1, into: &lines, budget: &budget, count: &count, chars: chars)
        }
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
}
