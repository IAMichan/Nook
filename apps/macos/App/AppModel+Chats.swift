// The Chats tab: every chat app in one inbox.
import SwiftUI

/// Chats from WhatsApp (through the linked phone) and from every other chat app on this Mac (collected from their
/// notifications by `ChatCaptureService`) in one list. WhatsApp chats can be answered right there, as in their card;
/// the others open in their own app, since Nook cannot write in them.
extension AppModel {
    func startChats() {
        // A linked phone brings WhatsApp in live, your own messages included: its notifications would only repeat it.
        ChatCaptureService.shared.skips = { notice in notice.app == "whatsapp" && WhatsAppLink.shared.isConnected }
        ChatCaptureService.shared.onFresh = { [weak self] ids in ids.forEach { self?.presentCapturedChat($0) } }
        ChatCaptureService.shared.start()
    }

    /// Someone wrote in a chat of another app (Telegram, Messages, Slack…): kept in the notice history, and shown the way
    /// Settings › Notifications says for chats when that app is switched on there (by default only WhatsApp is, since
    /// the other apps show their own macOS notifications already). Nook cannot write in these apps: the card opens the
    /// chat in the Chats tab or in its own app.
    func presentCapturedChat(_ id: String) {
        let capture = ChatCaptureService.shared
        guard let thread = capture.inbox.threads[id], let last = thread.messages.last(where: { !$0.isMine }) else { return }
        let appName = MessagingApps.app(id: thread.app)?.name ?? thread.app
        let line = (thread.isGroup && !last.sender.isEmpty ? last.sender + ": " : "") + last.summary
        let token = Self.chatCardPrefix + id
        logNotice(.info, title: thread.name, detail: line, context: appName, target: .chat(id), key: token,
                  source: .chats, app: thread.app)
        let open: () -> Void = { [weak self] in self?.showChats(ChatsFocus(chat: id)) }
        deliverNotice(.chats, app: thread.app, id: token, title: thread.name, subtitle: appName, body: line,
                      card: { [weak self] in self?.showCapturedChatCard(id) },
                      strip: { [weak self] in
                          self?.viewModel.notify(thread.name + ": " + line, button: tr("notices.openChat"), action: open)
                      },
                      open: open)
    }

    static let chatCardPrefix = "chatnotice-"

