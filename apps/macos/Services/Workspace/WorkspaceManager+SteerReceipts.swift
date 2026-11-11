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
