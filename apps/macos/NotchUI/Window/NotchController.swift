import AppKit
import SwiftUI
import Combine

/// Manages the notch panel: positioning, click-through outside shape, and dismissal on external clicks.
@MainActor
final class NotchController {
    /// The panel has a fixed bounding size (accommodating the largest state, including a notch you dragged larger); SwiftUI
    /// renders the notch shape within it, and outside the shape clicks pass through.
    static let panelSize = CGSize(width: 2000, height: 1300)

    let viewModel = NotchViewModel()
    private var panel: NotchPanel?
    private var geometry = NotchGeometry.placeholder
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var previousApp: NSRunningApplication?

    private var dragStart: (mouse: NSPoint, centerX: CGFloat, top: CGFloat)?

    /// Notch on every screen: the other screens show an idle copy. When idle, the real Nook moves
    /// to the screen with the mouse, so you can open it there.
    private var mirrors: [String: (panel: NotchPanel, viewModel: NotchViewModel)] = [:]
    private weak var app: AppModel?

    private var settings: AppSettings { AppSettings.shared }

    /// Left out of screen sharing, screenshots and recordings, or not (`applyQuiet`).
    private var captureSharing: NSWindow.SharingType = .readOnly
    /// While you share your screen or sit in a meeting and chose to hide Nook: the notch is gone while it rests, and
    /// shows only for what you open yourself (a shortcut, the menu bar).
    private var hidesWhileResting = false

    private var isFloating: Bool { settings.placement == "floating" }
    private var showsOnAllScreens: Bool { !isFloating && settings.notchOnAllScreens }

    private func makeGeometry() -> NotchGeometry {
        NotchGeometry.make(
            for: NotchGeometry.preferredScreen(choice: showsOnAllScreens ? "mouse" : settings.screenChoice),
            floating: isFloating
        )
    }

    /// The screen corresponding to current geometry (for visible area below menu bar).
    private var visibleFrame: NSRect {
        NSScreen.screens.first { $0.frame == geometry.screenFrame }?.visibleFrame ?? geometry.screenFrame
    }

    /// Center and top edge of the shape in screen coordinates. Anchored to notch, or floating at saved position
    /// clamped within screen bounds.
    private func anchor(size: CGSize) -> (centerX: CGFloat, top: CGFloat) {
        let s = geometry.screenFrame
        guard geometry.isFloating else { return (s.midX, s.maxY) }
        let v = visibleFrame
        let halfW = size.width / 2
        let centerX = min(max(s.midX + settings.floatOffsetX, s.minX + halfW), s.maxX - halfW)
        let top = min(max(v.maxY - settings.floatOffsetY, v.minY + size.height), v.maxY)
        return (centerX, top)
    }

    private func panelFrame() -> NSRect {
        let a = anchor(size: viewModel.size)
        let size = Self.panelSize
        return NSRect(x: a.centerX - size.width / 2, y: a.top - size.height, width: size.width, height: size.height)
    }

    func start(app: AppModel) {
        self.app = app
        geometry = makeGeometry()
        viewModel.geometry = geometry
        viewModel.onDragMoved = { [weak self] in self?.dragMoved() }
        viewModel.onDragEnded = { [weak self] in self?.dragStart = nil }
        viewModel.onAnnounce = { [weak self] info in self?.announce(info) }

        let initialFrame = panelFrame()
        let panel = NotchPanel(contentRect: initialFrame)
        let host = NSHostingView(rootView: NotchRootView(viewModel: viewModel)
            .environmentObject(app)
            .environmentObject(app.workspace)
            .environmentObject(app.workspace.settings))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
        self.panel = panel

        panel.orderFrontRegardless()
        refreshMirrors()
        installMonitors()

        // Size changed? Re-evaluate whether pointer is still hovering over shape.
        viewModel.$size
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.positionPanel()
                self?.pointerMoved(force: true)
            }
            .store(in: &cancellables)

        // The copies on the other screens follow in the same transaction as the real notch (no hop to the next run
        // loop pass), so every screen starts the same animation on the same frame.
        viewModel.$state
            .sink { [weak self] state in self?.syncMirrors(to: state) }
            .store(in: &cancellables)

