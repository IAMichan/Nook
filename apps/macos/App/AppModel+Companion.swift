// WhatsApp, Flow, the Notetaker, shortcuts, undo and attaching a window.
import SwiftUI
import Combine

/// WhatsApp through the linked phone: its chats are every chat app's (`WhatsAppGatewayBridge` brings them into the
/// shared inbox), so a new message shows as the same chat card every app gets, answered the same way.
extension AppModel {
    /// How many of a chat's newest photos, videos and documents an opened chat or card fetches to show.
    static let whatsAppPreviewCount = 6

    /// A file a chat shows by itself once fetched: a photo, a video, a document, a sticker or a voice message.
    static func whatsAppPreviews(_ media: WAMedia) -> Bool {
        switch media {
        case .image, .video, .document, .sticker, .audio, .voice: return true
        default: return false
        }
    }

    func startWhatsApp() {
        // The linked accounts' chats come into the shared inbox, and with them their news (`WhatsAppGatewayBridge`).
        ChatCaptureService.shared.whatsAppGatewayBridge.start()
        // A WhatsApp that went through Beeper links in Nook's own way from now on.
        BeeperImporter.migrateSettings()
        WhatsAppAccounts.shared.start()
    }

    /// Changes the card on screen in place, if it is still the one with this id. False when it is gone.
    @discardableResult
    func editShownCard(_ id: String, _ change: (inout NookCard) -> Void) -> Bool {
        guard case .card(var card) = viewModel.state, card.id == id else { return false }
        change(&card)
        viewModel.updateCard(card)
        return true
    }

    /// Room for the context, the name, the bubbles, the answer field and the buttons. A bubble holds about 48
    /// characters per line and at most 12 lines (a longer one folds), a file adds a row, and so do a quoted message and
    /// the emoji under it. The bubbles always get room for a few messages, and what does not fit in their maximum height
    /// scrolls.
    static func chatCardHeight(_ bubbles: [ChatBubble]) -> CGFloat {
        let chrome: CGFloat = 16 + 6 + 24 + 10 + 12 + 48 + 38 + 24
        let stack = bubbles.reduce(CGFloat(0)) { total, bubble in
            let lines = bubble.text.isEmpty ? 0 : min(12, max(1, (bubble.text.count + 47) / 48))
            let file: CGFloat
            switch bubble.media {
            case .photo(let url): file = ((bubble.image?.size ?? ChatMediaImages.pixelSize(url)).map(Self.photoHeight) ?? 135) + 4
            case .video: file = (bubble.image.map { Self.photoHeight($0.size) } ?? 135) + 4
            case .photoComing: file = 135 + 4
            case .gif: file = ChatGIFView.maxHeight + 4
            case .sticker: file = ChatStickerView.side + 4
            case .audio: file = 44
            case .file: file = bubble.attachment == nil ? 0 : (bubble.image == nil ? 40 : 60)
            }
            return total + 16 + max(CGFloat(lines) * 18, bubble.attachment == nil ? 18 : 14) + file
                + (bubble.sender.isEmpty ? 0 : 16) + (bubble.quote == nil ? 0 : 44) + (bubble.reactions.isEmpty ? 0 : 26) + 5
        }
        return chrome + min(max(stack, 140), 320)
    }

    /// How tall a bubble's photo stands: fitted in 240 × 180.
    static func photoHeight(_ size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 0 }
        return min(180, 240 * size.height / size.width)
    }
}

/// Flow, dictation anywhere: its clean-up runs on Nook's own brain.
extension AppModel {
    func startFlow() {
        FlowDictation.shared.rewrite = { [weak self] system, text, timeout in
            await self?.brain.rewrite(system: system, prompt: text, timeout: timeout)
        }
        FlowDictation.shared.refresh()
        startAutocomplete()
        startDoubleTap()
        // From now on every permission is checked again whenever Nook comes to the front.
        PermissionMonitor.shared.refresh()
    }

    /// Autocomplete anywhere, with what only Nook knows: your memory and the text it already reads on screen.
    func startAutocomplete() {
        let autocomplete = AutocompleteController.shared
        autocomplete.facts = { [weak self] context in
            guard let self, self.settings.useMemory else { return [] }
            return self.memory.book.forCompletion(context).map(\.text)
        }
        autocomplete.screenText = { [weak self] bundleID in
            let windows = self?.screenContext.windows.filter { $0.bundleID == bundleID } ?? []
            return (windows.first { $0.isFront } ?? windows.first)?.text
        }
        autocomplete.refresh()
    }

