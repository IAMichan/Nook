import Foundation

/// What Nook could do next, on the phone (`CompanionFeature.actionSuggestions`, `CompanionSuggestions.swift`): the steps
/// of the Mac's `ChatActionSuggestions`, the store every conversation's suggestion bar reads, for the conversation a
/// phone has open. The Mac looks while a phone shows a conversation, as its own bar asks when it is on screen (same gate,
/// same pace); *Do it* runs through `runDraftActions` as the bar's button does, after your tap on the phone.
extension CompanionServer {
    // MARK: What the phone sees

    /// The steps on offer for the conversation with the Mac's key `key`, as the phone shows them; nil when none.
    static func suggestion(_ key: String) -> ActionSuggestionDigest? {
        guard let state = ChatActionSuggestions.shared.shown(key) else { return nil }
        let steps = state.actions.prefix(ActionSuggestionDigest.stepLimit).map {
            ActionSuggestionDigest.Step(text: CompanionPolicy.clip($0.step.text, limit: 300), symbol: $0.symbol)
        }
        var digest = ActionSuggestionDigest(conversation: key, steps: Array(steps),
                                            reason: state.reason.map { CompanionPolicy.clip($0, limit: 300) }, state: .waiting)
        switch state.run {
        case .waiting: digest.state = .waiting
        case .running: digest.state = .running
        case .done(let result):
            digest.state = .done
            digest.result = CompanionPolicy.clip(result, limit: 300)
        case .failed(let reason):
            digest.state = .failed
            digest.result = CompanionPolicy.clip(reason, limit: 300)
        }
        return digest
    }

    // MARK: Looking while a phone shows the conversation

    /// An agent's session on the phone's screen: once its turn ended, Nook looks for what it could do next.
    static func lookForSuggestion(session: UUID, app: AppModel) {
        guard let run = app.workspace.run(session) else { return }
        ChatActionSuggestions.shared.request(app.agentSuggestionTurn(session), busy: run.status.isActive,
                                             place: app.agentActionPlace(session),
                                             lines: { [app] in app.agentActionLines(session) })
    }

    /// A chat with Nook on the phone's screen: once Nook's answer is written.
    static func lookForSuggestion(conversation: UUID, app: AppModel) {
        guard let found = app.chat.conversation(conversation), let last = found.messages.last else { return }
        let turn = last.role == .nook && !last.streaming
            ? ChatActionSuggestion.Turn(conversation: "nook:" + conversation.uuidString, message: last.id.uuidString, date: last.date)
            : nil
        // As the Nook tab: not while Nook answers, nor when its answer proposes steps of its own or failed.
        let busy = found.busy || !last.actions.isEmpty || last.isError
        ChatActionSuggestions.shared.request(turn, busy: busy, place: .nook,
                                             lines: { AppModel.nookActionLines(found.messages) })
    }

    /// A chat of your apps on the phone's screen: its newest message.
    func lookForSuggestion(chat entry: ChatsEntry, app: AppModel) {
        guard let thread = visibleThread(entry) else { return }
        let bubbles = ChatBubble.bubbles(thread, last: 30) { _ in "" }
        let appName = MessagingApps.app(id: entry.app)?.name ?? entry.app
        ChatActionSuggestions.shared.request(ChatActionSuggestion.turn(chat: entry.id, bubbles: bubbles), busy: false,
                                             place: .chat(app: appName, name: entry.name),
                                             lines: { ChatActionSuggestion.lines(bubbles, contact: entry.name) })
    }

    // MARK: Do it, or put away

    func suggestionAct(_ request: CompanionRequest, app: AppModel) -> CompanionResponse {
        guard let key = request.item, !key.isEmpty, let act = request.text.flatMap(SuggestionAct.init(rawValue:)) else {
            return .failure(request.id, .badRequest)
        }
        let store = ChatActionSuggestions.shared
        guard let state = store.shown(key) else { return .failure(request.id, .unknownItem) }
        switch act {
        case .run:
            guard state.run == .waiting else { return .failure(request.id, .busy) }
            store.run(key) { [app] in await app.runDraftActions($0) }
            audit("suggestion_run", state.actions.map(\.step.text).joined(separator: " · "))
        case .dismiss:
            store.dismiss(key)
            audit("suggestion_dismiss", key)
        }
        var response = CompanionResponse(id: request.id, ok: true, sessions: digests(app))
        response.suggestion = Self.suggestion(key)
        return response
    }
}
