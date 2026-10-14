import SwiftUI
import Combine
import AppKit
import Carbon.HIToolbox

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

    private(set) lazy var tools = NookTools(calendar: calendar, store: store, screen: screen) { [weak self] in
        self?.reloadLoops()
    }
    private(set) lazy var brain = BrainService(settings: settings)

    /// Voorbeelddata in plaats van echte bronnen, handig om de UI te bekijken.
    @Published var demoMode = false
    @Published private(set) var loops: [OpenLoop] = []
    @Published private(set) var upcoming: [CalEvent] = []

    var viewModel: NotchViewModel { notch.viewModel }

    private var bag = Set<AnyCancellable>()
    private var hotKeys: [HotKey] = []
    private var watchTimer: Timer?
    private var lastScreenHash: Int?
    private var lastAutoRun = Date.distantPast
    private var autoBusy = false

    private init() {
        hub.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        nowPlaying.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
    }

    // MARK: Opstarten

    func start() {
        viewModel.app = self
        notch.start(app: self)

        reloadLoops()
        nowPlaying.start()

        hub.onApproval = { [weak self] request in self?.presentApproval(request) }
        hub.onAttention = { [weak self] session in self?.agentNeedsAttention(session) }
        hub.start()

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
                } else if !playing, case .music = vm.state {
                    vm.show(.idle)
                }
            }
            .store(in: &bag)

        hotKeys = [
            HotKey(id: 1, keyCode: kVK_Space, modifiers: optionKey) { [weak self] in self?.toggleVoice() },
            HotKey(id: 2, keyCode: kVK_ANSI_N, modifiers: optionKey | cmdKey) { [weak self] in self?.lookAtScreen(manual: true) }
        ].compactMap { $0 }

        Task { await refreshUpcoming() }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshUpcoming() }
        }

        watchTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoWatchTick() }
        }
    }

    // MARK: Gegevens voor de UI

    var agentSessions: [AgentSession] {
        demoMode ? DemoContent.agents : hub.sessions
    }

    var todayItems: [TodayItem] {
        if demoMode { return DemoContent.today }
        var items: [TodayItem] = []

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

        if let next = upcoming.first(where: { $0.end > Date() }) {
            let place = next.location.isEmpty ? "" : " · \(next.location)"
            items.append(TodayItem(
                id: "event-\(next.id)",
                title: next.title,
                subtitle: NookDates.short(next.start) + place,
                action: "",
                color: NookTheme.iris,
                target: .none
            ))
        }

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
    func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(self))
            let window = NSWindow(contentViewController: host)
            window.title = "Nook Instellingen"
            window.styleMask = [.titled, .closable, .miniaturizable]
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
        guard settings.brainReady else {
            presentSetupCard()
            return
        }
        let title = "“\(String(text.prefix(100)))”"

        // Verwijst de gebruiker naar iets op het scherm ("maak er een afspraak voor"), lees dat dan meteen mee.
        if Self.refersToScreen(text) {
            viewModel.show(.card(thinkingCard(context: "Ik kijk even mee…", title: title)))
            Task {
                do {
                    let snapshot = try await screen.capture()
                    await runBrain(
                        userText: text,
                        snapshot: snapshot,
                        silentIfNone: false,
                        context: "Ik zag in \(snapshot.appName)"
                    )
                } catch {
                    replaceThinking(with: errorCard(error.localizedDescription))
                }
            }
            return
        }

        let loading = settings.useLocal && !EmbeddedModel.shared.isLoaded
        viewModel.show(.card(thinkingCard(context: loading ? "Lokaal model laden…" : "Even nadenken…", title: title)))
        Task { await runBrain(userText: text, snapshot: nil, silentIfNone: false, context: nil) }
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

    private func runBrain(userText: String, snapshot: ScreenSnapshot?, silentIfNone: Bool, context: String?) async {
        do {
            let plan = try await brain.run(
                userText: userText,
                context: contextSummary(),
                untrustedLabel: snapshot.map { "\($0.appName) — \($0.windowTitle)" },
                untrusted: snapshot?.text,
                tools: tools.specs
            )

            let bare = plan.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).uppercased()
            if plan.actions.isEmpty && bare == "NONE" {
                if silentIfNone {
                    viewModel.dismissCard(id: "thinking")
                } else {
                    replaceThinking(with: answerCard("Ik zie niets waar je iets aan hebt."))
                }
                return
            }

            let card = planCard(plan, context: context)
            if silentIfNone {
                viewModel.present(card)
            } else {
                replaceThinking(with: card)
            }
        } catch {
            if !silentIfNone {
                replaceThinking(with: errorCard(error.localizedDescription))
            }
        }
    }

    private func replaceThinking(with card: NookCard) {
        if case .card(let shown) = viewModel.state, shown.id == "thinking" {
            viewModel.show(.card(card))
        } else {
            viewModel.present(card)
        }
    }

    private func contextSummary() -> String {
        let now = Date()
        var lines = ["Nu: \(NookDates.long(now))"]

        let events = calendar.events(from: now, to: now.addingTimeInterval(3 * 86_400))
        if calendar.hasEventAccess {
            lines.append("Agenda, komende drie dagen:")
            if events.isEmpty { lines.append("- geen afspraken") }
            for event in events.prefix(15) {
                lines.append("- \(event.title) | \(NookDates.iso(event.start)) – \(NookDates.iso(event.end))")
            }
        } else {
            lines.append("Agenda: geen toegang.")
        }

        if !loops.isEmpty {
            lines.append("Open punten:")
            for loop in loops.prefix(10) { lines.append("- \(loop.title)") }
        }

        let sessions = hub.sessions
        if !sessions.isEmpty {
            lines.append("Draaiende agents:")
            for session in sessions { lines.append("- \(session.name) (\(session.project)): \(session.status.label)") }
        }

        if let playing = nowPlaying.current {
            lines.append("Speelt nu: \(playing.title) – \(playing.artist)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Plan en uitvoeren

    private func planCard(_ plan: BrainPlan, context: String?) -> NookCard {
        guard !plan.actions.isEmpty else { return answerCard(plan.text) }

        let token = "plan-" + UUID().uuidString
        let title = plan.text.isEmpty ? "Zo regel ik het:" : String(plan.text.prefix(160))
        let titleLines = max(1, Int(ceil(Double(title.count) / 46.0)))

        let steps: [PlanStep] = plan.actions.enumerated().map { index, action in
            let spec = tools.spec(named: action.tool)
            let tag = spec?.tag(action.input) ?? ("", .neutral)
            return PlanStep(
                number: index + 1,
                text: spec?.summarize(action.input) ?? action.tool,
                tag: tag.0,
                tone: tag.1
            )
        }

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

        return NookCard(
            id: token,
            mood: .think,
            context: contextLine,
            title: title,
            detail: detail,
            primary: CardAction(label: primaryLabel, outcome: .callback("\(token)#run", "")),
            secondary: CardAction(label: "Annuleren", outcome: .dismiss),
            contentHeight: min(400, 100 + CGFloat(titleLines) * 24 + detailHeight)
        )
    }

    private func execute(_ plan: BrainPlan) {
        Task {
            var results: [String] = []
            var failure: String?

            for action in plan.actions {
                guard let spec = tools.spec(named: action.tool) else { continue }
                let args = Self.json(action.input)
                do {
                    let result = try await spec.run(action.input)
                    store.audit(tool: action.tool, args: args, result: result)
                    results.append(result)
                } catch {
                    store.audit(tool: action.tool, args: args, result: "FOUT: \(error.localizedDescription)")
                    failure = error.localizedDescription
                    break
                }
            }

            reloadLoops()
            await refreshUpcoming()

            if let failure {
                viewModel.present(errorCard(failure))
            } else if results.count == 1 {
                viewModel.finish(results[0])
            } else {
                viewModel.finish("\(results.count) acties uitgevoerd")
            }
        }
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
        Task {
            guard await voice.requestPermissions() else {
                viewModel.present(errorCard("Nook mag nog niet luisteren. Zet de microfoon en spraakherkenning aan bij Systeminstellingen › Privacy en beveiliging."))
                return
            }
            warmUp()
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
            handleUserText(trimmed)
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

    private func autoWatchTick() {
        guard settings.autoWatch, !settings.useLocal, settings.brainReady, !autoBusy, CGPreflightScreenCaptureAccess() else { return }
        guard Date().timeIntervalSince(lastAutoRun) > 90 else { return }
        switch viewModel.state {
        case .idle, .music: break
        default: return
        }
        autoBusy = true
        lastAutoRun = Date()
        lookAtScreen(manual: false)
        autoBusy = false
    }

    // MARK: Agents

    private func presentApproval(_ request: ApprovalRequest) {
        let token = "approval-" + UUID().uuidString
        let danger = request.assessment.level == .danger

        viewModel.register("\(token)#yes") { request.reply(.allow) }
        viewModel.register("\(token)#no") { request.reply(.deny) }

        let card = NookCard(
            id: token,
            mood: danger ? .worry : .waiting,
            context: "\(request.agentName) · \(request.project)",
            title: danger ? request.assessment.title : "Mag \(request.agentName) dit uitvoeren?",
            detail: .command(String(request.command.prefix(160)), note: request.assessment.note),
            primary: CardAction(label: "Toestaan", outcome: .callback("\(token)#yes", "Toegestaan")),
            secondary: CardAction(label: "Weigeren", outcome: .callback("\(token)#no", "Geweigerd")),
            contentHeight: 214
        )
        viewModel.present(card)

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 95_000_000_000)
            self?.viewModel.dismissCard(id: token)
        }
    }

    private func agentNeedsAttention(_ session: AgentSession) {
        let message = session.status == .done
            ? "\(session.name) is klaar · \(session.project)"
            : "\(session.name) wacht op je · \(session.project)"
        switch viewModel.state {
        case .idle, .music, .done:
            viewModel.finish(message, button: "Bekijk") { [weak self] in
                self?.viewModel.selectedAgentID = session.id
                self?.viewModel.show(.panel(.agents))
            }
        default:
            break
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

    private func answerCard(_ text: String) -> NookCard {
        let body = text.isEmpty ? "Daar heb ik geen antwoord op." : String(text.prefix(240))
        let lines = max(1, Int(ceil(Double(body.count) / 46.0)))
        let token = "answer-" + UUID().uuidString
        viewModel.register("\(token)#talk") { [weak self] in self?.toggleVoice() }
        return NookCard(
            id: token,
            mood: .seen,
            context: "Nook",
            title: body,
            detail: .none,
            primary: CardAction(label: "Oké", outcome: .dismiss),
            secondary: CardAction(label: "Vraag door", outcome: .callback("\(token)#talk", "")),
            contentHeight: 90 + CGFloat(lines) * 24
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