    /// Double Tap: the notch asks what Nook should do; the form in front is filled with your memory and the screen, or
    /// the text you ask for is typed at your cursor, on the brain you chose, with every step in the notch. What goes to an
    /// external brain follows the same rules as a question: memories kept on this Mac stay here, and the screen only when
    /// the privacy level allows it. With a screen brain (`AppSettings.screenWorker`) Double Tap runs on it instead, so it reads
    /// what a brain on this Mac may read and nothing it reads leaves the Mac.
    func startDoubleTap() {
        let doubleTap = DoubleTap.shared
        doubleTap.ask = { [weak self] system, prompt, timeout in
            guard let self else { return nil }
            return await self.onScreenBrain { await self.brain.rewrite(system: system, prompt: prompt, timeout: timeout) }
        }
        doubleTap.facts = { [weak self] in
            guard let self, self.settings.useMemory, !self.doubleTapHidden.contains(SourceCatalog.memory) else { return [] }
            let local = self.settings.isLocalBrain || self.settings.screenWorker != nil
            return self.memory.items.filter { $0.kind != .lesson && $0.tool == nil && (local || !$0.localOnly) }
                .sorted { $0.strength > $1.strength }.prefix(30).map(\.text)
        }
        doubleTap.screenText = { [weak self] bundleID in
            guard let self, self.settings.liveScreen, !self.doubleTapHidden.contains(SourceCatalog.screen) else { return nil }
            let windows = self.screenContext.windows.filter { $0.bundleID == bundleID }
            return ((windows.first { $0.isFront } ?? windows.first)?.text).map(self.doubleTapShielded)
        }
        doubleTap.clipboardText = { [weak self] in
            guard let self, !self.doubleTapHidden.contains("clipboard"),
                  let text = NSPasteboard.general.string(forType: .string) else { return nil }
            return self.doubleTapShielded(String(text.prefix(4_000)))
        }
        // Nook's violet cursor shows where it selects and types in the document, as when it takes over a task.
        doubleTap.showCursor = { point, label in
            if let point { TakeoverCursor.shared.move(to: point, label: label) } else { TakeoverCursor.shared.hide() }
        }
        doubleTap.record = { [weak self] args, result in self?.store.audit(tool: "doubletap_edit", args: args, result: result) }
        doubleTap.present = { [weak self] outcome in self?.presentDoubleTap(outcome) }
        // Each step shows in the notch, with Stop: what Nook reads, what it thinks about, what it is about to type. A click
        // on it opens the notch, which lists every step and, once done, what Nook typed (`DoubleTapRunBar`).
        doubleTap.onStep = { [weak self] line in
            self?.viewModel.showWork(line, opensPanel: true) { DoubleTap.shared.stop() }
        }
        doubleTap.showSteps = { [weak self] in
            // An open panel already shows the steps under its tabs.
            guard let self else { return }
            if case .panel = self.viewModel.state { return }
            self.viewModel.openPanel()
        }
        doubleTap.onStepsEnd = { [weak self] last in
            // Only the step line goes: a result shown in its place since (a toast, a card) stays.
            guard let self, case .done(let shown) = self.viewModel.state, shown == last else { return }
            self.viewModel.endWork()
        }
        doubleTap.onAsk = { [weak self] in self?.presentTakeoverPrompt() }
        doubleTap.refresh()
    }

    /// The sources Double Tap may not read: none when it runs on the screen brain, which is on this Mac.
    private var doubleTapHidden: Set<String> {
        settings.screenWorker != nil ? [] : settings.privateSources
    }

    /// What Double Tap read, as the brain it runs on may get it: unchanged for the screen brain on this Mac.
    private func doubleTapShielded(_ text: String) -> String {
        settings.screenWorker != nil ? text : settings.shielded(text)
    }

