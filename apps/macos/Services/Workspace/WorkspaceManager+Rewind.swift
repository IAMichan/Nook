import Foundation

/// Rewind: going back to before a message of yours, with the files and the conversation, the files only, or the
/// conversation only (`RewindScope`). The choices come from `RewindPlan`; the work is done by `revertFiles` and
/// `editFromHere` (WorkspaceManager+Rollback).
extension WorkspaceManager {
    /// The ways back to before a message, the fullest first; empty when the session cannot go back there.
    func rewindScopes(_ id: UUID, before date: Date) -> [RewindScope] {
        RewindPlan.scopes(canRestoreFiles: canRevert(id, before: date), canRollBackConversation: canEditFromHere(id, before: date))
    }

    /// Goes back to before a message of yours the way you chose. Throws when that way is not open (any more).
    func rewind(_ id: UUID, before date: Date, scope: RewindScope) async throws {
        guard rewindScopes(id, before: date).contains(scope) else { throw StartError.git(tr("ws.edit.unavailable")) }
        switch scope {
        case .everything:
            try await revertFiles(id, before: date)
        case .files:
            try await revertFiles(id, before: date, rollingBackConversation: false)
        case .conversation:
            try await editFromHere(id, before: date, revertingFiles: false)
        }
    }

    /// After only the files went back: your next message tells the agent, so it does not build on what is gone.
    func noteFilesRestored(_ id: UUID, before date: Date) {
        let message = timeline(id).first { $0.kind == .user && $0.date >= date }?.text ?? ""
        update(id) { $0.filesRestoredNote = RewindPlan.note(before: message) }
    }

    /// Your message with the note about restored files in its hidden part, once.
    func withRewindNote(_ id: UUID, _ text: String) -> String {
        guard let note = run(id)?.filesRestoredNote, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        update(id) { $0.filesRestoredNote = nil }
        return RewindPlan.attach(note, to: text)
    }
}
