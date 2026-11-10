import AppKit
import Combine
import SwiftUI

/// What the keys and the command palette do to the session that is open in the Agents tab: pin, settle, stop the turn,
/// open its folder in your editor, copy where it works, rename it. One place, so ⇧⌘P and the palette's Pin do the same
/// as the row's pin. Each returns false when it does not apply (the key then goes on).
///
/// Every coding agent gets the same: sessions Nook runs (`run:`) of any agent can be stopped and renamed through
/// `WorkspaceManager`; sessions Nook only watches through an agent's hooks (and earlier ones read from its history) have
/// no turn Nook can stop and no title of Nook's own, for every agent alike.
@MainActor
struct OpenSessionActions {
    let item: AgentListItem
    let app: AppModel

    private var store: InboxStore { InboxStore.shared }
    private var finished: FinishedSessions { FinishedSessions.shared }

    /// The id of a session Nook runs.
    var runID: UUID? {
        item.id.hasPrefix("run:") ? UUID(uuidString: String(item.id.dropFirst(4))) : nil
    }

    private var isPast: Bool { item.id.hasPrefix("past:") }

    /// As the list counts it: earlier sessions are settled by nature, the others once you (or a rule) settled them.
    var settled: Bool { isPast || (!item.isBusy && finished.contains(item.finishKey)) }
    var pinned: Bool { store.state.pinned.contains(item.id) }

    func togglePin() -> Bool {
        withAnimation(NookTheme.reveal) {
            if pinned {
                store.unpin(item.id)
            } else {
                if settled && !isPast { store.unsettle([item], record: false) }
                store.pin(item.id)
            }
        }
        return true
    }

    /// Settles the session, or brings a settled one back; an earlier session stays settled.
    func toggleSettled() -> Bool {
        if settled {
            guard !isPast else { return false }
            withAnimation(NookTheme.reveal) { store.unsettle([item]) }
        } else {
            withAnimation(NookTheme.reveal) { store.settle([item]) }
        }
        return true
    }

    /// Whether the turn can be stopped now: a session Nook runs that is working.
    var canInterrupt: Bool {
        guard let runID else { return false }
        return app.workspace.run(runID)?.status.isActive == true
    }

    func interrupt() -> Bool {
        guard canInterrupt, let runID else { return false }
        app.workspace.stop(runID)
        return true
    }

    /// The folder on this Mac, for the editor and Finder.
    var localFolder: String? {
        guard item.machine == MachineName.local, !item.path.isEmpty,
              FileManager.default.fileExists(atPath: item.path) else { return nil }
        return item.path
    }

    func openInEditor() -> Bool {
        guard let folder = localFolder else { return false }
        app.workspace.openInEditor(folder)
        return true
    }

    func copyReference() -> Bool {
        guard let text = SessionReference.text(path: item.path, branch: item.branch) else { return false }
        Pasteboard.copy(text)
        ToastCenter.shared.success(tr("keys.copied.reference"), detail: text)
        return true
    }

    func copy(_ text: String) {
        Pasteboard.copy(text)
        ToastCenter.shared.success(tr("keys.copied"), detail: text)
    }

    /// Renaming is for sessions Nook runs: their name is Nook's. The name field opens in the session's header.
    var canRename: Bool { runID != nil }

    func rename() -> Bool {
        guard let runID else { return false }
        SessionRenameRequest.shared.request(runID)
        return true
    }

    var canFork: Bool { runID.map { app.workspace.canTransfer($0) } ?? false }

    /// Forks the session; the fork's list id, to open it.
    func fork() -> String? {
        guard let runID, let forked = app.workspace.fork(runID) else { return nil }
        return "run:" + forked.uuidString
    }

    /// Snoozing is for sessions Nook runs that are not working.
    var canSnooze: Bool { runID != nil && !item.isBusy }

    /// While a usage limit holds the session: when it resets.
    var limitResetsAt: Date? {
        guard let runID, let run = app.workspace.run(runID) else { return nil }
        return SnoozePolicy.limitResetEnd(limitedAt: run.limitedAt, resetAt: run.limitResetAt)
    }

    func snooze(until end: Date) {
        guard let runID else { return }
        withAnimation(NookTheme.reveal) {
            app.workspace.snooze(runID, until: end)
            store.note(.snoozed, ids: [item.id])
        }
    }
}

/// F2 or the palette's Rename asks the open session's header to show its name field (`AgentRunPanel`), also when the
/// session opens only now.
@MainActor
final class SessionRenameRequest: ObservableObject {
    static let shared = SessionRenameRequest()
    @Published private(set) var pending: UUID?

    func request(_ id: UUID) {
        pending = id
    }

    /// The header took the request.
    func take(_ id: UUID) {
        if pending == id { pending = nil }
    }
}
