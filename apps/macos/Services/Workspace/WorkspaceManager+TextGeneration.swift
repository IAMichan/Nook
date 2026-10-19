import Foundation

/// Text an agent writes for Nook (titles, commit messages, pull requests): the session's own
/// agent when that is Claude Code or Codex, otherwise whichever of the two is connected. Nil when neither is.
extension WorkspaceManager {
    func generateText(_ prompt: String, schema: [String: Any], prefer provider: RunProvider?, profileID: String?,
                      cwd: String) async -> [String: Any]? {
        var order: [RunProvider] = [.claude, .codex]
        if let provider, let index = order.firstIndex(of: provider) { order.insert(order.remove(at: index), at: 0) }
        guard let pick = order.first(where: { executable($0) != nil }), let executable = executable(pick) else { return nil }
        let environment = accountEnvironment(pick == provider ? (profileID ?? pick.kind.rawValue) : pick.kind.rawValue)
        let engine: TextGeneration.Engine = pick == .claude ? .claude : .codex
        return await Task.detached(priority: .utility) {
            TextGenerationRunner.run(engine: engine, executable: executable, environment: environment, prompt: prompt,
                                     schema: schema, cwd: cwd)
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
