import AppKit
import ApplicationServices

/// Presses the button of a prompt an agent's app draws (`AppPrompt`), through the accessibility layer, as you would
/// with the pointer. The app stays where it is: an accessibility press needs no focus, so nothing you are typing goes
/// elsewhere. Only a button `AppPrompt.button` is sure of is pressed; otherwise the caller opens the app.
enum AppPromptPresser {
    /// How long the app gets to build its accessibility tree the first time Nook asks (Electron builds it on request).
    private static let attempts = 5
    private static let pause: UInt64 = 300_000_000
    /// Elements read per window at most, so a long conversation cannot keep Nook busy.
    private static let budget = 12_000
    private static let maxDepth = 80

    /// True when the button was pressed.
    static func press(_ answer: AppPrompt.Answer, bundleIDs: [String]) async -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let running = bundleIDs.compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
        guard let app = running.first else { return false }
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier
        return await Task.detached(priority: .userInitiated) {
            AutocompleteField.wake(pid: pid, bundleID: bundleID)
            for attempt in 0..<attempts {
                if pressOnce(answer, pid: pid) { return true }
                if attempt < attempts - 1 { try? await Task.sleep(nanoseconds: pause) }
            }
            return false
        }.value
    }

    private static func pressOnce(_ answer: AppPrompt.Answer, pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 1)
        let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
        for window in windows {
            var buttons: [(label: String, ref: AXUIElement)] = []
            var left = budget
            collect(window, depth: 0, left: &left, into: &buttons)
            if let index = AppPrompt.button(answer, among: buttons.map(\.label)) {
                return AXUIElementPerformAction(buttons[index].ref, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    private static func collect(_ element: AXUIElement, depth: Int, left: inout Int,
                                into buttons: inout [(label: String, ref: AXUIElement)]) {
        guard left > 0, depth < maxDepth else { return }
        left -= 1
        if (attribute(element, kAXRoleAttribute) as String?) == kAXButtonRole {
            buttons.append((label(of: element), element))
            return
        }
        for child in (attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            collect(child, depth: depth + 1, left: &left, into: &buttons)
        }
    }

    /// What the button says: its title or description, or the texts inside it (a web button keeps its words there).
    private static func label(of element: AXUIElement) -> String {
        for name in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text: String = attribute(element, name), !text.trimmingCharacters(in: .whitespaces).isEmpty { return text }
        }
        var texts: [String] = []
        innerTexts(of: element, depth: 0, into: &texts)
        return texts.joined(separator: " ")
    }

    private static func innerTexts(of element: AXUIElement, depth: Int, into texts: inout [String]) {
        guard depth < 4, texts.count < 8 else { return }
        for child in (attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            if let value: String = attribute(child, kAXValueAttribute), !value.isEmpty { texts.append(value) }
            else if let title: String = attribute(child, kAXTitleAttribute), !title.isEmpty { texts.append(title) }
            innerTexts(of: child, depth: depth + 1, into: &texts)
        }
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
