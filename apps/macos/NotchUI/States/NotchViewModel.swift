import SwiftUI
import Combine
import AppKit

@MainActor
final class NotchViewModel: ObservableObject {
    @Published private(set) var state: NotchState = .idle
    @Published private(set) var size: CGSize = CGSize(width: 290, height: 34)
    @Published private(set) var pointerInside = false
    @Published var selectedAgentID: String = "cc" {
        didSet {
            guard selectedAgentID != oldValue else { return }
            // Another session starts on its conversation; the terminal or browser was for the one you left.
            sessionTool = .conversation
            resizeForWorkbench()
        }
    }

    /// What the selected session shows in the Agents tab: its conversation, or a terminal or the browser next to it.
    @Published var sessionTool: SessionTool = .conversation {
        didSet { if sessionTool != oldValue { resizeForWorkbench() } }
    }

    /// A terminal or the browser is open in the Agents tab: the panel gets the room the old Workspace tab had, and
    /// does not close by itself while you work in it.
    var workbenchOpen: Bool {
        sessionTool != .conversation || AgentsPage.tools.contains(selectedAgentID)
    }

    private func resizeForWorkbench() {
        guard case .panel(.agents) = state, sheet == nil else { return }
        withAnimation(NookTheme.swap) { size = layoutSize(for: state) }
        scheduleAutoClose()
    }
    @Published private(set) var doneButtonTitle = tr("button.close")
    private var doneButtonAction: (() -> Void)?

    /// A task open inside the panel (new session, changes, commit…). Resizes the panel to give it room.
    @Published var sheet: NotchSheet? {
        didSet {
            guard sheet != oldValue else { return }
            withAnimation(NookTheme.swap) { size = layoutSize(for: state) }
            scheduleAutoClose()
        }
    }

