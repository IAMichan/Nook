import Foundation

/// What a forge's pull request page can do. The page shows only what its forge offers, so one page serves them all.
struct PullRequestForgeFeatures: Equatable, Sendable {
    /// Checks of the head commit.
    var checks = true
    var labels = true
    var reviewers = true
    /// Comments on lines of the diff, sent with a review.
    var lineComments = true
    /// Replies on a thread, and resolving it.
    var threads = true
    var reactions = true
    var editComments = true
    var autoMerge = true
    var draft = true
    /// Bringing the branch up to date with its base.
    var updateBranch = true
    var revert = true
    var deleteBranch = true
    /// One commit's own diff on the Code tab.
    var commitView = true
    /// Approve and request changes; without it a review is only a comment.
    var verdicts = true

    static let github = PullRequestForgeFeatures()
}

/// One forge's API for pull requests in Nook's own types. GitHub has its own path (`GitHubPullRequestDetail`); every other
/// forge implements this for one repository, in a file of its own, so the page, the session lists and the watches stay
/// the same code. A client only exists with a token for its host.
protocol PullRequestForgeClient: Sendable {
    var features: PullRequestForgeFeatures { get }
    /// The pull requests whose source is `branch`, any state; nil when the forge could not be asked.
    func requests(branch: String) async -> [PullRequestLink]?
    /// The pull request with its checks. `activityLoaded` is false; `activity` fills in the rest.
    func summary(number: Int) async throws -> PullRequestDetail
    /// The conversation, commits and files. A part that fails stays empty instead of hiding the rest.
    func activity(number: Int) async -> PullRequestActivity
    /// Sends one action; returns the link of what it made (a revert), if anything. Throws the forge's refusal in words,
    /// and `PullRequestForgeError.unsupported` for an action `features` rules out.
    @discardableResult
    func perform(_ action: PullRequestAction, number: Int, detail: PullRequestDetail) async throws -> String?
    /// Merges exactly `sha` when the forge can hold it to that. Returns the merge commit's sha, or "".
    func merge(number: Int, method: PullRequestMergeMethod, sha: String) async throws -> String
    func commitFiles(sha: String) async throws -> [PullRequestFile]
    func labels() async -> [(name: String, color: String)]
    /// Your name on the forge, as comments show their author: it decides which comments you can edit. "" when unknown.
    func viewer() async -> String
}

extension PullRequestForgeClient {
    func viewer() async -> String { "" }
}

enum PullRequestForgeError: LocalizedError, Equatable {
    case unsupported(String)
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let forge): return "\(forge) does not offer this."
        case .refused(let message): return message
        }
    }
}

/// Where the adapters get what lives in the app, so they and their tests need nothing of it: tokens by host, and the
/// session for slow forge calls. The app fills these in at launch.
enum ForgeEnvironment {
    nonisolated(unsafe) static var token: @Sendable (_ host: String) -> String? = { _ in nil }
    nonisolated(unsafe) static var gitLabToken: @Sendable (_ host: String) -> String? = { _ in nil }
    nonisolated(unsafe) static var session = URLSession.shared
}

/// One forge's HTTP: json and text with an auth header, https only, a refusal thrown in the forge's words.
struct ForgeHTTP: Sendable {
    let name: String
    /// Everything before the path: "https://gitlab.com/api/v4".
    let base: String
    let headers: [String: String]

    func url(_ path: String) throws -> URL {
        guard let url = URL(string: base + path), url.scheme == "https" else { throw PullRequestForgeError.refused("Invalid \(name) address.") }
        return url
    }

    func data(_ path: String, method: String = "GET", body: Any? = nil, accept: String? = nil) async throws -> Data {
        var request = URLRequest(url: try url(path))
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await ForgeEnvironment.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw PullRequestForgeError.refused(Self.refusal(name, status: status, data: data)) }
        return data
    }

    func json(_ path: String, method: String = "GET", body: Any? = nil) async throws -> Any {
        let data = try await data(path, method: method, body: body)
        return data.isEmpty ? [:] as [String: Any] : try JSONSerialization.jsonObject(with: data)
    }

    func text(_ path: String) async throws -> String {
        String(decoding: try await data(path, accept: "text/plain"), as: UTF8.self)
    }

    static func refusal(_ name: String, status: Int, data: Data) -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let nested = (object?["error"] as? [String: Any])?["message"] as? String
        // GitLab answers a refused field as {"message": {"field": ["reason"]}}.
        let fields = (object?["message"] as? [String: Any])?.flatMap { key, value in ((value as? [String]) ?? []).map { key + " " + $0 } }.sorted().joined(separator: "; ")
        let message = nested ?? (object?["message"] as? String) ?? fields ?? (object?["error"] as? String) ?? ""
        return "\(name) refused this (\(status))." + (message.isEmpty ? "" : " " + message)
    }
}

