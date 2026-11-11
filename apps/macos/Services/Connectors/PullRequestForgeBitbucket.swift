import Foundation

/// Pull requests on Bitbucket Cloud, through its REST API 2.0. Reviews are per person (`participants`) instead of a list
/// of their own, so the timeline builds them from the pull request.
struct BitbucketPullRequestForge: PullRequestForgeClient {
    /// Bitbucket has no labels, emoji on comments, auto-merge, branch update or revert. Drafts are shown, but turning one
    /// into the other is not offered: no call for it has been tried against Bitbucket yet.
    static let forgeFeatures: PullRequestForgeFeatures = {
        var features = PullRequestForgeFeatures()
        features.labels = false
        features.reactions = false
        features.autoMerge = false
        features.draft = false
        features.updateBranch = false
        // Bitbucket Cloud has no revert API.
        features.revert = false
        return features
    }()

    static let name = "Bitbucket"
    static let api = "https://api.bitbucket.org/2.0"

    let repo: RemoteRepository
    let http: ForgeHTTP
    var features: PullRequestForgeFeatures { Self.forgeFeatures }

    init?(_ repo: RemoteRepository) {
        // The API lives on one host, so the token of a self-hosted Bitbucket must never travel there.
        guard repo.hostName == "bitbucket.org", repo.segments.count == 2,
              let token = ForgeEnvironment.token( repo.hostName) else { return nil }
        self.repo = repo
        http = ForgeHTTP(name: Self.name, base: Self.api,
                         headers: ["Authorization": "Basic " + Data(token.utf8).base64EncodedString()])
    }

    private var repository: String { Self.repositoryPath(repo.path) }
    private func pull(_ number: Int) -> String { repository + "/pullrequests/\(number)" }

    // MARK: Reading

    func requests(branch: String) async -> [PullRequestLink]? {
        guard let page = try? await http.json(Self.requestsPath(repo.path, branch: branch)) as? [String: Any] else { return nil }
        return Self.links((page["values"] as? [[String: Any]]) ?? [], repo: repo)
    }

    func summary(number: Int) async throws -> PullRequestDetail {
        async let diffstat = try? pages(pull(number) + "/diffstat?pagelen=100")
        async let statuses = try? pages(pull(number) + "/statuses?pagelen=100")
        async let conflicts = try? pages(pull(number) + "/conflicts")
        guard let item = try await http.json(pull(number) + "?fields=%2Bclosed_on") as? [String: Any],
              let detail = Self.detail(pull: item, repo: repo, diffstat: await diffstat ?? [], statuses: await statuses ?? [],
                                       conflicts: await conflicts) else {
            throw PullRequestForgeError.refused("\(Self.name) did not send this pull request.")
        }
        return detail
    }

    func activity(number: Int) async -> PullRequestActivity {
        async let item = try? http.json(pull(number)) as? [String: Any]
        async let comments = try? pages(pull(number) + "/comments?pagelen=100")
        async let commits = try? pages(pull(number) + "/commits?pagelen=100")
        async let diffstat = try? pages(pull(number) + "/diffstat?pagelen=100")
        async let diff = try? http.text(pull(number) + "/diff")
        let history = Self.commits(await commits ?? [])
        return PullRequestActivity(events: Self.events(pull: await item ?? [:], comments: await comments ?? [], commits: history),
                                   commits: history, files: Self.files(diff: await diff ?? "", diffstat: await diffstat ?? []))
    }

    func commitFiles(sha: String) async throws -> [PullRequestFile] {
        UnifiedDiffFiles.split(try await http.text(repository + "/diff/" + RemoteRepository.encode(sha)))
    }

    func viewer() async -> String {
        let user = (try? await http.json("/user")) as? [String: Any]
        return (user?["nickname"] as? String) ?? (user?["display_name"] as? String) ?? ""
    }

    func labels() async -> [PullRequestLabelChoice] { [] }

