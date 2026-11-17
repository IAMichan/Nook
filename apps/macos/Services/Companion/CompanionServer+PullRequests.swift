import Foundation

/// Pull requests on the iPhone companion (docs/COMPANION.md, "Pull requests"): the list of Agents › Pull requests, a
/// session's linked pull requests, one pull request in full, and what the phone may do to it. The Mac reads the forge
/// with its own accounts (GitHub, or the forge's own client for GitLab, Gitea, Bitbucket, Azure DevOps and GitCafe) and
/// keeps the rules of its own page: a merge goes only at the head the phone saw and only when the quick merge would
/// allow it (`PullRequestQuickRunner.blocker`), every action is the phone's own tap and lands in the audit log.
extension CompanionServer {
    // MARK: Lists

    /// The Mac's pull request list, or with `session` the pull requests linked to that session.
    func pulls(_ request: CompanionRequest, app: AppModel) -> CompanionResponse {
        if let session = request.session {
            guard let runID = UUID(uuidString: session), let run = app.workspace.run(runID) else {
                // An agent outside Nook has no linked list the phone can ask for (its folder's list is on the Mac).
                if CompanionAgents.handles(session) { return CompanionResponse(id: request.id, ok: true, pulls: []) }
                return .failure(request.id, .unknownSession)
            }
            let linked = PullRequestSync.shared.linked(run: runID, directory: run.workingDirectory, branch: run.branch)
            return CompanionResponse(id: request.id, ok: true, pulls: linked.map { Self.digest($0.link) })
        }
        // A list older than half a minute is read again in the background; this answer is what the Mac has now.
        Task { await PullRequestStore.shared.refresh() }
        var rows: [PullDigest] = []
        for account in PullRequestStore.shared.accounts where account.error == nil {
            rows += account.mine.map { Self.digest($0, group: .mine) }
            rows += account.reviews.map { Self.digest($0, group: .review) }
            rows += account.watched.map { Self.digest($0, group: .watched) }
        }
        return CompanionResponse(id: request.id, ok: true, pulls: PullDigest.trimmed(rows))
    }

    static func digest(_ item: PullRequestItem, group: PullDigest.Group) -> PullDigest {
        PullDigest(url: item.url?.absoluteString ?? "https://github.com/\(item.repo)/pull/\(item.number)", repo: item.repo,
                   number: item.number, title: CompanionPolicy.excerpt(item.title), author: item.author,
                   state: item.state == .open ? (item.draft ? "draft" : "open") : item.state.rawValue, ci: item.ci.rawValue,
                   review: item.review.rawValue, conflict: item.conflict, additions: item.additions, deletions: item.deletions,
                   updated: item.updated?.timeIntervalSince1970, group: group.rawValue, headBranch: item.headBranch,
                   baseBranch: item.baseBranch, labels: item.labels.isEmpty ? nil : Array(item.labels.prefix(12)),
                   labelColors: item.labelColors.isEmpty ? nil : item.labelColors.filter { item.labels.prefix(12).contains($0.key) },
                   created: item.created?.timeIntervalSince1970, comments: item.comments, checksPassed: item.checksPassed,
                   checksTotal: item.checksTotal)
    }

    static func digest(_ link: PullRequestLink) -> PullDigest {
        let status = URL(string: link.url).flatMap { PullRequestStatusStore.shared.status($0) }
        let ci: String
        switch status?.checks {
        case "failure": ci = "failing"
        case "pending": ci = "pending"
        case "success": ci = "passing"
        default: ci = "unknown"
        }
        return PullDigest(url: link.url, repo: link.repository, number: link.number,
                          title: CompanionPolicy.excerpt(link.title ?? ""), author: "", state: link.state.rawValue, ci: ci,
                          review: "none", conflict: link.hasConflict, additions: nil, deletions: nil,
                          updated: link.updatedAt?.timeIntervalSince1970, group: PullDigest.Group.linked.rawValue,
                          headBranch: link.headBranch, baseBranch: link.baseBranch)
    }

    // MARK: One pull request

    /// One pull request in full: its summary, checks and files with their patches and viewed marks.
    func pull(_ request: CompanionRequest, app: AppModel) async -> CompanionResponse {
        guard let reader = PullReader(app: app, address: request.item) else { return .failure(request.id, .unknownItem) }
        do {
            let detail = try await reader.read()
            var marks = PullRequestViewedFiles.load()
            PullRequestViewedSync.adopt(detail, accountID: reader.account, marks: &marks)
            return CompanionResponse(id: request.id, ok: true, pull: Self.digest(detail, url: reader.url, github: reader.isGitHub))
        } catch {
            return .failure(request.id, .failed, message: error.localizedDescription)
        }
    }