    /// The tab you used last: the notch opens there again, unless an agent is waiting for you.
    private(set) var lastTab: PanelTab {
        get { PanelTab(rawValue: UserDefaults.standard.string(forKey: "notch.lastTab") ?? "") ?? .chat }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "notch.lastTab") }
    }

    /// Chat should immediately receive keyboard focus (following a prompt or ⌥⌘ Space), but not on hover.
    var focusChat = false

    /// Set by AppModel; provides access to live data and actions.
    weak var app: AppModel?

    /// Floating mode only: the controller repositions the panel during dragging.
    var onDragMoved: (() -> Void)?
    var onDragEnded: (() -> Void)?
    /// Coordinated multi-screen track announcement.
    var onAnnounce: ((NowPlayingInfo) -> Void)?

    private var callbacks: [String: () -> Void] = [:]
    private var choiceHandlers: [String: ([String]) -> Void] = [:]
    private var pending: [NookCard] = []

    var geometry: NotchGeometry = .placeholder {
        didSet { size = layoutSize(for: state) }
    }

    /// Opens the panel when hovering over the notch for 0.4 seconds.
    /// Enabled by default; can be disabled via the menu bar.
    var openOnHover: Bool {
        get { UserDefaults.standard.object(forKey: "openOnHover") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "openOnHover") }
    }

    private var doneTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var autoCloseTask: Task<Void, Never>?

    /// Is a connected agent running or waiting? If so, the notch appears active when idle.
    var agentsActive: Bool { !(app?.activeAgents.isEmpty ?? true) }

    // MARK: States

    func show(_ new: NotchState) {
        doneTask?.cancel()
        NookPresence.shared.noteActivity()
        var target = new
        // The notch has one Nook tab (home and chat in one), Agents, and Music while something plays. Older routes
        // still work: home and shelf land on Nook; connections are managed in Settings.
        if case .panel(let tab) = new {
            switch tab {
            case .nook, .shelf:
                target = .panel(.chat)
            case .connect:
                app?.openSettings(section: .connections)
                target = .panel(.chat)
            default:
                break
            }
        }
        if case .idle = new {
            if !pending.isEmpty {
                target = .card(pending.removeFirst())
            } else if app?.nowPlaying.current?.isPlaying == true {
                target = .music
            }
        }
        if case .panel = target, state.kind != "panel" { app?.warmUp() }
        if case .panel(let tab) = target {
            switch tab {
            case .chat, .agents: lastTab = tab
            default: break
            }
            // Tasks belong to Agents; another tab means you moved on.
            if tab != .agents, sheet != nil { sheet = nil }
        } else if sheet != nil {
            sheet = nil
        }
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

    /// Automatically collapses the panel after one minute without mouse activity.
    private func scheduleAutoClose() {
        autoCloseTask?.cancel()
        guard case .panel(let openTab) = state, !pointerInside, sheet == nil, !(openTab == .agents && workbenchOpen) else { return }
        autoCloseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled, let self, !self.pointerInside, self.sheet == nil, case .panel(let tab) = self.state else { return }
            // Chat does not auto-collapse during a conversation; retry later.
            if (tab == .nook || tab == .chat), self.app?.chat.isRecentlyActive == true {
                self.scheduleAutoClose()
                return
            }
            self.show(.idle)
        }
    }

    // MARK: External cards

    /// An agent prompt: takes priority over the panel and regular cards (which return to the queue).
    /// If such a prompt is already shown, this queues behind it, ahead of regular cards.
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

    /// Removes a card from the queue only, not from view.
    func removePending(id: String) {
        pending.removeAll { $0.id == id }
    }

    /// Displays a card immediately if Nook is idle, otherwise enqueues it.
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

    /// For cards with options (`CardDetail.choices`): handler receives the selected labels.
    func registerChoice(_ id: String, _ handler: @escaping ([String]) -> Void) {
        choiceHandlers[id] = handler
    }

    func choose(_ id: String, _ labels: [String]) {
        guard let handler = choiceHandlers.removeValue(forKey: id) else { return }
        handler(labels)
    }

    /// Is this card currently visible or queued?
    func hasCard(id: String) -> Bool {
        if case .card(let current) = state, current.id == id { return true }
        return pending.contains { $0.id == id }
    }

    /// Updates the currently visible card in-place (same dimensions, avoiding animation), e.g. while speaking.
    func updateCard(_ card: NookCard) {
        guard case .card(let current) = state, current.id == card.id else { return }
        state = .card(card)
    }

    /// Dismisses a card, whether currently visible or queued.
    func dismissCard(id: String) {
        pending.removeAll { $0.id == id }
        if case .card(let current) = state, current.id == id { show(.idle) }
    }

    func showScene(_ scene: DemoScene) {
        switch scene {
        case .idle: show(.idle)
        case .music: show(.music)
        case .today: show(.panel(.nook))
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
                // The action may have already presented a new card; preserve it.
                if case .card(let shown) = state, shown.id.hasPrefix(base) { show(.idle) }
            } else {
                finish(message)
            }
        }
    }

    /// Displays a brief confirmation and returns to idle after a few seconds.
    func finish(_ message: String, button: String = tr("button.close"), action: (() -> Void)? = nil) {
        doneButtonTitle = button
        doneButtonAction = action
        show(.done(message))
        doneTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_200_000_000)
            guard !Task.isCancelled else { return }
            self?.show(.idle)
        }
    }

    /// A new track: notch expands briefly showing current playback. Only when idle, never over a card or panel.
    func announce(_ info: NowPlayingInfo) {
        if let onAnnounce {
            onAnnounce(info)
            return
        }
        guard state.isResting else { return }
        show(.track(title: info.title, artist: info.artist))
        doneTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self, case .track = self.state else { return }
            self.show(.idle)
        }
    }

    /// A suggestion from Nook next to the notch. Idle only: never over a card, panel, or agent prompt.
    /// Dismisses automatically after a timeout (saved to Today).
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

    /// Expands the short summary into the full card.
    func openNudge() {
        guard case .nudge(_, let card) = state else { return }
        show(.card(card))
    }

    /// Button on the right of the confirmation strip.
    func doneButtonPressed() {
        let action = doneButtonAction
        if let action { action() } else { show(.idle) }
    }

    func startListening() {
        if let app { app.toggleVoice() } else { show(.card(DemoContent.card(for: .listening))) }
    }

    // MARK: Mouse

    func pointerChanged(inside: Bool) {
        guard inside != pointerInside else { return }
        pointerInside = inside
        hoverTask?.cancel()
        if inside, state.isResting { NookPresence.shared.pointerEntered() } else { NookPresence.shared.noteActivity() }
        scheduleAutoClose()
        // Nook made an offer: hovering reveals the full proposal even if hover-to-open is disabled.
        if inside, case .nudge = state {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled, let self, self.pointerInside else { return }
                self.openNudge()
            }
            return
        }
        guard openOnHover, inside, state.isResting else { return }
        // If an agent is running, hover opens a little faster.
        let working = agentsActive
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: working ? 200_000_000 : 400_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.pointerInside, self.state.isResting { self.show(.panel(self.homeTab())) }
        }
    }

    /// Clicking the notch opens the panel immediately, without hover delay.
    func openPanel() {
        hoverTask?.cancel()
        show(.panel(homeTab()))
    }

    /// Where the panel opens: at the agent that waits for you, otherwise at the tab you used last. Predictable, no jumping.
    private func homeTab() -> PanelTab {
        if let waiting = app?.activeAgents.first(where: { $0.status == .waiting || $0.approvalID != nil }) {
            selectedAgentID = waiting.id
            return .agents
        }
        return lastTab
    }

    /// Opens a task inside the notch (new session, changes, commit…), on the Agents tab.
    func open(_ sheet: NotchSheet) {
        if state != .panel(.agents) { show(.panel(.agents)) }
        self.sheet = sheet
    }

    /// Clicking outside the notch closes the panel. Cards remain until an option is selected, and an open task
    /// (a form you are filling in) stays until you close it yourself.
    func clickedOutside() {
        // A folder picker opened from the notch is not "outside": keep the panel while it is up.
        guard sheet == nil, NSApp.modalWindow == nil else { return }
        if case .panel = state { show(.idle) }
    }

    // MARK: Dimensions

    func layoutSize(for state: NotchState) -> CGSize {
        let nw = geometry.notchWidth
        let nh = geometry.notchHeight
        let chrome = nh + 14 + 22   // spacing below notch and bottom margin
        // Floating and idle: just Nook itself, no bar around it.
        if geometry.isFloating, state.isResting {
            return CGSize(width: Self.floatingOrbSide, height: Self.floatingOrbSide)
        }
        switch state {
        case .idle:
            if app?.settings.hideWhenIdle == true, !geometry.isFloating, !agentsActive, !(app?.chat.anyBusy ?? false) {
                // The physical notch area; without a notch, a thin hover trigger strip at the top.
                return CGSize(width: nw, height: geometry.hasNotch ? nh : 5)
            }
            return CGSize(width: nw + 60, height: nh)
        case .music:
            return CGSize(width: nw + 92, height: nh)
        case .track(let title, let artist):
            // Compact, balanced expansion: Nook & artwork on left, title & equalizer on right.
            let textLen = max(CGFloat(title.count) * 6.2, CGFloat(artist.count) * 5.4)
            let wing = min(175, max(115, textLen + 46))
            return CGSize(width: nw + 2 * wing, height: nh)
        case .done:
            return CGSize(width: max(440, nw + 240), height: nh + 40)
        case .nudge:
            return CGSize(width: max(460, nw + 280), height: nh + 34)
        case .card(let card):
            return CGSize(width: 600, height: chrome + card.contentHeight)
        case .panel(let tab):
            let big = AppSettings.shared.panelLarge
            if sheet != nil {
                // A task in the notch gets room to breathe, whatever the size setting.
                return CGSize(width: 1040, height: min(chrome + 640, NotchController.panelSize.height))
            }
            switch tab {
            case .nook: return CGSize(width: 780, height: min(chrome + 440, NotchController.panelSize.height))
            case .chat: return CGSize(width: big ? 1120 : 860, height: min(chrome + (big ? 640 : 440), NotchController.panelSize.height))
            case .agents where workbenchOpen:
                return CGSize(width: big ? 1180 : 1000, height: min(chrome + (big ? 660 : 480), NotchController.panelSize.height))
            case .agents: return CGSize(width: big ? 1120 : 860, height: min(chrome + (big ? 620 : 440), NotchController.panelSize.height))
            case .music: return CGSize(width: big ? 940 : 800, height: min(chrome + (big ? 470 : 380), NotchController.panelSize.height))
            case .shelf: return CGSize(width: 640, height: chrome + 180)
            case .connect: return CGSize(width: 820, height: chrome + 330)
            }
        }
    }

    /// Floating and idle: the area around Nook (the orb plus room for its glow and a badge).
    static let floatingOrbSide: CGFloat = 44

    /// Floating and idle: no black shape, just Nook.
    var isBareOrb: Bool { geometry.isFloating && state.isResting }

    var cornerRadius: CGFloat {
        switch state {
        case .idle: return geometry.isFloating ? Self.floatingOrbSide / 2 : 14
        case .music, .track: return geometry.isFloating ? Self.floatingOrbSide / 2 : 16
        case .done, .nudge: return 16
        case .card: return 30
        case .panel: return 32
        }
    }

    /// Nook's mood when expanded.
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
        case .nook, .chat: return (app?.chat.anyBusy ?? false) ? .think : .rest
        case .music, .shelf: return .rest
        }
    }
}
