import AppKit

/// Een randloos paneel dat over de notch hangt, nooit de focus steelt
/// en op elk Space en boven volledig-scherm-apps blijft staan.
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
        // Standaard laat het paneel alles erdoorheen; de controller zet dit uit
        // zodra de muis boven de notch-vorm hangt.
        ignoresMouseEvents = true
    }

    // Nodig om in tekstvelden te kunnen typen.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Laat het paneel ook over de menubalk en notch heen staan.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
