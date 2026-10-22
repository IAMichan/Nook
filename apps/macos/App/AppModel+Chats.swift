// The Chats tab: every chat app in one inbox.
import SwiftUI

/// Chats from WhatsApp (through the linked phone) and from every other chat app on this Mac (collected from their
/// notifications by `ChatCaptureService`) in one list. WhatsApp chats can be answered right there, as in their card;
/// the others open in their own app, since Nook cannot write in them.
extension AppModel {
    func startChats() {
        // A linked phone brings WhatsApp in live, your own messages included: its notifications would only repeat it.
        ChatCaptureService.shared.skips = { notice in notice.app == "whatsapp" && WhatsAppLink.shared.isConnected }
        ChatCaptureService.shared.start()
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
        let app = card.id.hasPrefix(Self.whatsAppCardPrefix) ? "WhatsApp" : card.context
        let transcript = ChatBubble.transcript(Array(bubbles.suffix(30)), contact: card.title)
        return try await draftChatMessage(app: app, chat: card.title, transcript: transcript, instruction: instruction)
    }
}
