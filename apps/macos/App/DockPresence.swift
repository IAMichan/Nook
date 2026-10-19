import AppKit

/// While one of Nook's own windows (the workspace or Settings) is open, Nook behaves as a regular app: an icon in the Dock,
/// a place in ⌘Tab and a menu bar. Clicking next to the window then sends it behind the other apps instead of leaving it
/// without a way back. When the last of these windows closes, Nook is a menu bar app again.
@MainActor
final class DockPresence: NSObject {
    static let shared = DockPresence()

    /// The windows that keep Nook in the Dock while they are open (minimized counts as open).
    private var open: [ObjectIdentifier: NSWindow] = [:]
    private var observed: Set<ObjectIdentifier> = []

    /// Call before showing `window`: Nook joins the Dock and leaves it again once every tracked window is closed.
    func track(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        if !observed.contains(id) {
            observed.insert(id)
            // The windows are kept (`isReleasedWhenClosed = false`) and shown again later, so the observer stays.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.closed(id) }
            }
        }
        open[id] = window
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.mainMenu = makeMainMenu()
        NSApp.setActivationPolicy(.regular)
    }

    private func closed(_ id: ObjectIdentifier) {
        open[id] = nil
        guard open.isEmpty, NSApp.activationPolicy() != .accessory else { return }
        NSApp.setActivationPolicy(.accessory)
        // Only the windows need a menu bar; the notch handles its own keys.
        NSApp.mainMenu = nil
    }

    /// Clicking the Dock icon: the open window comes forward (also out of the Dock when minimized); with none open, the
    /// workspace opens. The notch panel always counts as a visible window, so AppKit's own check cannot tell.
    func reopen() {
        if let window = open.values.first(where: { $0.isVisible && !$0.isMiniaturized }) ?? open.values.first {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            AppModel.shared.openWindow()
        }
    }

    // MARK: Menu bar

    /// The usual app, Edit and Window menus, so the standard shortcuts (⌘Q, ⌘H, ⌘C/⌘V, ⌘M, ⌘W) work in the windows.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "Nook")
        let settings = NSMenuItem(title: tr("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(withTitle: tr("appmenu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: tr("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        submenu(app, in: main)

        let edit = NSMenu(title: tr("appmenu.edit"))
        edit.addItem(withTitle: tr("appmenu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: tr("appmenu.redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: tr("appmenu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("appmenu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("appmenu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("appmenu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        submenu(edit, in: main)

        let window = NSMenu(title: tr("appmenu.window"))
        window.addItem(withTitle: tr("appmenu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: tr("appmenu.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        submenu(window, in: main)
        NSApp.windowsMenu = window

        return main
    }

    private func submenu(_ menu: NSMenu, in main: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }

    @objc private func openSettings() {
        AppModel.shared.openSettings()
    }
}
