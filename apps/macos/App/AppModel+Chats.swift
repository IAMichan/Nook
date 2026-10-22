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
            .compactMap({ workspace.urlForApplication(withBundleIdentifier: $0) }).first else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    /// Your answer from the Chats tab to a WhatsApp chat: your own words and your own click, as in the chat's card, and
    /// logged the same way. Returns the chat's name.
    @discardableResult
    func sendWhatsAppFromChats(_ text: String, chat: String) async throws -> String {
        let name = try await WhatsAppLink.shared.send(text, to: chat)
        store.audit(tool: "whatsapp_send", args: name, result: "verstuurd")
        return name
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
}
