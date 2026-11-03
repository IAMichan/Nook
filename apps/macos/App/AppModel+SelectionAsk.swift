import Foundation

/// Asking Nook about words selected anywhere in Nook (`SelectionAsk`): the question becomes a conversation of its own,
/// answered through the same pipeline as the chat (`ask`), while the chat on screen stays as it is.
extension AppModel {
    /// Starts the conversation for a selection and returns it; nil when no brain is set up yet (the setup card shows).
    @discardableResult
    func askAboutSelection(_ selection: String, mode: SelectionAsk.Mode) -> UUID? {
        guard settings.brainReady else {
            presentSetupCard()
            return nil
        }
        NookPresence.shared.heard()
        let conversation = chat.startInBackground()
        ask(SelectionAsk.message(selection, mode: mode), in: conversation, reveal: false, note: SelectionAsk.note,
            selfContained: true)
        return conversation
    }

    /// A follow-up typed in the card: it waits in line while Nook is still answering, as in the chat.
    func followUpOnSelection(_ text: String, in conversation: UUID) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, chat.conversation(conversation) != nil else { return }
        if chat.isBusy(conversation) {
            chat.enqueue(request, conversation: conversation)
            return
        }
        ask(request, in: conversation, reveal: false, note: SelectionAsk.note, selfContained: true)
    }

    /// The card's conversation in the Nook chat, to go on there.
    func continueSelectionInChat(_ conversation: UUID) {
        guard chat.conversation(conversation) != nil else { return }
        openConversation(conversation)
    }
}
