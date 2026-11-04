import SwiftUI
import AppKit

/// A tab of the panel (the Nook chat, Agents, Chats or Music) in a window of its own, beside the main window or on
/// another screen: what split view shows beside the main tab, torn off. One window per tab; opening it again brings it
/// forward. It stays open until you close it, also across a restart of Nook, as the main window does.
@MainActor
final class TabWindowController {
    static let shared = TabWindowController()

    private struct Entry {
        let window: NSWindow
        let presence: WindowPresence
        let frameMemory: WindowFrameMemory
    }

    private var entries: [PanelTab: Entry] = [:]
    /// Quitting does not close the windows: they are open again when Nook starts.
    private var quitting = false

    /// The tabs that had a window of their own when Nook last quit (`PanelTab.rawValue`).
    private static let openKey = "nook.panel.tabWindows"

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.quitting = true }
        }
    }

    /// The tab as it is kept: the Nook chat is one tab, whichever of its names asked for it.
    static func key(_ tab: PanelTab) -> PanelTab {
        PanelSplitChoice.same(tab, .chat) ? .chat : tab
    }

    /// Whether `tab` has a window of its own now, in front or not.
    func isOpen(_ tab: PanelTab) -> Bool {
        entries[Self.key(tab)].map { $0.window.isVisible || $0.window.isMiniaturized } ?? false
    }

    /// Opens `tab` in a window of its own, or brings that window forward. Split view stops showing it beside the main
    /// tab: it is in its own window now.
    func open(_ tab: PanelTab, app: AppModel, activate: Bool = true) {
        let tab = Self.key(tab)
        guard PanelSplitChoice.choices.contains(tab) else { return }
        let defaults = UserDefaults.standard
        if let stored = PanelTab(rawValue: defaults.string(forKey: PanelSplitChoice.key) ?? ""),
           PanelSplitChoice.same(stored, tab) {
            defaults.set("", forKey: PanelSplitChoice.key)
        }
        // A tab you look at in the open notch: the notch closes, as for the main window, so the window gets the clicks.
        if case .panel = app.viewModel.state { app.viewModel.show(.idle) }
        let entry = entries[tab] ?? make(tab, app: app)
        entries[tab] = entry
        entry.presence.shown = true
        DockPresence.shared.track(entry.window)
        remember(tab, open: true)
        guard activate else {
            entry.window.orderFront(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        entry.window.makeKeyAndOrderFront(nil)
    }

    /// Closes the window of `tab` and shows the tab beside the main one again (split view).
    func dock(_ tab: PanelTab, app: AppModel) {
        let tab = Self.key(tab)
        entries[tab]?.window.close()
        UserDefaults.standard.set(tab.rawValue, forKey: PanelSplitChoice.key)
        app.openWindow()
    }

    /// The windows that were open when Nook last quit, back where they were, without taking the keyboard.
    func restore(app: AppModel) {
        let stored = UserDefaults.standard.stringArray(forKey: Self.openKey) ?? []
        for tab in stored.compactMap(PanelTab.init(rawValue:)) {
            open(tab, app: app, activate: false)
        }
    }

    private func make(_ tab: PanelTab, app: AppModel) -> Entry {
        let presence = WindowPresence()
        let minSize = CGSize(width: 420, height: 420)
        let root = WindowContent(presence: presence, background: NookTheme.notch, minSize: minSize) {
            TabWindowView(tab: tab)
        }
            .nookAttention()
            .environmentObject(app)
            .environmentObject(app.workspace)
            .environmentObject(app.workspace.settings)
        let host = WorkspaceHostingView(rootView: root)
        // The window sets its own minSize, as the main window does: the hosting view driving it loops on a pane's change.
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = "Nook · " + tab.title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .black
        window.minSize = NSSize(width: minSize.width, height: minSize.height)
        window.isReleasedWhenClosed = false
        // Each tab has a window of its own and its own place on screen.
        window.tabbingMode = .disallowed
        let frameMemory = WindowFrameMemory(window: window, name: "NookTab-" + tab.rawValue)
        if !frameMemory.restore() { window.center() }
        presence.follow(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.quitting else { return }
                self.remember(tab, open: false)
                presence.shown = false
            }
        }
        return Entry(window: window, presence: presence, frameMemory: frameMemory)
    }

    private func remember(_ tab: PanelTab, open: Bool) {
        var stored = UserDefaults.standard.stringArray(forKey: Self.openKey) ?? []
        stored.removeAll { $0 == tab.rawValue }
        if open { stored.append(tab.rawValue) }
        UserDefaults.standard.set(stored, forKey: Self.openKey)
    }
}

/// The content of a tab's own window: the tab's name with a button that puts it back beside the main tab, over the tab
/// itself as split view shows it.
private struct TabWindowView: View {
    let tab: PanelTab
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var viewModel = AppModel.shared.viewModel
    @StateObject private var mediaStage = ChatMediaStage()

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.sm) {
                SidePanelTitle(symbol: PanelSplitChoice.symbol(tab), title: tab.title)
                Spacer(minLength: 0)
                ToolbarIconButton("rectangle.split.2x1", tr("split.dock")) {
                    TabWindowController.shared.dock(tab, app: app)
                }
            }
            // Clear of the traffic lights, on the title bar's row.
            .padding(.leading, PanelSidebarMetrics.trafficLights - PanelSidebarMetrics.inset)
            .frame(height: PanelSidebarMetrics.titleBand)
            PanelTabContent(viewModel: viewModel, tab: tab, inWindow: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, NookTheme.Spacing.xl)
        .padding(.bottom, NookTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(.container, edges: .top)
        .background(alignment: .top) {
            // The row with the traffic lights moves the window where no button lies on it.
            WindowTitleBarArea()
                .frame(height: PanelSidebarMetrics.titleBand)
                .frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: .top)
        }
        .background(NookTheme.notch.ignoresSafeArea())
        .chatMediaStage(mediaStage)
        .nookToastHost()
        .tint(NookTheme.iris)
        .id(app.settings.accentHex)
    }
}
