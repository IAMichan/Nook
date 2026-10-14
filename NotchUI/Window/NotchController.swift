import AppKit
import SwiftUI
import Combine

/// Manages the notch panel: positioning, click-through outside shape, and dismissal on external clicks.
@MainActor
final class NotchController {
    /// The panel has a fixed bounding size (accommodating the largest state); SwiftUI renders the notch shape within it.
    static let panelSize = CGSize(width: 940, height: 540)

    let viewModel = NotchViewModel()
    private var panel: NotchPanel?
    private var geometry = NotchGeometry.placeholder
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var previousApp: NSRunningApplication?

    private var dragStart: (mouse: NSPoint, offsetX: Double, offsetY: Double)?

    private var settings: AppSettings { AppSettings.shared }

    private func makeGeometry() -> NotchGeometry {
        NotchGeometry.make(
            for: NotchGeometry.preferredScreen(choice: settings.screenChoice),
            floating: settings.placement == "floating"
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
        geometry = makeGeometry()
        viewModel.geometry = geometry
        viewModel.onDragMoved = { [weak self] in self?.dragMoved() }
        viewModel.onDragEnded = { [weak self] in self?.dragStart = nil }

        let initialFrame = panelFrame()
        let panel = NotchPanel(contentRect: initialFrame)
        let host = NSHostingView(rootView: NotchRootView(viewModel: viewModel).environmentObject(app))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
        self.panel = panel

        panel.orderFrontRegardless()
        installMonitors()

        // Size changed? Re-evaluate whether pointer is still hovering over shape.
        viewModel.$size
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.positionPanel()
                self?.pointerMoved()
            }
            .store(in: &cancellables)

        // A card with text input immediately requests keyboard focus so typing works without clicking.
        viewModel.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.stateChanged(state) }
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
        AppSettings.shared.$hideWhenIdle
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.viewModel.state.isResting else { return }
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
            // In chat, keep typing focus.
            if state == .panel(.nook) || state == .panel(.chat) { return }
            // Finished typing: return focus to previously active application.
            panel.resignKey()
            previousApp?.activate(options: [])
            previousApp = nil
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
    }

    /// Floating: shape tracks mouse while dragging; position is saved immediately.
    private func dragMoved() {
        guard geometry.isFloating else { return }
        let mouse = NSEvent.mouseLocation
        let start = dragStart ?? (mouse: mouse, offsetX: settings.floatOffsetX, offsetY: settings.floatOffsetY)
        dragStart = start
        settings.floatOffsetX = start.offsetX + Double(mouse.x - start.mouse.x)
        // Y axis runs downward: dragging downward increases distance below menu bar.
        settings.floatOffsetY = max(0, start.offsetY - Double(mouse.y - start.mouse.y))
        positionPanel()
    }

    /// "Follows mouse": when idle, Nook moves to whichever screen contains the cursor.
    private func followMouseIfNeeded() {
        guard AppSettings.shared.screenChoice == "mouse", viewModel.state.isResting,
              let screen = NotchGeometry.screenWithMouse(), screen.frame != geometry.screenFrame else { return }
        screenChanged()
    }

    /// Notch shape in screen coordinates (origin bottom-left).
    private func surfaceRect() -> NSRect {
        let size = viewModel.size
        let a = anchor(size: size)
        return NSRect(x: a.centerX - size.width / 2, y: a.top - size.height, width: size.width, height: size.height)
    }

    // MARK: Mouse

    private func installMonitors() {
        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moveMask, handler: { [weak self] _ in
            Task { @MainActor in self?.pointerMoved() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moveMask, handler: { [weak self] event in
            Task { @MainActor in self?.pointerMoved() }
            return event
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in self?.viewModel.clickedOutside() }
        }) { monitors.append(m) }
        // A click in another Nook window (Settings) is not treated as a global click by macOS.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            let window = event.windowNumber
            Task { @MainActor in
                guard let self, window != self.panel?.windowNumber else { return }
                self.viewModel.clickedOutside()
            }
            return event
        }) { monitors.append(m) }
    }

    private func pointerMoved() {
        guard let panel else { return }
        followMouseIfNeeded()
        let inside = surfaceRect().insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }
        viewModel.pointerChanged(inside: inside)
    }
}
