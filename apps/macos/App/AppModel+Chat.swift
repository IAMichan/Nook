import SwiftUI
import Combine
import AppKit
import Carbon.HIToolbox
import NaturalLanguage

/// Asking Nook: one question becomes a streaming answer with sources, charts, mail drafts and a plan.
extension AppModel {
    // MARK: Asking Nook

    /// `reveal: false` leaves the notch as it is while Nook answers (the Double Tap quick field); the answer then
    /// arrives as a small card (`nookFinished`), and the chat opens only when you open it yourself.
    /// `note`: what Nook adds to the question for the brain, not shown in the chat (see `ReplyContext.note`).
    func handleUserText(_ raw: String, images: [ImageAttachment] = [], reveal: Bool = true, note: String = "") {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        // A picture without a question: ask what is on it.
        if text.isEmpty { text = tr("image.defaultQuestion") }
        NookPresence.shared.heard()

        // "@open whatsapp": the app opens next to the chat. "@close" puts it away.
        if images.isEmpty, handleEmbeddedAppCommand(text) { return }

        // "Maak ongedaan": the last actions Nook carried out, reversed as a plan to approve.
        if Undo.isRequest(text) {
            proposeUndo(asked: text)
            return
        }

        // Short deterministic commands handled locally without querying the brain: instant execution.
        if images.isEmpty, let intent = LocalIntent.parse(text) {
            // In chat mode, keep the flow: music and time queries are replied to inline.
            if (viewModel.state == .panel(.nook) || viewModel.isShowing(.chat)), let reply = quickReplyInChat(intent) {
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
        // Nook is still answering: the question waits in line and goes out once that answer is done.
        if let busy = chat.activeID, chat.isBusy(busy) {
            chat.enqueue(text, images: images, conversation: busy)
            return
        }
        ask(text, images: images, reveal: reveal, note: note)
    }

    /// The next question that waited in line, once the answer before it is done. `message`: that question right away
    /// (Send now), stopping the answer that runs; it also lets a line held after a stop or an error go again.
    func sendQueued(_ conversation: UUID, message: UUID? = nil) {
        if message != nil, chat.isBusy(conversation) { stop(conversation: conversation) }
        guard !chat.isBusy(conversation), settings.brainReady,
              let next = chat.takeQueued(message, conversation: conversation) else { return }
        ask(next.text, images: next.images, in: conversation, reveal: false)
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
        chat.requestComposerFocus()
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
                    message.retrieval[index].outcome = .failed(tr("chat.sources.interrupted"))
                }
                if message.text.isEmpty && message.charts.isEmpty && message.mails.isEmpty && message.actions.isEmpty {
                    message.text = tr("chat.stopped")
                }
            }
        }
        replies[conversation] = nil
        chat.setBusy(false, conversation: conversation)
        chat.holdQueue(conversation: conversation)
        spokenRequest = false
    }

    /// Tools that count as reading but put something in the answer itself: not for a brain that only looks things up.
    static let chatOnlyTools: Set<String> = ["compose_mail", "show_chart", ChatTools.planTool]

    /// Actions that send a message the user approves in the chat, for every chat app.
    static let messageSendTools: Set<String> = ["whatsapp_send", "chat_send", "send_to_source"]

    /// The answer being written in the chat, nil when none is (a notch card, thinking along).
    var replyTarget: UUID? {
        let target = ReplyContext.messageID ?? chat.activeID.flatMap { replies[$0] }
        return target.flatMap { chat.message($0) != nil ? $0 : nil }
    }

    /// Collects charts and mail drafts produced by tools for the conversation that spawned them.
    func attachToReply(_ change: (inout ChatMessage) -> Void) {
        if let id = replyTarget {
            chat.update(id, change)
        } else {
            var message = ChatMessage(role: .nook, text: "")
            change(&message)
            chat.append(message)
        }
    }

    /// Submits a query in chat: response streams in real-time. `focus` and `reflects` are for prompts a card writes
    /// (see `ReplyContext`). `target` asks in that conversation instead of the active one, and `reveal: false` leaves the
    /// notch as it is (a question from the iPhone companion). `note`: see `ReplyContext.note`; `selfContained`: see
    /// `ReplyContext.selfContained`.
    func ask(_ text: String, images: [ImageAttachment] = [], focus: [Prefetch.Call] = [], reflects: Bool = true,
             in target: UUID? = nil, reveal: Bool = true, note: String = "", selfContained: Bool = false) {
        let conversation = target.flatMap { chat.conversation($0) == nil ? nil : $0 } ?? chat.ensureActive()
        if chat.isBusy(conversation) { stop(conversation: conversation) }
        // A question about the screen, or a follow-up on an answer that read it, while the screen stays on this Mac: the
        // screen brain answers it (`ScreenBrain`), so the screen text never leaves the Mac. Everything else goes to the
        // chosen brain as always.
        // With a relaying screen brain it writes a filtered note instead, and the chosen brain answers from that.
        let needed = ScreenBrain.routed ?? screenWorker(for: text, in: conversation)
        let relay = needed != nil && ScreenBrain.relays(text, images: !images.isEmpty) ? settings.relayWorker : nil
        let screenBrain = relay == nil ? needed : nil
        let runs = screenBrain ?? relay ?? settings.selection
        var question = ChatMessage(role: .user, text: text)
        question.images = images
        chat.append(question, to: conversation)
        var reply = ChatMessage(role: .nook, text: "")
        reply.streaming = true
        // Only some brains can see pictures; say so instead of answering as if they had.
        let localModel = ModelAdvisor.catalog.first { $0.id == runs.model }
        if !images.isEmpty, runs.runtime == .mlx && !(localModel?.seesImages ?? false) {
            reply.notices.append(tr("image.unsupported"))
        }
        if let screenBrain, !settings.chosenSelection.isLocal, !ScreenBrain.needsBoth(text) {
            reply.notices.append(tr("screenBrain.answered", AppSettings.screenBrainName(screenBrain)))
        }
        reply.status = runs.runtime == .mlx && runs.model != AppleModel.id && !EmbeddedModel.shared.isLoaded
            ? tr("app.status.loadingModel") : tr("app.status.thinking")
        chat.append(reply, to: conversation)
        replies[conversation] = reply.id
        chat.setBusy(true, conversation: conversation)
        // If prompt originated from a card or voice, reveal chat. If user is already typing in chat, stay there.
        if !viewModel.isShowing(.chat) {
            warmUp()
            if reveal { showChat() }
        }
        // The screen brain is on this Mac: it may read the whole conversation.
        let history = chat.history(before: question.id, hiding: screenBrain != nil ? [] : settings.privateSources)
        // Also the chosen brain's part: that one sees the conversation without what stays on this Mac.
        let together = screenBrain != nil && ScreenBrain.routed == nil && ScreenBrain.needsBoth(text) && images.isEmpty
        let outside = together ? chat.history(before: question.id, hiding: settings.privateSources) : nil
        // The model on this Mac reads the whole conversation for its note, the chosen brain what it may see.
        let local = relay.map { _ in chat.history(before: question.id) } ?? []
        let replyID = reply.id
        // The answer's task inherits the brain it runs on.
        chatTasks[conversation] = ScreenBrain.$routed.withValue(screenBrain) {
            Task { [weak self] in
                await ReplyContext.$images.withValue(images) {
                    await ReplyContext.$focus.withValue(focus) {
                        await ReplyContext.$reflects.withValue(reflects) {
                            await ReplyContext.$messageID.withValue(replyID) {
                                await ReplyContext.$note.withValue(note) {
                                    await ReplyContext.$selfContained.withValue(selfContained) {
                                        if let relay {
                                            await self?.answerFromBrief(text, worker: relay, local: local, history: history, replyID: replyID, conversation: conversation)
                                        } else {
                                            await self?.answerTogether(text, outside: outside, history: history, replyID: replyID, conversation: conversation)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The screen brain for a chat question that needs the screen: one about what is on screen, or a follow-up on an
    /// answer that read it. Nil when the chosen brain may read the screen itself or no screen brain was picked.
    private func screenWorker(for text: String, in conversation: UUID) -> BrainSelection? {
        guard let worker = settings.screenWorker else { return nil }
        // A question about another source kept on this Mac ("wat is het nummer van Lisa?"): the model on this Mac may read it.
        let wanted = (chat.conversation(conversation)?.scope ?? .automatic).merged(with: SourceScope.parse(text))
        if !withheldSources(asked: text, scope: wanted).isEmpty { return worker }
        if settings.privateSources.contains("contacts"), ChatIntent.detect(text).kinds.contains(.contacts) { return worker }
        let messages = chat.conversation(conversation)?.messages ?? []
        let last = messages.last { $0.role == .nook }
        let afterScreen = last?.used(anyOf: [SourceCatalog.screen]) == true || last?.privateBrief.isEmpty == false
        // The question itself was appended just before this: it is not a conversation of its own.
        return ScreenBrain.handles(text, conversation: messages.count > 1, afterScreen: afterScreen) ? worker : nil
    }

    /// The model on this Mac reads what stays here and writes a filtered note; the chosen brain answers from that note,
    /// with its own tools. When no note comes, nothing left the Mac and the model on this Mac answers as it would have.
    private func answerFromBrief(_ text: String, worker: BrainSelection, local: [ChatTurn], history: [ChatTurn], replyID id: UUID, conversation: UUID) async {
        let chosen = settings.chosenSelection.provider.title.components(separatedBy: " (").first ?? settings.chosenSelection.provider.title
        let workerName = AppSettings.screenBrainName(worker)
        chat.update(id) { $0.status = tr("screenBrain.reading") }
        let kept = settings.privateSources
        let note = await writeBrief(text, worker: worker, kept: kept, history: local, conversation: conversation)
        guard !Task.isCancelled else { return }
        guard let note else {
            chat.update(id) { $0.notices.append(tr("screenBrain.answered", workerName)) }
            await ScreenBrain.$routed.withValue(worker) {
                await answer(text, history: local, replyID: id, conversation: conversation)
            }
            return
        }
        chat.update(id) {
            $0.privateBrief = note.text
            $0.notices.append(tr("screenBrain.relayed", workerName, chosen))
            $0.status = tr("app.status.thinking")
        }
        await ReplyContext.$brief.withValue(note.text) {
            await ReplyContext.$briefAddresses.withValue(note.addresses) {
                await answer(text, history: history, replyID: id, conversation: conversation)
            }
        }
    }

    /// Runs on the model on this Mac, without tools: it reads only the screen and the sources the chosen brain may not
    /// (the chosen brain searches the others itself). Nil when there is nothing to read or the model gives no note.
    private func writeBrief(_ text: String, worker: BrainSelection, kept: Set<String>, history: [ChatTurn],
                            conversation: UUID) async -> (text: String, addresses: [String])? {
        await ScreenBrain.$routed.withValue(worker) {
            await ReplyContext.$images.withValue([]) {
                await ReplyContext.$note.withValue("") {
                    // Never a raw screen to anything but a model on this Mac.
                    guard settings.selection.isLocal else { return nil }
                    let wanted = (chat.conversation(conversation)?.scope ?? .automatic).merged(with: SourceScope.parse(text))
                    let sources = kept.subtracting([SourceCatalog.screen]).filter { wanted.allows($0) }
                    let readsScreen = kept.contains(SourceCatalog.screen) && wanted.allows(SourceCatalog.screen) && !ReplyContext.selfContained
                        && (ScreenBrain.refersToScreen(text) || ScreenBrain.followsUp(text))
                    let screen = readsScreen ? try? await screenSnapshot() : nil
                    let prepared = await prepareRun(text: text, scope: SourceScope(mode: .only, included: sources), snapshotText: nil,
                                                    ledger: RetrievalLedger(), prefetch: !sources.isEmpty, history: history)
                    guard screen != nil || !prepared.fetched.isEmpty else { return nil }
                    let profile = settings.brainProfile
                    let prompt = PrivateBrief.prompt(request: text, history: BrainService.historyPrefix(history, limit: 6, length: 300),
                                                     context: prepared.fetched.isEmpty ? "" : prepared.context, screen: screen?.text,
                                                     budget: profile.promptCharacterBudget)
                    let raw = await brain.rewrite(system: PrivateBrief.system, prompt: prompt, timeout: 60)
                    guard let sealed = raw.flatMap(PrivateBrief.sealed) else { return nil }
                    return (sealed, PrivateBrief.addresses(in: [screen?.text ?? "", prepared.context, raw ?? ""].joined(separator: "\n")))
                }
            }
        }
    }

    /// A question for both brains: the chosen brain looks up what it can, then the model on this Mac answers with that and
    /// with the screen. Text only goes that way: nothing from the screen or another private source reaches the chosen brain.
    private func answerTogether(_ text: String, outside: [ChatTurn]?, history: [ChatTurn], replyID id: UUID, conversation: UUID) async {
        guard let outside else {
            await answer(text, history: history, replyID: id, conversation: conversation)
            return
        }
        chat.update(id) { $0.status = tr("app.status.searching") }
        let screenName = settings.activeModelName
        let found = await chosenBrainPart(text, history: outside, conversation: conversation)
        chat.update(id) { $0.notices.append(tr(found.isEmpty ? "screenBrain.answered" : "screenBrain.together", screenName)) }
        await ReplyContext.$outside.withValue(found) {
            await answer(text, history: history, replyID: id, conversation: conversation)
        }
    }

    /// The chosen brain's part: read tools only, the sources kept on this Mac out of its reach. Empty when it fails: the
    /// model on this Mac then answers by itself.
    private func chosenBrainPart(_ text: String, history: [ChatTurn], conversation: UUID) async -> String {
        await ScreenBrain.$routed.withValue(nil) {
            await ReplyContext.$images.withValue([]) {
                await ReplyContext.$note.withValue("") {
                    await ReplyContext.$focus.withValue([]) {
                        let wanted = (chat.conversation(conversation)?.scope ?? .automatic).merged(with: SourceScope.parse(text))
                        let prepared = await prepareRun(text: text, scope: privacyScope(wanted), snapshotText: nil, ledger: RetrievalLedger(), history: history)
                        let plan = try? await brain.run(userText: text + "\n\n(" + ScreenBrain.outsideInstruction + ")", followUp: !history.isEmpty, history: history,
                                                        context: prepared.context, tools: prepared.tools.filter { $0.kind == .read && !Self.chatOnlyTools.contains($0.name) })
                        // Its citations point at lookups the answer on this Mac does not have.
                        return plan.map { Citations.sanitize(FollowUps.split($0.text).body, valid: []) } ?? ""
                    }
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
        var images: [ChatImage] = []
        let screenAllowed = scope.allows(SourceCatalog.screen)
        let explicitScreen = Self.refersToScreen(text)
        let shouldCaptureScreen: Bool
        let selfContained = ReplyContext.selfContained
        if !selfContained, let file = attachment, Date().timeIntervalSince(file.date) < 600 {
            attachment = (file.name, file.text, Date())
            chat.update(id) { $0.status = tr("app.status.reading", file.name) }
            let limit = settings.brainProfile.isSmall ? 12_000 : 40_000
            snapshot = ScreenSnapshot(appName: "Bestand", windowTitle: file.name, text: String(file.text.prefix(limit)))
            attachedName = file.name
            images = attachmentImages
            shouldCaptureScreen = false
        } else if screenAllowed, explicitScreen || (!selfContained && settings.screenWithEveryQuestion && screenContext.hasPermission && !settings.brainProfile.isSmall) {
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
        // The chosen brain already searched: the small window here goes to its findings and the screen.
        let outsideFound = ReplyContext.outside
        let prepared = await prepareRun(text: text, scope: scope, snapshotText: snapshot?.text, ledger: ledger, prefetch: outsideFound.isEmpty, history: history) { [weak self] summary in
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
        var brainContext = outsideFound.isEmpty ? prepared.context
            : "What Nook's main brain found for this question, without the screen:\n\(outsideFound.prefix(settings.brainProfile.isSmall ? 2_000 : 8_000))\n\n" + prepared.context
        if !ReplyContext.brief.isEmpty { brainContext = PrivateBrief.context(ReplyContext.brief) + "\n\n" + brainContext }
        // The answer style and the space's instructions of this conversation, then what the context inspector shows.
        let instructionLines = InstructionStore.shared.instructionLines(for: conversation)
        if !instructionLines.isEmpty { brainContext = instructionLines.joined(separator: "\n\n") + "\n\n" + brainContext }
        InstructionStore.shared.noteContext(Self.contextBreakdown(instructions: instructionLines, prepared: prepared,
                                                                  budget: settings.brainProfile.contextTokens))

        var request = text
        if let correction {
            request += "\n\n(\(correction) \(settings.languageInstruction(for: text)))"
        } else if retry {
            request += wantsChart
                ? "\n\n(Render the chart now using the show_chart tool with real numbers from context, tools, or web. Do not write code, JSON, or a table as a substitute.)"
                : "\n\n(Your previous answer was empty, or contained code/JSON or was in the wrong language. Answer the question itself, in plain sentences, \(settings.languageInstruction(for: text)) Use the context and what was looked up; if something is missing, fetch it with the matching tool (a connected source, an app with read_app, the screen, a file or the web). If it really is not possible, briefly say where you looked and what was missing.)"
        }

        // A spoken question is answered aloud while the answer is written, sentence by sentence. Not when a small brain's
        // answer may still be checked and written again: then it is read once it is final.
        let speaksLive = spokenRequest && settings.speakAnswers && !retry && correction == nil
            && !(settings.checkAnswers && settings.brainProfile.isSmall)
        var spokenQueue = SpokenText.Queue()
        if speaksLive { speech.stop() }
        do {
            var lastCleanedText = ""
            // perf: a model streams a token at a time; cleaning the whole text and publishing the chat for each one
            // costs the main thread more than the eye can use, so the text is written at most every 50 ms.
            let flusher = StreamFlusher { [weak self] partial in
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
                if speaksLive {
                    for sentence in spokenQueue.feed(cleaned) { self.speech.enqueue(sentence, language: self.settings.language) }
                }
            }
            let plan: BrainPlan
            do {
                plan = try await brain.run(
                    userText: request,
                    followUp: !history.isEmpty,
                    history: history,
                    context: brainContext,
                    untrustedLabel: snapshot.map { "\($0.appName) — \($0.windowTitle)" },
                    untrusted: snapshot?.text,
                    images: images,
                    tools: tools,
                    onText: { [weak self] partial in
                        guard let self, self.replies[conversation] == id else { return }
                        flusher.push(partial)
                    }
                )
            } catch {
                // The last words that arrived are written before an error is appended to them.
                flusher.flush()
                throw error
            }
            flusher.flush()
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
            // Sources that could not be read are shown, with their reason, in the sources card under the answer.
            var notices: [String] = []
            if !withheld.isEmpty, ReplyContext.brief.isEmpty {
                notices.append(tr("chat.notice.private", withheld.map { SourceCatalog.title($0) }.sorted().joined(separator: ", ")))
            }
            // A mail draft or a chat message in the plan is already the step to approve: its Send button sends it.
            // Taking over the same message (writing it in Mail or the chat app by hand) on top would only ask twice.
            let drafted = !(chat.message(id)?.mails.isEmpty ?? true) || plan.actions.contains { Self.messageSendTools.contains($0.tool) }
            let proposed = drafted ? plan.actions.filter { $0.tool != TakeoverPolicy.toolName } : plan.actions
            let normalized = proposed.map { action -> PlannedAction in
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
                // What `ask` already said about this answer (which brain, pictures it cannot see) stays.
                message.notices = (message.notices + notices.filter { !$0.isEmpty && !message.notices.contains($0) })
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
                if speaksLive {
                    for sentence in spokenQueue.finish(message.text.isEmpty ? spoken : message.text) {
                        speech.enqueue(sentence, language: settings.language)
                    }
                    spokenRequest = false
                } else {
                    speakIfAsked(spoken)
                }
            }
            replies[conversation] = nil
            chatTasks[conversation] = nil
            chat.setBusy(false, conversation: conversation)
            NookPresence.shared.nod()
            // Actions the chosen access lets Nook do by itself start before the notice, so a notice only asks for a
            // click on what still waits for one.
            if canRunWithoutAsking(BrainPlan(text: plan.text, actions: actions), request: text), problems.allSatisfy({ (p: [String]) in p.isEmpty }) { runPlan(id) }
            nookFinished(conversation)
            // What this answer teaches Nook (which sources answered, and now and then a reflection on what the user said).
            learnAfterAnswer(question: text, history: history, reply: id, conversation: conversation, actions: actions)
            sendQueued(conversation)
        } catch {
            guard !Task.isCancelled, replies[conversation] == id else { return }
            finishReply(id, error: error.localizedDescription, conversation: conversation)
        }
    }

    func finishReply(_ id: UUID, error: String, conversation: UUID) {
        // Asked from the notch: what went wrong shows there, where you wait for the answer.
        if NotchFollow.shared.conversations.remove(conversation) != nil { showInNotch(errorCard(error)) }
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
        chat.holdQueue(conversation: conversation)
    }

    /// Conversation finished in background while looking elsewhere: a notice the way Settings › Notifications says for
    /// Nook himself.
    func nookFinished(_ id: UUID) {
        // Asked about a selection, and its card is still open beside it: the answer is in sight already.
        if SelectionAskController.shared.shows(id) { return }
        // Asked from the notch (the Double Tap field, a notice's field): you wait for it there.
        let followed = NotchFollow.shared.conversations.remove(id) != nil
        let watching = viewModel.isInSight(.chat) && chat.activeID == id
        guard !watching, let conversation = chat.conversation(id) else { return }
        chat.markUnread(id)
        let preview = conversation.preview.isEmpty ? tr("nooks.finishedFallback") : conversation.preview
        let title = tr("nooks.finished", conversation.title)
        logNotice(.done, title: title, detail: preview, target: .conversation(id))
        // A plan that waits for your click comes to the notch with Run, so asking from the notch never ends in a chat
        // you do not see.
        if followed, let last = conversation.messages.last(where: { $0.role == .nook }), !last.actions.isEmpty, !last.planArchived {
            switch last.planState {
            case .pending:
                showInNotch(notchPlanCard(last, conversation: id))
                return
            case .running:
                // The access you chose lets Nook do it by itself: what came of it shows in the notch.
                followPlanInNotch(last.id)
                return
            default:
                break
            }
        }
        // The card shows the whole answer; the notice log, the strip and a macOS notification keep the short preview.
        presentNookNotice(title: title, detail: preview, full: conversation.lastAnswer, answer: conversation.lastNookAnswer,
                          button: tr("nooks.view"), mood: .done, replyTo: id, inNotch: followed) { [weak self] in
            self?.openConversation(id)
        }
    }

    /// A notice from Nook himself (an answer that finished, call notes that are ready), shown as Settings ›
    /// Notifications says: a card with `button` and Later, one line with `button`, or a macOS notification.
    /// `replyTo`: the conversation the card's field answers, so a question Nook asks back is answered in the notch
    /// (`answerFromNotice`) instead of only through View or Later. `full`: what the card shows instead of `detail` (the
    /// whole answer, where `detail` is its one-line preview). `inNotch`: you asked from the notch and wait for the
    /// answer there, so it is a card whatever the notice rules say (also in a meeting). `answer`: the whole answer with its
    /// sources and offers, drawn as the chat draws it (`NookAnswerView`) instead of `full` as plain text.
    func presentNookNotice(title: String, detail: String, full: String = "", answer: NookAnswer? = nil, button: String,
                           mood: NookMood, replyTo conversation: UUID? = nil, inNotch: Bool = false, open: @escaping () -> Void) {
        let token = conversation.map { Self.nookReplyCardPrefix + $0.uuidString + "/" + UUID().uuidString }
            ?? "nookdone-" + UUID().uuidString
        let shown = String((full.isEmpty ? (detail.isEmpty ? title : detail) : full).prefix(4000))
        let field: CGFloat = conversation == nil ? 0 : 50
        let height: CGFloat
        if let answer {
            height = Self.answerCardHeight(answer, field: field)
        } else {
            // Room for the whole text up to nine lines, as an answer card has; a longer one scrolls inside the card.
            let lines = max(1, min(9, Int(ceil(Double(shown.count) / (shown.count > 140 ? 62.0 : 46.0)))))
            height = min(470, 100 + CGFloat(lines) * (shown.count > 140 ? 21 : 24) + field)
        }
        let card = NookCard(
            id: token,
            mood: mood,
            context: detail.isEmpty ? "" : title,
            title: answer.map { Citations.sanitize($0.text, valid: []) } ?? shown,
            detail: answer.map { .answer($0) } ?? .none,
            primary: CardAction(label: button, outcome: .callback("\(token)#open", "")),
            secondary: CardAction(label: tr("nooks.later"), outcome: .dismiss),
            contentHeight: height,
            input: conversation != nil,
            inputPrompt: tr("nooks.replyPrompt"),
            // A question back ("What should I send Arjan?") takes the keyboard so the answer can be typed at once;
            // any other answer leaves you typing where you were, and a click in the field answers.
            focusesInput: shown.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        )
        if inNotch {
            viewModel.register("\(token)#open", open)
            showInNotch(card)
            return
        }
        deliverNotice(.nook, id: token, title: title, body: detail, card: { [weak self] in
            guard let self else { return }
            self.viewModel.register("\(token)#open", open)
            self.viewModel.present(card)
        }, strip: { [weak self] in
            self?.viewModel.notify(title, button: button, action: open)
        }, open: open,
        // An answer from Nook is answered on its banner, as in the card's field.
        banner: NoticeBanner(target: conversation.map { .conversation($0) } ?? .nowhere,
                             reply: conversation.map { id in { [weak self] text in self?.answerFromNotice(text, conversation: id) } }))
    }

    /// The height of a card with Nook's answer (`CardDetail.answer`): its lines as the card wraps them (a list item, a
    /// heading and a paragraph each start a line, with room between paragraphs), its source chips and offers, up to the
    /// tallest card; a longer answer scrolls inside it.
    static func answerCardHeight(_ answer: NookAnswer, field: CGFloat) -> CGFloat {
        let perLine = 60.0
        var height: CGFloat = 0
        var previousBlank = false
        for raw in Citations.sanitize(answer.text, valid: []).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                // The gap between two paragraphs or a paragraph and a list.
                if !previousBlank, height > 0 { height += 10 }
                previousBlank = true
                continue
            }
            previousBlank = false
            let plain = line.replacingOccurrences(of: "**", with: "")
            let heading = plain.hasPrefix("#")
            height += CGFloat(max(1, Int(ceil(Double(plain.count) / perLine)))) * (heading ? 26 : 23) + (heading ? 10 : 4)
        }
        if !answer.cited.isEmpty { height += 36 }
        if !answer.offers.isEmpty { height += 40 }
        // The header, the buttons and the margins around them.
        return min(470, max(150, 104 + height + field))
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

/// Hands the newest partial answer to `apply` at most every 50 ms; `flush()` writes whatever is still waiting.
@MainActor
final class StreamFlusher {
    private var pending: String?
    private var lastFlush = Date.distantPast
    private var trailing = false
    private let apply: (String) -> Void

    init(apply: @escaping (String) -> Void) { self.apply = apply }

    func push(_ text: String) {
        pending = text
        if Date().timeIntervalSince(lastFlush) >= 0.05 {
            flush()
        } else if !trailing {
            // The last words of a pause (a tool call) still show up.
            trailing = true
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 50_000_000)
                self?.trailing = false
                self?.flush()
            }
        }
    }

    func flush() {
        guard let text = pending else { return }
        pending = nil
        lastFlush = Date()
        apply(text)
    }
}
