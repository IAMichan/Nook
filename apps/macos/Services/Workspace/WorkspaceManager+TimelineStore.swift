import Foundation

/// Reading, releasing and saving the sessions' timelines. The events themselves stay in `WorkspaceManager.events`, which
/// every agent's handler writes; what is kept about them (`TimelineStore`) and how they come and go lives here.
extension WorkspaceManager {
    func timeline(_ id: UUID) -> [RunEvent] {
        if let loaded = events[id] {
            timelineStore.use[id] = Date()
            return loaded
        }
        // Released while unused: back from disk, off the main thread, so a view drawing it does not stall on the read;
        // it redraws once the timeline is here.
        if timelineStore.evicted.contains(id) { requestTimeline(id) }
        return []
    }

    /// A view shows this timeline from now on: it stays in memory until `timelineHidden`.
    func timelineShown(_ id: UUID) { timelineStore.shown[id, default: 0] += 1 }

    func timelineHidden(_ id: UUID) {
        guard let count = timelineStore.shown[id] else { return }
        timelineStore.shown[id] = count > 1 ? count - 1 : nil
        timelineStore.use[id] = Date()
    }

    /// Whether the session's timeline is in memory; false while it is still being read from disk.
    func isTimelineLoaded(_ id: UUID) -> Bool { events[id] != nil }

    /// The session's timeline for Search everything: from memory when it is loaded, else read from disk off the main
    /// thread without keeping it, so a search does not hold every timeline in memory.
    /// The sessions that may mention `query`, from the search index; nil when the index cannot answer. Timelines in
    /// memory are always included: what they streamed since their last save is not in the index yet.
    func sessionsMentioning(_ query: String) async -> [UUID]? {
        let store = store
        guard let indexed = await Task.detached(priority: .userInitiated, operation: { store.sessions(mentioning: query) }).value else {
            return nil
        }
        return indexed + events.keys.filter { !indexed.contains($0) }
    }

    func timelineForSearch(_ id: UUID) async -> [RunEvent] {
        if let loaded = events[id] { return loaded }
        let store = store
        return await Task.detached(priority: .utility) { store.peekEvents(id) }.value
    }

    /// The text of the session's last answer, from memory only: a released timeline is not read back for it, and asking
    /// does not count as using the timeline (so polling summaries do not keep every timeline in memory).
    func lastAnswer(_ id: UUID) -> String {
        if let loaded = events[id] { return loaded.last(where: { $0.kind == .assistant })?.text ?? "" }
        if let answer = timelineStore.bufferedAppends[id]?.last(where: { $0.kind == .assistant }) { return answer.text }
        return timelineStore.evictedAnswers[id] ?? ""
    }

