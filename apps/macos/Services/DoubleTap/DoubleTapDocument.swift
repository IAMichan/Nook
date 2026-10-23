import AppKit
import ApplicationServices

/// The document in front (Word's page, a Pages or TextEdit document, a mail, a note) as one text, read through the
/// accessibility layer, and Nook's hands in it: select a part the way a person would and type over it.
///
/// Selecting tries, in order: the accessibility layer (no mouse moves), the mouse (a click at the start and a shift-click at
/// the end, where the app's own window is on top), and the keyboard (the cursor at the start, then shift+→). Typing goes
/// through the clipboard and ⌘V (`FlowPaste`), deleting with the Delete key; both are undone with ⌘Z in the app. Password
/// fields are never read or written.
@MainActor
struct DoubleTapDocument {
    var element: AXUIElement
    var text: String
    /// The selection, or the cursor when its length is 0 (UTF-16 offsets).
    var selection: NSRange
    var title: String

    /// Longer documents are not edited this way: reading and comparing them takes too long.
    private static let maxLength = 400_000
    private static let maxNodes = 1_500
    private static let maxDepth = 14
    /// The keyboard selects at most this many characters with shift+→.
    private static let maxKeySelect = 1_500

    /// The focused text of the app, or else the longest text area of its focused window (the page of a word processor when
    /// the focus is on a toolbar). Nil when there is none, or when the focus is a password field.
    static func read(_ app: NSRunningApplication) -> DoubleTapDocument? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(root, 1.5)
        let focused: AXUIElement? = attribute(root, kAXFocusedUIElementAttribute)
        if let focused, isSecure(focused) { return nil }
        let window: AXUIElement? = attribute(root, kAXFocusedWindowAttribute) ?? focused.flatMap { attribute($0, kAXWindowAttribute) }
        let title = window.flatMap { attribute($0, kAXTitleAttribute) as String? } ?? ""
        if let focused, let document = document(focused, title: title) { return document }
        guard let window else { return nil }
        var best: (element: AXUIElement, length: Int)?
        var visited = 0
        func walk(_ node: AXUIElement, depth: Int) {
            guard depth <= maxDepth, visited < maxNodes else { return }
            visited += 1
            let role: String? = attribute(node, kAXRoleAttribute)
            if role == kAXMenuBarRole as String { return }
            if role == kAXTextAreaRole as String, !isSecure(node), let value: String = attribute(node, kAXValueAttribute) {
                let length = (value as NSString).length
                if length > (best?.length ?? 0) { best = (node, length) }
                return
            }
            for child in children(node) { walk(child, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return best.flatMap { document($0.element, title: title) }
    }

    private static func document(_ element: AXUIElement, title: String) -> DoubleTapDocument? {
        guard let value: String = attribute(element, kAXValueAttribute) else { return nil }
        let length = (value as NSString).length
        guard length > 0, length <= maxLength else { return nil }
        let range = selectedRange(element) ?? NSRange(location: 0, length: 0)
        let clamped = range.location + range.length <= length ? range : NSRange(location: 0, length: 0)
        return DoubleTapDocument(element: element, text: value, selection: clamped, title: title)
    }

    /// The text as the app holds it now.
    func current() -> String? {
        Self.attribute(element, kAXValueAttribute)
    }

    // MARK: Changing it

    /// Selects `edit`'s text and types its new text over it (or deletes it), then checks the document reads as it should.
    /// `show`: where Nook acts (screen point, top-left origin), for its violet cursor.
    func apply(_ edit: DoubleTapEdit, in app: NSRunningApplication, show: ((CGPoint, String) -> Void)?) async -> Bool {
        guard let before = current(), (before as NSString).length >= edit.range.location + edit.range.length,
              DoubleTapLogic.fold((before as NSString).substring(with: edit.range)) == DoubleTapLogic.fold(edit.find) else {
            return false
        }
        if let rect = bounds(NSRange(location: edit.range.location, length: 1)) {
            show?(CGPoint(x: rect.minX, y: rect.midY), DoubleTapLogic.preview(edit.find, limit: 30))
        }
        guard await select(edit.range, in: app) else { return false }
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        if edit.replace.isEmpty {
            Self.press(key: 0x33) // Delete
        } else {
            guard case .pasted = FlowPaste.insert(edit.replace) else { return false }
        }
        // The app takes the paste in its own time.
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if let after = current(), DoubleTapLogic.applied(edit, before: before, after: after) { return true }
        }
        // Some apps hold the text a little differently after a change (a paragraph mark, a list number): changed is enough.
        return current().map { $0 != before } ?? false
    }

    /// Selects a range: through the accessibility layer, else with the mouse, else with the keyboard. True when the app
    /// shows exactly that text selected.
    private func select(_ range: NSRange, in app: NSRunningApplication) async -> Bool {
        let wanted = DoubleTapLogic.fold((text as NSString).substring(with: range))
        func selected() -> Bool {
            if let now = Self.selectedRange(element), now == range { return true }
            guard let picked: String = Self.attribute(element, kAXSelectedTextAttribute) else { return false }
            return DoubleTapLogic.fold(picked) == wanted
        }
        // 1. The accessibility layer.
        if setSelection(range) {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if selected() { return true }
        }
        // 2. The mouse: a click before the first letter, a shift-click after the last one.
        if let first = bounds(NSRange(location: range.location, length: 1)),
           let last = bounds(NSRange(location: range.location + range.length - 1, length: 1)) {
            let start = CGPoint(x: first.minX + 0.5, y: first.midY)
            let end = CGPoint(x: last.maxX - 0.5, y: last.midY)
            if UIDriver.owns(start, pid: app.processIdentifier), UIDriver.owns(end, pid: app.processIdentifier) {
                let home = CGEvent(source: nil)?.location
                Self.click(at: start, shift: false)
                try? await Task.sleep(nanoseconds: 120_000_000)
                Self.click(at: end, shift: true)
                try? await Task.sleep(nanoseconds: 200_000_000)
                if let home { CGWarpMouseCursorPosition(home) }
                if selected() { return true }
            }
        }
        // 3. The keyboard: the cursor at the start, then shift+→ once per character.
        let characters = (text as NSString).substring(with: range).count
        guard characters <= Self.maxKeySelect, setSelection(NSRange(location: range.location, length: 0)) else { return false }
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard Self.selectedRange(element)?.location == range.location else { return false }
        for _ in 0..<characters {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
            Self.press(key: 0x7C, flags: .maskShift) // →
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        return selected()
    }

    private func setSelection(_ range: NSRange) -> Bool {
        var cf = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    /// Where a range is on screen (top-left origin), when the app says.
    private func bounds(_ range: NSRange) -> CGRect? {
        var cf = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cf) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter,
                                                         &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.width >= 0, rect.height > 0 else { return nil }
        return rect
    }

    // MARK: Mouse and keys

    private static func click(at point: CGPoint, shift: Bool) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            if shift { event?.flags = .maskShift }
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func press(key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Accessibility values

    private static func isSecure(_ element: AXUIElement) -> Bool {
        let role: String? = attribute(element, kAXRoleAttribute)
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        return role == "AXSecureTextField" || subrole == kAXSecureTextFieldSubrole as String
    }

    private static func selectedRange(_ element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        }
        return value as? T
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return (value as? [AXUIElement]) ?? []
    }
}
