import AppKit
import ApplicationServices

// The text-marker helpers are in ApplicationServices but not in its headers. Chromium, Electron and WebKit give the cursor's
// place, and the text of rich editors (contenteditable: Gmail, Notion, Slack in the browser), only through them.
// Create/Copy return an owned reference.
@_silgen_name("AXTextMarkerRangeCreate")
private func AXTextMarkerRangeCreate(_ allocator: CFAllocator?, _ start: CFTypeRef, _ end: CFTypeRef) -> CFTypeRef?
@_silgen_name("AXTextMarkerRangeCopyStartMarker")
private func AXTextMarkerRangeCopyStartMarker(_ range: CFTypeRef) -> CFTypeRef?
@_silgen_name("AXTextMarkerRangeCopyEndMarker")
private func AXTextMarkerRangeCopyEndMarker(_ range: CFTypeRef) -> CFTypeRef?

/// The focused text field at one moment.
struct AutocompleteFieldSnapshot {
    var before: String
    var after: String
    var hasSelection: Bool
    /// The cursor in AppKit screen coordinates (origin bottom left): x is where the next letter goes, the height is the line's.
    var caret: CGRect?
    var selectedText = ""
    var selectionRect: CGRect?
    var fieldFrame: CGRect?
    var windowTitle: String?
    /// The field's placeholder ("Write a reply…").
    var placeholder: String?
    /// The website's host, in browsers.
    var site: String?
    /// The font of the text at the cursor, so the suggestion looks like the text it continues.
    var fontName: String?
    var fontSize: CGFloat?

    /// Where a card or the emoji picker goes: under the cursor, or under the field when it is a single line. A note or a long
    /// message is one tall field, and under (or, without room, above) it is far from where you type: without a cursor there is
    /// no good place, so nothing is shown.
    var cardAnchor: CGRect? {
        if let caret { return caret }
        guard let fieldFrame, fieldFrame.height <= max(40, (fontSize ?? 13) * 2.8) else { return nil }
        return fieldFrame
    }
}

