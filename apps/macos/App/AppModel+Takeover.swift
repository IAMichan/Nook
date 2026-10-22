import AppKit
import Foundation

/// Where a task Nook took over stands: one at a time, with Stop.
@MainActor
final class TakeoverState: ObservableObject {
    static let shared = TakeoverState()

    @Published fileprivate(set) var isRunning = false
    /// The step Nook is on, as the notch shows it.
    @Published fileprivate(set) var line = ""
    fileprivate var task: Task<String, Error>?
    /// The chat message that follows the task when it started from the notch.
    fileprivate var messageID: UUID?
    /// A checkpoint or a question that waits for the user's answer.
    fileprivate var decision: CheckedContinuation<Bool, Never>?
    /// Stop was asked for: also before the brain's run exists (while Nook still gathers the context).
    fileprivate var stopRequested = false
    /// The last window Nook read shows a cookie banner: its plain "Accept" runs without a question.
    fileprivate var cookieBanner = false
    /// The browser the task works in (the user's, not just the default one).
    fileprivate var browser: NSRunningApplication?

    /// Stops the task: a question that waits is answered with no, the brain's run is cancelled.
    func stop() {
        stopRequested = true
        resolve(false)
        task?.cancel()
    }

    fileprivate func resolve(_ answer: Bool) {
        let pending = decision
        decision = nil
        pending?.resume(returning: answer)
    }
}

/// Taking over a task (`TakeoverPolicy`): "finish this for me", "order more coffee filters", "unsubscribe me from this".
///
/// - Start: the brain proposes `take_over` in the chat and the user approves it like any plan. The Double Tap key's field in
///   the notch is the same chat (`askFromQuickField`), so a task typed there is proposed the same way.
/// - Work: the chosen brain reads windows with `read_ui`, acts with `control_ui`, opens pages and apps, and reads again,
///   on its own. Nook's own violet cursor shows where it acts; most actions happen in the background (`UIDriver`).
///   The notch shows the current step in one slim line, with Stop.
/// - The point of no return: a step that pays, orders, sends, submits, deletes, books or signs waits for the user's yes
///   in a card. Card and social security numbers are never typed. Sign-in and payment details are left to the user
///   (`wait_for_user`).
/// - End: the brain's summary lands in the chat; success only counts when it says so after checking (`STATUS: DONE`).
extension AppModel {
    static let takeoverCardPrefix = "takeover-ask-"

    /// Tools the brain uses during a task, as far as they are available.
    static let takeoverToolNames = ["read_ui", "control_ui", "open_url", "open_app", "search_web", "read_webpage", "recall_memory"]

    // MARK: Tools

    var takeoverTools: [ToolSpec] {
        [
            ToolSpec(
                name: TakeoverPolicy.toolName,
                description: "Lets Nook carry out a task on the Mac by itself, from start to finish, in the user's own apps and logged-in browser: ordering or buying something, booking, unsubscribing, filling out and sending a form, finishing what is on screen, changing a setting that takes several steps. Use it when the request takes many clicks across windows or web pages. Nook asks the user itself before anything that pays, orders, sends, deletes or books. Give the task in the user's words, with every detail they gave.",
                schema: [
                    "type": "object",
                    "properties": ["task": ["type": "string", "description": "The task, complete, in the user's words, e.g. \"Bestel nieuwe koffiefilters bij bol.com, dezelfde als vorige keer\"."]],
                    "required": ["task"]
                ],
                kind: .action,
                summarize: { input in tr("takeover.plan", (input["task"] as? String) ?? "") },
                tag: { _ in (tr("takeover.tag"), .caution) },
                run: { [weak self] input in
                    guard let self else { throw NookError(tr("app.unavailable")) }
                    return try await self.takeOver((input["task"] as? String) ?? "")
                }
            )
        ]
    }

    /// The question to the user while a task runs: sign in, fill in payment details, make a choice. Run through the
    /// task's own `perform`, never offered in the chat.
    private var waitForUserTool: ToolSpec {
        ToolSpec(
            name: TakeoverPolicy.waitTool,
            description: "Asks the user to do one thing only they can do (sign in, enter payment details or a code, solve a captcha, make a choice) and waits until they say it is done. Say exactly what they should do, in their language.",
            schema: [
                "type": "object",
                "properties": ["request": ["type": "string", "description": "What the user should do, e.g. \"Log in bij bol.com in Safari\"."]],
                "required": ["request"]
            ],
            kind: .action,
            summarize: { input in (input["request"] as? String) ?? "" },
            tag: { _ in ("", .neutral) },
            run: { _ in "" }
        )
    }

