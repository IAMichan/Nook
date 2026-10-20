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

    // Typing in the notch: the emoji picker may open for its field, so watch for it (see `CharacterPaletteWatch`).
    override func becomeKey() {
        super.becomeKey()
        CharacterPaletteWatch.shared.start()
    }

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

/// The emoji picker (Emoji & Symbols) is a window of the system's own, on a level below the notch, so it opened behind
/// the card you were typing in. While the notch has the keyboard, this looks for the picker on screen and, while it is
/// up, drops the notch just below the picker's level; once it is gone, the notch goes back.
@MainActor
final class CharacterPaletteWatch {
    static let shared = CharacterPaletteWatch()

    private static let bundleID = "com.apple.CharacterPaletteIM"
    private var timer: Timer?
    /// The notch's own levels while they are lowered for the picker.
    private var saved: [(NotchPanel, NSWindow.Level)] = []

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated { CharacterPaletteWatch.shared.check() }
        }
    }

    private func check() {
        let notches = NSApp.windows.compactMap { $0 as? NotchPanel }
        if let layer = Self.pickerLayer() {
            if saved.isEmpty { saved = notches.map { ($0, $0.level) } }
            let below = NSWindow.Level(rawValue: max(NSWindow.Level.normal.rawValue, layer - 1))
            for (panel, level) in saved where panel.level != min(level, below) { panel.level = min(level, below) }
            return
        }
        saved.forEach { $0.0.level = $0.1 }
        saved = []
        // Nothing to watch once no notch has the keyboard.
        if !notches.contains(where: \.isKeyWindow) {
            timer?.invalidate()
            timer = nil
        }
    }

    /// The window level of the emoji picker when it is on screen. Owner and layer are readable without screen recording.
    private static func pickerLayer() -> Int? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = window[kCGWindowLayer as String] as? Int else { continue }
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleID || owner == "CharacterPalette" {
                return layer
            }
        }
        return nil
    }
}
