import Foundation

/// Gitea and Forgejo pull requests, which share an API. Their answers follow GitHub's closely, so most of them go through
/// `PullRequestDetailParser` after a few renamed fields.
struct GiteaPullRequestForge: PullRequestForgeClient {
    /// Neither API can resolve a thread (`threadID` stays nil, so the page does not offer it), merge by itself in a way
    /// Nook can show, or open a revert. Reactions take one request per comment.
    static let forgeFeatures: PullRequestForgeFeatures = {
        var features = PullRequestForgeFeatures()
        features.reactions = false
        features.autoMerge = false
        features.revert = false
        return features
    }()

    let repo: RemoteRepository
    let http: ForgeHTTP
    var features: PullRequestForgeFeatures { Self.forgeFeatures }

    init?(_ repo: RemoteRepository) {
        guard repo.webOrigin.hasPrefix("https://"), let token = ForgeEnvironment.token( repo.hostName) else { return nil }
        self.repo = repo
        http = ForgeHTTP(name: repo.host == .forgejo ? "Forgejo" : "Gitea", base: repo.webOrigin + "/api/v1",
                         headers: ["Authorization": "token " + token])
    }

    private var repository: String { Self.repositoryPath(repo.path) }
    private func pull(_ number: Int) -> String { repository + "/pulls/\(number)" }
    private func issue(_ number: Int) -> String { repository + "/issues/\(number)" }

    // MARK: Reading

    func requests(branch: String) async -> [PullRequestLink]? {
        guard let list = try? await pages(repository + "/pulls?state=all&sort=recentupdate", limit: 3) else { return nil }
        return Self.links(list, branch: branch, repo: repo)
    }

    func summary(number: Int) async throws -> PullRequestDetail {
        async let settings = try? http.json(repository) as? [String: Any]
        guard let item = try await http.json(pull(number)) as? [String: Any] else {
            throw PullRequestForgeError.refused("\(http.name) did not send this pull request.")
        }
        var statuses: [[String: Any]] = []
        if let sha = (item["head"] as? [String: Any])?["sha"] as? String, !sha.isEmpty {
            let combined = try? await http.json(repository + "/commits/\(sha)/status") as? [String: Any]
            statuses = (combined?["statuses"] as? [[String: Any]]) ?? []
        }
        guard let detail = Self.detail(pull: item, repository: await settings, statuses: statuses) else {
            throw PullRequestForgeError.refused("\(http.name) did not send this pull request.")
        }
        return detail
    }

    func activity(number: Int) async -> PullRequestActivity {
        async let reviews = try? pages(pull(number) + "/reviews", limit: 3)
        async let comments = try? pages(issue(number) + "/comments", limit: 5)
        async let commits = try? pages(pull(number) + "/commits?files=false&verification=false", limit: 5)
        async let diff = try? http.text(pull(number) + ".diff")
        let reviewList = await reviews ?? []
        let lines = await lineComments(reviewList, number: number)
        let history = PullRequestDetailParser.commits(await commits ?? [])
            .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        return PullRequestActivity(events: Self.events(reviews: reviewList, comments: await comments ?? [], lineComments: lines, commits: history),
                                   commits: history, files: UnifiedDiffFiles.split(await diff ?? ""))
    }

    func commitFiles(sha: String) async throws -> [PullRequestFile] {
        UnifiedDiffFiles.split(try await http.text(repository + "/git/commits/\(sha).diff"))
    }

    func viewer() async -> String {
        let user = (try? await http.json("/user")) as? [String: Any]
        return (user?["login"] as? String) ?? ""
    }