    /// What the phone asks of a pull request: a review (with comments on lines), a viewed mark, or a merge. A merge or a
    /// review of a pull request that moved on since the phone read it is refused, so nothing lands unseen.
    func pullAct(_ request: CompanionRequest, app: AppModel) async -> CompanionResponse {
        guard let action = request.pullAction, action.isValid else { return .failure(request.id, .badRequest) }
        guard let reader = PullReader(app: app, address: request.item) else { return .failure(request.id, .unknownItem) }
        do {
            switch action.kind {
            case .viewed, .unviewed:
                let detail = try await reader.read()
                guard let file = detail.files.first(where: { $0.path == action.path }) else { return .failure(request.id, .unknownItem) }
                var marks = PullRequestViewedFiles.load()
                PullRequestViewedSync.adopt(detail, accountID: reader.account, marks: &marks)
                PullRequestViewedSync.toggle(action.kind == .viewed, file: file, detail: detail, accountID: reader.account, marks: &marks)
                return CompanionResponse(id: request.id, ok: true, pull: Self.digest(detail, url: reader.url, github: reader.isGitHub))
            case .approve, .requestChanges, .comment:
                let detail = try await reader.read()
                if let head = action.head, !head.isEmpty, head != detail.headSHA {
                    return .failure(request.id, .failed, message: tr("companion.phone.pr.movedOn"))
                }
                let verdict: PullRequestAction.Verdict = action.kind == .approve ? .approve : action.kind == .requestChanges ? .requestChanges : .comment
                if verdict != .comment, !detail.features.verdicts { return .failure(request.id, .notAllowedFromPhone) }
                let notes = (action.comments ?? []).map {
                    PullRequestAction.LineComment(path: $0.path, line: $0.line, side: $0.side, body: $0.body,
                                                  startLine: $0.startLine, startSide: $0.startLine == nil ? nil : $0.side)
                }
                if !notes.isEmpty, !detail.features.lineComments { return .failure(request.id, .notAllowedFromPhone) }
                let review: PullRequestAction = notes.isEmpty
                    ? .review(verdict, body: action.reviewBody)
                    : .reviewWithComments(verdict, body: action.reviewBody, commit: detail.headSHA, comments: notes)
                try await reader.perform(review, detail: detail)
                audit("pr_review", "\(detail.repo)#\(detail.number) · \(verdict.rawValue)" + (notes.isEmpty ? "" : " · \(notes.count) comments"))
                let fresh = try await reader.read()
                return CompanionResponse(id: request.id, ok: true, pull: Self.digest(fresh, url: reader.url, github: reader.isGitHub))
            case .merge:
                let merged = try await reader.merge(head: action.head ?? "", method: action.method.flatMap(PullRequestMergeMethod.init(rawValue:)))
                audit("pr_merge", merged)
                let fresh = try? await reader.read()
                return CompanionResponse(id: request.id, ok: true, message: "merged",
                                         pull: fresh.map { Self.digest($0, url: reader.url, github: reader.isGitHub) })
            case .close, .reopen, .ready, .draft, .autoMergeOn, .autoMergeOff, .updateBranch, .rebaseBranch, .rerunFailed,
                 .deleteBranch, .note, .reply, .resolve, .unresolve:
                return try await menuAction(action, request: request, reader: reader)
            }
        } catch {
            return .failure(request.id, .failed, message: error.localizedDescription)
        }
    }

