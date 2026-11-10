import Foundation

// Marks in a session's timeline where it went on with another agent, model or effort (`ModelSwitch`):
// a divider between the turns, drawn by `ModelSwitchDivider`. Changes you make before sending one message count as one.

extension WorkspaceManager {
    /// What `run` runs now, as the timeline names it.
    func switchEndpoint(_ run: WorkspaceRun) -> ModelSwitch.Endpoint {
        let menu = modelMenu(for: run.provider, profileID: run.profileID)
        let model = run.autoModel == true ? nil : menu.name(run.model)
        return ModelSwitch.Endpoint(provider: run.provider.rawValue, agent: run.provider.displayName, model: model,
                                    effort: run.effort)
    }

    /// Notes that the session now runs something else than `from`. A switch right after another one, with no message of
    /// yours in between, joins it: the divider says where you came from and where you ended up.
    func noteModelSwitch(_ id: UUID, from: ModelSwitch.Endpoint) {
        guard let run = run(id) else { return }
        let to = switchEndpoint(run)
        loadTimeline(id)
        // Nothing was said in this session yet: there is no "before" to set apart.
        guard timeline(id).contains(where: { $0.kind == .user }) else { return }
        if let last = timeline(id).last(where: { $0.kind != .system || $0.tool == "switch" }),
           last.kind == .system, last.tool == "switch", var change = last.change {
            change.to = to
            mutateEvent(id, last.id) {
                $0.change = change
                $0.text = ModelSwitchText.plain(change)
            }
            return
        }
        let change = ModelSwitch(from: from, to: to)
        guard !change.isNoChange else { return }
        var event = RunEvent(kind: .system, text: ModelSwitchText.plain(change), tool: "switch")
        event.change = change
        append(id, event)
    }
}

/// The words of a switch, for search, copy and the handoff summary (the divider draws its own).
enum ModelSwitchText {
    static func side(_ endpoint: ModelSwitch.Endpoint, model: Bool, effort: Bool) -> String {
        [model ? endpoint.model ?? "default" : nil, effort ? endpoint.effort : nil].compactMap { $0 }.joined(separator: " ")
    }

    static func plain(_ change: ModelSwitch) -> String {
        if change.handoff {
            return change.from.agent + " " + side(change.from, model: true, effort: change.from.effort != nil) + " → "
                + change.to.agent + " " + side(change.to, model: true, effort: change.to.effort != nil)
        }
        let model = change.modelChanged, effort = change.effortChanged
        return side(change.from, model: model, effort: effort) + " → " + side(change.to, model: model, effort: effort)
    }
}
