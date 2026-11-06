import Foundation

/// Pull requests on Azure DevOps, through its Git REST API. Azure talks in threads, each with its own run of comment
/// numbers, and gives no patch: a file is only a path and a kind of change (see `files`).
struct AzureDevOpsPullRequestForge: PullRequestForgeClient {
    /// Azure's API has no diff, so a commit's own changes would be a list of names. It has no emoji, and a branch update
    /// and a revert have no call of their own. Reviewers and labels stay readable: adding a reviewer needs an identity
    /// lookup on another host, and labels have no list of a repository's own to choose from.
    static let forgeFeatures: PullRequestForgeFeatures = {
        var features = PullRequestForgeFeatures()
        features.labels = false
        features.reviewers = false
        features.reactions = false
        features.updateBranch = false
        features.revert = false
        features.commitView = false
        return features
    }()

    static let name = "Azure DevOps"
    static let apiVersion = "api-version=7.1"
    /// What Azure wants as a commit or identity that is not there.
    static let zeroCommit = String(repeating: "0", count: 40)
    static let noIdentity = "00000000-0000-0000-0000-000000000000"
    /// Comment numbers restart in every thread, so one number for the page holds both: thread × this + comment.
    static let threadFactor = 100_000

    let repo: RemoteRepository
    /// The repository's API.
    let http: ForgeHTTP
    /// The organization's API, for who the token belongs to.
    let organization: ForgeHTTP
    var features: PullRequestForgeFeatures { Self.forgeFeatures }

    init?(_ repo: RemoteRepository) {
        guard repo.hostName == "dev.azure.com", let place = Self.location(repo.path),
              let token = ForgeEnvironment.token( repo.hostName) else { return nil }
        self.repo = repo
        let headers = ["Authorization": "Basic " + Self.credential(token)]
        let org = "https://dev.azure.com/" + RemoteRepository.encode(place.organization)
        http = ForgeHTTP(name: Self.name, base: "\(org)/\(RemoteRepository.encode(place.project))/_apis/git/repositories/"
                         + RemoteRepository.encode(place.repository), headers: headers)
        organization = ForgeHTTP(name: Self.name, base: org, headers: headers)
    }

    private func pull(_ number: Int, _ suffix: String = "", query: String = "") -> String {
        "/pullrequests/\(number)\(suffix)?\(Self.apiVersion)\(query)"
    }

    // MARK: Reading

    func requests(branch: String) async -> [PullRequestLink]? {
        guard let page = try? await http.json(Self.requestsPath(branch: branch)) as? [String: Any] else { return nil }
        return Self.links(Self.rows(page), repo: repo)
    }

    func summary(number: Int) async throws -> PullRequestDetail {
        async let statuses = try? http.json(pull(number, "/statuses")) as? [String: Any]
        guard let item = try await http.json(pull(number)) as? [String: Any],
              let detail = Self.detail(pull: item, repo: repo, statuses: Self.rows(await statuses ?? [:])) else {
            throw PullRequestForgeError.refused("\(Self.name) did not send this pull request.")
        }
        return detail
    }

    func activity(number: Int) async -> PullRequestActivity {
        async let item = try? http.json(pull(number)) as? [String: Any]
        async let threads = try? http.json(pull(number, "/threads")) as? [String: Any]
        async let commits = try? http.json(pull(number, "/commits", query: "&$top=500")) as? [String: Any]
        async let files = try? changes(number)
        let history = Self.commits(Self.rows(await commits ?? [:]))
        return PullRequestActivity(events: Self.events(pull: await item ?? [:], threads: Self.rows(await threads ?? [:]), commits: history),
                                   commits: history, files: Self.files(await files ?? []))
    }

    func commitFiles(sha: String) async throws -> [PullRequestFile] { throw PullRequestForgeError.unsupported(Self.name) }

    func labels() async -> [(name: String, color: String)] { [] }

