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
        let target = PullRequestStatusStore.shared.canonicalURL(url)
        guard !isWatching(id, url: target) else { return }
        update(id) { run in
            let watch = PullRequestWatch(url: target.absoluteString, wakeAgent: wakeAgent)
            if run.prWatch == nil { run.prWatch = watch } else { run.extraPRWatches = (run.extraPRWatches ?? []) + [watch] }
        }
        checkPullRequestWatches(force: true)
    }

    func isWatching(_ id: UUID, url: URL) -> Bool {
        let aliases = PullRequestStatusStore.shared.repoAliases
        return run(id).map { SessionBranches.watch(for: url.absoluteString, in: $0.prWatches, aliases: aliases) != nil } ?? false
    }

    /// A watch on a pull request that merged or closed moves to the newer open one the session opened from the same branch
    /// (see `PullRequestWatch.carried`), keeping whether news wakes the agent.
    func carryFinishedWatch(_ id: UUID, links: [PullRequestLink]) {
        let aliases = PullRequestStatusStore.shared.repoAliases
        guard let run = run(id), let carry = PullRequestWatch.carried(run.prWatches, links: links, aliases: aliases),
              let old = URL(string: carry.from.url) else { return }
        stopWatchingPullRequest(id, url: old)
        watchPullRequest(id, url: carry.to, wakeAgent: carry.from.wakeAgent)
    }

    /// Ends the watch on one pull request; the next one takes the tray's place.
    func stopWatchingPullRequest(_ id: UUID, url: URL) {
        let aliases = PullRequestStatusStore.shared.repoAliases
        update(id) { run in
            // The same request under another spelling of its URL (a renamed repository) is the same watch.
            let place = SessionBranches.place(url.absoluteString, aliases: aliases)
            var rest = run.prWatches.filter { $0.url != url.absoluteString && SessionBranches.place($0.url, aliases: aliases) != place }
            run.prWatch = rest.isEmpty ? nil : rest.removeFirst()
            run.extraPRWatches = rest.isEmpty ? nil : rest
        }
        // Its host change feed ends with the last watch on it; the subscription is deleted.
        followPullRequestFeeds()
    }

    /// Collapses any duplicate watches in every run once a repository rename is known, rewriting old URLs to canonical ones.
    func deduplicatePullRequestWatches() {
        let store = PullRequestStatusStore.shared
        let aliases = store.repoAliases
        let canonical: (String) -> String = { raw in
            URL(string: raw).map { store.canonicalURL($0).absoluteString } ?? raw
        }
        var changed = false
        for run in runs where !run.prWatches.isEmpty {
            var deduped = SessionBranches.deduplicatedWatches(run.prWatches, aliases: aliases, canonical: canonical)
            guard deduped != run.prWatches else { continue }
            changed = true
            let first = deduped.isEmpty ? nil : deduped.removeFirst()
            let rest = deduped.isEmpty ? nil : deduped
            update(run.id) {
                $0.prWatch = first
                $0.extraPRWatches = rest
            }
        }
        if changed { followPullRequestFeeds() }
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
                // The forge's hourly limit: less often as it runs low, not at all under the reserve.
                let page = URL(string: watch.url)
                let watchGap = gap * ForgeRateBudget.shared.slowdown(forPage: page, orGraphQL: true)
                guard force || ForgeRateBudget.shared.allowsBackground(forPage: page, orGraphQL: true) else { continue }
                guard force || watch.wakeAgent || !energy.signals.idle,
                      force || watch.checkedAt.map({ now.timeIntervalSince($0) >= watchGap || $0 > now }) ?? true else { continue }
                checkPullRequestWatch(run.id, url: watch.url, recheck: false)
            }
        }
        followPullRequestFeeds()
    }

    /// Reads every watch on the pull request at `url` now: its host just said it changed.
    func checkPullRequestWatches(url: String) {
        let aliases = PullRequestStatusStore.shared.repoAliases
        for run in runs where !run.archived {
            if let watch = SessionBranches.watch(for: url, in: run.prWatches, aliases: aliases) {
                checkPullRequestWatch(run.id, url: watch.url, recheck: true)
            }
        }
    }

    /// Reads one watched pull request and turns what changed into news. With `recheck` (the host reported a change), a
    /// read already under way is followed by one more, so the change is not missed; the sweep just skips it.
    func checkPullRequestWatch(_ id: UUID, url link: String, recheck: Bool) {
        let aliases = PullRequestStatusStore.shared.repoAliases
        guard let fetch = pullRequestSnapshot,
              let watch = run(id).flatMap({ SessionBranches.watch(for: link, in: $0.prWatches, aliases: aliases) }),
              watch.state == "open", let url = URL(string: watch.url) else { return }
        let key = id.uuidString + " " + watch.url
        guard !pullRequestWatcher.inFlight.contains(key) else {
            if recheck { pullRequestWatcher.rechecks.insert(key) }
            return
        }
        pullRequestWatcher.inFlight.insert(key)
        Task { [weak self] in
            let snapshot = await fetch(url)
            guard let self else { return }
            self.pullRequestWatcher.inFlight.remove(key)
            let currentAliases = PullRequestStatusStore.shared.repoAliases
            if let snapshot,
               let current = self.run(id).flatMap({ SessionBranches.watch(for: watch.url, in: $0.prWatches, aliases: currentAliases) }) {
                self.pullRequestChanged(id, old: current, new: snapshot)
            }
            if self.pullRequestWatcher.rechecks.remove(key) != nil { self.checkPullRequestWatch(id, url: watch.url, recheck: false) }
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
        let store = PullRequestStatusStore.shared
        if let url = URL(string: old.url) { store.record(url: url, snapshot: new, at: now) }
        let canonicalURL = new.url?.absoluteString ?? URL(string: old.url).map { store.canonicalURL($0).absoluteString } ?? old.url
        let aliases = store.repoAliases
        let targetPlace = SessionBranches.place(canonicalURL, aliases: aliases)
        // The first look only sets what counts as seen, but for a conflict that is already there.
        let first = old.checkedAt == nil
        let news = first ? PullRequestNews.firstLook(new) : PullRequestNews.lines(old: old, new: new)
        let lines = news.map(\.text)
        let wake = old.wakeAgent && (first ? !lines.isEmpty : PullRequestNews.needsAgent(old: old, new: new))
        update(id) { run in
            var updated = PullRequestNews.updated(old, with: new, at: now)
            updated.url = canonicalURL
            let replaced = run.prWatches.map { watch -> PullRequestWatch in
                guard watch.url == old.url || SessionBranches.place(watch.url, aliases: aliases) == targetPlace else { return watch }
                var next = updated
                next.wakeAgent = updated.wakeAgent || watch.wakeAgent
                return next
            }
            var deduped = SessionBranches.deduplicatedWatches(replaced, aliases: aliases) { raw in
                URL(string: raw).map { store.canonicalURL($0).absoluteString } ?? raw
            }
            run.prWatch = deduped.isEmpty ? nil : deduped.removeFirst()
            run.extraPRWatches = deduped.isEmpty ? nil : deduped
        }
        settleQueuedNews(id, url: old.url, with: new)
        if canonicalURL != old.url { settleQueuedNews(id, url: canonicalURL, with: new) }
        // A merged or closed pull request has nothing more to report: its change feed ends.
        if new.state != "open" || canonicalURL != old.url { followPullRequestFeeds() }
        guard !lines.isEmpty else { return }
        append(id, RunEvent(kind: .system, text: tr("ws.prwatch.news") + "\n" + lines.joined(separator: "\n"), tool: "prwatch"))
        guard wake, let run = run(id) else { return }
        let message = PullRequestNews.message(url: canonicalURL, lines: lines)
        // The news line above already shows it: the agent gets it without a bubble of yours.
        if run.canContinue && processes[id] == nil {
            sendHidden(id, text: message)
        } else {
            enqueue(id, text: message, pullRequest: PullRequestNotice(url: canonicalURL, lines: news))
        }
    }

    /// Waiting news about this pull request that is out of date leaves the queue.
    func settleQueuedNews(_ id: UUID, url: String, with snapshot: PullRequestSnapshot) {
        guard var queue = queued[id] else { return }
        queue.settleNews(url: url, with: snapshot)
        if queue != queued[id] { setQueue(queue, for: id) }
    }

    /// At the end of a turn: a pull request link the turn brought that the conversation did not have before is the one
    /// the agent just made, also when it used its own `gh` instead of pull_request_create. It joins the session's list
    /// whether or not it is watched, so it shows above the composer also when its branch is one Nook does not follow.
    func noticeCreatedPullRequest(_ id: UUID) {
        followAddedWorktree(id)
        // The turn may have pushed, merged or closed a pull request: the ones shown read again now, not at their next tick.
        PullRequestStatusStore.shared.wakeFollowers()
        guard let all = events[id], let made = RunPullRequestLinks.created(in: all, before: &pullRequestWatcher.beforeTurn[id]) else { return }
        if let ref = PullRequestRef.parse(made.absoluteString) { noticePullRequests(id, [ref], mustExist: false) }
        // The session's row lists it now (Nook no longer asks a branch without one every minute: this is how it learns).
        // No branch: the agent may have opened it for another one, and the next answer from the forge says which.
        PullRequestSync.shared.opened(id, url: made, branch: nil)
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