    /// What a double tap filled in, as a card that waits for you: Send presses the form's own button (only from here,
    /// never by itself), Undo empties the fields again. Esc closes the card and sends nothing.
    func presentDoubleTap(_ outcome: DoubleTapOutcome) {
        let token = "doubletap-" + UUID().uuidString
        let shown = Array(outcome.filled.prefix(6))
        var facts = shown.map { Fact(label: String(($0.label.isEmpty ? tr("doubletap.card.field") : $0.label).prefix(40)),
                                     value: String($0.value.prefix(90))) }
        if outcome.filled.count > shown.count { facts.append(Fact(label: "", value: tr("doubletap.card.more", outcome.filled.count - shown.count))) }
        let close = CardAction(label: tr("app.ok"), outcome: .dismiss)
        var primary = close
        if let submit = outcome.submit {
            viewModel.register("\(token)#send") {
                if submit.perform() {
                    ToastCenter.shared.success(tr("doubletap.sent", outcome.app))
                } else {
                    ToastCenter.shared.warning(tr("doubletap.sendFailed", submit.label))
                }
            }
            primary = CardAction(label: submit.label, outcome: .callback("\(token)#send", ""), symbol: "paperplane")
        }
        var secondary = close
        if let undo = outcome.undo {
            viewModel.register("\(token)#undo") { undo() }
            secondary = CardAction(label: tr("doubletap.undo"), outcome: .callback("\(token)#undo", tr("doubletap.undone")),
                                   symbol: "arrow.uturn.backward")
        }
        let title = outcome.count == 1 ? tr("doubletap.filledOne", outcome.app) : tr("doubletap.filled", outcome.count, outcome.app)
        let card = NookCard(
            id: token,
            mood: outcome.submit == nil ? .done : .waiting,
            context: tr("doubletap.settings.title"),
            title: title,
            detail: .facts(facts),
            primary: primary,
            secondary: secondary,
            contentHeight: 116 + CGFloat(facts.count) * 26,
            escape: close,
            notice: tr(outcome.submit == nil ? "doubletap.notSent" : "doubletap.card.check"),
            status: outcome.submit == nil ? nil : CardStatus(text: tr("card.status.approval"), tone: .waiting)
        )
        viewModel.present(card)
    }
}

/// Autocomplete in the notch's Today: a line when it is on but cannot work, and what it saved you today.
extension AppModel {
    func autocompleteAttentionItem() -> TodayItem? {
        let autocomplete = AutocompleteController.shared
        guard autocomplete.needsAttention else { return nil }
        let subtitle: String
        switch autocomplete.state {
        case .noAccess: subtitle = tr("autocomplete.today.noAccess")
        case .noModel: subtitle = tr("autocomplete.today.noModel")
        case .failed(let message): subtitle = message
        default: subtitle = ""
        }
        return TodayItem(id: "autocomplete-attention", title: tr("autocomplete.today.attention"), subtitle: subtitle,
                         action: tr("autocomplete.today.fix"), color: NookTheme.amber,
                         target: .action { [weak self] in self?.openAutocompleteSettings(.general) },
                         logo: .symbol("keyboard"))
    }

    func autocompleteTodayItem() -> TodayItem? {
        let store = AutocompleteStore.shared
        let today = store.stats.day()
        guard store.prefs.enabled, today.takes > 0 else { return nil }
        let minutes = max(1, Int((Double(today.words) / 40).rounded()))
        return TodayItem(id: "autocomplete-today", title: tr("autocomplete.today.used", today.takes),
                         subtitle: tr("autocomplete.today.usedSub", today.words, minutes),
                         action: tr("button.view"), color: NookTheme.mint,
                         target: .action { [weak self] in self?.openAutocompleteSettings(.stats) },
                         logo: .symbol("text.cursor"))
    }

    func openAutocompleteSettings(_ tab: AutocompleteSettingsTab) {
        AutocompleteStore.shared.settingsTab = tab
        openSettings(section: .autocomplete)
    }
}

/// The Notetaker: the summary is written by Nook's brain, the finished note lands in the chat as a new Nook.
extension AppModel {
    func startNotes() {
        let notes = NoteTaker.shared
        notes.summarize = { [weak self] system, transcript in
            await self?.brain.rewrite(system: system, prompt: transcript, timeout: 180)
        }
        notes.locale = { [weak self] in
            guard let self else { return Locale(identifier: "nl-NL") }
            return VoiceService.locale(answerLanguage: self.settings.language, appLanguage: self.settings.appLanguage.rawValue)
        }
        notes.onFinished = { [weak self] note in self?.presentNote(note) }
        // perf: the same problem twice is two failed recordings, and each gets its card.
        notes.$problem
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] problem in
                guard let self else { return }
                self.viewModel.present(self.errorCard(problem))
            }
            .store(in: &bag)
        notes.$current
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { recording in
                if recording { RecordingBadge.shared.show() } else { RecordingBadge.shared.hide() }
            }
            .store(in: &bag)
    }

    func presentNote(_ note: Note) {
        let conversation = chat.startNew()
        var message: ChatMessage
        if note.status == .failed {
            message = ChatMessage(role: .nook, text: note.error ?? tr("notes.problem.empty"))
        } else {
            message = ChatMessage(role: .nook, text: NoteTaker.shared.markdown(note))
            message.sources = [tr("notes.source")]
            if !note.todos.isEmpty { message.offers = [tr("notes.offer.reminders"), tr("notes.offer.mail")] }
        }
        chat.append(message, to: conversation)
        logNotice(note.status == .failed ? .failed : .done, title: tr("notes.ready", note.title), target: .conversation(conversation))
        presentNookNotice(title: tr("notes.ready", note.title), detail: "", button: tr("notes.open"),
                          mood: note.status == .failed ? .worry : .done) { [weak self] in self?.openConversation(conversation) }
    }
}

