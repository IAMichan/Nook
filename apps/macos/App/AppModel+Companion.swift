// WhatsApp, Flow, the Notetaker, shortcuts, undo and attaching a window.
import SwiftUI
import Combine

/// WhatsApp in the notch: a new message shows as a card with the chat so far (it scrolls back) and a field to answer.
/// What you type there goes to that chat when you press Return or click the arrow (your own words, your own click);
/// a photo shows in the bubble and a click enlarges it in the card, a document shows in Quick Look with a click, a
/// video plays in the bubble; a message can be answered as a quote or get an emoji (your own click, logged like a send);
/// "Let Nook answer" hands the chat to Nook, who proposes an answer as a plan you approve.
extension AppModel {
    static let whatsAppCardPrefix = "whatsapp-"
    /// How many of a chat's newest photos, videos and documents its card fetches to show.
    static let whatsAppPreviewCount = 6

    /// A file the card shows by itself: a photo, a video or a document (a voice note stays a button).
    static func whatsAppPreviews(_ media: WAMedia) -> Bool {
        switch media {
        case .image, .video, .document: return true
        default: return false
        }
    }

    func startWhatsApp() {
        WhatsAppLink.shared.onMessage = { [weak self] chat in self?.presentWhatsApp(chat) }
        // New ticks redraw the chat's card when it is on screen; they never bring one up by themselves.
        WhatsAppLink.shared.onReceipt = { [weak self] chat in
            guard let self, self.viewModel.hasCard(id: Self.whatsAppCardPrefix + chat) else { return }
            self.presentWhatsApp(chat)
        }
        // Read on the phone: a card still waiting in line goes; the one on screen stays (you may be typing) and is redrawn.
        WhatsAppLink.shared.onReadElsewhere = { [weak self] chat in
            guard let self else { return }
            let token = Self.whatsAppCardPrefix + chat
            self.viewModel.removePending(id: token)
            if self.viewModel.isShowing(card: token) { self.presentWhatsApp(chat) }
        }
        WhatsAppLink.shared.start()
    }

    /// A new message (or new ticks) in `chat`: its card, or the card on screen redrawn. Nothing is marked read by showing it.
    /// `asked`: you opened the chat yourself ("@open chat Jan"), so the card comes up now, even with notifications off.
    func presentWhatsApp(_ chat: String, asked opened: Bool = false) {
        let link = WhatsAppLink.shared
        let token = Self.whatsAppCardPrefix + chat
        let asked = opened || viewModel.hasCard(id: token)
        guard asked || WhatsAppSettings.notify, let conversation = link.inbox.conversations[chat],
              asked ? !conversation.messages.isEmpty : conversation.messages.contains(where: { !$0.fromMe }) else { return }
        viewModel.register("\(token)#read") { link.markRead(chat) }
        viewModel.register("\(token)#nook") { [weak self] in
            guard let self else { return }
            link.markRead(chat)
            // Only this chat is read, and asking for a draft teaches memory nothing about the user.
            self.ask(tr("whatsapp.card.nookPrompt", conversation.name),
                     focus: [Prefetch.Call(tool: "whatsapp_live", input: ["chat": chat, "limit": 20])], reflects: false)
        }
        viewModel.register("\(token)#quiet") { link.mute(chat) }
        viewModel.register("\(token)#mute") { link.ignore(chat) }

        // In the notice history: the newest message from them, once (the card also updates for your own replies and ticks).
        if !opened, let last = conversation.messages.last(where: { !$0.fromMe }) {
            let file = Self.whatsAppFileLabel(last.media)
            let text = file == nil ? Self.whatsAppText(last) : (last.text.isEmpty ? file ?? "" : last.text)
            let sender = conversation.isGroup && !last.senderName.isEmpty ? last.senderName + ": " : ""
            if NoticeHistory.shared.entries.first(where: { $0.key == token })?.detail != NoticeLog.detail(sender + text) {
                logNotice(.info, title: conversation.name, detail: sender + text, context: "WhatsApp",
                          target: .whatsApp(chat), key: token)
            }
        }
        let messages = conversation.messages.suffix(WAInbox.keep)
        let bubbles = Self.whatsAppBubbles(conversation)
        let unread = conversation.unread > 1 ? " · \(tr("whatsapp.card.unread", conversation.unread))" : ""
        let card = NookCard(
            id: token,
            mood: .remind,
            context: "WhatsApp\(unread)",
            appIcon: "whatsapp",
            title: conversation.name,
            detail: .chat(bubbles),
            primary: CardAction(label: tr("whatsapp.card.read"), outcome: .callback("\(token)#read", "")),
            secondary: CardAction(label: tr("button.later"), outcome: .dismiss),
            contentHeight: Self.whatsAppCardHeight(bubbles),
            input: true,
            inputPrompt: tr("whatsapp.card.answer", conversation.name),
            // A new message never takes the keyboard from what you are doing; a chat you opened yourself does.
            focusesInput: opened,
            chatReply: true,
            extra: [CardAction(label: tr("whatsapp.card.nook"), outcome: .callback("\(token)#nook", ""), symbol: "sparkles")],
            more: [CardAction(label: tr("whatsapp.card.quiet"), outcome: .callback("\(token)#quiet", ""), symbol: "bell.slash"),
                   CardAction(label: tr("whatsapp.card.mute"), outcome: .callback("\(token)#mute", ""), symbol: "eye.slash")],
            escape: CardAction(label: "", outcome: .dismiss)
        )
        // A hidden notch (a full-screen app) keeps it in line until it shows again.
        if opened, !viewModel.isShowing(card: token) {
            // Asked for: in front now, ahead of the queue, instead of waiting behind the chat.
            viewModel.removePending(id: token)
            viewModel.presentUrgent(card)
        } else if viewModel.hasCard(id: token) {
            viewModel.updateCard(card)
        } else {
            viewModel.present(card)
        }

        // Older messages from the gateway, once per chat, so the card can scroll back further than what came in.
        Task { @MainActor [weak self] in
            guard await WhatsAppLink.shared.loadHistory(chat), let self, self.viewModel.hasCard(id: token) else { return }
            self.presentWhatsApp(chat)
        }
        // The newest photos, videos and documents (a fixed few, so a redraw never reaches further back), fetched once
        // each, then shown in their bubbles.
        let wanted = messages.filter { Self.whatsAppPreviews($0.media) }.suffix(Self.whatsAppPreviewCount)
            .filter { link.preview($0.id) == nil }.map(\.id)
        if !wanted.isEmpty {
            Task { @MainActor [weak self] in
                guard await link.loadPreviews(wanted, chat: chat), let self, self.viewModel.hasCard(id: token) else { return }
                self.presentWhatsApp(chat)
            }
        }
    }

