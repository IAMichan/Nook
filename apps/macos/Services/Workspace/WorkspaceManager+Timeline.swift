import Foundation

// Every provider's handler writes its output into the session's timeline through here (see AgentTimeline), so text,
// thinking and tool calls read the same for Claude Code, Codex, Gemini CLI and the ACP agents.
extension WorkspaceManager {
    /// One signal from a provider into the session's timeline, with what follows from it outside the timeline.
    func feed(_ id: UUID, _ signal: AgentSignal) {
        // Between turns (a replay, a late update) the events still land; there is no turn to remember them for.
        var timeline = turns[id]?.timeline ?? AgentTimeline()
        let effects = timeline.apply(signal, to: SessionTimelineSink(manager: self, id: id))
        turns[id]?.timeline = timeline
        for effect in effects {
            switch effect {
            case .toolStarted(let name):
                recap?.toolUse(name)
                turns[id]?.acpToolCalls += 1
            case .toolSucceeded(let name, let input, let paths):
                var recorded: Set<String> = []
                for change in ToolSummary.fileChanges(tool: name, input: input?.dictionary ?? [:]) where recorded.insert(change.path).inserted {
                    recordFileChange(id, path: change.path, kind: change.kind)
                }
                for path in paths where recorded.insert(path).inserted { recordFileChange(id, path: path, kind: "modified") }
            }
        }
    }

    /// The agent stops writing and thinking for now (an approval, a plan, the end of its turn).
    func pauseLive(_ id: UUID) { feed(id, .pause) }
}

/// The session's events as the timeline's sink.
private struct SessionTimelineSink: RunTimelineSink {
    let manager: WorkspaceManager
    let id: UUID

    func append(_ event: RunEvent) {
        MainActor.assumeIsolated { manager.append(id, event) }
    }

    func mutate(_ eventID: UUID, _ change: (inout RunEvent) -> Void) {
        MainActor.assumeIsolated { manager.mutateEvent(id, eventID, change) }
    }

    func eventID(callID: String) -> UUID? {
        MainActor.assumeIsolated { manager.timeline(id).last { $0.callID == callID && $0.kind == .tool }?.id }
    }
}
