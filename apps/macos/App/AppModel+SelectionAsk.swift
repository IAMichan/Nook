import Foundation

/// Asking Nook about words selected anywhere in Nook (`SelectionAsk`): the question becomes a conversation of its own,
/// answered through the same pipeline as the chat (`ask`), while the chat on screen stays as it is.
extension AppModel {
    /// Starts the conversation for a selection and returns it; nil when no brain is set up yet (the setup card shows).
    /// `context`: the chat around a selection made in a chat (`TranscriptSelection`).
    @discardableResult
    func askAboutSelection(_ selection: String, mode: SelectionAsk.Mode, context: String? = nil) -> UUID? {
        guard settings.brainReady else {
            presentSetupCard()
            return nil
        }
        NookPresence.shared.heard()
        let conversation = chat.startInBackground()
        ask(SelectionAsk.message(selection, mode: mode), in: conversation, reveal: false, note: selectionNote(context),
            selfContained: true)
        return conversation
    }

    /// A follow-up typed in the card: it waits in line while Nook is still answering, as in the chat.
    func followUpOnSelection(_ text: String, in conversation: UUID, context: String? = nil) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, chat.conversation(conversation) != nil else { return }
        if chat.isBusy(conversation) {
            chat.enqueue(request, conversation: conversation)
            return
        }
        ask(request, in: conversation, reveal: false, note: selectionNote(context), selfContained: true)
    }

    /// The note for the brain, with the chat around the selection as data: filtered as the privacy level asks when it
    /// goes to an external brain, like everything else Nook gathers.
    private func selectionNote(_ context: String?) -> String {
        guard let context, !context.isEmpty else { return SelectionAsk.note }
        return SelectionAsk.note + "\n\n" + UntrustedText.wrap(settings.shielded(context))
    }

    /// The card's conversation in the Nook chat, to go on there.
    func continueSelectionInChat(_ conversation: UUID) {
        guard chat.conversation(conversation) != nil else { return }
        openConversation(conversation)
    }
}
