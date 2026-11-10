import Foundation

/// Makes a GitHub repository for a local project (Publish), with the GitHub account Nook already uses for pull requests
/// (or the GitHub CLI's login). Only after your own click and confirmation; see `WorkspaceManager.publishRepository`.
enum GitHubRepositoryCreate {
    struct Made: Equatable, Sendable {
        /// "owner/name".
        var fullName: String
        var page: URL
        /// The HTTPS address to push to.
        var cloneURL: String
        /// The token that made it, to push the first time with.
        var token: String
    }

    /// The token to use: the first connected GitHub account, else the GitHub CLI's login.
    static func token() async -> String? {
        await GitHubCLILogin.read()
        var available = GitHubPullRequests.tokens
        if let cli = GitHubCLILogin.cached, !available.contains(cli) { available.append(cli) }
        return available.first
    }

    /// Creates `name` (under `owner`, an organization, or your own account), private unless asked otherwise. A repository
    /// of that name you made a moment ago that is still empty (an earlier publish whose push failed) is used again.
    static func create(name: String, owner: String?, isPrivate: Bool) async throws -> Made {
        guard RepositoryPublish.isValidName(name) else { throw NookError(tr("sc.publish.badName")) }
        guard let token = await token() else { throw CloudHelp.notSetUp("GitHub") }
        let (status, object) = try await send("POST", RepositoryPublish.requestPath(owner: owner),
                                              body: RepositoryPublish.requestBody(name: name, isPrivate: isPrivate), token: token)
        if (200...299).contains(status), let made = made(object, token: token) { return made }
        if status == 422 {
            let login: String
            if let owner, !owner.isEmpty {
                login = owner
            } else {
                let (_, user) = try await send("GET", "/user", body: nil, token: token)
                login = (user["login"] as? String) ?? ""
            }
            let (found, existing) = try await send("GET", "/repos/\(login)/\(name)", body: nil, token: token)
            // Only an empty one: a repository with anything in it is never pushed into.
            if found == 200, (existing["size"] as? Int) == 0, let made = made(existing, token: token) {
                return made
            }
            throw NookError(tr("sc.publish.exists", login.isEmpty ? name : login + "/" + name))
        }
        let message = (object["message"] as? String) ?? "GitHub returned an error (\(status))."
        throw NookError("GitHub: " + message)
    }

    private static func made(_ object: [String: Any], token: String) -> Made? {
        guard let fullName = object["full_name"] as? String, let page = (object["html_url"] as? String).flatMap(URL.init(string:)),
              let clone = object["clone_url"] as? String else { return nil }
        return Made(fullName: fullName, page: page, cloneURL: clone, token: token)
    }

    private static func send(_ method: String, _ path: String, body: [String: Any]?, token: String) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: try CloudHelp.url("https://api.github.com" + path))
        request.httpMethod = method
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await ConnectorHTTP.session.data(for: request)
        let http = response as? HTTPURLResponse
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let limited = GitHubRateLimit.message(http, object["message"] as? String) { throw NookError(limited, kind: .rateLimited) }
        return (http?.statusCode ?? 0, object)
    }
}
