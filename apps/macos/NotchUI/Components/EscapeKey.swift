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