    /// What the latest iteration (push) changed, in pages of Azure's own making.
    private func changes(_ number: Int) async throws -> [[String: Any]] {
        let iterations = (try await http.json(pull(number, "/iterations")) as? [String: Any]) ?? [:]
        guard let last = Self.rows(iterations).compactMap({ Self.int($0["id"]) }).max() else { return [] }
        var rows: [[String: Any]] = []
        var skip = 0
        for _ in 0..<20 {
            let page = (try await http.json(pull(number, "/iterations/\(last)/changes", query: "&$top=500&$skip=\(skip)")) as? [String: Any]) ?? [:]
            rows += (page["changeEntries"] as? [[String: Any]]) ?? []
            guard let next = Self.int(page["nextSkip"]), next > skip else { break }
            skip = next
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
            try await post(pull(number, "/threads"), Self.threadBody(body))
        case .reply(let id, let body):
            let place = Self.comment(id)
            try await post(pull(number, "/threads/\(place.thread)/comments"),
                           ["content": body, "parentCommentId": place.comment, "commentType": "text"])
        case .editComment(let id, _, let body):
            let place = Self.comment(id)
            try await patch(pull(number, "/threads/\(place.thread)/comments/\(place.comment)"), ["content": body])
        case .setThreadResolved(let threadID, let resolved):
            try await patch(pull(number, "/threads/\(RemoteRepository.encode(threadID))"), ["status": resolved ? "fixed" : "active"])
        case .close:
            try await patch(pull(number), ["status": "abandoned"])
        case .reopen:
            try await patch(pull(number), ["status": "active"])
        case .edit(let title, let body):
            try await patch(pull(number), ["title": title, "description": body])
        case .markReady:
            try await patch(pull(number), ["isDraft": false])
        case .markDraft:
            try await patch(pull(number), ["isDraft": true])
        case .changeBase(let branch):
            try await patch(pull(number), ["targetRefName": "refs/heads/" + branch])
        case .enableAutoMerge(_, let method):
            try await patch(pull(number), ["autoCompleteSetBy": ["id": try await viewerID()],
                                           "completionOptions": ["mergeStrategy": Self.mergeStrategy(method)]])
        case .disableAutoMerge:
            try await patch(pull(number), ["autoCompleteSetBy": ["id": Self.noIdentity]])
        case .deleteBranch(_, let branch):
            try await deleteBranch(branch, head: detail.headSHA)
        case .requestReviewers, .updateBranch, .addLabels, .removeLabel, .approveWorkflow, .rebaseBranch, .revert, .setMaintainerEdits:
            throw PullRequestForgeError.unsupported(Self.name)
        }
        return nil
    }

    /// Azure completes a pull request by a status change, and refuses when `lastMergeSourceCommit` is no longer the head.
    func merge(number: Int, method: PullRequestMergeMethod, sha: String) async throws -> String {
        var head = sha
        if head.isEmpty {
            let item = try await http.json(pull(number)) as? [String: Any]
            head = Self.commitID(item?["lastMergeSourceCommit"])
        }
        let body: [String: Any] = [
            "status": "completed", "lastMergeSourceCommit": ["commitId": head],
            "completionOptions": ["mergeStrategy": Self.mergeStrategy(method)],
        ]
        let answer = try await http.json(pull(number), method: "PATCH", body: body)
        return Self.commitID((answer as? [String: Any])?["lastMergeCommit"])
    }

    private func post(_ path: String, _ body: [String: Any]) async throws {
        _ = try await http.json(path, method: "POST", body: body)
    }

    private func patch(_ path: String, _ body: [String: Any]) async throws {
        _ = try await http.json(path, method: "PATCH", body: body)
    }

