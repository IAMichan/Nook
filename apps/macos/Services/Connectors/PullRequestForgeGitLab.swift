import Foundation

/// GitLab merge requests as pull requests, through API v4. A note's id stays in the event id and its discussion's id in
/// `threadID`, because every write on a thread needs the discussion.
struct GitLabPullRequestForge: PullRequestForgeClient {
    /// Reactions take one request per note.
    static let forgeFeatures: PullRequestForgeFeatures = {
        var features = PullRequestForgeFeatures()
        features.reactions = false
        return features
    }()

    let repo: RemoteRepository
    let http: ForgeHTTP
    var features: PullRequestForgeFeatures { Self.forgeFeatures }

    init?(_ repo: RemoteRepository) {
        guard let token = ForgeEnvironment.gitLabToken( repo.hostName), let base = GitLabAPI.apiBase(repo) else { return nil }
        self.repo = repo
        http = ForgeHTTP(name: "GitLab", base: base, headers: ["PRIVATE-TOKEN": token])
    }

    private var project: String { "/projects/" + GitLabAPI.projectID(repo) }
    private func request(_ number: Int) -> String { project + "/merge_requests/\(number)" }

    // MARK: Reading

    func requests(branch: String) async -> [PullRequestLink]? {
        guard let url = GitLabAPI.listURL(repo: repo, sourceBranch: branch) else { return nil }
        var request = URLRequest(url: url)
        for (key, value) in http.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await ConditionalFetch.data(for: request, session: ForgeEnvironment.session),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return GitLabAPI.parseList(data, repository: repo, sourceBranch: branch)
    }

    func summary(number: Int) async throws -> PullRequestDetail {
        async let approvals = try? http.json(request(number) + "/approvals") as? [String: Any]
        async let settings = try? http.json(project) as? [String: Any]
        async let labelList = labels()
        guard let mergeRequest = try await http.json(request(number)) as? [String: Any] else {
            throw PullRequestForgeError.refused("GitLab did not send this merge request.")
        }
        var jobs: [[String: Any]] = []
        if let pipeline = Self.int((mergeRequest["head_pipeline"] as? [String: Any])?["id"]) {
            jobs = await list(project + "/pipelines/\(pipeline)/jobs", pages: 2) ?? []
        }
        // A fork's own path takes a request of its own: the merge request only names its project by id.
        var source: [String: Any]?
        if let id = Self.int(mergeRequest["source_project_id"]), id != Self.int(mergeRequest["target_project_id"]) {
            source = try? await http.json("/projects/\(id)") as? [String: Any]
        }
        let known = await labelList
        let colors = Dictionary(known.map { ($0.name, $0.color) }, uniquingKeysWith: { first, _ in first })
        let descriptions = Dictionary(known.filter { !$0.description.isEmpty }.map { ($0.name, $0.description) }, uniquingKeysWith: { first, _ in first })
        guard let detail = Self.detail(mergeRequest: mergeRequest, project: await settings, sourceProject: source,
                                       approvals: await approvals, labelColors: colors, labelDescriptions: descriptions,
                                       jobs: jobs, repo: repo) else {
            throw PullRequestForgeError.refused("GitLab did not send this merge request.")
        }
        return detail
    }

    func activity(number: Int) async -> PullRequestActivity {
        async let mergeRequest = try? http.json(request(number)) as? [String: Any]
        async let approvals = try? http.json(request(number) + "/approvals") as? [String: Any]
        async let discussions = list(request(number) + "/discussions", pages: 5)
        async let commits = list(request(number) + "/commits", pages: 5)
        async let diffs = list(request(number) + "/diffs", pages: 10)
        async let closes = list(request(number) + "/closes_issues", pages: 1)
        let history = Self.commits(await commits ?? [])
        let link = (await mergeRequest)?["web_url"] as? String
        return PullRequestActivity(events: Self.events(discussions: await discussions ?? [], approvals: await approvals,
                                                       commits: history, url: link),
                                   commits: history, files: Self.files(await diffs ?? []),
                                   issues: Self.issues(await closes ?? [], repository: repo.displayName))
    }

    func commitFiles(sha: String) async throws -> [PullRequestFile] {
        guard let escaped = Self.escape(sha) else { return [] }
        return Self.files(try await pages(project + "/repository/commits/\(escaped)/diff", limit: 10))
    }

    func viewer() async -> String {
        let user = (try? await http.json("/user")) as? [String: Any]
        return (user?["username"] as? String) ?? ""
    }

    func labels() async -> [PullRequestLabelChoice] {
        Self.labels(await list(project + "/labels", pages: 5) ?? [])
    }

