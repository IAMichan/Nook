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
                   baseBranch: item.baseBranch)
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
            return CompanionResponse(id: request.id, ok: true, pull: Self.digest(detail, url: reader.url))
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
                marks.setViewed(action.kind == .viewed, file: file, in: PullRequestViewedFiles.key(repo: detail.repo, number: detail.number))
                marks.save()
                return CompanionResponse(id: request.id, ok: true, pull: Self.digest(detail, url: reader.url))
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
                return CompanionResponse(id: request.id, ok: true, pull: Self.digest(fresh, url: reader.url))
            case .merge:
                let merged = try await reader.merge(head: action.head ?? "", method: action.method.flatMap(PullRequestMergeMethod.init(rawValue:)))
                audit("pr_merge", merged)
                let fresh = try? await reader.read()
                return CompanionResponse(id: request.id, ok: true, message: "merged",
                                         pull: fresh.map { Self.digest($0, url: reader.url) })
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
            audit("pr_work", "\(detail.repo)#\(detail.number) · \(provider.displayName)")
            return CompanionResponse(id: request.id, ok: true, sessions: digests(app), created: id.uuidString)
        } catch {
            return .failure(request.id, .failed, message: error.localizedDescription)
        }
    }

    // MARK: Digests

    static func digest(_ detail: PullRequestDetail, url: URL, viewed: PullRequestViewedFiles = .load(), now: Date = Date()) -> PullDetailDigest {
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
        return PullDetailDigest(
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
            if let forge { return await forge.activity(number: number) }
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
