import Combine
import Foundation

/// Keeps the session list tidy whether or not a list is on screen: the auto-settle rules
/// (`AutoSettlePolicy`, per machine) and the pull request sync of every session's branch (`PullRequestSync`). Both used
/// to run only while the Agents list was drawn, so with the main window closed or the notch off nothing settled and no
/// pull request was found. Nook cannot settle while it is closed, so its first round runs just after launch and catches
/// up on what came due in the meantime: a merged pull request, a week of quiet.
@MainActor
final class SessionTidier {
    static let shared = SessionTidier()

    /// The rounds: soon after launch, so what came due while Nook was closed settles before you look; then as often as
    /// the list's own clock ticked.
    static let firstRound: TimeInterval = 5
    static let interval: TimeInterval = 30

    private weak var app: AppModel?
    private var loop: Task<Void, Never>?
    private var landed: AnyCancellable?

    func start(app: AppModel) {
        self.app = app
        let store = InboxStore.shared
        // What only the workspace can do for the list: undo a snooze or an archive, end a hanging turn, tidy up after
        // a settle. Set here once, not when a list first appears, so an auto-settle without a list does the same.
        store.undoSnooze = { [weak app] ids in
            for id in ids { if let uuid = Self.runID(id) { app?.workspace.unsnooze(uuid) } }
        }
        store.undoArchive = { [weak app] ids in
            for id in ids { if let uuid = Self.runID(id) { app?.workspace.setArchived(uuid, false) } }
        }
        // Only sessions Nook sees through hooks; the ones it runs itself ("run:…") end their own turns.
        store.settleBusy = { [weak app] ids in
            for id in ids where !id.hasPrefix("run:") { app?.hub.settleByUser(id) }
        }
        store.settled = { [weak app] items in app?.applySettleActions(items) }
        guard loop == nil else { return }
        // A pull request that merged or closed (seen by the branch sync, a watch, the page, or a merge from Nook) settles
        // its session at once, as its badge turns, not at the next round.
        landed = PullRequestStatusStore.shared.$statuses
            .map { statuses in Set(statuses.filter { $0.value.glyph == .merged || $0.value.glyph == .closed }.keys) }
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.settleNow() } }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.firstRound))
            while !Task.isCancelled {
                self?.round()
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    /// One round: follow the pull requests of every session's branch, then settle what the rules say is done.
    func round(now: Date = Date()) {
        guard let app, !app.demoMode else { return }
        let entries = app.agentListEntries(selected: app.viewModel.selectedAgentID)
        let items = entries.running + entries.earlier
        PullRequestSync.shared.follow(workspace: app.workspace, folders: Self.folders(items, now: now), now: now)
        autoSettle(items, workspace: app.workspace, now: now)
    }

    /// Only the settle rules, without asking the forges again: for a pull request that just landed.
    func settleNow(now: Date = Date()) {
        guard let app, !app.demoMode else { return }
        let entries = app.agentListEntries(selected: app.viewModel.selectedAgentID)
        autoSettle(entries.running + entries.earlier, workspace: app.workspace, now: now)
    }

    private func autoSettle(_ items: [AgentListItem], workspace: WorkspaceManager, now: Date) {
        let store = InboxStore.shared
        let finished = FinishedSessions.shared
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = items.map { InboxRow($0, store: store, finished: finished, workspace: workspace) }
        let ids = store.autoSettleCandidates(rows: rows, pullRequest: { id in
            Self.runID(id).map { run in PullRequestSync.shared.autoSettleState(run, since: workspace.lastWrittenAt(run)) } ?? .none
        }, now: now)
        let settle = ids.compactMap { byID[$0] }
        guard !settle.isEmpty else { return }
        store.settle(settle, now: now, record: false, automatically: true)
        // As a settle of yours: a few seconds to take it back (⌘Z); after that Reopen on the Settled shelf brings it back,
        // and it then stays until it has new activity.
        store.note(.autoSettled, ids: settle.map(\.finishKey), now: now)
    }

    /// Folder and branch of every agent Nook did not start, for `PullRequestSync`: the ones running now and the earlier
    /// ones of the last three days (older ones keep the state they had).
    static func folders(_ items: [AgentListItem], now: Date) -> [PullRequestSync.Folder] {
        let recent = now.addingTimeInterval(-3 * 24 * 3600)
        return items.compactMap { item in
            guard runID(item.id) == nil, let branch = item.branch else { return nil }
            if item.id.hasPrefix("past:"), (item.started ?? .distantPast) <= recent { return nil }
            return PullRequestSync.Folder(path: item.path, branch: branch, busy: item.isBusy, quietSince: item.started)
        }
    }

    private static func runID(_ id: String) -> UUID? {
        id.hasPrefix("run:") ? UUID(uuidString: String(id.dropFirst(4))) : nil
    }
}
