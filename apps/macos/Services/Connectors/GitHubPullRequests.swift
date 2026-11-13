import SwiftUI
import os

/// The GitHub CLI's login, read with `gh auth token` at most every few minutes and never on the caller's thread: the
/// fallback for someone who uses `gh` but never connected GitHub in Nook.
enum GitHubCLILogin {
    private struct State {
        var token: String?
        var read: Date?
        var reading = false
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())
    private static let lifetime: TimeInterval = 10 * 60

    /// The last token read; a stale or missing answer is read again in the background.
    static var cached: String? {
        let (token, due) = state.withLock { s -> (String?, Bool) in
            let due = !s.reading && (s.read.map { Date().timeIntervalSince($0) > lifetime } ?? true)
            if due { s.reading = true }
            return (s.token, due)
        }
        if due { Task.detached(priority: .utility) { finish(GitHubSignIn.cliToken()) } }
        return token
    }

    /// Reads the token now unless a recent answer is known, for a request that is about to go out.
    static func read() async {
        let fresh = state.withLock { s in s.read.map { Date().timeIntervalSince($0) <= lifetime } ?? false }
        guard !fresh else { return }
        let result = await Task.detached(priority: .userInitiated) { GitHubSignIn.cliToken() }.value
        finish(result)
    }

    private static func finish(_ result: Result<String, GitHubSignIn.CLIError>) {
        state.withLock { s in
            s.token = try? result.get()
            s.read = Date()
            s.reading = false
        }
    }
}

/// Open a pull request using the existing GitHub connection. Only after explicit user action in the workspace.
enum GitHubPullRequests {
    /// Whether the GitHub connector is active and has a token. Otherwise Nook opens the compare page on github.com.
    static var isAvailable: Bool {
        ConnectorToggle.isOn("github") && !tokens.isEmpty
    }

    /// Tokens of all GitHub accounts, primary first. Without any, the GitHub CLI's own login (`gh auth token`), so a
    /// pull request still opens and is followed through the API instead of GitHub's page in a browser.
    static var tokens: [String] {
        let accounts = AccountRegistry.shared.accounts(for: "github").compactMap { CloudHelp.secret($0.key("token")) }
        return accounts.isEmpty ? GitHubCLILogin.cached.map { [$0] } ?? [] : accounts
    }

