import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel.shared
    private var statusItem: NSStatusItem?
    private var hoverItem: NSMenuItem?
    private var demoItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.start()
        installStatusItem()
    }

    // MARK: Menubalk

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Nook")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        menu.delegate = self

        add(to: menu, title: "Praat met Nook   ⌥ spatie", action: #selector(talk))
        add(to: menu, title: "Kijk mee met mijn scherm   ⌥⌘N", action: #selector(lookAtScreen))
        add(to: menu, title: "Weekoverzicht", action: #selector(weekRecap))
        menu.addItem(.separator())

        let demo = NSMenuItem(title: "Voorbeeldscènes", action: nil, keyEquivalent: "")
        let demoMenu = NSMenu()
        for scene in DemoScene.allCases {
            let entry = NSMenuItem(title: scene.title, action: #selector(showScene(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = scene.rawValue
            demoMenu.addItem(entry)
        }
        demo.submenu = demoMenu
        menu.addItem(demo)

        let demoData = add(to: menu, title: "Voorbeelddata tonen", action: #selector(toggleDemo(_:)))
        demoItem = demoData

        menu.addItem(.separator())

        let hover = add(to: menu, title: "Openen bij hover", action: #selector(toggleHover(_:)))
        hoverItem = hover

        add(to: menu, title: "Instellingen…", action: #selector(openSettings), key: ",")
        menu.addItem(.separator())
        add(to: menu, title: "Nook afsluiten", action: #selector(quit), key: "q")

        item.menu = menu
        statusItem = item
    }

    @discardableResult
    private func add(to menu: NSMenu, title: String, action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        menu.addItem(entry)
        return entry
    }

    func menuWillOpen(_ menu: NSMenu) {
        hoverItem?.state = model.viewModel.openOnHover ? .on : .off
        demoItem?.state = model.demoMode ? .on : .off
    }

    @objc private func talk() { model.toggleVoice() }
    @objc private func lookAtScreen() { model.lookAtScreen(manual: true) }
    @objc private func weekRecap() { model.showWeekRecap() }
    @objc private func openSettings() { model.openSettings() }
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
