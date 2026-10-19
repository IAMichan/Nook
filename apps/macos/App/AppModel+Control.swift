import Foundation

/// Mouse and keyboard control from the chat (see `UIDriver`): after an approved batch of steps ran, Nook asks the brain
/// to look at the window again and propose the next batch, in the same conversation, until the goal is reached. Every
/// batch is still a plan the user approves; this only saves typing "go on" in between.
extension AppModel {
    /// Batches in a row Nook continues by itself; after that a button lets the user decide to go on.
    static let controlRounds = 6

    func continueAfterControl(_ messageID: UUID) {
        guard let message = chat.message(messageID), message.actions.contains(where: { $0.tool == UIDriver.controlTool }),
              case .done = message.planState,
              let conversation = chat.conversationID(of: messageID),
              let messages = chat.conversation(conversation)?.messages,
              // Only while the user stays with it: not after they asked something else or opened another chat.
              messages.last?.id == messageID, chat.activeID == conversation, !chat.isBusy(conversation) else { return }
        let prompt = tr("control.continue")
        let rounds = UIControl.rounds(in: messages.filter { $0.role == .user }.map(\.text), marker: prompt)
        guard rounds < Self.controlRounds else {
            chat.update(messageID) { if !$0.offers.contains(prompt) { $0.offers.append(prompt) } }
            return
        }
        ask(prompt)
    }
}