    /// Every page of a list, up to `limit`: Bitbucket's lists are paged by an address it hands out.
    private func pages(_ path: String, limit: Int = 10) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var next: String? = path
        for _ in 0..<limit {
            guard let current = next else { break }
            let page = (try await http.json(current) as? [String: Any]) ?? [:]
            rows += (page["values"] as? [[String: Any]]) ?? []
            next = Self.nextPath(page["next"])
        }
        return rows
    }

    // MARK: Actions

    @discardableResult
    func perform(_ action: PullRequestAction, number: Int, detail: PullRequestDetail) async throws -> String? {
        switch action {
        case .review(let verdict, let body):
            try await review(verdict, body: body, comments: [], number: number)
        case .reviewWithComments(let verdict, let body, _, let comments):
            try await review(verdict, body: body, comments: comments, number: number)
        case .comment(let body):
            try await post(pull(number) + "/comments", ["content": ["raw": body]])
        case .reply(let id, let body):
            try await post(pull(number) + "/comments", ["content": ["raw": body], "parent": ["id": id]])
        case .editComment(let id, _, let body):
            _ = try await http.json(pull(number) + "/comments/\(id)", method: "PUT", body: ["content": ["raw": body]])
        case .setThreadResolved(let threadID, let resolved):
            _ = try await http.json(pull(number) + "/comments/\(RemoteRepository.encode(threadID))/resolve",
                                    method: resolved ? "POST" : "DELETE")
        case .close:
            try await post(pull(number) + "/decline")
        case .edit(let title, let body):
            _ = try await http.json(pull(number), method: "PUT", body: ["title": title, "description": body])
        case .changeBase(let branch):
            _ = try await http.json(pull(number), method: "PUT", body: ["destination": ["branch": ["name": branch]]])
        case .requestReviewers(let people):
            try await requestReviewers(people, number: number)
        case .deleteBranch(let repository, let branch):
            _ = try await http.json(Self.repositoryPath(repository) + "/refs/branches/" + RemoteRepository.encode(branch), method: "DELETE")
        case .reopen, .updateBranch, .addLabels, .removeLabel, .markReady, .markDraft, .approveWorkflow, .rebaseBranch, .revert,
             .setMaintainerEdits, .enableAutoMerge, .disableAutoMerge:
            throw PullRequestForgeError.unsupported(Self.name)
        }
        return nil
    }

    /// Bitbucket's merge cannot be held to a commit, so the head is compared first; that leaves only a moment for a push.
    func merge(number: Int, method: PullRequestMergeMethod, sha: String) async throws -> String {
        if !sha.isEmpty {
            let item = try await http.json(pull(number)) as? [String: Any]
            let head = Self.headSHA(item ?? [:])
            guard Self.sameCommit(head, sha) else {
                throw PullRequestForgeError.refused("The branch changed since you opened it. Look at the new commits and try again.")
            }
        }
        let answer = try await http.json(pull(number) + "/merge", method: "POST", body: ["merge_strategy": Self.mergeStrategy(method)])
        return ((answer as? [String: Any])?["merge_commit"] as? [String: Any])?["hash"] as? String ?? ""
    }

    private func post(_ path: String, _ body: [String: Any]? = nil) async throws {
        _ = try await http.json(path, method: "POST", body: body)
    }

    /// The comments go first: a review that fails halfway must not leave an approval behind.
    private func review(_ verdict: PullRequestAction.Verdict, body: String, comments: [PullRequestAction.LineComment], number: Int) async throws {
        for comment in comments { try await post(pull(number) + "/comments", Self.lineCommentBody(comment)) }
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await post(pull(number) + "/comments", ["content": ["raw": body]])
        }
        switch verdict {
        case .comment: break
        case .approve: try await post(pull(number) + "/approve")
        case .requestChanges: try await post(pull(number) + "/request-changes")
        }
    }

    /// Bitbucket asks for reviewers by uuid and replaces the whole list, so the names are looked up among the workspace's
    /// members and added to the ones already asked.
    private func requestReviewers(_ people: [String], number: Int) async throws {
        let workspace = RemoteRepository.encode(repo.segments[0])
        let members = try await pages("/workspaces/\(workspace)/members?pagelen=100", limit: 20)
        let item = (try await http.json(pull(number)) as? [String: Any]) ?? [:]
        let reviewers = try Self.reviewerIDs(people, members: members, current: (item["reviewers"] as? [[String: Any]]) ?? [])
        _ = try await http.json(pull(number), method: "PUT", body: ["reviewers": reviewers.map { ["uuid": $0] }])
    }

    // MARK: Requests

    static func repositoryPath(_ path: String) -> String {
        "/repositories/" + path.split(separator: "/").map { RemoteRepository.encode(String($0)) }.joined(separator: "/")
    }

    /// Without a `state` Bitbucket only lists open pull requests.
    static func requestsPath(_ path: String, branch: String) -> String {
        let literal = branch.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let states = ["OPEN", "MERGED", "DECLINED", "SUPERSEDED"].map { "state=" + $0 }.joined(separator: "&")
        return repositoryPath(path) + "/pullrequests?\(states)&pagelen=50&sort=-updated_on&q="
            + RemoteRepository.encode("source.branch.name = \"\(literal)\"")
    }

    /// The next page's address, without the API's own start. Any other address is not followed, so the token stays there.
    static func nextPath(_ next: Any?) -> String? {
        guard let text = next as? String, text.hasPrefix(api + "/") else { return nil }
        return String(text.dropFirst(api.count))
    }

    static func mergeStrategy(_ method: PullRequestMergeMethod) -> String {
        switch method {
        case .merge: return "merge_commit"
        case .squash: return "squash"
        // Plain `fast_forward` refuses a branch that fell behind; this one rebases it first, as "rebase" says.
        case .rebase: return "rebase_fast_forward"
        }
    }

    /// `to` is a line of the new file, `from` one of the old file; Bitbucket takes one of them. A comment on several lines
    /// names its first line too, as `start_to` or `start_from` by the side it starts on.
    static func lineCommentBody(_ comment: PullRequestAction.LineComment) -> [String: Any] {
        var inline: [String: Any] = ["path": comment.path, comment.side == "LEFT" ? "from" : "to": comment.line]
        if let start = comment.startLine {
            let side = comment.startSide ?? comment.side
            if start != comment.line || side != comment.side { inline[side == "LEFT" ? "start_from" : "start_to"] = start }
        }
        return ["content": ["raw": comment.body], "inline": inline]
    }

    /// The uuids of the reviewers already asked and of `people`, by nickname or name. A name nobody has is refused
    /// instead of dropped, so a typo does not look like a request that went out.
    static func reviewerIDs(_ people: [String], members: [[String: Any]], current: [[String: Any]]) throws -> [String] {
        var ids = current.compactMap { $0["uuid"] as? String }
        for person in people {
            let wanted = person.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased()
            let found = members.lazy.compactMap { $0["user"] as? [String: Any] }.first { user in
                [user["nickname"], user["display_name"]].contains { ($0 as? String)?.lowercased() == wanted }
            }
            guard let uuid = found?["uuid"] as? String else {
                throw PullRequestForgeError.refused("\(name) knows no one called \(person) in this workspace.")
            }
            if !ids.contains(uuid) { ids.append(uuid) }
        }
        return ids
    }

    // MARK: Parsing

    static func detail(pull: [String: Any], repo: RemoteRepository, diffstat: [[String: Any]] = [], statuses: [[String: Any]] = [],
                       conflicts: [[String: Any]]? = nil) -> PullRequestDetail? {
        guard let number = int(pull["id"]) else { return nil }
        let state = self.state(pull)
        let open = state == .open || state == .draft
        // The list of conflicts is only meaningful while the pull request can still merge.
        let conflicted = open ? conflicts.map { !$0.isEmpty } : nil
        let source = pull["source"] as? [String: Any]
        let reviewers = (pull["reviewers"] as? [[String: Any]]) ?? []
        var detail = PullRequestDetail(
            repo: repo.path, number: number, title: (pull["title"] as? String) ?? "Untitled",
            body: (pull["description"] as? String) ?? "", url: webURL(pull), author: login(pull["author"]), state: state,
            baseBranch: branch(pull["destination"]), headBranch: branch(source), headSHA: headSHA(pull),
            additions: diffstat.reduce(0) { $0 + (int($1["lines_added"]) ?? 0) },
            deletions: diffstat.reduce(0) { $0 + (int($1["lines_removed"]) ?? 0) },
            changedFiles: diffstat.count, created: PullRequestDetailParser.date(pull["created_on"]),
            // `updated_on` moves with every later comment; a closed pull request has its own date.
            updated: PullRequestDetailParser.date(pull["closed_on"]) ?? PullRequestDetailParser.date(pull["updated_on"]),
            mergeable: conflicted.map { !$0 }, mergeState: conflicted.map { $0 ? "dirty" : "clean" } ?? "unknown")
        detail.checks = checks(statuses)
        let answered = Set(reviews(pull).map(\.author))
        detail.requestedReviewers = reviewers.map { login($0) }.filter { !answered.contains($0) }
        detail.headRepository = (source?["repository"] as? [String: Any])?["full_name"] as? String
        if let head = detail.headRepository, head.lowercased() != repo.path.lowercased() {
            detail.headOwner = head.split(separator: "/").first.map(String.init)
        }
        detail.features = forgeFeatures
        detail.activityLoaded = false
        return detail
    }

    static func state(_ pull: [String: Any]) -> PullRequestDetail.State {
        switch ((pull["state"] as? String) ?? "").uppercased() {
        case "MERGED": return .merged
        case "DECLINED", "SUPERSEDED": return .closed
        default: return (pull["draft"] as? Bool) == true ? .draft : .open
        }
    }

    /// A branch of the same name on a fork is another pull request's business.
    static func links(_ list: [[String: Any]], repo: RemoteRepository) -> [PullRequestLink] {
        list.compactMap { item in
            guard let number = int(item["id"]) else { return nil }
            let source = item["source"] as? [String: Any]
            if let head = (source?["repository"] as? [String: Any])?["full_name"] as? String,
               head.lowercased() != repo.path.lowercased() { return nil }
            let state = self.state(item)
            return PullRequestLink(host: repo.host, repository: repo.path, number: number, url: webURL(item)?.absoluteString ?? "",
                                   title: item["title"] as? String, state: PullRequestState(rawValue: state.rawValue) ?? .open,
                                   updatedAt: PullRequestDetailParser.date(item["updated_on"]),
                                   baseBranch: branch(item["destination"]), headBranch: branch(source))
        }
    }

    /// Commit statuses of the head. A re-run keeps its key, and the later entry is its state.
    static func checks(_ statuses: [[String: Any]]) -> [PullRequestCheck] {
        var order: [String] = []
        var latest: [String: [String: Any]] = [:]
        for status in statuses {
            let name = (status["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (status["key"] as? String) ?? ""
            guard !name.isEmpty else { continue }
            let key = (status["key"] as? String) ?? name
            if latest[key] == nil { order.append(key) }
            let state: String
            switch ((status["state"] as? String) ?? "").uppercased() {
            case "SUCCESSFUL": state = "success"
            case "FAILED", "STOPPED": state = "failure"
            default: state = "pending"
            }
            latest[key] = ["context": name, "state": state, "description": (status["description"] as? String) ?? "",
                           "target_url": (status["url"] as? String) ?? ""]
        }
        return PullRequestDetailParser.checks(runs: [], statuses: order.compactMap { latest[$0] })
    }

    /// Bitbucket lists a pull request's commits newest first; the page reads oldest first.
    static func commits(_ list: [[String: Any]]) -> [PullRequestCommit] {
        list.reversed().compactMap { item in
            guard let sha = item["hash"] as? String else { return nil }
            let author = item["author"] as? [String: Any]
            var name = login(author?["user"])
            if name == "?", let raw = author?["raw"] as? String {
                // "Ada Lovelace <ada@example.com>" when the address belongs to no account.
                name = raw.components(separatedBy: " <").first ?? raw
            }
            return PullRequestCommit(sha: sha, message: (item["message"] as? String) ?? "", author: name,
                                     date: PullRequestDetailParser.date(item["date"]))
        }
    }

    /// The whole timeline, oldest first: commits, each person's verdict and the comments.
    static func events(pull: [String: Any], comments list: [[String: Any]], commits: [PullRequestCommit]) -> [PullRequestEvent] {
        let history = commits.map {
            PullRequestEvent(id: "commit-" + $0.sha, kind: .commit(sha: $0.sha), author: $0.author, body: $0.subject, date: $0.date, url: nil)
        }
        let all = history + reviews(pull) + comments(list)
        return all.enumerated().sorted {
            ($0.element.date ?? .distantPast, $0.offset) < ($1.element.date ?? .distantPast, $1.offset)
        }.map(\.element)
    }

    /// Bitbucket keeps one verdict per person on the pull request, with no text.
    static func reviews(_ pull: [String: Any]) -> [PullRequestEvent] {
        ((pull["participants"] as? [[String: Any]]) ?? []).compactMap { participant in
            let state: String
            switch ((participant["state"] as? String) ?? "").lowercased() {
            case "approved": state = "APPROVED"
            case "changes_requested": state = "CHANGES_REQUESTED"
            default:
                guard (participant["approved"] as? Bool) == true else { return nil }
                state = "APPROVED"
            }
            let author = login(participant["user"])
            return PullRequestEvent(id: "review-" + author, kind: .review(state), author: author, body: "",
                                    date: PullRequestDetailParser.date(participant["participated_on"]), url: nil)
        }
    }

    /// Comments as timeline events. A reply can answer a reply, while the page wants the thread's first comment, so each
    /// is walked up to it. A reply takes its place in the code from there too. `threadID` is that comment's id, which is
    /// what resolving asks for.
    static func comments(_ list: [[String: Any]]) -> [PullRequestEvent] {
        let kept = list.filter { comment in
            (comment["deleted"] as? Bool) != true && (comment["pending"] as? Bool) != true
                && !text(comment).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var byID: [Int: [String: Any]] = [:]
        for comment in kept { if let id = int(comment["id"]) { byID[id] = comment } }
        func root(of comment: [String: Any]) -> [String: Any] {
            var current = comment
            // Bounded, so a loop in what Bitbucket sent cannot hang the page.
            for _ in 0..<kept.count {
                guard let parent = int((current["parent"] as? [String: Any])?["id"]), let next = byID[parent] else { break }
                current = next
            }
            return current
        }
        return kept.compactMap { comment -> PullRequestEvent? in
            guard let id = int(comment["id"]) else { return nil }
            let body = text(comment)
            let date = PullRequestDetailParser.date(comment["created_on"])
            let url = (((comment["links"] as? [String: Any])?["html"] as? [String: Any])?["href"] as? String).flatMap(URL.init(string:))
            let top = root(of: comment)
            let inline = top["inline"] as? [String: Any]
            guard let path = inline?["path"] as? String, !path.isEmpty else {
                var event = PullRequestEvent(id: "comment-\(id)", kind: .comment, author: login(comment["user"]), body: body, date: date, url: url)
                event.rawBody = body
                return event
            }
            let rootID = int(top["id"]) ?? id
            let line = [int(inline?["to"]), int(inline?["from"])].compactMap { $0 }.first { $0 > 0 }
            var event = PullRequestEvent(id: "line-\(id)", kind: .lineComment(path: path, line: line), author: login(comment["user"]),
                                         body: body, date: date, url: url)
            event.replyTo = rootID == id ? nil : "line-\(rootID)"
            event.threadID = String(rootID)
            event.resolved = rootID == id && top["resolution"] is [String: Any]
            event.outdated = (inline?["outdated"] as? Bool) == true
            event.rawBody = body
            return event
        }
    }

    /// The diffstat knows every file, also the binary ones without a patch; the diff adds the patches. Without a diffstat
    /// the diff alone still shows the changes.
    static func files(diff: String, diffstat: [[String: Any]]) -> [PullRequestFile] {
        let patches = UnifiedDiffFiles.split(diff)
        guard !diffstat.isEmpty else { return patches }
        return diffstat.compactMap { entry in
            let new = (entry["new"] as? [String: Any])?["path"] as? String
            let old = (entry["old"] as? [String: Any])?["path"] as? String
            guard let path = new ?? old else { return nil }
            let status = ((entry["status"] as? String) ?? "").lowercased()
            return PullRequestFile(path: path, status: ["added", "removed", "renamed"].contains(status) ? status : "modified",
                                   additions: int(entry["lines_added"]) ?? 0, deletions: int(entry["lines_removed"]) ?? 0,
                                   patch: patches.first { $0.path == path }?.patch, previousPath: status == "renamed" ? old : nil)
        }
    }

    /// Bitbucket shortens hashes in a pull request and not in a commit list, so a short one matches a long one.
    static func sameCommit(_ one: String, _ other: String) -> Bool {
        !one.isEmpty && !other.isEmpty && (one.hasPrefix(other) || other.hasPrefix(one))
    }

    static func headSHA(_ pull: [String: Any]) -> String {
        ((pull["source"] as? [String: Any])?["commit"] as? [String: Any])?["hash"] as? String ?? ""
    }

    private static func webURL(_ pull: [String: Any]) -> URL? {
        (((pull["links"] as? [String: Any])?["html"] as? [String: Any])?["href"] as? String).flatMap(URL.init(string:))
    }

    private static func branch(_ side: Any?) -> String {
        ((side as? [String: Any])?["branch"] as? [String: Any])?["name"] as? String ?? ""
    }

    /// App accounts have no nickname, only a display name.
    private static func login(_ user: Any?) -> String {
        let user = user as? [String: Any]
        return (user?["nickname"] as? String) ?? (user?["display_name"] as? String) ?? "?"
    }

    private static func text(_ comment: [String: Any]) -> String {
        (comment["content"] as? [String: Any])?["raw"] as? String ?? ""
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }
}
