import SwiftUI
import Combine
import AppKit
import Carbon.HIToolbox
import NaturalLanguage

/// Asking Nook: one question becomes a streaming answer with sources, charts, mail drafts and a plan.
extension AppModel {
    // MARK: Asking Nook

    func handleUserText(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Short deterministic commands handled locally without querying the brain: instant execution.
        if let intent = LocalIntent.parse(text) {
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
        ask(text)
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
    func ask(_ text: String) {
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
        // If prompt originated from a card or voice, reveal chat. If user is already typing in chat, stay there.
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

    func answer(_ text: String, history: [ChatTurn], replyID id: UUID, conversation: UUID, retry: Bool = false) async {
        // Scope permitted sources: conversation scope plus query-level constraints ("only my calendar and mail").
        let requested = SourceScope.parse(text)
        let scope = (chat.conversation(conversation)?.scope ?? .automatic).merged(with: requested)

        // Context from a dropped Shelf file or active screen contents.
        var snapshot: ScreenSnapshot?
        var attachedName: String?
        let screenAllowed = scope.allows(SourceCatalog.screen)
        if let file = attachment, Date().timeIntervalSince(file.date) < 600 {
            attachment = (file.name, file.text, Date())
            chat.update(id) { $0.status = "Ik lees \(file.name)…" }
            let limit = settings.brainProfile.isSmall ? 12_000 : 40_000
            snapshot = ScreenSnapshot(appName: "Bestand", windowTitle: file.name, text: String(file.text.prefix(limit)))
            attachedName = file.name
        } else if screenAllowed, Self.refersToScreen(text) || (settings.screenWithEveryQuestion && screenContext.hasPermission && !settings.brainProfile.isSmall) {
            if screenContext.cachedSnapshot() == nil { chat.update(id) { $0.status = "Ik kijk even mee…" } }
            do {
                snapshot = try await screenSnapshot()
            } catch {
                // Missing screen recording permission: reply without screen content unless explicitly requested.
                if Self.refersToScreen(text) {
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
                    message.status = "Ik kijk in \(running.sourceTitle)…"
                }
            }
        }
        let prepared = await prepareRun(text: text, scope: scope, snapshotText: snapshot?.text, ledger: ledger) { [weak self] summary in
            self?.chat.update(id) {
                $0.sources = sources
                $0.contextSources = summary.titles
                $0.scopeLabel = scope.isRestricted ? scope.label() : ""
                $0.status = retry ? (wantsChart ? "Ik teken de grafiek…" : "Ik zoek verder…") : "Even nadenken…"
            }
        }
        guard !Task.isCancelled else { return }
        let tools = prepared.tools
        let relevant = prepared.relevant
        let fetched = prepared.fetched
        let brainContext = prepared.context

        var request = text
        if retry {
            request += wantsChart
                ? "\n\n(Render the chart now using the show_chart tool with real numbers from context, tools, or web. Do not write code, JSON, or a table as a substitute.)"
                : "\n\n(Your previous answer was empty, or contained code/JSON or was in the wrong language. Answer the question itself, in plain sentences, \(settings.languageInstruction(for: text)) Use the context and what was looked up; if something is missing, fetch it with the matching tool (a connected source, an app with read_app, the screen, a file or the web). If it really is not possible, briefly say where you looked and what was missing.)"
        }

        do {
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
                    self.chat.update(id) { message in
                        message.text = Self.cleanReply(visible)
                        message.status = ""
                    }
                }
            )
            guard !Task.isCancelled, replies[conversation] == id else { return }
            // Follow-up actions suggested by Nook appear as interactive buttons below response.
            let split = FollowUps.split(plan.text)
            var rawBody = split.body

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
                    chat.update(id) { $0.text = ""; $0.status = "Ik teken de grafiek…" }
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
                chat.update(id) { $0.text = ""; $0.status = "Ik zoek verder…" }
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
                body = "Ik vond hier niets over. Zeg erbij waar ik moet kijken?"
            }
            let cited = Citations.used(in: body)
            // Prioritize cited references first, followed by other retrieved sources.
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
            // Automatically execute safe small actions if auto-run is enabled and inputs validate.
            if canRunWithoutAsking(plan, request: text), problems.allSatisfy({ (p: [String]) in p.isEmpty }) { runPlan(id) }
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

    /// Cleans residual raw tool call tags and stray backslashes from model output.
    static func cleanReply(_ text: String) -> String {
        var cleaned = text
        // Reasoning blocks or tool syntax as raw text should not appear in chat.
        cleaned = cleaned.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(?m)^\s*\{\s*"(name|tool)"\s*:.*\}\s*$"#, with: "", options: .regularExpression)
        return MarkdownBlock.clean(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
