import Foundation
import AppKit
import ApplicationServices

/// Leest de tekst van een app via de toegankelijkheidslaag van macOS (dezelfde die VoiceOver gebruikt), in plaats van
/// met een schermafbeelding. Dat werkt ook als de app verborgen is of achter andere vensters ligt, dus Nook kan een app
/// helemaal op de achtergrond lezen zonder dat je er iets van ziet. Vraagt eenmalig toestemming voor Toegankelijkheid.
enum AppTextReader {
    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Vraagt macOS om de toestemming (opent het systeemvenster één keer).
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Alle tekst in de vensters van de app, grootste venster eerst, binnen `limit` tekens. Leeg als er niets te lezen is.
    static func text(pid: pid_t, limit: Int) async -> [(title: String, text: String)] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: read(pid: pid, limit: limit))
            }
        }
    }

    /// Electron- en Chromium-apps (Slack, Teams, WhatsApp, Chrome) bouwen hun toegankelijkheidslaag pas als iemand erom vraagt.
    static func wake(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
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
        // Wachtwoordvelden nooit.
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
        // Menu's en werkbalken zijn geen inhoud.
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
