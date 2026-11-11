import AppKit

extension Notification.Name {
    /// Asks the composer on screen to take the keyboard (`composerFocusOnAppear` listens), when nothing else had it.
    static let nookComposerFocusRequest = Notification.Name("nook.composerFocusRequest")
}

/// Gives the keyboard back when a session's side panel closes, as t3code does: to what had it before the panel took it
/// (the composer, a field, a list) when that is still in the window, else to the composer. Only when closing the panel
/// dropped the keyboard: focus that never went into the panel stays where it is.
@MainActor
final class SideFocusReturn {
    private weak var origin: NSResponder?
    private weak var window: NSWindow?

    /// The panel opens: remember what has the keyboard now.
    func panelOpened() {
        guard let window = NSApp.keyWindow else {
            origin = nil
            self.window = nil
            return
        }
        self.window = window
        origin = Self.owner(of: window.firstResponder)
    }

    /// The panel closed: once its views are gone, the keyboard goes back if it was dropped.
    func panelClosed() {
        let origin = self.origin
        let window = self.window
        self.origin = nil
        self.window = nil
        // After SwiftUI removed the panel's views, so the first responder says whether the keyboard was dropped.
        DispatchQueue.main.async {
            guard let window = window ?? NSApp.keyWindow, Self.dropped(window) else { return }
            if let view = origin as? NSView, view.window === window, !view.isHiddenOrHasHiddenAncestor,
               window.makeFirstResponder(view) {
                return
            }
            NotificationCenter.default.post(name: .nookComposerFocusRequest, object: window)
        }
    }

    /// Nothing in the window has the keyboard: it fell back to the window itself, or to a view that left it.
    static func dropped(_ window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return true }
        if responder === window { return true }
        if let view = responder as? NSView { return view.window !== window }
        return false
    }

    /// The view that owns the keyboard: a text field's own view rather than the shared field editor that edits it.
    static func owner(of responder: NSResponder?) -> NSResponder? {
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder {
            return field
        }
        return responder is NSWindow ? nil : responder
    }
}