/// A whole unified diff cut into `PullRequestFile`s, for forges that give the diff of a change in one piece.
enum UnifiedDiffFiles {
    static func split(_ diff: String) -> [PullRequestFile] {
        var files: [PullRequestFile] = []
        var header: (path: String, previous: String?, status: String)?
        var body: [String] = []
        var inHunk = false
        func flush() {
            guard let current = header else { return }
            let additions = body.filter { $0.hasPrefix("+") }.count, deletions = body.filter { $0.hasPrefix("-") }.count
            files.append(PullRequestFile(path: current.path, status: current.status, additions: additions, deletions: deletions,
                                         patch: body.isEmpty ? nil : body.joined(separator: "\n"), previousPath: current.previous))
        }
        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") {
                flush()
                body = []
                inHunk = false
                let names = line.dropFirst("diff --git ".count).components(separatedBy: " b/")
                header = (names.count > 1 ? names[names.count - 1] : "", nil, "modified")
                continue
            }
            guard header != nil else { continue }
            if line.hasPrefix("@@") { inHunk = true }
            if inHunk {
                if !line.isEmpty { body.append(line) }
            } else if line.hasPrefix("rename from ") {
                header?.previous = String(line.dropFirst("rename from ".count))
                header?.status = "renamed"
            } else if line.hasPrefix("new file mode") {
                header?.status = "added"
            } else if line.hasPrefix("deleted file mode") {
                header?.status = "removed"
            }
        }
        flush()
        return files
    }
}

extension RemoteRepository {
    /// The account a pull request page reads with on a forge other than GitHub.
    var forgeAccount: String { "forge\n\(host.key)\n\(hostName)\n\(webOrigin)" }
}

/// Which client serves a page, by the account it was opened with.
enum PullRequestForges {
    /// Filled by the adapters' file: one entry per forge. Nil without a token for the host.
    static func client(_ repo: RemoteRepository) -> PullRequestForgeClient? {
        switch repo.host {
        case .gitlab: return GitLabPullRequestForge(repo)
        case .gitea, .forgejo: return GiteaPullRequestForge(repo)
        case .gitcafe: return GitCafePullRequestForge(repo)
        case .bitbucket: return BitbucketPullRequestForge(repo)
        case .azureDevOps: return AzureDevOpsPullRequestForge(repo)
        case .github, .unknown: return nil
        }
    }

    static func repository(account: String, path: String) -> RemoteRepository? {
        let parts = account.components(separatedBy: "\n")
        guard parts.count == 4, parts[0] == "forge" else { return nil }
        return RemoteRepository(host: SourceControlHost(key: parts[1]), hostName: parts[2], path: path, webOrigin: parts[3])
    }

    static func client(account: String, path: String) -> PullRequestForgeClient? {
        repository(account: account, path: path).flatMap(client)
    }
}

extension PullRequestRef {
    /// The repository of a link on a forge Nook reads with a client of its own; nil for anything else.
    var forgeRepository: RemoteRepository? {
        guard let host, host != .github, !host.isUnknown, let repository, let url, let scheme = url.scheme, let name = url.host else { return nil }
        let origin = "\(scheme)://\(name)" + (url.port.map { ":\($0)" } ?? "")
        return RemoteRepository(host: host, hostName: hostName ?? name, path: repository, webOrigin: origin)
    }
}

extension PullRequestForges {
    /// How a pull request looks now, for a session that watches it: the same shape a watch gets from GitHub.
    static func snapshot(url: URL) async -> PullRequestSnapshot? {
        guard let ref = PullRequestRef.parse(url.absoluteString), let repo = ref.forgeRepository, let client = client(repo),
              var detail = try? await client.summary(number: ref.number) else { return nil }
        detail.apply(await client.activity(number: ref.number))
        let conversation = detail.events.compactMap { event -> (review: Bool, note: PullRequestSnapshot.Note)? in
            switch event.kind {
            case .review(let state): return (true, .init(author: event.author, verdict: state, text: event.body))
            case .comment, .lineComment: return (false, .init(author: event.author, verdict: "", text: event.body))
            default: return nil
            }
        }
        let checks: String = switch detail.checkSummary {
        case .failing: "failure"
        case .pending: "pending"
        case .passing: "success"
        case .unknown: ""
        }
        let state = detail.state == .merged ? "merged" : detail.state == .closed ? "closed" : "open"
        return PullRequestSnapshot(state: state, checks: checks, failedChecks: detail.checks.filter { $0.outcome == .failing }.map(\.name),
                                   reviews: conversation.filter(\.review).map(\.note), comments: conversation.filter { !$0.review }.map(\.note),
                                   draft: detail.state == .draft, conflicted: detail.conflicted, mergeabilityKnown: detail.mergeable != nil)
    }
}