    /// A chat as bubbles, the newest at the bottom; in a group each says who wrote it. Once fetched, a photo shows as
    /// itself, a video plays in its bubble and a document shows its first page; until then a file is a button.
    static func whatsAppBubbles(_ conversation: WAConversation) -> [ChatBubble] {
        let link = WhatsAppLink.shared
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        let byID = Dictionary(conversation.messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return conversation.messages.suffix(WAInbox.keep).map { message in
            let file = Self.whatsAppFileLabel(message.media)
            var bubble = ChatBubble(id: message.id, text: file == nil ? Self.whatsAppText(message) : message.text,
                                    time: time.string(from: message.date), date: message.date,
                                    sender: conversation.isGroup && !message.fromMe ? message.senderName : "",
                                    fromMe: message.fromMe, attachment: file,
                                    ticks: message.fromMe ? message.receipt.map(Self.bubbleTicks) : nil)
            bubble.quote = Self.whatsAppQuote(message, in: byID, conversation: conversation)
            bubble.reactions = Self.bubbleReactions(message.reactions)
            if let preview = link.preview(message.id) {
                bubble.image = preview.image
                switch message.media {
                case .image: bubble.media = .photo(preview.file)
                case .video: bubble.media = .video(preview.file)
                default: break
                }
            }
            return bubble
        }
    }

    /// What a message answers, as its bubble quotes it: the message itself when Nook keeps it, else the text the
    /// gateway quoted. Nil when it answers nothing, or nothing is known of what it answers.
    static func whatsAppQuote(_ message: WAMessage, in byID: [String: WAMessage], conversation: WAConversation) -> BubbleQuote? {
        guard let id = message.replyTo else { return nil }
        if let answered = byID[id] {
            let sender = answered.fromMe ? tr("chat.you")
                : (conversation.isGroup ? answered.senderName : conversation.name)
            let file = Self.whatsAppFileLabel(answered.media)
            let text = answered.text.isEmpty ? (file ?? Self.whatsAppText(answered)) : answered.text
            return BubbleQuote(sender: sender, text: text, mine: answered.fromMe)
        }
        guard let quoted = message.quotedText, !quoted.isEmpty else { return nil }
        return BubbleQuote(sender: "", text: quoted)
    }

    /// The emoji on a message, one chip each, the most used first (then in the order they came).
    static func bubbleReactions(_ reactions: [WAReaction]) -> [BubbleReaction] {
        var chips: [BubbleReaction] = []
        for reaction in reactions where !reaction.emoji.isEmpty {
            if let index = chips.firstIndex(where: { $0.emoji == reaction.emoji }) {
                chips[index].count += 1
                chips[index].mine = chips[index].mine || reaction.fromMe
            } else {
                chips.append(BubbleReaction(emoji: reaction.emoji, count: 1, mine: reaction.fromMe))
            }
        }
        return chips.enumerated().sorted { a, b in
            a.element.count != b.element.count ? a.element.count > b.element.count : a.offset < b.offset
        }.map(\.element)
    }

    /// Return in a WhatsApp card's field: the text goes to that chat as typed, as an answer to its message `replyTo`
    /// when one was quoted. The card says it is sending; when that fails it says why and puts the text back, so nothing
    /// typed is lost.
    func replyWhatsApp(_ text: String, chat: String, replyTo: String? = nil) {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // "@nook …" is a request to Nook, never a message for the chat; the card's field lets Nook write it.
        guard !reply.isEmpty, ChatDraft.instruction(in: reply) == nil else { return }
        let token = Self.whatsAppCardPrefix + chat
        editShownCard(token) { $0.notice = tr("whatsapp.card.sending"); $0.draft = nil }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let name = try await WhatsAppLink.shared.send(reply, to: chat, replyTo: replyTo)
                self.store.audit(tool: "whatsapp_send", args: name, result: "verstuurd")
                self.viewModel.dismissCard(id: token)
                self.viewModel.finish(tr("whatsapp.sent", name))
            } catch {
                let shown = self.editShownCard(token) {
                    $0.notice = tr("whatsapp.card.notSent", error.localizedDescription)
                    $0.draft = reply
                }
                if !shown { self.viewModel.present(self.errorCard(error.localizedDescription)) }
            }
        }
    }

    /// The field of a message card quoted one of its messages: the text goes to that chat as an answer to it.
    func replyCardMessage(_ text: String, to bubble: ChatBubble, card: NookCard) {
        guard card.id.hasPrefix(Self.whatsAppCardPrefix) else { return handleCardReply(text, card: card) }
        replyWhatsApp(text, chat: String(card.id.dropFirst(Self.whatsAppCardPrefix.count)), replyTo: bubble.id)
    }

    /// An emoji on a message in a card's chat, after your own click: it goes to the chat (the same emoji again takes it
    /// back) and is logged as a send is; the card redraws with it, or says why it could not.
    func reactCardMessage(_ bubble: ChatBubble, _ emoji: String, card: NookCard) {
        guard card.id.hasPrefix(Self.whatsAppCardPrefix) else { return }
        let chat = String(card.id.dropFirst(Self.whatsAppCardPrefix.count))
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.reactWhatsApp(emoji, to: bubble.id, chat: chat)
                if self.viewModel.hasCard(id: card.id) { self.presentWhatsApp(chat) }
            } catch {
                self.editShownCard(card.id) { $0.notice = error.localizedDescription }
            }
        }
    }

    /// A click on a file in a card's chat bubble: for WhatsApp, the file is fetched from the gateway (unless the card
    /// already has it) and shows in Quick Look, else in the app the Mac uses for it. The card stays open and says what
    /// happens.
    func openCardAttachment(_ bubble: ChatBubble, card: NookCard) {
        guard card.id.hasPrefix(Self.whatsAppCardPrefix) else { return }
        let chat = String(card.id.dropFirst(Self.whatsAppCardPrefix.count))
        editShownCard(card.id) { $0.notice = tr("whatsapp.file.opening", bubble.attachment ?? "") }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await WhatsAppLink.shared.download(message: bubble.id, chat: chat)
                let shown = FilePreviewWindow.shared.show(url, title: bubble.attachment ?? url.lastPathComponent)
                guard shown || NSWorkspace.shared.open(url) else { throw NookError(tr("whatsapp.file.noApp")) }
                self.editShownCard(card.id) { $0.notice = nil }
            } catch {
                let shown = self.editShownCard(card.id) { $0.notice = error.localizedDescription }
                if !shown { self.viewModel.present(self.errorCard(error.localizedDescription)) }
            }
        }
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
    static func whatsAppCardHeight(_ bubbles: [ChatBubble]) -> CGFloat {
        let chrome: CGFloat = 16 + 6 + 24 + 10 + 12 + 48 + 38 + 24
        let stack = bubbles.reduce(CGFloat(0)) { total, bubble in
            let lines = bubble.text.isEmpty ? 0 : min(12, max(1, (bubble.text.count + 47) / 48))
            let file: CGFloat
            switch bubble.media {
            case .photo, .video: file = (bubble.image.map(Self.photoHeight) ?? 135) + 4
            case .file: file = bubble.attachment == nil ? 0 : (bubble.image == nil ? 40 : 60)
            }
            return total + 16 + max(CGFloat(lines) * 18, bubble.attachment == nil ? 18 : 14) + file
                + (bubble.sender.isEmpty ? 0 : 16) + (bubble.quote == nil ? 0 : 44) + (bubble.reactions.isEmpty ? 0 : 26) + 5
        }
        return chrome + min(max(stack, 140), 320)
    }

    /// How tall a bubble's photo stands: fitted in 240 × 180.
    static func photoHeight(_ image: NSImage) -> CGFloat {
        guard image.size.width > 0, image.size.height > 0 else { return 0 }
        return min(180, 240 * image.size.height / image.size.width)
    }

    static func bubbleTicks(_ receipt: WAReceipt) -> BubbleTicks {
        switch receipt {
        case .failed: return .failed
        case .pending: return .pending
        case .sent: return .sent
        case .delivered: return .delivered
        case .read: return .read
        }
    }

    static func whatsAppText(_ message: WAMessage) -> String {
        [WhatsAppRecipients.label(message.media), message.text.isEmpty ? nil : message.text]
            .compactMap { $0 }.joined(separator: " ")
    }

    /// What a bubble calls a file that can be opened: a document by its name, anything else by its kind.
    static func whatsAppFileLabel(_ media: WAMedia) -> String? {
        switch media {
        case .document(let name): return name ?? tr("whatsapp.file.document")
        case .image: return tr("whatsapp.file.photo")
        case .video: return tr("whatsapp.file.video")
        case .audio, .voice: return tr("whatsapp.file.voice")
        default: return nil
        }
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
        autocomplete.facts = { [weak self] in
            guard let self, self.settings.useMemory else { return [] }
            return self.memory.items.filter { $0.kind != .lesson && $0.tool == nil }
                .sorted { $0.strength > $1.strength }.prefix(8).map(\.text)
        }
        autocomplete.screenText = { [weak self] bundleID in
            let windows = self?.screenContext.windows.filter { $0.bundleID == bundleID } ?? []
            return (windows.first { $0.isFront } ?? windows.first)?.text
        }
        autocomplete.refresh()
    }

    /// Double Tap: the notch asks what Nook should do, or (when chosen in Settings) the form in front is filled with your
    /// memory and the screen, on the brain you chose. What goes to an
    /// external brain follows the same rules as a question: memories kept on this Mac stay here, and the screen only when
    /// the privacy level allows it.
    func startDoubleTap() {
        let doubleTap = DoubleTap.shared
        doubleTap.ask = { [weak self] system, prompt, timeout in
            await self?.brain.rewrite(system: system, prompt: prompt, timeout: timeout)
        }
        doubleTap.facts = { [weak self] in
            guard let self, self.settings.useMemory, !self.settings.privateSources.contains(SourceCatalog.memory) else { return [] }
            let local = self.settings.isLocalBrain
            return self.memory.items.filter { $0.kind != .lesson && $0.tool == nil && (local || !$0.localOnly) }
                .sorted { $0.strength > $1.strength }.prefix(30).map(\.text)
        }
        doubleTap.screenText = { [weak self] bundleID in
            guard let self, self.settings.liveScreen, !self.settings.privateSources.contains(SourceCatalog.screen) else { return nil }
            let windows = self.screenContext.windows.filter { $0.bundleID == bundleID }
            return ((windows.first { $0.isFront } ?? windows.first)?.text).map(self.settings.shielded)
        }
        doubleTap.present = { [weak self] outcome in self?.presentDoubleTap(outcome) }
        doubleTap.onAsk = { [weak self] in self?.presentTakeoverPrompt() }
        doubleTap.refresh()
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
        viewModel.notify(tr("notes.ready", note.title), button: tr("notes.open")) { [weak self] in self?.showChat() }
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
