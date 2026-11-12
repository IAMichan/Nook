import Foundation

// Session commands that may arrive more than once or late (`SessionCommandReceipts`): the phone's Stop, its messages and
// steers, its decisions and answers, and the sessions it starts. A repeated command id gets its first outcome and does
// nothing; a Stop or a steer meant for a turn that has ended leaves the turn that runs now alone.
extension WorkspaceManager {
    /// The turn that runs now, as a sender sees it (`SessionDigest.turn`); nil while none runs.
    func turnIdentity(_ id: UUID) -> String? {
        turns[id]?.identity
    }

    /// What a command did the first time, when it came before.
    func commandReceipt(_ command: SessionCommand?) -> SessionCommandReceipts.Receipt? {
        command.flatMap { commandReceipts.receipt($0.id) }
    }

    /// Keeps what a command did, also when it did nothing, so a repeat of it does nothing either.
    func recordCommand(_ command: SessionCommand?, _ outcome: SessionCommandOutcome, created: String? = nil) {
        guard let command else { return }
        commandReceipts.record(command.id, outcome, created: created)
        let data = commandReceipts.encoded()
        let url = commandReceiptsURL
        Self.receiptWrites.async { SessionCommandReceipts.save(data, to: url) }
    }

    /// One write after another, off the main thread: a few kilobytes on a tap on the phone.
    private static let receiptWrites = DispatchQueue(label: "nook.command-receipts", qos: .utility)

    /// Stops the session's turn, once per command, and only the turn the command was meant for: a Stop the sender issued
    /// while turn A ran never stops turn B that started after it (a queued message, a retry that came late).
    @discardableResult
    func stop(_ id: UUID, command: SessionCommand?) -> SessionCommandOutcome {
        if let earlier = commandReceipt(command) { return earlier.outcome }
        let outcome: SessionCommandOutcome
        if SessionTurnCheck.applies(issuedFor: command?.turn, current: turnIdentity(id)) {
            stop(id)
            outcome = .stopped
        } else {
            outcome = .stale
        }
        recordCommand(command, outcome)
        return outcome
    }

    /// A message for the session, once per command: sent when it rests, into the running turn when `steer` asks for it
    /// and that turn is still the one the sender saw and can take it, else in line for after the turn.
    @discardableResult
    func message(_ id: UUID, text: String, steer: Bool, command: SessionCommand?) -> SessionCommandOutcome {
        if let earlier = commandReceipt(command) { return earlier.outcome }
        let outcome: SessionCommandOutcome
        guard let run = run(id) else { return .stale }
        if !run.status.isActive || startsFreshConversation(id, text: text) {
            outcome = submit(id, text: text, fromYou: true) ? .sent : .queued
        } else if steer, SessionTurnCheck.applies(issuedFor: command?.turn, current: turnIdentity(id)), canSteer(id),
                  self.steer(id, text: text) {
            outcome = .steered
        } else {
            enqueue(id, text: text)
            outcome = .queued
        }
        recordCommand(command, outcome)
        return outcome
    }
}
