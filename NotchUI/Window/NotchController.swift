import AppKit
import SwiftUI
import Combine

/// Beheert het notch-paneel: positie, klikken doorlaten buiten de vorm en sluiten bij een klik elders.
@MainActor
final class NotchController {
    /// Het paneel is vast groot (ruim genoeg voor de grootste toestand); SwiftUI tekent de notch-vorm erin.
    static let panelSize = CGSize(width: 940, height: 540)

    let viewModel = NotchViewModel()
    private var panel: NotchPanel?
    private var geometry = NotchGeometry.placeholder
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var previousApp: NSRunningApplication?

    private var dragStart: (mouse: NSPoint, centerX: CGFloat, top: CGFloat)?

    /// Notch op elk scherm: op de andere schermen staat een rustende kopie. De echte Nook springt
    /// in rust mee naar het scherm waar je muis is, zodat je hem daar kunt openen.
    private var mirrors: [String: (panel: NotchPanel, viewModel: NotchViewModel)] = [:]
    private weak var app: AppModel?

    private var settings: AppSettings { AppSettings.shared }

    private var isFloating: Bool { settings.placement == "floating" }
    private var showsOnAllScreens: Bool { !isFloating && settings.notchOnAllScreens }

    private func makeGeometry() -> NotchGeometry {
        NotchGeometry.make(
            for: NotchGeometry.preferredScreen(choice: showsOnAllScreens ? "mouse" : settings.screenChoice),
            floating: isFloating
        )
    }

    /// Het scherm dat bij de huidige geometrie hoort (voor de zichtbare ruimte onder de menubalk).
    private var visibleFrame: NSRect {
        NSScreen.screens.first { $0.frame == geometry.screenFrame }?.visibleFrame ?? geometry.screenFrame
    }

    /// Midden en bovenrand van de vorm in schermcoördinaten. Vast in de notch; zwevend volgens de bewaarde positie,
    /// binnen het scherm gehouden.
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

        let initialFrame = panelFrame()
        let panel = NotchPanel(contentRect: initialFrame)
        let host = NSHostingView(rootView: NotchRootView(viewModel: viewModel).environmentObject(app))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
        self.panel = panel

        panel.orderFrontRegardless()
        refreshMirrors()
        installMonitors()

        // Nieuwe maat? Dan opnieuw bepalen of de muis nog boven de vorm hangt.
        viewModel.$size
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.positionPanel()
                self?.pointerMoved()
            }
            .store(in: &cancellables)

        // Een kaart met tekstveld krijgt meteen de toetsenbordfocus, zodat je kunt typen zonder te klikken.
        viewModel.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.stateChanged(state)
                if state.isResting { self?.refreshMirrorContent() }
            }
            .store(in: &cancellables)

        // Ander scherm gekozen in de instellingen, of Nook in rust verbergen aan of uit.
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

    // MARK: Toetsenbordfocus

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
            // Tijdens het nadenken blijft de focus staan: het volgende antwoord heeft weer een tekstveld.
            if case .card(let card) = state, card.id == "thinking" { return }
            // In de chat blijf je typen.
            if state == .panel(.nook) || state == .panel(.chat) { return }
            // Klaar met typen: geef de focus terug aan de app waar je mee bezig was.
            panel.resignKey()
            previousApp?.activate(options: [])
            previousApp = nil
        }
    }

    // MARK: Positie

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

    /// Zwevend: de vorm volgt de muis zolang je sleept, ook naar een ander aangesloten scherm.
    /// Positie en scherm worden direct bewaard.
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

        // Over de rand naar een ander scherm: Nook verhuist mee en onthoudt dat scherm.
        if let target = NotchGeometry.screenWithMouse(), target.frame != geometry.screenFrame {
            geometry = NotchGeometry.make(for: target, floating: true)
            viewModel.geometry = geometry
            if settings.screenChoice != target.localizedName { settings.screenChoice = target.localizedName }
        }

        settings.floatOffsetX = Double(centerX - geometry.screenFrame.midX)
        // Y loopt omlaag: sleep je naar beneden, dan wordt de afstand onder de menubalk groter.
        settings.floatOffsetY = max(0, Double(visibleFrame.maxY - top))
        positionPanel()
    }

    /// "Volgt je muis" of notch op elk scherm: in rust springt Nook mee naar het scherm waar de muis is.
    private func followMouseIfNeeded() {
        guard settings.screenChoice == "mouse" || showsOnAllScreens, viewModel.state.isResting, dragStart == nil,
              let screen = NotchGeometry.screenWithMouse(), screen.frame != geometry.screenFrame else { return }
        screenChanged()
    }

    // MARK: Notch op elk scherm

    /// Zet een rustende notch op elk scherm behalve het scherm waar de echte Nook staat.
    private func refreshMirrors() {
        let wanted = showsOnAllScreens
            ? NSScreen.screens.filter { $0.frame != geometry.screenFrame }
            : []
        let wantedKeys = Set(wanted.map { NSStringFromRect($0.frame) })
        for (key, mirror) in mirrors where !wantedKeys.contains(key) {
            mirror.panel.orderOut(nil)
            mirrors[key] = nil
        }
        guard let app else { return }
        for screen in wanted {
            let mirrorGeometry = NotchGeometry.make(for: screen)
            let key = NSStringFromRect(screen.frame)
            if let existing = mirrors[key] {
                existing.viewModel.geometry = mirrorGeometry
                placeMirror(existing.panel, on: screen.frame)
                continue
            }
            let mirrorModel = NotchViewModel()
            mirrorModel.app = app
            mirrorModel.geometry = mirrorGeometry
            mirrorModel.show(.idle)
            let panel = NotchPanel()
            let host = NSHostingView(rootView: NotchRootView(viewModel: mirrorModel).environmentObject(app))
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: Self.panelSize)
            panel.contentView = host
            placeMirror(panel, on: screen.frame)
            // Alleen om naar te kijken: de muis gaat erdoorheen, de echte Nook komt naar dit scherm zodra je muis er is.
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
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

    /// Houdt de kopieën gelijk aan de rusttoestand (muziek, verbergen in rust, agents).
    private func refreshMirrorContent() {
        for mirror in mirrors.values { mirror.viewModel.show(.idle) }
    }

    /// De notch-vorm in schermcoördinaten (oorsprong linksonder).
    private func surfaceRect() -> NSRect {
        let size = viewModel.size
        let a = anchor(size: size)
        return NSRect(x: a.centerX - size.width / 2, y: a.top - size.height, width: size.width, height: size.height)
    }

    // MARK: Muis

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
        // Een klik in een ander venster van Nook zelf (Instellingen) is voor macOS geen globale klik.
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