/// Reads the focused field of the front app through the Accessibility API. Password fields are never read. Slow apps can take
/// tens of milliseconds to answer, so this runs off the main thread. Also reads rich web editors, the app's font and a strict
/// cursor position.
enum AutocompleteField {
    /// Browsers built on Chromium: they build their accessibility tree for web pages only when a client says it needs it.
    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "ai.perplexity.comet", "com.openai.atlas"
    ]

    /// Asks the app to build its accessibility tree: Electron apps listen to AXManualAccessibility, Chromium browsers to
    /// AXEnhancedUserInterface.
    static func wake(_ app: NSRunningApplication) {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if chromium.contains(app.bundleIdentifier ?? "") {
            AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    /// Roles that take typed text.
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// - Parameter screenHeight: the main screen's height (`NSScreen.screens[0].frame.height`), taken on the main thread.
    static func read(screenHeight: CGFloat) -> AutocompleteFieldSnapshot? {
        guard AXIsProcessTrusted(), let element = focusedElement(), isEditable(element) else { return nil }
        let role: String? = attribute(element, kAXRoleAttribute)
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        guard role != "AXSecureTextField", subrole != (kAXSecureTextFieldSubrole as String) else { return nil }
        let flip = { (rect: CGRect) in CGRect(x: rect.minX, y: screenHeight - rect.maxY, width: rect.width, height: rect.height) }

        var snapshot: AutocompleteFieldSnapshot
        var fontLocation: Int?
        if let value: String = attribute(element, kAXValueAttribute), let range = selectedRange(of: element),
           range.location >= 0, range.location + range.length <= (value as NSString).length {
            let text = value as NSString
            let cursor = range.location + range.length
            snapshot = AutocompleteFieldSnapshot(
                before: clean(text.substring(to: range.location)),
                after: clean(text.substring(from: cursor)),
                hasSelection: range.length > 0,
                caret: caretRect(in: element, at: cursor, text: text).map(flip)
            )
            if range.length > 0 {
                snapshot.selectedText = text.substring(with: NSRange(location: range.location, length: range.length))
                snapshot.selectionRect = bounds(in: element, location: range.location, length: range.length).map(flip)
            }
            if snapshot.caret == nil { snapshot.caret = markerCaret(in: element).map(flip) }
            fontLocation = cursor > 0 ? cursor - 1 : (text.length > 0 ? 0 : nil)
        } else if let marked = markerText(in: element) {
            // A rich editor without a plain value: the text comes from the text markers.
            snapshot = marked
            snapshot.caret = markerCaret(in: element).map(flip)
        } else {
            return nil
        }

        if let size: CGSize = axValue(element, kAXSizeAttribute, .cgSize), let origin: CGPoint = axValue(element, kAXPositionAttribute, .cgPoint) {
            snapshot.fieldFrame = flip(CGRect(origin: origin, size: size))
        }
        // A cursor outside its own field (scrolled away, a stale answer) would put the suggestion somewhere else on screen.
        if let caret = snapshot.caret, let field = snapshot.fieldFrame, field.width > 0,
           !field.insetBy(dx: -4, dy: -4).contains(CGPoint(x: caret.minX, y: caret.midY)) {
            snapshot.caret = nil
        }
        if let location = fontLocation, let font = font(in: element, at: location) {
            snapshot.fontName = font.name
            snapshot.fontSize = font.size
        }
        snapshot.placeholder = attribute(element, kAXPlaceholderValueAttribute)
        if let window: AXUIElement = attribute(element, kAXWindowAttribute) { snapshot.windowTitle = attribute(window, kAXTitleAttribute) }
        snapshot.site = site(containing: element)
        return snapshot
    }

    // MARK: Which element

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

    /// A field you can type in: a text role, a value that can be set, or (in browsers) an editable web element. A focused web
    /// page you only read is not one.
    private static func isEditable(_ element: AXUIElement) -> Bool {
        if let role: String = attribute(element, kAXRoleAttribute), textRoles.contains(role) { return true }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue { return true }
        if let editable: AXUIElement = attribute(element, "AXEditableAncestor"), CFGetTypeID(editable) == AXUIElementGetTypeID() { return true }
        if let editable: Bool = attribute(element, "AXEditable"), editable { return true }
        return false
    }

    // MARK: Text

    /// Web content gives spaces as non-breaking spaces, and some editors end with an object replacement character.
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    /// Before and after the cursor from text markers: from the start of the field to the selection, and from the selection to
    /// the end.
    private static func markerText(in element: AXUIElement) -> AutocompleteFieldSnapshot? {
        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &selection) == .success, let selection,
              let whole = parameterized(element, "AXTextMarkerRangeForUIElement", element),
              let fieldStart = AXTextMarkerRangeCopyStartMarker(whole), let fieldEnd = AXTextMarkerRangeCopyEndMarker(whole),
              let selectionStart = AXTextMarkerRangeCopyStartMarker(selection), let selectionEnd = AXTextMarkerRangeCopyEndMarker(selection),
              let beforeRange = AXTextMarkerRangeCreate(nil, fieldStart, selectionStart),
              let afterRange = AXTextMarkerRangeCreate(nil, selectionEnd, fieldEnd) else { return nil }
        let before = string(element, beforeRange) ?? ""
        let after = string(element, afterRange) ?? ""
        let selected = string(element, selection) ?? ""
        var snapshot = AutocompleteFieldSnapshot(before: clean(before), after: clean(after), hasSelection: !selected.isEmpty, caret: nil)
        snapshot.selectedText = selected
        return snapshot
    }

    private static func string(_ element: AXUIElement, _ range: CFTypeRef) -> String? {
        parameterized(element, "AXStringForTextMarkerRange", range) as? String
    }

    private static func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success else { return nil }
        return value
    }

    /// The font of one character, from the attributed string the app gives for it.
    private static func font(in element: AXUIElement, at location: Int) -> (name: String?, size: CGFloat)? {
        var range = CFRange(location: location, length: 1)
        guard let parameter = AXValueCreate(.cfRange, &range),
              let value = parameterized(element, kAXAttributedStringForRangeParameterizedAttribute, parameter),
              let attributed = value as? NSAttributedString, attributed.length > 0,
              let font = attributed.attribute(NSAttributedString.Key("AXFont"), at: 0, effectiveRange: nil) as? [String: Any],
              let size = (font["AXFontSize"] as? NSNumber).map({ CGFloat($0.doubleValue) }), size >= 6, size <= 96 else { return nil }
        return (font["AXFontName"] as? String, size)
    }

    // MARK: Values

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
        guard let parameter = AXValueCreate(.cfRange, &range),
              let value = parameterized(element, kAXBoundsForRangeParameterizedAttribute, parameter),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        // A rect at the screen's corner is an app's way of saying it does not know (Notes, for the end of the text).
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 1, rect.height < 400, rect.origin != .zero else { return nil }
        return rect
    }

    private static func lineRange(in element: AXUIElement, containing location: Int) -> CFRange? {
        guard let line = parameterized(element, kAXLineForIndexParameterizedAttribute, NSNumber(value: location)) as? NSNumber,
              let value = parameterized(element, kAXRangeForLineParameterizedAttribute, line as CFNumber),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    // MARK: The cursor

    /// Where the next letter goes. Many apps answer badly for an empty range (x 0, the whole line, the next character), so the
    /// right edge of the character before the cursor comes first: the suggestion then starts exactly where the text ends and
    /// never covers it. Only when the cursor is on a new line (wrapped or after a return) does the empty range decide.
    private static func caretRect(in element: AXUIElement, at location: Int, text: NSString) -> CGRect? {
        let empty = bounds(in: element, location: location, length: 0)
        let previousIsNewline = location > 0 && [0x0A, 0x0D, 0x2028, 0x2029].contains(text.character(at: location - 1))
        if location > 0, !previousIsNewline, let previous = bounds(in: element, location: location - 1, length: 1),
           previous.width > 0, previous.width < 200 {
            // The cursor wrapped to the next line: the empty range is lower down than the character before it.
            if let empty, empty.height > 1, abs(empty.minY - previous.minY) > previous.height / 2, empty.width < 4 {
                return CGRect(x: empty.minX, y: empty.minY, width: 0, height: empty.height)
            }
            return CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height)
        }
        // Notes and other rich text views often have no box for the last character, but do for the line it ends: the cursor
        // at the end of that line is at the line's right edge.
        if location > 0, !previousIsNewline, let line = lineRange(in: element, containing: location - 1) {
            var length = line.length
            while length > 0, line.location + length > location || [0x0A, 0x0D, 0x2028, 0x2029].contains(text.character(at: line.location + length - 1)) {
                length -= 1
            }
            if line.location + length == location, length > 0, let box = bounds(in: element, location: line.location, length: length),
               box.height < 100 {
                return CGRect(x: box.maxX, y: box.minY, width: 0, height: box.height)
            }
        }
        if let empty, empty.height > 1 {
            return CGRect(x: empty.minX, y: empty.minY, width: 0, height: min(empty.height, 200))
        }
        // On a new line: the next character, when there is one, starts where the cursor is.
        if location < text.length, ![0x0A, 0x0D, 0x2028, 0x2029].contains(text.character(at: location)),
           let next = bounds(in: element, location: location, length: 1), next.width < 200 {
            return CGRect(x: next.minX, y: next.minY, width: 0, height: next.height)
        }
        return nil
    }

    private static func markerBounds(in element: AXUIElement, range: CFTypeRef) -> CGRect? {
        guard let value = parameterized(element, "AXBoundsForTextMarkerRange", range), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 1 else { return nil }
        return rect
    }

    /// The cursor from the selected text-marker range (web content): the right edge of the character before it first, like
    /// `caretRect`.
    private static func markerCaret(in element: AXUIElement) -> CGRect? {
        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &selection) == .success, let selection,
              let end = AXTextMarkerRangeCopyEndMarker(selection) else { return nil }
        if let previous = parameterized(element, "AXPreviousTextMarkerForTextMarker", end),
           let range = AXTextMarkerRangeCreate(nil, previous, end), let box = markerBounds(in: element, range: range), box.width > 0,
           (string(element, range).map { !$0.contains("\n") } ?? true) {
            return CGRect(x: box.maxX, y: box.minY, width: 0, height: box.height)
        }
        if let caret = markerBounds(in: element, range: selection) {
            return CGRect(x: caret.minX, y: caret.minY, width: 0, height: caret.height)
        }
        if let next = parameterized(element, "AXNextTextMarkerForTextMarker", end),
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

    /// Presses one key (an accept key held while a suggestion was on its way, passed on after all).
    static func press(keyCode: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: isDown) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.post(tap: .cgSessionEventTap)
        }
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
