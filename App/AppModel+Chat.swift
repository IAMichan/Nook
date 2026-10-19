import SwiftUI
import Combine
import AppKit
import Carbon.HIToolbox
import NaturalLanguage

/// Asking Nook: one question becomes a streaming answer with sources, charts, mail drafts and a plan.
extension AppModel {
    // MARK: Asking Nook

    func handleUserText(_ raw: String, images: [ImageAttachment] = []) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        // A picture without a question: ask what is on it.
        if text.isEmpty { text = tr("image.defaultQuestion") }
        NookPresence.shared.heard()

        // Short deterministic commands handled locally without querying the brain: instant execution.
        if images.isEmpty, let intent = LocalIntent.parse(text) {
            // In chat mode, keep the flow: music and time queries are replied to inline.
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
        ask(text, images: images)
    }

    // MARK: Chat


    /// Opens chat view. `focus`: activates text field for typing.
    func showChat(focus: Bool = true) {
        viewModel.focusChat = focus
        viewModel.show(.panel(.chat))
    }

    /// Starts a new conversation. Any running background conversation continues.
    func newChat() {
        chat.startNew()
        attachment = nil
        showChat()
    }

    func openConversation(_ id: UUID) {
        chat.select(id)
        showChat()
    }

    /// Cancels generation for the active conversation.
    func stopChat() {
        guard let id = chat.activeID else { return }
        stop(conversation: id)
    }

