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
            state: DelegatedTask.state(run.status, hasPendingQuestion: question),
            summary: DelegatedTask.summary(status: run.status, statusDetail: run.statusDetail, events: timeline(run.id)),
            hasPendingQuestion: question,
            model: run.resolvedModel ?? (run.model.isEmpty ? nil : run.model),
            provider: run.provider.displayName
        )
    }

    /// A child that was not waited for has finished: tell its parent once, in its own conversation. A parent that is busy
    /// gets it after the turn (the queue); a parent you stopped is left alone.
    func deliverDelegatedResult(_ id: UUID) {
        guard let child = run(id), var link = child.delegation, link.wake, !link.delivered,
              child.status == .completed || child.status == .failed,
              let parent = run(link.parentID), !parent.archived, parent.status != .stopped else { return }
        link.delivered = true
        update(id) { $0.delegation = link }
        let text = DelegatedTask.wakeMessage(snapshot(of: child))
        append(parent.id, RunEvent(kind: .system, text: tr("ws.event.delegatedDone", child.title)))
        if parent.canContinue, processes[parent.id] == nil, !checkpointing.contains(parent.id) {
            send(parent.id, text: text)
        } else {
            enqueue(parent.id, text: text)
        }
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
            stopDelegatedChildren(of: id)
        }
    }

    /// Stopping a session stops what it delegated.
    func stopDelegatedChildren(of id: UUID) {
        for child in activeChildren(of: id) { cancelDelegated(child.id) }
    }
}