    /// The comments go first: a review that fails halfway must not leave a vote behind.
    private func review(_ verdict: PullRequestAction.Verdict, body: String, comments: [PullRequestAction.LineComment], number: Int) async throws {
        for comment in comments { try await post(pull(number, "/threads"), Self.threadBody(comment.body, line: comment)) }
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await post(pull(number, "/threads"), Self.threadBody(body))
        }
        guard let vote = Self.vote(verdict) else { return }
        let me = RemoteRepository.encode(try await viewerID())
        _ = try await http.json(pull(number, "/reviewers/\(me)"), method: "PUT", body: ["vote": vote])
    }

    /// Azure votes and sets auto-complete by identity, and the token is the only thing that says who that is.
    private func viewerID() async throws -> String {
        let answer = try await organization.json("/_apis/connectionData?api-version=7.1-preview.1") as? [String: Any]
        guard let id = (answer?["authenticatedUser"] as? [String: Any])?["id"] as? String else {
            throw PullRequestForgeError.refused("\(Self.name) did not say who this token belongs to.")
        }
        return id
    }

    /// A branch goes by updating its ref to nothing. Azure answers 200 and reports a refusal per ref.
    private func deleteBranch(_ branch: String, head: String) async throws {
        let answer = try await http.json("/refs?\(Self.apiVersion)", method: "POST", body: [Self.deleteBranchBody(branch, head: head)])
        let result = Self.rows((answer as? [String: Any]) ?? [:]).first
        guard (result?["success"] as? Bool) != false else {
            throw PullRequestForgeError.refused((result?["customMessage"] as? String) ?? "\(Self.name) kept the branch.")
        }
    }

    // MARK: Requests

    /// A pasted token has no user in front of it; Azure ignores the user.
    static func credential(_ token: String) -> String {
        Data((token.contains(":") ? token : ":" + token).utf8).base64EncodedString()
    }

    /// `org/project/_git/repo`, or `org/_git/repo` for the repository named after its project.
    static func location(_ path: String) -> (organization: String, project: String, repository: String)? {
        let parts = path.split(separator: "/").map(String.init)
        guard let git = parts.firstIndex(of: "_git"), git == 1 || git == 2, git + 2 == parts.count else { return nil }
        return (parts[0], git == 2 ? parts[1] : parts[git + 1], parts[git + 1])
    }

    static func requestsPath(branch: String) -> String {
        "/pullrequests?searchCriteria.sourceRefName=" + RemoteRepository.encode("refs/heads/" + branch)
            + "&searchCriteria.status=all&$top=50&\(apiVersion)"
    }

    static func mergeStrategy(_ method: PullRequestMergeMethod) -> String {
        switch method {
        case .merge: return "noFastForward"
        case .squash: return "squash"
        case .rebase: return "rebase"
        }
    }

    /// "Wait for author" is what a request for changes means; a rejection (-10) says the change should not land at all.
    static func vote(_ verdict: PullRequestAction.Verdict) -> Int? {
        switch verdict {
        case .comment: return nil
        case .approve: return 10
        case .requestChanges: return -5
        }
    }

    /// A new thread: on the whole pull request, or on a line. Azure counts offsets from 1 and wants both ends.
    static func threadBody(_ text: String, line: PullRequestAction.LineComment? = nil) -> [String: Any] {
        let comment: [String: Any] = ["parentCommentId": 0, "content": text, "commentType": "text"]
        var body: [String: Any] = ["comments": [comment], "status": "active"]
        if let line {
            let side = line.side == "LEFT" ? "left" : "right"
            body["threadContext"] = [
                "filePath": "/" + line.path,
                side + "FileStart": ["line": line.startLine ?? line.line, "offset": 1],
                side + "FileEnd": ["line": line.line, "offset": 1],
            ] as [String: Any]
        }
        return body
    }

    static func deleteBranchBody(_ branch: String, head: String) -> [String: Any] {
        ["name": "refs/heads/" + branch, "oldObjectId": head, "newObjectId": zeroCommit]
    }

    /// The number the page knows a comment by.
    static func commentNumber(thread: Int, comment: Int) -> Int { thread * threadFactor + comment }

    /// The thread and comment inside that number.
    static func comment(_ number: Int) -> (thread: Int, comment: Int) { (number / threadFactor, number % threadFactor) }

    // MARK: Parsing

    static func detail(pull: [String: Any], repo: RemoteRepository, statuses: [[String: Any]] = []) -> PullRequestDetail? {
        guard let number = int(pull["pullRequestId"]) else { return nil }
        let merge = mergeability(pull)
        var detail = PullRequestDetail(
            repo: repo.path, number: number, title: (pull["title"] as? String) ?? "Untitled",
            body: (pull["description"] as? String) ?? "", url: repo.pullRequestURL(number: number),
            author: login(pull["createdBy"]), state: state(pull),
            baseBranch: branch(pull["targetRefName"]), headBranch: branch(pull["sourceRefName"]),
            headSHA: commitID(pull["lastMergeSourceCommit"]),
            // Azure counts neither lines nor files on a pull request; the files arrive with the activity.
            additions: 0, deletions: 0, changedFiles: 0, created: PullRequestDetailParser.date(pull["creationDate"]),
            updated: PullRequestDetailParser.date(pull["closedDate"]) ?? PullRequestDetailParser.date(pull["creationDate"]),
            mergeable: merge.mergeable, mergeState: merge.state)
        detail.checks = checks(statuses)
        let reviewers = (pull["reviewers"] as? [[String: Any]]) ?? []
        let waiting = reviewers.filter { (int($0["vote"]) ?? 0) == 0 }
        detail.requestedReviewers = waiting.map { login($0) }
        detail.requestedTeams = waiting.filter { ($0["isContainer"] as? Bool) == true }.map { login($0) }
        detail.labels = ((pull["labels"] as? [[String: Any]]) ?? []).filter { ($0["active"] as? Bool) != false }.compactMap { $0["name"] as? String }
        if let owner = pull["autoCompleteSetBy"] as? [String: Any] {
            detail.autoMerge = PullRequestAutoMerge(method: method(pull), enabledBy: login(owner))
        }
        detail.autoMergeAllowed = true
        // A fork's ref cannot be deleted through this repository's API, so it is not offered.
        detail.headRepository = pull["forkSource"] is [String: Any] ? nil : repo.path
        // The page offers draft and auto-merge actions by this id. Azure's address needs only the number.
        detail.nodeID = String(number)
        detail.features = forgeFeatures
        detail.activityLoaded = false
        return detail
    }

    static func state(_ pull: [String: Any]) -> PullRequestDetail.State {
        switch ((pull["status"] as? String) ?? "").lowercased() {
        case "completed": return .merged
        case "abandoned": return .closed
        default: return (pull["isDraft"] as? Bool) == true ? .draft : .open
        }
    }

    /// Azure works this out in the background: `queued` and `notSet` are no answer yet. A rejection by policy is no
    /// conflict in the code, so it stops short of the page's conflict note.
    static func mergeability(_ pull: [String: Any]) -> (mergeable: Bool?, state: String) {
        switch ((pull["mergeStatus"] as? String) ?? "").lowercased() {
        case "succeeded": return (true, "clean")
        case "conflicts", "failure": return (false, "dirty")
        case "rejectedbypolicy": return (true, "blocked")
        default: return (nil, "unknown")
        }
    }

    private static func method(_ pull: [String: Any]) -> PullRequestMergeMethod? {
        let options = pull["completionOptions"] as? [String: Any]
        switch ((options?["mergeStrategy"] as? String) ?? "").lowercased() {
        case "squash": return .squash
        case "rebase", "rebasemerge": return .rebase
        case "nofastforward": return .merge
        default: return (options?["squashMerge"] as? Bool) == true ? .squash : nil
        }
    }

    static func links(_ list: [[String: Any]], repo: RemoteRepository) -> [PullRequestLink] {
        list.compactMap { item in
            guard let number = int(item["pullRequestId"]) else { return nil }
            return PullRequestLink(host: repo.host, repository: repo.path, number: number,
                                   url: repo.pullRequestURL(number: number)?.absoluteString ?? "", title: item["title"] as? String,
                                   state: PullRequestState(rawValue: state(item).rawValue) ?? .open,
                                   updatedAt: PullRequestDetailParser.date(item["closedDate"]) ?? PullRequestDetailParser.date(item["creationDate"]),
                                   baseBranch: branch(item["targetRefName"]), headBranch: branch(item["sourceRefName"]),
                                   conflicted: (item["mergeStatus"] as? String)?.lowercased() == "conflicts")
        }
    }

    /// Statuses of all pushes come back together; the newest per context counts. `notApplicable` asks nothing of anyone.
    static func checks(_ statuses: [[String: Any]]) -> [PullRequestCheck] {
        var order: [String] = []
        var latest: [String: (id: Int, status: [String: Any])] = [:]
        for status in statuses {
            let context = status["context"] as? [String: Any]
            let name = [context?["genre"] as? String, context?["name"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/")
            guard !name.isEmpty else { continue }
            let id = int(status["id"]) ?? 0
            if let held = latest[name], held.id > id { continue }
            if latest[name] == nil { order.append(name) }
            latest[name] = (id, status)
        }
        let mapped = order.compactMap { name -> [String: Any]? in
            guard let status = latest[name]?.status else { return nil }
            let state: String
            switch ((status["state"] as? String) ?? "").lowercased() {
            case "notapplicable": return nil
            case "succeeded": state = "success"
            case "failed", "error": state = "failure"
            default: state = "pending"
            }
            return ["context": name, "state": state, "description": (status["description"] as? String) ?? "",
                    "target_url": (status["targetUrl"] as? String) ?? ""]
        }
        return PullRequestDetailParser.checks(runs: [], statuses: mapped)
    }

    /// Azure lists a pull request's commits newest first; the page reads oldest first.
    static func commits(_ list: [[String: Any]]) -> [PullRequestCommit] {
        let commits = list.compactMap { item -> PullRequestCommit? in
            guard let sha = item["commitId"] as? String else { return nil }
            let author = item["author"] as? [String: Any]
            return PullRequestCommit(sha: sha, message: (item["comment"] as? String) ?? "", author: (author?["name"] as? String) ?? "?",
                                     date: PullRequestDetailParser.date(author?["date"]))
        }
        return commits.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    /// The whole timeline, oldest first: commits, votes and the threads' comments.
    static func events(pull: [String: Any], threads: [[String: Any]], commits: [PullRequestCommit]) -> [PullRequestEvent] {
        let history = commits.map {
            PullRequestEvent(id: "commit-" + $0.sha, kind: .commit(sha: $0.sha), author: $0.author, body: $0.subject, date: $0.date, url: nil)
        }
        let all = history + reviews(pull) + comments(threads: threads)
        return all.enumerated().sorted {
            ($0.element.date ?? .distantPast, $0.offset) < ($1.element.date ?? .distantPast, $1.offset)
        }.map(\.element)
    }

    /// A vote is a state on the reviewer, without a date of its own. Groups vote through their members, so only people count.
    static func reviews(_ pull: [String: Any]) -> [PullRequestEvent] {
        ((pull["reviewers"] as? [[String: Any]]) ?? []).compactMap { reviewer in
            guard (reviewer["isContainer"] as? Bool) != true, let vote = int(reviewer["vote"]), vote != 0 else { return nil }
            let author = login(reviewer)
            return PullRequestEvent(id: "review-" + author, kind: .review(vote > 0 ? "APPROVED" : "CHANGES_REQUESTED"),
                                    author: author, body: "", date: nil, url: nil)
        }
    }

    /// Comments as timeline events. Azure writes its own remarks ("Ada voted 10") into threads as system comments; those
    /// are left out. A thread with a file is a line comment, its first comment the root. `threadID` is the thread's id.
    static func comments(threads: [[String: Any]]) -> [PullRequestEvent] {
        threads.flatMap { thread -> [PullRequestEvent] in
            guard (thread["isDeleted"] as? Bool) != true, let threadID = int(thread["id"]) else { return [] }
            let comments = ((thread["comments"] as? [[String: Any]]) ?? []).filter { comment in
                (comment["isDeleted"] as? Bool) != true && ((comment["commentType"] as? String) ?? "").lowercased() != "system"
                    && !((comment["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let context = thread["threadContext"] as? [String: Any]
            let path = (context?["filePath"] as? String).map { String($0.drop { $0 == "/" }) }.flatMap { $0.isEmpty ? nil : $0 }
            let root = comments.first.map { commentNumber(thread: threadID, comment: int($0["id"]) ?? 0) }
            return comments.map { comment in
                let number = commentNumber(thread: threadID, comment: int(comment["id"]) ?? 0)
                let body = (comment["content"] as? String) ?? ""
                let date = PullRequestDetailParser.date(comment["publishedDate"])
                guard let path else {
                    var event = PullRequestEvent(id: "comment-\(number)", kind: .comment, author: login(comment["author"]), body: body, date: date, url: nil)
                    event.rawBody = body
                    return event
                }
                let line = int((context?["rightFileStart"] as? [String: Any])?["line"]) ?? int((context?["leftFileStart"] as? [String: Any])?["line"])
                var event = PullRequestEvent(id: "line-\(number)", kind: .lineComment(path: path, line: line), author: login(comment["author"]),
                                             body: body, date: date, url: nil)
                event.replyTo = number == root ? nil : root.map { "line-\($0)" }
                event.threadID = String(threadID)
                event.resolved = number == root && resolved(thread)
                event.rawBody = body
                return event
            }
        }
    }

    /// Every status but these means someone still has to act on the thread.
    static func resolved(_ thread: [String: Any]) -> Bool {
        ["fixed", "wontfix", "closed", "bydesign"].contains(((thread["status"] as? String) ?? "").lowercased())
    }

    /// The changed files. Azure has no patch and no line counts: only whole files could be compared, at two reads per
    /// file, so `patch` stays nil and the Code tab lists the names.
    static func files(_ changes: [[String: Any]]) -> [PullRequestFile] {
        changes.compactMap { change in
            let item = change["item"] as? [String: Any]
            guard let raw = item?["path"] as? String, (item?["isFolder"] as? Bool) != true,
                  ((item?["gitObjectType"] as? String) ?? "blob").lowercased() == "blob" else { return nil }
            let path = String(raw.drop { $0 == "/" })
            // Azure says where a file came from in either field, depending on the route.
            let origin = ((change["sourceServerItem"] as? String) ?? (change["originalPath"] as? String)).map { String($0.drop { $0 == "/" }) }
            let previous = origin.flatMap { $0.isEmpty || $0 == path ? nil : $0 }
            let kinds = Set(((change["changeType"] as? String) ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            let status: String
            if kinds.contains("delete") { status = "removed" }
            else if kinds.contains("rename") || previous != nil { status = "renamed" }
            else if kinds.contains("add") { status = "added" }
            else { status = "modified" }
            return PullRequestFile(path: path, status: status, additions: 0, deletions: 0, patch: nil, previousPath: previous,
                                   revision: status == "removed" ? "" : item?["objectId"] as? String)
        }
    }

    static func rows(_ page: [String: Any]) -> [[String: Any]] { (page["value"] as? [[String: Any]]) ?? [] }

    private static func branch(_ ref: Any?) -> String {
        let name = (ref as? String) ?? ""
        return name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name
    }

    private static func commitID(_ commit: Any?) -> String { (commit as? [String: Any])?["commitId"] as? String ?? "" }

    /// The sign-in name, as a mention needs it; a group or service has only a display name.
    private static func login(_ identity: Any?) -> String {
        let identity = identity as? [String: Any]
        let unique = (identity?["uniqueName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return unique ?? (identity?["displayName"] as? String) ?? "?"
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }
}
