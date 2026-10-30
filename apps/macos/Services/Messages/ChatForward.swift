import Foundation

/// A chat message on its way to another chat, the same for every chat app: its file (when Nook has it on this Mac) and
/// its text. Where the other chat takes the file, the text goes with it as its caption (or after it, for a kind without
/// one); a chat that takes no file of that kind cannot get the message, so nothing of it goes there half. Foundation
/// only, so it can be tested anywhere; the Chats tab builds it from a bubble and `AppModel.forwardChatMessage` sends it
/// through each chat's own route.
struct ChatForward: Equatable, Sendable {
    /// The message's text (or a file's caption), trimmed; empty for a file without words.
    var text: String
    /// The message's file on this Mac, with what it is; nil for text alone.
    var file: URL?
    /// What the file is; nil lets its name decide (`ChatMedia.kind`).
    var kind: ChatMedia.Kind?

    /// A message with something to forward: text, a file on this Mac, or both. Nil for an empty one.
    init?(text: String, file: URL? = nil, kind: ChatMedia.Kind? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || file != nil else { return nil }
        self.text = text
        self.file = file
        self.kind = kind
    }

    /// The kinds that carry a caption: their text goes with them instead of after them.
    static let captioned: Set<ChatMedia.Kind> = [.photo, .video, .gif, .file]

    /// What goes to a chat that takes `sends` besides text: the file (with the text as its caption where its kind has one)
    /// and the text still to go after it. Nil when the chat cannot take the file, or it is no longer on this Mac.
    func parts(sends: Set<ChatOutgoing.Kind>) -> (attachment: ChatAttachment?, text: String)? {
        guard let file else { return (nil, text) }
        guard var attachment = ChatAttachment(url: file, as: kind),
              sends.contains(ChatOutgoing.Kind(attachment.kind)) else { return nil }
        guard Self.captioned.contains(attachment.kind), !text.isEmpty else { return (attachment, text) }
        attachment.caption = text
        return (attachment, "")
    }

    /// Whether a chat that takes `sends` can get this message.
    func fits(_ sends: Set<ChatOutgoing.Kind>) -> Bool { parts(sends: sends) != nil }
}
