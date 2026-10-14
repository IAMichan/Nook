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

    func start(app: AppModel) {
        geometry = NotchGeometry.make(for: NotchGeometry.preferredScreen(choice: AppSettings.shared.screenChoice))
        viewModel.geometry = geometry

        let panel = NotchPanel()
        let host = NSHostingView(rootView: NotchRootView(viewModel: viewModel).environmentObject(app))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
        self.panel = panel

        positionPanel()
        panel.orderFrontRegardless()
        installMonitors()

        // Nieuwe maat? Dan opnieuw bepalen of de muis nog boven de vorm hangt.
        viewModel.$size
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pointerMoved() }
            .store(in: &cancellables)

        // Een kaart met tekstveld krijgt meteen de toetsenbordfocus, zodat je kunt typen zonder te klikken.
        viewModel.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.stateChanged(state) }
            .store(in: &cancellables)

        // Ander scherm gekozen in de instellingen, of Nook in rust verbergen aan of uit.
        AppSettings.shared.$screenChoice
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

    // MARK: Toetsenbordfocus

    private func stateChanged(_ state: NotchState) {
        guard let panel else { return }
        if case .card(let card) = state, card.input {
            guard !panel.isKeyWindow else { return }
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
            panel.ignoresMouseEvents = false
            panel.makeKey()
        } else if panel.isKeyWindow {
            // Tijdens het nadenken blijft de focus staan: het volgende antwoord heeft weer een tekstveld.
            if case .card(let card) = state, card.id == "thinking" { return }
            // Klaar met typen: geef de focus terug aan de app waar je mee bezig was.
            panel.resignKey()
            previousApp?.activate(options: [])
            previousApp = nil
        }
    }

    // MARK: Positie

    private func positionPanel() {
        guard let panel else { return }
        let s = geometry.screenFrame
        let size = Self.panelSize
        let frame = NSRect(x: s.midX - size.width / 2, y: s.maxY - size.height, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }

    private func screenChanged() {
        geometry = NotchGeometry.make(for: NotchGeometry.preferredScreen(choice: AppSettings.shared.screenChoice))
        viewModel.geometry = geometry
        positionPanel()
    }

    /// "Volgt je muis": in rust springt Nook mee naar het scherm waar de muis is.
    private func followMouseIfNeeded() {
        guard AppSettings.shared.screenChoice == "mouse", viewModel.state.isResting,
              let screen = NotchGeometry.screenWithMouse(), screen.frame != geometry.screenFrame else { return }
        screenChanged()
    }

    /// De notch-vorm in schermcoördinaten (oorsprong linksonder).
    private func surfaceRect() -> NSRect {
        let size = viewModel.size
        let s = geometry.screenFrame
        return NSRect(x: s.midX - size.width / 2, y: s.maxY - size.height, width: size.width, height: size.height)
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
