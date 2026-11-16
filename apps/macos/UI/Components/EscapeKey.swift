import AppKit
import Carbon
import SwiftUI

extension View {
    /// Escape in the window this view is in runs `action`, also when nothing there has the keyboard (a list row was
    /// clicked last, or the non-activating notch panel took the keys without a focused field): SwiftUI's
    /// `onExitCommand` only hears Escape inside a focused view. While a text field is being typed in, Escape stays the
    /// field's own (closing its menu, clearing it); a field that wants it to go further calls the same action itself.
    func onEscapeKey(enabled: Bool = true, perform action: @escaping () -> Void) -> some View {
        background(EscapeKeyReader(enabled: enabled, action: action))
    }
}

/// Watches the keys of the window it is in while it is in one.
private struct EscapeKeyReader: NSViewRepresentable {
    let enabled: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> EscapeKeyView {
        let view = EscapeKeyView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: EscapeKeyView, context: Context) {
        nsView.enabled = enabled
        nsView.action = action
    }

    final class EscapeKeyView: NSView {
        var enabled = true
        var action: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.claims(event) else { return event }
                self.action?()
                return nil
            }
        }

        private func claims(_ event: NSEvent) -> Bool {
            guard enabled, let window, event.window === window, event.keyCode == UInt16(kVK_Escape),
                  event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty else { return false }
            return !(window.firstResponder is NSText)
        }
    }
}

extension View {
    /// Keys pressed in the window this view is in, before the focused field or SwiftUI sees them: a palette steers its
    /// list (Return, ↑/↓, Tab) while its text field keeps the keyboard, which `onKeyPress` and `onSubmit` do not hear
    /// reliably in the notch. `handler` returns true when it used the key. Keys an input method is composing stay the
    /// field's.
    func onWindowKeyDown(enabled: Bool = true, perform handler: @escaping (NSEvent) -> Bool) -> some View {
        background(KeyDownReader(enabled: enabled, handler: handler))
    }
}

private struct KeyDownReader: NSViewRepresentable {
    let enabled: Bool
    let handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyDownView {
        let view = KeyDownView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: KeyDownView, context: Context) {
        nsView.enabled = enabled
        nsView.handler = handler
    }

    final class KeyDownView: NSView {
        var enabled = true
        var handler: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.enabled, let window = self.window, event.window === window else { return event }
                if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
                return self.handler?(event) == true ? nil : event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