    /// Return in the field of another app's chat card: Nook cannot write there, so the text goes on the clipboard and
    /// the app opens to paste it, as in the Chats tab.
    func copyCardReply(_ text: String, card: NookCard) {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty, ChatDraft.instruction(in: reply) == nil,
              let thread = ChatCaptureService.shared.inbox.threads[String(card.id.dropFirst(Self.chatCardPrefix.count))]
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reply, forType: .string)
        viewModel.dismissCard(id: card.id)
        openChatApp(thread.app)
        viewModel.finish(tr("chats.reply.copied", card.replyCopiesTo ?? thread.app))
    }

    /// The card of a chat from another app: its newest messages, Open (in the Chats tab), the app itself, and the same
    /// answer field as the Chats tab ("@nook …" lets Nook write it; what you send is copied for the app).
    private func showCapturedChatCard(_ id: String) {
        guard let thread = ChatCaptureService.shared.inbox.threads[id] else { return }
        let token = Self.chatCardPrefix + id
        let appName = MessagingApps.app(id: thread.app)?.name ?? thread.app
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        let bubbles = thread.messages.suffix(8).map { ChatBubble($0, time: time.string(from: $0.date)) }
        viewModel.register("\(token)#open") { [weak self] in self?.showChats(ChatsFocus(chat: id)) }
        viewModel.register("\(token)#app") { [weak self] in self?.openChatApp(thread.app) }
        let unread = thread.unread > 1 ? " · \(tr("whatsapp.card.unread", thread.unread))" : ""
        let card = NookCard(
            id: token,
            mood: .remind,
            context: appName + unread,
            appIcon: thread.app,
            title: thread.name,
            detail: .chat(bubbles),
            primary: CardAction(label: tr("notices.openChat"), outcome: .callback("\(token)#open", "")),
            secondary: CardAction(label: tr("button.later"), outcome: .dismiss),
            contentHeight: Self.whatsAppCardHeight(bubbles),
            input: true,
            inputPrompt: tr("chats.reply.copyPrompt", thread.name),
            // A new message never takes the keyboard from what you are doing.
            focusesInput: false,
            chatReply: true,
            replyCopiesTo: appName,
            extra: [CardAction(label: tr("notices.openApp", appName), outcome: .callback("\(token)#app", ""),
                               symbol: "arrow.up.forward.app")],
            escape: CardAction(label: "", outcome: .dismiss)
        )
        if viewModel.hasCard(id: token) { viewModel.updateCard(card) } else { viewModel.present(card) }
    }

    /// Opens a chat app: beside the chat in Nook when Nook can show it there (the Mac app, else its web version), else
    /// the Mac app in its own window.
    func openChatApp(_ appID: String) {
        if let app = EmbeddedAppCatalog.find(appID) {
            openEmbeddedApp(app)
            showChat()
            return
        }
        let workspace = NSWorkspace.shared
        guard let url = MessagingApps.app(id: appID)?.bundleIDs.lazy
            .compactMap({ workspace.urlForApplication(withBundleIdentifier: $0) }).first else {
            // No Mac app: a website you added (or a known app's web version) opens in the browser.
            if let source = MessagingApps.app(id: appID), let host = source.domains.first ?? source.site,
               let site = URL(string: "https://" + host) {
                workspace.open(site)
            }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    /// Your answer from the Chats tab to a WhatsApp chat (to one of its messages, when `replyTo` is set): your own words
    /// and your own click, as in the chat's card, and logged the same way. Returns the chat's name.
    @discardableResult
    func sendWhatsAppFromChats(_ text: String, chat: String, replyTo: String? = nil) async throws -> String {
        let name = try await WhatsAppLink.shared.send(text, to: chat, replyTo: replyTo)
        store.audit(tool: "whatsapp_send", args: name, result: "verstuurd")
        return name
    }

    /// An emoji on a message of a WhatsApp chat, after your own click in its card or the Chats tab (the same emoji again
    /// takes it back), logged as a send is.
    func reactWhatsApp(_ emoji: String, to message: String, chat: String) async throws {
        let name = try await WhatsAppLink.shared.react(emoji, to: message, chat: chat)
        store.audit(tool: "whatsapp_react", args: "\(name): \(emoji)", result: "verstuurd")
    }

    /// A file in a WhatsApp chat in the Chats tab: fetched from the gateway and shown in Quick Look, else in the app the
    /// Mac uses for it.
    func openWhatsAppFile(_ bubble: ChatBubble, chat: String) async throws {
        let url = try await WhatsAppLink.shared.download(message: bubble.id, chat: chat)
        let shown = FilePreviewWindow.shared.show(url, title: bubble.attachment ?? url.lastPathComponent)
        guard shown || NSWorkspace.shared.open(url) else { throw NookError(tr("whatsapp.file.noApp")) }
    }

    /// "Let Nook answer" for a WhatsApp chat, as on its card: Nook reads only this chat and proposes an answer you approve.
    func askNookAboutWhatsApp(_ chat: String, name: String) {
        ask(tr("whatsapp.card.nookPrompt", name), focus: [Prefetch.Call(tool: "whatsapp_live", input: ["chat": chat, "limit": 20])],
            reflects: false)
    }

    // MARK: From the chat

    /// The Chats tab, on what `focus` asks for.
    func showChats(_ focus: ChatsFocus = ChatsFocus()) {
        viewModel.chatsFocus = focus
        viewModel.show(.panel(.inbox))
    }

    /// The Chats tab's id of the chat with this name: a WhatsApp chat of the linked phone, else a collected one.
    func chatsEntryID(named name: String) -> String? {
        let link = WhatsAppLink.shared
        if link.isConnected, let target = link.resolve(name), link.inbox.conversations[target.jid] != nil {
            return "wa|" + target.jid
        }
        let capture = ChatCaptureService.shared
        guard let thread = capture.inbox.thread(named: name), capture.sources.isOn(thread.app) else { return nil }
        return thread.id
    }

    /// The chats "@chat …" offers, newest first: WhatsApp's (with a linked phone or not), then the ones collected
    /// from the other apps, each with its app and how many are new.
    func chatChoices() -> [(name: String, detail: String)] {
        var choices = WhatsAppLink.shared.chatChoices()
        let capture = ChatCaptureService.shared
        for thread in capture.inbox.sorted where capture.sources.isOn(thread.app) {
            let app = MessagingApps.app(id: thread.app)?.name ?? thread.app
            choices.append((thread.name, thread.unread > 0 ? app + " · " + tr("whatsapp.card.unread", thread.unread) : app))
        }
        return choices
    }

    // MARK: Nook writes a message

    /// "@nook …" in a chat's answer field: the message Nook writes from the chat and what you asked. It only goes into the
    /// field; sending stays your own click. Throws with a sentence you can act on.
    func draftChatMessage(app appName: String, chat name: String, transcript: String, instruction: String) async throws -> String {
        guard settings.brainReady else { throw NookError(tr("chats.draft.noBrain")) }
        let prompt = ChatDraft.prompt(app: appName, chat: name, transcript: transcript, instruction: instruction)
        guard let answer = await brain.rewrite(system: ChatDraft.system, prompt: prompt, timeout: 90),
              let message = ChatDraft.clean(answer) else { throw NookError(tr("chats.draft.failed")) }
        return message
    }

    /// "@nook …" in a message card's field: the message Nook writes from the chat the card shows, as the Chats tab does.
    func draftCardReply(_ instruction: String, card: NookCard) async throws -> String {
        guard case .chat(let bubbles) = card.detail else { throw NookError(tr("chats.draft.failed")) }
        let app = card.id.hasPrefix(Self.whatsAppCardPrefix) ? "WhatsApp" : card.replyCopiesTo ?? card.context
        let transcript = ChatBubble.transcript(Array(bubbles.suffix(30)), contact: card.title)
        return try await draftChatMessage(app: app, chat: card.title, transcript: transcript, instruction: instruction)
    }
}