    /// "Work on this pull request": its branch checked out in a worktree of its own in the folder where this Mac has the
    /// repository, and a session started there with the agent and words from the phone, kept to asking permission as
    /// every session started from the phone is.
    func pullWork(_ request: CompanionRequest, app: AppModel) async -> CompanionResponse {
        guard let work = request.pullWork, let provider = RunProvider(rawValue: work.agent),
              launchableProviders(app).contains(provider) else { return .failure(request.id, .badRequest) }
        // Started before (a retry after a restart of Nook): the same session, not a second worktree and session.
        let command = SessionCommand.phone(request.id)
        if let earlier = app.workspace.commandReceipt(command), let created = earlier.created {
            return CompanionResponse(id: request.id, ok: true, sessions: digests(app), created: created)
        }
        guard let reader = PullReader(app: app, address: work.url) else { return .failure(request.id, .unknownItem) }
        do {
            let detail = try await reader.read()
            let host = PullRequestRef.parse(reader.url.absoluteString)?.host ?? .github
            let plan = PullRequestCheckoutPlan(host: host, repository: detail.repo, number: detail.number,
                                               headBranch: detail.headBranch, fork: detail.headOwner != nil)
            let ref = SessionPullRequestRef(number: detail.number, title: detail.title, url: reader.url.absoluteString,
                                            headBranch: detail.headBranch, baseBranch: detail.baseBranch)
            let words = CompanionPolicy.cleanMessage(work.task) ?? SessionPrompts.checkedOut(ref)
            let path = try await app.pullRequestWorktree(plan, preferred: nil)
            var config = app.sessionConfig(task: words, provider: provider, folder: path, plan: false)
            config.projectPath = path
            config.worktreeRoot = app.workspace.settings.worktreeRoot
            if let model = work.model, app.models(for: provider).contains(model) { config.model = model }
            config.permission = phonePermission(provider, preferred: config.permission, plan: false)
            let id = try await app.workspace.start(config, allowSharedFolder: false)
            app.workspace.recordCommand(command, .started, created: id.uuidString)
            audit("pr_work", "\(detail.repo)#\(detail.number) · \(provider.displayName)")
            return CompanionResponse(id: request.id, ok: true, sessions: digests(app), created: id.uuidString)
        } catch {
            return .failure(request.id, .failed, message: error.localizedDescription)
        }
    }

    /// One of the Mac's menu actions (`PullDetailDigest.actions`), only when its menu would offer it now; the branch
    /// actions only at the head the phone saw. Answered with the pull request as it is after it.
    private func menuAction(_ action: CompanionPullAction, request: CompanionRequest, reader: PullReader) async throws -> CompanionResponse {
        let detail = try await reader.read()
        guard PullActionRules.allowed(Self.facts(detail, github: reader.isGitHub)).contains(action.kind) else {
            return .failure(request.id, .notAllowedFromPhone)
        }
        if [.updateBranch, .rebaseBranch].contains(action.kind), action.head != detail.headSHA {
            return .failure(request.id, .failed, message: tr("companion.phone.pr.movedOn"))
        }
        let body = action.reviewBody
        let target = "\(detail.repo)#\(detail.number)"
        switch action.kind {
        case .rerunFailed:
            try await reader.rerunFailed(Self.failedRuns(detail), repo: detail.repo)
        case .reply, .resolve, .unresolve:
            let thread = Self.conversation(detail).1.first { $0.id == action.thread }
            let opener = detail.events.first { $0.id == action.thread }
            guard let thread, let opener else { return .failure(request.id, .unknownItem) }
            if action.kind == .reply {
                guard thread.canReply, let rest = opener.restComment else { return .failure(request.id, .notAllowedFromPhone) }
                try await reader.perform(.reply(to: rest.id, body: body), detail: detail)
            } else {
                let id = opener.threadID ?? detail.events.first { ($0.replyTo == opener.id) && $0.threadID != nil }?.threadID
                guard thread.canResolve, let id else { return .failure(request.id, .notAllowedFromPhone) }
                try await reader.perform(.setThreadResolved(threadID: id, resolved: action.kind == .resolve), detail: detail)
            }
        default:
            guard let mapped = Self.forgeAction(action, detail: detail) else { return .failure(request.id, .badRequest) }
            try await reader.perform(mapped, detail: detail)
        }
        audit("pr_" + action.kind.rawValue, target)
        let fresh = try await reader.read()
        return CompanionResponse(id: request.id, ok: true, pull: Self.digest(fresh, url: reader.url, github: reader.isGitHub))
    }

