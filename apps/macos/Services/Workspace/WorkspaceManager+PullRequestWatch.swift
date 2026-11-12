import Foundation

/// Pull requests a session watches: their host's change feed (one per pull request, shared by every session watching
/// it) and a look every half minute; what changed reaches the agent as news. Also the pull request a turn just made.
extension WorkspaceManager {
    /// Watches this pull request for the session: CI, reviews, comments and the merge become news in the timeline, and
    /// what the agent can act on goes to it as a message.
    /// A session watches any number of them; nil ends every watch of the session.
    func watchPullRequest(_ id: UUID, url: URL?, wakeAgent: Bool = true) {
        guard let url else {
            update(id) {
                $0.prWatch = nil
                $0.extraPRWatches = nil
            }
            followPullRequestFeeds()
            return
        }
        guard !isWatching(id, url: url) else { return }
        update(id) { run in
            let watch = PullRequestWatch(url: url.absoluteString, wakeAgent: wakeAgent)
            if run.prWatch == nil { run.prWatch = watch } else { run.extraPRWatches = (run.extraPRWatches ?? []) + [watch] }
        }
        checkPullRequestWatches(force: true)
    }

    func isWatching(_ id: UUID, url: URL) -> Bool {
        run(id)?.prWatches.contains { $0.url == url.absoluteString } ?? false
    }

    /// A watch on a pull request that merged or closed moves to the newer open one the session opened from the same branch
    /// (see `PullRequestWatch.carried`), keeping whether news wakes the agent.
    func carryFinishedWatch(_ id: UUID, links: [PullRequestLink]) {
        guard let run = run(id), let carry = PullRequestWatch.carried(run.prWatches, links: links),
              let old = URL(string: carry.from.url) else { return }
        stopWatchingPullRequest(id, url: old)
        watchPullRequest(id, url: carry.to, wakeAgent: carry.from.wakeAgent)
    }

    /// Ends the watch on one pull request; the next one takes the tray's place.
    func stopWatchingPullRequest(_ id: UUID, url: URL) {
        update(id) { run in
            var rest = run.prWatches.filter { $0.url != url.absoluteString }
            run.prWatch = rest.isEmpty ? nil : rest.removeFirst()
            run.extraPRWatches = rest.isEmpty ? nil : rest
        }
        // Its host change feed ends with the last watch on it; the subscription is deleted.
        followPullRequestFeeds()
    }

    /// Looks at each watched pull request at most every two minutes, stretched by the energy plan. A watch that wakes its
    /// agent keeps going while nobody is at the Mac (the agent answers a review or a failed check by itself), only slower;
    /// one that only updates a badge waits until someone is back. Host change feeds start and stop here too.
    func checkPullRequestWatches(force: Bool = false) {
        guard pullRequestSnapshot != nil else { return }
        let now = Date()
        let energy = EnergyMonitor.shared
        let gap = 120 * energy.plan.slowdown
        for run in runs {
            guard !run.archived else { continue }
            for watch in run.prWatches {
                guard force || watch.wakeAgent || !energy.signals.idle,
                      force || watch.checkedAt.map({ now.timeIntervalSince($0) >= gap || $0 > now }) ?? true else { continue }
                checkPullRequestWatch(run.id, url: watch.url, recheck: false)
            }
        }
        followPullRequestFeeds()
    }

    /// Reads every watch on the pull request at `url` now: its host just said it changed.
    func checkPullRequestWatches(url: String) {
        for run in runs where !run.archived && run.prWatches.contains(where: { $0.url == url }) {
            checkPullRequestWatch(run.id, url: url, recheck: true)
        }
    }

    /// Reads one watched pull request and turns what changed into news. With `recheck` (the host reported a change), a
    /// read already under way is followed by one more, so the change is not missed; the sweep just skips it.
    func checkPullRequestWatch(_ id: UUID, url link: String, recheck: Bool) {
        guard let fetch = pullRequestSnapshot, let watch = run(id)?.prWatches.first(where: { $0.url == link }),
              watch.state == "open", let url = URL(string: link) else { return }
        let key = id.uuidString + " " + link
        guard !pullRequestWatcher.inFlight.contains(key) else {
            if recheck { pullRequestWatcher.rechecks.insert(key) }
            return
        }
        pullRequestWatcher.inFlight.insert(key)
        Task { [weak self] in
            let snapshot = await fetch(url)
            guard let self else { return }
            self.pullRequestWatcher.inFlight.remove(key)
            if let snapshot, let current = self.run(id)?.prWatches.first(where: { $0.url == link }) {
                self.pullRequestChanged(id, old: current, new: snapshot)
            }
            if self.pullRequestWatcher.rechecks.remove(key) != nil { self.checkPullRequestWatch(id, url: link, recheck: false) }
        }
    }