    func labels() async -> [(name: String, color: String)] {
        await allLabels().compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return (name, (item["color"] as? String) ?? "")
        }
    }

    /// The repository's labels and its organization's: a pull request can carry both. Only an organization has the second.
    private func allLabels() async -> [[String: Any]] {
        let own = (try? await pages(repository + "/labels", limit: 3)) ?? []
        guard let owner = repo.segments.first.flatMap(Self.segment) else { return own }
        return own + ((try? await pages("/orgs/\(owner)/labels", limit: 3)) ?? [])
    }

    /// Line comments live under the review they were sent with; only a review that has any is worth a request.
    private func lineComments(_ reviews: [[String: Any]], number: Int) async -> [[String: Any]] {
        var result: [[String: Any]] = []
        for review in reviews {
            guard let id = Self.int(review["id"]), (Self.int(review["comments_count"]) ?? 1) > 0 else { continue }
            result += (try? await http.json(pull(number) + "/reviews/\(id)/comments") as? [[String: Any]]) ?? []
        }
        return result
    }

    /// A list's pages of 50, the most a Gitea server sends by default, one after the other until a short one.
    private func pages(_ path: String, limit: Int) async throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        for page in 1...max(1, limit) {
            let items = try await http.json(path + (path.contains("?") ? "&" : "?") + "limit=50&page=\(page)") as? [[String: Any]] ?? []
            result += items
            if items.count < 50 { break }
        }
        return result
    }

    // MARK: Writing

    @discardableResult
    func perform(_ action: PullRequestAction, number: Int, detail: PullRequestDetail) async throws -> String? {
        let path = pull(number)
        switch action {
        case .comment(let body):
            _ = try await http.json(issue(number) + "/comments", method: "POST", body: ["body": try Self.words(body)])
        case .review(let verdict, let body):
            _ = try await http.json(path + "/reviews", method: "POST",
                                    body: Self.reviewBody(verdict, body: body, commit: detail.headSHA, comments: []))
        case .reviewWithComments(let verdict, let body, let commit, let comments):
            _ = try await http.json(path + "/reviews", method: "POST",
                                    body: Self.reviewBody(verdict, body: body, commit: commit, comments: comments))
        case .reply(let id, let body):
            try await reply(to: id, body: try Self.words(body), number: number, commit: detail.headSHA)
        case .editComment(let id, _, let body):
            // Both kinds are comments of one table, with one address.
            _ = try await http.json(repository + "/issues/comments/\(id)", method: "PATCH", body: ["body": try Self.words(body)])
        case .close:
            _ = try await http.json(path, method: "PATCH", body: ["state": "closed"])
        case .reopen:
            _ = try await http.json(path, method: "PATCH", body: ["state": "open"])
        case .edit(let title, let body):
            _ = try await http.json(path, method: "PATCH", body: ["title": try Self.words(title), "body": body])
        case .changeBase(let branch):
            _ = try await http.json(path, method: "PATCH", body: ["base": try Self.words(branch)])
        case .setMaintainerEdits(let allowed):
            _ = try await http.json(path, method: "PATCH", body: ["allow_maintainer_edit": allowed])
        case .markDraft:
            _ = try await http.json(path, method: "PATCH", body: ["title": Self.title(detail.title, draft: true)])
        case .markReady:
            _ = try await http.json(path, method: "PATCH", body: ["title": Self.title(detail.title, draft: false)])
        case .requestReviewers(let people):
            _ = try await http.json(path + "/requested_reviewers", method: "POST", body: ["reviewers": GitLabPullRequestForge.usernames(people)])
        case .addLabels(let names):
            let ids = Self.labelIDs(names, in: await allLabels())
            guard ids.count == names.count else { throw PullRequestForgeError.refused("\(http.name) does not have this label.") }
            _ = try await http.json(issue(number) + "/labels", method: "POST", body: ["labels": ids])
        case .removeLabel(let name):
            guard let id = Self.labelIDs([name], in: await allLabels()).first else {
                throw PullRequestForgeError.refused("\(http.name) does not have this label.")
            }
            _ = try await http.data(issue(number) + "/labels/\(id)", method: "DELETE")
        case .updateBranch:
            _ = try await http.data(path + "/update?style=merge", method: "POST")
        case .rebaseBranch:
            _ = try await http.data(path + "/update?style=rebase", method: "POST")
        case .deleteBranch(let repository, let branch):
            guard let name = Self.branch(branch) else { throw PullRequestForgeError.refused("Invalid branch name.") }
            _ = try await http.data(Self.repositoryPath(repository) + "/branches/" + name, method: "DELETE")
        case .setThreadResolved, .revert, .enableAutoMerge, .disableAutoMerge, .approveWorkflow:
            throw PullRequestForgeError.unsupported(http.name)
        }
        return nil
    }

    func merge(number: Int, method: PullRequestMergeMethod, sha: String) async throws -> String {
        _ = try await http.data(pull(number) + "/merge", method: "POST", body: Self.mergeBody(method: method, sha: sha))
        // The merge answers with nothing; the pull request itself then names the commit.
        let merged = try? await http.json(pull(number)) as? [String: Any]
        return (merged?["merge_commit_sha"] as? String) ?? ""
    }

    /// There is no reply call: a thread is the comments on one line. So a reply is a one-comment review on that line, and
    /// the line is read back from the forge, as an event does not say which side of the diff it is on.
    private func reply(to id: Int, body: String, number: Int, commit: String) async throws {
        let reviews = try await pages(pull(number) + "/reviews", limit: 3)
        guard let comment = await lineComments(reviews, number: number).first(where: { Self.int($0["id"]) == id }),
              let target = Self.lineTarget(comment) else {
            throw PullRequestForgeError.refused("\(http.name) no longer has this comment.")
        }
        let line = PullRequestAction.LineComment(path: target.path, line: target.line, side: target.left ? "LEFT" : "RIGHT", body: body)
        _ = try await http.json(pull(number) + "/reviews", method: "POST", body: Self.reviewBody(.comment, body: "", commit: commit, comments: [line]))
    }

    // MARK: Parsing

    static func detail(pull: [String: Any], repository: [String: Any]?, statuses: [[String: Any]]) -> PullRequestDetail? {
        guard var detail = PullRequestDetailParser.detail(pull: githubPull(pull), repository: repository.map(githubRepository)) else { return nil }
        detail.features = forgeFeatures
        detail.activityLoaded = false
        // The page offers draft and rebase only with this id. These actions do not read it.
        detail.nodeID = int(pull["id"]).map(String.init) ?? String(detail.number)
        detail.checks = checks(statuses, pageURL: detail.url)
        return detail
    }

    /// A pull request in the fields GitHub's parser reads. `mergeable` is also false on a draft and during a check. An
    /// open one that is not a draft cannot be merged either way, so it reads as a conflict until a later read says otherwise.
    static func githubPull(_ pull: [String: Any]) -> [String: Any] {
        var result = pull
        let open = (pull["state"] as? String) == "open" && (pull["merged"] as? Bool) != true
        let draft = isDraft(pull)
        result["draft"] = draft
        result["locked"] = pull["is_locked"]
        result["maintainer_can_modify"] = pull["allow_maintainer_edit"]
        result["requested_teams"] = pull["requested_reviewers_teams"]
        let mergeable = pull["mergeable"] as? Bool
        result["mergeable"] = open && !draft ? mergeable : nil
        if !open {
            result["mergeable_state"] = "unknown"
        } else if draft {
            result["mergeable_state"] = "draft"
        } else {
            result["mergeable_state"] = mergeable == true ? "clean" : mergeable == false ? "dirty" : "unknown"
        }
        return result
    }

    /// A repository in the fields GitHub's parser reads, where the merge methods are named differently.
    static func githubRepository(_ repository: [String: Any]) -> [String: Any] {
        var result = repository
        result["allow_merge_commit"] = repository["allow_merge_commits"]
        result["allow_rebase_merge"] = repository["allow_rebase"]
        return result
    }

    /// Older servers have no `draft` field and only the title says.
    static func isDraft(_ pull: [String: Any]) -> Bool {
        if let draft = pull["draft"] as? Bool { return draft }
        let title = ((pull["title"] as? String) ?? "").lowercased()
        return title.hasPrefix("wip:") || title.hasPrefix("[wip]")
    }

    static func links(_ list: [[String: Any]], branch: String, repo: RemoteRepository) -> [PullRequestLink] {
        list.compactMap { item in
            guard ((item["head"] as? [String: Any])?["ref"] as? String) == branch, let number = int(item["number"]) else { return nil }
            let merged = (item["merged"] as? Bool) == true
            let state: PullRequestState = merged ? .merged : (item["state"] as? String) != "open" ? .closed : isDraft(item) ? .draft : .open
            return PullRequestLink(host: repo.host, repository: repo.displayName, number: number, url: (item["html_url"] as? String) ?? "",
                                   title: item["title"] as? String, state: state, updatedAt: PullRequestDetailParser.date(item["updated_at"]),
                                   baseBranch: (item["base"] as? [String: Any])?["ref"] as? String, headBranch: branch,
                                   conflicted: state == .open && (item["mergeable"] as? Bool) == false)
        }
    }

    /// Commit statuses, failing first. Forge Actions gives its links relative to the server, hence `pageURL`.
    static func checks(_ statuses: [[String: Any]], pageURL: URL?) -> [PullRequestCheck] {
        let result = statuses.map { status -> PullRequestCheck in
            let state = (status["status"] as? String) ?? (status["state"] as? String) ?? ""
            let description = (status["description"] as? String) ?? ""
            let context = (status["context"] as? String) ?? ""
            return PullRequestCheck(name: context.isEmpty ? "check" : context, outcome: outcome(state),
                                    detail: description.isEmpty ? state : description,
                                    url: (status["target_url"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0, relativeTo: pageURL)?.absoluteURL },
                                    reporter: (status["creator"] as? [String: Any])?["login"] as? String)
        }
        return GitLabPullRequestForge.failingFirst(result)
    }

    /// Forgejo Actions reports a job that did not run as skipped, and warning is finished without being a pass. Only
    /// pending and words Nook does not know stay open.
    static func outcome(_ state: String) -> PullRequestCheck.Outcome {
        switch state {
        case "success": return .passing
        case "failure", "error": return .failing
        case "skipped", "warning": return .skipped
        default: return .pending
        }
    }

    /// The timeline, oldest first. A thread is every comment on one side of a line, as the forge's own page groups them.
    static func events(reviews: [[String: Any]], comments: [[String: Any]], lineComments: [[String: Any]],
                       commits: [PullRequestCommit]) -> [PullRequestEvent] {
        let sorted = lineComments.enumerated().sorted {
            (PullRequestDetailParser.date($0.element["created_at"]) ?? .distantPast, $0.offset)
                < (PullRequestDetailParser.date($1.element["created_at"]) ?? .distantPast, $1.offset)
        }.map(\.element)
        var roots: [String: Int] = [:]
        var threads: [String: PullRequestThreadState] = [:]
        var lines: [[String: Any]] = []
        for comment in sorted {
            guard let id = int(comment["id"]), let target = lineTarget(comment) else { continue }
            let key = "\(target.path)\n\(target.left)\n\(target.line)"
            var github = comment
            github["line"] = target.line
            if let root = roots[key] {
                github["in_reply_to_id"] = root
            } else {
                roots[key] = id
                let resolved = !((comment["resolver"] ?? NSNull()) is NSNull)
                threads["line-\(id)"] = PullRequestThreadState(resolved: resolved, outdated: false)
            }
            lines.append(github)
        }
        return PullRequestDetailParser.applying(threads, to: PullRequestDetailParser.events(
            reviews: reviews.compactMap(githubReview), comments: comments, lineComments: lines, commits: commits))
    }

    /// A review in GitHub's words, or nil for what is no review: the entry a request for one leaves behind.
    static func githubReview(_ review: [String: Any]) -> [String: Any]? {
        var result = review
        switch (review["state"] as? String)?.uppercased() {
        case "REQUEST_REVIEW": return nil
        case "REQUEST_CHANGES": result["state"] = "CHANGES_REQUESTED"
        case "COMMENT": result["state"] = "COMMENTED"
        default: break
        }
        if (review["dismissed"] as? Bool) == true { result["state"] = "DISMISSED" }
        return result
    }

    /// Where a line comment sits. The number is in `position` on the new side and in `original_position` on the old one.
    static func lineTarget(_ comment: [String: Any]) -> (path: String, line: Int, left: Bool)? {
        guard let path = comment["path"] as? String else { return nil }
        let new = int(comment["position"]) ?? 0, old = int(comment["original_position"]) ?? 0
        return new > 0 ? (path, new, false) : (path, old, old > 0)
    }

    static func labelIDs(_ names: [String], in labels: [[String: Any]]) -> [Int] {
        names.compactMap { name in
            let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
            return labels.first { ($0["name"] as? String)?.lowercased() == wanted }.flatMap { int($0["id"]) }
        }
    }

    // MARK: Building

    static func reviewBody(_ verdict: PullRequestAction.Verdict, body: String, commit: String,
                           comments: [PullRequestAction.LineComment]) -> [String: Any] {
        let event: String
        switch verdict {
        case .approve: event = "APPROVED"
        case .requestChanges: event = "REQUEST_CHANGES"
        case .comment: event = "COMMENT"
        }
        var payload: [String: Any] = ["event": event, "body": body.trimmingCharacters(in: .whitespacesAndNewlines)]
        if !commit.isEmpty { payload["commit_id"] = commit }
        if !comments.isEmpty {
            payload["comments"] = comments.map { comment -> [String: Any] in
                let left = comment.side == "LEFT"
                return ["path": comment.path, "body": comment.body,
                        "new_position": left ? 0 : comment.line, "old_position": left ? comment.line : 0]
            }
        }
        return payload
    }

    /// With `head_commit_id`, the forge refuses when someone pushed since the page was read.
    static func mergeBody(method: PullRequestMergeMethod, sha: String) -> [String: Any] {
        var body: [String: Any] = ["Do": method.rawValue]
        if !sha.isEmpty { body["head_commit_id"] = sha }
        return body
    }

    /// A draft is a title prefix on every server that has no draft call. "WIP:" is the default both forges read.
    static func title(_ title: String, draft: Bool) -> String {
        var clean = title.trimmingCharacters(in: .whitespaces)
        for prefix in ["wip:", "[wip]"] where clean.lowercased().hasPrefix(prefix) {
            clean = clean.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
        return draft ? "WIP: " + clean : clean
    }

    // MARK: Helpers

    private static func words(_ text: String) throws -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw PullRequestForgeError.refused("This needs some text.") }
        return clean
    }

    private static func segment(_ text: String) -> String? {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~")))
    }

    /// "/repos/owner/name", each part encoded on its own.
    private static func repositoryPath(_ path: String) -> String {
        "/repos/" + path.split(separator: "/").map { segment(String($0)) ?? String($0) }.joined(separator: "/")
    }

    /// A branch address keeps its slashes: the route takes the rest of the path.
    private static func branch(_ name: String) -> String? {
        let parts = name.split(separator: "/").compactMap { segment(String($0)) }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }
}
