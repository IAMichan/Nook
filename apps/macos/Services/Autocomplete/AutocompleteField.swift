import AppKit
import ApplicationServices

// The text-marker helpers are in ApplicationServices but not in its headers. Chromium, Electron and WebKit give the cursor's
// place only through them. Create/Copy return an owned reference.
@_silgen_name("AXTextMarkerRangeCreate")
private func AXTextMarkerRangeCreate(_ allocator: CFAllocator?, _ start: CFTypeRef, _ end: CFTypeRef) -> CFTypeRef?
@_silgen_name("AXTextMarkerRangeCopyEndMarker")
private func AXTextMarkerRangeCopyEndMarker(_ range: CFTypeRef) -> CFTypeRef?

/// The focused text field at one moment.
struct AutocompleteFieldSnapshot {
    var before: String
    var after: String
    var hasSelection: Bool
    /// The cursor in AppKit screen coordinates (origin bottom left).
    var caret: CGRect?
    var selectedText = ""
    var selectionRect: CGRect?
    var fieldFrame: CGRect?
    var windowTitle: String?
    /// The field's placeholder ("Write a reply…").
    var placeholder: String?
    /// The website's host, in browsers.
    var site: String?
}

/// Reads the focused field of the front app through the Accessibility API. Password fields are never read. Slow apps can take
/// tens of milliseconds to answer, so this runs off the main thread. After Typist's reader (MIT, © 2026 Brody Salvucci).
enum AutocompleteField {
    /// Chromium and Electron apps only build their accessibility tree when asked.
    static func wake(_ app: NSRunningApplication) {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// - Parameter screenHeight: the main screen's height (`NSScreen.screens[0].frame.height`), taken on the main thread.
    static func read(screenHeight: CGFloat) -> AutocompleteFieldSnapshot? {
        guard AXIsProcessTrusted(), let element = focusedElement() else { return nil }
        let role: String? = attribute(element, kAXRoleAttribute)
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        guard role != "AXSecureTextField", subrole != (kAXSecureTextFieldSubrole as String) else { return nil }
        guard let value: String = attribute(element, kAXValueAttribute), let range = selectedRange(of: element) else { return nil }
        let text = value as NSString
        guard range.location >= 0, range.location + range.length <= text.length else { return nil }

        let flip = { (rect: CGRect) in CGRect(x: rect.minX, y: screenHeight - rect.maxY, width: rect.width, height: rect.height) }
        // Web content gives trailing spaces as non-breaking spaces.
        var snapshot = AutocompleteFieldSnapshot(
            before: text.substring(to: range.location).replacingOccurrences(of: "\u{00A0}", with: " "),
            after: text.substring(from: range.location + range.length).replacingOccurrences(of: "\u{00A0}", with: " "),
            hasSelection: range.length > 0,
            caret: caretRect(in: element, at: range.location + range.length).map(flip)
        )
        if range.length > 0 {
            snapshot.selectedText = text.substring(with: NSRange(location: range.location, length: range.length))
            snapshot.selectionRect = bounds(in: element, location: range.location, length: range.length).map(flip)
        }
        if let size: CGSize = axValue(element, kAXSizeAttribute, .cgSize), let origin: CGPoint = axValue(element, kAXPositionAttribute, .cgPoint) {
            snapshot.fieldFrame = flip(CGRect(origin: origin, size: size))
        }
        if snapshot.caret == nil { snapshot.caret = markerCaret(in: element).map(flip) }
        snapshot.placeholder = attribute(element, kAXPlaceholderValueAttribute)
        if let window: AXUIElement = attribute(element, kAXWindowAttribute) { snapshot.windowTitle = attribute(window, kAXTitleAttribute) }
        snapshot.site = site(containing: element)
        return snapshot
    }

    // MARK: Private

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        if let element: AXUIElement = attribute(system, kAXFocusedUIElementAttribute) {
            AXUIElementSetMessagingTimeout(element, 0.25)
            return element
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let owner = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(owner, 0.25)
        return attribute(owner, kAXFocusedUIElementAttribute)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil
        }
        return value as? T
    }

    private static func axValue<T>(_ element: AXUIElement, _ name: String, _ type: AXValueType) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        return AXValueGetValue(value as! AXValue, type, pointer) ? pointer.pointee : nil
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        axValue(element, kAXSelectedTextRangeAttribute, .cfRange)
    }

    private static func bounds(in element: AXUIElement, location: Int, length: Int) -> CGRect? {
        var range = CFRange(location: location, length: length)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 1, rect.height < 400 else { return nil }
        return rect
    }

    /// Most apps give no box for an empty range: then the right edge of the character before the cursor.
    private static func caretRect(in element: AXUIElement, at location: Int) -> CGRect? {
        if let caret = bounds(in: element, location: location, length: 0) {
            return CGRect(x: caret.minX, y: caret.minY, width: 0, height: caret.height)
        }
        if location > 0, let previous = bounds(in: element, location: location - 1, length: 1) {
            return CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height)
        }
        return nil
    }

    private static func markerBounds(in element: AXUIElement, range: CFTypeRef) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForTextMarkerRange" as CFString, range, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 1 else { return nil }
        return rect
    }

    private static func marker(_ name: String, of marker: CFTypeRef, in element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, marker, &value) == .success else { return nil }
        return value
    }

    /// The cursor from the selected text-marker range (web content).
    private static func markerCaret(in element: AXUIElement) -> CGRect? {
        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &selection) == .success, let selection else { return nil }
        if let caret = markerBounds(in: element, range: selection) {
            return CGRect(x: caret.maxX, y: caret.minY, width: 0, height: caret.height)
        }
        guard let end = AXTextMarkerRangeCopyEndMarker(selection) else { return nil }
        if let previous = marker("AXPreviousTextMarkerForTextMarker", of: end, in: element),
           let range = AXTextMarkerRangeCreate(nil, previous, end), let box = markerBounds(in: element, range: range) {
            return CGRect(x: box.maxX, y: box.minY, width: 0, height: box.height)
        }
        if let next = marker("AXNextTextMarkerForTextMarker", of: end, in: element),
           let range = AXTextMarkerRangeCreate(nil, end, next), let box = markerBounds(in: element, range: range) {
            return CGRect(x: box.minX, y: box.minY, width: 0, height: box.height)
        }
        return nil
    }

    /// Up from the field to the web area around it, and its host.
    private static func site(containing element: AXUIElement) -> String? {
        var current = element
        for _ in 0..<40 {
            if let role: String = attribute(current, kAXRoleAttribute), role == "AXWebArea" {
                let url: URL? = attribute(current, kAXURLAttribute)
                return url?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            }
            guard let parent: AXUIElement = attribute(current, kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }
}

/// Types into the focused field with key events that carry the characters themselves, so the clipboard is untouched. The
/// events carry a mark, so Nook's key watcher knows they are not the user's.
enum AutocompleteTyper {
    static let marker: Int64 = 0x4E4F4F4B
    /// Some apps cut off longer strings.
    private static let chunk = 20

    /// Deletes `count` characters before the cursor, then types `text` (emoji, typo fixes, other words).
    static func replace(last count: Int, with text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: isDown) else { continue }
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: marker)
                event.post(tap: .cgSessionEventTap)
            }
        }
        type(text)
    }

    static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var start = 0
        while start < units.count {
            var end = min(start + chunk, units.count)
            // Never between the halves of a surrogate pair.
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            let piece = Array(units[start..<end])
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: piece.count, unicodeString: piece)
                event.setIntegerValueField(.eventSourceUserData, value: marker)
                event.post(tap: .cgSessionEventTap)
            }
            start = end
        }
    }
}
