import Foundation

/// A personal access token per GitLab host (gitlab.com or a self-hosted one), kept in the Keychain. Only sent to that
/// host over https, with the `PRIVATE-TOKEN` header, and never written to a log or a URL.
enum GitLabCredentials {
    private static let hostsKey = "gitlab.hosts"

    private static func account(_ host: String) -> String { "gitlab.token." + host.lowercased() }

    static func token(host: String) -> String? { CloudHelp.secret(account(host)) }

    /// The hosts that have a token, for the settings list.
    static var hosts: [String] {
        (UserDefaults.standard.stringArray(forKey: hostsKey) ?? []).filter { token(host: $0) != nil }
    }

    /// A host as typed ("gitlab.com", "https://git.example.com/"): lower case, no scheme, path or credentials.
    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        text = String(text.split(separator: "/").first ?? "")
        guard !text.contains("@"), !text.isEmpty, text.allSatisfy({ $0.isLetter || $0.isNumber || "-.:".contains($0) }),
              text.contains(".") || text.hasPrefix("localhost") else { return nil }
        return text
    }

    @discardableResult
    static func save(host: String, token: String) -> Bool {
        guard let host = normalize(host) else { return false }
        let clean = ConnectorField.clean(token)
        guard !clean.isEmpty, Keychain.write(clean, account: account(host)) == errSecSuccess else { return false }
        var list = UserDefaults.standard.stringArray(forKey: hostsKey) ?? []
        if !list.contains(host) { list.append(host) }
        UserDefaults.standard.set(list, forKey: hostsKey)
        return true
    }

    static func remove(host: String) {
        Keychain.write("", account: account(host))
        UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: hostsKey) ?? []).filter { $0 != host.lowercased() },
                                  forKey: hostsKey)
    }
}

/// Merge requests on GitLab with the user's own token (the same two actions as GitHubPullRequests: look up, open).
enum GitLabMergeRequests {
    static func isAvailable(_ repo: RemoteRepository) -> Bool {
        repo.host == .gitlab && GitLabAPI.apiBase(repo) != nil && GitLabCredentials.token(host: repo.hostName) != nil
    }

    private static func request(_ url: URL, token: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Merge requests whose source is `branch`, any state. nil when GitLab cannot be asked (no token, offline, refused).
    static func list(repo: RemoteRepository, branch: String) async -> [PullRequestLink]? {
        guard let token = GitLabCredentials.token(host: repo.hostName), GitLabAPI.apiBase(repo) != nil,
              let url = GitLabAPI.listURL(repo: repo, sourceBranch: branch),
              let req = try? request(url, token: token),
              let (data, response) = try? await ConnectorHTTP.session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return GitLabAPI.parseList(data, repository: repo, sourceBranch: branch)
    }

    /// A merge request as it is now, for a session that watches it: state, pipeline, approvals and comments. nil when
    /// GitLab cannot be asked (no token, offline, refused).
    static func snapshot(url: URL) async -> PullRequestSnapshot? {
        guard let (repo, iid) = GitLabAPI.mergeRequest(url).map({ ($0.repo, $0.iid) }),
              let token = GitLabCredentials.token(host: repo.hostName) else { return nil }
        func get(_ url: URL?) async -> Any? {
            guard let url, let req = try? request(url, token: token),
                  let (data, response) = try? await ConnectorHTTP.session.data(for: req),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        guard let mergeRequest = await get(GitLabAPI.mergeRequestURL(repo, iid: iid)) as? [String: Any] else { return nil }
        let notes = await get(GitLabAPI.mergeRequestURL(repo, iid: iid, suffix: "/notes", query: "per_page=100&sort=asc")) as? [[String: Any]] ?? []
        let approvals = await get(GitLabAPI.mergeRequestURL(repo, iid: iid, suffix: "/approvals")) as? [String: Any]
        var failed: [[String: Any]] = []
        if let pipeline = mergeRequest["head_pipeline"] as? [String: Any], (pipeline["status"] as? String) == "failed",
           let pipelineID = pipeline["id"] as? Int {
            failed = await get(GitLabAPI.failedJobsURL(repo, pipeline: pipelineID)) as? [[String: Any]] ?? []
        }
        return GitLabAPI.snapshot(mergeRequest: mergeRequest, notes: notes, approvals: approvals, failedJobs: failed)
    }

    static func create(repo: RemoteRepository, title: String, body: String, head: String, base: String, draft: Bool) async throws -> URL {
        guard let token = GitLabCredentials.token(host: repo.hostName), let url = GitLabAPI.createURL(repo: repo) else {
            throw CloudHelp.notSetUp("GitLab")
        }
        let req = try request(url, token: token, method: "POST",
                              body: GitLabAPI.createBody(title: title, description: body, source: head, target: base, draft: draft))
        let (data, response) = try await ConnectorHTTP.session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let link = GitLabAPI.parseCreated(data) else {
            throw NookError("GitLab: " + (GitLabAPI.errorMessage(data) ?? "GitLab returned an error (\(status))."))
        }
        return link
    }
}

/// The forge behind a folder's remote: the one place that decides between GitHub's API, GitLab's API and the browser page
/// every other forge gets.
enum SourceForge {
    static func repository(remoteURL: String?) -> RemoteRepository? { remoteURL.flatMap { RemoteRepository.detect(remoteURL: $0) } }

    /// Whether Nook can open the request itself (a connected account) rather than hand you the forge's page.
    static func canCreate(_ repo: RemoteRepository) -> Bool {
        switch repo.host {
        case .github: return repo.hostName == "github.com" && GitHubPullRequests.isAvailable
        case .gitlab: return GitLabMergeRequests.isAvailable(repo)
        default: return false
        }
    }

    static func create(repo: RemoteRepository, title: String, body: String, head: String, base: String, draft: Bool) async throws -> URL {
        switch repo.host {
        case .github: return try await GitHubPullRequests.create(repo: repo.displayName, title: title, body: body, head: head, base: base, draft: draft)
        case .gitlab: return try await GitLabMergeRequests.create(repo: repo, title: title, body: body, head: head, base: base, draft: draft)
        default: throw NookError("Nook cannot open a request on \(repo.hostName) itself.")
        }
    }

    static func requests(repo: RemoteRepository, branch: String) async -> [PullRequestLink]? {
        switch repo.host {
        case .github: return repo.hostName == "github.com" ? await GitHubPullRequests.pullRequests(repo: repo.displayName, branch: branch) : nil
        case .gitlab: return await GitLabMergeRequests.list(repo: repo, branch: branch)
        default: return nil
        }
    }

    /// The forge's own "new request" page, title and description filled in.
    static func newRequestPage(repo: RemoteRepository, base: String, head: String, title: String, body: String, draft: Bool = false) -> URL? {
        repo.newPullRequestURL(base: base, head: head, title: title, body: String(body.prefix(6_000)), draft: draft)
    }

    static func word(_ repo: RemoteRepository) -> String { repo.host.usesMergeRequests ? "merge request" : "pull request" }
}
