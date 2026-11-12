import Foundation

/// Pull requests on GitCafe. Every write is fenced on the pull request's `version`, so an action reads it first. Comment
/// ids are opaque text where the page works with numbers: see `number(of:)`.
struct GitCafePullRequestForge: PullRequestForgeClient {
    /// Line comments go through GitCafe's review drafts, which this client does not speak yet. It updates branches only
    /// as a whole stack, has no commit diffs, auto-merge or revert, and Nook has no action to send its emoji.
    static let forgeFeatures: PullRequestForgeFeatures = {
        var features = PullRequestForgeFeatures()
        features.lineComments = false
        features.reactions = false
        features.autoMerge = false
        features.updateBranch = false
        features.revert = false
        features.deleteBranch = false
        features.commitView = false
        // GitCafe's API has no per-file viewed state.
        features.viewedFiles = false
        return features
    }()

    static let name = "GitCafe"
    static let hosts: Set<String> = ["git.cafe", "staging.git.cafe"]
    /// GitCafe's cap on paths per `/diff-files` read.
    static let diffBatch = 64
    /// Enough for the page; files past this show without their patch.
    static let diffBatches = 16

    let repo: RemoteRepository
    let http: ForgeHTTP
    var features: PullRequestForgeFeatures { Self.forgeFeatures }

    init?(_ repo: RemoteRepository) {
        // GitCafe lives on two known hosts, and a remote must not be able to draw the token anywhere else.
        guard Self.hosts.contains(repo.hostName), let token = ForgeEnvironment.token( repo.hostName) else { return nil }
        self.repo = repo
        http = ForgeHTTP(name: Self.name, base: "https://\(repo.hostName)/api",
                         headers: ["Authorization": "Bearer " + token, "Accept": "application/json"])
    }

    private var repository: String { "/repos/" + repo.segments.map(RemoteRepository.encode).joined(separator: "/") }
    private func pull(_ number: Int) -> String { repository + "/pulls/\(number)" }

    // MARK: Reading

    func requests(branch: String) async -> [PullRequestLink]? {
        guard let rows = try? await pages(repository + "/pulls?sort=newest", limit: 3) else { return nil }
        return Self.links(rows, branch: branch, repo: repo)
    }

    func summary(number: Int) async throws -> PullRequestDetail {
        guard let item = try await http.json(pull(number)) as? [String: Any] else {
            throw PullRequestForgeError.refused("\(Self.name) did not send this pull request.")
        }
        // A single pull request carries neither its reviewers nor its labels. Reviewers need a scope a token may lack.
        async let status = try? http.json(pull(number) + "/status") as? [String: Any]
        async let reviewers = try? pages(pull(number) + "/reviewers")
        async let labels = try? pages(pull(number) + "/labels")
        async let checks = try? headChecks(item)
        async let changes = try? self.changes(number, version: Self.int(item["version"]) ?? 0)
        guard let detail = Self.detail(pull: item, repo: repo, status: await status, reviewers: await reviewers ?? [], labels: await labels ?? [],
                                       checks: await checks ?? [], changes: await changes ?? []) else {
            throw PullRequestForgeError.refused("\(Self.name) did not send this pull request.")
        }
        return detail
    }

    func activity(number: Int) async -> PullRequestActivity {
        async let item = try? http.json(pull(number)) as? [String: Any]
        async let comments = try? pages(pull(number) + "/comments")
        async let reviews = try? pages(pull(number) + "/reviews")
        async let commits = try? pages(pull(number) + "/commits")
        let current = await item ?? [:]
        async let files = try? self.files(number, version: Self.int(current["version"]) ?? 0)
        let history = Self.commits(await commits ?? [])
        return PullRequestActivity(events: Self.events(comments: await comments ?? [], reviews: await reviews ?? [], commits: history,
                                                       head: current["headOid"] as? String),
                                   commits: history, files: await files ?? [])
    }

    func commitFiles(sha: String) async throws -> [PullRequestFile] { throw PullRequestForgeError.unsupported(Self.name) }

    func labels() async -> [PullRequestLabelChoice] {
        let rows = (try? await pages(repository + "/labels")) ?? []
        return Self.labels(rows)
    }

