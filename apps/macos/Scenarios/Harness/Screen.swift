import AppKit
import SwiftUI

/// One element of the window's accessibility tree, as a scenario finds it: what VoiceOver would read.
struct ScreenElement {
    let object: NSObject
    let role: String
    let label: String
    let value: String
    let frame: NSRect

    /// Every text the element carries, for a text search.
    var texts: [String] { [label, value].filter { !$0.isEmpty } }
    var isButton: Bool { role == NSAccessibility.Role.button.rawValue || role == NSAccessibility.Role.menuButton.rawValue }
}

/// What a scenario looks for: a description for the report, and the query on the current tree.
struct Locator {
    let description: String
    let match: (ScreenElement) -> Bool
    let screen: Screen
    var index: Int?

    /// The first match, where several elements match.
    var first: Locator { var copy = self; copy.index = 0; return copy }

    @MainActor func resolve() -> ScreenElement? {
        let found = screen.elements().filter(match).filter { screen.isOnScreen($0) }
        if let index { return index < found.count ? found[index] : nil }
        return found.first
    }

    @MainActor func count() -> Int { screen.elements().filter(match).filter { screen.isOnScreen($0) }.count }

    /// Presses the element as VoiceOver does (`accessibilityPerformPress`). A missing element means the scenario could
    /// not run, not that the behavior is broken.
    @MainActor func tap(timeout: TimeInterval = 10) throws {
        try screen.scenario.step("tap", description) {
            let element = try waitForElement(timeout: timeout)
            screen.scenario.log("tap \(element.role) \(element.label)")
            guard axNode(element.object).accessibilityPerformPress?() == true else {
                throw ScenarioFailure.couldNotRun("\(description) did not take the press")
            }
            screen.settle()
        }
    }

    /// Types into a text field or text view, replacing what it holds.
    @MainActor func fill(_ text: String, timeout: TimeInterval = 10) throws {
        try screen.scenario.step("fill", "\(description) ← \(text)") {
            let element = try waitForElement(timeout: timeout)
            if let textView = element.object as? NSTextView {
                textView.window?.makeFirstResponder(textView)
                textView.selectAll(nil)
                textView.insertText(text, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
            } else if let field = element.object as? NSTextField {
                field.stringValue = text
                field.sendAction(field.action, to: field.target)
            } else {
                axNode(element.object).setAccessibilityValue?(text)
            }
            screen.settle()
        }
    }

    @MainActor private func waitForElement(timeout: TimeInterval) throws -> ScreenElement {
        let end = Date().addingTimeInterval(timeout)
        while true {
            screen.refresh()
            if let element = resolve() { return element }
            if Date() > end { throw ScenarioFailure.couldNotRun("\(description) is not on screen") }
            ScenarioClock.spin(nanoseconds: 100_000_000)
        }
    }
}

/// The hosted window's content, read through its accessibility tree.
@MainActor
final class Screen {
    let scenario: Scenario
    weak var window: NSWindow?
    var host: NSView? { window?.contentView }

    init(scenario: Scenario) {
        self.scenario = scenario
    }

    /// Text anywhere: a label, a value, or a text view's contents. `exact` asks for the whole text.
    func text(_ needle: String, exact: Bool = false) -> Locator {
        Locator(description: "text \"\(needle)\"", match: { element in
            element.texts.contains { exact ? $0 == needle : $0.localizedCaseInsensitiveContains(needle) }
        }, screen: self)
    }

    /// A button by its label (what VoiceOver reads).
    func button(_ label: String, exact: Bool = true) -> Locator {
        Locator(description: "button \"\(label)\"", match: { element in
            element.isButton && (exact ? element.label == label : element.label.localizedCaseInsensitiveContains(label))
        }, screen: self)
    }

    /// An element by its accessibility label, of any role.
    func labelled(_ label: String, exact: Bool = true) -> Locator {
        Locator(description: "element \"\(label)\"", match: { element in
            exact ? element.label == label : element.label.localizedCaseInsensitiveContains(label)
        }, screen: self)
    }

    /// Lets SwiftUI apply what changed: the window is never on screen, so nothing draws it by itself.
    func refresh() {
        guard let window, let host else { return }
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    /// A few run loop turns, so state changes reach the views.
    func settle(_ seconds: TimeInterval = 0.3) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            refresh()
            ScenarioClock.spin(nanoseconds: 50_000_000)
        }
        refresh()
    }

    /// Whether an element lies inside the window's content (the window is offscreen, so frames are compared to it).
    func isOnScreen(_ element: ScreenElement) -> Bool {
        guard let window else { return false }
        let frame = element.frame
        guard frame.width > 0.5, frame.height > 0.5 else { return false }
        return window.frame.intersects(frame)
    }

    func elements() -> [ScreenElement] {
        guard let host else { return [] }
        var result: [ScreenElement] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: Any, depth: Int) {
            guard depth < 80, let node = object as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return }
            let ax = axNode(node)
            let role = axText(ax.accessibilityRole?() ?? nil)
            var label = axText(ax.accessibilityLabel?() ?? nil)
            if label.isEmpty { label = axText(ax.accessibilityTitle?() ?? nil) }
            var value = ""
            if let textView = node as? NSTextView {
                value = textView.string
            } else if let field = node as? NSTextField {
                value = field.stringValue
            } else if let raw = ax.accessibilityValue?() ?? nil {
                value = axText(raw)
            }
            result.append(ScreenElement(object: node, role: role, label: label, value: value, frame: ax.accessibilityFrame?() ?? .zero))
            for child in (ax.accessibilityChildren?() ?? nil) ?? [] { visit(child, depth: depth + 1) }
            // AppKit views SwiftUI hosts (text views, scroll views) are reached through their subviews too.
            if let view = node as? NSView {
                for subview in view.subviews where !seen.contains(ObjectIdentifier(subview)) { visit(subview, depth: depth + 1) }
            }
        }
        visit(host, depth: 0)
        return result
    }

    /// The tree as text, for the report of a scenario that failed.
    func dump(limit: Int = 400) -> String {
        elements().prefix(limit).map { element in
            let value = element.value.count > 120 ? String(element.value.prefix(120)) + "…" : element.value
            return "\(element.role) \"\(element.label)\"" + (value.isEmpty ? "" : " = \"\(value)\"")
                + " \(type(of: element.object)) \(Int(element.frame.minX)),\(Int(element.frame.minY)) \(Int(element.frame.width))x\(Int(element.frame.height))"
                + (isOnScreen(element) ? "" : " (off)")
        }.joined(separator: "\n")
    }
}

/// The NSAccessibility methods a scenario reads, called by name: SwiftUI's elements answer them without one Swift type
/// that declares them all, and a method an element lacks is skipped.
@objc private protocol AXNode {
    @objc optional func accessibilityRole() -> Any?
    @objc optional func accessibilityLabel() -> Any?
    @objc optional func accessibilityTitle() -> Any?
    @objc optional func accessibilityValue() -> Any?
    @objc optional func accessibilityFrame() -> NSRect
    @objc optional func accessibilityChildren() -> [Any]?
    @objc optional func accessibilityPerformPress() -> Bool
    @objc optional func setAccessibilityValue(_ value: Any?)
}

private func axNode(_ object: NSObject) -> AXNode { unsafeBitCast(object, to: AXNode.self) }

/// An accessibility text, which may come as a string or an attributed string.
private func axText(_ value: Any?) -> String {
    if let string = value as? String { return string }
    if let attributed = value as? NSAttributedString { return attributed.string }
    if let number = value as? NSNumber { return number.stringValue }
    return ""
}
