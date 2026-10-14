import AppKit

/// A borderless panel overlaying the notch that never steals focus
/// and stays visible across all Spaces and above full-screen apps.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect = .zero) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        // Panel ignores mouse events by default; controller disables click-through
        // whenever cursor hovers over the notch shape.
        ignoresMouseEvents = true
    }

    // Required to allow typing in text fields.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Ensures the panel renders above the menu bar and notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
