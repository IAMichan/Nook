import Foundation

/// "Auto" at work (see `AutoModel`), over every connected agent and account. A new session on Auto starts on the agent,
/// account and model that fit its task and limits best; before each later message Nook may move it to another agent or
/// account (handing the conversation over, as when you switch yourself) when that fits clearly better, for example because
/// the account in use runs out; and before each turn it picks the model within the agent. It says in the session what it
/// picked and why when that changes.
extension WorkspaceManager {
    /// The models "Auto" may pick: every allowed model of every connected agent that can run here, under each of its
    /// accounts with that account's usage windows. `preferring` goes first, so it wins a tie; `only` keeps to one account.
    func autoCandidates(preferring: AutoModel.Account? = nil, only: AutoModel.Account? = nil) -> [AutoModel.Candidate] {
        var accounts = only.map { [$0] } ?? autoAccounts()
        if let preferring, let index = accounts.firstIndex(of: preferring) { accounts.insert(accounts.remove(at: index), at: 0) }
        return accounts.filter { executable($0.provider) != nil }.flatMap { account -> [AutoModel.Candidate] in
            let menu = modelMenu(for: account.provider, profileID: account.profileID)
            return AutoModel.candidates(menu.choices, allowed: settings.autoModels(for: account.provider), same: menu.same,
                                        account: account, windows: usageWindows(account.profileID))
        }
    }

    /// How many models and agents "Auto" picks from now, for the model menu.
    func autoReach() -> (models: Int, agents: Int) {
        let candidates = autoCandidates()
        return (Set(candidates.map { $0.provider.rawValue + "/" + $0.id }).count, Set(candidates.map(\.provider)).count)
    }

    /// A new session on Auto: the agent and account that fit its task and limits best. The model stays "Auto" and is
    /// picked as the first turn starts; effort and rights that the new agent does not offer fall back to its own defaults.
    /// On another machine Nook keeps to the agent you chose there.
    func autoTarget(_ config: NewRunConfig) -> NewRunConfig {
        let chosen = AutoModel.Account(provider: config.provider, profileID: config.profileID)
        guard config.remote == nil, config.lineage == nil,
              let decision = AutoModel.pick(autoCandidates(preferring: chosen),
                                            need: AutoModel.need(prompt: config.task, effort: config.effort)),
              decision.provider != config.provider || decision.profileID != config.profileID else { return config }
        var config = config
        if decision.provider != config.provider {
            config.effort = settings.effort(for: decision.provider)
            config.permission = config.permission.steppedDown(within: decision.provider.capabilities.policies)
            if config.mode == .plan, !decision.provider.capabilities.planMode { config.mode = .agent }
        }
        config.provider = decision.provider
        config.profileID = decision.profileID
        return config
    }

    /// Before a message to a session on Auto: moves it to another agent or account when that fits clearly better (see
    /// `AutoModel.pick`), and says so. Only while it is idle and on this Mac, as a switch of your own.
    func autoMove(_ id: UUID, prompt: String) {
        guard let run = run(id), run.autoModel == true, !run.isRemote, canTransfer(id) else { return }
        let current = AutoModel.Account(provider: run.provider, profileID: run.profileID)
        guard let decision = AutoModel.pick(autoCandidates(preferring: current),
                                            need: AutoModel.need(prompt: prompt, effort: run.effort), current: current),
              decision.provider != run.provider || decision.profileID != run.profileID else { return }
        let windows = usageWindows(run.profileID)
        if case .reject = applySelection(id, provider: decision.provider, profileID: decision.profileID, model: AutoModel.id) { return }
        let full = AutoModel.pressure(windows) == .relaxed ? nil : windows.map(\.percent).max()
        let reason = full.map { tr("auto.reason.full", Int($0.rounded())) } ?? tr("auto.reason." + String(describing: decision.need))
        append(id, RunEvent(kind: .system, text: tr("auto.moved", decision.provider.displayName, reason)))
    }

    /// Sets the model of a session on Auto for the turn about to start, within its agent and account.
    func applyAutoModel(_ id: UUID, prompt: String) {
        guard let run = run(id), run.autoModel == true else { return }
        let account = AutoModel.Account(provider: run.provider, profileID: run.profileID)
        guard let decision = AutoModel.pick(autoCandidates(only: account), need: AutoModel.need(prompt: prompt, effort: run.effort)),
              run.model.isEmpty || !sameModel(decision.model, run.model, for: run.provider) else { return }
        update(id) { $0.model = decision.model }
        let name = modelChoice(decision.model, for: run.provider, profileID: run.profileID)?.name ?? decision.model
        let reason = tr(AutoModel.reasonKey(decision), Int(decision.fullest.rounded()))
        append(id, RunEvent(kind: .system, text: tr("auto.chose", run.provider.displayName + " · " + name, reason)))
    }
}
