import SwiftUI
import Combine
import AppKit

@MainActor
final class NotchViewModel: ObservableObject {
    @Published private(set) var state: NotchState = .idle
    @Published private(set) var size: CGSize = CGSize(width: 290, height: 34)
    @Published private(set) var pointerInside = false
    /// A notice that came in while the panel was open: shown in the panel's own bar instead of over it.
    @Published private(set) var panelNotice: PanelNotice?
    @Published var selectedAgentID: String = UserDefaults.standard.string(forKey: "notch.lastAgentPage") ?? "cc" {
        didSet {
            guard selectedAgentID != oldValue else { return }
            UserDefaults.standard.set(selectedAgentID, forKey: "notch.lastAgentPage")
            // Another session starts on its conversation; the terminal or browser was for the one you left.
            sessionTool = .conversation
            bottomTool = .conversation
            resizeForWorkbench()
        }
    }

    /// What the selected session shows in the Agents tab: its conversation, or a terminal or the browser next to it.
    /// A tool that opens gets its own tab in the side panel, and leaves the bottom panel if it was open there.
    @Published var sessionTool: SessionTool = .conversation {
        didSet {
            if SessionTool.panelTools.contains(sessionTool) {
                if !sessionTabs.contains(sessionTool) { sessionTabs.append(sessionTool) }
                take(sessionTool, from: \.bottomTool, tabs: \.bottomTabs)
            }
            if sessionTool != oldValue { resizeForWorkbench() }
        }
    }

    /// The tools open as tabs in a session's side panel, in the order you opened them. Kept between sessions and
    /// launches; with none open the side panel offers the tools to choose from.
    @Published var sessionTabs: [SessionTool] = (UserDefaults.standard.stringArray(forKey: "nook.agents.sideTabs") ?? [])
        .compactMap(SessionTool.init(rawValue:)).filter { SessionTool.panelTools.contains($0) } {
        didSet { UserDefaults.standard.set(sessionTabs.map(\.rawValue), forKey: "nook.agents.sideTabs") }
    }

    /// What the bottom panel under the selected session's conversation shows: nothing (closed), the list of tools, or
    /// a tool, the terminal at first. A tool that opens here gets its own tab, and leaves the side panel.
    @Published var bottomTool: SessionTool = .conversation {
        didSet {
            if SessionTool.panelTools.contains(bottomTool) {
                if !bottomTabs.contains(bottomTool) { bottomTabs.append(bottomTool) }
                take(bottomTool, from: \.sessionTool, tabs: \.sessionTabs)
            }
            if bottomTool != oldValue { resizeForWorkbench() }
        }
    }

    /// The tools open as tabs in the bottom panel, like `sessionTabs`; never one that is open in the side panel.
    @Published var bottomTabs: [SessionTool] = {
        let side = UserDefaults.standard.stringArray(forKey: "nook.agents.sideTabs") ?? []
        return (UserDefaults.standard.stringArray(forKey: "nook.agents.bottomTabs") ?? [])
            .compactMap(SessionTool.init(rawValue:)).filter { SessionTool.panelTools.contains($0) && !side.contains($0.rawValue) }
    }() {
        didSet { UserDefaults.standard.set(bottomTabs.map(\.rawValue), forKey: "nook.agents.bottomTabs") }
    }

    /// A tool is open in one panel at a time (a terminal or the web view can only be in one place): opening it in one
    /// closes its tab in the other, which then shows its next tab or the list of tools.
    private func take(_ tool: SessionTool, from shown: ReferenceWritableKeyPath<NotchViewModel, SessionTool>,
                      tabs: ReferenceWritableKeyPath<NotchViewModel, [SessionTool]>) {
        guard self[keyPath: tabs].contains(tool) else { return }
        self[keyPath: tabs].removeAll { $0 == tool }
        if self[keyPath: shown] == tool { self[keyPath: shown] = self[keyPath: tabs].first ?? .picker }
    }

