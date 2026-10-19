import SwiftUI
import Combine
import AppKit
import Carbon.HIToolbox
import NaturalLanguage

/// Plans: validating, editing and running the actions Nook proposes, and the shared plan card.
extension AppModel {
    /// Formatted plan steps as presented in chat and action cards.
    func planSteps(_ actions: [PlannedAction]) -> [PlanStep] {
        actions.enumerated().map { index, action in
            let spec = allTools.first { $0.name == action.tool }
            let tag = spec?.tag(action.input) ?? ("", .neutral)
            return PlanStep(number: index + 1, text: spec?.summarize(action.input) ?? action.tool, tag: tag.0, tone: tag.1)
        }
    }

    /// Validation issues for proposed action: missing tool, disallowed source, or invalid input.
    func actionProblems(_ action: PlannedAction, scope: SourceScope) -> [String] {
        guard let spec = allTools.first(where: { $0.name == action.tool }), spec.kind == .action else {
            return [tr("chat.plan.unavailable", action.tool)]
        }
        guard scope.allowsTool(action.tool) else {
            return [tr("chat.plan.notAllowed", SourceCatalog.source(forTool: action.tool).map(SourceCatalog.title) ?? action.tool)]
        }
        // Checked again at run time: the account must still be allowed in this chat.
        if let service = SourceCatalog.source(forTool: action.tool), let chosen = action.input["account"] as? String,
           let account = AccountRegistry.match(chosen, in: AccountRegistry.shared.accounts(for: service)), !scope.allowsAccount(account.id) {
            return [tr("chat.account.notAllowed", chosen)]
        }
        let schema = Self.restrictAccounts(spec, to: scope)?.schema ?? spec.schema
        return ActionGate.problems(tool: action.tool, input: action.input, schema: schema, parseDate: NookDates.parse)
    }

    /// Executes enabled plan steps. Resuming after an error picks up from where it stopped:
    /// already completed steps are skipped. `force`: allows running steps previously flagged as duplicate.
    func runPlan(_ id: UUID, force: Set<Int> = []) {
        guard let message = chat.message(id), !message.actions.isEmpty, message.planState != .running, message.planState != .cancelled else { return }
        if case .done = message.planState, force.isEmpty { return }
        let scope = chat.conversationID(of: id).flatMap { chat.conversation($0)?.scope } ?? .automatic
        let steps = message.actions.map { PlanRunner.Step(tool: $0.tool, input: $0.input) }
        // Fields the user changed before running teach Nook their habits.
        learnFromPlan(message: id, actions: message.actions, include: message.actionIncluded, states: nil)
        store.audit(tool: "plan_goedgekeurd", args: planSteps(message.actions).enumerated()
            .filter { index, _ in index < message.actionIncluded.count ? message.actionIncluded[index] : true }
            .map(\.element.text).joined(separator: " | "), result: "")
        chat.update(id) { $0.planState = .running }
        let runner = planRunner(scope: scope) { [weak self] states in
            self?.chat.update(id) { $0.actionStates = states }
        }
        Task {
            let states = await runner.run(steps, states: message.actionStates, include: message.actionIncluded, force: force)
            learnFromPlan(message: id, actions: message.actions, include: message.actionIncluded, states: states)
            reloadLoops()
            await refreshUpcoming()
            let outcome = Self.planOutcome(states)
            chat.update(id) { message in
                message.actionStates = states
                message.planState = outcome
            }
            // A plan of several steps that all went through: a small celebration.
            let succeeded = states.filter { state in
                switch state {
                case .done, .verified: return true
                default: return false
                }
            }
            if case .done = outcome, succeeded.count > 1 { NookPresence.shared.celebrate() }
        }
    }