    /// Reads a timeline that is not in memory off the main thread, so opening its session right after (a row under the
    /// pointer, the session the list is about to show) draws it at once instead of replaying its whole log
    /// on the main thread first. Opening before this is done waits for the same read (`requestTimeline`).
    func prefetchTimeline(_ id: UUID) {
        guard events[id] == nil, !timelineStore.prefetching.contains(id), runIndex(id) != nil else { return }
        timelineStore.prefetching.insert(id)
        let store = store
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { store.loadEvents(id) }.value
            guard let self else { return }
            self.timelineStore.prefetching.remove(id)
            let awaited = self.timelineStore.awaited.remove(id) != nil
            // Opened (or written to) meanwhile: what is in memory is newer than what was read.
            guard self.events[id] == nil else {
                // Events appended while it was read still join it.
                if let buffered = self.timelineStore.bufferedAppends.removeValue(forKey: id), let current = self.events[id] {
                    self.events[id] = TimelineMerge.merge(current, buffered)
                    self.scheduleEventSave(id)
                }
                self.runTimelineWaiters(id)
                return
            }
            self.timelineStore.use[id] = Date()
            // News only for a view that is waiting for it, or for events that came while it was read; a prefetch nobody
            // shows yet redraws nothing.
            self.timelineStore.quiet = !awaited && self.timelineStore.bufferedAppends[id] == nil
            self.installTimeline(id, loaded)
            self.timelineStore.quiet = false
            self.evictTimelines()
            self.runTimelineWaiters(id)
        }
    }

    /// Runs `body` once the session's timeline is in memory: now when it is, else after it is read off the main thread.
    func whenTimelineLoaded(_ id: UUID, _ body: @escaping () -> Void) {
        guard events[id] == nil else { return body() }
        timelineStore.waiters[id, default: []].append(body)
        prefetchTimeline(id)
        // Not a session in the list: nothing to read in the background, as before.
        if !timelineStore.prefetching.contains(id) { loadTimeline(id) }
    }

    func runTimelineWaiters(_ id: UUID) {
        guard events[id] != nil, let waiters = timelineStore.waiters.removeValue(forKey: id) else { return }
        for waiter in waiters { waiter() }
    }

    /// Puts a timeline read from disk in memory, with the events appended to it while it was read.
    func installTimeline(_ id: UUID, _ loaded: [RunEvent]) {
        timelineStore.evicted.remove(id)
        timelineStore.evictedAnswers[id] = nil
        let buffered = timelineStore.bufferedAppends.removeValue(forKey: id) ?? []
        let timeline = TimelineMerge.merge(loaded, buffered)
        timelineStore.countingBytes = true
        events[id] = timeline
        timelineStore.bytes.loaded(id, timeline)
        timelineStore.countingBytes = false
        guard !buffered.isEmpty else { return }
        // What `append` and `mutateEvent` leave for a timeline in memory: a save of what changed, and the pull request a
        // turn that ended meanwhile made.
        scheduleEventSave(id)
        if buffered.contains(where: { $0.kind == .result }) { noticeCreatedPullRequest(id) }
    }

    /// For a view that shows the timeline: reads it off the main thread when it is not in memory and redraws the view
    /// once it is here, so opening an older session never waits for its log on the main thread. Actions that need the
    /// events right away (handoff, rollback) use `loadTimeline`; a message you send and an event appended to a released
    /// timeline wait for the same read (`whenTimelineLoaded`, `append`).
    func requestTimeline(_ id: UUID) {
        timelineStore.use[id] = Date()
        guard events[id] == nil else { return }
        prefetchTimeline(id)
        if timelineStore.prefetching.contains(id) { timelineStore.awaited.insert(id) }
    }

    /// Loads timeline from disk if not yet in memory.
    func loadTimeline(_ id: UUID) {
        timelineStore.use[id] = Date()
        guard events[id] == nil else { return }
        installTimeline(id, store.loadEvents(id))
        evictTimelines()
        runTimelineWaiters(id)
    }

    /// Releases the longest unused timelines of idle sessions, beyond `timelineLimit` or `timelineByteBudget`.
    func evictTimelines() {
        // Unused for minutes: a save scheduled for it has long been written, so reading it back gets everything.
        let unusedSince = Date().addingTimeInterval(-TimelineStore.timelineIdleSeconds)
        let candidates = events.map { id, list in
            let used = timelineStore.use[id] ?? .distantPast
            let idle = used < unusedSince && timelineStore.shown[id] == nil
                && timelineStore.eventSaves[id] == nil && processes[id] == nil && turns[id] == nil && codexServers[id] == nil
                && claudeIdle[id] == nil && acpClients[id] == nil && !(run(id)?.status.isActive ?? false)
            return TimelineEviction.Candidate(id: id, lastUsed: used, bytes: timelineStore.bytes.bytes(id, of: list), idle: idle)
        }
        for id in TimelineEviction.pick(candidates, limit: TimelineStore.timelineLimit, budget: TimelineStore.timelineByteBudget) {
            // Only the start: a summary shows a short excerpt of it, and a long answer need not stay in memory whole.
            timelineStore.evictedAnswers[id] = events[id]?.last(where: { $0.kind == .assistant }).map { String($0.text.prefix(2_000)) }
            timelineStore.countingBytes = true
            events[id] = nil
            timelineStore.bytes.forget(id)
            timelineStore.countingBytes = false
            timelineStore.use[id] = nil
            timelineStore.evicted.insert(id)
        }
    }

    // MARK: Tracking and Persistence

    func append(_ id: UUID, _ event: RunEvent) {
        // A kept agent's output read again after a crash: what is already there is not shown twice.
        if keptReplays[id] != nil, replaceReplayed(id, event) { return }
        timelineStore.changing = id
        defer { timelineStore.changing = nil }
        timelineStore.use[id] = Date()
        if events[id] == nil, runIndex(id) != nil {
            // Released while idle: read back off the main thread, and this event joins it once it is here
            // (`installTimeline`). The log gets it now, as always.
            timelineStore.bufferedAppends[id, default: []].append(event)
            prefetchTimeline(id)
        } else {
            // Not a session in the list: nothing to read in the background, as before.
            if events[id] == nil { installTimeline(id, store.loadEvents(id)) }
            timelineStore.countingBytes = true
            events[id]?.append(event)
            timelineStore.bytes.appended(id, event)
            timelineStore.countingBytes = false
        }
        store.appendEventAsync(id, event)
        if !worktreeSetups.isEmpty { noteSetupEvent(id, event) }
        if event.countsAsActivity(runActive: runIndex(id).map { runs[$0].status.isActive } ?? false) {
            // Every bump republishes `runs` (and redraws what observes it) outside the 50 ms events throttle. A streaming
            // agent appends many events a second, so in between turn boundaries the time moves on at most every 2 s.
            let boundary = event.kind == .user || event.kind == .result || event.kind == .error || event.kind == .approval
            let now = Date()
            if boundary || runIndex(id).map({ now.timeIntervalSince(runs[$0].updatedAt) >= 2 }) ?? false {
                update(id, save: false) { $0.updatedAt = now }
            }
        }
        scheduleEventSave(id)
        if event.kind == .result { noticeCreatedPullRequest(id) }
        // A pull request you name in your message ("#12", a link) is one this session works on. "#12" may be an issue,
        // so it is linked only once the forge says it is a pull request.
        if event.kind == .user { noticePullRequests(id, PullRequestMentions.inMessage(event.text), mustExist: true) }
    }

    func mutateEvent(_ id: UUID, _ eventID: UUID, _ change: (inout RunEvent) -> Void) {
        // An event read again after a crash changes the one it took the place of.
        let eventID = keptReplays[id]?.resolve(eventID) ?? eventID
        // In place: this runs for every streamed token, and a copy of the list would copy the whole timeline each time.
        guard let index = events[id]?.lastIndex(where: { $0.id == eventID }) else {
            // Appended while its timeline is read back: changed where it waits (`installTimeline` saves it).
            if events[id] == nil, let at = timelineStore.bufferedAppends[id]?.lastIndex(where: { $0.id == eventID }) {
                // Out and back in: the change runs outside an access to `timelineStore`, which it may read itself.
                var event = timelineStore.bufferedAppends[id]![at]
                change(&event)
                timelineStore.bufferedAppends[id]?[at] = event
            }
            return
        }
        timelineStore.changing = id
        timelineStore.countingBytes = true
        let before = events[id]![index].approximateBytes
        change(&events[id]![index])
        timelineStore.bytes.changed(id, from: before, to: events[id]![index].approximateBytes)
        timelineStore.countingBytes = false
        timelineStore.changing = nil
        scheduleEventSave(id)
    }

    /// Announces a changed timeline: the first change at once, later ones within the same short window together.
    /// `id` is the session that changed, nil when it could be any.
    func eventsDidChange(_ id: UUID? = nil) {
        guard !timelineStore.quiet else { return }
        if let id { timelineStore.dirtyTimelines?.insert(id) } else { timelineStore.dirtyTimelines = nil }
        if timelineStore.throttled {
            timelineStore.dirty = true
            return
        }
        publishTimelineChanges()
    }

    func publishTimelineChanges() {
        timelines.objectWillChange.send()
        if let dirty = timelineStore.dirtyTimelines {
            for id in dirty { sessionTimelines[id]?.objectWillChange.send() }
        } else {
            for changes in sessionTimelines.values { changes.objectWillChange.send() }
        }
        timelineStore.dirtyTimelines = []
        timelineStore.throttled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: TimelineStore.eventsPublishInterval)
            guard let self else { return }
            self.timelineStore.throttled = false
            if self.timelineStore.dirty {
                self.timelineStore.dirty = false
                self.publishTimelineChanges()
            }
        }
    }


    func scheduleSave() {
        timelineStore.saveTask?.cancel()
        timelineStore.saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled, self.runsLoaded else { return }
            let runsSnapshot = self.runs
            self.writeRuns(runsSnapshot)
        }
    }

    func scheduleEventSave(_ id: UUID) {
        guard timelineStore.eventSaves[id] == nil else { return }
        timelineStore.eventSaves[id] = Task { [weak self] in
            // Each save compares the whole timeline with the log and writes every changed event in full, so a long answer
            // is written again each time (new events are written at once by `append`). While an answer streams, every five
            // seconds is plenty: a crash loses at most the last five seconds of text.
            try? await Task.sleep(nanoseconds: TimelineStore.eventSaveInterval)
            guard let self else { return }
            self.timelineStore.eventSaves[id] = nil
            if let list = self.events[id] { self.store.saveEventsAsync(id, list) }
            self.scheduleRunsCatchUp()
        }
    }

    /// What streaming changes in the session list is only the time of the last event: a real change saves on its own
    /// (`scheduleSave`), and quitting saves everything. The list holds every session, so it is written now and then, once,
    /// however many sessions stream.
    func scheduleRunsCatchUp() {
        guard timelineStore.runsCatchUp == nil else { return }
        timelineStore.runsCatchUp = Task { [weak self] in
            try? await Task.sleep(nanoseconds: TimelineStore.runsCatchUpInterval)
            guard let self else { return }
            self.timelineStore.runsCatchUp = nil
            guard self.runsLoaded, self.timelineStore.savedRuns != self.runs else { return }
            self.writeRuns(self.runs)
        }
    }

    func writeRuns(_ snapshot: [WorkspaceRun]) {
        timelineStore.savedRuns = snapshot
        // A write that failed tries again: without a change to the list nothing else would.
        store.saveRunsAsync(durableRuns(snapshot)) { [weak self] in
            Task { @MainActor in
                self?.timelineStore.savedRuns = nil
                self?.scheduleRunsCatchUp()
            }
        }
    }
}

