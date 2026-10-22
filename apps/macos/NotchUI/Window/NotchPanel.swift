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
        level = Self.notchLevel
        collectionBehavior = Self.notchBehavior
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

    /// Above the menu bar and the notch.
    static let notchLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
    static let notchBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

    // Required to allow typing in text fields.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // The notch has no menu bar of its own (see `DockPresence`), so the standard editing shortcuts go to the selected
    // text or field from here: ⌘C copies what you selected in a chat card, ⌘V pastes into its reply field.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard event.type == .keyDown, let action = Self.editAction(for: event) else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }

    private static func editAction(for event: NSEvent) -> Selector? {
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == [.command, .shift] { return key == "z" ? Selector(("redo:")) : nil }
        guard flags == .command else { return nil }
        switch key {
        case "c": return #selector(NSText.copy(_:))
        case "x": return #selector(NSText.cut(_:))
        case "v": return #selector(NSText.paste(_:))
        case "a": return #selector(NSText.selectAll(_:))
        case "z": return Selector(("undo:"))
        default: return nil
        }
    }

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

/// Runs a modal window in front of the notch. A modal session puts its window on the modal level, which is below the
/// notch, so a picker or alert started from the notch would open unseen behind it while its modal loop blocks every
/// click. The notch drops to the normal level while it is open and goes back afterwards.
@MainActor
enum AboveNotch {
    static func run<Result>(_ modal: () -> Result) -> Result {
        let notches = NSApp.windows.compactMap { $0 as? NotchPanel }
        let levels = notches.map(\.level)
        notches.forEach { $0.level = .normal }
        NSApp.activate(ignoringOtherApps: true)
        defer { zip(notches, levels).forEach { $0.level = $1 } }
        return modal()
    }
}

extension NSSavePanel {
    /// `runModal()` in front of the notch (see `AboveNotch`); also covers `NSOpenPanel`.
    @MainActor
    func runAboveNotch() -> NSApplication.ModalResponse {
        AboveNotch.run { runModal() }
    }
}

extension NSAlert {
    /// `runModal()` in front of the notch (see `AboveNotch`).
    @MainActor
    func runAboveNotch() -> NSApplication.ModalResponse {
        AboveNotch.run { runModal() }
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
    /// The notch sits lower on purpose right now: the picker is up.
    var lowersNotch: Bool { !saved.isEmpty }

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

    /// The window level of the emoji picker when it is on screen. Owner, layer, bounds and alpha are readable without
    /// screen recording. The input method keeps small or transparent helper windows on screen when no picker is open;
    /// counting those dropped the notch below the menu bar for as long as they stayed, so the notch seemed to vanish.
    private static func pickerLayer() -> Int? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = window[kCGWindowLayer as String] as? Int else { continue }
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleID || owner == "CharacterPalette"
            else { continue }
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0, let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= minPickerSide, rect.height >= minPickerSide else { continue }
            return layer
        }
        return nil
    }

    /// Smaller than the picker can be: anything below this is a helper window, not Emoji & Symbols.
    private static let minPickerSide: CGFloat = 120
}
