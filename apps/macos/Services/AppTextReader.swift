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
    /// Shares `AutocompleteField.wake`: once per process, and AXEnhancedUserInterface only for Chromium browsers.
    static func wake(pid: pid_t) {
        AutocompleteField.wake(pid: pid, bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
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

    /// The text of the pane around the focused element: the nearest ancestor with at least `minimum` characters of text (the
    /// conversation above a message field, the mail being answered), not the whole window with its sidebar and lists first.
    /// Read in screen order and cut from the front, so the end stays: in a chat that is the newest messages, right above the
    /// field. Falls back to the whole focused window. Nil when there is nothing to read. Synchronous: call it off the main thread.
    static func textAroundFocus(pid: pid_t, limit: Int, minimum: Int = 400) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var found: String?
        // One budget for the whole walk, not one per ancestor: twelve ancestors of 5000 elements each kept a chat app (Slack,
        // Teams) busy answering for seconds.
        var budget = Self.aroundFocusBudget
        let deadline = CFAbsoluteTimeGetCurrent() + Self.walkSeconds
        if let focused = value(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            var element = focused as! AXUIElement
            for _ in 0..<12 {
                guard let parent = value(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                element = parent as! AXUIElement
                let role = (value(element, kAXRoleAttribute) as? String) ?? ""
                if role == "AXWindow" || role == "AXApplication" { break }
                let text = collectedText(element, chars: limit * 4, budget: &budget, deadline: deadline)
                if text.count >= minimum || budget <= 0 { found = text; break }
            }
        }
        if found == nil, let window = value(app, kAXFocusedWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() {
            budget = max(budget, Self.aroundFocusBudget / 2)
            found = collectedText(window as! AXUIElement, chars: limit * 4, budget: &budget, deadline: deadline)
        }
        guard let text = found, !text.isEmpty else { return nil }
        return String(text.suffix(limit))
    }

    /// How many elements `textAroundFocus` asks the app about at most.
    private static let aroundFocusBudget = 800

    private static func collectedText(_ element: AXUIElement, chars: Int, budget: inout Int, deadline: CFAbsoluteTime) -> String {
        var lines: [String] = []
        var count = 0
        collect(element, depth: 0, into: &lines, budget: &budget, count: &count, chars: chars, deadline: deadline)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// How long one walk through an app's elements may take. A chat app with thousands of elements keeps answering for
    /// seconds, and every answer costs the app and Nook CPU; what has been read by then is enough.
    private static let walkSeconds: CFTimeInterval = 0.6

    /// The attributes `collect` needs of an element, asked in one round trip: one message to the app instead of five.
    private static let walkAttributes = [kAXRoleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                                         kAXChildrenAttribute] as CFArray

    private static func collect(_ element: AXUIElement, depth: Int, into lines: inout [String], budget: inout Int, count: inout Int, chars: Int,
                                deadline: CFAbsoluteTime = CFAbsoluteTimeGetCurrent() + walkSeconds) {
        guard depth < 60, budget > 0, count < chars, CFAbsoluteTimeGetCurrent() < deadline else { return }
        budget -= 1
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, walkAttributes, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let values = raw as? [AnyObject], values.count == 5 else { return }
        func attribute(_ i: Int) -> AnyObject? {
            let item = values[i]
            // An attribute the element does not have comes back as an AXValue holding an error.
            if CFGetTypeID(item) == AXValueGetTypeID(), AXValueGetType(item as! AXValue) == .axError { return nil }
            return item
        }
        let role = (attribute(0) as? String) ?? ""
        // Never password fields.
        if role == "AXSecureTextField" { return }
        var parts: [String] = []
        if let text = attribute(1) as? String { parts.append(text) }
        if ["AXButton", "AXLink", "AXCell", "AXRow", "AXHeading", "AXMenuButton", "AXRadioButton", "AXTab", "AXImage"].contains(role)
            || parts.isEmpty {
            if let title = attribute(2) as? String { parts.append(title) }
            if role != "AXGroup", let description = attribute(3) as? String { parts.append(description) }
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
        for child in (attribute(4) as? [AXUIElement]) ?? [] {
            collect(child, depth: depth + 1, into: &lines, budget: &budget, count: &count, chars: chars, deadline: deadline)
        }
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
}
