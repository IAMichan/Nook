import Foundation

// Delegated tasks as sessions: a child is an ordinary session with a link to its parent. The
// parent gets the result by task_status, by waiting in the call, or by a message when the child finishes.

extension WorkspaceManager {
    func children(of parent: UUID) -> [WorkspaceRun] {
        runs.filter { $0.delegation?.parentID == parent }
    }

    func activeChildren(of parent: UUID) -> [WorkspaceRun] {
        children(of: parent).filter { $0.status.isActive }
    }

    /// The sub-threads at every level that still work for `parent` (`DelegatedTask.workingSubThreads`).
    func workingSubThreads(of parent: UUID) -> Int {
        DelegatedTask.workingSubThreads(of: parent, in: runs)
    }

    /// The child a repeated call with the same `client_request_id` already started.
    func delegatedChild(of parent: UUID, key: String) -> WorkspaceRun? {
        children(of: parent).first { $0.delegation?.key == key }
    }

    /// A task of this parent by the id delegate_task returned; never one of another session.
    func delegatedTask(_ taskID: String, of parent: UUID) -> WorkspaceRun? {
        guard let id = UUID(uuidString: taskID), let run = run(id), run.delegation?.parentID == parent else { return nil }
        return run
    }

    func snapshot(of run: WorkspaceRun) -> DelegatedTask.Snapshot {
        loadTimeline(run.id)
        let question = !(questions[run.id] ?? []).isEmpty
        return DelegatedTask.Snapshot(
            taskID: run.id.uuidString.lowercased(),
            title: run.title,
            state: DelegatedTask.state(run.status, hasPendingQuestion: question, hasQueuedWork: hasQueuedWork(run.id)),
            summary: DelegatedTask.summary(status: run.status, statusDetail: run.statusDetail, events: timeline(run.id)),
            hasPendingQuestion: question,
            model: run.resolvedModel ?? (run.model.isEmpty ? nil : run.model),
            provider: run.provider.displayName,
            worktree: run.isolation == .worktree ? run.worktreePath : nil,
            branch: run.isolation == .worktree ? run.branch : nil
        )
    }

    /// A message still waits to go out to this session (not one held after a failure or a stop): the work it asked for
    /// is not over yet. Its live process does not count: Claude Code, Codex and the ACP agents keep theirs between turns.
    func hasQueuedWork(_ id: UUID) -> Bool {
        (queued[id].map { !$0.isEmpty && !$0.isHeld } ?? false) || pendingSendNow[id] != nil || awaitingCheckpoint[id] != nil
    }

    /// A child that was not waited for has finished: tell its parent once, in its own conversation. A parent that is busy
    /// gets it after the turn (the queue); a parent you stopped is left alone. A child with a message still waiting to go
    /// out to it is not finished: it reports after that turn (`sendQueued` calls here once the queue is empty), and a
    /// result held for a monitor waits for it (`WakeCompletion`).
    func deliverDelegatedResult(_ id: UUID) {
        guard let child = run(id), var link = child.delegation, link.wake, !link.delivered,
              DelegatedTask.mayDeliver(child.status, hasQueuedWork: hasQueuedWork(id)), !heldWakeCompletions.contains(id),
              let parent = run(link.parentID), !parent.archived, parent.status != .stopped else { return }
        link.delivered = true
        update(id) { $0.delegation = link }
        let text = DelegatedTask.wakeMessage(snapshot(of: child))
        append(parent.id, RunEvent(kind: .system, text: tr("ws.event.delegatedDone", child.title)))
        // The parent carries on its own work: its working timer keeps going (`TurnTimer`).
        if parent.canContinue, processes[parent.id] == nil, !checkpointing.contains(parent.id) {
            send(parent.id, text: text, origin: .notice)
        } else {
            enqueue(parent.id, text: text, origin: .notice)
        }
    }

    /// A new turn of a task that already reported (a message from you, its parent, or a client without a session of its
    /// own): its parent hears of this one too when it ends (a send to a finished child notifies its parent).
    func rearmDelegation(_ id: UUID) {
        guard run(id)?.delegation?.delivered == true else { return }
        update(id) { $0.delegation?.delivered = false }
    }

    /// An agent asks you something: the notification, and for a delegated task a word to its parent.
    func asked(_ id: UUID, _ pending: PendingQuestion) {
        guard let run = run(id) else { return }
        onQuestion?(run, pending)
        deliverDelegatedQuestion(id, pending)
    }