    /// Keeps one host change feed per open watched pull request that the sweep would read now: none while the energy plan
    /// pauses background work, and none for a watch that only updates a badge while nobody is at the Mac. A feed that
    /// ended by itself waits a sweep (two minutes) before it is asked for again.
    func followPullRequestFeeds() {
        guard let events = pullRequestEvents else { return }
        let now = Date()
        let energy = EnergyMonitor.shared
        var wanted = Set<String>()
        if energy.plan.pace != .paused {
            for run in runs where !run.archived {
                for watch in run.prWatches where watch.state == "open" && (watch.wakeAgent || !energy.signals.idle) {
                    wanted.insert(watch.url)
                }
            }
        }
        for (url, feed) in pullRequestWatcher.feeds where !wanted.contains(url) {
            feed.cancel()
            pullRequestWatcher.feeds[url] = nil
        }
        pullRequestWatcher.feedEnded = pullRequestWatcher.feedEnded.filter { wanted.contains($0.key) && now.timeIntervalSince($0.value) < 120 }
        for url in wanted where pullRequestWatcher.feeds[url] == nil && pullRequestWatcher.feedEnded[url] == nil {
            // No feed for this host or account: asked again a sweep later, not every half minute.
            guard let link = URL(string: url), let changes = events(link) else {
                pullRequestWatcher.feedEnded[url] = now
                continue
            }
            pullRequestWatcher.feeds[url] = Task { [weak self] in
                for await _ in changes {
                    guard !Task.isCancelled else { break }
                    self?.checkPullRequestWatches(url: url)
                }
                guard !Task.isCancelled, let self else { return }
                self.pullRequestWatcher.feeds[url] = nil
                self.pullRequestWatcher.feedEnded[url] = Date()
            }
        }
    }

    func pullRequestChanged(_ id: UUID, old: PullRequestWatch, new: PullRequestSnapshot) {
        let now = Date()
        if let url = URL(string: old.url) { PullRequestStatusStore.shared.record(url: url, snapshot: new, at: now) }
        // The first look only sets what counts as seen, but for a conflict that is already there.
        let first = old.checkedAt == nil
        let news = first ? PullRequestNews.firstLook(new) : PullRequestNews.lines(old: old, new: new)
        let lines = news.map(\.text)
        let wake = old.wakeAgent && (first ? !lines.isEmpty : PullRequestNews.needsAgent(old: old, new: new))
        update(id) { run in
            let updated = PullRequestNews.updated(old, with: new, at: now)
            if run.prWatch?.url == old.url {
                run.prWatch = updated
            } else {
                run.extraPRWatches = run.extraPRWatches?.map { $0.url == old.url ? updated : $0 }
            }
        }
        settleQueuedNews(id, url: old.url, with: new)
        // A merged or closed pull request has nothing more to report: its change feed ends.
        if new.state != "open" { followPullRequestFeeds() }
        guard !lines.isEmpty else { return }
        append(id, RunEvent(kind: .system, text: tr("ws.prwatch.news") + "\n" + lines.joined(separator: "\n"), tool: "prwatch"))
        guard wake, let run = run(id) else { return }
        let message = PullRequestNews.message(url: old.url, lines: lines)
        // The news line above already shows it: the agent gets it without a bubble of yours.
        if run.canContinue && processes[id] == nil {
            sendHidden(id, text: message)
        } else {
            enqueue(id, text: message, pullRequest: PullRequestNotice(url: old.url, lines: news))
        }
    }

    /// Waiting news about this pull request that is out of date leaves the queue.
    func settleQueuedNews(_ id: UUID, url: String, with snapshot: PullRequestSnapshot) {
        guard var queue = queued[id] else { return }
        queue.settleNews(url: url, with: snapshot)
        if queue != queued[id] { store(queue, for: id) }
    }

    /// At the end of a turn: a pull request link the turn brought that the conversation did not have before is the one
    /// the agent just made, also when it used its own `gh` instead of pull_request_create.
    func noticeCreatedPullRequest(_ id: UUID) {
        guard let all = events[id], let made = RunPullRequestLinks.created(in: all, before: &pullRequestWatcher.beforeTurn[id]) else { return }
        pullRequestCreated?(id, made)
        watchCreatedPullRequest(id, url: made)
    }

    /// A pull request the session just opened is watched from the start, unless Settings says you follow them yourself
    /// (`WorkspaceSettings.watchNewPullRequests`). Covers the git button's and the agent's own (pull_request_create, `gh`).
    func watchCreatedPullRequest(_ id: UUID, url: URL) {
        guard settings.watchNewPullRequests, PullRequestWatch.canWatch(url), !isWatching(id, url: url) else { return }
        watchPullRequest(id, url: url)
    }
}

/// What `WorkspaceManager+PullRequestWatch` keeps between looks.
struct PullRequestWatcher {
    /// Watches being read now, by link.
    var inFlight: Set<String> = []
    /// Watches whose host reported a change while they were being read: read once more when that read is done.
    var rechecks: Set<String> = []
    /// One change feed per watched pull request (by its link), shared by every session watching it.
    var feeds: [String: Task<Void, Never>] = [:]
    /// When a feed ended by itself (GitHub refused it, or it kept failing): it starts again a sweep later at the earliest.
    var feedEnded: [String: Date] = [:]
    /// The last pull request link before each session's current turn, as the end of its last turn with one found it
    /// (`RunPullRequestLinks.created`), so a turn's end reads that turn and not the whole conversation again.
    var beforeTurn: [UUID: RunPullRequestLinks.BeforeTurn] = [:]

    /// A deleted session's own entry; the watches and feeds are per pull request and end with their last watcher.
    mutating func forget(_ id: UUID) {
        beforeTurn[id] = nil
    }
}