/// What `WorkspaceManager+TimelineStore` keeps about the timelines besides their events.
struct TimelineStore {
    /// What each timeline in memory holds, for `evictTimelines`: kept by loads, `append`, `mutateEvent` and evictions.
    var bytes = TimelineBytes()
    /// Set while a change to `events` updates `bytes` itself.
    var countingBytes = false
    /// The session whose timeline `append` or `mutateEvent` is changing, so only views of that session hear about it.
    /// Any other change to `events` (a load, a rollback, a fork) is announced to every session.
    var changing: UUID?
    var saveTask: Task<Void, Never>?
    var eventSaves: [UUID: Task<Void, Never>] = [:]
    /// A pending save of the session list that streaming asked for (see `scheduleRunsCatchUp`).
    var runsCatchUp: Task<Void, Never>?
    /// The session list as it was last handed to the store: a timeline save only rewrites `runs.json` when it changed.
    var savedRuns: [WorkspaceRun]?
    /// A change to `events` was announced less than `eventsPublishInterval` ago; `dirty` says another one followed.
    var throttled = false
    var dirty = false
    /// The sessions whose timeline changed since the last announcement; nil when it could be any of them.
    var dirtyTimelines: Set<UUID>? = []
    /// At most this often a view redraws for a changing timeline: about 20 times a second, smooth for streaming text.
    static let eventsPublishInterval: UInt64 = 50_000_000
    /// When each timeline in memory was last used. Every timeline ever opened used to stay in memory until Nook quit;
    /// beyond `timelineLimit` the longest unused ones of idle sessions are released (`evictTimelines`) and read back from
    /// disk when anything asks for them again (`evicted`).
    var use: [UUID: Date] = [:]
    var evicted: Set<UUID> = []
    /// The timelines on screen, with how many views show each. `use` moves only on a redraw, so a session you sit
    /// and read looks unused; it must not disappear under you.
    var shown: [UUID: Int] = [:]
    /// The last answer of each released timeline, so a summary (the phone's session list) can show it without reading
    /// the whole timeline back from disk and keeping it in memory again.
    var evictedAnswers: [UUID: String] = [:]
    static let timelineLimit = 16
    /// What the timelines in memory may hold together: measured on 2026-11-06, a session was 2 MB and the longest 6.5 MB.
    static let timelineByteBudget = 64 * 1024 * 1024
    static let timelineIdleSeconds: TimeInterval = 300
    /// Set while an evicted timeline is read back for a view that is drawing it: no news for anyone.
    var quiet = false
    /// Timelines being read off the main thread by `prefetchTimeline`.
    var prefetching: Set<UUID> = []
    /// Of those, the ones a view waits for (`requestTimeline`): their arrival redraws it.
    var awaited: Set<UUID> = []
    /// What waits for a timeline being read back (`whenTimelineLoaded`), run once it is in memory.
    var waiters: [UUID: [() -> Void]] = [:]
    /// Events appended to a timeline while it is read back from disk, added to it once it is here (`installTimeline`).
    var bufferedAppends: [UUID: [RunEvent]] = [:]
    /// Sessions whose message waits for their timeline to be read back before its turn starts (`send`).
    var readingToSend: Set<UUID> = []
    static let eventSaveInterval: UInt64 = 5_000_000_000
    static let runsCatchUpInterval: UInt64 = 30_000_000_000

    /// A deleted session's entries, and the save it still had coming.
    mutating func forget(_ id: UUID) {
        use[id] = nil
        evicted.remove(id)
        evictedAnswers[id] = nil
        waiters[id] = nil
        bufferedAppends[id] = nil
        readingToSend.remove(id)
        eventSaves.removeValue(forKey: id)?.cancel()
        dirtyTimelines?.remove(id)
        shown[id] = nil
        prefetching.remove(id)
        awaited.remove(id)
    }
}
