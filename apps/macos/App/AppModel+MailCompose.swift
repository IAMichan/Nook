// Writing mail from the Chats tab: a new mail, an answer to everyone or a mail forwarded (`MailComposeView`), sent
// through Mail after your own click and logged, and a mail opened in Mail itself.
import AppKit
import Foundation

extension AppModel {
    /// Every address you can send from, per account in Mail, for the From menu of a new mail.
    var mailSenders: [(account: String, address: String)] {
        ChatCaptureService.shared.mailBridge.accounts.flatMap { account in
            account.addresses.map { (account: account.name, address: $0) }
        }
    }

    /// An empty new mail, from the account the open mail chat is in (else Mail's first account).
    func newMailDraft(chatID: String? = nil, to: String = "") -> MailDraft {
        let bridge = ChatCaptureService.shared.mailBridge
        let from = bridge.sender(for: chatID)
        return MailDraft(to: to, cc: "", subject: "", body: "", from: from.isEmpty ? (mailSenders.first?.address ?? "") : from)
    }

    /// A new mail to everyone a mail went to, or that mail forwarded, from what Mail gave of it (`whole`), else from what
    /// the conversation keeps of it.
    func mailDraft(_ action: MailThreadAction, for message: InboxMessage, whole: MailChatData.Message?, contact: String,
                   chatID: String?) -> MailDraft {
        let bridge = ChatCaptureService.shared.mailBridge
        let parts = MailChatData.parts(message.text)
        let mail = whole ?? MailChatData.Message(subject: parts.subject, from: message.senderID ?? contact, date: message.date,
                                                 body: parts.body)
        let compose: MailChatData.Compose
        switch action {
        case .forward:
            compose = MailChatData.forward(mail, date: MailDates.full(mail.date ?? message.date),
                                           labels: (tr("chats.mail.forwarded"), tr("chat.mail.from"), tr("chats.mail.date"),
                                                    tr("chat.mail.subject"), tr("chat.mail.to")))
        default:
            compose = MailChatData.replyAll(to: mail, own: bridge.ownAddresses)
        }
        var draft = newMailDraft(chatID: chatID, to: compose.to)
        draft.cc = compose.cc
        draft.subject = compose.subject
        draft.body = compose.body
        return draft
    }

    /// Sends a mail you wrote in the Chats tab through Mail, after your own click: it is logged, and Mail is read again
    /// so the mail shows in its conversation.
    func sendNewMail(_ draft: MailDraft) async throws {
        try await MailSender.deliver(draft, send: true)
        store.audit(tool: "send_mail", args: "\(draft.to) · \(draft.subject)", result: "verstuurd")
        ChatCaptureService.shared.readSoon(MailChatData.app)
    }

    /// Hands a mail you started in the Chats tab to Mail, open to finish there.
    func openNewMailInMail(_ draft: MailDraft) async throws {
        try await MailSender.deliver(draft, send: false)
    }

    /// Opens one mail in Mail itself, by its message id; a mail Mail did not give (yet), or one from a mail app Nook only
    /// knows by its notifications, opens that app.
    func openMailMessage(_ whole: MailChatData.Message?, app id: String) {
        if let url = whole?.mailURL {
            NSWorkspace.shared.open(url)
        } else {
            openChatApp(id)
        }
    }
}
