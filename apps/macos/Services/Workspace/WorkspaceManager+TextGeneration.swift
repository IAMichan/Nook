import Foundation

/// Text Nook asks for (titles, commit messages, pull requests, the suggested next prompt): written by the generator
/// chosen for its task in Settings (`TextGenerator`), by default the session's own agent when that is Claude Code or
/// Codex, otherwise whichever of the two is connected. Nil when none can.
extension WorkspaceManager {
    /// `task` picks the generator (nil: always an agent, as for review guides, which read the whole diff); `model` is
    /// the Claude model of the agent route (a small one by default); `timeout` how long the call may take.
    func generateText(_ prompt: String, schema: [String: Any], task: TextTask?, prefer provider: RunProvider?, profileID: String?,
                      cwd: String, model: String? = nil, timeout: TimeInterval = 120) async -> [String: Any]? {
        if let task, case .api(let api, let apiModel, let key) = TextGenerationRoute.resolve(settings.textGenerator(for: task),
                                                                                            key: { SecretStore.read($0.keyAccount) }) {
            // A failed request leaves the text to the caller's fallback, as an agent that gave no answer does: a key
            // you chose for this should not quietly turn into a run on your subscription.
            return try? await TextGeneratorAPI.generate(provider: api, model: apiModel, key: key, prompt: prompt, schema: schema,
                                                        maxTokens: task.maxTokens, timeout: min(timeout, 90))
        }
        return await generateWithAgent(prompt, schema: schema, prefer: provider, profileID: profileID, cwd: cwd, model: model,
                                       timeout: timeout)
    }

    private func generateWithAgent(_ prompt: String, schema: [String: Any], prefer provider: RunProvider?, profileID: String?,
                                   cwd: String, model: String?, timeout: TimeInterval) async -> [String: Any]? {
        var order: [RunProvider] = [.claude, .codex]
        if let provider, let index = order.firstIndex(of: provider) { order.insert(order.remove(at: index), at: 0) }
        guard let pick = order.first(where: { executable($0) != nil }), let executable = executable(pick) else { return nil }
        let environment = accountEnvironment(pick == provider ? (profileID ?? pick.kind.rawValue) : pick.kind.rawValue)
        let engine: TextGeneration.Engine = pick == .claude ? .claude : .codex
        let work = Task.detached(priority: .utility) {
            await TextGenerationRunner.run(engine: engine, executable: executable, environment: environment, prompt: prompt,
                                     schema: schema, cwd: cwd, timeout: timeout, model: model)
        }
        // A detached task does not inherit cancellation: pass it on, so a cancelled request stops its agent process.
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    /// A title for a new session from its first message, in place of the first line Nook shows until then. It is
    /// dropped when you renamed the session meanwhile. With the user's title rules (Settings, or the project's own). The
    /// same answer names the session's worktree branch in English, in place of the words Nook took from the prompt (see
    /// `renameBranch`).
    func generateTitle(_ id: UUID) {
        guard let run = run(id) else { return }
        let renamesBranch = !run.isRemote && run.worktreePath != nil && run.branch.flatMap { WorktreeNaming.renamedBranch($0, slug: "x") } != nil
        guard settings.autoTitles || renamesBranch else { return }
        writeTitle(run, later: [], announce: false, renamesBranch: renamesBranch)
    }

    /// "Regenerate title" from the session menu or the command palette: a new title from the first message and the
    /// latest ones, also when automatic titles are off. Says so when no agent could write one. The branch keeps its name.
    func regenerateTitle(_ id: UUID) {
        guard let run = run(id), !regeneratingTitles.contains(id) else { return }
        loadTimeline(id)
        let messages = timeline(id).filter { $0.kind == .user }.map(\.text)
        // The first message is the task itself; what came after says where the session went.
        writeTitle(run, later: Array(messages.dropFirst()), announce: true, renamesBranch: false)
    }

    private func writeTitle(_ run: WorkspaceRun, later: [String], announce: Bool, renamesBranch: Bool) {
        let id = run.id
        let seed = run.title
        let instructions = settings.sessionDefaults(for: run.projectPath.isEmpty ? run.workingDirectory : run.projectPath).titleInstructions
        let prompt = TextGeneration.titlePrompt(message: run.task, later: later, instructions: instructions)
        if announce { regeneratingTitles.insert(id) }
        Task { [weak self] in
            guard let self else { return }
            let answer = await self.generateText(prompt, schema: TextGeneration.titleSchema, task: .titles, prefer: run.provider, profileID: run.profileID,
                                                 cwd: run.isRemote ? NSHomeDirectory() : run.workingDirectory)
            if announce { self.regeneratingTitles.remove(id) }
            if renamesBranch, let raw = answer?["branch"] as? String, let slug = TextGeneration.branchSlug(raw) {
                await self.renameBranch(id, from: run.branch ?? "", slug: slug)
            }
            // A title written on its own only with automatic titles on; one you asked for always.
            guard announce || self.settings.autoTitles else { return }
            guard let raw = answer?["title"] as? String, let title = TextGeneration.title(raw) else {
                if announce { ToastCenter.shared.error(tr("ws.title.regenerateFailed")) }
                return
            }
            guard self.run(id)?.title == seed else { return }
            self.update(id) { $0.title = title }
        }
    }

    /// Gives a worktree session's branch the agent-written slug once its worktree exists, as long as the branch is
    /// still the one Nook named and was never pushed. The worktree's folder keeps its name: the agent is working in it.
    func renameBranch(_ id: UUID, from branch: String, slug: String) async {
        guard let git = gitService, let new = WorktreeNaming.renamedBranch(branch, slug: slug) else { return }
        while run(id)?.status == .preparing { try? await Task.sleep(for: .milliseconds(250)) }
        guard let run = run(id), run.branch == branch, let root = run.repoRoot, run.worktreePath != nil else { return }
        let renamed = (try? await FolderLease.shared.run(FolderLease.key(root), priority: .utility) {
            try git.renameUnpublishedBranch(branch, to: new, in: root)
        }) != nil
        guard renamed, self.run(id)?.branch == branch else { return }
        update(id) { $0.branch = new }
        append(id, RunEvent(kind: .system, text: tr("ws.event.branchRenamed", new)))
    }
}

extension WorkspaceManager {
    /// A review guide for a pull request (`PullRequestReviewGuide`), written by Claude Code (a larger model, it reads the
    /// whole diff) or Codex from what GitHub returned, without tools and outside any project folder. Nil when neither
    /// agent is connected or the answer holds no stop.
    func writeReviewGuide(_ detail: PullRequestDetail) async -> PullRequestReviewGuide? {
        let instructions = UserDefaults.standard.string(forKey: PullRequestReviewGuides.instructionsKey) ?? ""
        let prompt = PullRequestReviewGuide.prompt(
            title: detail.title, body: detail.body, base: detail.baseBranch, head: detail.headBranch,
            commits: detail.commits.map { "\($0.shortSHA) \($0.subject)" },
            files: detail.files.map { ($0.path, $0.status, $0.patch) }, instructions: instructions)
        guard let answer = await generateText(prompt, schema: PullRequestReviewGuide.schema, task: nil, prefer: nil, profileID: nil,
                                              cwd: NSHomeDirectory(), model: "sonnet", timeout: 300) else { return nil }
        return PullRequestReviewGuide.parse(answer, files: detail.files.map(\.path), headSHA: detail.headSHA)
    }
}
