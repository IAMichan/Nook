import SwiftUI
import Combine
import AppKit
import Carbon.HIToolbox
import PDFKit
import UniformTypeIdentifiers

/// Knoopt alles aan elkaar: services, brein en notch. De UI praat alleen met dit object.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let notch = NotchController()
    let settings = AppSettings.shared
    let store = NookStore()
    let calendar = CalendarService()
    let nowPlaying = NowPlayingService()
    let hub = AgentHub()
    let voice = VoiceService()
    let screen = ScreenReader()
    let recap = RecapStore()
    let speech = SpeechOutput()
    let wake = WakeWordService()
    /// Wat er op al je schermen staat, live bijgehouden (lokaal).
    let screenContext = ScreenContext()
    /// Agenda, mail, browser, GitHub, Stripe…: alles waar Nook context uit haalt.
    let connectors = ConnectorHub()
    let codex = CodexUsage()
    /// Eerdere sessies en tokengebruik van Claude Code en Codex, voor de Agents-tab.
    let history = AgentHistory()
    /// Je accounts per agent (persoonlijk, werk…) en welke de standaard is.
    let profiles = AgentProfileStore()
    /// Zoeken op het web en webpagina's lezen, voor elk brein.
    let web = WebTools()
    let portfolio = PortfolioConnector()
    /// Meedenken: wanneer Nook ongevraagd meekijkt en iets aanbiedt.
    let thinkAlong = ThinkAlong()
    /// Het gesprek met Nook in de chat.
    let chat = NookChat()
    /// Coding-agents die Nook zelf start en volgt, in hun eigen venster.
    let workspace = WorkspaceManager()
    /// Welk onderdeel van Instellingen open staat.
    @Published var settingsSection: SettingsSection = .general

    private(set) lazy var tools: NookTools = {
        let tools = NookTools(calendar: calendar, store: store, screen: screen) { [weak self] in
            self?.reloadLoops()
        }
        tools.screenSnapshot = { [weak self] in
            guard let self else { throw ScreenError.nothing }
            return try await self.screenSnapshot()
        }
        return tools
    }()

    /// Grafieken en mailconcepten: die komen in het bericht waar Nook nu aan schrijft.
    private(set) lazy var chatTools: [ToolSpec] = ChatTools.specs(
        onChart: { [weak self] chart in self?.attachToReply { $0.charts.append(chart) } },
        onMail: { [weak self] mail in self?.attachToReply { $0.mails.append(mail) } }
    )

    /// Nooks eigen tools plus de lees-tools van alle koppelingen die aan staan.
    var allTools: [ToolSpec] {
        // Claude via de API zoekt met Anthropic's eigen zoektool; de rest (ook lokaal) met Nooks zoektool.
        let ownSearch = settings.useLocal || settings.provider != .claude
        let webSpecs = settings.webSearch ? web.specs(includeSearch: ownSearch) : []
        return tools.specs + chatTools + connectors.tools + webSpecs
    }
    private(set) lazy var brain = BrainService(settings: settings)

    /// Alles wat Nook kan, ook van koppelingen die nu uit staan: voor het overzicht bij Instellingen › Koppelingen.
    var knownTools: [ToolSpec] {
        tools.specs + chatTools + connectors.hubTools + connectors.sources.flatMap { $0.tools } + web.specs(includeSearch: true)
    }

    /// Tools voor één vraag in de chat: alleen van bronnen die mogen, en elke lees-tool via het grootboek, zodat
    /// zichtbaar is waar Nook keek, wat het opleverde en wat faalde.
    func scopedTools(_ scope: SourceScope, ledger: RetrievalLedger?) -> [ToolSpec] {
        allTools.filter { scope.allowsTool($0.name) }.map { spec in
            // Alleen echte lees-tools van een bron; een grafiek of mailconcept tekenen is geen opzoeken (en mag nooit uit een cache komen).
            guard spec.kind == .read, let ledger, SourceCatalog.source(forTool: spec.name) != nil else { return spec }
            let run = spec.run
            return ToolSpec(
                name: spec.name, description: spec.description, schema: spec.schema, kind: spec.kind,
                summarize: spec.summarize, tag: spec.tag,
                run: { input in
                    let output = try await ledger.run(tool: spec.name, input: input, operation: run)
                    return output
                }
            )
        }
    }

    /// Voorbeelddata in plaats van echte bronnen, handig om de UI te bekijken.
    @Published var demoMode = false
    /// Hoe ver het koppelen van een agent-account is (één klik in de Agents-tab of bij Instellingen).
    /// Per account (`AgentProfile.id`).
    @Published private(set) var agentConnect: [String: AgentConnectProgress] = [:]
    @Published private(set) var loops: [OpenLoop] = []
    @Published private(set) var upcoming: [CalEvent] = []

    var viewModel: NotchViewModel { notch.viewModel }

    private var bag = Set<AnyCancellable>()
    private var hotKeys: [HotKey] = []
    private var watchTimer: Timer?
    private var lastScreenHash: Int?
    private var lastAutoRun = Date.distantPast
    private var autoBusy = false
    /// De vraag kwam via je stem: dan mag het antwoord ook hardop.
    private var spokenRequest = false
    /// Een bestand uit de Shelf waar je net een vraag over stelt.
    private var attachment: (name: String, text: String, date: Date)? {
        didSet { attachmentName = attachment?.name }
    }
    /// Voor het invoerveld: welk bestand er nu meegaat.
    @Published private(set) var attachmentName: String?

    private init() {
        hub.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        nowPlaying.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        connectors.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        codex.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        history.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        profiles.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        // Komt er een account bij of gaat er een af, dan leest de geschiedenis meteen de juiste mappen.
        profiles.$all.removeDuplicates().sink { [weak self] all in
            guard let self else { return }
            self.history.profiles = all
            self.history.refresh(minimumInterval: 0)
        }.store(in: &bag)
        screenContext.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        thinkAlong.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        // Of er een Nook werkt (voor zijn gezicht en de notch in rust); de berichten zelf volgt de chat rechtstreeks.
        chat.$conversations.map { $0.contains { $0.busy } }.removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                if self.viewModel.state.isResting { self.viewModel.show(self.viewModel.state) }
            }
            .store(in: &bag)
    }

    // MARK: Opstarten

    func start() {
        viewModel.app = self
        notch.start(app: self)

        reloadLoops()
        nowPlaying.start()

        // Altijd de nieuwste versie van het hook-script, zodat bestaande koppelingen meegroeien.
        try? HookScript.install()
        hub.recap = recap
        startWorkspace()
        hub.onApproval = { [weak self] request in self?.presentApproval(request) }
        hub.onApprovalGone = { [weak self] id, message in self?.cardGone("approval-" + id, message: message) }
        hub.onQuestion = { [weak self] request in self?.presentQuestion(request) }
        hub.onQuestionGone = { [weak self] id, message in self?.cardGone("question-" + id, message: message) }
        hub.onAttention = { [weak self] session in self?.agentNeedsAttention(session) }
        hub.start()

        // Begint of stopt een agent, dan verandert wat de notch in rust laat zien.
        hub.$sessions
            .map { sessions in sessions.map { "\($0.id)|\($0.status.label)|\($0.approvalID ?? "")" } }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.viewModel.state.isResting else { return }
                self.viewModel.show(self.viewModel.state)
            }
            .store(in: &bag)

        // Wekwoord: alleen luisteren als je het aanzet, en even niet zolang Nook al luistert.
        wake.onWake = { [weak self] in self?.toggleVoice() }
        settings.$wakeWord
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateWakeWord() }
            .store(in: &bag)
        voice.$isListening
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] listening in if !listening { self?.updateWakeWord() } }
            .store(in: &bag)

        // Muziek die begint of stopt, verandert wat de notch in rust laat zien.
        nowPlaying.$current
            .map { $0?.isPlaying == true }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in
                guard let self else { return }
                let vm = self.viewModel
                if playing, case .idle = vm.state {
                    vm.show(.music)
                } else if !playing, vm.state.kind == "music" || vm.state.kind == "track" {
                    vm.show(.idle)
                }
            }
            .store(in: &bag)

        // Een nieuw nummer: de notch zegt even wat er nu speelt.
        nowPlaying.$current
            .compactMap { $0 }
            .removeDuplicates { $0.title == $1.title && $0.artist == $1.artist && $0.app == $1.app }
            .filter(\.isPlaying)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in self?.viewModel.announce(info) }
            .store(in: &bag)

        hotKeys = [
            HotKey(id: 1, keyCode: kVK_Space, modifiers: optionKey) { [weak self] in self?.toggleVoice() },
            HotKey(id: 2, keyCode: kVK_ANSI_N, modifiers: optionKey | cmdKey) { [weak self] in self?.lookAtScreen(manual: true) },
            HotKey(id: 3, keyCode: kVK_Space, modifiers: optionKey | cmdKey) { [weak self] in self?.openAsk() }
        ].compactMap { $0 }

        // Koppelingen: lokaal (agenda, herinneringen, mail, browser, bestanden, klembord) en diensten met een sleutel.
        connectors.register([
            CalendarConnector(calendar: calendar),
            RemindersConnector(calendar: calendar),
            MailConnector(),
            BrowserConnector(),
            FilesConnector(),
            ClipboardConnector()
        ])
        connectors.register(CloudConnectors.makeAll())
        connectors.register([portfolio])
        connectors.start()
        codex.start()

        // Alle schermen live bijhouden, zodat elke vraag meteen weet wat je ziet.
        screenContext.enabled = { [weak self] in self?.settings.liveScreen ?? false }
        settings.$liveScreen
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                guard let self else { return }
                if on && self.screenContext.hasPermission { self.screenContext.start() } else if !on { self.screenContext.stop() }
            }
            .store(in: &bag)

        if !settings.onboardingDone {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.presentWelcome() }
        } else if !settings.autoWatch, !UserDefaults.standard.bool(forKey: "thinkAlongIntro") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.presentThinkAlongIntro() }
        }

        Task { await refreshUpcoming() }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshUpcoming() }
        }

        // Meedenken: elke paar seconden kijken of je lang genoeg met iets bezig bent. Dat kost niets; het brein komt
        // pas in actie als ThinkAlong het moment goed vindt.
        watchTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.thinkAlongTick() }
        }
    }

    // MARK: Gegevens voor de UI

    var agentSessions: [AgentSession] {
        demoMode ? DemoContent.agents : hub.sessions + hub.detected
    }

    /// Gekoppelde agents die nu werken of op je wachten (niet alleen "draait als proces").
    var activeAgents: [AgentSession] {
        agentSessions.filter { !$0.isDetected && ($0.status == .running || $0.status == .waiting || $0.approvalID != nil) }
    }

    var todayItems: [TodayItem] {
        if demoMode { return DemoContent.today }
        var items: [TodayItem] = []

        // Een aanbod van Nook waar je nog niet op reageerde.
        if let missed = missedNudge, Date().timeIntervalSince(missed.date) < 45 * 60 {
            items.append(TodayItem(
                id: "nudge-\(missed.card.id)",
                title: missed.line,
                subtitle: "Ik dacht mee in \(missed.app) · \(NookDates.time(missed.date))",
                action: "Bekijk",
                color: NookTheme.iris,
                target: .action { [weak self] in
                    self?.missedNudge = nil
                    self?.viewModel.show(.card(missed.card))
                }
            ))
        }

        for session in hub.sessions where session.status == .waiting || session.status == .failed {
            let title = session.status == .waiting ? "\(session.name) wacht op je" : "\(session.name) heeft een fout"
            items.append(TodayItem(
                id: "agent-\(session.id)",
                title: title,
                subtitle: session.project,
                action: "Bekijk",
                color: session.status.color,
                target: .agent(session.id)
            ))
        }

        let now = Date()
        if let next = upcoming.first(where: { $0.end > now }), next.start.timeIntervalSince(now) < 3 * 3600 {
            let starting = next.start <= now
            items.append(TodayItem(
                id: "event-\(next.id)",
                title: next.title,
                subtitle: (starting ? "Nu bezig" : "Om \(NookDates.time(next.start))") + (next.location.isEmpty ? "" : " · \(next.location)"),
                action: "Bereid voor",
                color: NookTheme.iris,
                target: .action { [weak self] in
                    self?.handleUserText("Help me voorbereiden op mijn afspraak \"\(next.title)\": wat moet ik weten en wat staat er op mijn schermen dat erbij hoort?")
                }
            ))
        }

        for source in connectors.needingAttention.prefix(2) {
            items.append(TodayItem(
                id: "connector-\(source.id)",
                title: "\(source.title): \(source.status.headline)",
                subtitle: source.status.detail.isEmpty ? (source.status.items.first?.title ?? "") : source.status.detail,
                action: "Bekijk",
                color: NookTheme.amber,
                target: .action { [weak self] in self?.viewModel.show(.panel(.connect)) }
            ))
        }

        if let recapItem = weeklyRecapItem() { items.append(recapItem) }

        for loop in loops.prefix(3) {
            items.append(TodayItem(
                id: "loop-\(loop.id)",
                title: loop.title,
                subtitle: "Open sinds \(NookDates.short(loop.created))",
                action: "Afronden",
                color: NookTheme.amber,
                target: .action { [weak self] in self?.presentLoop(loop) }
            ))
        }
        return Array(items.prefix(5))
    }

    func reloadLoops() {
        loops = store.openLoops()
    }

    private func refreshUpcoming() async {
        guard calendar.hasEventAccess else { return }
        let now = Date()
        upcoming = calendar.events(from: now, to: now.addingTimeInterval(36 * 3600))
    }

    private var settingsWindow: NSWindow?

    /// Eigen venster: de Settings-scene opent niet betrouwbaar in een app zonder Dock-icoon.
    func openSettings(section: SettingsSection? = nil) {
        if let section { settingsSection = section }
        // Het paneel hangt boven alle vensters: blijft het open, dan ligt het over Instellingen en vangt het de klikken.
        if case .panel = viewModel.state { viewModel.show(.idle) }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(self))
            host.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Nook"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 820, height: 600))
            window.minSize = NSSize(width: 720, height: 480)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Vragen aan Nook

    func handleUserText(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Korte vaste opdrachten doet Nook zelf, zonder brein: meteen klaar.
        if let intent = LocalIntent.parse(text) {
            // In de chat blijft het gesprek staan: muziek en tijd beantwoordt Nook daar gewoon.
            if (viewModel.state == .panel(.nook) || viewModel.state == .panel(.chat)), let reply = quickReplyInChat(intent) {
                chat.append(ChatMessage(role: .user, text: text))
                chat.append(ChatMessage(role: .nook, text: reply))
                return
            }
            handleLocalIntent(intent)
            return
        }

        guard settings.brainReady else {
            presentSetupCard()
            return
        }
        ask(text)
    }

    // MARK: Chat

    /// Per Nook het bericht waar hij nu aan schrijft, en de taak die dat doet. Meerdere Nooks kunnen tegelijk werken.
    private var replies: [UUID: UUID] = [:]
    private var chatTasks: [UUID: Task<Void, Never>] = [:]

    /// Opent de chat. `focus`: meteen kunnen typen.
    func showChat(focus: Bool = true) {
        viewModel.focusChat = focus
        viewModel.show(.panel(.chat))
    }

    /// Een nieuwe Nook. Een Nook die nog bezig is, werkt gewoon door.
    func newChat() {
        chat.startNew()
        attachment = nil
        showChat()
    }

    func openConversation(_ id: UUID) {
        chat.select(id)
        showChat()
    }

    /// Stopt de Nook die je nu ziet.
    func stopChat() {
        guard let id = chat.activeID else { return }
        stop(conversation: id)
    }

    private func stop(conversation: UUID) {
        chatTasks[conversation]?.cancel()
        chatTasks[conversation] = nil
        if let id = replies[conversation] {
            chat.update(id) { message in
                message.streaming = false
                message.status = ""
                for index in message.retrieval.indices where message.retrieval[index].outcome == .running {
                    message.retrieval[index].outcome = .failed("gestopt")
                }
                if message.text.isEmpty && message.charts.isEmpty && message.mails.isEmpty && message.actions.isEmpty {
                    message.text = "Gestopt."
                }
            }
        }
        replies[conversation] = nil
        chat.setBusy(false, conversation: conversation)
        spokenRequest = false
    }

    /// Grafieken en mailconcepten die tools tijdens het denken maken, komen bij het antwoord van de Nook die ze maakte.
    private func attachToReply(_ change: (inout ChatMessage) -> Void) {
        let target = ReplyContext.messageID ?? chat.activeID.flatMap { replies[$0] }
        if let id = target, chat.message(id) != nil {
            chat.update(id, change)
        } else {
            var message = ChatMessage(role: .nook, text: "")
            change(&message)
            chat.append(message)
        }
    }

    /// Stelt een vraag in de chat: het antwoord verschijnt terwijl het geschreven wordt.
    private func ask(_ text: String) {
        let conversation = chat.ensureActive()
        if chat.isBusy(conversation) { stop(conversation: conversation) }
        let question = ChatMessage(role: .user, text: text)
        chat.append(question, to: conversation)
        var reply = ChatMessage(role: .nook, text: "")
        reply.streaming = true
        reply.status = settings.useLocal && !EmbeddedModel.shared.isLoaded ? "Lokaal model laden…" : "Even nadenken…"
        chat.append(reply, to: conversation)
        replies[conversation] = reply.id
        chat.setBusy(true, conversation: conversation)
        // De vraag kwam uit een kaart of met je stem: dan het gesprek tonen. Wie al in de chat typt, blijft daar.
        if viewModel.state != .panel(.chat) {
            warmUp()
            showChat()
        }
        let history = chat.history(before: question.id)
        let replyID = reply.id
        chatTasks[conversation] = Task { [weak self] in
            await ReplyContext.$messageID.withValue(replyID) {
                await self?.answer(text, history: history, replyID: replyID, conversation: conversation)
            }
        }
    }

    private func answer(_ text: String, history: [ChatTurn], replyID id: UUID, conversation: UUID, retry: Bool = false) async {
        // Welke bronnen mogen: de bronkiezer van deze Nook, plus wat de vraag zelf zegt ("alleen mijn agenda en mail").
        let requested = SourceScope.parse(text)
        let scope = (chat.conversation(conversation)?.scope ?? .automatic).merged(with: requested)

        // Een vraag over een bestand uit de Shelf, of over wat er op je schermen staat.
        var snapshot: ScreenSnapshot?
        var context: String?
        let screenAllowed = scope.allows(SourceCatalog.screen)
        if let file = attachment, Date().timeIntervalSince(file.date) < 600 {
            attachment = (file.name, file.text, Date())
            chat.update(id) { $0.status = "Ik lees \(file.name)…" }
            let limit = settings.useLocal ? 12_000 : 40_000
            snapshot = ScreenSnapshot(appName: "Bestand", windowTitle: file.name, text: String(file.text.prefix(limit)))
            context = file.name
        } else if screenAllowed, Self.refersToScreen(text) || (settings.screenWithEveryQuestion && screenContext.hasPermission && !settings.useLocal) {
            if screenContext.cachedSnapshot() == nil { chat.update(id) { $0.status = "Ik kijk even mee…" } }
            do {
                snapshot = try await screenSnapshot()
            } catch {
                // Geen schermtoegang: gewoon zonder scherm antwoorden, tenzij de vraag juist over het scherm ging.
                if Self.refersToScreen(text) {
                    finishReply(id, error: error.localizedDescription, conversation: conversation)
                    return
                }
            }
        }
        guard !Task.isCancelled else { return }

        var sources: [String] = []
        if let context { sources.append(context) } else if let snapshot {
            sources.append(snapshot.windowTitle == "alle zichtbare vensters" ? "schermen" : snapshot.windowTitle)
        }

        // Alleen wat voor deze vraag relevant is gaat volledig mee; de rest als één regel.
        var activeIDs = Set(connectors.searchable.map { $0.id })
        activeIDs.insert(SourceCatalog.loops)
        let relevant = SourceRouter.relevant(to: text, scope: scope, active: activeIDs)
        let summary = contextSummary(scope: scope, relevant: relevant)
        let scopeLabel = scope.isRestricted ? scope.label() : ""
        // Vraag je om een grafiek, dan tekent Nook hem; code of JSON in het antwoord hoort daar niet bij.
        let wantsChart = ChartRescue.wantsChart(text)
        chat.update(id) {
            $0.sources = sources
            $0.contextSources = summary.titles
            $0.scopeLabel = scopeLabel
            $0.status = retry ? (wantsChart ? "Ik teken de grafiek…" : "Ik zoek verder…") : "Even nadenken…"
        }

        // Wat Nook opzoekt, verschijnt live boven het antwoord.
        let ledger = RetrievalLedger()
        ledger.onChange = { [weak self, weak ledger] in
            guard let self, let ledger, self.replies[conversation] == id else { return }
            let steps = ledger.steps
            self.chat.update(id) { message in
                message.retrieval = steps
                if let running = steps.last(where: { $0.outcome == .running }), message.text.isEmpty {
                    message.status = "Ik kijk in \(running.sourceTitle)…"
                }
            }
        }
        let tools = scopedTools(scope, ledger: ledger)

        web.note(text)
        if let snapshot { web.note(snapshot.text) }
        web.note(connectors.contextLines(scope: scope, full: relevant).lines.joined(separator: "\n"))

        var request = text
        if retry {
            request += wantsChart
                ? "\n\n(Teken de grafiek nu echt met de tool show_chart, met echte cijfers uit de context, de tools of het web. Schrijf geen code, geen JSON en geen tabel als vervanging.)"
                : "\n\n(Je gaf nog geen antwoord. Bedenk welke bron het antwoord heeft: een gekoppelde bron, een open app (read_app), het scherm, een bestand of het web. Haal het op met de passende tool en beantwoord dan de vraag. Lukt het echt niet, zeg dan kort waar je keek en wat er ontbrak.)"
        }

        do {
            let plan = try await brain.run(
                userText: request,
                followUp: !history.isEmpty,
                history: history,
                context: summary.text,
                untrustedLabel: snapshot.map { "\($0.appName) — \($0.windowTitle)" },
                untrusted: snapshot?.text,
                tools: tools,
                onText: { [weak self] partial in
                    guard let self, self.replies[conversation] == id else { return }
                    var visible = FollowUps.streamingBody(partial)
                    if wantsChart { visible = ChartRescue.hidingChartCode(visible) }
                    self.chat.update(id) { message in
                        message.text = Self.cleanReply(visible)
                        message.status = ""
                    }
                }
            )
            guard !Task.isCancelled, replies[conversation] == id else { return }
            // Wat Nook hierna kan doen, komt als knoppen onder het antwoord.
            let split = FollowUps.split(plan.text)
            var rawBody = split.body

            // Schreef het brein de grafiek als code, JSON of tabel? Dan tekent Nook hem alsnog zelf.
            var rescued: [ChatChart] = []
            let alreadyDrawn = !(chat.message(id)?.charts.isEmpty ?? true)
            if !alreadyDrawn {
                let extracted = ChartRescue.extract(from: rawBody, title: Conversation.title(from: text))
                if !extracted.charts.isEmpty || wantsChart {
                    rawBody = extracted.text
                    rescued = extracted.charts
                }
                if rescued.isEmpty, wantsChart, let table = ChartRescue.chartFromTable(rawBody, title: Conversation.title(from: text)) {
                    rescued = [table]
                }
                // Nog steeds geen grafiek: één keer opnieuw, met de opdracht hem echt te tekenen.
                if rescued.isEmpty, wantsChart, !retry, !settings.useLocal {
                    chat.update(id) { $0.text = ""; $0.status = "Ik teken de grafiek…" }
                    await answer(text, history: history, replyID: id, conversation: conversation, retry: true)
                    return
                }
            }

            // Geen antwoord, geen grafiek, geen concept, geen plan: één keer opnieuw, met de opdracht zelf de bron te zoeken.
            let bare = rawBody.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let nothing = (bare.isEmpty || bare.uppercased() == "NONE") && rescued.isEmpty
                && (chat.message(id)?.charts.isEmpty ?? true) && (chat.message(id)?.mails.isEmpty ?? true) && plan.actions.isEmpty
            if nothing, !retry, !settings.useLocal {
                chat.update(id) { $0.text = ""; $0.status = "Ik zoek verder…" }
                await answer(text, history: history, replyID: id, conversation: conversation, retry: true)
                return
            }

            // Verwijzingen naar bronnen die Nook niet echt ophaalde, gaan eruit.
            let references = ledger.references
            var body = Citations.sanitize(Self.cleanReply(rawBody), valid: Set(references.map(\.number)))
            if plan.actions.isEmpty, body.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).uppercased() == "NONE" {
                body = "Ik vond hier niets over. Zeg erbij waar ik moet kijken?"
            }
            let cited = Citations.used(in: body)
            // Eerst de bronnen waar het antwoord naar verwijst, dan wat verder bekeken werd.
            let shown = references.filter { cited.contains($0.number) } + references.filter { !cited.contains($0.number) }
            var notices = ledger.failures.map { step -> String in
                if case .failed(let error) = step.outcome { return tr("chat.notice.sourceFailed", step.sourceTitle, error) }
                return ""
            }
            if !ledger.failures.isEmpty { notices.append(tr("chat.notice.incomplete")) }
            let actions = plan.actions.map { action -> PlannedAction in
                var copy = action
                if let spec = tools.first(where: { $0.name == action.tool }) { copy.input = ActionGate.normalized(action.input, schema: spec.schema) }
                return copy
            }
            let problems = actions.map { actionProblems($0, scope: scope) }
            chat.update(id) { message in
                message.text = body
                message.charts.append(contentsOf: rescued)
                message.retrieval = ledger.steps
                message.references = Array(shown.prefix(12))
                message.notices = notices.filter { !$0.isEmpty }
                message.actions = actions
                message.actionStates = Array(repeating: .pending, count: actions.count)
                message.actionIncluded = Array(repeating: true, count: actions.count)
                message.actionProblems = problems
                message.offers = split.offers
                message.streaming = false
                message.status = ""
                if body.isEmpty && message.charts.isEmpty && message.mails.isEmpty && plan.actions.isEmpty {
                    message.text = wantsChart
                        ? "Ik vond geen cijfers om een grafiek van te maken. Zeg erbij waar ik moet kijken?"
                        : "Daar heb ik geen antwoord op. Probeer het anders te vragen?"
                }
            }
            if let message = chat.message(id) {
                let spoken = !message.text.isEmpty ? message.text
                    : (!message.mails.isEmpty ? "Ik heb een mail voor je klaargezet." : (!message.charts.isEmpty ? "Hier is je grafiek." : "Ik heb een plan klaargezet."))
                speakIfAsked(spoken)
            }
            replies[conversation] = nil
            chatTasks[conversation] = nil
            chat.setBusy(false, conversation: conversation)
            nookFinished(conversation)
            // Kleine dingen waar je zelf om vroeg, doet Nook meteen als je dat aanzette (alleen als alles klopt).
            if canRunWithoutAsking(plan), problems.allSatisfy(\.isEmpty) { runPlan(id) }
        } catch {
            guard !Task.isCancelled, replies[conversation] == id else { return }
            finishReply(id, error: error.localizedDescription, conversation: conversation)
        }
    }

    private func finishReply(_ id: UUID, error: String, conversation: UUID) {
        chat.update(id) { message in
            message.streaming = false
            message.status = ""
            if message.text.isEmpty {
                message.text = error
                message.isError = true
            } else {
                message.text += "\n\n_\(error)_"
            }
        }
        replies[conversation] = nil
        chatTasks[conversation] = nil
        spokenRequest = false
        chat.setBusy(false, conversation: conversation)
    }

    /// Een Nook is klaar terwijl je naar iets anders keek: hij laat het even weten.
    private func nookFinished(_ id: UUID) {
        let watching = viewModel.state == .panel(.chat) && chat.activeID == id
        guard !watching, let conversation = chat.conversation(id) else { return }
        chat.markUnread(id)
        let token = "nookdone-" + UUID().uuidString
        viewModel.register("\(token)#open") { [weak self] in self?.openConversation(id) }
        let preview = conversation.preview.isEmpty ? tr("nooks.finishedFallback") : conversation.preview
        let lines = max(1, min(3, Int(ceil(Double(preview.count) / 46.0))))
        let card = NookCard(
            id: token,
            mood: .done,
            context: tr("nooks.finished", conversation.title),
            title: preview,
            detail: .none,
            primary: CardAction(label: tr("nooks.view"), outcome: .callback("\(token)#open", "")),
            secondary: CardAction(label: tr("nooks.later"), outcome: .dismiss),
            contentHeight: 100 + CGFloat(lines) * 24
        )
        viewModel.present(card)
    }

    /// Haalt resten van tool-aanroepen en losse backslashes uit een antwoord.
    private static func cleanReply(_ text: String) -> String {
        var cleaned = text
        // Een denkblok of tool-aanroep als tekst hoort niet in de chat.
        cleaned = cleaned.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(?m)^\s*\{\s*"(name|tool)"\s*:.*\}\s*$"#, with: "", options: .regularExpression)
        return MarkdownBlock.clean(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// De regels van een plan, zoals ze in de chat en op een kaart staan.
    func planSteps(_ actions: [PlannedAction]) -> [PlanStep] {
        actions.enumerated().map { index, action in
            let spec = allTools.first { $0.name == action.tool }
            let tag = spec?.tag(action.input) ?? ("", .neutral)
            return PlanStep(number: index + 1, text: spec?.summarize(action.input) ?? action.tool, tag: tag.0, tone: tag.1)
        }
    }

    /// Wat er mis is met een voorgestelde actie: de tool bestaat niet (meer), de bron mag niet, of de invoer klopt niet.
    func actionProblems(_ action: PlannedAction, scope: SourceScope) -> [String] {
        guard let spec = allTools.first(where: { $0.name == action.tool }), spec.kind == .action else {
            return [tr("chat.plan.unavailable", action.tool)]
        }
        guard scope.allowsTool(action.tool) else {
            return [tr("chat.plan.notAllowed", SourceCatalog.source(forTool: action.tool).map(SourceCatalog.title) ?? action.tool)]
        }
        return ActionGate.problems(tool: action.tool, input: action.input, schema: spec.schema, parseDate: NookDates.parse)
    }

    /// Voert de stappen uit die aan staan. Opnieuw aanroepen na een fout gaat verder waar het bleef: wat al lukte, gebeurt
    /// nooit nog een keer. `force`: stappen die toch mogen, ook al lijken ze kort geleden al uitgevoerd.
    func runPlan(_ id: UUID, force: Set<Int> = []) {
        guard let message = chat.message(id), !message.actions.isEmpty, message.planState != .running, message.planState != .cancelled else { return }
        if case .done = message.planState, force.isEmpty { return }
        let scope = chat.conversationID(of: id).flatMap { chat.conversation($0)?.scope } ?? .automatic
        let steps = message.actions.map { PlanRunner.Step(tool: $0.tool, input: $0.input) }
        store.audit(tool: "plan_goedgekeurd", args: planSteps(message.actions).enumerated()
            .filter { index, _ in index < message.actionIncluded.count ? message.actionIncluded[index] : true }
            .map(\.element.text).joined(separator: " | "), result: "")
        chat.update(id) { $0.planState = .running }
        let runner = planRunner(scope: scope) { [weak self] states in
            self?.chat.update(id) { $0.actionStates = states }
        }
        Task {
            let states = await runner.run(steps, states: message.actionStates, include: message.actionIncluded, force: force)
            reloadLoops()
            await refreshUpcoming()
            chat.update(id) { message in
                message.actionStates = states
                message.planState = Self.planOutcome(states)
            }
        }
    }

    /// Eén regel over hoe een plan afliep.
    static func planOutcome(_ states: [ActionStepState]) -> ChatMessage.PlanState {
        var done: [String] = []
        var failure: String?
        for (index, state) in states.enumerated() {
            switch state {
            case .done(let result): done.append(result)
            case .failed(let error): failure = failure ?? tr("chat.plan.stepFailed", index + 1, error)
            case .duplicate: failure = failure ?? tr("chat.plan.duplicateHint")
            default: break
            }
        }
        if let failure {
            return .failed(done.isEmpty ? failure : tr("chat.plan.partial", done.count, states.count, failure))
        }
        if done.isEmpty { return .done(tr("chat.plan.nothingRun")) }
        return .done(done.count == 1 ? done[0] : tr("chat.plan.allDone", done.count))
    }

    private func planRunner(scope: SourceScope, progress: @escaping ([ActionStepState]) -> Void = { _ in }) -> PlanRunner {
        PlanRunner(
            check: { [weak self] step in
                guard let self else { return ["Nook is niet beschikbaar."] }
                return self.actionProblems(PlannedAction(tool: step.tool, input: step.input), scope: scope)
            },
            execute: { [weak self] step in
                guard let self, let spec = self.allTools.first(where: { $0.name == step.tool }), spec.kind == .action else {
                    throw NookError(tr("chat.plan.unavailable", step.tool))
                }
                let args = Self.json(step.input)
                do {
                    let result = try await spec.run(step.input)
                    self.store.audit(tool: step.tool, args: args, result: result)
                    return result
                } catch {
                    self.store.audit(tool: step.tool, args: args, result: "FOUT: \(error.localizedDescription)")
                    throw error
                }
            },
            executedBefore: { [weak self] key in self?.store.executedAction(key, within: ActionGate.duplicateWindow) },
            recordExecuted: { [weak self] key, step, result in self?.store.recordExecuted(key, tool: step.tool, result: result) },
            progress: progress
        )
    }

    func cancelPlan(_ id: UUID) {
        store.audit(tool: "plan_geannuleerd", args: chat.message(id).map { planSteps($0.actions).map(\.text).joined(separator: " | ") } ?? "", result: "")
        chat.update(id) { $0.planState = .cancelled }
    }

    /// Een stap aan- of uitzetten voordat je uitvoert.
    func setActionIncluded(_ id: UUID, index: Int, _ on: Bool) {
        chat.update(id) { message in
            guard index < message.actionIncluded.count, message.actionStates[safe: index]?.isFinished != true || !on else { return }
            message.actionIncluded[index] = on
        }
    }

    /// De gebruiker past een voorstel aan (bijvoorbeeld de tekst van een bericht). Wordt meteen opnieuw gecontroleerd.
    func editAction(_ id: UUID, index: Int, key: String, value: String) {
        guard let message = chat.message(id), index < message.actions.count else { return }
        if case .done = message.actionStates[safe: index] ?? .pending { return }
        let scope = chat.conversationID(of: id).flatMap { chat.conversation($0)?.scope } ?? .automatic
        var action = message.actions[index]
        action.input[key] = value
        if let spec = allTools.first(where: { $0.name == action.tool }) {
            action.input = ActionGate.normalized(action.input, schema: spec.schema)
        }
        let problems = actionProblems(action, scope: scope)
        chat.update(id) { message in
            message.actions[index] = action
            if index < message.actionProblems.count { message.actionProblems[index] = problems }
        }
    }

    /// De volledige invoer van een stap, voor het overzicht vóór Uitvoeren.
    func actionFields(_ action: PlannedAction) -> [ActionField] {
        let schema = allTools.first { $0.name == action.tool }?.schema ?? [:]
        return ActionGate.fields(action.input, schema: schema)
    }

    // MARK: Bronnen in de chat

    func scope(of conversation: UUID?) -> SourceScope {
        conversation.flatMap { chat.conversation($0)?.scope } ?? .automatic
    }

    func setScope(_ scope: SourceScope) {
        let id = chat.ensureActive()
        chat.setScope(scope, conversation: id)
    }

    /// Opent een bron uit een antwoord, alleen als het een veilige link is (https, een bestand in je eigen map, een mail).
    func openReference(_ reference: SourceReference) {
        guard SourceReference.isOpenable(reference.url), let raw = reference.url, let url = URL(string: raw) else { return }
        if url.isFileURL, !FileText.isAllowed(url) { return }
        NSWorkspace.shared.open(url)
    }

    /// Stelt de laatste vraag van deze Nook opnieuw.
    func retryLast() {
        guard let id = chat.activeID, let question = chat.lastQuestion(in: id) else { return }
        ask(question)
    }

    /// Kies een bestand om mee te sturen (zoals slepen naar de Shelf).
    func attachFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileText.isAllowed(url) else {
            viewModel.show(.card(errorCard(tr("chat.attach.notAllowed"))))
            return
        }
        askAbout(url)
    }

    func clearAttachment() {
        attachment = nil
    }

    func sendMail(_ draft: MailDraft) {
        chat.updateMail(draft.id) { $0 = draft; $0.state = .sending }
        Task {
            do {
                try await MailSender.deliver(draft, send: true)
                store.audit(tool: "send_mail", args: "\(draft.to) · \(draft.subject)", result: "verstuurd")
                chat.updateMail(draft.id) { $0.state = .sent }
            } catch {
                chat.updateMail(draft.id) { $0.state = .failed(error.localizedDescription) }
            }
        }
    }

    func openMail(_ draft: MailDraft) {
        chat.updateMail(draft.id) { $0 = draft }
        Task {
            do {
                try await MailSender.deliver(draft, send: false)
                chat.updateMail(draft.id) { $0.state = .opened }
            } catch {
                chat.updateMail(draft.id) { $0.state = .failed(error.localizedDescription) }
            }
        }
    }

    /// De tekst van al je vensters: uit de live cache als die aan staat, anders nu even alles lezen.
    func screenSnapshot() async throws -> ScreenSnapshot {
        let local = settings.useLocal
        if settings.liveScreen {
            if !screenContext.isRunning, screenContext.hasPermission { screenContext.start() }
            return try await screenContext.snapshot(totalLimit: local ? 3500 : 12_000)
        }
        return try await screen.captureAll(maxWindows: local ? 3 : 6, totalLimit: local ? 3500 : 9000)
    }

    /// Woorden en zinnen waaruit blijkt dat het verzoek over iets op het scherm gaat.
    private static let screenCue = try? NSRegularExpression(
        pattern: #"\b(hier\w*|dit|deze|daar\w*|erbij|ervoor|ervan|erover|scherm|kijk mee|lees mee)\b|\ber\b.{0,25}\b(afspraak|herinnering|taak|mail|punt|agenda)\b"#,
        options: [.caseInsensitive]
    )

    static func refersToScreen(_ text: String) -> Bool {
        guard let screenCue else { return false }
        return screenCue.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // Het gesprek van zojuist, zodat een vervolgvraag ("ja, doe maar") begrepen wordt.
    private var recentExchanges: [(date: Date, user: String, nook: String)] = []

    private var isFollowUp: Bool {
        guard let last = recentExchanges.last else { return false }
        return Date().timeIntervalSince(last.date) < 180
    }

    private func remember(user: String, nook: String) {
        recentExchanges.append((Date(), user, nook))
        recentExchanges = recentExchanges.suffix(3).filter { Date().timeIntervalSince($0.date) < 900 }
    }

    private func runBrain(userText: String, snapshot: ScreenSnapshot?, silentIfNone: Bool, context: String?) async {
        let followUp = isFollowUp && !silentIfNone
        var sources: [String] = []
        if let snapshot { sources.append(snapshot.windowTitle == "alle zichtbare vensters" ? "schermen" : snapshot.windowTitle) }
        sources.append(contentsOf: connectors.contributingTitles.prefix(4))
        lastSources = sources
        // Adressen die de gebruiker ziet of noemt, mag het brein openen (en alleen die, plus zoekresultaten).
        web.note(userText)
        if let snapshot { web.note(snapshot.text) }
        web.note(connectors.contextLines().joined(separator: "\n"))
        do {
            var plan = try await brain.run(
                userText: userText,
                followUp: followUp,
                context: contextSummary(),
                untrustedLabel: snapshot.map { "\($0.appName) — \($0.windowTitle)" },
                untrusted: snapshot?.text,
                tools: allTools,
                onText: silentIfNone ? nil : { [weak self] text in self?.showStreaming(text, sources: sources) }
            )
            // Wat Nook hierna kan doen, komt als knoppen onder het antwoord.
            let split = FollowUps.split(plan.text)
            plan.text = split.body

            let bare = plan.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).uppercased()
            if plan.actions.isEmpty && bare == "NONE" {
                if silentIfNone {
                    viewModel.dismissCard(id: "thinking")
                } else {
                    replaceThinking(with: answerCard("Ik zie niets waar je iets aan hebt."))
                }
                return
            }

            // Kleine dingen waar je zelf om vroeg, doet Nook meteen als je dat aanzette.
            if !silentIfNone, canRunWithoutAsking(plan) {
                remember(user: userText, nook: plan.text.isEmpty ? "(meteen uitgevoerd)" : plan.text)
                speakIfAsked(plan.text.isEmpty ? "Gedaan." : plan.text)
                viewModel.removePending(id: "thinking")
                execute(plan)
                return
            }

            if !silentIfNone {
                remember(user: userText, nook: plan.text.isEmpty ? "(acties voorgesteld, wachten op goedkeuring)" : plan.text)
                speakIfAsked(plan.text.isEmpty ? "Ik heb een plan klaargezet." : plan.text)
            }
            var card = planCard(plan, context: context, offers: split.offers)
            card.sources = sources
            if silentIfNone {
                viewModel.present(card)
            } else {
                replaceThinking(with: card)
            }
        } catch {
            if !silentIfNone {
                spokenRequest = false
                replaceThinking(with: errorCard(error.localizedDescription))
            }
        }
    }

    private var lastSources: [String] = []
    private var streamedLines = 0

    /// Het antwoord verschijnt terwijl het geschreven wordt. Groeit de tekst een regel, dan groeit de kaart mee.
    private func showStreaming(_ text: String, sources: [String]) {
        let body = FollowUps.streamingBody(text)
        guard !body.isEmpty else { return }
        guard case .card(let shown) = viewModel.state, shown.id == "thinking" else { return }
        let lines = min(9, max(1, Int(ceil(Double(body.count) / (body.count > 140 ? 62.0 : 46.0)))))
        var card = shown
        card.title = String(body.prefix(4000))
        card.context = "Nook"
        card.sources = sources
        card.contentHeight = max(shown.contentHeight, 110 + CGFloat(lines) * (body.count > 140 ? 21 : 24))
        if card.contentHeight != shown.contentHeight {
            viewModel.show(.card(card))
        } else {
            viewModel.updateCard(card)
        }
    }

    private func speakIfAsked(_ text: String) {
        defer { spokenRequest = false }
        guard spokenRequest, settings.speakAnswers else { return }
        speech.speak(text, language: settings.language)
    }

    private func replaceThinking(with card: NookCard) {
        if case .card(let shown) = viewModel.state, shown.id == "thinking" {
            viewModel.show(.card(card))
        } else {
            // Een vraag van een agent kan het denkkaartje opzij hebben gezet: dat hoeft niet meer terug.
            viewModel.removePending(id: "thinking")
            viewModel.present(card)
        }
    }

    private func contextSummary() -> String {
        contextSummary(scope: .automatic, relevant: nil).text
    }

    /// De context voor het brein. `relevant` nil = alles volledig (kaarten in de notch); anders gaan alleen relevante bronnen
    /// volledig mee en de rest als één regel. Wat de gebruiker uitsloot, gaat helemaal niet mee.
    private func contextSummary(scope: SourceScope, relevant: Set<String>?) -> (text: String, titles: [String]) {
        let now = Date()
        var lines = ["Nu: \(NookDates.long(now))"]

        if relevant != nil {
            lines.append("Bronnen voor deze vraag:")
            lines.append("- Keuze: \(scope.label())")
            if !scope.excluded.isEmpty || scope.mode == .only {
                let blocked = SourceCatalog.all.filter { !scope.allows($0.id) }.map { $0.title }
                lines.append("- Niet gebruiken (keuze van de gebruiker): " + blocked.joined(separator: ", "))
            }
            if !scope.focus.isEmpty {
                lines.append("- Genoemd door de gebruiker, kijk daar zeker: " + scope.focus.map(SourceCatalog.title).sorted().joined(separator: ", "))
            }
            let unavailable = connectors.sources.filter { !$0.isActive && !$0.canLookUp && scope.allows($0.id) }.map { $0.title }
            if !unavailable.isEmpty { lines.append("- Niet gekoppeld of uit: " + unavailable.joined(separator: ", ")) }
            // Elke open app is ook een bron: zonder koppeling leest read_app wat erin staat.
            if scope.allows(SourceCatalog.screen) {
                let apps = ScreenReader.openApps().compactMap(\.localizedName).sorted()
                if !apps.isEmpty { lines.append("- Open apps (lees er een met read_app; dat kan ook met apps die dicht zijn): " + apps.joined(separator: ", ")) }
            }
        }

        // Agenda (vanaf het begin van vandaag), herinneringen, mail, browser, diensten: alles uit de cache van de koppelingen.
        if scope.allows("calendar"), !connectors.active.contains(where: { $0.id == "calendar" }) {
            lines.append(calendar.hasEventAccess ? "Agenda: staat uit bij Koppelingen." : "Agenda: geen toegang.")
        }
        let sourceContext = connectors.contextLines(scope: scope, full: relevant)
        lines.append(contentsOf: sourceContext.lines)

        if !recentExchanges.isEmpty {
            lines.append("Gesprek zojuist (voor vervolgvragen):")
            for exchange in recentExchanges {
                lines.append("- Gebruiker: \(exchange.user.prefix(200)) | Nook: \(exchange.nook.prefix(200))")
            }
        }

        if !loops.isEmpty, scope.allows(SourceCatalog.loops) {
            lines.append("Open punten (id tussen haken, voor complete_open_loop):")
            for loop in loops.prefix(10) { lines.append("- \(loop.title) [\(loop.id.prefix(8))]") }
        }

        let sessions = hub.sessions
        if !sessions.isEmpty {
            lines.append("Draaiende agents:")
            for session in sessions { lines.append("- \(session.name) (\(session.project)): \(session.status.label)") }
        }

        if let playing = nowPlaying.current {
            lines.append("Speelt nu: \(playing.title) – \(playing.artist)")
        }

        if let usage = hub.planUsage {
            lines.append("Claude-abonnement gebruikt: \(usage.label)" + (usage.resetLabel.map { " (\($0))" } ?? ""))
        }
        if let codexLine = codex.contextLine { lines.append(codexLine) }
        return (lines.joined(separator: "\n"), sourceContext.fullTitles)
    }

    // MARK: Plan en uitvoeren

    private func planCard(_ plan: BrainPlan, context: String?, offers: [String] = []) -> NookCard {
        guard !plan.actions.isEmpty else { return answerCard(plan.text, offers: offers) }

        let token = "plan-" + UUID().uuidString
        let title = plan.text.isEmpty ? "Zo regel ik het:" : String(plan.text.prefix(160))
        let titleLines = max(1, Int(ceil(Double(title.count) / 46.0)))

        let steps = planSteps(plan.actions)

        var detail: CardDetail = .steps(steps)
        var detailHeight = CGFloat(steps.count * 30)
        var contextLine = context ?? "Plan · \(steps.count) \(steps.count == 1 ? "stap" : "stappen")"
        var primaryLabel = "Uitvoeren"

        if plan.actions.count == 1, plan.actions[0].tool == "create_event",
           let start = NookTools.parseDate(plan.actions[0].input, "start") {
            let input = plan.actions[0].input
            let end = NookTools.parseDate(input, "end") ?? start.addingTimeInterval(3600)
            let location = (input["location"] as? String) ?? ""
            detail = .event(
                top: NookDates.weekdayCaps(start),
                big: NookDates.dayNumber(start),
                line: "\(NookDates.time(start)) – \(NookDates.time(end))" + (location.isEmpty ? "" : " · \(location)"),
                subline: "Agenda · \((input["title"] as? String) ?? "Afspraak")"
            )
            detailHeight = 36
            contextLine = context ?? "Voorstel"
            primaryLabel = "Toevoegen"
        }

        viewModel.register("\(token)#run") { [weak self] in self?.execute(plan) }

        let cancel = CardAction(label: "Annuleren", outcome: .dismiss)
        return NookCard(
            id: token,
            mood: .think,
            context: contextLine,
            title: title,
            detail: detail,
            primary: CardAction(label: primaryLabel, outcome: .callback("\(token)#run", "")),
            secondary: cancel,
            contentHeight: min(440, 100 + CGFloat(titleLines) * 24 + detailHeight + (offers.isEmpty ? 0 : 40)),
            offers: offers,
            escape: cancel
        )
    }

    /// Acties die Nook zonder vragen mag doen als je "Kleine dingen meteen doen" aanzette: makkelijk terug te draaien
    /// en zonder gevolgen voor anderen. Afspraken, mail, links, opdrachten en diensten vragen altijd eerst.
    static let safeTools: Set<String> = ["media_control", "set_volume", "open_app", "add_open_loop", "create_reminder", "complete_open_loop"]

    private func canRunWithoutAsking(_ plan: BrainPlan) -> Bool {
        settings.autoRunSafe && !plan.actions.isEmpty && plan.actions.allSatisfy { Self.safeTools.contains($0.tool) }
    }

    private func execute(_ plan: BrainPlan) {
        Task {
            let outcome = await perform(plan.actions)
            if let failure = outcome.failure {
                viewModel.present(errorCard(failure))
            } else if outcome.results.count == 1 {
                viewModel.finish(outcome.results[0])
            } else {
                viewModel.finish("\(outcome.results.count) acties uitgevoerd")
            }
        }
    }

    /// Voert goedgekeurde acties uit, één voor één; stopt bij de eerste fout. Alles komt in het logboek.
    /// Dezelfde controle als in de chat: een tool die niet (meer) bestaat of foute invoer wordt niet stilletjes overgeslagen
    /// maar meldt een fout, en een actie die kort geleden al lukte gebeurt niet nog een keer.
    private func perform(_ actions: [PlannedAction]) async -> (results: [String], failure: String?) {
        let steps = actions.map { PlanRunner.Step(tool: $0.tool, input: $0.input) }
        let states = await planRunner(scope: .automatic).run(steps, states: [], include: Array(repeating: true, count: steps.count))
        reloadLoops()
        await refreshUpcoming()
        var results: [String] = []
        for state in states { if case .done(let result) = state { results.append(result) } }
        if case .failed(let failure) = Self.planOutcome(states) { return (results, failure) }
        return (results, nil)
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: Spraak

    /// Maakt de volgende vraag sneller: zet de verbinding open of laadt het lokale model alvast.
    func warmUp() {
        if settings.useLocal {
            EmbeddedModel.shared.preload(settings.localModel)
        } else {
            brain.prewarm()
        }
    }

    func toggleVoice() {
        if voice.isListening {
            voice.finishNow()
            return
        }
        guard settings.brainReady else {
            presentSetupCard()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            guard await voice.requestPermissions() else {
                viewModel.present(errorCard("Nook mag nog niet luisteren. Zet de microfoon en spraakherkenning aan bij Systeminstellingen › Privacy en beveiliging."))
                return
            }
            warmUp()
            wake.stop()
            speech.stop()
            viewModel.register("listening#done") { [weak self] in self?.voice.finishNow() }
            viewModel.register("listening#cancel") { [weak self] in self?.voice.cancel() }
            viewModel.show(.card(listeningCard("")))
            do {
                try voice.start(
                    onPartial: { [weak self] text in
                        guard let self else { return }
                        self.viewModel.updateCard(self.listeningCard(text))
                    },
                    onFinish: { [weak self] text in self?.voiceFinished(text) }
                )
            } catch {
                viewModel.show(.card(errorCard(error.localizedDescription)))
            }
        }
    }

    private func voiceFinished(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            viewModel.dismissCard(id: "listening")
        } else {
            spokenRequest = true
            handleUserText(trimmed)
        }
    }

    private func updateWakeWord() {
        guard settings.wakeWord else {
            wake.stop()
            return
        }
        guard !voice.isListening, !wake.isRunning else { return }
        do {
            try wake.start()
        } catch {
            settings.wakeWord = false
            viewModel.present(errorCard(error.localizedDescription))
        }
    }

    private func listeningCard(_ text: String) -> NookCard {
        NookCard(
            id: "listening",
            mood: .listen,
            context: "Ik luister, praat gerust",
            title: text.isEmpty ? "Zeg het maar…" : "“\(text)”",
            detail: .waveform,
            primary: CardAction(label: "Klaar", outcome: .callback("listening#done", "")),
            secondary: CardAction(label: "Annuleren", outcome: .callback("listening#cancel", "")),
            contentHeight: 166
        )
    }

    // MARK: Meekijken

    func lookAtScreen(manual: Bool) {
        guard settings.brainReady else {
            if manual { presentSetupCard() }
            return
        }
        if manual {
            viewModel.show(.card(thinkingCard(context: "Ik kijk even mee…", title: "Ik lees wat er op je scherm staat.")))
        }
        Task {
            do {
                let snapshot = try await screen.capture()
                let hash = snapshot.text.hashValue
                if !manual {
                    if hash == lastScreenHash { return }
                }
                lastScreenHash = hash
                await runBrain(
                    userText: "Dit is wat de gebruiker nu op het scherm heeft. Zie je iets waar je hem mee kunt helpen, zoals een afspraak, een belofte of een taak? Stel dan een passende actie voor. Zo niet: NONE.",
                    snapshot: snapshot,
                    silentIfNone: !manual,
                    context: "Ik zag in \(snapshot.appName)"
                )
            } catch {
                if manual { replaceThinking(with: errorCard(error.localizedDescription)) }
            }
        }
    }

    // MARK: Meedenken

    /// Een aanbod waar je nog niet op reageerde; staat een tijdje in Vandaag.
    @Published private var missedNudge: (line: String, card: NookCard, app: String, date: Date)?

    /// Ben je een tijdje met iets bezig, dan kijkt Nook even mee en biedt hij hulp aan als hij echt iets kan doen.
    private func thinkAlongTick() {
        guard settings.autoWatch, !settings.useLocal, settings.brainReady, !autoBusy, !demoMode,
              CGPreflightScreenCaptureAccess(), viewModel.state.isResting else { return }
        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundle = frontApp?.bundleIdentifier ?? ""
        // Venstertitel en inhoud uit de live cache; zonder cache telt alleen de app en kijkt Nook hooguit eens per vijf minuten.
        let front = screenContext.windows.first { $0.isFront && $0.bundleID == bundle }
        let window = front?.title ?? ""
        let print = front?.fingerprint ?? UInt64(Date().timeIntervalSince1970 / 300)
        guard thinkAlong.shouldLook(bundleID: bundle, window: window, print: print) else { return }
        thinkAlong.didLook(bundleID: bundle, window: window, print: print)

        autoBusy = true
        lastAutoRun = Date()
        let appName = frontApp?.localizedName ?? "deze app"
        Task {
            await thinkAlongRun(bundleID: bundle, appName: appName, window: window)
            autoBusy = false
        }
    }

    private func thinkAlongRun(bundleID: String, appName: String, window: String) async {
        guard let snapshot = try? await screenSnapshot() else { return }
        var request = """
        [Meedenken] De gebruiker is nu bezig in \(appName)\(window.isEmpty ? "" : " (venster: \(window.prefix(80)))"). \
        Je kijkt ongevraagd mee. Is er één concreet ding dat jij nu voor hem kunt overnemen met een actie-tool (iets inplannen, \
        een herinnering of open punt, een concept schrijven, een app of link openen), of weet je een duidelijk slimmere of snellere \
        aanpak voor wat hij nu doet? Roep bij een actie meteen de tool aan. Begin je tekst met één korte vraag of tip van hooguit \
        acht woorden, zoals "Zal ik dit in je agenda zetten?" of "Tip: dit kan ook in één keer", daarna hooguit twee zinnen uitleg. \
        Alleen als het hem echt tijd scheelt of voorkomt dat hij iets vergeet; samenvattingen, complimenten of wat hij al doet tellen niet. \
        Twijfel je, antwoord dan alleen NONE.
        """
        let earlier = thinkAlong.recentOffers
        if !earlier.isEmpty {
            request += " Dit bood je onlangs al aan, herhaal het niet: " + earlier.joined(separator: "; ") + "."
        }
        web.note(snapshot.text)

        guard let plan = try? await brain.run(
            userText: request,
            context: contextSummary(),
            untrustedLabel: "\(snapshot.appName) — \(snapshot.windowTitle)",
            untrusted: snapshot.text,
            tools: allTools
        ) else { return }

        let split = FollowUps.split(plan.text)
        var body = split.body
        let bare = body.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).uppercased()
        if bare == "NONE" || bare.hasPrefix("NONE") { body = "" }
        guard !body.isEmpty || !plan.actions.isEmpty else { return }

        let line = Self.nudgeLine(body: body, fallback: planSteps(plan.actions).first.map { "Zal ik dit doen? \($0.text)" })
        guard !line.isEmpty, !thinkAlong.alreadyOffered(line) else { return }

        let offer = BrainPlan(text: body, actions: plan.actions)
        let card = nudgeCard(offer, offers: split.offers, bundleID: bundleID, appName: appName)
        guard viewModel.offerNudge(line, card: card) else { return }
        thinkAlong.didOffer(line)
        missedNudge = (line, card, appName, Date())
        remember(user: "(Nook keek ongevraagd mee in \(appName))", nook: body.isEmpty ? line : body)
    }

    /// De korte zin naast de notch: de eerste zin van het aanbod, hooguit zo'n zestig tekens.
    private static func nudgeLine(body: String, fallback: String?) -> String {
        let first = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var line = first
        if let end = first.firstIndex(where: { $0 == "?" || $0 == "." || $0 == "!" }) {
            line = String(first[...end])
        }
        line = line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        if line.isEmpty { line = fallback ?? "" }
        return line.count > 64 ? String(line.prefix(62)) + "…" : line
    }

    /// Het hele aanbod: wat Nook zag, wat hij wil doen, en "Doe maar", "Nee" of "Niet in deze app".
    private func nudgeCard(_ plan: BrainPlan, offers: [String], bundleID: String, appName: String) -> NookCard {
        let token = "nudge-" + UUID().uuidString
        viewModel.register("\(token)#yes") { [weak self] in
            guard let self else { return }
            self.thinkAlong.accepted()
            self.missedNudge = nil
            if !plan.actions.isEmpty { self.execute(plan) }
        }
        viewModel.register("\(token)#no") { [weak self] in
            self?.thinkAlong.declined()
            self?.missedNudge = nil
        }
        viewModel.register("\(token)#mute") { [weak self] in
            self?.thinkAlong.mute(bundleID: bundleID, name: appName)
            self?.missedNudge = nil
        }

        let steps = planSteps(plan.actions)
        let title = plan.text.isEmpty ? "Zal ik dit voor je doen?" : String(plan.text.prefix(600))
        let long = title.count > 140
        let lines = min(8, max(1, Int(ceil(Double(title.count) / (long ? 62.0 : 46.0)))))
        var height = 150 + CGFloat(lines) * (long ? 21 : 24)
        if !steps.isEmpty { height += CGFloat(steps.count * 30) + 14 }
        if !offers.isEmpty { height += 40 }

        let no = CardAction(label: "Nee", outcome: .callback("\(token)#no", ""))
        return NookCard(
            id: token,
            mood: .seen,
            context: "Ik dacht mee",
            title: title,
            detail: steps.isEmpty ? .none : .steps(steps),
            primary: CardAction(label: plan.actions.isEmpty ? "Handig" : "Doe maar", outcome: .callback("\(token)#yes", "")),
            secondary: no,
            contentHeight: min(470, height),
            input: true,
            extra: [CardAction(label: "Niet in deze app", outcome: .callback("\(token)#mute", "Ik denk niet meer mee in \(appName)"))],
            sources: [appName],
            offers: offers,
            escape: no
        )
    }

    /// Eén keer na de update: vertellen dat Nook kan meedenken en kleine dingen zelf kan doen.
    func presentThinkAlongIntro() {
        guard settings.brainReady, !settings.useLocal, !settings.autoWatch else { return }
        UserDefaults.standard.set(true, forKey: "thinkAlongIntro")
        let token = "thinkintro"
        viewModel.register("\(token)#all") { [weak self] in
            self?.settings.autoWatch = true
            self?.settings.autoRunSafe = true
        }
        viewModel.register("\(token)#watch") { [weak self] in self?.settings.autoWatch = true }
        let facts = [
            Fact(label: "meedenken", value: "ik bied zelf hulp aan"),
            Fact(label: "kleine dingen zelf doen", value: "muziek, volume, apps"),
            Fact(label: "altijd eerst vragen", value: "agenda, mail, links"),
            Fact(label: "uitzetten", value: "Instellingen › Assistent")
        ]
        let card = NookCard(
            id: token,
            mood: .seen,
            context: "Nieuw in Nook",
            title: "Zal ik meedenken terwijl je werkt? Zie ik iets wat ik voor je kan doen, dan bied ik het aan.",
            detail: .facts(facts),
            primary: CardAction(label: "Zet aan", outcome: .callback("\(token)#all", "Ik denk vanaf nu mee")),
            secondary: CardAction(label: "Later", outcome: .dismiss),
            contentHeight: 150 + 2 * 44 + 24,
            extra: [CardAction(label: "Alleen meedenken", outcome: .callback("\(token)#watch", "Ik denk vanaf nu mee"))],
            escape: CardAction(label: "Later", outcome: .dismiss)
        )
        viewModel.present(card)
    }

    // MARK: Agents

    private func presentApproval(_ request: ApprovalRequest) {
        let token = "approval-" + request.id
        let danger = request.assessment.level == .danger
        let id = request.id

        viewModel.register("\(token)#yes") { [weak self] in self?.hub.decide(id, .allow) }
        viewModel.register("\(token)#always") { [weak self] in self?.hub.decide(id, .always) }
        viewModel.register("\(token)#no") { [weak self] in self?.hub.decide(id, .deny) }
        viewModel.register("\(token)#terminal") { [weak self] in
            guard let self else { return }
            let host = self.hub.sessions.first { $0.id == request.sessionKey }?.hostBundleID
            self.hub.decide(id, .terminal)
            TerminalLauncher.activate(sessionBundleID: host)
        }

        var context = "\(request.agentName) · \(request.project)"
        let others = hub.approvals.count - 1
        if others > 0 { context += " · nog \(others) wachtend" }

        let detail: CardDetail
        let height: CGFloat
        if request.diff.isEmpty {
            detail = .command(String(request.summary.prefix(160)), note: request.assessment.note)
            height = 214
        } else {
            detail = .diff(title: request.summary, lines: request.diff, note: request.assessment.note)
            height = 150 + min(166, CGFloat(request.diff.count) * 15 + 34)
        }

        var extra = [CardAction(label: "In terminal", outcome: .callback("\(token)#terminal", ""))]
        if request.canAlways {
            extra.insert(CardAction(label: "Altijd", outcome: .callback("\(token)#always", "")), at: 0)
        }

        let card = NookCard(
            id: token,
            mood: danger ? .worry : .waiting,
            context: context,
            title: request.title,
            detail: detail,
            primary: CardAction(label: "Toestaan", outcome: .callback("\(token)#yes", "")),
            secondary: CardAction(label: "Weigeren", outcome: .callback("\(token)#no", "")),
            contentHeight: height,
            extra: extra,
            urgent: true
        )
        viewModel.presentUrgent(card)
        NookSound.play(.attention)
    }

    /// Meerkeuzevragen van een agent, één voor één. Na de laatste gaat het antwoord in één keer terug.
    private func presentQuestion(_ request: AgentQuestionRequest, index: Int = 0, selections: [[String]] = []) {
        guard index < request.items.count else { return }
        let item = request.items[index]
        let token = "question-" + request.id
        let choiceID = "\(token)#choice\(index)"

        viewModel.registerChoice(choiceID) { [weak self] labels in
            guard let self else { return }
            let all = selections + [labels]
            if index + 1 < request.items.count {
                self.presentQuestion(request, index: index + 1, selections: all)
            } else {
                self.hub.answerQuestion(request.id, selections: all)
            }
        }
        viewModel.register("\(token)#terminal") { [weak self] in
            guard let self else { return }
            let host = self.hub.sessions.first { $0.id == request.sessionKey }?.hostBundleID
            self.hub.answerQuestionInTerminal(request.id)
            TerminalLauncher.activate(sessionBundleID: host)
        }

        var context = "\(request.agentName) · \(request.project) vraagt"
        if !item.header.isEmpty { context += " · \(item.header)" }
        if request.items.count > 1 { context += " · \(index + 1) van \(request.items.count)" }

        let titleLines = max(1, Int(ceil(Double(item.question.count) / 46.0)))
        let optionsHeight = item.options.reduce(CGFloat(0)) { $0 + ($1.description.isEmpty ? 40 : 58) }
        let card = NookCard(
            id: token,
            mood: .waiting,
            context: context,
            title: item.question,
            detail: .choices(ChoiceSet(
                id: choiceID,
                options: item.options.map { ChoiceOption(label: $0.label, description: $0.description) },
                multiSelect: item.multiSelect
            )),
            primary: CardAction(label: "In terminal", outcome: .callback("\(token)#terminal", "")),
            secondary: CardAction(label: "", outcome: .dismiss),
            contentHeight: min(470, 110 + CGFloat(titleLines) * 24 + optionsHeight + (item.multiSelect ? 52 : 0)),
            urgent: true
        )
        if index == 0 {
            viewModel.presentUrgent(card)
            NookSound.play(.attention)
        } else {
            viewModel.show(.card(card))
        }
    }

    /// Een vraag van een agent is afgehandeld: kaart weg, en als jij in Nook antwoordde een korte bevestiging.
    private func cardGone(_ token: String, message: String?) {
        var visible = false
        if case .card(let shown) = viewModel.state, shown.id == token { visible = true }
        viewModel.dismissCard(id: token)
        guard visible, let message else { return }
        if case .card = viewModel.state { return }   // de volgende vraag staat al klaar
        viewModel.finish(message)
    }

    /// Een agent is klaar, liep vast of wacht op je: een eigen kaart met wat hij zei.
    /// Alleen als je niet met iets anders bezig bent in de notch; na een paar seconden gaat hij vanzelf weg.
    private func agentNeedsAttention(_ session: AgentSession) {
        NookSound.play(session.status == .done ? .done : .attention)
        switch viewModel.state {
        case .idle, .music, .track, .done, .nudge: break
        case .card(let shown) where shown.id.hasPrefix("agentstatus-"): break
        default: return
        }

        let token = "agentstatus-" + UUID().uuidString
        let mood: NookMood
        let state: String
        let fallback: String
        switch session.status {
        case .done:
            mood = .done; state = "klaar"; fallback = "Klaar met je opdracht."
        case .failed:
            mood = .worry; state = "liep vast"; fallback = "Er ging iets mis."
        default:
            mood = .waiting; state = "wacht op je"; fallback = "Wacht op je antwoord in de terminal."
        }
        let title = session.summary.isEmpty ? fallback : session.summary

        viewModel.register("\(token)#view") { [weak self] in
            self?.viewModel.selectedAgentID = session.id
            self?.viewModel.show(.panel(.agents))
        }
        viewModel.register("\(token)#terminal") { [weak self] in self?.openTerminal(for: session) }

        var context = "\(session.name) · \(session.project) · \(state)"
        if session.linesAdded + session.linesRemoved > 0 {
            context += " · +\(session.linesAdded) −\(session.linesRemoved)"
        }
        let lines = max(1, min(4, Int(ceil(Double(title.count) / 46.0))))
        let card = NookCard(
            id: token,
            mood: mood,
            context: context,
            title: title,
            detail: .none,
            primary: CardAction(label: "Bekijk", outcome: .callback("\(token)#view", "")),
            secondary: CardAction(label: "Open \(TerminalLauncher.name(for: session.hostBundleID))", outcome: .callback("\(token)#terminal", "")),
            contentHeight: 100 + CGFloat(lines) * 24
        )
        viewModel.show(.card(card))

        // Vanzelf weg na 5 seconden, behalve als je met de muis op de kaart staat.
        Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 5_200_000_000)
                guard let self, case .card(let shown) = self.viewModel.state, shown.id == token else { return }
                if !self.viewModel.pointerInside {
                    self.viewModel.dismissCard(id: token)
                    return
                }
            }
        }
    }

    /// Brengt het venster naar voren waarin deze agent draait.
    func openTerminal(for session: AgentSession) {
        if !TerminalLauncher.activate(sessionBundleID: session.hostBundleID) {
            viewModel.present(errorCard("Ik vind de terminal van \(session.name) niet. Staat hij nog open?"))
        }
    }

    // MARK: Agents koppelen

    /// Is alles voor het eerste account van deze agent geregeld: programma aanwezig, ingelogd en alle koppelingen aan?
    func isFullyConnected(_ kind: AgentKind) -> Bool {
        isFullyConnected(AgentProfile.defaultProfile(kind))
    }

    func isFullyConnected(_ profile: AgentProfile) -> Bool {
        history.executables[profile.kind] != nil && history.profileAccounts[profile.id] != nil
            && profile.kind.targets.allSatisfy { AgentConfigInstaller.state(of: $0, home: profile.home.map { _ in profile.homeURL }) == .installed }
    }

    /// Het account van een draaiende sessie, of nil als Nook het niet kent.
    func profile(for session: AgentSession) -> AgentProfile? {
        guard let kind = AgentKind(agentName: session.name) else { return nil }
        return profiles.profile(kind: kind, home: session.home)
    }

    func profile(for session: PastSession) -> AgentProfile? {
        profiles.profile(id: session.profileID) ?? profiles.profile(id: session.agent.rawValue)
    }

    func connect(_ kind: AgentKind) {
        connect(profiles.profile(id: kind.rawValue) ?? .defaultProfile(kind))
    }

    /// Eén klik: koppelt alles voor dit account. Ontbreekt het programma of ben je niet ingelogd, dan opent Nook
    /// een Terminal-venster dat installeert en het inloggen start, en ziet daarna vanzelf dat je bent ingelogd.
    func connect(_ profile: AgentProfile) {
        let kind = profile.kind
        if agentConnect[profile.id]?.isBusy == true { return }
        agentConnect[profile.id] = .working("Bezig met koppelen…")

        let home = profile.home.map { _ in profile.homeURL }
        if home != nil { try? FileManager.default.createDirectory(at: profile.homeURL, withIntermediateDirectories: true) }
        var problems: [String] = []
        for target in kind.targets where AgentConfigInstaller.state(of: target, home: home) != .installed {
            do {
                _ = try AgentConfigInstaller.apply(AgentConfigInstaller.prepare(target, install: true, home: home))
            } catch {
                problems.append("\(target.title): \(error.localizedDescription)")
            }
        }
        if !problems.isEmpty {
            agentConnect[profile.id] = .failed(problems.joined(separator: "\n"))
            return
        }
        // Nog geen brein? Dan denkt Nook voortaan met je Claude-abonnement.
        if kind == .claude, !settings.brainReady { settings.provider = .claudeCode }

        let hasProgram = history.executables[kind] != nil
        let loggedIn = history.profileAccounts[profile.id] != nil
        guard !hasProgram || !loggedIn else {
            finishConnect(profile)
            return
        }

        let who = profile.isDefault ? kind.name : "\(kind.name) (\(profile.label))"
        var steps = ["echo " + TerminalLauncher.shellQuote("Nook koppelt \(who). " + (hasProgram
            ? "Log hieronder in met het juiste account; Nook ziet het vanzelf."
            : "Eerst installeren, daarna inloggen. Nook ziet het vanzelf."))]
        if !hasProgram { steps.append(kind.installCommand) }
        steps.append(profile.commandPrefix + kind.loginCommand)
        do {
            try TerminalLauncher.run(command: steps.joined(separator: " && "),
                                     in: FileManager.default.homeDirectoryForCurrentUser.path,
                                     name: "nook-connect-\(profile.id)")
        } catch {
            agentConnect[profile.id] = .failed("Ik kon Terminal niet openen: \(error.localizedDescription)")
            return
        }
        agentConnect[profile.id] = .waitingForLogin(hasProgram ? "Log in in het Terminal-venster…" : "Installeren en inloggen in Terminal…")
        waitForLogin(profile)
    }

    /// Kijkt een kwartier lang elke paar seconden of de agent er staat en je bent ingelogd.
    private func waitForLogin(_ profile: AgentProfile) {
        Task { [weak self] in
            for _ in 0..<300 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, case .waitingForLogin? = self.agentConnect[profile.id] else { return }
                self.history.refresh(minimumInterval: 0)
                if self.history.executables[profile.kind] != nil, self.history.profileAccounts[profile.id] != nil {
                    self.finishConnect(profile)
                    return
                }
            }
            self?.agentConnect[profile.id] = .failed("Ik zag nog geen login. Ben je klaar in Terminal? Klik dan nog eens op Koppel.")
        }
    }

    private func finishConnect(_ profile: AgentProfile) {
        let kind = profile.kind
        // Net geïnstalleerd? Dan opnieuw zoeken, zodat Claude Code ook als brein werkt.
        if kind == .claude { ClaudeCodeBrain.resetLocation(); settings.objectWillChange.send() }
        let running = agentSessions.contains { self.profile(for: $0)?.id == profile.id }
        agentConnect[profile.id] = .done(running ? "Alles gekoppeld. Start lopende sessies opnieuw." : "Alles gekoppeld.")
        history.refresh(minimumInterval: 0)
    }

    // MARK: Accounts

    /// Een extra account (bijvoorbeeld je werkaccount) met een eigen map, en meteen inloggen.
    @discardableResult
    func addAccount(_ kind: AgentKind, label: String, home: URL? = nil) -> AgentProfile {
        let profile = profiles.add(kind: kind, label: label, home: home)
        viewModel.selectedAgentID = "account:" + profile.id
        if history.profileAccounts[profile.id] == nil || !isFullyConnected(profile) { connect(profile) }
        return profile
    }

    func removeAccount(_ profile: AgentProfile) {
        profiles.remove(profile.id)
        agentConnect[profile.id] = nil
        viewModel.selectedAgentID = "account:" + profiles.preferredProfile(profile.kind).id
    }

    func makeDefault(_ profile: AgentProfile) {
        profiles.setPreferred(profile)
    }

    /// Start de agent met dit account in een nieuw Terminal-venster, in `folder`.
    func startSession(_ profile: AgentProfile, in folder: String) {
        do {
            try TerminalLauncher.run(command: profile.launchCommand, in: folder, name: "nook-start-\(profile.id)")
            viewModel.show(.idle)
        } catch {
            viewModel.present(errorCard("Ik kon Terminal niet openen: \(error.localizedDescription)"))
        }
    }

    /// Laat je een map kiezen en start daar een sessie met dit account.
    func startSessionChoosingFolder(_ profile: AgentProfile) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Start hier"
        panel.message = "In welke map start \(profile.kind.name)?"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startSession(profile, in: url.path)
    }

    /// Mappen waar je met dit account onlangs werkte, nieuwste eerst.
    func recentFolders(_ profile: AgentProfile, limit: Int = 5) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for session in history.sessions(for: profile) where !session.cwd.isEmpty {
            guard seen.insert(session.cwd).inserted, FileManager.default.fileExists(atPath: session.cwd) else { continue }
            result.append(session.cwd)
            if result.count == limit { break }
        }
        return result
    }

    func copyLaunchCommand(_ profile: AgentProfile) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(profile.launchCommand, forType: .string)
    }

    /// Gaat verder met een eerdere sessie, in een nieuw Terminal-venster in de map van toen.
    func resume(_ session: PastSession) {
        guard FileManager.default.fileExists(atPath: session.cwd) else {
            viewModel.present(errorCard("De map van deze sessie bestaat niet meer: \(session.cwd)"))
            return
        }
        do {
            try TerminalLauncher.run(command: resumeCommand(for: session, absolute: true), in: session.cwd,
                                     name: "nook-resume-\(session.agent.rawValue)")
            viewModel.show(.idle)
        } catch {
            viewModel.present(errorCard("Ik kon Terminal niet openen: \(error.localizedDescription)"))
        }
    }

    /// Het commando om een sessie te hervatten, met het account van toen. `absolute` gebruikt het volledige pad
    /// als Nook weet waar de agent staat.
    func resumeCommand(for session: PastSession, absolute: Bool = false) -> String {
        var program = session.agent.command
        if absolute, session.agent == .claude, let path = ClaudeCodeBrain.executable { program = path }
        let prefix = profile(for: session)?.commandPrefix ?? ""
        return prefix + ([program] + session.resumeArguments).map(TerminalLauncher.shellQuote).joined(separator: " ")
    }

    func copyResumeCommand(_ session: PastSession) {
        let command = "cd \(TerminalLauncher.shellQuote(session.cwd)) && \(resumeCommand(for: session))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    // MARK: Snelle opdrachten

    private func handleLocalIntent(_ intent: LocalIntent) {
        spokenRequest = false
        switch intent {
        case .media(let action):
            let command: NowPlayingService.Command
            let message: String
            switch action {
            case "next": command = .next; message = "Volgend nummer"
            case "previous": command = .previous; message = "Vorig nummer"
            default: command = .playPause; message = nowPlaying.current?.isPlaying == true ? "Gepauzeerd" : "Muziek hervat"
            }
            nowPlaying.control(command)
            viewModel.finish(message)
        case .volume(let level):
            proposeQuick(tool: "set_volume", input: ["level": level])
        case .volumeStep(let step):
            let current = Int(SystemControl.appleScript("output volume of (get volume settings)") ?? "") ?? 50
            proposeQuick(tool: "set_volume", input: ["level": max(0, min(100, current + step))])
        case .openApp(let name):
            proposeQuick(tool: "open_app", input: ["name": name])
        case .showTab(let tab):
            viewModel.show(.panel(tab))
        case .weekRecap:
            showWeekRecap()
        case .time:
            let text = "Het is \(NookDates.time(Date()))."
            viewModel.show(.card(answerCard(text)))
            if settings.speakAnswers { speech.speak(text, language: settings.language) }
        }
    }

    /// Snelle opdrachten die in de chat meteen klaar zijn, zonder kaart. Nil: gewoon de kaart tonen.
    private func quickReplyInChat(_ intent: LocalIntent) -> String? {
        switch intent {
        case .media(let action):
            let command: NowPlayingService.Command
            let message: String
            switch action {
            case "next": command = .next; message = "Volgend nummer."
            case "previous": command = .previous; message = "Vorig nummer."
            default: command = .playPause; message = nowPlaying.current?.isPlaying == true ? "Gepauzeerd." : "Muziek hervat."
            }
            nowPlaying.control(command)
            return message
        case .time:
            return "Het is \(NookDates.time(Date()))."
        default:
            return nil
        }
    }

    /// Een actie die Nook zelf herkende: meteen als plan klaarzetten, zonder het brein.
    private func proposeQuick(tool: String, input: [String: Any]) {
        let plan = BrainPlan(text: "", actions: [PlannedAction(tool: tool, input: input)])
        if canRunWithoutAsking(plan) {
            execute(plan)
            return
        }
        viewModel.show(.card(planCard(plan, context: "Snelle opdracht")))
    }

    // MARK: Weekoverzicht

    func showWeekRecap() {
        let now = Date()
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        var summary = recap.summary(weekOf: now)
        var label = "Deze week"
        let lastWeek = recap.summary(weekOf: now.addingTimeInterval(-7 * 86_400))
        if (calendar.component(.weekday, from: now) == 2 || summary.isEmpty), !lastWeek.isEmpty {
            summary = lastWeek
            label = "Vorige week"
        }
        UserDefaults.standard.set(Self.weekKey(lastWeek.start), forKey: "recapSeen")

        guard !summary.isEmpty else {
            viewModel.show(.card(answerCard("Ik heb nog niets bijgehouden. Koppel je agents bij Instellingen › Agents, dan zie je hier wat ze voor je deden.")))
            return
        }

        var facts = [
            Fact(label: "tijd met agents", value: RecapStore.duration(summary.activeSeconds)),
            Fact(label: "sessies", value: "\(summary.sessions)"),
            Fact(label: "opdrachten", value: "\(summary.prompts)"),
            Fact(label: "regels erbij / eraf", value: "+\(summary.linesAdded) −\(summary.linesRemoved)"),
            Fact(label: "commando's", value: "\(summary.commands)"),
            Fact(label: "toegestaan / geweigerd", value: "\(summary.allowed) / \(summary.denied)")
        ]
        if let day = summary.busiestDay {
            facts.append(Fact(label: "drukste dag", value: NookDates.weekday(day) + " · " + RecapStore.duration(summary.busiestSeconds)))
        }
        if let project = summary.topProject {
            facts.append(Fact(label: "meeste tijd in", value: project))
        }

        let who = summary.topAgent.map { "\($0) en co" } ?? "Je agents"
        let card = NookCard(
            id: "recap",
            mood: .done,
            context: "\(label) · vanaf \(NookDates.dayMonth(summary.start))",
            title: "\(who) werkten \(RecapStore.duration(summary.activeSeconds)) voor je.",
            detail: .facts(facts),
            primary: CardAction(label: "Oké", outcome: .dismiss),
            secondary: CardAction(label: "", outcome: .dismiss),
            contentHeight: 140 + CGFloat((facts.count + 1) / 2) * 44
        )
        viewModel.show(.card(card))
    }

    /// Op maandag een regel in de tab Nook met het overzicht van vorige week, tot je het bekeken hebt.
    private func weeklyRecapItem() -> TodayItem? {
        let now = Date()
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        guard calendar.component(.weekday, from: now) == 2 else { return nil }
        let lastWeek = recap.summary(weekOf: now.addingTimeInterval(-7 * 86_400))
        guard !lastWeek.isEmpty, UserDefaults.standard.string(forKey: "recapSeen") != Self.weekKey(lastWeek.start) else { return nil }
        return TodayItem(
            id: "recap",
            title: "Je week met agents",
            subtitle: "\(RecapStore.duration(lastWeek.activeSeconds)) · \(lastWeek.sessions) sessies",
            action: "Bekijk",
            color: NookTheme.mint,
            target: .action { [weak self] in self?.showWeekRecap() }
        )
    }

    private static func weekKey(_ date: Date) -> String {
        "\(Int(date.timeIntervalSince1970))"
    }

    // MARK: Bestanden

    /// Een bestand uit de Shelf: lees de tekst (op je Mac) en vraag wat je wilt weten.
    func askAbout(_ url: URL) {
        do {
            let text = try FileText.read(url)
            attachment = (url.lastPathComponent, text, Date())
            var message = ChatMessage(role: .nook, text: "Ik heb **\(url.lastPathComponent)** gelezen. Wat wil je erover weten? Ik kan het samenvatten, er een grafiek of mail van maken, of acties eruit halen.")
            message.sources = ["Bestand"]
            chat.append(message)
            showChat()
        } catch {
            viewModel.show(.card(errorCard(error.localizedDescription)))
        }
    }

    // MARK: Kaarten

    private func presentLoop(_ loop: OpenLoop) {
        let token = "loop-" + loop.id
        viewModel.register("\(token)#done") { [weak self] in
            self?.store.completeLoop(id: loop.id)
            self?.reloadLoops()
        }
        let card = NookCard(
            id: token,
            mood: .remind,
            context: "Open punt · sinds \(NookDates.short(loop.created))",
            title: loop.title,
            detail: .none,
            primary: CardAction(label: "Afgerond", outcome: .callback("\(token)#done", "Afgevinkt")),
            secondary: CardAction(label: "Later", outcome: .dismiss),
            contentHeight: 130
        )
        viewModel.show(.card(card))
    }

    /// ⌥⌘ spatie: meteen typen in de chat, waar je ook bent.
    func openAsk() {
        warmUp()
        showChat(focus: true)
    }

    /// De eerste keer: in drie stappen klaar. Alles staat ook in Instellingen.
    func presentWelcome() {
        let token = "welcome"
        viewModel.register("\(token)#setup") { [weak self] in
            self?.settings.onboardingDone = true
            self?.openSettings()
        }
        viewModel.register("\(token)#later") { [weak self] in self?.settings.onboardingDone = true }
        let facts = [
            Fact(label: "1 · brein", value: settings.brainReady ? "klaar" : "kies Claude, een andere AI of gratis lokaal"),
            Fact(label: "2 · scherm lezen", value: CGPreflightScreenCaptureAccess() ? "aan" : "geef toestemming"),
            Fact(label: "3 · agenda", value: calendar.hasEventAccess ? "gekoppeld" : "geef toestemming"),
            Fact(label: "4 · koppelingen", value: "mail, GitHub, Stripe… (optioneel)")
        ]
        let card = NookCard(
            id: token,
            mood: .seen,
            context: "Welkom bij Nook",
            title: "Ik ben je assistent. Ik zie je schermen en ken je agenda, dus vraag me gewoon alles.",
            detail: .facts(facts),
            primary: CardAction(label: "Instellen", outcome: .callback("\(token)#setup", "")),
            secondary: CardAction(label: "Later", outcome: .callback("\(token)#later", "")),
            contentHeight: 150 + 2 * 44 + 24
        )
        viewModel.present(card)
    }

    /// Een bestand uit de Shelf als bijlage in een nieuwe mail zetten (Mail.app). Jij verstuurt zelf.
    func mailFile(_ url: URL) {
        let path = ScriptText.quote(url.path)
        let script = """
        tell application "Mail"
            set m to make new outgoing message with properties {visible:true, subject:\(ScriptText.quote(url.lastPathComponent))}
            tell content of m to make new attachment with properties {file name:(POSIX file \(path) as alias)} at after last paragraph
            activate
        end tell
        """
        Task {
            let result = await ScriptText.run(script)
            if result.errorNumber == -1743 {
                viewModel.present(errorCard("Geef Nook toestemming voor Mail bij Systeeminstellingen › Privacy › Automatisering."))
            } else {
                store.audit(tool: "mail_file", args: url.lastPathComponent, result: "concept geopend")
                viewModel.finish("Concept met \(url.lastPathComponent) staat klaar in Mail")
            }
        }
    }

    private func thinkingCard(context: String, title: String) -> NookCard {
        NookCard(
            id: "thinking",
            mood: .think,
            context: context,
            title: title,
            detail: .none,
            primary: CardAction(label: "Verberg", outcome: .dismiss),
            secondary: CardAction(label: "", outcome: .dismiss),
            contentHeight: 130
        )
    }

    private func answerCard(_ text: String, offers: [String] = []) -> NookCard {
        let body = text.isEmpty ? "Daar heb ik geen antwoord op." : String(text.prefix(4000))
        let lines = min(9, max(1, Int(ceil(Double(body.count) / 46.0))))
        let token = "answer-" + UUID().uuidString
        return NookCard(
            id: token,
            mood: .seen,
            context: "Nook",
            title: body,
            detail: .none,
            primary: CardAction(label: "Oké", outcome: .dismiss),
            secondary: CardAction(label: "", outcome: .dismiss),
            contentHeight: 140 + CGFloat(lines) * 24 + (offers.isEmpty ? 0 : 40),
            input: true,
            offers: offers
        )
    }

    private func errorCard(_ message: String) -> NookCard {
        let lines = max(1, Int(ceil(Double(message.count) / 46.0)))
        let token = "error-" + UUID().uuidString
        viewModel.register("\(token)#settings") { [weak self] in self?.openSettings() }
        return NookCard(
            id: token,
            mood: .worry,
            context: "Dat lukte niet",
            title: String(message.prefix(240)),
            detail: .none,
            primary: CardAction(label: "Oké", outcome: .dismiss),
            secondary: CardAction(label: "Instellingen", outcome: .callback("\(token)#settings", "")),
            contentHeight: 90 + CGFloat(lines) * 24
        )
    }

    private func presentSetupCard() {
        let token = "setup-" + UUID().uuidString
        viewModel.register("\(token)#open") { [weak self] in self?.openSettings() }
        let card = NookCard(
            id: token,
            mood: .waiting,
            context: "Eerst even instellen",
            title: "Ik heb een API-sleutel of een gratis lokaal model nodig om te kunnen denken.",
            detail: .none,
            primary: CardAction(label: "Open instellingen", outcome: .callback("\(token)#open", "")),
            secondary: CardAction(label: "Later", outcome: .dismiss),
            contentHeight: 138
        )
        viewModel.show(.card(card))
    }
}
