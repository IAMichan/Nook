import AppKit
import ApplicationServices

/// The text field that has the focus, as far as autocompletion needs it: the words before the cursor, whether anything stands
/// after it, and where the cursor is on screen.
struct AutocompleteFieldSnapshot: Equatable {
    var before: String
    var after: String
    /// The cursor's place in screen coordinates (origin bottom left, like AppKit's).
    var caret: CGRect
    var bundleID: String
}

enum AutocompleteField {
    /// Roles that take typed text. Search fields and combo boxes are left out on purpose: a suggestion there rarely helps.
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXWebArea"]

    /// Reads the focused field of the front app, or nil when there is none, it is a password field, the text is selected, or
    /// the app does not tell where the cursor is.
    @MainActor static func read(maxBefore: Int = 4_000) -> AutocompleteFieldSnapshot? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let owner = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(owner, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement

        let role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        guard role != "AXSecureTextField", subrole != "AXSecureTextField", let role, textRoles.contains(role) else { return nil }
        guard let value = string(element, kAXValueAttribute) else { return nil }

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection), selection.length == 0 else { return nil }

        let text = value as NSString
        let location = min(max(selection.location, 0), text.length)
        var beforeRange = NSRange(location: max(0, location - maxBefore), length: min(location, maxBefore))
        beforeRange = text.rangeOfComposedCharacterSequences(for: beforeRange)
        let before = text.substring(with: beforeRange)
        var afterRange = NSRange(location: location, length: min(text.length - location, 200))
        afterRange = text.rangeOfComposedCharacterSequences(for: afterRange)
        var after = text.substring(with: afterRange)
        if let newline = after.firstIndex(of: "\n") { after = String(after[..<newline]) }

        guard let caret = caretRect(element, location: location) else { return nil }
        return AutocompleteFieldSnapshot(before: before, after: after, caret: caret, bundleID: app.bundleIdentifier ?? "")
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// The box of the character before the cursor, with its right edge as the place to draw: the accessibility API gives
    /// no box for an empty range in most apps.
    private static func caretRect(_ element: AXUIElement, location: Int) -> CGRect? {
        guard location > 0 else { return nil }
        var range = CFRange(location: location - 1, length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var box = CGRect.zero
        guard AXValueGetValue(result as! AXValue, .cgRect, &box), box.height > 2, box.height < 200, box.width >= 0 else { return nil }
        // Accessibility counts from the top left of the main screen, AppKit from the bottom left.
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        return CGRect(x: box.maxX, y: mainHeight - box.maxY, width: 0, height: box.height)
    }
}

/// Types text into the focused field by sending key events that carry the characters themselves, so the clipboard stays as
/// it is. The events carry a mark, so Nook's own key watcher knows they are not the user's.
enum AutocompleteTyper {
    static let marker: Int64 = 0x4E4F4F4B

    static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var start = 0
        while start < units.count {
            // Cut between whole characters: never between the halves of a surrogate pair.
            var end = min(start + 20, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            let chunk = Array(units[start..<end])
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event.setIntegerValueField(.eventSourceUserData, value: marker)
                event.post(tap: .cghidEventTap)
            }
            start = end
        }
    }
}