    /// Summary line describing plan completion.
    static func planOutcome(_ states: [ActionStepState]) -> ChatMessage.PlanState {
        var done: [String] = []
        var failure: String?
        for (index, state) in states.enumerated() {
            switch state {
            case .done(let result), .verified(let result): done.append(result)
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

    func planRunner(scope: SourceScope, progress: @escaping ([ActionStepState]) -> Void = { _ in }) -> PlanRunner {
        PlanRunner(
            check: { [weak self] step in
                guard let self else { return [tr("app.unavailable")] }
                return self.actionProblems(PlannedAction(tool: step.tool, input: step.input), scope: scope)
            },
            execute: { [weak self] step in
                guard let self, let found = self.allTools.first(where: { $0.name == step.tool }), found.kind == .action,
                      // The same account rules as when the plan was made: one allowed account is filled in, others refused.
                      let spec = Self.restrictAccounts(found, to: scope) else {
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
            progress: progress,
            verify: { [weak self] step, result in await self?.verify(step, result: result) }
        )
    }

    /// Reads the result of an action back where that is possible on the Mac itself. nil = cannot be checked.
    func verify(_ step: PlanRunner.Step, result: String) async -> Bool? {
        switch step.tool {
        case "create_event":
            guard let id = Self.createdID(in: result) else { return nil }
            return calendar.eventExists(id)
        case "update_event":
            guard let id = step.input["id"] as? String else { return nil }
            return calendar.eventExists(id)
        case "create_reminder":
            guard let id = Self.createdID(in: result) else { return nil }
            return calendar.reminderExists(id)
        default:
            return nil
        }
    }

    /// The "(id …)" a create tool puts in its result.
    nonisolated static func createdID(in result: String) -> String? {
        guard let range = result.range(of: #"\(id ([^)]+)\)"#, options: .regularExpression) else { return nil }
        return String(result[range].dropFirst(4).dropLast()).trimmingCharacters(in: .whitespaces)
    }

    func cancelPlan(_ id: UUID) {
        store.audit(tool: "plan_geannuleerd", args: chat.message(id).map { planSteps($0.actions).map(\.text).joined(separator: " | ") } ?? "", result: "")
        chat.update(id) { $0.planState = .cancelled }
    }

    /// Toggle an individual action step before running.
    func setActionIncluded(_ id: UUID, index: Int, _ on: Bool) {
        chat.update(id) { message in
            guard index < message.actionIncluded.count, message.actionStates[safe: index]?.isFinished != true || !on else { return }
            message.actionIncluded[index] = on
        }
    }

    /// Modifies proposed action inputs (e.g. message text) and re-validates.
    func editAction(_ id: UUID, index: Int, key: String, value: String) {
        guard let message = chat.message(id), index < message.actions.count else { return }
        if (message.actionStates[safe: index] ?? .pending).result != nil { return }
        let scope = chat.conversationID(of: id).flatMap { chat.conversation($0)?.scope } ?? .automatic
        var action = message.actions[index]
        noteEditOrigin(message: id, index: index, key: key, old: action.input[key])
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

    /// Detailed input payload for an action step before execution.
    func actionFields(_ action: PlannedAction) -> [ActionField] {
        let schema = allTools.first { $0.name == action.tool }?.schema ?? [:]
        return ActionGate.fields(action.input, schema: schema)
    }

    // MARK: Plan Execution

    func planCard(_ plan: BrainPlan, context: String?, offers: [String] = []) -> NookCard {
        guard !plan.actions.isEmpty else { return answerCard(plan.text, offers: offers) }

        let token = "plan-" + UUID().uuidString
        let title = plan.text.isEmpty ? tr("app.plan.title") : String(plan.text.prefix(160))
        let titleLines = max(1, Int(ceil(Double(title.count) / 46.0)))

        let steps = planSteps(plan.actions)

        var detail: CardDetail = .steps(steps)
        var detailHeight = CGFloat(steps.count * 30)
        var contextLine = context ?? tr(steps.count == 1 ? "app.plan.steps.one" : "app.plan.steps.many", steps.count)
        var primaryLabel = tr("app.plan.run")

        if plan.actions.count == 1, plan.actions[0].tool == "create_event",
           let start = NookTools.parseDate(plan.actions[0].input, "start") {
            let input = plan.actions[0].input
            let end = NookTools.parseDate(input, "end") ?? start.addingTimeInterval(3600)
            let location = (input["location"] as? String) ?? ""
            detail = .event(
                top: NookDates.weekdayCaps(start),
                big: NookDates.dayNumber(start),
                line: "\(NookDates.time(start)) – \(NookDates.time(end))" + (location.isEmpty ? "" : " · \(location)"),
                subline: tr("app.plan.event", (input["title"] as? String) ?? tr("app.plan.appointment"))
            )
            detailHeight = 36
            contextLine = context ?? tr("app.plan.proposal")
            primaryLabel = tr("app.plan.add")
        }

        viewModel.register("\(token)#run") { [weak self] in
            self?.cardReplies[token] = nil
            self?.continueInChat(plan, title: title, offers: offers)
        }
        registerCardReply(token) { [weak self] in self?.continueInChat(plan, title: title, offers: offers, run: false) }

        let cancel = CardAction(label: tr("button.cancel"), outcome: .dismiss)
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

    /// Safe actions that can run without prompt when Auto-run Safe Actions is enabled: easily reversible
    /// and without side effects on third parties. Events, emails, links, shortcuts require approval.
    static let safeTools: Set<String> = ["media_control", "set_volume", "open_app", "add_open_loop", "create_reminder", "complete_open_loop"]

    /// Only when the user's own words ask for each action. The prompt also carries text from others (screen, mail, web, invites),
    /// and such text must never be enough to make Nook act without a click. `request == nil` means no user request is known.
    func canRunWithoutAsking(_ plan: BrainPlan, request: String?) -> Bool {
        guard !plan.actions.isEmpty, let request else { return false }
        // Remembering or forgetting what the user's own words ask for: it stays on this Mac and is undone in
        // Settings › Memory, so it needs no click (and no "small things" setting).
        if plan.actions.allSatisfy({ Self.memoryTools.contains($0.tool) && Self.request(request, asksFor: $0) }) { return true }
        guard settings.autoRunSafe else { return false }
        return plan.actions.allSatisfy { Self.safeTools.contains($0.tool) && Self.request(request, asksFor: $0) }
    }

    nonisolated static func request(_ request: String, asksFor action: PlannedAction) -> Bool {
        let text = request.lowercased()
        func mentions(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        switch action.tool {
        case "open_app":
            let name = ((action.input["name"] as? String) ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            return !name.isEmpty && text.contains(name) && mentions(#"\b(open|start|launch|öffne|starte)"#)
        case "media_control":
            return mentions(#"muziek|music|musik|nummer|liedje|song|track|speel|play|pauze|pause|stop|volgende|vorige|next|previous|skip|shuffle|herhaal|repeat"#)
        case "set_volume":
            return mentions(#"volume|geluid|harder|zachter|louder|quieter|lauter|leiser|mute|dempen"#)
        case "create_reminder":
            return mentions(#"herinner|reminder|erinner|onthoud|remember"#)
        case "remember":
            // Only what the user said: a memory planted by text on screen or in a mail is never stored without a click.
            let memory = (action.input["text"] as? String) ?? ""
            return MemoryRequest.asksToRemember(request) && MemoryText.grounded(memory, in: request)
        case "forget":
            let what = (action.input["what"] as? String) ?? ""
            return MemoryRequest.asksToForget(request) && MemoryText.grounded(what, in: request)
        case "add_open_loop", "complete_open_loop":
            return mentions(#"onthoud|noteer|open punt|todo|to-do|taak|taken|remember|note|aufgabe|afgerond|klaar|done|erledigt"#)
        default:
            return false
        }
    }

    /// An accepted proposal from a card continues in the chat, in a conversation of its own: the proposal becomes Nook's message
    /// and its plan runs there, so the outcome stays visible and a follow-up can steer it. `run: false` only places it,
    /// for when the user replies to the card instead of accepting it.
    func continueInChat(_ plan: BrainPlan, title: String, sources: [String] = [], offers: [String] = [], run: Bool = true) {
        let conversation = chat.startNew()
        chat.rename(conversation, to: Conversation.title(from: title))
        var message = ChatMessage(role: .nook, text: plan.text)
        message.sources = sources
        message.offers = offers
        message.actions = plan.actions
        message.actionStates = Array(repeating: .pending, count: plan.actions.count)
        message.actionIncluded = Array(repeating: true, count: plan.actions.count)
        message.actionProblems = plan.actions.map { actionProblems($0, scope: .automatic) }
        chat.append(message, to: conversation)
        showChat()
        if run, !plan.actions.isEmpty { runPlan(message.id) }
    }

    /// A reply typed on a proposal card: the proposal moves into the chat first, so the question is answered with it in view.
    func handleCardReply(_ text: String, card: NookCard) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !question.isEmpty, settings.brainReady, let adopt = cardReplies.removeValue(forKey: card.id) {
            warmUp()
            adopt()
            ask(question)
        } else {
            handleUserText(text)
        }
    }

    /// Remembers how a proposal card moves into the chat when the user replies to it.
    func registerCardReply(_ cardID: String, _ adopt: @escaping () -> Void) {
        if cardReplies.count > 12 { cardReplies.removeAll() }
        cardReplies[cardID] = adopt
    }

    func execute(_ plan: BrainPlan) {
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

    /// Executes approved actions sequentially; stops at first error. Logged to ledger.
    /// Validates tool availability and parameters; reports errors and avoids re-running recent duplicates.
    /// Reports failure clearly and deduplicates recently completed actions.
    func perform(_ actions: [PlannedAction]) async -> (results: [String], failure: String?) {
        let steps = actions.map { PlanRunner.Step(tool: $0.tool, input: $0.input) }
        let states = await planRunner(scope: .automatic).run(steps, states: [], include: Array(repeating: true, count: steps.count))
        reloadLoops()
        await refreshUpcoming()
        var results: [String] = []
        for state in states { if let result = state.result { results.append(result) } }
        if case .failed(let failure) = Self.planOutcome(states) { return (results, failure) }
        return (results, nil)
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
