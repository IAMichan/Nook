import Foundation
import WidgetKit

// What the phone does beyond sessions and chats: pull requests (docs/COMPANION.md, "Pull requests"), snoozing to a moment,
// what other apps share (`ShareQueue`), the share sheet's choices (`ShareTargets`) and the usage widget (`UsageSnapshot`).

extension CompanionClient {
    // MARK: Pull requests

    /// Takes in what an answer says of pull requests: the Mac's list, a session's linked ones, or one in full.
    func takePulls(_ response: CompanionResponse, for request: CompanionRequest) {
        let now = Date()
        var changed = false
        if let list = response.pulls, request.op == .pulls {
            if let session = request.session {
                if linkedPulls[session] != list {
                    linkedPulls[session] = list
                    pullCache.record(linked: list, session: session)
                    changed = true
                }
            } else {
                if pulls != list { pulls = list }
                pullsAt = now
                pullCache.record(list: list, at: now)
                changed = true
            }
        }
        if let detail = response.pull {
            if pullDetails[detail.url] != detail { pullDetails[detail.url] = detail }
            pullCache.record(detail, at: now)
            changed = true
        }
        if changed, let id = activeMacID { PullCacheStore.save(pullCache, mac: id) }
    }

    /// The Mac's pull request list (Agents › Pull requests).
    func loadPulls() async {
        guard can(CompanionFeature.pullRequests) else { return }
        await perform(CompanionRequest(op: .pulls), quiet: true)
    }

    /// The pull requests linked to a session.
    func loadLinkedPulls(_ session: String) async {
        guard can(CompanionFeature.pullRequests) else { return }
        await perform(CompanionRequest(op: .pulls, session: session), quiet: true)
    }

    /// One pull request in full; the cached copy shows meanwhile.
    func loadPull(_ url: String) async {
        guard can(CompanionFeature.pullRequests) else { return }
        await perform(CompanionRequest(op: .pull, item: url), quiet: true)
    }

    /// When the cached copy of a pull request was read, for "as of HH:mm" while the Mac is away.
    func pullReadAt(_ url: String) -> Date? {
        pullCache.detail(url).map { Date(timeIntervalSince1970: $0.at) }
    }

    /// A review, a viewed mark or a merge, through the Mac: never through the outbox, since each means something only
    /// now. True when the Mac did it; the reason is in `notice` otherwise.
    @discardableResult
    func actOnPull(_ url: String, _ action: CompanionPullAction) async -> Bool {
        guard can(CompanionFeature.pullRequests), action.isValid else { return false }
        guard let response = await perform(CompanionRequest(op: .pullAct, item: url, pullAction: action)) else { return false }
        if action.kind == .merge {
            await loadPulls()
            notice = String(localized: "Merged.")
        }
        return response.ok
    }

    /// Starts a session on the Mac that works on this pull request, in a worktree of its own; the new session's id.
    func workOnPull(_ work: PullWorkRequest) async -> String? {
        guard can(CompanionFeature.pullRequests) else { return nil }
        return await perform(CompanionRequest(op: .pullWork, pullWork: work))?.created
    }

    // MARK: Snooze

    /// Snoozes a session until a moment you picked (`SessionAction.snoozeUntil`).
    func snooze(_ session: SessionDigest, until date: Date) async {
        await manage(session, .snoozeUntil, text: CompanionSnooze.text(date))
    }

    // MARK: Shares from other apps

    /// Takes what the share sheet left for the active Mac into its outbox (or says what waited too long), then sends it.
    func takeShares() {
        guard let mac = activeMacID else { return }
        var taken: (ready: [SharedItem], expired: [SharedItem]) = ([], [])
        let paired = Set(macs.map(\.id))
        AppGroup.update(AppGroup.shareQueue, empty: ShareQueue()) { queue in
            queue.keep(macs: paired)
            taken = queue.take(for: mac, now: Date())
        }
        guard !taken.ready.isEmpty || !taken.expired.isEmpty else { return }
        var kept = 0
        for item in taken.ready {
            guard let request = item.request() else { continue }
            if enqueueShared(request, sharedAt: Date(timeIntervalSince1970: item.created)) { kept += 1 }
        }
        if !taken.expired.isEmpty {
            notice = String(localized: "What you shared waited too long for your Mac and was not sent.")
        } else if kept < taken.ready.count {
            notice = String(localized: "Some of what you shared could not wait for your Mac: the queue is full.")
        }
        if kept > 0, phase == .connected { Task { await drainOutbox() } }
    }

    /// What the share sheet may offer for the active Mac, written when it changed.
    func writeShareTargets() {
        guard let mac = activeMacID else { return }
        let targets = ShareTargets(mac: mac, macName: macName, sessions: ShareTargets.sessions(sessions),
                                   launch: launchOptions, canStart: can(CompanionFeature.start) && allows(.operate),
                                   canSend: allows(.operate),
                                   canAsk: can(CompanionFeature.chat) && allows(.nookChat),
                                   canAttach: can(CompanionFeature.attachments) && allows(.operate),
                                   canImages: can(CompanionFeature.images) && allows(.operate), updated: 0)
        guard targets != ShareTargetsCache.last else { return }
        ShareTargetsCache.last = targets
        var stamped = targets
        stamped.updated = Date().timeIntervalSince1970
        AppGroup.write(stamped, AppGroup.shareTargets)
    }

    // MARK: The usage widget