        // A card with text input immediately requests keyboard focus so typing works without clicking.
        viewModel.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                // Shown first: a hidden notch cannot take the keyboard.
                self?.updateVisibility()
                self?.stateChanged(state)
                if !state.isResting { self?.cancelAnnouncement() }
            }
            .store(in: &cancellables)

        // Screen changed in settings, or idle hide toggled.
        AppSettings.shared.$screenChoice
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.screenChanged() }
            .store(in: &cancellables)
        AppSettings.shared.$placement
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.screenChanged() }
            .store(in: &cancellables)
        AppSettings.shared.$notchOnAllScreens
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.screenChanged() }
            .store(in: &cancellables)
        AppSettings.shared.$hideWhenIdle
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshMirrorContent()
                guard self.viewModel.state.isResting else { return }
                self.viewModel.show(self.viewModel.state)
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screenChanged() }
        }
    }

    // MARK: Keyboard focus

    private func stateChanged(_ state: NotchState) {
        guard let panel else { return }
        let chatFocus = (state == .panel(.nook) || state == .panel(.chat)) && viewModel.focusChat
        viewModel.focusChat = false
        var wantsKeys = chatFocus
        if case .card(let card) = state, card.input { wantsKeys = true }
        if wantsKeys {
            guard !panel.isKeyWindow else { return }
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
            panel.ignoresMouseEvents = false
            panel.makeKey()
        } else if panel.isKeyWindow {
            // Focus is preserved during thinking: subsequent response provides a follow-up text field.
            if case .card(let card) = state, card.id == "thinking" { return }
            // Inside the panel (chat, a session, a terminal), keep typing focus.
            if case .panel = state { return }
            // Finished typing: return focus to previously active application.
            panel.resignKey()
            previousApp?.activate(options: [])
            previousApp = nil
        }
    }

    // MARK: Meetings and screen sharing

    /// How the notch behaves while you share your screen or sit in a meeting (`AppModel+Quiet`, every few seconds).
    func applyQuiet(_ state: QuietState, alwaysExcluded: Bool) {
        let sharing: NSWindow.SharingType = alwaysExcluded || state.excludedFromCapture ? .none : .readOnly
        if sharing != captureSharing {
            captureSharing = sharing
            for panel in allPanels { panel.sharingType = sharing }
        }
        viewModel.silenced = state.silent
        if state.silent, case .track = viewModel.state { dismissTrackAnnouncement() }
        guard state.hidden != hidesWhileResting else { return }
        hidesWhileResting = state.hidden
        viewModel.holdsCards = state.hidden
        if state.hidden {
            // A suggestion or moment showing when the meeting starts goes; what you opened yourself stays.
            switch viewModel.state {
            case .nudge, .moment, .done: viewModel.show(.idle)
            default: break
            }
        } else if viewModel.state.isResting {
            // Over: what waited in line shows now.
            viewModel.show(.idle)
        }
        updateVisibility()
        for mirror in mirrors.values {
            if state.hidden { mirror.panel.orderOut(nil) } else { mirror.panel.orderFrontRegardless() }
        }
    }

    private var allPanels: [NotchPanel] { [panel].compactMap { $0 } + mirrors.values.map(\.panel) }

    /// Hidden for a share or meeting: the notch shows only while something you opened is on it.
    private func updateVisibility() {
        guard let panel else { return }
        let visible = !hidesWhileResting || !viewModel.state.isResting
        guard visible != panel.isVisible else { return }
        if visible {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
            viewModel.pointerChanged(inside: false)
        }
    }

    // MARK: Position

    private func positionPanel() {
        guard let panel else { return }
        let frame = panelFrame()
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
        }
    }

    private func screenChanged() {
        geometry = makeGeometry()
        viewModel.geometry = geometry
        positionPanel()
        refreshMirrors()
    }

    /// Floating: shape tracks mouse while dragging, also onto another connected screen.
    /// Position and screen are saved immediately.
    private func dragMoved() {
        guard geometry.isFloating else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil {
            let a = anchor(size: viewModel.size)
            dragStart = (mouse: mouse, centerX: a.centerX, top: a.top)
        }
        guard let start = dragStart else { return }
        let centerX = start.centerX + mouse.x - start.mouse.x
        let top = start.top + mouse.y - start.mouse.y

        // Dragged across the edge onto another screen: Nook moves along and remembers that screen.
        if let target = NotchGeometry.screenWithMouse(), target.frame != geometry.screenFrame {
            geometry = NotchGeometry.make(for: target, floating: true)
            viewModel.geometry = geometry
            if settings.screenChoice != target.localizedName { settings.screenChoice = target.localizedName }
        }

        settings.floatOffsetX = Double(centerX - geometry.screenFrame.midX)
        // Y axis runs downward: dragging downward increases distance below menu bar.
        settings.floatOffsetY = max(0, Double(visibleFrame.maxY - top))
        positionPanel()
    }

    /// "Follows mouse" or notch on every screen: when idle, Nook moves to whichever screen contains the cursor.
    private func followMouseIfNeeded() {
        guard settings.screenChoice == "mouse" || showsOnAllScreens, viewModel.state.isResting, dragStart == nil,
              let screen = NotchGeometry.screenWithMouse(), screen.frame != geometry.screenFrame else { return }
        // While announcing a track on all screens, avoid hopping the main window between displays mid-animation
        // unless the mouse is actually inside the notch area on the target screen.
        if case .track = viewModel.state, showsOnAllScreens {
            let targetGeometry = NotchGeometry.make(for: screen)
            let targetSize = viewModel.size
            let s = targetGeometry.screenFrame
            let targetRect = NSRect(x: s.midX - targetSize.width / 2, y: s.maxY - targetSize.height, width: targetSize.width, height: targetSize.height)
            guard targetRect.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) else { return }
        }
        screenChanged()
    }

    // MARK: Notch on every screen

    private var announceTask: Task<Void, Never>?

    /// A new track: the notch expands briefly showing current playback; the copies on the other screens follow it in
    /// the same transaction (`syncMirrors`).
    func announce(_ info: NowPlayingInfo) {
        guard viewModel.state.isResting, !viewModel.silenced else { return }
        announceTask?.cancel()
        viewModel.show(.track(title: info.title, artist: info.artist))

        announceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.dismissTrackAnnouncement()
        }
    }

    /// Closes the track announcement on every notch at once.
    func dismissTrackAnnouncement() {
        announceTask?.cancel()
        announceTask = nil
        if case .track = viewModel.state { viewModel.show(.idle) }
    }

    /// Stops a running announcement without closing it (playback stopped, or a panel or card opened over it).
    func cancelAnnouncement() {
        announceTask?.cancel()
        announceTask = nil
    }

    /// Called as the real notch's state is about to change: the copies show the same resting notch (idle, music or a
    /// track announcement). While the real notch is open they rest, without the announcement.
    private func syncMirrors(to state: NotchState) {
        for mirror in mirrors.values {
            let current = mirror.viewModel.state
            if state.isResting {
                if current != state { mirror.viewModel.show(state) }
            } else if case .track = current {
                mirror.viewModel.show(.idle)
            }
        }
    }

    /// Puts an idle notch on every screen except the one the real Nook is on.
    private func refreshMirrors() {
        let wanted = showsOnAllScreens
            ? NSScreen.screens.filter { $0.frame != geometry.screenFrame }
            : []
        let wantedKeys = Set(wanted.map { NSStringFromRect($0.frame) })
        // When Nook follows the mouse to another screen, the copy that stood there moves to the screen Nook left
        // instead of being torn down and built again: no new window has to render its first frame, and what it shows
        // keeps running without a hitch.
        var spare: [(panel: NotchPanel, viewModel: NotchViewModel)] = []
        for (key, mirror) in mirrors where !wantedKeys.contains(key) {
            spare.append(mirror)
            mirrors[key] = nil
        }
        defer {
            for mirror in spare { mirror.panel.orderOut(nil) }
        }
        guard let app else { return }
        let resting: NotchState = viewModel.state.isResting ? viewModel.state : .idle
        for screen in wanted {
            let mirrorGeometry = NotchGeometry.make(for: screen)
            let key = NSStringFromRect(screen.frame)
            if let existing = mirrors[key] ?? spare.popLast() {
                existing.viewModel.geometry = mirrorGeometry
                placeMirror(existing.panel, on: screen.frame)
                if existing.viewModel.state != resting { existing.viewModel.show(resting) }
                mirrors[key] = existing
                continue
            }
            let mirrorModel = NotchViewModel()
            mirrorModel.app = app
            mirrorModel.geometry = mirrorGeometry
            mirrorModel.show(resting)
            let panel = NotchPanel()
            let host = NSHostingView(rootView: NotchRootView(viewModel: mirrorModel)
                .environmentObject(app)
                .environmentObject(app.workspace)
                .environmentObject(app.workspace.settings))
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: Self.panelSize)
            panel.contentView = host
            placeMirror(panel, on: screen.frame)
            // Display only: clicks pass through; the real Nook moves to this screen as soon as the mouse is on it.
            panel.ignoresMouseEvents = true
            panel.sharingType = captureSharing
            if !hidesWhileResting { panel.orderFrontRegardless() }
            mirrors[key] = (panel, mirrorModel)
        }
    }

    private func placeMirror(_ panel: NotchPanel, on screenFrame: CGRect) {
        let size = Self.panelSize
        panel.setFrame(
            NSRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height),
            display: false
        )
    }

    /// Lays the copies out again for the resting notch (after "hide when idle" changed their size).
    private func refreshMirrorContent() {
        let resting: NotchState = viewModel.state.isResting ? viewModel.state : .idle
        for mirror in mirrors.values { mirror.viewModel.show(resting) }
    }

    /// Notch shape in screen coordinates (origin bottom-left).
    private func surfaceRect() -> NSRect {
        let size = viewModel.size
        let a = anchor(size: size)
        return NSRect(x: a.centerX - size.width / 2, y: a.top - size.height, width: size.width, height: size.height)
    }

    // MARK: Mouse

    private var lastCheckedMouseLocation = NSPoint(x: -10_000, y: -10_000)

    private func installMonitors() {
        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moveMask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moveMask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                // A click in the Mac app under the chat's pane is a click in Nook, not outside it.
                guard !MacAppMirror.shared.holds(NSEvent.mouseLocation) else { return }
                self?.dismissForOutsideClick()
            }
        }) { monitors.append(m) }
        // A click in another Nook window (Settings) is not treated as a global click by macOS.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            let window = event.windowNumber
            let eventWindow = event.window
            MainActor.assumeIsolated {
                guard let self, NSApp.modalWindow == nil else { return }
                if let panel = self.panel, window == panel.windowNumber {
                    // The panel window is far larger than the shape. When the pointer left the shape without a move
                    // reaching us, the panel still catches clicks on its transparent rest: those are outside too.
                    guard self.isOutsideShape(NSEvent.mouseLocation) else { return }
                    panel.ignoresMouseEvents = true
                    self.viewModel.pointerChanged(inside: false)
                    self.viewModel.clickedOutside()
                    return
                }
                // A dropdown (SwiftUI popover) or a confirmation (the sheet of a `.confirmationDialog`, e.g. "Merge pull
                // request?") is a window of its own, but it belongs to the notch: a click in it is not outside.
                if let eventWindow, self.belongsToNotch(eventWindow) { return }
                self.dismissForOutsideClick()
            }
            return event
        }) { monitors.append(m) }
    }

    /// A click outside closes the panel. A click on another screen only closes it: Nook then follows the pointer to
    /// that screen, but does not open there until the pointer has left the notch.
    private func dismissForOutsideClick() {
        let wasOpen = !viewModel.state.isResting
        viewModel.clickedOutside()
        guard wasOpen, viewModel.state.isResting,
              let screen = NotchGeometry.screenWithMouse(), screen.frame != geometry.screenFrame else { return }
        viewModel.holdsHoverOpen = true
    }

    /// True for a popover, sheet or other child window that hangs off a notch panel (the real one or a mirror).
    private func belongsToNotch(_ window: NSWindow) -> Bool {
        var parent: NSWindow? = window
        while let current = parent {
            if current is NotchPanel { return true }
            // A sheet is not a child window: it hangs off its window through `sheetParent`.
            parent = current.parent ?? current.sheetParent
        }
        return false
    }

    /// While you drag an edge to resize, the pointer can run a little ahead of it: it still counts as inside.
    private func isOutsideShape(_ point: NSPoint) -> Bool {
        !viewModel.resizing && !surfaceRect().insetBy(dx: -4, dy: -4).contains(point)
    }

    private func pointerMoved(force: Bool = false) {
        // Hidden for a share or meeting: hovering the notch area opens nothing.
        guard let panel, panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        if !force, dragStart == nil {
            let dx = mouse.x - lastCheckedMouseLocation.x
            let dy = mouse.y - lastCheckedMouseLocation.y
            if dx * dx + dy * dy < 2.25 { return }
        }
        lastCheckedMouseLocation = mouse
        followMouseIfNeeded()
        let inside = !isOutsideShape(mouse)
        if !inside { viewModel.holdsHoverOpen = false }
        // Over a Mac app open next to the chat, the pointer falls through onto the real app window lying under it.
        let ignores = !inside || MacAppMirror.shared.passesThrough(at: mouse)
        if panel.ignoresMouseEvents != ignores {
            panel.ignoresMouseEvents = ignores
        }
        viewModel.pointerChanged(inside: inside)
    }
}
