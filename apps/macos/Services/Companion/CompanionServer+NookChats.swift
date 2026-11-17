import AppKit
import Foundation

/// The Nook tab on the phone does what the Mac's does (`CompanionFeature.nookChats`, `CompanionNookChats.swift`): the
/// list with its flags, a search and the archive, and the conversation menu, through the same `NookChat` and `AppModel`
/// calls as the Mac's Nook tab. Always after your own tap on the phone; each action is logged as coming from the phone.
extension CompanionServer {
    /// One conversation as the phone's list shows it, with the flags the Mac's list sorts and groups by.
    func nookDigest(_ conversation: Conversation) -> ChatDigest {
        var digest = ChatDigest(id: conversation.id.uuidString, title: CompanionPolicy.excerpt(conversation.title),
                   updated: conversation.updated.timeIntervalSince1970, busy: conversation.busy,
                   waiting: conversation.status == .waiting, preview: CompanionPolicy.clip(conversation.preview, limit: 200),
                   pinned: conversation.pinned, archived: conversation.archived, unread: conversation.unread,
                   created: conversation.created.timeIntervalSince1970, scheduled: conversation.isScheduledRun,
                   queued: conversation.queue.isEmpty ? nil
                       : conversation.queue.messages.prefix(NookChatSections.maxQueued).map { CompanionPolicy.clip($0.text, limit: 300) })
        digest.suggestion = Self.suggestion("nook:" + conversation.id.uuidString)
        return digest
    }

    /// How many conversations wait in the archive, for the shelf at the foot of the list.
    func archivedConversations(_ app: AppModel) -> Int {
        app.chat.count(query: "", showArchived: true)
    }

    /// The pictures of an `ask` as the Mac's composer holds them; none for none, nil when one is not a picture the phone
    /// may send.
    func phoneImages(_ images: [CompanionImage]?) -> [ImageAttachment]? {
        guard let images, !images.isEmpty else { return [] }
        guard images.count <= CompanionImage.maxCount else { return nil }
        var attachments: [ImageAttachment] = []
        for (index, image) in images.enumerated() {
            // As the composer takes a pasted picture: scaled to what a model needs.
            guard let data = image.data, let picture = NSImage(data: data),
                  let attachment = ImageAttachment(image: picture, name: "phone-\(index + 1).jpg") else { return nil }
            attachments.append(attachment)
        }
        return attachments
    }

    /// An action on one conversation (`CompanionOp.chatAct`): answered with the list as it is after it, and with the
    /// conversation's messages while it still exists.
    func chatAct(_ request: CompanionRequest, app: AppModel) -> CompanionResponse {
        guard let id = request.conversation.flatMap(UUID.init(uuidString:)), let conversation = app.chat.conversation(id) else {
            return .failure(request.id, .unknownSession)
        }
        guard let action = request.nookAction, action.isComplete else { return .failure(request.id, .badRequest) }
        // As on the Mac: a conversation Nook still writes in is not archived, deleted or asked again.
        if action.needsIdle, conversation.busy { return .failure(request.id, .busy) }
        switch action.kind {
        case .rename: app.chat.rename(id, to: action.text ?? "")
        case .pin: app.chat.setPinned(action.value == true, [id])
        case .archive: app.chat.setArchived(action.value == true, id)
        case .delete: app.chat.delete(id)
        case .markUnread: app.chat.setUnread(action.value == true, [id])
        case .retry:
            guard app.settings.brainReady else { return .failure(request.id, .failed, message: "nobrain") }
            guard let question = app.chat.lastQuestion(in: id) else { return .failure(request.id, .unknownItem) }
            app.ask(question, in: id, reveal: false)
        }
        audit("nook_" + action.kind.rawValue, conversation.title)
        var response = chats(request, app: app)
        response.messages = app.chat.conversation(id).map(lines)
        return response
    }

    /// The conversations whose title or last answer hold the words (`CompanionOp.chatSearch`), as the Mac's search finds
    /// them; with `allow` true in the archive instead. Empty words list the archive (or the open list) whole.
    func chatSearch(_ request: CompanionRequest, app: AppModel) -> CompanionResponse {
        let words = String((request.text ?? "").prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
        let found = app.chat.list(query: words, showArchived: request.allow == true).prefix(100).map(nookDigest)
        var response = CompanionResponse(id: request.id, ok: true)
        response.conversationsFound = Array(found)
        response.conversationsArchived = archivedConversations(app)
        return response
    }
}
