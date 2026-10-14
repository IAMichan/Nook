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
    }

    // MARK: Kaarten van buiten

    /// Toont een kaart meteen als Nook in rust is, anders komt hij in de wachtrij.
    func present(_ card: NookCard) {
        switch state {
        case .idle, .music, .done:
            show(.card(card))
        default:
            pending.append(card)
        }
    }

    func register(_ id: String, _ action: @escaping () -> Void) {
        callbacks[id] = action
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
        guard openOnHover, inside, state.isResting else { return }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.pointerInside, self.state.isResting {
                self.show(.panel(.today))
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
            return CGSize(width: nw + 100, height: nh)
        case .music:
            return CGSize(width: nw + 130, height: nh)
        case .done:
            return CGSize(width: max(440, nw + 240), height: nh + 40)
        case .card(let card):
            return CGSize(width: 600, height: chrome + card.contentHeight)
        case .panel(let tab):
            switch tab {
            case .today: return CGSize(width: 680, height: chrome + 310)
            case .agents: return CGSize(width: 860, height: chrome + 386)
            case .music, .shelf: return CGSize(width: 640, height: chrome + 180)
            }
        }
    }

    var cornerRadius: CGFloat {
        switch state {
        case .idle: return 14
        case .music, .done: return 16
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
        case .music, .today, .shelf: return .rest
        }
    }
}