    /// A terminal or the browser is open in the Agents tab (beside or under a session): the panel gets the room the old Workspace tab had, and
    /// does not close by itself while you work in it.
    var workbenchOpen: Bool {
        sessionTool != .conversation || bottomTool != .conversation || AgentsPage.tools.contains(selectedAgentID)
    }

    /// An app is open next to the chat ("@open whatsapp"): the chat gets the room for it, and does not close by itself
    /// while you work in the app.
    @Published var embeddedAppOpen = false {
        didSet {
            guard embeddedAppOpen != oldValue, case .panel(let tab) = state, tab == .chat || tab == .nook, sheet == nil else { return }
            withAnimation(NookTheme.swap) { size = layoutSize(for: state) }
            scheduleAutoClose()
        }
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

    /// The tab Nook's main window shows: the same tabs as the panel, with more room (see `WorkspaceView`). Remembered,
    /// so the window opens where you left it.
    @Published var windowTab: PanelTab = NotchViewModel.savedWindowTab {
        didSet { UserDefaults.standard.set(windowTab.rawValue, forKey: "window.lastTab") }
    }

    private nonisolated static var savedWindowTab: PanelTab {
        switch PanelTab(rawValue: UserDefaults.standard.string(forKey: "window.lastTab") ?? "") {
        case .agents: return .agents
        case .music: return .music
        default: return .chat
        }
    }
    /// A task open in the main window (changes, commit…): the window's counterpart of `sheet`.
    @Published var windowSheet: NotchSheet?

    /// While the main window is in front (and the panel is not open), the tabs and tasks you ask for open there instead
    /// of in the notch.
    var routesToWindow: Bool {
        if case .panel = state { return false }
        return WorkspaceWindowController.shared.isKey
    }

    /// Whether `tab` is on screen: in the open panel, or in the main window while that is in front.
    func isShowing(_ tab: PanelTab) -> Bool {
        state == .panel(tab) || (routesToWindow && windowTab == tab && windowSheet == nil)
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

    /// While you share your screen or sit in a meeting and chose so (`AppModel+Quiet`): no track announcements,
    /// suggestions or moments of Nook's own.
    var silenced = false
    /// While the notch hides for a share or meeting: cards wait in line, also agent prompts, until it is over.
    var holdsCards = false

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

    /// - `inNotch`: the notch itself asks (hover, a click on it, the menu bar): the panel opens even while the main
    ///   window is in front. Anything else that asks for a tab goes to the main window while that is in front.
    func show(_ new: NotchState, inNotch: Bool = false) {
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
        if case .panel(let tab) = target, !inNotch, routesToWindow {
            if tab == .chat { app?.warmUp() }
            // Tasks belong to Agents; another tab means you moved on.
            if tab != .agents { windowSheet = nil }
            windowTab = tab
            return
        }
        if case .idle = new {
            if !pending.isEmpty, !holdsCards {
                target = .card(pending.removeFirst())
            } else if app?.nowPlaying.current?.isPlaying == true {
                target = .music
            }
        }
        // Only where you can ask something: with the brain on this Mac, warming up loads a model of several gigabytes, and
        // opening the panel for the agents or the music is no reason for that.
        if case .panel(let tab) = target, state.kind != "panel", tab == .chat || tab == .nook { app?.warmUp() }
        if case .panel(let tab) = target {
            switch tab {
            case .chat, .agents, .music: lastTab = tab
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
        guard case .panel(let openTab) = state, !pointerInside, sheet == nil, !(openTab == .agents && workbenchOpen),
              !((openTab == .chat || openTab == .nook) && embeddedAppOpen) else { return }
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
    /// - `keepPanel`: an open panel stays: the prompt waits in line (it shows as a card once the panel closes) and the
    ///   panel asks it in a compact bar of its own (see `PanelApprovalBar`), so it does not take over the whole notch.
    func presentUrgent(_ card: NookCard, keepPanel: Bool = false) {
        var urgent = card
        urgent.urgent = true
        let firstNormal = pending.firstIndex { !$0.urgent } ?? pending.count
        if holdsCards {
            pending.insert(urgent, at: firstNormal)
            return
        }
        switch state {
        case .card(let current) where current.urgent:
            pending.insert(urgent, at: firstNormal)
        case .panel where keepPanel:
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
        if holdsCards {
            pending.append(card)
            return
        }
        switch state {
        case .idle, .music, .track, .done, .nudge, .moment:
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

    /// A notice Nook gives by himself (not in reply to what you just did): like `finish`, but an open panel stays and
    /// shows it in a compact bar (see `PanelApprovalBar`) instead of being replaced and then closed.
    func notify(_ message: String, button: String = tr("button.close"), action: (() -> Void)? = nil) {
        guard case .panel = state else {
            finish(message, button: button, action: action)
            return
        }
        let notice = PanelNotice(message: message, button: button, action: action)
        panelNotice = notice
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if self?.panelNotice?.id == notice.id { self?.panelNotice = nil }
        }
    }

    func dismissPanelNotice() {
        panelNotice = nil
    }

    /// A new track: notch expands briefly showing current playback. Only when idle, never over a card or panel.
    func announce(_ info: NowPlayingInfo) {
        guard !silenced else { return }
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
        guard state.isResting, pending.isEmpty, !silenced else { return false }
        show(.nudge(line, card))
        doneTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, case .nudge(_, let shown) = self.state, shown.id == card.id else { return }
            self.show(.idle)
        }
        return true
    }

    /// A moment Nook shares by himself, below the notch. Like a nudge: only while resting, never over a card, a panel
    /// or something waiting in line; it goes away by itself.
    @discardableResult
    func offerMoment(_ moment: NookMoment) -> Bool {
        guard state.isResting, pending.isEmpty, !silenced else { return false }
        show(.moment(moment))
        dismissMoment(moment.id, after: moment.seconds)
        return true
    }

    /// Shows another moment in place of the one showing now (the next step of the same moment, like breathing along).
    func replaceMoment(_ moment: NookMoment) {
        guard case .moment = state else { return }
        show(.moment(moment))
        dismissMoment(moment.id, after: moment.seconds)
    }

    /// Back to idle after `seconds`, if this moment is still showing.
    func dismissMoment(_ id: String, after seconds: Double) {
        doneTask?.cancel()
        doneTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled, let self, case .moment(let shown) = self.state, shown.id == id else { return }
            self.show(.idle)
        }
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
        // A moment stays while you read it, and leaves a little after you move away.
        if case .moment(let moment) = state {
            // Breathing along keeps going for its full minute, wherever the pointer is.
            let left = moment.mood == .breathe ? max(3, moment.seconds - Date().timeIntervalSince(moment.started)) : 3
            if inside { doneTask?.cancel() } else { dismissMoment(moment.id, after: left) }
            return
        }
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
            if self.pointerInside, self.state.isResting { self.show(.panel(self.homeTab()), inNotch: true) }
        }
    }

    /// Clicking the notch opens the panel immediately, without hover delay.
    func openPanel() {
        hoverTask?.cancel()
        show(.panel(homeTab()), inNotch: true)
    }

    /// Where the panel opens: at the agent that waits for you, otherwise at the tab you used last. Predictable, no jumping.
    private func homeTab() -> PanelTab {
        if let waiting = app?.activeAgents.first(where: { $0.status == .waiting || $0.approvalID != nil }) {
            selectedAgentID = waiting.id
            return .agents
        }
        // Music only exists while a player is open.
        if lastTab == .music, app?.nowPlaying.current == nil { return .chat }
        return lastTab
    }

    /// Where the main window opens: at the agent that waits for you, otherwise at the tab it showed last (Music only while
    /// a player is open).
    func prepareWindow() {
        if let waiting = app?.activeAgents.first(where: { $0.status == .waiting || $0.approvalID != nil }) {
            selectedAgentID = waiting.id
            windowSheet = nil
            windowTab = .agents
        } else if windowTab == .music, app?.nowPlaying.current == nil {
            windowTab = .chat
        }
    }

    /// Opens a task inside the notch (new session, changes, commit…), on the Agents tab; in the main window while that is
    /// in front.
    func open(_ sheet: NotchSheet) {
        if routesToWindow {
            windowTab = .agents
            windowSheet = sheet
            return
        }
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
            return CGSize(width: nw + 56, height: nh)
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
        case .moment:
            return CGSize(width: max(500, nw + 300), height: nh + 40)
        case .card(let card):
            return CGSize(width: 600, height: chrome + card.contentHeight)
        case .panel(let tab):
            return NotchResize.size(base: panelBase(tab), extra: panelExtra, maximum: panelMaximum)
        }
    }

    /// The size a tab of the open panel starts at, before your own resize.
    private func panelBase(_ tab: PanelTab) -> CGSize {
        let nh = geometry.notchHeight
        let chrome = nh + 14 + 22   // spacing below notch and bottom margin
        let big = AppSettings.shared.panelLarge
        if sheet != nil {
            // A task in the notch gets room to breathe, whatever the size setting.
            return CGSize(width: 1040, height: min(chrome + 640, NotchController.panelSize.height))
        }
        switch tab {
        case .nook where embeddedAppOpen, .chat where embeddedAppOpen:
            return CGSize(width: 1240, height: min(chrome + 680, NotchController.panelSize.height))
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

    // MARK: Resizing the open panel

    /// Your own size for the open panel, on top of what each tab starts at: drag its sides or bottom corners, double-click
    /// one to go back. Remembered.
    private var panelExtra = NotchResize.load()
    private var resizeStart: CGSize?
    /// While you drag an edge the pointer counts as over the notch, also when it runs ahead of the edge for a moment.
    private(set) var resizing = false

    /// As large as the panel window and the screen allow.
    private var panelMaximum: CGSize {
        let screen = geometry.screenFrame.size
        let width = NotchController.panelSize.width - 40
        let height = NotchController.panelSize.height
        return CGSize(width: screen.width > 0 ? min(width, screen.width - 40) : width,
                      height: screen.height > 0 ? min(height, screen.height - 40) : height)
    }

    func resize(_ edge: NotchResize.Edge, translation: CGSize) {
        guard case .panel(let tab) = state else { return }
        resizing = true
        autoCloseTask?.cancel()
        let start = resizeStart ?? panelExtra
        resizeStart = start
        panelExtra = NotchResize.clamped(NotchResize.dragged(edge, from: start, translation: translation),
                                         base: panelBase(tab), maximum: panelMaximum)
        // Follows the pointer: no animation.
        size = layoutSize(for: state)
    }

    func endResize() {
        resizing = false
        resizeStart = nil
        NotchResize.save(panelExtra)
        scheduleAutoClose()
    }

    func resetPanelSize() {
        panelExtra = .zero
        NotchResize.save(panelExtra)
        withAnimation(NookTheme.swap) { size = layoutSize(for: state) }
    }

    /// Floating and idle: the area around Nook (the orb plus room for its glow and a badge).
    static let floatingOrbSide: CGFloat = 44

    /// Floating and idle: no black shape, just Nook.
    var isBareOrb: Bool { geometry.isFloating && state.isResting }

    var cornerRadius: CGFloat {
        switch state {
        case .idle: return geometry.isFloating ? Self.floatingOrbSide / 2 : 14
        case .music, .track: return geometry.isFloating ? Self.floatingOrbSide / 2 : 16
        case .done, .nudge, .moment: return 16
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

/// A notice shown in the open panel's bar; see `NotchViewModel.notify`.
struct PanelNotice: Identifiable {
    let id = UUID()
    let message: String
    let button: String
    let action: (() -> Void)?
}
