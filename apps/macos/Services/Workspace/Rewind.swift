import Foundation

/// What going back to before a message of yours takes with it, as you choose under that message.
enum RewindScope: String, CaseIterable, Sendable {
    /// The files go back to the snapshot before the message, and the agent forgets that message and everything after.
    case everything
    /// Only the files go back; the agent still remembers the turns, and is told with your next message.
    case files
    /// Only the conversation goes back; the files stay as they are now.
    case conversation
}

/// Which ways back a message offers, and what the agent is told when only its files went back.
enum RewindPlan {
    /// The choices under a message, the fullest first. `canRestoreFiles`: a snapshot before it can be put back
    /// (`WorkspaceManager.canRevert`). `canRollBackConversation`: the agent can forget the turns since
    /// (`WorkspaceManager.canEditFromHere`, per agent in `ProviderCapabilities.canRollbackConversation`).
    static func scopes(canRestoreFiles: Bool, canRollBackConversation: Bool) -> [RewindScope] {
        var result: [RewindScope] = []
        if canRestoreFiles && canRollBackConversation { result.append(.everything) }
        if canRestoreFiles { result.append(.files) }
        if canRollBackConversation { result.append(.conversation) }
        return result
    }

    /// The record in the hidden part of your next message (`<nook_context>`), so your bubble stays yours.
    static let noteID = "files-restored"

    /// What the agent learns with your next message after its files went back while it still remembers its turns:
    /// otherwise it would build on changes that are no longer on disk.
    static func note(before message: String) -> String {
        let quoted = TextClip.oneLine(ContextRefs.visible(message), 200)
        return "Nook: the user put the files back to how they were before their message \"\(quoted)\". Every change made "
            + "after that message is gone from disk, although you still remember those turns. Read the files again "
            + "before you rely on them, and do not redo the undone changes unless the user asks for them."
    }

    /// `text` with `note` in its hidden context, next to any references and notes already there.
    static func attach(_ note: String, to text: String) -> String {
        ContextRefs.attachMode(noteID, note, to: text)
    }
}

extension ContextRefs {
    /// Adds a `<mode id="…">` record to the hidden `<nook_context>` envelope of `text`, opening one when there is none.
    /// The timeline strips the envelope (`ContextRefs.timeline`), so only the agent reads it.
    static func attachMode(_ id: String, _ note: String, to text: String) -> String {
        let record = "<mode id=\"\(id)\">\n" + escape(note) + "\n</mode>"
        let open = "\n\n<nook_context>\n", close = "\n</nook_context>"
        if let start = text.range(of: open), let end = text.range(of: close, range: start.upperBound..<text.endIndex) {
            var result = text
            result.insert(contentsOf: "\n" + record, at: end.lowerBound)
            return result
        }
        return text + open + record + close
    }
}
