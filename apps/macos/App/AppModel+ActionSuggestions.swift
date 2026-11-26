import Foundation

/// The steps Nook suggests from what a conversation says (`ChatActionSuggestion`), for a chat of any chat app, an
/// agent's session and Nook Chat alike: once new lines could ask for something (`worthALook`, decided on the Mac at
/// once), the brain reads them with a few of Nook's tools and proposes what it can do; `ActionSuggestionBar` shows it
/// above the field, and nothing runs until you click.
@MainActor
extension AppModel {
    /// What Nook would do for this conversation now: at most a couple of steps and why, or none. `fresh`: how many of the
    /// last lines are new since the last look; `handled`: what was already offered in it, so that is not offered again.
    func suggestActions(place: ChatActionSuggestion.Place, lines: [ChatActionSuggestion.Line], fresh: Int,
                        handled: [String]) async -> ActionSuggestionFound {
        guard settings.actionSuggestionsReady, !lines.isEmpty else { return ActionSuggestionFound() }
        let prompt = ChatActionSuggestion.prompt(place: place, lines: lines, fresh: fresh, projects: agentProjectFolders(),
                                                 handled: handled, dateSheet: ChatIntent.dateSheet())
        // Only the tools a suggestion can use: a small request answers fast.
        let wanted = Set(ChatActionSuggestion.preferredTools)
        let tools = draftTools { _ in }.filter { wanted.contains($0.name) }
        let box = SuggestionPlanBox()
        // The model chosen for suggestions, else the brain itself (Settings › Autocomplete).
        await ScreenBrain.$routed.withValue(settings.actionSuggestionBrain) {
            _ = try? await RetrievalLedger.withTimeout(ChatActionSuggestion.timeout) { [brain] in
                box.plan = try await brain.writeInChat(system: ChatActionSuggestion.system, prompt: prompt,
                                                       request: ChatActionSuggestion.request(lines), tools: tools,
                                                       preferring: ChatActionSuggestion.preferredTools,
                                                       rounds: ChatActionSuggestion.rounds)
                return ""
            }
        }
        guard let plan = box.plan, !plan.actions.isEmpty, ChatActionSuggestion.backed(plan.text) else { return ActionSuggestionFound() }
        let steps = zip(plan.actions, planSteps(plan.actions)).map { ChatDraftAction(action: $0.0, step: $0.1) }
        let complete = steps.filter { ChatActionSuggestion.complete(tool: $0.action.tool, input: $0.action.input) }
        let kept = ChatActionSuggestion.keep(complete, tool: { $0.action.tool }, summary: { $0.step.text }, handled: handled)
        let reason = plan.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ActionSuggestionFound(actions: kept, reason: kept.isEmpty ? nil : TextKit.clip(reason, to: 200, wordBoundary: true))
    }

    /// A chat card's lines in the notch: the chat the card shows.
    static func cardActionLines(_ card: NookCard) -> [ChatActionSuggestion.Line] {
        guard card.chatReply, case .chat(let bubbles) = card.detail else { return [] }
        return ChatActionSuggestion.lines(bubbles, contact: card.title)
    }

    /// The app a chat card's chat is in, named as the brain reads it.
    static func cardActionPlace(_ card: NookCard) -> ChatActionSuggestion.Place {
        let thread = chatCardThread(card).flatMap { ChatCaptureService.shared.loadedInbox.threads[$0] }
        let app = thread.map { MessagingApps.app(id: $0.app)?.name ?? $0.app } ?? card.replyCopiesTo ?? card.context
        return .chat(app: app, name: card.title)
    }

    /// An agent session's turn for a suggested step: the agent's last reply, so Nook looks once the turn has ended.
    func agentSuggestionTurn(_ runID: UUID) -> ChatActionSuggestion.Turn? {
        guard let reply = NextPromptSuggestion.lastReply(workspace.timeline(runID)) else { return nil }
        return ChatActionSuggestion.Turn(conversation: "agent:" + runID.uuidString, message: reply.id.uuidString, date: reply.date)
    }