    /// The forge action of a menu action from the phone; nil for one that is not a single forge call.
    static func forgeAction(_ action: CompanionPullAction, detail: PullRequestDetail) -> PullRequestAction? {
        switch action.kind {
        case .close: return .close
        case .reopen: return .reopen
        case .ready: return .markReady(nodeID: detail.nodeID)
        case .draft: return .markDraft(nodeID: detail.nodeID)
        case .autoMergeOn:
            let preferred = PullRequestMergeMethod(rawValue: UserDefaults.standard.string(forKey: "agents.pr.mergeMethod") ?? "") ?? .merge
            guard let method = action.method.flatMap(PullRequestMergeMethod.init(rawValue:)).flatMap({ detail.methods.contains($0) ? $0 : nil })
                    ?? PullRequestQuickAction.mergeMethod(preferred: preferred, allowed: detail.methods) else { return nil }
            return .enableAutoMerge(nodeID: detail.nodeID, method: method)
        case .autoMergeOff: return .disableAutoMerge(nodeID: detail.nodeID)
        case .updateBranch: return .updateBranch(headSHA: detail.headSHA)
        case .rebaseBranch: return .rebaseBranch(nodeID: detail.nodeID, headSHA: detail.headSHA)
        case .deleteBranch: return detail.headRepository.map { .deleteBranch(repository: $0, branch: detail.headBranch) }
        case .note: return .comment(action.reviewBody)
        case .approve, .requestChanges, .comment, .merge, .viewed, .unviewed, .rerunFailed, .reply, .resolve, .unresolve: return nil
        }
    }

    // MARK: Digests

    static func digest(_ detail: PullRequestDetail, url: URL, github: Bool = true, viewed: PullRequestViewedFiles = .load(),
                       now: Date = Date()) -> PullDetailDigest {
        let key = PullRequestViewedFiles.key(repo: detail.repo, number: detail.number)
        let files = detail.files.map { file -> PullDetailDigest.File in
            let mark: String
            switch viewed.status(file, in: key) {
            case .viewed: mark = "viewed"
            case .changed: mark = "changed"
            case .unviewed: mark = "unviewed"
            }
            return PullDetailDigest.File(path: file.path, status: file.status, additions: file.additions, deletions: file.deletions,
                                         patch: file.patch, truncated: false, viewed: mark)
        }
        let preferred = PullRequestMergeMethod(rawValue: UserDefaults.standard.string(forKey: "agents.pr.mergeMethod") ?? "") ?? .merge
        let methods = detail.methods.sorted { ($0 == preferred ? 0 : 1) < ($1 == preferred ? 0 : 1) }.map(\.rawValue)
        var digest = PullDetailDigest(
            url: url.absoluteString, repo: detail.repo, number: detail.number, title: CompanionPolicy.clip(detail.title, limit: 300),
            body: CompanionPolicy.clip(detail.body, limit: PullDetailDigest.maxBody), author: detail.author,
            state: detail.state.rawValue, baseBranch: detail.baseBranch, headBranch: detail.headBranch, headSHA: detail.headSHA,
            additions: detail.additions, deletions: detail.deletions, changedFiles: detail.changedFiles,
            updated: detail.updated?.timeIntervalSince1970,
            checks: detail.checks.prefix(PullDetailDigest.maxChecks).map {
                PullDetailDigest.Check(name: CompanionPolicy.clip($0.name, limit: 200), outcome: $0.outcome.rawValue,
                                       detail: CompanionPolicy.clip($0.detail, limit: 200))
            },
            files: PullDetailDigest.budgeted(files),
            verdicts: detail.verdicts.map { PullDetailDigest.Verdict(author: $0.author, approved: $0.approved) },
            methods: methods, blocker: blocker(detail)?.rawValue, verdictsAllowed: detail.features.verdicts,
            lineComments: detail.features.lineComments, fetched: now.timeIntervalSince1970)
        digest.reviewers = detail.requestedReviewers + detail.requestedTeams.map { "@" + $0 }
        digest.assignees = detail.assignees
        digest.labels = detail.labels
        digest.labelColors = detail.labelColors.isEmpty ? nil : detail.labelColors
        digest.milestone = detail.milestone
        digest.issues = detail.linkedIssues.prefix(20).map {
            PullDetailDigest.Issue(repo: $0.repo, number: $0.number, title: CompanionPolicy.clip($0.title, limit: 200), open: $0.open,
                                   url: $0.url?.absoluteString)
        }
        digest.autoMerge = detail.autoMerge.map { PullDetailDigest.AutoMerge(method: $0.method?.rawValue, by: $0.enabledBy) }
        digest.behind = detail.mergeState == "behind"
        digest.branchDeleted = detail.branchDeleted
        digest.created = detail.created?.timeIntervalSince1970
        digest.actions = PullActionRules.allowed(facts(detail, github: github)).map(\.rawValue)
        let (notes, threads) = conversation(detail)
        digest.conversation = notes
        digest.threads = threads
        return digest
    }