    /// A list's pages of 100 one after the other, until a short one.
    private func pages(_ path: String, limit: Int) async throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        for page in 1...max(1, limit) {
            let items = try await http.json(path + (path.contains("?") ? "&" : "?") + "per_page=100&page=\(page)") as? [[String: Any]] ?? []
            result += items
            if items.count < 100 { break }
        }
        return result
    }

    private func list(_ path: String, pages limit: Int) async -> [[String: Any]]? {
        try? await pages(path, limit: limit)
    }

    // MARK: Writing

    @discardableResult
    func perform(_ action: PullRequestAction, number: Int, detail: PullRequestDetail) async throws -> String? {
        let path = request(number)
        switch action {
        case .comment(let body):
            try await note(body, number: number)
        case .review(let verdict, let body):
            let requested = verdict == .requestChanges ? try await requestChanges(number) : false
            try await finish(verdict, body: body, number: number, head: detail.headSHA, changesRequested: requested)
        case .reviewWithComments(let verdict, let body, _, let comments):
            // Requesting changes goes first, so a GitLab that refuses it does so before any comment lands.
            let requested = verdict == .requestChanges ? try await requestChanges(number) : false
            try await send(comments, number: number, detail: detail)
            // Line comments are words enough, so a remark with only those has no note of its own.
            let hasWords = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if verdict == .approve || hasWords {
                try await finish(verdict, body: body, number: number, head: detail.headSHA, changesRequested: requested)
            }
        case .reply(let id, let body):
            guard let thread = Self.thread(of: id, in: detail.events) else {
                throw PullRequestForgeError.refused("GitLab did not say which discussion this comment is in.")
            }
            _ = try await http.json(path + "/discussions/\(thread)/notes", method: "POST", body: ["body": try Self.words(body)])
        case .setThreadResolved(let thread, let resolved):
            _ = try await http.json(path + "/discussions/\(thread)?resolved=\(resolved)", method: "PUT")
        case .editComment(let id, _, let body):
            _ = try await http.json(path + "/notes/\(id)", method: "PUT", body: ["body": try Self.words(body)])
        case .close:
            _ = try await http.json(path, method: "PUT", body: ["state_event": "close"])
        case .reopen:
            _ = try await http.json(path, method: "PUT", body: ["state_event": "reopen"])
        case .edit(let title, let body):
            _ = try await http.json(path, method: "PUT", body: ["title": try Self.words(title), "description": body])
        case .requestReviewers(let people):
            try await addReviewers(people, number: number)
        case .addLabels(let labels):
            let names = labels.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            _ = try await http.json(path, method: "PUT", body: ["add_labels": names.joined(separator: ",")])
        case .removeLabel(let label):
            _ = try await http.json(path, method: "PUT", body: ["remove_labels": label])
        case .updateBranch, .rebaseBranch:
            // Rebasing is GitLab's only way to bring a branch up to date from the API. It takes no expected head.
            _ = try await http.json(path + "/rebase", method: "PUT")
        case .markDraft:
            _ = try await http.json(path, method: "PUT", body: ["title": Self.title(detail.title, draft: true)])
        case .markReady:
            _ = try await http.json(path, method: "PUT", body: ["title": Self.title(detail.title, draft: false)])
        case .changeBase(let branch):
            _ = try await http.json(path, method: "PUT", body: ["target_branch": try Self.words(branch)])
        case .setMaintainerEdits(let allowed):
            _ = try await http.json(path, method: "PUT", body: ["allow_collaboration": allowed])
        case .deleteBranch(let repository, let branch):
            guard let owner = Self.escape(repository), let name = Self.escape(branch) else {
                throw PullRequestForgeError.refused("Invalid branch name.")
            }
            _ = try await http.data("/projects/\(owner)/repository/branches/\(name)", method: "DELETE")
        case .enableAutoMerge(_, let method):
            _ = try await http.json(path + "/merge", method: "PUT",
                                    body: Self.mergeBody(method: method, sha: detail.headSHA).merging(["merge_when_pipeline_succeeds": true]) { $1 })
        case .disableAutoMerge:
            _ = try await http.json(path + "/cancel_merge_when_pipeline_succeeds", method: "POST")
        case .revert:
            return try await revert(number)
        case .approveWorkflow:
            throw PullRequestForgeError.unsupported("GitLab")
        }
        return nil
    }

    func merge(number: Int, method: PullRequestMergeMethod, sha: String) async throws -> String {
        // The project's merge method decides how the commits land; only a squash can be asked for per merge.
        guard method != .rebase else { throw PullRequestForgeError.unsupported("GitLab") }
        let answer = try await http.json(request(number) + "/merge", method: "PUT", body: Self.mergeBody(method: method, sha: sha))
        return Self.mergedSHA(answer as? [String: Any] ?? [:])
    }

    /// What GitLab's own Revert button does (as t3code): the merged commit reverted onto a new branch off the target, and a
    /// merge request of that branch. Returns its link. The branch goes again when a later step fails, or a retry would
    /// fail on making it.
    private func revert(_ number: Int) async throws -> String? {
        guard let mergeRequest = try await http.json(request(number)) as? [String: Any], let target = Self.revertTarget(mergeRequest) else {
            throw PullRequestForgeError.refused("GitLab did not send this merge request.")
        }
        guard target.merged else { throw PullRequestForgeError.refused("Only a merged merge request can be reverted.") }
        var sha = target.sha
        if sha == nil {
            // A fast-forward merge without squash records neither commit; it can be reverted only when it was one commit.
            let commits = try await http.json(request(number) + "/commits?per_page=2") as? [[String: Any]] ?? []
            sha = commits.count == 1 ? commits[0]["id"] as? String : nil
        }
        guard let sha, let escaped = Self.escape(sha) else {
            throw PullRequestForgeError.refused("This merge request landed as several commits, so there is no single commit to revert.")
        }
        let body = Self.revertRequest(number: number, title: target.title, targetBranch: target.targetBranch, sha: sha)
        _ = try await http.json(project + "/repository/branches", method: "POST", body: ["branch": body.branch, "ref": target.targetBranch])
        do {
            _ = try await http.json(project + "/repository/commits/\(escaped)/revert", method: "POST", body: ["branch": body.branch])
            let made = try await http.json(project + "/merge_requests", method: "POST", body: body.mergeRequest) as? [String: Any]
            return made?["web_url"] as? String
        } catch {
            // Detached, so a cancelled request still removes the branch.
            let http = http, path = project + "/repository/branches/" + (Self.escape(body.branch) ?? body.branch)
            await Task.detached { _ = try? await http.data(path, method: "DELETE") }.value
            throw error
        }
    }

    private func note(_ body: String, number: Int) async throws {
        _ = try await http.json(request(number) + "/notes", method: "POST", body: ["body": try Self.words(body)])
    }

    /// An approval goes first: when GitLab refuses it, no note is left that reads as if it went through. The words of a
    /// review are a note; with changes requested (`requestChanges`) and no words, there is nothing more to post.
    private func finish(_ verdict: PullRequestAction.Verdict, body: String, number: Int, head: String,
                        changesRequested: Bool = false) async throws {
        let silent = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if verdict == .approve {
            // With the head, GitLab refuses an approval of commits the reviewer did not see.
            let pinned: [String: String] = head.isEmpty ? [:] : ["sha": head]
            _ = try await http.json(request(number) + "/approve", method: "POST", body: pinned)
            if silent { return }
        }
        if changesRequested && silent { return }
        try await note(body, number: number)
    }

    /// Requests changes as GitLab's own verdict (GitLab 18.9 and later, GraphQL only, like t3code): you join the
    /// reviewers, since GitLab keeps the verdict on a reviewer, then `mergeRequestRequestChanges`. False when this
    /// GitLab does not know the mutation (an older server): the review is then a note, as before. A refusal throws.
    private func requestChanges(_ number: Int) async throws -> Bool {
        guard http.base.hasSuffix("/v4") else { return false }
        guard let user = try await http.json("/user") as? [String: Any], let name = user["username"] as? String, !name.isEmpty else {
            throw PullRequestForgeError.refused("GitLab did not say who you are.")
        }
        let graphQL = ForgeHTTP(name: http.name, base: String(http.base.dropLast("/v4".count)), headers: http.headers)
        let target: [String: Any] = ["projectPath": repo.path, "iid": String(number)]
        let reviewers = try await graphQL.json("/graphql", method: "POST",
                                               body: ["query": Self.setReviewerMutation, "variables": target.merging(["reviewers": [name]]) { $1 }])
        switch Self.mutationOutcome(reviewers, field: "mergeRequestSetReviewers") {
        case .unsupported: return false
        case .refused(let reasons): throw PullRequestForgeError.refused("GitLab refused it: " + reasons.joined(separator: "; "))
        case .done: break
        }
        let answer = try await graphQL.json("/graphql", method: "POST", body: ["query": Self.requestChangesMutation, "variables": target])
        switch Self.mutationOutcome(answer, field: "mergeRequestRequestChanges") {
        case .unsupported: return false
        case .refused(let reasons): throw PullRequestForgeError.refused("GitLab refused it: " + reasons.joined(separator: "; "))
        case .done: return true
        }
    }

    static let setReviewerMutation = """
        mutation($projectPath: ID!, $iid: String!, $reviewers: [String!]!) {
          mergeRequestSetReviewers(input: { projectPath: $projectPath, iid: $iid, reviewerUsernames: $reviewers, operationMode: APPEND }) { errors }
        }
        """

    static let requestChangesMutation = """
        mutation($projectPath: ID!, $iid: String!) {
          mergeRequestRequestChanges(input: { projectPath: $projectPath, iid: $iid }) { errors }
        }
        """

    enum MutationOutcome: Equatable {
        case done
        /// The mutation went through GraphQL but GitLab said no (a locked merge request).
        case refused([String])
        /// This GitLab has no such mutation (or no such argument): it is older than the API.
        case unsupported
    }

    /// What a GraphQL answer says about `field`: GitLab names a mutation it does not know in a top-level error and
    /// gives no data for it; a mutation it ran lists its refusals in `errors`.
    static func mutationOutcome(_ answer: Any, field: String) -> MutationOutcome {
        let object = answer as? [String: Any] ?? [:]
        let payload = (object["data"] as? [String: Any])?[field] as? [String: Any]
        guard let payload else {
            let messages = ((object["errors"] as? [[String: Any]]) ?? []).compactMap { $0["message"] as? String }
            let unknown = messages.isEmpty || messages.contains { $0.contains("doesn't exist") || $0.contains("isn't defined") }
            return unknown ? .unsupported : .refused(messages)
        }
        let reasons = (payload["errors"] as? [String]) ?? []
        return reasons.isEmpty ? .done : .refused(reasons)
    }

    /// Each comment is a discussion of its own. GitLab pins them to the commits of `diff_refs`, which only a fresh read has.
    private func send(_ comments: [PullRequestAction.LineComment], number: Int, detail: PullRequestDetail) async throws {
        guard !comments.isEmpty else { return }
        let fresh = try await http.json(request(number)) as? [String: Any] ?? [:]
        guard let refs = fresh["diff_refs"] as? [String: Any] else {
            throw PullRequestForgeError.refused("GitLab did not send the commits of this diff.")
        }
        for comment in comments {
            let file = detail.files.first { $0.path == comment.path }
            let position = Self.position(comment, refs: refs, file: file)
            _ = try await http.json(request(number) + "/discussions", method: "POST",
                                    body: ["body": comment.body, "position": position] as [String: Any])
        }
    }

    /// `reviewer_ids` replaces the whole list and takes ids, so the people already asked go along and names are looked up.
    private func addReviewers(_ people: [String], number: Int) async throws {
        let current = try await http.json(request(number)) as? [String: Any] ?? [:]
        var ids = ((current["reviewers"] as? [[String: Any]]) ?? []).compactMap { Self.int($0["id"]) }
        for name in Self.usernames(people) {
            guard let escaped = Self.escape(name),
                  let found = (try await http.json("/users?username=\(escaped)") as? [[String: Any]])?.first,
                  let id = Self.int(found["id"]) else {
                throw PullRequestForgeError.refused("GitLab has no user \(name).")
            }
            if !ids.contains(id) { ids.append(id) }
        }
        _ = try await http.json(request(number), method: "PUT", body: ["reviewer_ids": ids])
    }

    // MARK: Parsing

    static func detail(mergeRequest item: [String: Any], project: [String: Any]?, sourceProject: [String: Any]?,
                       approvals: [String: Any]?, labelColors: [String: String], labelDescriptions: [String: String] = [:],
                       jobs: [[String: Any]],
                       repo: RemoteRepository) -> PullRequestDetail? {
        guard let number = int(item["iid"]) else { return nil }
        let state: PullRequestDetail.State
        switch GitLabAPI.state(item) {
        case .merged: state = .merged
        case .closed: state = .closed
        case .draft: state = .draft
        case .open: state = .open
        }
        var detail = PullRequestDetail(
            repo: repo.path, number: number, title: (item["title"] as? String) ?? "Untitled",
            body: GitHubMarkdown.markdown((item["description"] as? String) ?? ""),
            url: (item["web_url"] as? String).flatMap(URL.init(string:)), author: username(item["author"]), state: state,
            baseBranch: (item["target_branch"] as? String) ?? "", headBranch: (item["source_branch"] as? String) ?? "",
            headSHA: (item["sha"] as? String) ?? "", additions: 0, deletions: 0,
            changedFiles: int(item["changes_count"]) ?? Int(((item["changes_count"] as? String) ?? "").prefix { $0.isNumber }) ?? 0,
            created: PullRequestDetailParser.date(item["created_at"]), updated: PullRequestDetailParser.date(item["updated_at"]),
            mergeable: mergeable(item), mergeState: mergeState(item))
        detail.features = forgeFeatures
        detail.activityLoaded = false
        // The page offers draft, rebase and auto-merge only with this id. GitLab's actions do not read it.
        detail.nodeID = int(item["id"]).map(String.init) ?? String(number)
        detail.checks = checks(pipeline: item["head_pipeline"] as? [String: Any], jobs: jobs)
        detail.canPush = (item["user"] as? [String: Any])?["can_merge"] as? Bool
        detail.commentCount = int(item["user_notes_count"])
        detail.methods = methods(project)
        let approved = Set(approvers(approvals).map { $0.lowercased() })
        detail.requestedReviewers = accounts(item["reviewers"]).filter { !approved.contains($0.lowercased()) }
        detail.assignees = accounts(item["assignees"])
        detail.milestone = ((item["milestone"] as? [String: Any])?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        detail.locked = (item["discussion_locked"] as? Bool) == true
        detail.labels = (item["labels"] as? [String]) ?? []
        detail.labelColors = labelColors.filter { detail.labels.contains($0.key) }
        detail.labelDescriptions = labelDescriptions.filter { detail.labels.contains($0.key) }
        detail.maintainerEdits = (item["allow_collaboration"] as? Bool) == true
        detail.autoMergeAllowed = true
        if (item["merge_when_pipeline_succeeds"] as? Bool) == true {
            detail.autoMerge = PullRequestAutoMerge(method: (item["squash"] as? Bool) == true ? .squash : .merge,
                                                    enabledBy: username(item["merge_user"]))
        }
        if let id = int(item["source_project_id"]), id != int(item["target_project_id"]) {
            detail.headRepository = sourceProject?["path_with_namespace"] as? String
            detail.headOwner = detail.headRepository?.split(separator: "/").first.map(String.init)
                ?? (item["author"] as? [String: Any])?["username"] as? String
        } else {
            detail.headRepository = repo.path
        }
        return detail
    }

    /// A conflict is known at once; the rest only once GitLab finished checking. Older versions only have `merge_status`.
    static func mergeable(_ item: [String: Any]) -> Bool? {
        if PullRequestMergeability.gitlabConflicted(item) { return false }
        let working = ["unchecked", "checking", "cannot_be_merged_recheck"].contains((item["merge_status"] as? String)?.lowercased() ?? "")
        return PullRequestMergeability.gitlabKnown(item) && !working ? true : nil
    }

    /// GitLab's merge status in GitHub's words, which the page reads.
    static func mergeState(_ item: [String: Any]) -> String {
        if PullRequestMergeability.gitlabConflicted(item) { return "dirty" }
        guard let status = (item["detailed_merge_status"] as? String)?.lowercased() else { return "unknown" }
        switch status {
        case "mergeable": return "clean"
        case "need_rebase": return "behind"
        case "draft_status": return "draft"
        case "ci_must_pass", "ci_still_running": return "unstable"
        case "not_approved", "requested_changes", "discussions_not_resolved", "blocked_status", "merge_request_blocked",
             "external_status_checks", "commits_status", "jira_association_missing", "locked_paths", "locked_lfs_files",
             "merge_time", "title_regex", "approvals_syncing", "security_policy_evaluation", "security_policy_violations":
            return "blocked"
        default: return "unknown"
        }
    }

    /// A project offers one way of merging, so the menu only chooses whether to squash. Without an answer that stays open.
    static func methods(_ project: [String: Any]?) -> [PullRequestMergeMethod] {
        switch project?["squash_option"] as? String {
        case "never": return [.merge]
        case "always": return [.squash]
        default: return [.merge, .squash]
        }
    }

    /// The jobs of the head pipeline, failing first. Without jobs the pipeline itself is the one check.
    static func checks(pipeline: [String: Any]?, jobs: [[String: Any]]) -> [PullRequestCheck] {
        guard let pipeline else { return [] }
        let items = jobs.isEmpty ? [pipeline.merging(["name": "Pipeline"]) { $1 }] : jobs
        let result = items.map { job -> PullRequestCheck in
            let status = (job["status"] as? String) ?? ""
            return PullRequestCheck(name: (job["name"] as? String) ?? "?",
                                    outcome: outcome(status, allowedToFail: (job["allow_failure"] as? Bool) == true),
                                    detail: status, url: (job["web_url"] as? String).flatMap(URL.init(string:)),
                                    isCheckRun: true, running: status == "running",
                                    started: PullRequestDetailParser.date(job["started_at"]),
                                    finished: PullRequestDetailParser.date(job["finished_at"]))
        }
        return failingFirst(result)
    }

    /// The order of the page's check list, the forge's order within one outcome.
    static func failingFirst(_ checks: [PullRequestCheck]) -> [PullRequestCheck] {
        func rank(_ check: PullRequestCheck) -> Int {
            switch check.outcome { case .failing: return 0; case .pending: return 1; case .passing: return 2; case .skipped: return 3 }
        }
        return checks.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    static func outcome(_ status: String, allowedToFail: Bool) -> PullRequestCheck.Outcome {
        switch status {
        case "success": return .passing
        case "failed", "canceled": return allowedToFail ? .skipped : .failing
        case "skipped", "manual": return .skipped
        default: return .pending
        }
    }

    /// System notes GitLab writes in fixed words, as the timeline's activity. Others say nothing the page shows.
    private static let systemNotes: [(prefix: String, type: String)] = [
        ("marked this merge request as **draft**", "convert_to_draft"), ("marked this merge request as **ready**", "ready_for_review"),
        ("marked as a **work in progress**", "convert_to_draft"), ("unmarked as a **work in progress**", "ready_for_review"),
        ("requested review from ", "review_requested"), ("removed review request for ", "review_request_removed"),
        ("assigned to ", "assigned"), ("unassigned ", "unassigned"),
        ("enabled an automatic merge", "auto_merge_enabled"), ("canceled the automatic merge", "auto_merge_disabled"),
        ("deleted source branch", "head_ref_deleted"), ("restored source branch", "head_ref_restored"),
        ("closed", "closed"), ("reopened", "reopened"), ("merged", "merged"),
    ]

    /// The timeline, oldest first. Discussions hold every note, the system's too. `approved_by` is what stands now, since
    /// a push can reset an approval without a note; the note only gives its date.
    static func events(discussions: [[String: Any]], approvals: [String: Any]?, commits: [PullRequestCommit], url: String?) -> [PullRequestEvent] {
        var result = PullRequestDetailParser.events(reviews: [], comments: [], lineComments: [], commits: commits)
        var approvedAt: [String: Date] = [:]
        func link(_ id: Int) -> URL? { url.flatMap { URL(string: $0 + "#note_\(id)") } }
        for discussion in discussions {
            let thread = discussion["id"] as? String
            let notes = (discussion["notes"] as? [[String: Any]]) ?? []
            let root = notes.first { ($0["system"] as? Bool) != true }.flatMap { int($0["id"]) }
            let individual = (discussion["individual_note"] as? Bool) == true
            for note in notes {
                guard let id = int(note["id"]) else { continue }
                let raw = (note["body"] as? String) ?? ""
                let date = PullRequestDetailParser.date(note["created_at"])
                if (note["system"] as? Bool) == true {
                    if raw.hasPrefix("approved this merge request") {
                        approvedAt[username(note["author"]).lowercased()] = date
                    } else if let known = systemNotes.first(where: { raw.hasPrefix($0.prefix) }) {
                        let mention = raw.hasPrefix(known.prefix + "@") ? String(raw.dropFirst(known.prefix.count)) : ""
                        result.append(PullRequestEvent(id: "timeline-\(id)", kind: .activity(type: known.type, detail: mention),
                                                       author: username(note["author"]), body: "", date: date, url: nil))
                    }
                    continue
                }
                let position = note["position"] as? [String: Any] ?? (notes.first?["position"] as? [String: Any])
                let onLine = position != nil && !individual
                let kind: PullRequestEvent.Kind = onLine
                    ? .lineComment(path: (position?["new_path"] as? String) ?? (position?["old_path"] as? String) ?? "",
                                   line: int(position?["new_line"]) ?? int(position?["old_line"]))
                    : .comment
                var event = PullRequestEvent(id: "\(onLine ? "line" : "comment")-\(id)", kind: kind, author: username(note["author"]),
                                             body: GitHubMarkdown.markdown(raw), date: date, url: link(id))
                event.rawBody = raw
                if !individual {
                    event.threadID = thread
                    if onLine, let root, root != id { event.replyTo = "line-\(root)" }
                    if root == id { event.resolved = (note["resolved"] as? Bool) == true }
                }
                result.append(event)
            }
        }
        for name in approvers(approvals) {
            result.append(PullRequestEvent(id: "review-approved-\(name)", kind: .review("APPROVED"), author: name, body: "",
                                           date: approvedAt[name.lowercased()], url: nil))
        }
        return result.enumerated().sorted {
            ($0.element.date ?? .distantPast, $0.offset) < ($1.element.date ?? .distantPast, $1.offset)
        }.map(\.element)
    }

    /// Who approved the merge request as it stands.
    static func approvers(_ approvals: [String: Any]?) -> [String] {
        ((approvals?["approved_by"] as? [[String: Any]]) ?? []).compactMap { ($0["user"] as? [String: Any])?["username"] as? String }
    }

    /// The discussion of a note, by the note's number.
    static func thread(of id: Int, in events: [PullRequestEvent]) -> String? {
        events.first { $0.id == "line-\(id)" || $0.id == "comment-\(id)" }?.threadID
    }

    /// Oldest first, as GitHub lists them; GitLab sends the newest first.
    static func commits(_ list: [[String: Any]]) -> [PullRequestCommit] {
        list.compactMap { item -> PullRequestCommit? in
            guard let sha = item["id"] as? String else { return nil }
            return PullRequestCommit(sha: sha, message: (item["message"] as? String) ?? (item["title"] as? String) ?? "",
                                     author: (item["author_name"] as? String) ?? "?",
                                     date: PullRequestDetailParser.date(item["authored_date"] ?? item["created_at"]))
        }.reversed()
    }

    /// Entries of `/diffs` and of a commit's `/diff`. GitLab sends each diff from its first `@@`, without file headers.
    static func files(_ list: [[String: Any]]) -> [PullRequestFile] {
        list.compactMap { item in
            guard let path = (item["new_path"] as? String) ?? (item["old_path"] as? String) else { return nil }
            let removed = (item["deleted_file"] as? Bool) == true, renamed = (item["renamed_file"] as? Bool) == true
            let status = (item["new_file"] as? Bool) == true ? "added" : removed ? "removed" : renamed ? "renamed" : "modified"
            let patch = ((item["diff"] as? String) ?? "").trimmingCharacters(in: .newlines)
            let lines = patch.components(separatedBy: "\n")
            return PullRequestFile(path: path, status: status, additions: lines.filter { $0.hasPrefix("+") }.count,
                                   deletions: lines.filter { $0.hasPrefix("-") }.count, patch: patch.isEmpty ? nil : patch,
                                   previousPath: renamed ? item["old_path"] as? String : nil, revision: removed ? "" : nil)
        }
    }

    static func issues(_ list: [[String: Any]], repository: String) -> [PullRequestLinkedIssue] {
        list.compactMap { item in
            guard let number = int(item["iid"]) else { return nil }
            return PullRequestLinkedIssue(repo: repository, number: number, title: (item["title"] as? String) ?? "",
                                          open: (item["state"] as? String) == "opened",
                                          url: (item["web_url"] as? String).flatMap(URL.init(string:)))
        }
    }

    /// What a revert needs of a merge request. `sha` is nil for a fast-forward merge without squash, which records neither.
    static func revertTarget(_ item: [String: Any]) -> (merged: Bool, title: String, targetBranch: String, sha: String?)? {
        guard let title = item["title"] as? String, let branch = item["target_branch"] as? String, let state = item["state"] as? String else { return nil }
        func trimmed(_ value: Any?) -> String? {
            (value as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        return (state == "merged", title, branch, trimmed(item["merge_commit_sha"]) ?? trimmed(item["squash_commit_sha"]))
    }

    /// The branch a revert of `sha` goes on, and the merge request that proposes it, in GitLab's own words.
    static func revertRequest(number: Int, title: String, targetBranch: String, sha: String) -> (branch: String, mergeRequest: [String: Any]) {
        let branch = "revert-" + sha.prefix(8)
        return (branch, ["source_branch": branch, "target_branch": targetBranch, "title": "Revert \"\(title)\"",
                         "description": "This reverts merge request !\(number)", "remove_source_branch": true])
    }

    /// Names with colors as six hex digits, as the page expects them, and what each is for.
    static func labels(_ list: [[String: Any]]) -> [PullRequestLabelChoice] {
        list.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return (name, ((item["color"] as? String) ?? "").replacingOccurrences(of: "#", with: ""), (item["description"] as? String) ?? "")
        }
    }

    // MARK: Building

    /// A diff position. A line that did not change needs both its numbers, and only the patch knows the other one. A
    /// comment on several lines also sends `line_range` (see `lineRange`), so GitLab marks every line of it.
    static func position(_ comment: PullRequestAction.LineComment, refs: [String: Any], file: PullRequestFile?) -> [String: Any] {
        var position: [String: Any] = ["position_type": "text", "new_path": comment.path, "old_path": file?.previousPath ?? comment.path]
        for key in ["base_sha", "start_sha", "head_sha"] { position[key] = refs[key] }
        let pair = file?.patch.flatMap { unchangedLine(comment.line, left: comment.side == "LEFT", patch: $0) }
        if comment.side == "LEFT" {
            position["old_line"] = comment.line
            if let pair { position["new_line"] = pair }
        } else {
            position["new_line"] = comment.line
            if let pair { position["old_line"] = pair }
        }
        if let range = lineRange(comment, file: file) { position["line_range"] = range }
        return position
    }

    /// Where a comment on several lines starts and ends, as GitLab's own page sends it (t3code does the same): each end
    /// with `type` ("new" for an added line, "old" for a removed one, null for one that did not change), its line numbers,
    /// and a `line_code` of the path's SHA-1 and both of GitLab's line counters there. GitLab finds the lines to mark by
    /// that code, and only the patch knows the other side's counter. Nil for a comment on one line.
    static func lineRange(_ comment: PullRequestAction.LineComment, file: PullRequestFile?) -> [String: Any]? {
        guard let startLine = comment.startLine else { return nil }
        let hash = sha1Hex(Data(comment.path.utf8))
        let patch = file?.patch ?? ""
        let start = rangeEnd(line: startLine, left: (comment.startSide ?? comment.side) == "LEFT", patch: patch, hash: hash)
        let end = rangeEnd(line: comment.line, left: comment.side == "LEFT", patch: patch, hash: hash)
        guard start["line_code"] as? String != end["line_code"] as? String else { return nil }
        return ["start": start, "end": end]
    }

    private static func rangeEnd(line: Int, left: Bool, patch: String, hash: String) -> [String: Any] {
        let found = lineCounters(line, left: left, patch: patch)
        let kind = found?.kind ?? (left ? .deleted : .added)
        let old = found?.old ?? (left ? line : 0), new = found?.new ?? (left ? 0 : line)
        var end: [String: Any] = ["line_code": "\(hash)_\(old)_\(new)"]
        switch kind {
        case .added:
            end["type"] = "new"
            end["new_line"] = new
        case .deleted:
            end["type"] = "old"
            end["old_line"] = old
        case .context:
            end["type"] = NSNull()
            end["old_line"] = old
            end["new_line"] = new
        }
        return end
    }

    enum LineKind: Equatable { case added, deleted, context }

    /// The old and new line counters GitLab's diff parser holds at a line, and what kind of line it is. An added line keeps
    /// the old counter where it stands, and a removed line the new one. Nil for a line outside the patch.
    static func lineCounters(_ line: Int, left: Bool, patch: String) -> (kind: LineKind, old: Int, new: Int)? {
        var old = 0, new = 0
        for text in patch.components(separatedBy: "\n") {
            if text.hasPrefix("@@") {
                let numbers = text.split(separator: " ").dropFirst().prefix(2).map { part -> Int in
                    Int(part.dropFirst().prefix { $0.isNumber }) ?? 0
                }
                guard numbers.count == 2 else { return nil }
                old = numbers[0]
                new = numbers[1]
            } else if text.hasPrefix("+") {
                if !left && new == line { return (.added, old, new) }
                new += 1
            } else if text.hasPrefix("-") {
                if left && old == line { return (.deleted, old, new) }
                old += 1
            } else if !text.hasPrefix("\\") {
                if (left ? old : new) == line { return (.context, old, new) }
                old += 1
                new += 1
            }
        }
        return nil
    }

    /// SHA-1 in hex, for GitLab's line codes. Written out because the adapters stay Foundation-only (no CryptoKit).
    static func sha1Hex(_ data: Data) -> String {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var message = [UInt8](data)
        let bits = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8((bits >> UInt64(shift)) & 0xFF)) }
        func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 { (value << count) | (value >> (32 - count)) }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let at = chunk + i * 4
                w[i] = UInt32(message[at]) << 24 | UInt32(message[at + 1]) << 16 | UInt32(message[at + 2]) << 8 | UInt32(message[at + 3])
            }
            for i in 16..<80 { w[i] = rotate(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default: f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let next = rotate(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = rotate(b, 30); b = a; a = next
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }

    /// The number on the other side of an unchanged line; nil for an added or removed line, or one outside the patch.
    static func unchangedLine(_ line: Int, left: Bool, patch: String) -> Int? {
        var old = 0, new = 0
        for text in patch.components(separatedBy: "\n") {
            if text.hasPrefix("@@") {
                let numbers = text.split(separator: " ").dropFirst().prefix(2).map { part -> Int in
                    Int(part.dropFirst().prefix { $0.isNumber }) ?? 0
                }
                guard numbers.count == 2 else { return nil }
                old = numbers[0]
                new = numbers[1]
            } else if text.hasPrefix("+") {
                new += 1
            } else if text.hasPrefix("-") {
                old += 1
            } else if !text.hasPrefix("\\") {
                if (left ? old : new) == line { return left ? new : old }
                old += 1
                new += 1
            }
        }
        return nil
    }

    /// GitLab's draft is a title prefix. Every prefix it reads comes off, so a title never gets two.
    static func title(_ title: String, draft: Bool) -> String {
        var clean = title.trimmingCharacters(in: .whitespaces)
        var searching = true
        while searching {
            searching = false
            for prefix in ["draft:", "[draft]", "(draft)", "wip:", "[wip]"] where clean.lowercased().hasPrefix(prefix) {
                clean = clean.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                searching = true
            }
        }
        return draft ? "Draft: " + clean : clean
    }

    /// With `sha`, GitLab refuses when someone pushed since the page was read.
    static func mergeBody(method: PullRequestMergeMethod, sha: String) -> [String: Any] {
        var body: [String: Any] = ["squash": method == .squash]
        if !sha.isEmpty { body["sha"] = sha }
        return body
    }

    /// The commit a merge made; a fast-forward has neither and lands the head itself.
    static func mergedSHA(_ answer: [String: Any]) -> String {
        (answer["squash_commit_sha"] as? String) ?? (answer["merge_commit_sha"] as? String) ?? (answer["sha"] as? String) ?? ""
    }

    /// "@anna, bob.b" → names. GitLab's usernames hold dots and underscores, which GitHub's cleaning would drop.
    static func usernames(_ people: [String]) -> [String] {
        var seen = Set<String>()
        return people.flatMap { $0.split(whereSeparator: { $0 == "," || $0.isWhitespace }) }
            .map { String($0.drop { $0 == "@" }) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    // MARK: Helpers

    private static func words(_ text: String) throws -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw PullRequestForgeError.refused("This needs some text.") }
        return clean
    }

    /// One path segment: GitLab reads a project or branch with slashes as a single encoded segment.
    private static func escape(_ text: String) -> String? {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~")))
    }

    private static func username(_ user: Any?) -> String { ((user as? [String: Any])?["username"] as? String) ?? "?" }

    private static func accounts(_ users: Any?) -> [String] {
        ((users as? [[String: Any]]) ?? []).compactMap { $0["username"] as? String }
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }
}
