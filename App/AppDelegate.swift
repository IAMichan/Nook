import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel.shared
    private var statusItem: NSStatusItem?
    private var talkItem: NSMenuItem?
    private var screenItem: NSMenuItem?
    private var weekRecapItem: NSMenuItem?
    private var workspaceItem: NSMenuItem?
    private var demoScenesItem: NSMenuItem?
    private var demoSubmenu: NSMenu?
    private var hoverItem: NSMenuItem?
    private var demoItem: NSMenuItem?
    private var settingsItem: NSMenuItem?
    private var quitItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.start()
        installStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Lopende agents uit de werkruimte netjes stoppen en hun tijdlijn bewaren.
        model.workspace.shutdown()
    }

    // MARK: Menubalk

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.menuBarIcon()
        }

        let menu = NSMenu()
        menu.delegate = self

        talkItem = add(to: menu, title: tr("menu.talk"), action: #selector(talk))
        screenItem = add(to: menu, title: tr("menu.screen"), action: #selector(lookAtScreen))
        weekRecapItem = add(to: menu, title: tr("menu.weekRecap"), action: #selector(weekRecap))
        workspaceItem = add(to: menu, title: tr("menu.workspace"), action: #selector(openWorkspace), key: "w")
        workspaceItem?.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())

        let demo = NSMenuItem(title: tr("menu.demoScenes"), action: nil, keyEquivalent: "")
        let demoMenu = NSMenu()
        for scene in DemoScene.allCases {
            let entry = NSMenuItem(title: scene.title, action: #selector(showScene(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = scene.rawValue
            demoMenu.addItem(entry)
        }
        demo.submenu = demoMenu
        menu.addItem(demo)
        demoScenesItem = demo
        demoSubmenu = demoMenu

        let demoData = add(to: menu, title: tr("menu.demoData"), action: #selector(toggleDemo(_:)))
        demoItem = demoData

        menu.addItem(.separator())

        let hover = add(to: menu, title: tr("menu.hover"), action: #selector(toggleHover(_:)))
        hoverItem = hover

        settingsItem = add(to: menu, title: tr("menu.settings"), action: #selector(openSettings), key: ",")
        menu.addItem(.separator())
        quitItem = add(to: menu, title: tr("menu.quit"), action: #selector(quit), key: "q")

        item.menu = menu
        statusItem = item
    }

    /// Nook itself, mirroring the notch design: a circular glow with two eyes. Custom-drawn for crispness,
    /// configured as a template image to adapt to light and dark menu bars.
    private static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()

            // Cut out the eyes using the even-odd winding rule, letting the menu bar show through.
            let nook = NSBezierPath(ovalIn: NSRect(x: 1.5, y: 1.5, width: 15, height: 15))
            for x in [5.9, 10.1] {
                nook.append(NSBezierPath(
                    roundedRect: NSRect(x: x, y: 6.5, width: 2, height: 3.6),
                    xRadius: 1, yRadius: 1
                ))
            }
            nook.windingRule = .evenOdd
            nook.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = tr("menu.accessibility")
        return image
    }

    @discardableResult
    private func add(to menu: NSMenu, title: String, action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        menu.addItem(entry)
        return entry
    }

    func menuWillOpen(_ menu: NSMenu) {
        talkItem?.title = tr("menu.talk")
        screenItem?.title = tr("menu.screen")
        weekRecapItem?.title = tr("menu.weekRecap")
        workspaceItem?.title = tr("menu.workspace")
        demoScenesItem?.title = tr("menu.demoScenes")
        if let demoSubmenu = demoSubmenu {
            for item in demoSubmenu.items {
                if let raw = item.representedObject as? String, let scene = DemoScene(rawValue: raw) {
                    item.title = scene.title
                }
            }
        }
        demoItem?.title = tr("menu.demoData")
        hoverItem?.title = tr("menu.hover")
        settingsItem?.title = tr("menu.settings")
        quitItem?.title = tr("menu.quit")
        hoverItem?.state = model.viewModel.openOnHover ? .on : .off
        demoItem?.state = model.demoMode ? .on : .off
    }

    @objc private func talk() { model.toggleVoice() }
    @objc private func lookAtScreen() { model.lookAtScreen(manual: true) }
    @objc private func weekRecap() { model.showWeekRecap() }
    @objc private func openSettings() { model.openSettings() }
    @objc private func openWorkspace() { model.openWorkspace() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showScene(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let scene = DemoScene(rawValue: raw) else { return }
        model.viewModel.showScene(scene)
    }

    @objc private func toggleHover(_ sender: NSMenuItem) {
        model.viewModel.openOnHover.toggle()
        sender.state = model.viewModel.openOnHover ? .on : .off
    }

    @objc private func toggleDemo(_ sender: NSMenuItem) {
        model.demoMode.toggle()
        sender.state = model.demoMode ? .on : .off
    }
}
