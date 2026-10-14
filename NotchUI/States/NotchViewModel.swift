import SwiftUI
import Combine

@MainActor
final class NotchViewModel: ObservableObject {
    @Published private(set) var state: NotchState = .idle
    @Published private(set) var size: CGSize = CGSize(width: 290, height: 34)
    @Published private(set) var pointerInside = false
    @Published var selectedAgentID: String = "cc"
    @Published private(set) var doneButtonTitle = "Sluiten"
    private var doneButtonAction: (() -> Void)?

    /// Wordt gezet door AppModel; geeft toegang tot echte data en acties.
    weak var app: AppModel?

    private var callbacks: [String: () -> Void] = [:]
    private var choiceHandlers: [String: ([String]) -> Void] = [:]
    private var pending: [NookCard] = []

    var geometry: NotchGeometry = .placeholder {
        didSet { size = layoutSize(for: state) }
    }

    /// Opent het paneel als je 0,4 seconde met de muis op de notch blijft hangen.
    /// Staat standaard aan; uitzetten kan via de menubalk.
    var openOnHover: Bool {
        get { UserDefaults.standard.object(forKey: "openOnHover") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "openOnHover") }
    }

    private var doneTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var autoCloseTask: Task<Void, Never>?

    /// Draait of wacht er een gekoppelde agent? Dan is de notch in rust "aan het werk".
    var agentsActive: Bool { !(app?.activeAgents.isEmpty ?? true) }

    // MARK: Toestanden

    func show(_ new: NotchState) {
        doneTask?.cancel()
        var target = new
        if case .idle = new {
            if !pending.isEmpty {
                target = .card(pending.removeFirst())
            } else if app?.nowPlaying.current?.isPlaying == true {
                target = .music
            }
        }
        if case .panel = target, state.kind != "panel" { app?.warmUp() }
        let newSize = layoutSize(for: target)
        let growing = newSize.width * newSize.height > size.width * size.height
        let sameKind = state.kind == target.kind
        let animation: Animation = sameKind ? NookTheme.swap : (growing ? NookTheme.open : NookTheme.close)
        withAnimation(animation) {
            state = target
            size = newSize
        }
        scheduleAutoClose()
    }

    /// Het paneel klapt na een minuut zonder muis vanzelf dicht, net als bij Coucou.
    private func scheduleAutoClose() {
        autoCloseTask?.cancel()
        guard case .panel = state, !pointerInside else { return }
        autoCloseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled, let self, !self.pointerInside, case .panel = self.state else { return }
            self.show(.idle)
        }
    }

    // MARK: Kaarten van buiten

    /// Een vraag van een agent: gaat voor op het paneel en op gewone kaarten (die schuiven terug in de wachtrij).
    /// Staat er al zo'n vraag, dan komt deze erachter, vóór de gewone kaarten.
    func presentUrgent(_ card: NookCard) {
        var urgent = card
        urgent.urgent = true
        let firstNormal = pending.firstIndex { !$0.urgent } ?? pending.count
        switch state {
        case .card(let current) where current.urgent:
            pending.insert(urgent, at: firstNormal)
        case .card(let current):
            pending.insert(current, at: firstNormal)
            show(.card(urgent))
        default:
            show(.card(urgent))
        }
    }

    /// Haalt een kaart alleen uit de wachtrij, niet uit beeld.
    func removePending(id: String) {
        pending.removeAll { $0.id == id }
    }

    /// Toont een kaart meteen als Nook in rust is, anders komt hij in de wachtrij.
    func present(_ card: NookCard) {
        switch state {
        case .idle, .music, .track, .done, .nudge:
            show(.card(card))
        default:
            pending.append(card)
        }
    }

    func register(_ id: String, _ action: @escaping () -> Void) {
        callbacks[id] = action
    }

    /// Voor kaarten met opties (`CardDetail.choices`): de handler krijgt de gekozen labels.
    func registerChoice(_ id: String, _ handler: @escaping ([String]) -> Void) {
        choiceHandlers[id] = handler
    }

    func choose(_ id: String, _ labels: [String]) {
        guard let handler = choiceHandlers.removeValue(forKey: id) else { return }
        handler(labels)
    }

    /// Staat deze kaart nu in beeld of in de wachtrij?
    func hasCard(id: String) -> Bool {
        if case .card(let current) = state, current.id == id { return true }
        return pending.contains { $0.id == id }
    }

    /// Ververst de inhoud van de kaart die nu zichtbaar is (zelfde maat, dus zonder animatie), bijvoorbeeld tijdens het praten.
    func updateCard(_ card: NookCard) {
        guard case .card(let current) = state, current.id == card.id else { return }
        state = .card(card)
    }

    /// Haalt een kaart weg, of hij nu zichtbaar is of nog wacht.
    func dismissCard(id: String) {
        pending.removeAll { $0.id == id }
        if case .card(let current) = state, current.id == id { show(.idle) }
    }

    func showScene(_ scene: DemoScene) {
        switch scene {
        case .idle: show(.idle)
        case .music: show(.music)
        case .today: show(.panel(.today))
        case .agents: show(.panel(.agents))
        case .suggestion: show(.card(DemoContent.card(for: .suggestion)))
        case .reminder: show(.card(DemoContent.card(for: .reminder)))
        case .listening: show(.card(DemoContent.card(for: .listening)))
        case .plan: show(.card(DemoContent.card(for: .plan)))
        case .approval: show(.card(DemoContent.card(for: .approval)))
        }
    }

    func perform(_ action: CardAction) {
        switch action.outcome {
        case .done(let message): finish(message)
        case .show(let scene): show(.card(DemoContent.card(for: scene)))
        case .dismiss: show(.idle)
        case .callback(let id, let message):
            let base = id.split(separator: "#").first.map(String.init) ?? id
            let action = callbacks[id]
            for key in callbacks.keys where key.hasPrefix(base) { callbacks[key] = nil }
            action?()
            if message.isEmpty {
                // De actie kan zelf al een nieuwe kaart hebben getoond; laat die staan.
                if case .card(let shown) = state, shown.id.hasPrefix(base) { show(.idle) }
            } else {
                finish(message)
            }
        }
    }

    /// Toont een korte bevestiging en gaat na een paar seconden terug naar rust.
    func finish(_ message: String, button: String = "Sluiten", action: (() -> Void)? = nil) {
        doneButtonTitle = button
        doneButtonAction = action
        show(.done(message))
        doneTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_200_000_000)
            guard !Task.isCancelled else { return }
            self?.show(.idle)
        }
    }

    /// Een nieuw nummer: de notch wordt even breder en zegt wat er nu speelt. Alleen in rust, nooit over een kaart of paneel heen.
    func announce(_ info: NowPlayingInfo) {
        guard state.isResting else { return }
        show(.track(title: info.title, artist: info.artist))
        doneTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self, case .track = self.state else { return }
            self.show(.idle)
        }
    }

    /// Een aanbod van Nook naast de notch. Alleen in rust: nooit over een kaart, paneel of vraag van een agent heen.
    /// Na een tijdje zonder reactie verdwijnt het vanzelf (de app bewaart het dan in Vandaag).
    @discardableResult
    func offerNudge(_ line: String, card: NookCard, for seconds: Double = 14) -> Bool {
        guard state.isResting, pending.isEmpty else { return false }
        show(.nudge(line, card))
        doneTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, case .nudge(_, let shown) = self.state, shown.id == card.id else { return }
            self.show(.idle)
        }
        return true
    }

    /// Van de korte zin naar de hele kaart.
    func openNudge() {
        guard case .nudge(_, let card) = state else { return }
        show(.card(card))
    }

    /// De knop rechts in de bevestigingsstrook.
    func doneButtonPressed() {
        let action = doneButtonAction
        if let action { action() } else { show(.idle) }
    }

    func startListening() {
        if let app { app.toggleVoice() } else { show(.card(DemoContent.card(for: .listening))) }
    }

    // MARK: Muis

    func pointerChanged(inside: Bool) {
        guard inside != pointerInside else { return }
        pointerInside = inside
        hoverTask?.cancel()
        scheduleAutoClose()
        // Nook bood iets aan: wijzen is genoeg om het hele voorstel te zien, ook als openen bij hover uit staat.
        if inside, case .nudge = state {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled, let self, self.pointerInside else { return }
                self.openNudge()
            }
            return
        }
        guard openOnHover, inside, state.isResting else { return }
        // Werkt er een agent, dan opent hover sneller en meteen op Agents.
        let working = agentsActive
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: working ? 200_000_000 : 400_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.pointerInside, self.state.isResting {
                if working, let first = self.app?.activeAgents.first { self.selectedAgentID = first.id }
                self.show(.panel(working ? .agents : .today))
            }
        }
    }

    /// Een klik buiten de notch sluit het paneel. Kaarten blijven staan tot je kiest.
    func clickedOutside() {
        if case .panel = state { show(.idle) }
    }

    // MARK: Maten

    func layoutSize(for state: NotchState) -> CGSize {
        let nw = geometry.notchWidth
        let nh = geometry.notchHeight
        let chrome = nh + 14 + 22   // ruimte onder de notch en onderrand
        switch state {
        case .idle:
            if app?.settings.hideWhenIdle == true, !agentsActive {
                // Alleen de notch zelf; zonder notch een dun randje bovenaan om naar te wijzen.
                return CGSize(width: nw, height: geometry.hasNotch ? nh : 5)
            }
            return CGSize(width: nw + 100, height: nh)
        case .music:
            return CGSize(width: nw + 130, height: nh)
        case .track:
            return CGSize(width: nw + 340, height: nh)
        case .done:
            return CGSize(width: max(440, nw + 240), height: nh + 40)
        case .nudge:
            return CGSize(width: max(460, nw + 280), height: nh + 34)
        case .card(let card):
            return CGSize(width: 600, height: chrome + card.contentHeight)
        case .panel(let tab):
            switch tab {
            case .today: return CGSize(width: 700, height: chrome + 356)
            case .agents: return CGSize(width: 860, height: chrome + 386)
            case .music: return CGSize(width: 640, height: chrome + 196)
            case .shelf: return CGSize(width: 640, height: chrome + 180)
            case .connect: return CGSize(width: 820, height: chrome + 330)
            }
        }
    }

    var cornerRadius: CGFloat {
        switch state {
        case .idle: return 14
        case .music, .track, .done, .nudge: return 16
        case .card: return 30
        case .panel: return 32
        }
    }

    /// Hoe Nook zich voelt in de uitgeklapte toestanden.
    func mood(for panelTab: PanelTab) -> NookMood {
        switch panelTab {
        case .agents:
            let sessions = app?.agentSessions ?? DemoContent.agents
            let session = sessions.first { $0.id == selectedAgentID } ?? sessions.first
            switch session?.status {
            case .waiting: return .waiting
            case .failed: return .worry
            case .running: return .think
            default: return .rest
            }
        case .connect:
            return (app?.connectors.needingAttention.isEmpty ?? true) ? .rest : .waiting
        case .music, .today, .shelf: return .rest
        }
    }
}