    /// What decides which of the Mac's menu actions the pull request takes now (`PullActionRules`), as its menu reads it.
    static func facts(_ detail: PullRequestDetail, github: Bool) -> PullActionRules.Facts {
        PullActionRules.Facts(state: detail.state.rawValue, hasNodeID: !detail.nodeID.isEmpty, canPush: detail.canPush,
                              conflicted: detail.conflicted, behind: detail.mergeState == "behind", autoMergeOn: detail.autoMerge != nil,
                              autoMergeAllowed: detail.autoMergeAllowed, hasHeadRepository: detail.headRepository != nil,
                              branchDeleted: detail.branchDeleted, failedRuns: github ? failedRuns(detail).count : 0,
                              draft: detail.features.draft, autoMerge: detail.features.autoMerge,
                              updateBranch: detail.features.updateBranch, deleteBranch: detail.features.deleteBranch,
                              threads: detail.features.threads, rerun: github)
    }

    /// The workflow runs of the failing checks, each once: what "Rerun failed checks" runs again.
    static func failedRuns(_ detail: PullRequestDetail) -> [Int] {
        var seen = Set<Int>()
        return detail.checks.compactMap { check -> Int? in
            guard check.outcome == .failing, let path = check.url?.path,
                  let found = path.range(of: #"/actions/runs/\d+"#, options: .regularExpression),
                  let id = Int(path[found].split(separator: "/").last ?? "") else { return nil }
            return seen.insert(id).inserted ? id : nil
        }
    }

    /// The conversation (comments, and reviews with words) and the threads on lines, as the Mac's Conversation tab
    /// reads them, oldest first and cut to fit one answer.
    static func conversation(_ detail: PullRequestDetail) -> ([PullDetailDigest.Note], [PullDetailDigest.Thread]) {
        func note(_ event: PullRequestEvent, verdict: String? = nil) -> PullDetailDigest.Note {
            PullDetailDigest.Note(id: event.id, author: event.author,
                                  body: CompanionPolicy.clip(event.body, limit: PullDetailDigest.maxNoteBody),
                                  date: event.date?.timeIntervalSince1970, verdict: verdict)
        }
        var notes: [PullDetailDigest.Note] = []
        var threads: [PullDetailDigest.Thread] = []
        var index: [String: Int] = [:]
        for event in detail.events {
            switch event.kind {
            case .comment:
                notes.append(note(event))
            case .review(let state):
                if !event.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state != "COMMENTED" {
                    notes.append(note(event, verdict: state))
                }
            case .lineComment(let path, let line):
                let root = event.replyTo ?? event.id
                if let at = index[root] {
                    threads[at].comments.append(note(event))
                    if event.threadID != nil, !threads[at].canResolve { threads[at].canResolve = detail.features.threads }
                } else {
                    index[root] = threads.count
                    threads.append(PullDetailDigest.Thread(
                        id: root, path: path, line: line, resolved: event.resolved, outdated: event.outdated,
                        canReply: detail.features.threads && event.replyTo == nil && event.restComment != nil,
                        canResolve: detail.features.threads && event.threadID != nil, comments: [note(event)]))
                }
            default:
                break
            }
        }
        return (Array(notes.suffix(PullDetailDigest.maxNotes)), Array(threads.suffix(PullDetailDigest.maxThreads)))
    }

    /// Why the phone cannot merge it, from the quick merge's own rule (`PullRequestQuickRunner.blocker`).
    static func blocker(_ detail: PullRequestDetail) -> PullMergeBlocker? {
        guard let key = PullRequestQuickRunner.blocker(detail) else { return nil }
        return PullMergeBlocker(rawValue: String(key.split(separator: ".").last ?? ""))
    }
}

/// Reads and acts on one pull request the way the Mac's own page does: with the forge client for its host, else GitHub
/// with the account that lists it.
@MainActor
struct PullReader {
    let url: URL
    let account: String
    let item: PullRequestItem
    private let forge: PullRequestForgeClient?

    init?(app: AppModel, address: String?) {
        guard let address, let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let open = app.pullRequestRequest(for: url) else { return nil }
        self.url = url
        account = open.account
        item = open.item
        forge = PullRequestForges.client(account: open.account, path: open.item.repo)
    }

    /// GitHub itself, not another forge's client: what workflow runs need.
    var isGitHub: Bool { forge == nil }

    private func token() throws -> String {
        if forge != nil { return "" }
        guard let token = GitHubPullRequestDetail.token(accountID: account) else { throw NookError(tr("agents.pr.noToken")) }
        return token
    }