    /// "owner/repo" and the number of a pull request link ("https://github.com/owner/repo/pull/12").
    static func parse(_ url: URL) -> (repo: String, number: Int)? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard url.host.map { $0 == "github.com" || $0.hasSuffix(".github.com") } == true, parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]) else { return nil }
        return (parts[0] + "/" + parts[1], number)
    }

    /// A pull request's state, checks, reviews and comments, for a session that watches it. Nil when
    /// no connected account can read it.
    static func snapshot(url: URL) async -> PullRequestSnapshot? {
        guard isAvailable, let target = parse(url) else { return nil }
        let repo = target.repo, number = target.number
        for token in tokens {
            let auth = ["Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
            let base = "https://api.github.com/repos/\(repo)"
            func get(_ path: String) async -> Any? {
                guard let url = URL(string: base + path) else { return nil }
                return try? await ConnectorHTTP.json(url, headers: auth, conditional: true)
            }
            guard let pull = await get("/pulls/\(number)") as? [String: Any] else { continue }
            let merged = (pull["merged"] as? Bool) ?? false
            let state = merged ? "merged" : ((pull["state"] as? String) == "open" ? "open" : "closed")
            var checks = ""
            var failed: [String] = []
            var checksKnown = false
            if let sha = (pull["head"] as? [String: Any])?["sha"] as? String,
               let all = (await get("/commits/\(sha)/check-runs?per_page=100") as? [String: Any])?["check_runs"] as? [[String: Any]] {
                checksKnown = true
                // Only the newest run of each check counts: a cancelled or re-run workflow leaves its old failures behind.
                let runs = PullRequestDetailParser.latestRuns(all)
                failed = runs.filter { ["failure", "timed_out", "cancelled", "action_required"].contains(($0["conclusion"] as? String) ?? "") }
                    .compactMap { $0["name"] as? String }
                let pending = runs.contains { ($0["status"] as? String) != "completed" }
                checks = !failed.isEmpty ? "failure" : pending ? "pending" : runs.isEmpty ? "" : "success"
            }
            func author(_ item: [String: Any]) -> String { ((item["user"] as? [String: Any])?["login"] as? String) ?? "?" }
            let reviews = ((await get("/pulls/\(number)/reviews?per_page=100")) as? [[String: Any]] ?? [])
                .filter { ($0["state"] as? String) != "PENDING" }
                .map { PullRequestSnapshot.Note(author: author($0), verdict: ($0["state"] as? String) ?? "", text: ($0["body"] as? String) ?? "") }
            let issueComments = (await get("/issues/\(number)/comments?per_page=100")) as? [[String: Any]] ?? []
            let lineComments = (await get("/pulls/\(number)/comments?per_page=100")) as? [[String: Any]] ?? []
            let comments = (issueComments + lineComments)
                .sorted { (($0["created_at"] as? String) ?? "") < (($1["created_at"] as? String) ?? "") }
                .map { item -> PullRequestSnapshot.Note in
                    var text = (item["body"] as? String) ?? ""
                    if let path = item["path"] as? String { text = path + ": " + text }
                    return PullRequestSnapshot.Note(author: author(item), verdict: "", text: text)
                }
            return PullRequestSnapshot(state: state, checks: checks, failedChecks: failed, reviews: reviews, comments: comments,
                                       draft: (pull["draft"] as? Bool) ?? false,
                                       conflicted: PullRequestMergeability.githubConflicted(pull),
                                       merge: PullRequestMergeFacts(state: ((pull["mergeable_state"] as? String) ?? "unknown").lowercased(),
                                                                    autoMerge: pull["auto_merge"] is [String: Any],
                                                                    baseBranch: ((pull["base"] as? [String: Any])?["ref"] as? String) ?? ""),
                                       mergeabilityKnown: PullRequestMergeability.githubKnown(pull),
                                       checksKnown: checksKnown)
        }
        return nil
    }

    /// Tries the accounts in order: the first one with access to the repository opens the pull request.
    /// When GitHub answers that its REST limit is reached, the same request goes through its GraphQL API, which counts
    /// against a limit of its own (and the other way round for an agent whose `gh` hit the GraphQL one).
    static func create(repo: String, title: String, body: String, head: String, base: String, draft: Bool) async throws -> URL {
        await GitHubCLILogin.read()
        // The GitHub CLI's login as well, after the accounts: another way in when theirs are refused.
        var available = tokens
        if let cli = GitHubCLILogin.cached, !available.contains(cli) { available.append(cli) }
        guard ConnectorToggle.isOn("github"), !available.isEmpty else { throw CloudHelp.notSetUp("GitHub") }
        var lastError: Error = CloudHelp.notSetUp("GitHub")
        var limited = false
        for token in available {
            do {
                return try await create(repo: repo, title: title, body: body, head: head, base: base, draft: draft, token: token)
            } catch {
                lastError = error
                if ConnectorErrorKind.classify(error) == .rateLimited { limited = true }
            }
        }
        guard limited else { throw lastError }
        for token in available {
            do {
                return try await createViaGraphQL(repo: repo, title: title, body: body, head: head, base: base, draft: draft, token: token)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func createViaGraphQL(repo: String, title: String, body: String, head: String, base: String, draft: Bool,
                                         token: String) async throws -> URL {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw NookError("GitHub: \(repo) is not owner/name.") }
        func ask(_ query: String, _ variables: [String: Any]) async throws -> [String: Any] {
            var request = URLRequest(url: try CloudHelp.url("https://api.github.com/graphql"))
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Nook", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await ConnectorHTTP.session.data(for: request)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let errors = (object["errors"] as? [[String: Any]])?.compactMap { $0["message"] as? String } ?? []
            if let limited = GitHubRateLimit.message(response as? HTTPURLResponse, (object["message"] as? String) ?? errors.first) {
                throw NookError(limited, kind: .rateLimited)
            }
            guard errors.isEmpty, let answer = object["data"] as? [String: Any] else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw NookError("GitHub: " + (errors.isEmpty ? (object["message"] as? String) ?? "GitHub returned an error (\(status))." : errors.joined(separator: " ")))
            }
            return answer
        }
        let found = try await ask("query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { id } }",
                                  ["owner": parts[0], "name": parts[1]])
        guard let id = (found["repository"] as? [String: Any])?["id"] as? String else { throw NookError("GitHub: \(repo) was not found.") }
        let made = try await ask("""
            mutation($input: CreatePullRequestInput!) { createPullRequest(input: $input) { pullRequest { url } } }
            """, ["input": ["repositoryId": id, "baseRefName": base, "headRefName": head, "title": title, "body": body, "draft": draft]])
        guard let link = ((made["createPullRequest"] as? [String: Any])?["pullRequest"] as? [String: Any])?["url"] as? String,
              let url = URL(string: link) else { throw NookError("GitHub did not return the new pull request.") }
        return url
    }

    /// The open pull request whose head is `branch` (for the git button), asked with the first account that can see the
    /// repository. Nil when there is none, or GitHub is not connected.
    static func openPullRequest(repo: String, branch: String) async -> URL? {
        guard isAvailable, let owner = repo.split(separator: "/").first.map(String.init) else { return nil }
        for token in tokens {
            guard var components = URLComponents(string: "https://api.github.com/repos/\(repo)/pulls") else { return nil }
            components.queryItems = [URLQueryItem(name: "state", value: "open"), URLQueryItem(name: "head", value: owner + ":" + branch),
                                     URLQueryItem(name: "per_page", value: "1")]
            guard let url = components.url else { return nil }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Nook", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await ConditionalFetch.data(for: request, session: ConnectorHTTP.session),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { continue }
            return (list.first?["html_url"] as? String).flatMap(URL.init(string:))
        }
        return nil
    }

    /// The open pull requests of a repository (newest first, at most 30), for the `#` list in a message. Asked with the first
    /// account that can see the repository; empty when GitHub is not connected.
    static func openPullRequests(repo: String) async -> [(number: Int, title: String)] {
        guard isAvailable else { return [] }
        for token in tokens {
            guard var components = URLComponents(string: "https://api.github.com/repos/\(repo)/pulls") else { return [] }
            components.queryItems = [URLQueryItem(name: "state", value: "open"), URLQueryItem(name: "per_page", value: "30"),
                                     URLQueryItem(name: "sort", value: "updated"), URLQueryItem(name: "direction", value: "desc")]
            guard let url = components.url else { return [] }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Nook", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await ConnectorHTTP.session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { continue }
            return list.compactMap { item in
                guard let number = item["number"] as? Int, let title = item["title"] as? String else { return nil }
                return (number, title)
            }
        }
        return []
    }

    /// The pull requests (any state) whose head is `branch` in `repo`, for the badge on a session. nil when GitHub cannot
    /// be asked (not connected, offline), so a failed check never looks like "no pull request".
    static func pullRequests(repo: String, branch: String) async -> [PullRequestLink]? {
        guard isAvailable, let owner = repo.split(separator: "/").first else { return nil }
        for token in tokens {
            guard var components = URLComponents(string: "https://api.github.com/repos/\(repo)/pulls") else { return nil }
            components.queryItems = [URLQueryItem(name: "state", value: "all"), URLQueryItem(name: "per_page", value: "10"),
                                     URLQueryItem(name: "head", value: "\(owner):\(branch)")]
            guard let url = components.url else { return nil }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Nook", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await ConnectorHTTP.session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { continue }
            let iso = ISO8601DateFormatter()
            var links: [PullRequestLink] = list.compactMap { item in
                guard let number = item["number"] as? Int, let html = item["html_url"] as? String else { return nil }
                let merged = (item["merged_at"] as? String) != nil
                let open = (item["state"] as? String) == "open"
                let state: PullRequestState = merged ? .merged : open ? ((item["draft"] as? Bool) == true ? .draft : .open) : .closed
                return PullRequestLink(host: .github, repository: repo, number: number, url: html, title: item["title"] as? String,
                                       state: state, updatedAt: (item["updated_at"] as? String).flatMap(iso.date(from:)),
                                       baseBranch: (item["base"] as? [String: Any])?["ref"] as? String,
                                       headBranch: branch)
            }
            // The list leaves out mergeability: ask each open one on its own.
            for index in links.indices where links[index].state.isOpen {
                links[index].conflicted = await conflicted(repo: repo, number: links[index].number, token: token)
            }
            return links
        }
        return nil
    }

    /// Whether an open pull request has a merge conflict with its base. False when GitHub cannot say (yet).
    private static func conflicted(repo: String, number: Int, token: String) async -> Bool {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/pulls/\(number)") else { return false }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await ConditionalFetch.data(for: request, session: ConnectorHTTP.session),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let pull = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return PullRequestMergeability.githubConflicted(pull)
    }

    private static func create(repo: String, title: String, body: String, head: String, base: String, draft: Bool, token: String) async throws -> URL {
        let url = try CloudHelp.url("https://api.github.com/repos/\(repo)/pulls")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "title": title, "body": body, "head": head, "base": base, "draft": draft
        ])
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await ConnectorHTTP.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status), let link = object["html_url"] as? String, let result = URL(string: link) else {
            if let limited = GitHubRateLimit.message(response as? HTTPURLResponse, object["message"] as? String) {
                throw NookError(limited, kind: .rateLimited)
            }
            var message = (object["message"] as? String) ?? "GitHub returned an error (\(status))."
            if let errors = object["errors"] as? [[String: Any]] {
                let details = errors.compactMap { $0["message"] as? String }
                if !details.isEmpty { message += " " + details.joined(separator: " ") }
            }
            throw NookError("GitHub: \(message)")
        }
        return result
    }
}
