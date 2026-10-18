import SwiftUI
import Combine
import AppKit
import Carbon.HIToolbox
import PDFKit
import UniformTypeIdentifiers
import NaturalLanguage

/// Orchestrates services, brain, and notch UI. The UI interacts solely with this object.
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
    /// Real-time on-screen content across all displays, indexed locally.
    let screenContext = ScreenContext()
    /// Calendar, mail, browser, GitHub, Stripe, etc.: context sources for Nook.
    let connectors = ConnectorHub()
    let codex = CodexUsage()
    /// Antigravity's quota windows, read from Google.
    let antigravityUsage = AntigravityUsage()
    /// Claude's subscription limits, read from Anthropic for every Claude account.
    private(set) lazy var claudeUsage = ClaudeUsage(hub: hub) { [weak self] in self?.profiles.profiles(for: .claude) ?? [] }

    /// Reads the limits of all linked accounts right away (Claude and Codex).
    func refreshQuotas() {
        codex.refreshNow()
        claudeUsage.refreshNow()
        antigravityUsage.refreshNow()
    }
    /// Past sessions and token usage for Claude Code and Codex, for the Agents tab.
    let history = AgentHistory()
    /// Configured accounts per agent (personal, work, etc.) and active defaults.
    let profiles = AgentProfileStore()
    /// Web search and webpage reading, available across all providers.
    let web = WebTools()
    /// Proactive assistance: evaluates screen context and offers assistance when appropriate.
    let thinkAlong = ThinkAlong()
    /// Conversation state and history in chat.
    let chat = NookChat()
    /// Coding agents spawned and tracked by Nook in dedicated terminal windows.
    let workspace = WorkspaceManager()
    /// Every permission request from an agent, whether it arrives through hooks or from a session Nook runs.
    private(set) lazy var approvals = ApprovalCenter(hub: hub, workspace: workspace, bridge: .shared)
    /// The subscription limits of every agent account.
    var quota: QuotaService { QuotaService(hub: hub, codex: codex, antigravity: antigravityUsage) }
    /// Currently selected settings section.
    @Published var settingsSection: SettingsSection = .general

    private(set) lazy var tools: NookTools = {
        let tools = NookTools(calendar: calendar, store: store, screen: screen) { [weak self] in
            self?.reloadLoops()
        }
        tools.mediaControl = { [weak self] action in
            switch action {
            case "next": self?.nowPlaying.control(.next)
            case "previous": self?.nowPlaying.control(.previous)
            default: self?.nowPlaying.control(.playPause)
            }
        }
        tools.screenSnapshot = { [weak self] in
            guard let self else { throw ScreenError.nothing }
            return try await self.screenSnapshot()
        }
        return tools
    }()

    /// Charts and mail drafts: attached to the message currently being streamed.
    private(set) lazy var chatTools: [ToolSpec] = ChatTools.specs(
        onChart: { [weak self] chart in self?.attachToReply { $0.charts.append(chart) } },
        onMail: { [weak self] mail in self?.attachToReply { $0.mails.append(mail) } }
    )

    /// Built-in Nook tools plus read tools for all enabled connectors.
    var allTools: [ToolSpec] {
        // Claude API uses Anthropic's native search tool; other providers use Nook's search tool.
        let ownSearch = settings.useLocal || settings.provider != .claude
        let webSpecs = settings.webSearch ? web.specs(includeSearch: ownSearch) : []
        var all: [ToolSpec] = tools.specs + chatTools + connectors.tools
        all += webSpecs
        all += BrowserStore.shared.tools
        all += TerminalStore.shared.tools
        return all
    }
    private(set) lazy var brain = BrainService(settings: settings)

    /// All supported capabilities, including inactive connectors: displayed in Settings › Connectors.
    var knownTools: [ToolSpec] {
        var all: [ToolSpec] = tools.specs + chatTools + connectors.hubTools
        all += connectors.sources.flatMap { $0.tools }
        all += web.specs(includeSearch: true)
        all += BrowserStore.shared.tools
        all += TerminalStore.shared.tools
        return all
    }

    /// Tools available for a chat prompt: scoped to permitted sources and tracked via ledger
    /// to record what Nook inspected, returned, or failed.
    func scopedTools(_ scope: SourceScope, ledger: RetrievalLedger?) -> [ToolSpec] {
        allTools.filter { scope.allowsTool($0.name) }.compactMap { Self.restrictAccounts($0, to: scope) }.map { spec in
            // Read tools only; drawing a chart or drafting an email is not a retrieval tool (and never cached).
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

    /// A tool with an `account` field only offers the accounts this chat allows. With one left, the field disappears and
    /// that account is filled in; with none left, the tool is not offered at all. A call naming another account is refused.
    static func restrictAccounts(_ spec: ToolSpec, to scope: SourceScope) -> ToolSpec? {
        guard let service = SourceCatalog.source(forTool: spec.name),
              var properties = spec.schema["properties"] as? [String: Any],
              let field = properties["account"] as? [String: Any],
              let names = field["enum"] as? [String] else { return spec }
        let accounts = AccountRegistry.shared.accounts(for: service)
        let allowed = names.filter { name in AccountRegistry.match(name, in: accounts).map { scope.allowsAccount($0.id) } ?? true }
        guard !allowed.isEmpty else { return nil }
        guard allowed.count < names.count else { return spec }
        var schema = spec.schema
        if allowed.count == 1 {
            properties.removeValue(forKey: "account")
            schema["required"] = ((schema["required"] as? [String]) ?? []).filter { $0 != "account" }
        } else {
            var restricted = field
            restricted["enum"] = allowed
            properties["account"] = restricted
        }
        schema["properties"] = properties
        let run = spec.run
        let only = allowed.count == 1 ? allowed[0] : nil
        return ToolSpec(
            name: spec.name, description: spec.description, schema: schema, kind: spec.kind,
            summarize: { input in
                var filled = input
                if let only, filled["account"] == nil { filled["account"] = only }
                return spec.summarize(filled)
            },
            tag: spec.tag,
            run: { input in
                var filled = input
                if let only { filled["account"] = only }
                if let chosen = filled["account"] as? String, !allowed.contains(where: { $0.caseInsensitiveCompare(chosen) == .orderedSame }) {
                    throw NookError(tr("chat.account.notAllowed", chosen))
                }
                return try await run(filled)
            }
        )
    }

    /// Mock demo content for UI preview without real credentials.
    @Published var demoMode = false
    /// Integration progress for an agent profile (one-click setup in Agents tab or Settings).
    /// Per account (`AgentProfile.id`).
    @Published var agentConnect: [String: AgentConnectProgress] = [:]
    @Published var loops: [OpenLoop] = []
    @Published var upcoming: [CalEvent] = []

    var viewModel: NotchViewModel { notch.viewModel }

    var bag = Set<AnyCancellable>()
    var hotKeys: [HotKey] = []
    var watchTimer: Timer?
    var lastScreenHash: Int?
    var autoBusy = false
    /// Prompt was spoken: enables spoken voice response.
    var spokenRequest = false
    /// File from Shelf attached as prompt context.
    var attachment: (name: String, text: String, date: Date)? {
        didSet { attachmentName = attachment?.name }
    }
    /// Attachment indicator for the input field: file currently included.
    @Published private(set) var attachmentName: String?

    private init() {
        hub.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        nowPlaying.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        connectors.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        codex.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        antigravityUsage.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        history.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        profiles.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        // When accounts are added or removed, history immediately reloads from the correct directories.
        profiles.$all.removeDuplicates().sink { [weak self] all in
            guard let self else { return }
            self.history.profiles = all
            self.history.refresh(minimumInterval: 0)
        }.store(in: &bag)
        screenContext.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        thinkAlong.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        // Tracks whether any conversation is active (for orb mood and idle notch state); chat handles messages directly.
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

        // Always install newest hook script version so existing integrations stay up to date.
        try? HookScript.install()
        hub.recap = recap
        workspace.recap = recap
        startWorkspace()
        hub.onApproval = { [weak self] request in self?.presentApproval(request) }
        hub.onApprovalGone = { [weak self] id, message in self?.cardGone("approval-" + id, message: message) }
        hub.onQuestion = { [weak self] request in self?.presentQuestion(request) }
        hub.onQuestionGone = { [weak self] id, message in self?.cardGone("question-" + id, message: message) }
        hub.onAttention = { [weak self] session in self?.agentNeedsAttention(session) }
        hub.start()

        // Load agents, accounts and past sessions up front and keep them fresh in the background, so the Agents tab is
        // already filled the moment the notch opens instead of loading only then.
        history.refresh(minimumInterval: 0)
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.adoptAccounts()
                self.history.refresh()
            }
        }

        // Agent start/stop events update the idle notch indicator.
        hub.$sessions
            .map { sessions in sessions.map { "\($0.id)|\($0.status.label)|\($0.approvalID ?? "")" } }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.viewModel.state.isResting else { return }
                self.viewModel.show(self.viewModel.state)
            }
            .store(in: &bag)

        // Wake word: only listen when enabled, and pause while Nook is already listening.
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

        // Music playback changes update the idle notch indicator.
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
                    self.notch.cancelAnnouncement()
                    vm.show(.idle)
                }
            }
            .store(in: &bag)

        // Equalizer: listen to the player's real output while it plays, and stop as soon as it doesn't.
        nowPlaying.$current
            .map { info -> String? in
                guard let info, info.isPlaying else { return nil }
                return info.app == "Spotify" ? "com.spotify.client" : "com.apple.Music"
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { bundleID in
                if let bundleID { AudioLevelMonitor.shared.start(bundleID: bundleID) } else { AudioLevelMonitor.shared.stop() }
            }
            .store(in: &bag)

        // Track change: notch temporarily shows currently playing track.
        nowPlaying.$current
            .compactMap { $0 }
            .removeDuplicates { $0.title == $1.title && $0.artist == $1.artist && $0.app == $1.app }
            .filter(\.isPlaying)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in self?.notch.announce(info) }
            .store(in: &bag)

        hotKeys = [
            HotKey(id: 1, keyCode: kVK_Space, modifiers: optionKey) { [weak self] in self?.toggleVoice() },
            HotKey(id: 2, keyCode: kVK_ANSI_N, modifiers: optionKey | cmdKey) { [weak self] in self?.lookAtScreen(manual: true) },
            HotKey(id: 3, keyCode: kVK_Space, modifiers: optionKey | cmdKey) { [weak self] in self?.openAsk() }
        ].compactMap { $0 }

        // Connectors: local (calendar, reminders, notes, mail, browser, files, clipboard) and authenticated services.
        connectors.register([
            CalendarConnector(calendar: calendar),
            RemindersConnector(calendar: calendar),
            NotesConnector(),
            MailConnector(),
            BrowserConnector(),
            FilesConnector(),
            ClipboardConnector(),
            // Apps without an API: their local database, read-only (Messages and WhatsApp need Full Disk Access).
            MessagesConnector(),
            WhatsAppConnector(),
            BearConnector(),
            ThingsConnector()
        ])
        connectors.register(CloudConnectors.makeAll())
        // The crypto portfolio (PortfolioConnector) is switched off for now: not registered, not in Settings.
        // MCP servers from Settings, kept in line when the user adds or removes one.
        connectors.syncMCP(MCPServerStore.shared.servers)
        MCPServerStore.shared.$servers
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] servers in self?.connectors.syncMCP(servers) }
            .store(in: &bag)
        connectors.start()
        codex.homes = { [weak self] in
            guard let self else { return [] }
            return self.profiles.profiles(for: .codex).map { $0.homeURL }
        }
        codex.start()
        antigravityUsage.home = { [weak self] in self?.profiles.profiles(for: .antigravity).first?.homeURL ?? AgentKind.antigravity.defaultHome }
        antigravityUsage.start()
        claudeUsage.start()

        // Continuously index visible screen text locally so every query has immediate visual context.
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

        // ThinkAlong: evaluates dwell time periodically. Zero cost; model is only
        // invoked when ThinkAlong determines assistance is genuinely helpful.
        watchTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.thinkAlongTick() }
        }
    }

    // MARK: Stored state used by the extensions
    // Extensions cannot hold stored properties, so state that belongs to a feature lives here.

    /// The agent session open in the main window that Nook does not run itself ("live:<id>" or "past:<id>"), if any.
    @Published var selectedExternalSession: String?
    /// The first-run flow is showing in the main window.
    @Published var showOnboarding = false
    /// The Settings window (created on first use).
    var settingsWindow: NSWindow?
    /// Tracks the message currently streaming per conversation, and its task. Multiple conversations can run concurrently.
    var replies: [UUID: UUID] = [:]
    var chatTasks: [UUID: Task<Void, Never>] = [:]
    /// Pending proactive offer awaiting response, displayed temporarily in Today.
    @Published var missedNudge: (line: String, card: NookCard, app: String, date: Date)?
    /// Proposal cards that move into the chat when the user types a reply on them, by card ID.
    var cardReplies: [String: () -> Void] = [:]
}