    /// The summary and the activity (files with patches, reviews), as the page shows them; the Mac's list and badges
    /// learn what it read too.
    func read() async throws -> PullRequestDetail {
        let token = try token()
        let forge = forge, repo = item.repo, number = item.number
        async let activity = Task.detached(priority: .userInitiated) { () -> PullRequestActivity in
            if let forge { return await forge.activityWithViewed(number: number) }
            return await GitHubPullRequestDetail.loadActivity(repo: repo, number: number, token: token, counts: nil)
        }.value
        var detail = try await Task.detached(priority: .userInitiated) { () -> PullRequestDetail in
            if let forge { return try await forge.summary(number: number) }
            return try await GitHubPullRequestDetail.summary(repo: repo, number: number, token: token)
        }.value
        detail.apply(await activity)
        PullRequestStore.shared.update(with: detail)
        PullRequestStatusStore.shared.record(detail)
        return detail
    }

    /// One action, written to the action log as the page writes it.
    func perform(_ action: PullRequestAction, detail: PullRequestDetail) async throws {
        let token = try token()
        let args = action.auditArgs(repo: detail.repo, number: detail.number)
        do {
            if let forge {
                _ = try await forge.perform(action, number: detail.number, detail: detail)
            } else {
                _ = try await GitHubPullRequestDetail.perform(action, repo: detail.repo, number: detail.number, token: token)
            }
            AppModel.shared.store.audit(tool: action.auditTool, args: args, result: "ok")
        } catch {
            AppModel.shared.store.audit(tool: action.auditTool, args: args, result: "error: " + error.localizedDescription)
            throw error
        }
    }

    /// Runs the failed jobs of these workflow runs again (GitHub only), each written to the action log.
    func rerunFailed(_ runs: [Int], repo: String) async throws {
        let token = try token()
        for run in runs {
            let args = "\(repo) run \(run)"
            do {
                try await GitHubActions.perform(.rerunFailed, repo: repo, runID: run, token: token)
                AppModel.shared.store.audit(tool: WorkflowRunAction.rerunFailed.auditTool, args: args, result: "ok")
            } catch {
                AppModel.shared.store.audit(tool: WorkflowRunAction.rerunFailed.auditTool, args: args, result: "error: " + error.localizedDescription)
                throw error
            }
        }
    }

    /// Merges at `head` (what the phone saw), only when the quick merge's rule allows it now. Returns what was merged,
    /// for the audit log.
    func merge(head: String, method requested: PullRequestMergeMethod?) async throws -> String {
        let token = try token()
        let detail: PullRequestDetail
        if let forge {
            detail = try await forge.summary(number: item.number)
        } else {
            detail = try await GitHubPullRequestDetail.loadForMerge(repo: item.repo, number: item.number, token: token)
        }
        guard detail.headSHA == head else { throw NookError(tr("companion.phone.pr.movedOn")) }
        if let reason = PullRequestQuickRunner.blocker(detail) { throw NookError(tr(reason, "#\(detail.number)")) }
        let preferred = PullRequestMergeMethod(rawValue: UserDefaults.standard.string(forKey: "agents.pr.mergeMethod") ?? "") ?? .merge
        guard let method = requested.flatMap({ detail.methods.contains($0) ? $0 : nil })
                ?? PullRequestQuickAction.mergeMethod(preferred: preferred, allowed: detail.methods) else {
            throw NookError(tr("agents.pulls.quick.noMethod", "#\(detail.number)"))
        }
        let args = "\(detail.id) · \(method.rawValue) · \(detail.headBranch) → \(detail.baseBranch)"
        do {
            let sha: String
            if let forge {
                sha = try await forge.merge(number: detail.number, method: method, sha: detail.headSHA)
            } else {
                sha = try await GitHubPullRequestDetail.merge(repo: detail.repo, number: detail.number, method: method,
                                                              sha: detail.headSHA, token: token)
            }
            AppModel.shared.store.audit(tool: "github_merge_pr", args: args, result: "merged" + (sha.isEmpty ? "" : " " + String(sha.prefix(7))))
        } catch {
            AppModel.shared.store.audit(tool: "github_merge_pr", args: args, result: "error: " + error.localizedDescription)
            throw error
        }
        PullRequestStore.shared.markMerged(detail.id)
        PullRequestSync.shared.markMerged(repository: detail.repo, number: detail.number)
        return args
    }
}