    /// An agent's session as lines, every agent alike: your messages and its replies (`NextPromptSuggestion.messages`).
    /// None for a session Nook delegated itself.
    func agentActionLines(_ runID: UUID) -> [ChatActionSuggestion.Line] {
        guard let run = workspace.run(runID), run.delegation == nil else { return [] }
        let agent = run.provider.displayName
        return NextPromptSuggestion.messages(workspace.timeline(runID)).suffix(12).map { message in
            ChatActionSuggestion.Line(speaker: message.role == .user ? tr("chat.you") : agent, text: message.text,
                                      mine: message.role == .user)
        }
    }

    func agentActionPlace(_ runID: UUID) -> ChatActionSuggestion.Place {
        let run = workspace.run(runID)
        return .agent(name: run?.provider.displayName ?? "", title: run?.title ?? "")
    }

    /// The same for a session Nook does not run (an agent in a terminal it sees through hooks or its transcript): its
    /// last prompt and reply are all Nook knows of it, so the turn is that reply.
    func agentSuggestionTurn(_ session: AgentSession) -> ChatActionSuggestion.Turn? {
        let reply = session.lastReply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return nil }
        return ChatActionSuggestion.Turn(conversation: "session:" + session.id, message: String(reply.hashValue), date: session.updated)
    }

    static func agentActionLines(_ session: AgentSession) -> [ChatActionSuggestion.Line] {
        [ChatActionSuggestion.Line(speaker: tr("chat.you"), text: session.lastPrompt, mine: true),
         ChatActionSuggestion.Line(speaker: session.name, text: session.lastReply)]
    }

    /// Nook Chat as lines: your questions and Nook's answers.
    static func nookActionLines(_ messages: [ChatMessage]) -> [ChatActionSuggestion.Line] {
        messages.suffix(12).map { message in
            ChatActionSuggestion.Line(speaker: message.role == .user ? tr("chat.you") : "Nook", text: message.text,
                                      id: message.id.uuidString, mine: message.role == .user)
        }
    }

    /// "Adjust first" on a suggested agent session: the new-session composer on its project, with the task in the box to
    /// read and change before you start it.
    func adjustSuggestedAction(_ action: PlannedAction) {
        guard action.tool == ActionSuggestionBar.adjustableTool else { return }
        let task = ((action.input["task"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = agentFolder(named: (action.input["folder"] as? String) ?? "", among: agentProjectFolders())
        openWorkspace(newSession: true)
        if let folder {
            PromptLinkInbox.shared.requestProject(folder, text: task)
        }
    }
}

/// What a look at a conversation found: the steps to offer and why.
struct ActionSuggestionFound {
    var actions: [ChatDraftAction] = []
    var reason: String? = nil
}

/// Holds the plan across the timeout that bounds the look.
@MainActor
private final class SuggestionPlanBox {
    var plan: BrainPlan?
}

/// The suggested steps of every conversation, shared by every place a conversation shows (the Chats tab and a chat card,
/// the Agents tab and the session window) so it is asked once and reads the same. A look only when new lines say more
/// than a reaction (`ChatActionSuggestion.worthALook`) and the pace allows (`ChatActionSuggestion.Pace`: a few minutes
/// apart per conversation, quiet a while after a dismissal), and a suggestion only when it clears the bar
/// (`ChatActionSuggestion.system`, `backed`, `complete`).
@MainActor
final class ChatActionSuggestions: ObservableObject {
    static let shared = ChatActionSuggestions()

    /// A conversation's suggestion: the turn it was last considered for, whether a look is under way, and the steps on
    /// offer with how running them went.
    struct State: Equatable {
        var turn: ChatActionSuggestion.Turn
        var looking: Bool
        var actions: [ChatDraftAction] = []
        var reason: String?
        var run = ChatDraftActionRun.waiting
    }

    /// What the pace remembers of a conversation.
    private struct History {
        var seen: String?
        var lastLook: Date?
        var dismissed: Date?
        var offered: [String] = []
    }

    @Published private(set) var states: [String: State] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var history: [String: History] = [:]
    /// Every look in the last hour, over all conversations.
    private var looks: [Date] = []

    /// The steps to show for a conversation now, if any.
    func shown(_ conversation: String) -> State? {
        guard let state = states[conversation], !state.actions.isEmpty else { return nil }
        return state
    }

    /// A conversation is on screen with `turn` its newest message. A moment after it came Nook checks the new lines on
    /// the Mac and, only when they could ask for something and the pace allows, asks the brain once. Called again
    /// whenever the turn or `busy` changes.
    func request(_ turn: ChatActionSuggestion.Turn?, busy: Bool, place: ChatActionSuggestion.Place,
                 lines: @escaping () -> [ChatActionSuggestion.Line]) {
        guard let turn else { return }
        let key = turn.conversation
        let settings = AppSettings.shared
        let gate = ChatActionSuggestion.Gate(
            enabled: settings.suggestChatActions, brainReady: settings.actionSuggestionsReady,
            alreadyTried: states[key]?.turn == turn, stale: ChatActionSuggestion.Gate.isStale(turn.date), busy: busy)
        guard gate.allows else { return }
        var state = states[key] ?? State(turn: turn, looking: false)
        state.turn = turn
        // A proposal that ran or failed belongs to its moment; one still waiting for you stays up.
        if state.run != .waiting, state.run != .running {
            state.actions = []
            state.reason = nil
            state.run = .waiting
        }
        states[key] = state
        tasks[key]?.cancel()
        tasks[key] = Task { [weak self] in
            try? await Task.sleep(for: ChatActionSuggestion.settle)
            guard let self, !Task.isCancelled, self.states[key]?.turn == turn else { return }
            await self.look(key, turn: turn, place: place, lines: lines())
        }
    }

    private func look(_ key: String, turn: ChatActionSuggestion.Turn, place: ChatActionSuggestion.Place,
                      lines: [ChatActionSuggestion.Line]) async {
        let now = Date()
        looks.removeAll { now.timeIntervalSince($0) > 3600 }
        var past = history[key] ?? History()
        let fresh = ChatActionSuggestion.newLines(lines, since: past.seen)
        guard !fresh.isEmpty, ChatActionSuggestion.worthALook(fresh, place: place) else {
            // Nothing that could ask for a step: the next look starts after these lines.
            past.seen = lines.last?.key ?? past.seen
            history[key] = past
            return
        }
        let pace = ChatActionSuggestion.Pace(lastLook: past.lastLook, waiting: shown(key) != nil, looksThisHour: looks.count,
                                             dismissed: past.dismissed)
        // Not now: these lines stay new, so the next look (for a later message) still reads them.
        guard pace.allows(now: now) else { return }
        past.seen = lines.last?.key ?? past.seen
        past.lastLook = now
        history[key] = past
        looks.append(now)
        states[key]?.looking = true
        let found = await AppModel.shared.suggestActions(place: place, lines: lines, fresh: fresh.count, handled: past.offered)
        tasks[key] = nil
        guard !Task.isCancelled, var current = states[key], current.turn == turn else {
            states[key]?.looking = false
            return
        }
        current.looking = false
        if !found.actions.isEmpty, current.run != .running {
            current.actions = found.actions
            current.reason = found.reason
            current.run = .waiting
            history[key]?.offered.append(contentsOf: found.actions.map(\.step.text))
        }
        states[key] = current
    }

    /// Do it: the steps run through `act`, one after another, as a plan in Nook Chat does.
    func run(_ conversation: String, act: @escaping ([PlannedAction]) async -> (results: [String], failure: String?)) {
        guard var state = states[conversation], !state.actions.isEmpty, state.run == .waiting else { return }
        state.run = .running
        states[conversation] = state
        let actions = state.actions.map(\.action)
        Task { [weak self] in
            let outcome = await act(actions)
            guard let self, var current = self.states[conversation], current.run == .running else { return }
            if let failure = outcome.failure {
                current.run = .failed(failure)
            } else {
                current.run = .done(outcome.results.count == 1 ? outcome.results[0] : tr("chat.plan.allDone", outcome.results.count))
            }
            self.states[conversation] = current
        }
    }

    /// The cross: the steps go without running (they are not offered again), or are put away once done.
    func dismiss(_ conversation: String) {
        guard var state = states[conversation], state.run != .running else { return }
        // Dismissing a proposal that still waited says this conversation needs no help now: quiet for a while.
        if state.run == .waiting, !state.actions.isEmpty {
            history[conversation, default: History()].dismissed = Date()
        }
        state.actions = []
        state.reason = nil
        state.run = .waiting
        states[conversation] = state
    }
}
