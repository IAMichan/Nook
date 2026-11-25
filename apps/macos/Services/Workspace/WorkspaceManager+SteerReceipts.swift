import Foundation

// "Steer · waiting to be read" (`SteerReceipts`): a steer to an agent that echoes what it reads stays pending until the
// echo, and is cancelled when the turn stops before the agent read it.
extension WorkspaceManager {
    /// A steered message of yours as it goes into the timeline: pending when the agent will say once it read it.
    func steerEvent(_ id: UUID, text: String, mark: RunEvent.SteerKind) -> RunEvent {
        var event = steered(RunEvent(kind: .user, text: shownMessage(id, text)), mark)
        if run(id)?.provider.capabilities.echoesSteers == true { event.steerStatus = .pending }
        return event
    }

    /// The agent echoed a message of yours: the steer it stands for has been read.
    func steerEchoed(_ id: UUID, text: String?) {
        let events = timeline(id)
        guard events.contains(where: { $0.steerStatus == .pending }),
              let read = SteerReceipts.read(in: events, echo: text, turnPrompt: turnPrompts[id]) else { return }
        mutateEvent(id, read) { $0.steerStatus = nil }
    }

    /// The turn ended: a steer still waiting was read (the agent takes them in before it settles) or, when the turn was
    /// stopped or failed, dropped unread.
    func settleSteers(_ id: UUID, dropped: Bool) {
        for (event, status) in SteerReceipts.settled(timeline(id), dropped: dropped) {
            mutateEvent(id, event) { $0.steerStatus = status }
        }
    }
}

/// A steer of yours that waits until the agent is done changing a file (`WorkspaceManager.holdSteer`).
struct HeldSteer: Equatable, Sendable {
    var text: String
    var mark: RunEvent.SteerKind
    /// Its bubble in the timeline; nil for a steer that goes in right away (its bubble comes with it).
    var eventID: UUID? = nil
}

// A steer while the agent changes a file: Claude Code's steer stops what it does, and an agent steered by interrupting
// it stops altogether, so a change could be cut off halfway. It waits instead, shown as sent but not taken in yet, and
// goes in as soon as the change is done. The same for every agent (`AgentTimeline.isEditing`).
extension WorkspaceManager {
    /// Shows the steer as waiting to be read and keeps it for `releaseHeldSteers`.
    func holdSteer(_ id: UUID, text: String, mark: RunEvent.SteerKind) {
        var event = steerEvent(id, text: text, mark: mark)
        event.steerStatus = .pending
        append(id, event)
        heldSteers[id, default: []].append(HeldSteer(text: text, mark: mark, eventID: event.id))
    }

    /// The change is done: what waited goes into the turn, in the order you sent it. When the turn cannot take it any
    /// more (it is being stopped), it waits for the end of the turn (`settleHeldSteers`).
    func releaseHeldSteers(_ id: UUID) {
        guard let held = heldSteers[id], !held.isEmpty, turns[id]?.timeline.isEditing != true, canSteer(id) else { return }
        heldSteers[id] = nil
        if !deliverSteer(id, held, shown: true) { heldSteers[id] = held }
    }

    /// The turn ended with steers still waiting: after a finished turn they go out first, as the next message (their
    /// bubbles say they were not taken into this one); after a stop or a failure they were dropped (`settleSteers`).
    func settleHeldSteers(_ id: UUID, completed: Bool) {
        guard let held = heldSteers.removeValue(forKey: id), !held.isEmpty else { return }
        for steer in held {
            if let bubble = steer.eventID { mutateEvent(id, bubble) { $0.steerStatus = .cancelled } }
        }
        guard completed else { return }
        var queue = queued[id] ?? MessageQueue()
        for steer in held.reversed() { queue.requeueFirst(steer.text) }
        setQueue(queue, for: id)
    }
}