    func stop(conversation: UUID) {
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

    /// Collects charts and mail drafts produced by tools for the conversation that spawned them.
    func attachToReply(_ change: (inout ChatMessage) -> Void) {
        let target = ReplyContext.messageID ?? chat.activeID.flatMap { replies[$0] }
        if let id = target, chat.message(id) != nil {
            chat.update(id, change)
        } else {
            var message = ChatMessage(role: .nook, text: "")
            change(&message)
            chat.append(message)
        }
    }

    /// Submits a query in chat: response streams in real-time.
    func ask(_ text: String, images: [ImageAttachment] = []) {
        let conversation = chat.ensureActive()
        if chat.isBusy(conversation) { stop(conversation: conversation) }
        var question = ChatMessage(role: .user, text: text)
        question.images = images
        chat.append(question, to: conversation)
        var reply = ChatMessage(role: .nook, text: "")
        reply.streaming = true
        // Only some brains can see pictures; say so instead of answering as if they had.
        let selection = settings.selection
        let localModel = ModelAdvisor.catalog.first { $0.id == selection.model }
        if !images.isEmpty, selection.runtime == .mlx && !(localModel?.seesImages ?? false) {
            reply.notices.append(tr("image.unsupported"))
        }
        reply.status = settings.useLocal && !EmbeddedModel.shared.isLoaded ? tr("app.status.loadingModel") : tr("app.status.thinking")
        chat.append(reply, to: conversation)
        replies[conversation] = reply.id
        chat.setBusy(true, conversation: conversation)
        // If prompt originated from a card or voice, reveal chat. If user is already typing in chat, stay there.
        if viewModel.state != .panel(.chat) {
            warmUp()
            showChat()
        }
        let history = chat.history(before: question.id, hiding: settings.privateSources)
        let replyID = reply.id
        chatTasks[conversation] = Task { [weak self] in
            await ReplyContext.$images.withValue(images) {
                await ReplyContext.$messageID.withValue(replyID) {
                    await self?.answer(text, history: history, replyID: replyID, conversation: conversation)
                }
            }
        }
    }

    func answer(_ text: String, history: [ChatTurn], replyID id: UUID, conversation: UUID, retry: Bool = false, correction: String? = nil) async {
        // Scope permitted sources: conversation scope plus query-level constraints ("only my calendar and mail").
        let requested = SourceScope.parse(text)
        let wanted = (chat.conversation(conversation)?.scope ?? .automatic).merged(with: requested)
        // An external brain never gets the sources kept on this Mac; a question about one of them says so plainly.
        let scope = privacyScope(wanted)
        let withheld = withheldSources(asked: text, scope: wanted)

        // Context from a dropped Shelf file or active screen contents.
        var snapshot: ScreenSnapshot?
        var attachedName: String?
        let screenAllowed = scope.allows(SourceCatalog.screen)
        let explicitScreen = Self.refersToScreen(text)
        let shouldCaptureScreen: Bool
        if let file = attachment, Date().timeIntervalSince(file.date) < 600 {
            attachment = (file.name, file.text, Date())
            chat.update(id) { $0.status = tr("app.status.reading", file.name) }
            let limit = settings.brainProfile.isSmall ? 12_000 : 40_000
            snapshot = ScreenSnapshot(appName: "Bestand", windowTitle: file.name, text: String(file.text.prefix(limit)))
            attachedName = file.name
            shouldCaptureScreen = false
        } else if screenAllowed, explicitScreen || (settings.screenWithEveryQuestion && screenContext.hasPermission && !settings.brainProfile.isSmall) {
            if screenContext.cachedSnapshot() == nil { chat.update(id) { $0.status = tr("app.look.context") } }
            shouldCaptureScreen = true
        } else {
            shouldCaptureScreen = false
        }
        guard !Task.isCancelled else { return }

        // If asking for a chart, Nook renders it natively; raw code/JSON should not appear in chat.
        let wantsChart = ChartRescue.wantsChart(text)

        // Live retrieval steps appear above the streaming response.
        let ledger = RetrievalLedger()
        ledger.onChange = { [weak self, weak ledger] in
            guard let self, let ledger, self.replies[conversation] == id else { return }
            let steps = ledger.steps
            self.chat.update(id) { message in
                message.retrieval = steps
                if let running = steps.last(where: { $0.outcome == .running }), message.text.isEmpty {
                    message.status = tr("app.status.looking", running.sourceTitle)
                }
            }
        }

        // Run screen snapshot and source prefetching in parallel so neither waits on the other.
        async let capturedScreen: Result<ScreenSnapshot?, Error> = {
            guard shouldCaptureScreen else { return .success(nil) }
            do {
                return .success(try await self.screenSnapshot())
            } catch {
                return .failure(error)
            }
        }()

        let initialSources = attachedName.map { [$0] } ?? []
        let prepared = await prepareRun(text: text, scope: scope, snapshotText: snapshot?.text, ledger: ledger, history: history) { [weak self] summary in
            self?.chat.update(id) {
                if !initialSources.isEmpty { $0.sources = initialSources }
                $0.contextSources = summary.titles
                $0.scopeLabel = scope.isRestricted ? scope.label() : ""
                $0.status = retry ? (wantsChart ? tr("app.status.drawing") : tr("app.status.searching")) : tr("app.status.thinking")
            }
        }

        if shouldCaptureScreen {
            switch await capturedScreen {
            case .success(let snap):
                snapshot = snap
                if let snap { web.note(snap.text) }
            case .failure(let error):
                // Missing screen recording permission: reply without screen content unless explicitly requested.
                if explicitScreen {
                    finishReply(id, error: error.localizedDescription, conversation: conversation)
                    return
                }
            }
        }
        guard !Task.isCancelled else { return }

        var sources: [String] = []
        if let attachedName { sources.append(attachedName) } else if let snapshot {
            sources.append(snapshot.windowTitle == "alle zichtbare vensters" ? "schermen" : snapshot.windowTitle)
        }
        if !sources.isEmpty {
            chat.update(id) { $0.sources = sources }
        }

        let tools = prepared.tools
        let relevant = prepared.relevant
        let fetched = prepared.fetched
        let brainContext = prepared.context

        var request = text
        if let correction {
            request += "\n\n(\(correction) \(settings.languageInstruction(for: text)))"
        } else if retry {
            request += wantsChart
                ? "\n\n(Render the chart now using the show_chart tool with real numbers from context, tools, or web. Do not write code, JSON, or a table as a substitute.)"
                : "\n\n(Your previous answer was empty, or contained code/JSON or was in the wrong language. Answer the question itself, in plain sentences, \(settings.languageInstruction(for: text)) Use the context and what was looked up; if something is missing, fetch it with the matching tool (a connected source, an app with read_app, the screen, a file or the web). If it really is not possible, briefly say where you looked and what was missing.)"
        }

        do {
            var lastCleanedText = ""
            let plan = try await brain.run(
                userText: request,
                followUp: !history.isEmpty,
                history: history,
                context: brainContext,
                untrustedLabel: snapshot.map { "\($0.appName) — \($0.windowTitle)" },
                untrusted: snapshot?.text,
                tools: tools,
                onText: { [weak self] partial in
                    guard let self, self.replies[conversation] == id else { return }
                    var visible = FollowUps.streamingBody(partial)
                    if wantsChart { visible = ChartRescue.hidingChartCode(visible) }
                    let cleaned = Self.cleanReply(visible)
                    guard cleaned != lastCleanedText else { return }
                    lastCleanedText = cleaned
                    self.chat.update(id) { message in
                        message.text = cleaned
                        message.status = ""
                    }
                }
            )
            guard !Task.isCancelled, replies[conversation] == id else { return }
            // Follow-up actions suggested by Nook appear as interactive buttons below response.
            let split = FollowUps.split(plan.text)
            var rawBody = split.body

            // A small brain sometimes invents a number, time or address. Nook compares those with everything it was given
            // and tool results, and has the answer written again when one is found nowhere.
            if settings.checkAnswers, settings.brainProfile.isSmall, !retry, !wantsChart, plan.actions.isEmpty, rawBody.count >= 20,
               !Grounding.mayCompute(text) {
                let given = [brainContext, text, snapshot?.text ?? "", ledger.retrievedText, history.map(\.text).joined(separator: "\n")]
                let loose = Grounding.ungrounded(answer: rawBody, sources: given.joined(separator: "\n"))
                if !loose.isEmpty {
                    Log.brain.info("ungrounded details: \(loose.count, privacy: .public)")
                    chat.update(id) { $0.text = ""; $0.status = tr("app.status.checking") }
                    await answer(text, history: history, replyID: id, conversation: conversation, retry: true, correction: Grounding.correction(for: loose))
                    return
                }
            }

            // Did the model write chart code, JSON, or a table? Parse and rescue into native chart.
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
                // Still missing chart: retry once with strict instruction to invoke show_chart.
                if rescued.isEmpty, wantsChart, !retry, !settings.brainProfile.isSmall {
                    chat.update(id) { $0.text = ""; $0.status = tr("app.status.drawing") }
                    await answer(text, history: history, replyID: id, conversation: conversation, retry: true)
                    return
                }
            }

            // No answer, chart, draft or plan: try once more, asking the model to find the right source itself.
            let bare = rawBody.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let nothing = (bare.isEmpty || bare.uppercased() == "NONE") && rescued.isEmpty
                && (chat.message(id)?.charts.isEmpty ?? true) && (chat.message(id)?.mails.isEmpty ?? true) && plan.actions.isEmpty
            // Code or JSON for a question that is not about code, or an answer in another language: also try once more.
            let broken = !nothing && rescued.isEmpty && plan.actions.isEmpty && Self.looksBroken(rawBody, question: text, expected: settings.answerLanguage(for: text))
            if nothing || broken, !retry {
                chat.update(id) { $0.text = ""; $0.status = tr("app.status.searching") }
                await answer(text, history: history, replyID: id, conversation: conversation, retry: true)
                return
            }

            // Strip citations pointing to sources that were not actually retrieved.
            let references = ledger.references
            var body = Citations.sanitize(Self.cleanReply(rawBody), valid: Set(references.map(\.number)))
            let bareBody = body.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).uppercased()
            // Still empty, or still code/JSON or the wrong language after the second try: show what Nook found instead.
            let unusable = bareBody.isEmpty || bareBody == "NONE" || (retry && Self.looksBroken(body, question: text, expected: settings.answerLanguage(for: text)))
            let found = fetched.isEmpty ? connectors.contextLines(scope: scope, full: relevant).lines.filter { !$0.isEmpty } : fetched
            if plan.actions.isEmpty, unusable, !found.isEmpty, chat.message(id)?.charts.isEmpty ?? true {
                body = Self.digest(found)
            } else if plan.actions.isEmpty, bareBody == "NONE" {
                body = tr("app.found.nothing")
            }
            let cited = Citations.used(in: body)
            // Prioritize cited references first, followed by other retrieved sources.
            let shown = references.filter { cited.contains($0.number) } + references.filter { !cited.contains($0.number) }
            var notices = ledger.failures.map { step -> String in
                if case .failed(let error) = step.outcome { return tr("chat.notice.sourceFailed", step.sourceTitle, error) }
                return ""
            }
            if !ledger.failures.isEmpty { notices.append(tr("chat.notice.incomplete")) }
            if !withheld.isEmpty {
                notices.append(tr("chat.notice.private", withheld.map { SourceCatalog.title($0) }.sorted().joined(separator: ", ")))
            }
            let normalized = plan.actions.map { action -> PlannedAction in
                var copy = action
                if let spec = tools.first(where: { $0.name == action.tool }) { copy.input = ActionGate.normalized(action.input, schema: spec.schema) }
                return copy
            }
            // Fields the user keeps choosing (a calendar, a list) are filled in when the brain left them empty.
            let habits = withHabits(normalized, tools: tools)
            let actions = habits.actions
            notices += habits.notices
            let problems: [[String]] = actions.map { actionProblems($0, scope: scope) }
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
                        ? tr("app.found.noNumbers")
                        : tr("app.noAnswerRetry")
                }
            }
            if let message = chat.message(id) {
                let spoken = !message.text.isEmpty ? message.text
                    : (!message.mails.isEmpty ? tr("app.spoken.mail") : (!message.charts.isEmpty ? tr("app.spoken.chart") : tr("app.plan.ready")))
                speakIfAsked(spoken)
            }
            replies[conversation] = nil
            chatTasks[conversation] = nil
            chat.setBusy(false, conversation: conversation)
            NookPresence.shared.nod()
            nookFinished(conversation)
            // What this answer teaches Nook (which sources answered, and now and then a reflection on what the user said).
            learnAfterAnswer(question: text, history: history, reply: id, conversation: conversation, actions: actions)
            // Automatically execute safe small actions if auto-run is enabled and inputs validate.
            if canRunWithoutAsking(BrainPlan(text: plan.text, actions: actions), request: text), problems.allSatisfy({ (p: [String]) in p.isEmpty }) { runPlan(id) }
        } catch {
            guard !Task.isCancelled, replies[conversation] == id else { return }
            finishReply(id, error: error.localizedDescription, conversation: conversation)
        }
    }

    func finishReply(_ id: UUID, error: String, conversation: UUID) {
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

    /// Conversation finished in background while looking elsewhere: display notification.
    func nookFinished(_ id: UUID) {
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

    private static let thinkBlockRegex = try? NSRegularExpression(pattern: #"<think>[\s\S]*?</think>"#)
    private static let rawToolCallRegex = try? NSRegularExpression(pattern: #"(?m)^\s*\{\s*"(name|tool)"\s*:.*\}\s*$"#)

    /// Cleans residual raw tool call tags and stray backslashes from model output.
    static func cleanReply(_ text: String) -> String {
        var cleaned = text
        // Reasoning blocks or tool syntax as raw text should not appear in chat.
        if cleaned.contains("<think"), let rx = thinkBlockRegex {
            cleaned = rx.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")
        }
        if cleaned.contains("{"), let rx = rawToolCallRegex {
            cleaned = rx.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")
        }
        return MarkdownBlock.clean(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