    /// Asks the Mac for the plan limits now and then (at most every ten minutes), for the usage widget.
    func refreshUsage() async {
        guard phase == .connected, can(CompanionFeature.usage), allows(.read) else { return }
        if let asked = usageAskedAt, Date().timeIntervalSince(asked) < 600 { return }
        usageAskedAt = Date()
        await perform(CompanionRequest(op: .usage, item: "today"), quiet: true)
    }

    /// The limits the Mac reported, kept for the widget, which is told to look again only when they changed.
    func keepUsage(_ accounts: [UsageDigest.Account]) {
        let snapshot = UsageSnapshot(macName: macName, accounts: accounts.map { account in
            UsageSnapshot.Account(id: account.id, agent: account.agent, account: account.account,
                                  limits: account.limits.map { .init(label: $0.label, percent: $0.percent, resetsAt: $0.resetsAt) })
        }, taken: Date().timeIntervalSince1970)
        let previous = AppGroup.read(UsageSnapshot.fileName, as: UsageSnapshot.self)
        AppGroup.write(snapshot, UsageSnapshot.fileName)
        // Also once the numbers it shows are an hour old, so it does not turn "as of" while they are current.
        if previous?.accounts != snapshot.accounts || previous?.macName != snapshot.macName
            || snapshot.taken - (previous?.taken ?? 0) > 3600 {
            WidgetCenter.shared.reloadTimelines(ofKind: UsageWidgetKind.kind)
        }
    }

    // MARK: The agent activity widget

    /// The agents the Live Activity follows, kept for the Agent activity widget, which is told to look again when they
    /// changed, or when what it shows is getting old (so it does not read as out of date while the app is open).
    func keepAgentActivity(_ list: [SessionDigest], now: Date) {
        let snapshot = AgentActivitySnapshot(macName: macName, snapshots: list.map { (LiveActivitySnapshot(digest: $0), $0.updated) },
                                             taken: now)
        let previous = AppGroup.read(AgentActivitySnapshot.fileName, as: AgentActivitySnapshot.self)
        let aging = snapshot.taken - (previous?.taken ?? 0) > AgentActivitySnapshot.staleAfter / 2
        guard !snapshot.sameAgents(as: previous) || aging else { return }
        AppGroup.write(snapshot, AgentActivitySnapshot.fileName)
        WidgetCenter.shared.reloadTimelines(ofKind: AgentActivityWidgetKind.kind)
    }

    // MARK: Older sessions and search

    /// A session by its id: from the live list, else from the older ones or a search.
    func session(_ id: String) -> SessionDigest? {
        sessions.first { $0.id == id } ?? olderSessions.first { $0.id == id } ?? foundSessions.first { $0.id == id }
    }

    /// The next page of sessions older than the live list (`CompanionOp.history`).
    func loadOlderSessions() async {
        guard can(CompanionFeature.history), !olderEnded else { return }
        let cursor = olderCursor
        guard let response = await perform(CompanionRequest(op: .history, item: cursor), quiet: true),
              cursor == olderCursor else { return }
        olderSessions = CompanionHistory.merge(live: sessions, older: olderSessions + (response.sessions ?? []))
        olderCursor = response.cursor
        olderEnded = response.cursor == nil
    }

    /// Sessions on the Mac that match `query`, the older ones included (`CompanionOp.history` with words); `more` asks
    /// for the next page of the same search. Words that changed meanwhile win: an answer to older words is dropped.
    func searchSessions(_ query: String, more: Bool = false) async {
        let words = CompanionHistory.clean(query)
        guard can(CompanionFeature.history), !words.isEmpty else {
            foundSessions = []
            foundCursor = nil
            foundQuery = ""
            return
        }
        if more, words != foundQuery || foundCursor == nil { return }
        let cursor = more ? foundCursor : nil
        guard let response = await perform(CompanionRequest(op: .history, item: cursor, text: words), quiet: true),
              !Task.isCancelled, more ? words == foundQuery : true else { return }
        foundSessions = (more ? foundSessions : []) + (response.sessions ?? [])
        foundCursor = response.cursor
        foundQuery = words
    }

    // MARK: File previews

    /// A file of a session's folder on the phone, fetched in pieces (`CompanionOp.fileData`), to open with Quick Look:
    /// its place in the app's temporary folder, or nil when it could not be fetched. `progress` hears 0…1 as it comes.
    /// Only the last preview is kept; the system clears the folder too.
    func fetchFile(_ sessionID: String, path: String, progress: (Double) -> Void) async -> URL? {
        guard can(CompanionFeature.filePreview) else { return nil }
        var assembly = FileAssembly()
        repeat {
            guard !Task.isCancelled,
                  let chunk = await perform(CompanionRequest(op: .fileData, session: sessionID, item: path,
                                                             text: String(assembly.nextOffset)), quiet: true)?.fileChunk,
                  chunk.path == path, (try? assembly.take(chunk)) != nil else { return nil }
            progress(assembly.total.map { $0 == 0 ? 1 : Double(assembly.nextOffset) / Double($0) } ?? 0)
        } while !assembly.complete
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Previews", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        let name = path.split(separator: "/").last.map(String.init) ?? "file"
        let url = folder.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try assembly.data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            return nil
        }
    }
}

/// The last share targets written, so an unchanged list is not written again with every update of the sessions.
@MainActor
enum ShareTargetsCache {
    static var last: ShareTargets?
}