    private func pages(_ path: String, limit: Int = 10) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var after: String?
        for _ in 0..<limit {
            let glue = path.contains("?") ? "&" : "?"
            let cursor = after.map { "&after=" + RemoteRepository.encode($0) } ?? ""
            let page = (try await http.json("\(path)\(glue)limit=100\(cursor)") as? [String: Any]) ?? [:]
            let items = (page["items"] as? [[String: Any]]) ?? []
            rows += items
            let next = page["next"] as? String
            guard let next, next != after, !items.isEmpty else { break }
            after = next
        }
        return rows
    }

    private func headChecks(_ item: [String: Any]) async throws -> [[String: Any]] {
        guard let head = item["headOid"] as? String, !head.isEmpty else { return [] }
        return try await pages(repository + "/commits/" + RemoteRepository.encode(head) + "/checks")
    }

    /// The changed paths, without hunks: those take a read per batch.
    private func changes(_ number: Int, version: Int) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var after: String?
        for _ in 0..<20 {
            let cursor = after.map { "&after=" + RemoteRepository.encode($0) } ?? ""
            let page = (try await http.json(pull(number) + "/changes?expectedVersion=\(version)&limit=500\(cursor)") as? [String: Any]) ?? [:]
            let items = (page["items"] as? [[String: Any]]) ?? []
            rows += items
            let next = page["next"] as? String
            guard let next, next != after, !items.isEmpty else { break }
            after = next
        }
        return rows
    }

    private func files(_ number: Int, version: Int) async throws -> [PullRequestFile] {
        let listed = try await changes(number, version: version)
        let paths = Self.readablePaths(listed)
        var details: [[String: Any]] = []
        for start in stride(from: 0, to: min(paths.count, Self.diffBatch * Self.diffBatches), by: Self.diffBatch) {
            let batch = Array(paths[start..<min(start + Self.diffBatch, paths.count)])
            let answer = try? await http.json(pull(number) + "/diff-files", method: "POST", body: ["paths": batch, "expectedVersion": version])
            details += ((answer as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        }
        return Self.files(listed: listed, details: details)
    }

    // MARK: Actions

    @discardableResult
    func perform(_ action: PullRequestAction, number: Int, detail: PullRequestDetail) async throws -> String? {
        switch action {
        case .review(let verdict, let body):
            try await review(verdict, body: body, number: number)
        case .reviewWithComments(let verdict, let body, _, let comments):
            guard comments.isEmpty else { throw PullRequestForgeError.unsupported(Self.name) }
            try await review(verdict, body: body, number: number)
        case .comment(let body):
            // GitCafe takes a new comment at this address with its trailing slash, unlike reading the list.
            try await post(pull(number) + "/comments/", ["body": body])
        case .reply(let id, let body):
            let comment = try await self.comment(numbered: id, number: number)
            let thread = RemoteRepository.encode((comment["threadId"] as? String) ?? "")
            try await post(pull(number) + "/comments/\(thread)/replies", ["body": body])
        case .editComment(let id, _, let body):
            let comment = try await self.comment(numbered: id, number: number)
            let path = pull(number) + "/comments/" + RemoteRepository.encode((comment["id"] as? String) ?? "")
            let current = try await http.json(path + "/detail") as? [String: Any]
            _ = try await http.json(path, method: "PATCH", body: ["body": body, "expectedVersion": try Self.version(current ?? [:])])
        case .setThreadResolved(let threadID, let resolved):
            try await setResolved(threadID, resolved, number: number)
        case .close:
            try await act("close", number: number)
        case .reopen:
            try await act("reopen", number: number)
        case .markReady:
            try await act("ready", number: number)
        case .markDraft:
            try await act("draft", number: number)
        case .edit(let title, let body):
            let current = try await fresh(number)
            _ = try await http.json(pull(number), method: "PATCH",
                                    body: ["expectedVersion": try Self.version(current), "title": title, "description": body])
        case .requestReviewers(let people):
            let candidates = try await pages(pull(number) + "/reviewer-candidates")
            try await change("reviewers", key: "actorIds", ids: try Self.actorIDs(people, candidates: candidates), adding: true, number: number)
        case .addLabels(let names):
            let known = try await pages(repository + "/labels")
            try await change("labels", key: "labelIds", ids: try Self.labelIDs(names, labels: known), adding: true, number: number)
        case .removeLabel(let name):
            let known = try await pages(repository + "/labels")
            try await change("labels", key: "labelIds", ids: try Self.labelIDs([name], labels: known), adding: false, number: number)
        case .updateBranch, .changeBase, .approveWorkflow, .rebaseBranch, .deleteBranch, .revert, .setMaintainerEdits, .enableAutoMerge,
             .disableAutoMerge:
            throw PullRequestForgeError.unsupported(Self.name)
        }
        return nil
    }

    /// A merge is fenced on the pull request's version and both tips, so the head it merges is the one on the page.
    func merge(number: Int, method: PullRequestMergeMethod, sha: String) async throws -> String {
        let current = try await fresh(number)
        if (current["state"] as? String) == "merged" { return "" }
        if (current["mergeRoute"] as? String) == "unsupported" {
            throw PullRequestForgeError.refused("This \(Self.name) pull request has no supported merge route.")
        }
        guard let head = current["headOid"] as? String, !head.isEmpty else {
            throw PullRequestForgeError.refused("\(Self.name) has not reported the pull request's head yet. Refresh and try again.")
        }
        if !sha.isEmpty, sha != head {
            throw PullRequestForgeError.refused("The branch changed since you opened it. Look at the new commits and try again.")
        }
        guard let base = try await baseCommit(current) else {
            throw PullRequestForgeError.refused("\(Self.name) has not reported the pull request's base yet. Refresh and try again.")
        }
        let answer = try await http.json(pull(number) + "/merge", method: "POST", body: [
            "requestId": UUID().uuidString.lowercased(), "expectedVersion": try Self.version(current), "headOid": head, "baseOid": base,
            "strategy": method.rawValue,
        ])
        let outcome = answer as? [String: Any]
        if (outcome?["state"] as? String) == "failed" {
            throw PullRequestForgeError.refused((outcome?["reason"] as? String) ?? "\(Self.name) could not merge the pull request.")
        }
        // The merge runs on after the answer, so there is no commit to name yet.
        return ""
    }

    private func post(_ path: String, _ body: [String: Any]) async throws {
        _ = try await http.json(path, method: "POST", body: body)
    }

    private func fresh(_ number: Int) async throws -> [String: Any] {
        guard let item = try await http.json(pull(number)) as? [String: Any] else {
            throw PullRequestForgeError.refused("\(Self.name) did not send this pull request.")
        }
        return item
    }

    /// A native merge fences on the target's commit, one routed to GitHub on the base GitCafe observed there.
    private func baseCommit(_ current: [String: Any]) async throws -> String? {
        if (current["mergeRoute"] as? String) == "provider" { return current["observedBaseOid"] as? String }
        let ref = RemoteRepository.encode("refs/heads/" + ((current["targetBranch"] as? String) ?? ""))
        let commit = try await http.json(repository + "/commit?ref=" + ref) as? [String: Any]
        return commit?["oid"] as? String
    }

    private func act(_ action: String, number: Int) async throws {
        let current = try await fresh(number)
        try await post(pull(number) + "/" + action, ["expectedVersion": try Self.version(current)])
    }

    private func review(_ verdict: PullRequestAction.Verdict, body: String, number: Int) async throws {
        let current = try await fresh(number)
        guard let head = current["headOid"] as? String, !head.isEmpty else {
            throw PullRequestForgeError.refused("\(Self.name) has not reported the pull request's head yet. Refresh and try again.")
        }
        try await post(pull(number) + "/reviews", Self.reviewBody(verdict, body: body, head: head, version: try Self.version(current)))
    }

    /// The page holds a comment by its number; its real id is read back from the list.
    private func comment(numbered id: Int, number: Int) async throws -> [String: Any] {
        let comments = try await pages(pull(number) + "/comments")
        guard let found = comments.first(where: { Self.number(of: ($0["id"] as? String) ?? "") == id }) else {
            throw PullRequestForgeError.refused("\(Self.name) no longer has this comment.")
        }
        return found
    }

    /// Resolving is fenced on the version of the thread's first comment.
    private func setResolved(_ threadID: String, _ resolved: Bool, number: Int) async throws {
        let comments = try await pages(pull(number) + "/comments")
        guard let root = comments.first(where: { ($0["id"] as? String) == threadID }) else {
            throw PullRequestForgeError.refused("\(Self.name) did not return the thread.")
        }
        if resolved == (root["resolvedAt"] is String) { return }
        let path = pull(number) + "/comments/\(RemoteRepository.encode(threadID))/" + (resolved ? "resolve" : "unresolve")
        try await post(path, ["expectedVersion": try Self.version(root)])
    }

    /// GitCafe replaces a whole list, so one change reads it and writes it back. The version is read first: a change
    /// landing between the reads then fails the fence instead of being overwritten.
    private func change(_ list: String, key: String, ids: [String], adding: Bool, number: Int) async throws {
        let current = try await fresh(number)
        let listed = try await pages(pull(number) + "/" + list).compactMap { $0["id"] as? String }
        let next = Self.changed(listed, ids: ids, adding: adding)
        guard next != listed else { return }
        _ = try await http.json(pull(number) + "/" + list, method: "PUT", body: ["expectedVersion": try Self.version(current), key: next])
    }

    // MARK: Requests

    static func reviewBody(_ verdict: PullRequestAction.Verdict, body: String, head: String, version: Int) -> [String: Any] {
        var payload: [String: Any] = ["commitOid": head, "expectedVersion": version, "requestId": UUID().uuidString.lowercased()]
        switch verdict {
        case .comment: payload["verdict"] = "comment"
        case .approve: payload["verdict"] = "approve"
        case .requestChanges: payload["verdict"] = "request_changes"
        }
        if !body.isEmpty { payload["body"] = body }
        return payload
    }

    static func changed(_ listed: [String], ids: [String], adding: Bool) -> [String] {
        adding ? listed + ids.filter { !listed.contains($0) } : listed.filter { !ids.contains($0) }
    }

    /// The actor ids of `people` among the candidates. A name nobody has is refused instead of dropped, so a typo does
    /// not look like a request that went out.
    static func actorIDs(_ people: [String], candidates: [[String: Any]]) throws -> [String] {
        try people.map { person in
            let wanted = person.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased()
            let found = candidates.first { logins($0["actor"]).contains { $0.lowercased() == wanted } }
            guard let id = found?["id"] as? String else {
                throw PullRequestForgeError.refused("\(name) cannot ask \(person) for a review here.")
            }
            return id
        }
    }

    static func labelIDs(_ names: [String], labels: [[String: Any]]) throws -> [String] {
        try names.map { label in
            let found = labels.first { ($0["name"] as? String)?.lowercased() == label.lowercased() }
            guard let id = found?["id"] as? String else { throw PullRequestForgeError.refused("\(name) has no label \(label) here.") }
            return id
        }
    }

    static func version(_ item: [String: Any]) throws -> Int {
        guard let version = int(item["version"]) else { throw PullRequestForgeError.refused("\(name) did not say which version this is.") }
        return version
    }

    /// A stable number for an opaque id. `PullRequestEvent` and the reply and edit actions carry numbers; the action
    /// finds the real id again by this number in the comments it reads. 53 bits leave a collision within one pull
    /// request out of the question, and keep it positive.
    static func number(of id: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int(hash >> 11)
    }

    // MARK: Parsing

    static func detail(pull: [String: Any], repo: RemoteRepository, status: [String: Any]? = nil, reviewers: [[String: Any]] = [],
                       labels: [[String: Any]] = [], checks list: [[String: Any]] = [], changes: [[String: Any]] = []) -> PullRequestDetail? {
        guard let number = int(pull["number"]) else { return nil }
        let merge = status?["merge"] as? [String: Any]
        let conflicts = merge?["conflicts"] as? String
        let mergeable: Bool? = conflicts == "conflicting" ? false : conflicts == "none" ? true : nil
        let mergeState = conflicts == "conflicting" ? "dirty" : (merge?["permitted"] as? Bool) == false ? "blocked"
            : conflicts == "none" ? "clean" : "unknown"
        var detail = PullRequestDetail(
            repo: repo.path, number: number, title: (pull["title"] as? String) ?? "Untitled",
            body: (pull["description"] as? String) ?? "", url: repo.pullRequestURL(number: number), author: login(pull["author"]),
            state: state(pull), baseBranch: (pull["targetBranch"] as? String) ?? "", headBranch: (pull["sourceBranch"] as? String) ?? "",
            headSHA: (pull["headOid"] as? String) ?? "",
            additions: changes.reduce(0) { $0 + (int($1["additions"]) ?? 0) }, deletions: changes.reduce(0) { $0 + (int($1["deletions"]) ?? 0) },
            changedFiles: changes.count, created: PullRequestDetailParser.date(pull["createdAt"]),
            updated: PullRequestDetailParser.date(pull["updatedAt"]), mergeable: mergeable, mergeState: mergeState)
        detail.checks = checks(list)
        if let merge { detail.methods = methods(merge) }
        let capabilities = pull["capabilities"] as? [String: Any]
        detail.canPush = capabilities?["merge"] as? Bool
        detail.requestedReviewers = reviewers.compactMap { logins($0["actor"]).first }
        detail.labels = labels.compactMap { $0["name"] as? String }
        for label in labels {
            if let name = label["name"] as? String, let color = label["color"] as? String { detail.labelColors[name] = hex(color) }
            if let name = label["name"] as? String, let text = label["description"] as? String, !text.isEmpty { detail.labelDescriptions[name] = text }
        }
        detail.locked = pull["lockedAt"] is String
        let source = pull["sourceRepo"] as? [String: Any]
        if let owner = source?["owner"] as? String, let name = source?["name"] as? String {
            detail.headRepository = owner + "/" + name
            if (owner + "/" + name).lowercased() != repo.path.lowercased() { detail.headOwner = owner }
        } else {
            detail.headRepository = repo.path
        }
        // The page offers draft actions by this id. GitCafe's address needs only the number.
        detail.nodeID = String(number)
        detail.features = forgeFeatures
        detail.activityLoaded = false
        return detail
    }

    /// GitHub's merge counts as soon as GitCafe records it, ahead of the sync that reports it.
    static func state(_ pull: [String: Any]) -> PullRequestDetail.State {
        switch pull["state"] as? String {
        case "merged": return .merged
        case "closed": return .closed
        default:
            if pull["providerMerge"] is [String: Any] { return .merged }
            return (pull["draft"] as? Bool) == true ? .draft : .open
        }
    }

    /// The strategies GitCafe would take right now; a blocker can rule out one and leave the others.
    static func methods(_ merge: [String: Any]) -> [PullRequestMergeMethod] {
        guard (merge["permitted"] as? Bool) != false else { return [] }
        let strategies = (merge["strategies"] as? [String]) ?? []
        let blocked = ((merge["blockers"] as? [[String: Any]]) ?? []).flatMap { ($0["blockedStrategies"] as? [String]) ?? [] }
        return PullRequestMergeMethod.allCases.filter { strategies.contains($0.rawValue) && !blocked.contains($0.rawValue) }
    }

    /// GitCafe has no filter on a source branch, so the newest pull requests are read and matched here.
    static func links(_ list: [[String: Any]], branch: String, repo: RemoteRepository) -> [PullRequestLink] {
        list.compactMap { item in
            guard (item["sourceBranch"] as? String) == branch, let number = int(item["number"]) else { return nil }
            return PullRequestLink(host: repo.host, repository: repo.path, number: number,
                                   url: repo.pullRequestURL(number: number)?.absoluteString ?? "", title: item["title"] as? String,
                                   state: PullRequestState(rawValue: state(item).rawValue) ?? .open,
                                   updatedAt: PullRequestDetailParser.date(item["updatedAt"]),
                                   baseBranch: item["targetBranch"] as? String, headBranch: branch)
        }
    }

    /// GitCafe lists every run, so a re-run stands beside the run it replaced. A run's id grows, and the newest run of
    /// one reporter's check is its state. Runs without a numeric id are all kept, so no failure is hidden.
    static func checks(_ list: [[String: Any]]) -> [PullRequestCheck] {
        var kept: [[String: Any]] = []
        var newest: [String: (index: Int, order: UInt64)] = [:]
        for check in list {
            guard let order = (check["id"] as? String).flatMap(UInt64.init) else {
                kept.append(check)
                continue
            }
            let key = [check["provider"], check["githubApp"], check["name"]].map { ($0 as? String) ?? "" }.joined(separator: "\n")
            if let held = newest[key] {
                if order > held.order {
                    kept[held.index] = check
                    newest[key] = (held.index, order)
                }
            } else {
                newest[key] = (kept.count, order)
                kept.append(check)
            }
        }
        // GitCafe's checks have GitHub's shape under other names, so the parser's words for an outcome apply.
        let runs = kept.map { check -> [String: Any] in
            var run: [String: Any] = ["name": (check["name"] as? String) ?? "?", "status": (check["status"] as? String) ?? ""]
            run["conclusion"] = check["conclusion"] as? String
            run["details_url"] = check["detailsUrl"] as? String
            return run
        }
        return PullRequestDetailParser.checks(runs: runs, statuses: [])
    }

    /// `summary` is a commit's first line, and GitCafe does not say who wrote it.
    static func commits(_ list: [[String: Any]]) -> [PullRequestCommit] {
        list.compactMap { item in
            guard let sha = item["oid"] as? String else { return nil }
            let time = (item["time"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return PullRequestCommit(sha: sha, message: (item["summary"] as? String) ?? "", author: "?", date: time)
        }
    }

    /// The whole timeline, oldest first.
    static func events(comments list: [[String: Any]], reviews: [[String: Any]], commits: [PullRequestCommit], head: String?) -> [PullRequestEvent] {
        let history = commits.map {
            PullRequestEvent(id: "commit-" + $0.sha, kind: .commit(sha: $0.sha), author: $0.author, body: $0.subject, date: $0.date, url: nil)
        }
        let all = history + self.reviews(reviews) + comments(list, head: head)
        return all.enumerated().sorted {
            ($0.element.date ?? .distantPast, $0.offset) < ($1.element.date ?? .distantPast, $1.offset)
        }.map(\.element)
    }

    static func reviews(_ list: [[String: Any]]) -> [PullRequestEvent] {
        list.compactMap { review in
            guard let id = review["id"] as? String else { return nil }
            let state: String
            if review["dismissedAt"] is String { state = "DISMISSED" } else {
                switch review["verdict"] as? String {
                case "approve": state = "APPROVED"
                case "request_changes": state = "CHANGES_REQUESTED"
                default: state = "COMMENTED"
                }
            }
            let body = (review["body"] as? String) ?? ""
            guard state != "COMMENTED" || !body.isEmpty else { return nil }
            return PullRequestEvent(id: "review-" + id, kind: .review(state), author: login(review["author"]), body: body,
                                    date: PullRequestDetailParser.date(review["createdAt"]), url: nil)
        }
    }

    /// Comments as timeline events. One with a path sits on a line, its thread opened by the comment whose id is the
    /// thread's. A thread lost its first comment when that one is not in the list, and then the oldest stands in for it.
    /// `threadID` keeps GitCafe's own id, which is what resolving asks for. A thread is outdated when its latest comment
    /// was made on another commit than the head.
    static func comments(_ list: [[String: Any]], head: String?) -> [PullRequestEvent] {
        let ordered = list.enumerated().sorted {
            (PullRequestDetailParser.date($0.element["createdAt"]) ?? .distantPast, $0.offset)
                < (PullRequestDetailParser.date($1.element["createdAt"]) ?? .distantPast, $1.offset)
        }.map(\.element)
        var threads: [String: [[String: Any]]] = [:]
        for comment in ordered where isOnFile(comment) {
            threads[(comment["threadId"] as? String) ?? "", default: []].append(comment)
        }
        return ordered.compactMap { comment -> PullRequestEvent? in
            guard let id = comment["id"] as? String else { return nil }
            let number = self.number(of: id)
            let body = (comment["body"] as? String) ?? ""
            let date = PullRequestDetailParser.date(comment["createdAt"])
            guard isOnFile(comment), let path = comment["path"] as? String else {
                var event = PullRequestEvent(id: "comment-\(number)", kind: .comment, author: login(comment["author"]), body: body, date: date, url: nil)
                event.rawBody = body
                return event
            }
            let threadID = (comment["threadId"] as? String) ?? ""
            let thread = threads[threadID] ?? [comment]
            let root = thread.first { ($0["id"] as? String) == threadID } ?? thread[0]
            let rootID = (root["id"] as? String) ?? id
            var event = PullRequestEvent(id: "line-\(number)", kind: .lineComment(path: path, line: int(comment["line"]).flatMap { $0 > 0 ? $0 : nil }),
                                         author: login(comment["author"]), body: body, date: date, url: nil)
            event.replyTo = rootID == id ? nil : "line-\(self.number(of: rootID))"
            event.threadID = threadID
            event.resolved = rootID == id && root["resolvedAt"] is String
            if let head, let latest = thread.last?["commitOid"] as? String { event.outdated = latest != head }
            event.rawBody = body
            return event
        }
    }

    private static func isOnFile(_ comment: [String: Any]) -> Bool { !((comment["path"] as? String) ?? "").isEmpty }

    /// Binary and oversized files have no hunks to ask for.
    static func readablePaths(_ files: [[String: Any]]) -> [String] {
        files.filter { ($0["binary"] as? Bool) != true && ($0["tooLarge"] as? Bool) != true }.compactMap { $0["path"] as? String }
    }

    /// The changed files; `details` are the same files with their hunks, for as far as those were read.
    static func files(listed: [[String: Any]], details: [[String: Any]]) -> [PullRequestFile] {
        var byPath: [String: [String: Any]] = [:]
        for file in details { if let path = file["path"] as? String { byPath[path] = file } }
        return listed.compactMap { entry in
            guard let path = entry["path"] as? String else { return nil }
            let file = byPath[path] ?? entry
            let hunks = (file["hunks"] as? [[String: Any]]) ?? []
            let origins = hunks.flatMap { ($0["lines"] as? [[String: Any]]) ?? [] }.map { ($0["origin"] as? String) ?? "" }
            let status = fileStatus(file["status"] as? String)
            return PullRequestFile(path: path, status: status,
                                   additions: int(file["additions"]) ?? origins.filter { $0 == "+" }.count,
                                   deletions: int(file["deletions"]) ?? origins.filter { $0 == "-" }.count,
                                   patch: patch(hunks), previousPath: (file["oldPath"] as? String).flatMap { $0 == path ? nil : $0 },
                                   revision: status == "removed" ? "" : file["newOid"] as? String)
        }
    }

    static func fileStatus(_ status: String?) -> String {
        switch status {
        case "added", "renamed", "copied": return status ?? "modified"
        case "deleted": return "removed"
        case "typeChanged": return "changed"
        default: return "modified"
        }
    }

    /// GitCafe's structured hunks as a unified patch. Its `=`, `>` and `<` lines are git's end-of-file markers.
    static func patch(_ hunks: [[String: Any]]) -> String? {
        guard !hunks.isEmpty else { return nil }
        var lines: [String] = []
        for hunk in hunks {
            lines.append("@@ -\(int(hunk["oldStart"]) ?? 0),\(int(hunk["oldLines"]) ?? 0) +\(int(hunk["newStart"]) ?? 0),\(int(hunk["newLines"]) ?? 0) @@")
            for line in (hunk["lines"] as? [[String: Any]]) ?? [] {
                let origin = (line["origin"] as? String) ?? " "
                if ["=", ">", "<"].contains(origin) {
                    lines.append("\\ No newline at end of file")
                } else {
                    var content = (line["content"] as? String) ?? ""
                    if content.hasSuffix("\n") { content.removeLast() }
                    lines.append(origin + content)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func labels(_ list: [[String: Any]]) -> [PullRequestLabelChoice] {
        list.compactMap { label in
            guard let name = label["name"] as? String else { return nil }
            return (name, hex((label["color"] as? String) ?? ""), (label["description"] as? String) ?? "")
        }
    }

    private static func hex(_ color: String) -> String { color.hasPrefix("#") ? String(color.dropFirst()) : color }

    /// An actor is local, mirrored from GitHub, or no longer available.
    static func login(_ actor: Any?) -> String { logins(actor).first ?? "?" }

    /// Every name an actor goes by: a GitHub account can also be linked to a GitCafe profile.
    static func logins(_ actor: Any?) -> [String] {
        guard let actor = actor as? [String: Any] else { return [] }
        switch actor["kind"] as? String {
        case "local": return [actor["handle"] as? String].compactMap { $0 }
        case "github":
            return [actor["login"] as? String, (actor["linkedProfile"] as? [String: Any])?["handle"] as? String].compactMap { $0 }
        default: return []
        }
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }
}
