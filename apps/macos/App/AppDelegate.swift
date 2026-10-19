import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel.shared
    private var statusItem: NSStatusItem?
    private var countWatch: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.start()
        installStatusItem()
    }

    /// Clicking Nook's Dock icon (there while one of its windows is open) brings that window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DockPresence.shared.reopen()
        return false
    }

    /// `nook://prompt?text=…`: fills a draft in a new session, never sends it (see PromptLink).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let link = PromptLink.parse(url: url) else { continue }
            PromptLinkInbox.shared.pending = link
            model.viewModel.selectedAgentID = "new"
            model.viewModel.show(.panel(.agents))
            return
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Lopende agents uit de werkruimte netjes stoppen en hun tijdlijn bewaren.
        model.workspace.shutdown()
        AutocompleteController.shared.flush()
        Self.skipStaticDestructorsAtExit()
    }

    /// After this notification AppKit calls `exit()`, which runs the C++ static destructors of llama.cpp (Metal), MLX and
    /// FluidAudio. With a model still loaded, or loading on another thread, those abort: Nook then crashes on quit, for
    /// instance when macOS asks to "Quit & Reopen" right after a permission was granted (that is when autocomplete loads its
    /// model). Handlers registered with `atexit` run in reverse order, so this one, registered last, runs before every
    /// destructor and ends the process once all of Nook's own saving (here and in other `willTerminate` observers) is done.
    nonisolated private static func skipStaticDestructorsAtExit() {
        atexit {
            fflush(nil)
            _exit(0)
        }
    }

    // MARK: Menubalk

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.menuBarIcon()
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        watchCount()
    }

    /// The words autocomplete typed today, next to the icon, when turned on in Settings › Autocomplete. Follows every taken
    /// word, and starts again at zero when the day changes.
    private func watchCount() {
        let store = AutocompleteStore.shared
        let dayChanged = NotificationCenter.default.publisher(for: .NSCalendarDayChanged).map { _ in () }.prepend(())
        countWatch = store.$stats.combineLatest(store.$prefs, dayChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] stats, prefs, _ in
                MainActor.assumeIsolated { self?.showCount(prefs.enabled && prefs.menuBarCount ? stats.day().words : nil) }
            }
    }

    private func showCount(_ words: Int?) {
        guard let item = statusItem, let button = item.button else { return }
        if let words {
            item.length = NSStatusItem.variableLength
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
            button.title = words.formatted()
            button.imagePosition = .imageLeading
            button.toolTip = tr("autocomplete.menuBarCount.tooltip", words)
        } else {
            item.length = NSStatusItem.squareLength
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = nil
        }
    }

    /// The menu shows what is going on right now (next meeting, agents, music), so it is rebuilt every time it opens.
    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        // Status: only what needs attention.
        var status = false
        if let event = model.upcoming.first(where: { $0.end > Date() }) {
            let when = event.start <= Date() ? tr("menu.now") : Self.timeFormatter.string(from: event.start)
            addInfo(to: menu, title: tr("menu.nextEvent", event.title, when), action: #selector(openChat), icon: "calendar.badge.clock")
            status = true
        }
        let active = model.activeAgents
        if !active.isEmpty {
            let waiting = active.filter { $0.status == .waiting || $0.approvalID != nil }.count
            let title = waiting > 0 ? tr("menu.agentsWaiting", active.count, waiting) : tr("menu.agentsRunning", active.count)
            addInfo(to: menu, title: title, action: #selector(openAgents), icon: "sparkles")
            status = true
        }
        if let track = model.nowPlaying.current {
            let line = track.artist.isEmpty ? track.title : "\(track.title) – \(track.artist)"
            let header = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            header.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
            header.isEnabled = false
            menu.addItem(header)
            add(to: menu, title: track.isPlaying ? tr("menu.pause") : tr("menu.play"), action: #selector(playPause))
            add(to: menu, title: tr("menu.nextTrack"), action: #selector(nextTrack))
            status = true
        }
        if status { menu.addItem(.separator()) }

        // Actions.
        add(to: menu, title: tr("menu.openPanel"), action: #selector(openChat), icon: "bubble.left")
        add(to: menu, title: tr("menu.talk"), action: #selector(talk), icon: "mic")
        add(to: menu, title: tr("menu.screen"), action: #selector(lookAtScreen), icon: "eye")
        add(to: menu, title: NoteTaker.shared.isRecording ? tr("notes.menu.stop") : tr("notes.menu.start"), action: #selector(recordCall), icon: "record.circle")
        add(to: menu, title: tr("menu.weekRecap"), action: #selector(weekRecap), icon: "calendar")
        let workspace = add(to: menu, title: tr("menu.window"), action: #selector(openWorkspace), key: "w", icon: "macwindow")
        workspace.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())

        // Demo scenes show made-up confirmations: only in development builds. Sample data stays in Settings › General.
        #if DEBUG
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
        let demoData = add(to: menu, title: tr("menu.demoData"), action: #selector(toggleDemo(_:)))
        demoData.state = model.demoMode ? .on : .off
        menu.addItem(.separator())
        #endif

        if AutocompleteStore.shared.prefs.enabled {
            let words = AutocompleteStore.shared.stats.day().words
            let title = AutocompleteController.shared.isPausedEverywhere ? tr("autocomplete.menu.resume") : tr("autocomplete.menu.pause", words)
            add(to: menu, title: title, action: #selector(toggleAutocomplete), icon: "text.cursor")
        }
        let hover = add(to: menu, title: tr("menu.hover"), action: #selector(toggleHover(_:)))
        hover.state = model.viewModel.openOnHover ? .on : .off
        add(to: menu, title: tr("menu.settings"), action: #selector(openSettings), key: ",")
        menu.addItem(.separator())
        add(to: menu, title: tr("menu.quit"), action: #selector(quit), key: "q")
    }

    @objc private func toggleAutocomplete() {
        AutocompleteController.shared.togglePauseEverywhere()
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

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
    private func add(to menu: NSMenu, title: String, action: Selector, key: String = "", icon: String? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        if let icon { entry.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
        menu.addItem(entry)
        return entry
    }

    /// A status line that opens the matching part of the panel when clicked.
    private func addInfo(to menu: NSMenu, title: String, action: Selector, icon: String) {
        add(to: menu, title: title, action: action, icon: icon)
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu)
    }

    @objc private func openChat() { model.viewModel.focusChat = true; model.viewModel.show(.panel(.chat), inNotch: true) }
    @objc private func openAgents() { model.viewModel.show(.panel(.agents), inNotch: true) }
    @objc private func playPause() { model.nowPlaying.control(.playPause) }
    @objc private func nextTrack() { model.nowPlaying.control(.next) }
    @objc private func talk() { model.toggleVoice() }
    @objc private func lookAtScreen() { model.lookAtScreen(manual: true) }
    @objc private func recordCall() { NoteTaker.shared.toggle() }
    @objc private func weekRecap() { model.showWeekRecap() }
    @objc private func openSettings() { model.openSettings() }
    @objc private func openWorkspace() { model.openWindow() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showScene(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let scene = DemoScene(rawValue: raw) else { return }
        model.viewModel.showScene(scene)
    }

    @objc private func toggleHover(_ sender: NSMenuItem) {
        model.viewModel.openOnHover.toggle()
    }

    @objc private func toggleDemo(_ sender: NSMenuItem) {
        model.demoMode.toggle()
    }
}
