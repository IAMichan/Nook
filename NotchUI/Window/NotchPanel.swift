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
        // The notch is always dark: system controls inside it (menus, pickers, text fields) follow.
        appearance = NSAppearance(named: .darkAqua)
    }

    // Required to allow typing in text fields.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Ensures the panel renders above the menu bar and notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

extension NSOpenPanel {
    /// Runs the open panel in front of the notch. `runModal()` puts the panel on the modal level itself, which is below the
    /// notch, so the notch drops to the normal level while the picker is open and goes back afterwards.
    func runAboveNotch() -> NSApplication.ModalResponse {
        let notches = NSApp.windows.compactMap { $0 as? NotchPanel }
        let levels = notches.map(\.level)
        notches.forEach { $0.level = .normal }
        NSApp.activate(ignoringOtherApps: true)
        defer { zip(notches, levels).forEach { $0.level = $1 } }
        return runModal()
    }
}
