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
                // A patch names its files from the session's folder (Codex's apply_patch).
                let cwd = run(id)?.workingDirectory ?? ""
                for change in ToolSummary.fileChanges(tool: name, input: input?.dictionary ?? [:]) {
                    let path = SessionProjects.absolute(change.path, cwd: cwd)
                    if recorded.insert(path).inserted { recordFileChange(id, path: path, kind: change.kind) }
                }
                for path in paths where recorded.insert(path).inserted { recordFileChange(id, path: path, kind: "modified") }
                // The agent merged or closed a pull request from the shell: its state shows now, for every agent alike.
                if let input {
                    let texts = PullRequestToolCall.texts(in: input.object)
                    if PullRequestToolCall.closesPullRequest(command: texts) { PullRequestSync.shared.recheck(id) }
                    // A pull request the agent works on with the forge's CLI joins the session's list, for every agent alike.
                    noticePullRequests(id, PullRequestMentions.inCommand(texts), mustExist: false)
                    // A worktree the agent made itself: the session may move there when the turn ends.
                    if let cwd = run(id)?.workingDirectory,
                       let added = texts.lazy.compactMap({ WorktreeMove.added(in: $0, cwd: cwd) }).first {
                        addedWorktrees[id] = added
                    }
                }
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

// A worktree the agent made with `git worktree add` and works in (`WorktreeMove`): the session follows it, so its branch,
// changes and pull request show. The same for every agent.
extension WorkspaceManager {
    /// At the end of a turn: the session moves to the worktree the agent made during it, when its own worktree is gone or
    /// the agent changed files in the new one. The branch it leaves stays listed above the composer with its pull request
    /// (`followBranch`, through the next git read).
    func followAddedWorktree(_ id: UUID) {
        guard let added = addedWorktrees.removeValue(forKey: id), let run = run(id), !run.isRemote,
              run.isolation == .worktree, let repo = run.repoRoot, let git = sessionGit(for: run),
              WorktreeMove.normalize(added) != WorktreeMove.normalize(run.workingDirectory) else { return }
        let own = run.worktreePath ?? run.workingDirectory
        let start = timeline(id).lastIndex { $0.kind == .user } ?? 0
        let changed = timeline(id)[start...].compactMap { $0.kind == .fileChange ? $0.detail : nil }
        Task { @MainActor [weak self] in
            let checks = await Task.detached(priority: .utility) { () -> (own: Bool, sameRepo: Bool) in
                func commonDir(_ folder: String) -> String? {
                    (try? git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: folder))
                        .map { WorktreeMove.normalize($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                }
                let fm = FileManager.default
                let ownIsCheckout = fm.fileExists(atPath: (own as NSString).appendingPathComponent(".git"))
                guard fm.fileExists(atPath: (added as NSString).appendingPathComponent(".git")),
                      let new = commonDir(added), new == commonDir(repo) else { return (ownIsCheckout, false) }
                return (ownIsCheckout, true)
            }.value
            guard let self, checks.sameRepo, self.run(id)?.workingDirectory == run.workingDirectory,
                  WorktreeMove.follows(ownIsCheckout: checks.own, added: added, changedFiles: changed) else { return }
            self.update(id) {
                $0.workingDirectory = added
                $0.worktreePath = added
                if $0.statusDetail == "worktreeRemoved" { $0.statusDetail = nil }
            }
            self.append(id, RunEvent(kind: .system, text: tr("ws.event.worktreeFollowed", AgentPathFormat.tilde(added))))
            self.git[id] = nil
            self.refreshGit(id, quiet: true)
            self.refreshWorktrees()
        }
    }
}

// The pull requests a session works on besides its own branch's (`PullRequestMentions`): linked to it, so the tray above
// its composer shows them with their state and checks.
extension WorkspaceManager {
    /// At most this many from one message or command: a pasted list of links is not a list of work.
    private static let mentionsPerEvent = 6

    func noticePullRequests(_ id: UUID, _ refs: [PullRequestRef], mustExist: Bool) {
        guard !refs.isEmpty, let run = run(id) else { return }
        let directory = run.workingDirectory
        let key = PullRequestSync.sessionKey(run: id, directory: directory)
        Task { @MainActor in
            let sync = PullRequestSync.shared
            let repository = await sync.repository(directory: directory)
            for ref in refs.prefix(Self.mentionsPerEvent) {
                guard let host = ref.host ?? repository?.host, let path = ref.repository ?? repository?.path else { continue }
                let id = PullRequestLink(host: host, repository: path, number: ref.number).id
                guard !sync.knows(id, session: key) else { continue }
                if let link = await PullRequestResolver.resolve(ref, repository: repository, mustExist: mustExist) {
                    sync.mention(link, session: key)
                }
            }
        }
    }
}
