import Foundation

/// What you choose on a suggested session's card (`SessionSuggestion`, `SessionSuggestionCard`).
@MainActor
extension AppModel {
    func chooseSuggestion(_ choice: SessionSuggestion.Choice, event: RunEvent, in runID: UUID) {
        guard event.state == .pending, let suggestion = SessionSuggestion(event: event), let run = workspace.run(runID) else { return }
        switch choice {
        case .dismiss:
            workspace.mutateEvent(runID, event.id) { $0.state = .denied }
        case .here:
            // As if you typed it: it waits in line behind a running turn, like any message of yours.
            workspace.submit(runID, text: suggestion.prompt, fromYou: true)
            workspace.mutateEvent(runID, event.id) { $0.state = .allowed }
        case .options:
            // The new-session composer on this project's draft, with the prompt to read and change before you start it.
            PromptLinkInbox.shared.requestProject(WorktreeOrigin.checkoutPath(of: run.projectPath), text: suggestion.prompt)
            viewModel.selectedAgentID = "new"
        case .start:
            workspace.mutateEvent(runID, event.id) { $0.state = .running }
            Task { await startSuggestion(suggestion, event: event, from: run) }
        }
    }

    /// A new session beside the one that suggested it: the same project, the same agent and account unless the suggestion
    /// names another, and the folder's own choices for the rest.
    private func startSuggestion(_ suggestion: SessionSuggestion, event: RunEvent, from run: WorkspaceRun) async {
        let folder = WorktreeOrigin.checkoutPath(of: run.projectPath)
        let defaults = workspace.settings.sessionDefaults(for: folder)
        let provider = RunProvider.named(suggestion.agent) ?? run.provider
        var config = NewRunConfig()
        config.task = suggestion.prompt
        config.title = suggestion.title
        config.provider = provider
        config.projectPath = folder
        config.worktreeRoot = workspace.settings.worktreeRoot
        if provider == run.provider {
            config.profileID = run.profileID
            config.model = run.model
            config.effort = run.effort
            config.permission = run.permission
        } else {
            config.profileID = (connectedProfiles(for: provider).first ?? profiles.preferredProfile(provider.kind)).id
            config.model = defaults.model(for: provider)
            config.permission = defaults.permission(for: provider)
        }
        config.mode = .agent
        config.startedBy = tr("ws.event.startedByIn", run.provider.displayName, run.title)
        switch suggestion.worktree {
        case .some(true): config.isolation = .worktree
        case .some(false): config.isolation = .folder
        case .none: config.isolation = defaults.isolation
        }
        if config.isolation == .worktree {
            config.branchName = WorktreeNaming.branchName(task: suggestion.title, id: UUID())
            let git = workspace.gitService
            config.baseBranch = await Task.detached(priority: .userInitiated) { git?.currentBranch(folder) ?? "" }.value
        }
        do {
            // You chose Start on the card: a second agent beside this one is the point.
            let id = try await workspace.start(config, allowSharedFolder: true)
            workspace.mutateEvent(run.id, event.id) {
                $0.state = .done
                $0.output = id.uuidString
            }
            ToastCenter.shared.success(tr("suggest.started"), detail: suggestion.title,
                                       action: NookToastAction(title: tr("suggest.open")) { [weak self] in
                                           self?.viewModel.selectedAgentID = "run:" + id.uuidString
                                       })
        } catch {
            workspace.mutateEvent(run.id, event.id) { $0.state = .pending }
            ToastCenter.shared.error(error, title: tr("suggest.failed"))
        }
    }
}
