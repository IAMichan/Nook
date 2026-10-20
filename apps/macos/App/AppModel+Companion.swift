// WhatsApp, Flow, the Notetaker, shortcuts, undo and attaching a window.
import SwiftUI
import Combine

/// WhatsApp in the notch: a new message shows as a card with the chat so far (it scrolls back) and a field to answer.
/// What you type there goes to that chat when you press Return or click the arrow (your own words, your own click);
/// a document or photo opens with a click; "Let Nook answer" hands the chat to Nook, who proposes an answer as a plan
/// you approve.
extension AppModel {
    static let whatsAppCardPrefix = "whatsapp-"

    func startWhatsApp() {
        WhatsAppLink.shared.onMessage = { [weak self] chat in self?.presentWhatsApp(chat) }
        WhatsAppLink.shared.start()
    }

    func presentWhatsApp(_ chat: String) {
        let link = WhatsAppLink.shared
        guard WhatsAppSettings.notify, let conversation = link.inbox.conversations[chat],
              conversation.messages.contains(where: { !$0.fromMe }) else { return }
        let token = Self.whatsAppCardPrefix + chat
        viewModel.register("\(token)#read") { link.markRead(chat) }
        viewModel.register("\(token)#nook") { [weak self] in
            guard let self else { return }
            link.markRead(chat)
            // Only this chat is read, and asking for a draft teaches memory nothing about the user.
            self.ask(tr("whatsapp.card.nookPrompt", conversation.name),
                     focus: [Prefetch.Call(tool: "whatsapp_live", input: ["chat": chat, "limit": 20])], reflects: false)
        }
        viewModel.register("\(token)#mute") { link.ignore(chat) }

        // The chat as bubbles, the newest at the bottom; in a group each says who wrote it. A file is a button.
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        let bubbles = conversation.messages.suffix(WAInbox.keep).map { message in
            let file = Self.whatsAppFileLabel(message.media)
            return ChatBubble(id: message.id, text: file == nil ? Self.whatsAppText(message) : message.text,
                              time: time.string(from: message.date),
                              sender: conversation.isGroup && !message.fromMe ? message.senderName : "",
                              fromMe: message.fromMe, attachment: file)
        }
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
            extra: [CardAction(label: tr("whatsapp.card.nook"), outcome: .callback("\(token)#nook", "")),
                    CardAction(label: tr("whatsapp.card.mute"), outcome: .callback("\(token)#mute", ""))],
            escape: CardAction(label: "", outcome: .dismiss)
        )
        if viewModel.hasCard(id: token) { viewModel.updateCard(card) } else { viewModel.present(card) }

        // Older messages from the gateway, once per chat, so the card can scroll back further than what came in.
        Task { @MainActor [weak self] in
            guard await WhatsAppLink.shared.loadHistory(chat), let self, self.viewModel.hasCard(id: token) else { return }
            self.presentWhatsApp(chat)
        }
    }

    /// Return in a WhatsApp card's field: the text goes to that chat as typed. The card says it is sending; when that
    /// fails it says why and puts the text back, so nothing typed is lost.
    func replyWhatsApp(_ text: String, chat: String) {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return }
        let token = Self.whatsAppCardPrefix + chat
        editShownCard(token) { $0.notice = tr("whatsapp.card.sending"); $0.draft = nil }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let name = try await WhatsAppLink.shared.send(reply, to: chat)
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

    /// A click on a file in a card's chat bubble: for WhatsApp, the file is fetched from the gateway and opens in the
    /// app the Mac uses for it. The card stays open and says what happens.
    func openCardAttachment(_ bubble: ChatBubble, card: NookCard) {
        guard card.id.hasPrefix(Self.whatsAppCardPrefix) else { return }
        let chat = String(card.id.dropFirst(Self.whatsAppCardPrefix.count))
        editShownCard(card.id) { $0.notice = tr("whatsapp.file.opening", bubble.attachment ?? "") }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await WhatsAppLink.shared.download(message: bubble.id, chat: chat)
                guard NSWorkspace.shared.open(url) else { throw NookError(tr("whatsapp.file.noApp")) }
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
    /// characters per line and at most 5 lines, a file adds a row; what does not fit in the bubbles' maximum height
    /// scrolls.
    static func whatsAppCardHeight(_ bubbles: [ChatBubble]) -> CGFloat {
        let chrome: CGFloat = 16 + 6 + 24 + 10 + 12 + 48 + 38 + 24
        let stack = bubbles.reduce(CGFloat(0)) { total, bubble in
            let lines = bubble.text.isEmpty ? 0 : min(5, max(1, (bubble.text.count + 47) / 48))
            let file: CGFloat = bubble.attachment == nil ? 0 : 40
            return total + 16 + max(CGFloat(lines) * 18, bubble.attachment == nil ? 18 : 14) + file
                + (bubble.sender.isEmpty ? 0 : 16) + 5
        }
        return chrome + min(stack, 260)
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
