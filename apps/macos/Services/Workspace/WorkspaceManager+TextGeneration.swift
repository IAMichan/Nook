import Foundation

/// Text an agent writes for Nook (titles, commit messages, pull requests): the session's own
/// agent when that is Claude Code or Codex, otherwise whichever of the two is connected. Nil when neither is.
extension WorkspaceManager {
    /// `model` is the Claude model (a small one by default); `timeout` how long the call may take.
    func generateText(_ prompt: String, schema: [String: Any], prefer provider: RunProvider?, profileID: String?,
                      cwd: String, model: String? = nil, timeout: TimeInterval = 120) async -> [String: Any]? {
        var order: [RunProvider] = [.claude, .codex]
        if let provider, let index = order.firstIndex(of: provider) { order.insert(order.remove(at: index), at: 0) }
        guard let pick = order.first(where: { executable($0) != nil }), let executable = executable(pick) else { return nil }
        let environment = accountEnvironment(pick == provider ? (profileID ?? pick.kind.rawValue) : pick.kind.rawValue)
        let engine: TextGeneration.Engine = pick == .claude ? .claude : .codex
        return await Task.detached(priority: .utility) {
            TextGenerationRunner.run(engine: engine, executable: executable, environment: environment, prompt: prompt,
                                     schema: schema, cwd: cwd, timeout: timeout, model: model)
        }.value
    }

    /// A title for a new session from its first message, in place of the first line Nook shows until then. It is
    /// dropped when you renamed the session meanwhile.
    func generateTitle(_ id: UUID) {
        guard settings.autoTitles, let run = run(id) else { return }
        let seed = run.title
        Task { [weak self] in
            guard let self else { return }
            let answer = await self.generateText(TextGeneration.titlePrompt(message: run.task), schema: TextGeneration.titleSchema,
                                                 prefer: run.provider, profileID: run.profileID, cwd: run.isRemote ? NSHomeDirectory() : run.workingDirectory)
            guard let raw = answer?["title"] as? String, let title = TextGeneration.title(raw), self.run(id)?.title == seed else { return }
            self.update(id) { $0.title = title }
        }
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
        guard let answer = await generateText(prompt, schema: PullRequestReviewGuide.schema, prefer: nil, profileID: nil,
                                              cwd: NSHomeDirectory(), model: "sonnet", timeout: 300) else { return nil }
        return PullRequestReviewGuide.parse(answer, files: detail.files.map(\.path), headSHA: detail.headSHA)
    }
}