    // MARK: Starting from the notch

    /// A double tap (or one tap) of the Double Tap key: a small field in the notch asks what Nook should do, with nothing
    /// around it but its send button. Escape closes it. A tap while a task runs stops it.
    func presentTakeoverPrompt() {
        if TakeoverState.shared.isRunning {
            TakeoverState.shared.stop()
            return
        }
        guard settings.brainReady else {
            presentSetupCard()
            return
        }
        let close = CardAction(label: tr("button.close"), outcome: .dismiss)
        let card = NookCard(
            id: Self.takeoverCardPrefix + UUID().uuidString,
            mood: .listen,
            context: tr("takeover.title"),
            title: tr("takeover.prompt.title"),
            detail: .none,
            primary: close,
            secondary: CardAction(label: "", outcome: .dismiss),
            contentHeight: 46,
            input: true,
            inputPrompt: tr("takeover.prompt.title"),
            focusesInput: true,
            compact: true,
            escape: close
        )
        viewModel.show(.card(card))
    }

    /// What was typed in the notch's quick field: a new conversation in the Nook chat, through the same path as a message
    /// typed there (`handleUserText`), so the quick field can do everything the chat can. The notch stays small while
    /// Nook works; the answer arrives as a card with View, and opening the notch yourself shows the chat.
    func askFromQuickField(_ text: String) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        viewModel.show(.idle)
        // "Vul het formulier in": Double Tap fills the form in front, once the app you were in has the keyboard back.
        if DoubleTapLogic.asksToFill(request) {
            DoubleTap.shared.fill(request: request, after: 0.3)
            return
        }
        // "Schrijf een sollicitatiebrief", "vertaal dit": typed where your cursor is, in Word or any other app. Without a
        // cursor in a text, it is a chat message after all.
        if DoubleTapLogic.asksToWrite(request) {
            DoubleTap.shared.write(request: request, after: 0.3) { [weak self] in
                self?.chat.startNew()
                self?.handleUserText(request, reveal: false)
            }
            return
        }
        chat.startNew()
        handleUserText(request, reveal: false)
        followInNotch()
    }

    /// While Nook answers what was typed in the quick field, the notch shows how it gets there in one slim line with
    /// Stop: what it looks at, then the answer as it is written. The answer itself arrives as a card with View, as before.
    private func followInNotch() {
        guard let conversation = chat.activeID, chat.isBusy(conversation) else { return }
        Task { @MainActor [weak self] in
            var shown = ""
            while !Task.isCancelled {
                guard let self, self.chat.isBusy(conversation) else { break }
                if let id = self.replies[conversation], let message = self.chat.message(id) {
                    let line = DoubleTapLogic.progressLine(text: message.text, status: message.status)
                    if !line.isEmpty, line != shown {
                        shown = line
                        self.viewModel.showWork(line) { [weak self] in self?.stop(conversation: conversation) }
                    }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            // Only the line goes: the card with the answer, or anything else shown since, stays.
            guard let self, case .done(let current) = self.viewModel.state, current == shown else { return }
            self.viewModel.endWork()
        }
    }

    // MARK: Running

    /// Carries out one task and returns the brain's summary. Throws when it could not, or when the user stopped it.
    /// `messageID`: the chat message that follows the task's steps.
    func takeOver(_ task: String, messageID: UUID? = nil) async throws -> String {
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { throw NookError(tr("takeover.noTask")) }
        let state = TakeoverState.shared
        guard !state.isRunning else { throw NookError(tr("takeover.busy")) }
        state.isRunning = true
        state.stopRequested = false
        state.messageID = messageID
        state.cookieBanner = false
        UIDriver.onAct = { point, label in TakeoverCursor.shared.move(to: point, label: label) }
        defer {
            state.isRunning = false
            state.resolve(false)
            state.task = nil
            state.messageID = nil
            state.browser = nil
            UIDriver.onAct = nil
            TakeoverCursor.shared.hide()
            viewModel.endWork()
        }
        updateTakeover(tr("takeover.starting"))
        store.audit(tool: TakeoverPolicy.toolName, args: task, result: "")

        // What Nook already knows: the app in front (not Nook itself), its text and a picture of it, the user's memories.
        let own = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == own ? nil : $0 }
        let screenAllowed = settings.liveScreen && !settings.privateSources.contains(SourceCatalog.screen)
        var screen = ""
        if screenAllowed, let bundle = front?.bundleIdentifier {
            let windows = screenContext.windows.filter { $0.bundleID == bundle }
            screen = settings.shielded(((windows.first { $0.isFront } ?? windows.first)?.text) ?? "")
        }
        var images: [ChatImage] = []
        if screenAllowed, let front, let shot = await ScreenReader.windowImage(of: front, scale: 1),
           let image = ChatImage.encode(shot.image) {
            images = [image]
        }
        let memories = recalledMemories(for: task, scope: .automatic, tools: []).map(\.text)
        state.browser = UIDriver.userBrowser()
        let prompt = TakeoverPolicy.prompt(task: task, frontApp: front?.localizedName ?? "", window: "", screen: screen,
                                           memories: memories, dates: ChatIntent.dateSheet(),
                                           browser: state.browser?.localizedName ?? "")

        // Sources kept on this Mac stay out of reach of an external brain here too (the screen, when it is one of them).
        let available = scopedTools(SourceScope.automatic.keepingLocal(settings.privateSources), ledger: nil)
        guard available.contains(where: { $0.name == "read_ui" }), available.contains(where: { $0.name == "control_ui" }) else {
            throw NookError(tr("takeover.screenPrivate"))
        }
        let tools = Self.takeoverToolNames.compactMap { name in available.first { $0.name == name } }.map(followed).map(inBrowser)
            + [waitForUserTool]
        if state.stopRequested { throw NookError(tr("takeover.stopped")) }
        let run = Task { @MainActor [weak self] () throws -> String in
            guard let self else { throw CancellationError() }
            return try await self.brain.runTask(system: TakeoverPolicy.system, prompt: prompt, tools: tools, images: images,
                                                perform: { [weak self] tool, input in
                                                    guard let self else { return ("Nook is not available.", true) }
                                                    return await self.performTakeoverStep(tool, input, tools: tools)
                                                })
        }
        state.task = run
        let text: String
        do {
            text = try await withTaskCancellationHandler { try await run.value } onCancel: { run.cancel() }
        } catch {
            if run.isCancelled || error is CancellationError {
                store.audit(tool: TakeoverPolicy.toolName, args: task, result: "gestopt")
                throw NookError(tr("takeover.stopped"))
            }
            throw error
        }
        let result = TakeoverPolicy.outcome(of: text)
        store.audit(tool: TakeoverPolicy.toolName, args: task, result: String(describing: result.outcome))
        switch result.outcome {
        case .done:
            NookPresence.shared.celebrate()
            return result.summary.isEmpty ? tr("takeover.done") : result.summary
        case .couldNot(let reason):
            throw NookError(result.summary.isEmpty ? tr("takeover.couldNot", reason) : result.summary)
        case .unconfirmed:
            return (result.summary.isEmpty ? "" : result.summary + "\n\n") + tr("takeover.unconfirmed")
        }
    }

    /// One action of the brain: refused, asked first, or run, with the step in the notch.
    private func performTakeoverStep(_ tool: String, _ input: [String: Any], tools: [ToolSpec]) async -> (output: String, isError: Bool) {
        guard let spec = tools.first(where: { $0.name == tool }) else { return ("Unknown tool \(tool).", true) }
        if tool == TakeoverPolicy.waitTool {
            let request = (input["request"] as? String) ?? ""
            updateTakeover(tr("takeover.waiting"))
            let done = await askTakeoverUser(title: tr("takeover.wait.title"), line: request, yes: tr("takeover.wait.yes"))
            return done
                ? ("The user says it is done. Read the window again (read_ui) and continue.", false)
                : ("The user stopped the task. Summarize what is done and what is left, and end with STATUS: COULD_NOT — stopped by the user.", false)
        }
        if let refusal = TakeoverPolicy.refusal(tool: tool, input: input) { return (refusal, true) }
        let summary = spec.summarize(input)
        if let line = TakeoverPolicy.checkpoint(tool: tool, input: input, summary: summary,
                                                cookieBanner: TakeoverState.shared.cookieBanner) {
            updateTakeover(tr("takeover.waiting"))
            let yes = await askTakeoverUser(title: tr("takeover.check.title"), line: line, yes: tr("takeover.check.yes"))
            guard yes else {
                store.audit(tool: tool, args: Self.json(input), result: "geweigerd door gebruiker")
                return ("The user said no to this step; it did not run. Do not try it another way. Summarize what is done and what is left, and end with STATUS: COULD_NOT — the user declined.", false)
            }
        }
        updateTakeover(summary)
        let args = Self.json(input)
        do {
            let result = try await spec.run(input)
            store.audit(tool: tool, args: args, result: result)
            if tool == UIDriver.readTool { TakeoverState.shared.cookieBanner = TakeoverPolicy.showsCookieBanner(result) }
            return (result, false)
        } catch {
            store.audit(tool: tool, args: args, result: "FOUT: \(error.localizedDescription)")
            return ("Error: \(error.localizedDescription)", true)
        }
    }

    /// A read tool that also shows in the notch what Nook looks at.
    private func followed(_ spec: ToolSpec) -> ToolSpec {
        guard spec.kind == .read else { return spec }
        return ToolSpec(name: spec.name, description: spec.description, schema: spec.schema, kind: spec.kind,
                        summarize: spec.summarize, tag: spec.tag,
                        run: { [weak self] input in
                            self?.updateTakeover(spec.summarize(input))
                            return try await spec.run(input)
                        })
    }

    /// Web pages open in the user's browser (the one they have open), not in whatever the default browser is.
    private func inBrowser(_ spec: ToolSpec) -> ToolSpec {
        guard spec.name == "open_url" else { return spec }
        return ToolSpec(name: spec.name, description: "Opens a web URL (https) in the user's browser.", schema: spec.schema,
                        kind: spec.kind, summarize: spec.summarize, tag: spec.tag,
                        run: { input in
                            guard let browser = TakeoverState.shared.browser, let bundle = browser.bundleURL,
                                  let text = input["url"] as? String, let url = URL(string: text),
                                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
                                return try await spec.run(input)
                            }
                            let configuration = NSWorkspace.OpenConfiguration()
                            configuration.activates = true
                            _ = try await NSWorkspace.shared.open([url], withApplicationAt: bundle, configuration: configuration)
                            return "Opened in \(browser.localizedName ?? "the browser")"
                        })
    }

    /// The step in the notch's slim line and in the chat message that follows the task.
    private func updateTakeover(_ line: String) {
        let state = TakeoverState.shared
        let clean = Self.firstLine(line)
        state.line = clean
        viewModel.showWork(clean) { TakeoverState.shared.stop() }
        if let id = state.messageID { chat.update(id) { $0.status = clean } }
    }

    /// A card that waits for the user's yes or no (a checkpoint, or something only they can do). No after ten minutes
    /// without an answer, on Esc, and when the task is stopped.
    private func askTakeoverUser(title: String, line: String, yes: String) async -> Bool {
        let state = TakeoverState.shared
        let token = "takeover-check-" + UUID().uuidString
        viewModel.register("\(token)#yes") { TakeoverState.shared.resolve(true) }
        viewModel.register("\(token)#no") { TakeoverState.shared.resolve(false) }
        let no = CardAction(label: tr("takeover.check.no"), outcome: .callback("\(token)#no", ""))
        // The whole step, wrapped: what the user approves must be all there is to read.
        let lines = max(1, Int(ceil(Double(line.count) / 58.0)))
        let card = NookCard(
            id: token,
            mood: .waiting,
            context: tr("takeover.title"),
            title: title,
            detail: .note(line, label: tr("takeover.check.step")),
            primary: CardAction(label: yes, outcome: .callback("\(token)#yes", "")),
            secondary: no,
            contentHeight: 124 + CGFloat(min(lines, 8)) * 20,
            escape: no,
            status: CardStatus(text: tr("card.status.approval"), tone: .waiting)
        )
        let timeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            guard !Task.isCancelled else { return }
            TakeoverState.shared.resolve(false)
        }
        defer { timeout.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                state.resolve(false)
                state.decision = continuation
                viewModel.presentUrgent(card)
            }
        } onCancel: {
            Task { @MainActor in TakeoverState.shared.resolve(false) }
        }
    }

    nonisolated static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return String(line.trimmingCharacters(in: .whitespaces).prefix(120))
    }
}