/// Global shortcuts, as set in Settings › Overview.
extension AppModel {
    func reloadHotKeys() {
        // The old keys go first: a new one with the same id would lose its handler when the old one is released.
        hotKeys = []
        let set = ShortcutSet.load()
        hotKeys = ShortcutAction.allCases.compactMap { action in
            guard let shortcut = set.shortcut(for: action) else { return nil }
            return HotKey(id: action.hotKeyID, keyCode: Int(shortcut.keyCode), modifiers: Int(shortcut.modifiers)) { [weak self] in
                self?.perform(action)
            }
        }
    }

    func perform(_ action: ShortcutAction) {
        switch action {
        case .talk: toggleVoice()
        case .ask: openAsk()
        case .lookAtScreen: lookAtScreen(manual: true)
        case .screenPart: captureScreenPart()
        case .recordCall: NoteTaker.shared.toggle()
        }
    }

    /// Changes a shortcut. Returns the action that gave it up, if another one had it.
    @discardableResult
    func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) -> ShortcutAction? {
        var set = ShortcutSet.load()
        let displaced = set.set(shortcut, for: action)
        set.save()
        reloadHotKeys()
        objectWillChange.send()
        return displaced
    }
}

/// "Maak ongedaan": what Nook just did in your calendar, reminders or to-dos, reversed as a plan you approve.
extension AppModel {
    func remember(_ step: PlanRunner.Step, result: String) {
        recentActions.removeAll { Date().timeIntervalSince($0.date) > 1_800 }
        recentActions.append((item: (tool: step.tool, input: step.input, result: result), date: Date()))
    }

    func proposeUndo(asked text: String) {
        let conversation = chat.ensureActive()
        chat.append(ChatMessage(role: .user, text: text), to: conversation)
        let batch = Undo.batch(recentActions)
        let steps = batch.compactMap { Undo.step(tool: $0.tool, input: $0.input, result: $0.result) }
        var reply = ChatMessage(role: .nook, text: "")
        if batch.isEmpty {
            reply.text = tr("undo.nothing")
        } else if steps.isEmpty {
            reply.text = tr("undo.cannot")
        } else {
            let actions = steps.map { PlannedAction(tool: $0.tool, input: $0.input) }
            reply.text = steps.count < batch.count ? tr("undo.partly") : tr("undo.ready")
            reply.actions = actions
            reply.actionStates = Array(repeating: .pending, count: actions.count)
            reply.actionIncluded = Array(repeating: true, count: actions.count)
            reply.actionProblems = actions.map { actionProblems($0, scope: .automatic) }
        }
        chat.append(reply, to: conversation)
        showChat()
    }
}

/// ⌥-drag Nook onto a window: that window's picture and text are attached to the chat.
extension AppModel {
    func startWindowAttach() {
        WindowAttach.shared.onAttach = { [weak self] image, target in self?.attachWindow(image, target: target) }
        WindowAttach.shared.onFailure = { [weak self] message in
            guard let self else { return }
            self.viewModel.present(self.errorCard(message))
        }
    }

    func attachWindow(_ cg: CGImage, target: WindowAttach.Target) {
        guard let image = ChatImage.encode(cg) else { return }
        let name = target.title.isEmpty ? target.app : "\(target.app) — \(target.title)"
        showChat()
        Task { @MainActor [weak self] in
            let recognized = (try? await ScreenReader.recognize(cg)) ?? ""
            guard let self else { return }
            self.attachment = (name, ChatImage.describe(name: name, recognized: recognized), Date())
            self.attachmentImages = [image]
            var message = ChatMessage(role: .nook, text: tr("attach.window.done", name))
            message.sources = [target.app]
            self.chat.append(message)
        }
    }
}
