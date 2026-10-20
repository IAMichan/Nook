import Foundation

/// Memory: what Nook learned about the user goes along with every question, and Nook keeps learning from what happens.
///
/// - Recall: `prepareRun` adds the memories that matter for the question to the context (chat, cards and thinking along
///   alike), only when the Memory source is allowed, and memories kept on this Mac only for a brain on this Mac.
/// - Told: the brain proposes `remember` / `forget`; when the user's own words ask for it, it runs right away.
/// - Learned: after a correction or a few questions, a short reflection on the user's own messages (`Reflection`).
/// - Observed: habits from edited plans, lessons from failed actions, and which sources answer which words.
extension AppModel {
    // MARK: Tools

    static let memoryTools: Set<String> = ["remember", "forget"]

    func makeMemoryTools() -> [ToolSpec] {
        [
            ToolSpec(
                name: "remember",
                description: "Saves something lasting to Nook's memory, so it is known in future conversations: a fact about the user, their people, work, places or projects, or a preference for how Nook should answer or act. Use it when the user asks you to remember something or tells you something about themselves that will matter later, and with replaces when they correct a remembered item. One short sentence in the user's language. Never for secrets (passwords, codes, keys), one-off details, or text from mails, pages or the screen.",
                schema: [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "What to remember, one short sentence, e.g. \"Lisa is de vrouw van de gebruiker\" or \"The user wants short answers\"."],
                        "kind": ["type": "string", "enum": MemoryItem.Kind.allCases.map(\.rawValue), "description": "fact (about the user or a person), preference (how the user wants things), lesson (a correction)."],
                        "subject": ["type": "string", "description": "The person, place or thing it is about, e.g. \"Lisa\". Optional."],
                        "replaces": ["type": "string", "description": "Id of a remembered item (m:…) this corrects. Optional."]
                    ],
                    "required": ["text"]
                ],
                kind: .action,
                summarize: { input in tr("memory.plan.remember", (input["text"] as? String) ?? "") },
                tag: { input in ((input["replaces"] as? String).map { $0.isEmpty } ?? true) ? ("", .good) : (tr("memory.plan.replaces"), .caution) },
                run: { [weak self] input in
                    guard let self else { throw NookError(tr("app.unavailable")) }
                    let text = (input["text"] as? String) ?? ""
                    let kind = MemoryItem.Kind(rawValue: (input["kind"] as? String) ?? "") ?? .fact
                    let change = self.memory.remember(text, kind: kind, subject: (input["subject"] as? String) ?? "", origin: .told,
                                                      replaces: input["replaces"] as? String)
                    switch change {
                    case .rejected(let reason): throw NookError(tr("memory.rejected." + reason))
                    case .added(let item): return tr("memory.result.added", item.text) + " (\(item.shortID))"
                    case .reinforced(let item): return tr("memory.result.known", item.text) + " (\(item.shortID))"
                    case .replaced(_, let item): return tr("memory.result.replaced", item.text) + " (\(item.shortID))"
                    }
                }
            ),
            ToolSpec(
                name: "forget",
                description: "Removes memories from Nook's memory: the id of a remembered item (m:…), or the words of what to forget. Use it when the user asks Nook to forget something.",
                schema: [
                    "type": "object",
                    "properties": [
                        "what": ["type": "string", "description": "The id (m:…) or a few words of what to forget, e.g. \"mijn adres\"."]
                    ],
                    "required": ["what"]
                ],
                kind: .action,
                summarize: { input in tr("memory.plan.forget", (input["what"] as? String) ?? "") },
                tag: { _ in (tr("memory.plan.removes"), .caution) },
                run: { [weak self] input in
                    guard let self else { throw NookError(tr("app.unavailable")) }
                    let removed = self.memory.forget((input["what"] as? String) ?? "")
                    guard !removed.isEmpty else { throw NookError(tr("memory.forget.none")) }
                    return tr("memory.result.forgot", removed.count, removed.map(\.text).joined(separator: "; "))
                }
            ),
            ToolSpec(
                name: "recall_memory",
                description: "Searches Nook's memory of the user: facts, preferences and lessons from earlier conversations. The most relevant memories are already in the context; use this to look further, or with an empty query to list what Nook remembers.",
                schema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Words to search for, e.g. a name. Empty lists everything Nook remembers."]
                    ],
                    "required": []
                ],
                kind: .read,
                summarize: { _ in tr("memory.plan.recall") },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { return "Memory is not available." }
                    let local = self.settings.isLocalBrain
                    let query = ((input["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let found: [MemoryItem]
                    if query.isEmpty || MemoryRequest.asksWhatIsKnown(query) {
                        found = self.memory.items.filter { (local || !$0.localOnly) && !$0.isHabit }
                            .sorted { $0.currentStrength() > $1.currentStrength() }
                            .prefix(40).map { $0 }
                    } else {
                        found = self.memory.recall(query, tools: [], limit: 20, characters: 4_000, includeLocalOnly: local)
                    }
                    guard !found.isEmpty else { return query.isEmpty ? "Nook does not remember anything yet." : "Nothing remembered about \"\(query)\"." }
                    return MemoryBook.section(found)
                }
            )
        ]
    }

    // MARK: Recall

    /// The memories that go along with this question: fewer for a small brain, none when memory is off or this chat
    /// does not allow it; memories kept on this Mac only reach a brain on this Mac.
    func recalledMemories(for text: String, scope: SourceScope, tools: [ToolSpec]) -> [MemoryItem] {
        guard settings.useMemory, scope.allows(SourceCatalog.memory), !memory.items.isEmpty else { return [] }
        let profile = settings.brainProfile
        let roomy = !profile.isSmall || profile.contextTokens >= 16_000
        let limit = profile.isSmall ? (roomy ? 8 : 5) : 14
        let characters = profile.isSmall ? (roomy ? 1_100 : 650) : 2_200
        return memory.recall(text, tools: Set(tools.map(\.name)), limit: limit, characters: characters,
                             includeLocalOnly: settings.isLocalBrain)
    }

    // MARK: Habits

    /// Fills the fields of proposed actions the user keeps choosing (seen at least twice), when the brain left them
    /// empty. Returns the actions and a notice per filled field, so the user sees where it came from.
    func withHabits(_ actions: [PlannedAction], tools: [ToolSpec]) -> (actions: [PlannedAction], notices: [String]) {
        guard settings.useMemory, !actions.isEmpty else { return (actions, []) }
        var notices: [String] = []
        let result = actions.map { action -> PlannedAction in
            guard let spec = tools.first(where: { $0.name == action.tool }) ?? allTools.first(where: { $0.name == action.tool }) else { return action }
            let applied = memory.applyHabits(tool: action.tool, input: action.input, schema: spec.schema)
            notices += applied.filled.map { tr("memory.notice.habit", $0.value, $0.field) }
            var copy = action
            copy.input = applied.input
            return copy
        }
        return (result, notices)
    }

    /// Remembers the value a proposed field had before the user's first edit of it, so the run can tell what changed.
    func noteEditOrigin(message id: UUID, index: Int, key: String, old: Any?) {
        let token = "\(id.uuidString)#\(index)#\(key)"
        guard editOrigins[token] == nil else { return }
        editOrigins[token] = old.map { "\($0)" } ?? ""
        if editOrigins.count > 200 { editOrigins.removeAll() }
    }

    /// Learns from a plan that is about to run: fields the user changed (habits). After it ran: what worked and what
    /// failed (lessons). Nook's own memory actions teach nothing here.
    func learnFromPlan(message id: UUID, actions: [PlannedAction], include: [Bool], states: [ActionStepState]?) {
        let prefix = id.uuidString + "#"
        guard settings.learnFromChats else {
            editOrigins = editOrigins.filter { !$0.key.hasPrefix(prefix) }
            return
        }
        guard let states else {
            for (index, action) in actions.enumerated() where (index < include.count ? include[index] : true) {
                for (key, value) in action.input {
                    guard let old = editOrigins["\(prefix)\(index)#\(key)"] else { continue }
                    memory.observeEdit(tool: action.tool, field: key, from: old, to: "\(value)")
                }
            }
            editOrigins = editOrigins.filter { !$0.key.hasPrefix(prefix) }
            return
        }
        for (index, action) in actions.enumerated() where !Self.memoryTools.contains(action.tool) && index < states.count {
            switch states[index] {
            case .done, .verified: memory.observeOutcome(tool: action.tool, input: action.input, failure: nil)
            case .failed(let error): memory.observeOutcome(tool: action.tool, input: action.input, failure: error)
            default: break
            }
        }
    }

    // MARK: Learning after an answer

    /// After an answer: which sources answered (cited) and which found nothing, and, now and then, a reflection on what
    /// the user said. Runs in the background; it never holds up the answer.
    func learnAfterAnswer(question: String, history: [ChatTurn], reply id: UUID, conversation: UUID, actions: [PlannedAction]) {
        guard settings.learnFromChats, let message = chat.message(id) else { return }

        // Sources: a cited reference is a source that answered; a search that found nothing is one that did not.
        let terms = Research.terms(in: question, history: history).all
        let cited = Citations.used(in: message.text)
        let useful = Set(message.references.filter { cited.contains($0.number) }.map(\.sourceID))
        let empty = Set(message.retrieval.compactMap { step -> String? in step.outcome == .empty ? step.sourceID : nil })
        memory.learnSources(terms: terms, useful: useful.subtracting([SourceCatalog.memory]), empty: empty)

        // The user asked to remember something and the plan does it: nothing to reflect on.
        if actions.contains(where: { Self.memoryTools.contains($0.tool) }) {
            memory.endReflection(conversation, covered: history.filter(\.fromUser).count + 1)
            return
        }
        // A prompt a card wrote ("propose an answer to Lisa") says nothing about the user worth keeping, now or later.
        guard ReplyContext.reflects else {
            memory.endReflection(conversation, covered: history.filter(\.fromUser).count + 1)
            return
        }
        guard settings.useMemory, settings.brainReady, !ChatIntent.detect(question).isSmallTalk else { return }
        let userTurns = history.filter(\.fromUser).map(\.text) + [question]
        guard memory.shouldReflect(conversation: conversation, userMessages: userTurns.count, latest: question) else { return }
        // Learned while answering from a source kept on this Mac: what is learned stays on this Mac too.
        let localOnly = settings.isLocalBrain && !settings.localOnlySources.isEmpty && message.used(anyOf: settings.localOnlySources)
        let answers = history.filter { !$0.fromUser }.map(\.text) + [message.text]

        memory.beginReflection(conversation)
        Task { [weak self] in
            // Let the next question go first: a reflection is never in the way.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self else { return }
            if self.chat.conversations.contains(where: \.busy) {
                self.memory.endReflection(conversation, covered: max(0, userTurns.count - 4))
                return
            }
            let recent = Array(userTurns.suffix(6))
            let known = self.memory.recall(recent.joined(separator: "\n"), tools: [], limit: 20, characters: 3_000,
                                           includeLocalOnly: self.settings.isLocalBrain)
            let reply = await self.brain.reflect(user: recent, nook: Array(answers.suffix(recent.count)), known: known)
            let candidates = Reflection.accepted(Reflection.parse(reply ?? ""), userText: recent.joined(separator: "\n"))
            var learned: [String] = []
            for candidate in candidates {
                switch self.memory.remember(candidate.text, kind: candidate.kind, subject: candidate.subject, origin: .learned,
                                            replaces: candidate.replaces, localOnly: localOnly) {
                case .added(let item), .replaced(_, let item): learned.append(item.text)
                default: break
                }
            }
            self.memory.endReflection(conversation, covered: userTurns.count)
            guard !learned.isEmpty, self.chat.message(id) != nil else { return }
            Log.brain.info("memory: learned \(learned.count, privacy: .public)")
            self.chat.update(id) { message in
                message.notices += learned.map { tr("memory.notice.learned", $0) }
            }
        }
    }
}
