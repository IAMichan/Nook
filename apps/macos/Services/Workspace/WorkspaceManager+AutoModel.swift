import Foundation

/// "Auto" at work (see `AutoModel`): before each turn of a session set to Auto, Nook picks the model from the ones you
/// allow for its agent, the turn's prompt and effort, and the account's usage windows, and says in the session which one
/// it took and why when that changes. The same for every agent: what differs is only the models each one offers.
extension WorkspaceManager {
    /// The models "Auto" may pick for an agent (see `AutoModel.candidates`).
    func autoCandidates(for provider: RunProvider, profileID: String? = nil) -> [AutoModel.Candidate] {
        let menu = modelMenu(for: provider, profileID: profileID)
        return AutoModel.candidates(menu.choices, allowed: settings.autoModels(for: provider), same: menu.same)
    }

    /// What "Auto" would pick for this prompt now; nil when the agent offers no models to pick from.
    func autoModelDecision(provider: RunProvider, profileID: String, prompt: String, effort: String?) -> AutoModel.Decision? {
        AutoModel.pick(autoCandidates(for: provider, profileID: profileID),
                       need: AutoModel.need(prompt: prompt, effort: effort), windows: usageWindows(profileID))
    }

    /// Sets the model of a session on Auto for the turn about to start.
    func applyAutoModel(_ id: UUID, prompt: String) {
        guard let run = run(id), run.autoModel == true,
              let decision = autoModelDecision(provider: run.provider, profileID: run.profileID, prompt: prompt, effort: run.effort),
              !sameModel(decision.model, run.model, for: run.provider) || run.model.isEmpty else { return }
        update(id) { $0.model = decision.model }
        let name = modelChoice(decision.model, for: run.provider, profileID: run.profileID)?.name ?? decision.model
        let reason = tr(AutoModel.reasonKey(decision), Int(decision.fullest.rounded()))
        append(id, RunEvent(kind: .system, text: tr("auto.chose", name, reason)))
    }
}