    /// A task its parent did not wait for asks a question: the parent hears of it once, the way it hears of a result
    /// (nobody watches a child, so its question would go unanswered). A waiting parent learns it from its wait.
    func deliverDelegatedQuestion(_ id: UUID, _ pending: PendingQuestion) {
        guard let child = run(id), var link = child.delegation, link.wake,
              !(link.toldQuestions ?? []).contains(pending.id),
              let parent = run(link.parentID), !parent.archived, parent.status != .stopped else { return }
        link.toldQuestions = (link.toldQuestions ?? []) + [pending.id]
        update(id) { $0.delegation = link }
        let question = pending.questions.map { [$0.header, $0.question].filter { !$0.isEmpty }.joined(separator: ": ") }
            .joined(separator: "\n")
        let text = DelegatedTask.questionMessage(snapshot(of: child), questionID: pending.id, question: question)
        append(parent.id, RunEvent(kind: .system, text: tr("ws.event.delegatedAsks", child.title)))
        // Into its running turn only when that interrupts nothing (a long turn of a main thread may never end).
        if parent.status.isActive, steerRoute(parent.id) == .native, steer(parent.id, text: text) { return }
        if parent.canContinue, processes[parent.id] == nil, !checkpointing.contains(parent.id) {
            send(parent.id, text: text, origin: .notice)
        } else {
            enqueue(parent.id, text: text, origin: .notice)
        }
    }

    // MARK: Main thread

    /// "Main thread" on or off for the next messages (`MainThread`). The agent hears of it with your next message.
    func setMainThread(_ id: UUID, _ on: Bool) {
        guard let run = run(id), (run.mainThread ?? false) != on else { return }
        update(id) { $0.mainThread = on ? true : nil }
    }

    /// Your message, with the main-thread note when the agent does not know the current state yet.
    func withMainThreadNote(_ id: UUID, _ text: String) -> String {
        guard let run = run(id), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let note = MainThread.pending(on: run.mainThread, told: run.mainThreadTold) else { return text }
        update(id) { $0.mainThreadTold = $0.mainThread }
        return MainThread.attach(note, to: text)
    }

    /// The tasks you can follow above a session's composer: those at work or waiting for an answer, and those that ended
    /// since your last message there (done, failed or stopped), so a task never drops out of sight before you saw it.
    func subThreads(of parent: UUID) -> [WorkspaceRun] {
        let since = timeline(parent).last { $0.kind == .user }?.date ?? .distantPast
        return DelegatedTask.shown(children(of: parent), asking: { !(self.questions[$0] ?? []).isEmpty }, since: since)
    }

    /// The parent will not wait for this task any more: no message when it finishes.
    func stopWaiting(for id: UUID) {
        guard run(id)?.delegation != nil else { return }
        update(id) { $0.delegation?.wake = false }
    }

    /// The parent wants the message after all (its wait ran out).
    func wakeParent(when id: UUID) {
        guard run(id)?.delegation != nil else { return }
        update(id) { $0.delegation?.wake = true }
        // It may have finished while the parent was still waiting.
        deliverDelegatedResult(id)
    }

    /// Nobody is woken for this task or the tasks it delegated.
    private func silence(_ id: UUID) {
        stopWaiting(for: id)
        for child in children(of: id) { silence(child.id) }
    }

    /// Stops a task and every task it delegated; nobody is woken for it.
    func cancelDelegated(_ id: UUID) {
        silence(id)
        if run(id)?.status.isActive == true {
            // Stop also reaches the tasks it delegated.
            stop(id)
        } else {
            // What still waited to go out to it stays (held) instead of starting a turn nobody asked for any more.
            holdQueue(id)
            stopDelegatedChildren(of: id)
        }
    }

    /// Stopping a session stops what it delegated.
    func stopDelegatedChildren(of id: UUID) {
        for child in activeChildren(of: id) { cancelDelegated(child.id) }
    }
}

// MARK: Lineage

extension WorkspaceRun {
    /// The session this one came from: the one that delegated it, or the one it was forked, compared or asked beside.
    var parentRunID: UUID? { delegation?.parentID ?? lineage?.parentID }

    /// How it came from `parentRunID` (`SubThreadLineage`).
    var subThreadRelation: SubThreadRelation? {
        if delegation != nil { return .delegated }
        switch lineage?.kind {
        case .fork?: return .fork
        case .comparison?: return .comparison
        case .side?: return .side
        case nil: return nil
        }
    }
}

extension WorkspaceManager {
    /// The sessions related to `id`, in the groups of its Lineage control: its parent and forks, the tasks it delegated
    /// (at work, or ended), and its side chats.
    func lineageGroups(of id: UUID) -> LineageGroups {
        guard let me = run(id) else { return LineageGroups() }
        // Only the sessions that can show up: this one, its parent, and its own children.
        let related = runs.filter { $0.id == id || $0.id == me.parentRunID || $0.parentRunID == id }
        let nodes = related.map { run in
            LineageNode(id: run.id, parentID: run.parentRunID, relation: run.subThreadRelation, title: run.title,
                        status: lineageStatus(run), createdAt: run.createdAt)
        }
        return LineageLayout.groups(for: id, nodes: nodes)
    }

    private func lineageStatus(_ run: WorkspaceRun) -> LineageStatus {
        switch attention(run, unseen: false, includeSnooze: false) {
        case .approval: return .approval
        case .input: return .question
        case .working: return .working
        case .failed: return .failed
        case .limited, .ready, .idle, .finished: return run.status == .stopped ? .stopped : .done
        }
    }
}
