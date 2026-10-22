import Foundation

/// The CI of a watched pull request, for "CI running" in a session: the checks of its head, and the steps and log of one
/// GitHub Actions job. Asked with the first connected account that can read the repository.
enum GitHubCILogs {
    /// The checks of the pull request's latest commit, failing first. Nil when no connected account can read it.
    static func checks(pullRequest url: URL) async -> [PullRequestCheck]? {
        guard GitHubPullRequests.isAvailable, let target = GitHubPullRequests.parse(url) else { return nil }
        for token in GitHubPullRequests.tokens {
            let get = getter(repo: target.repo, token: token)
            guard let pull = (try? await get("/pulls/\(target.number)")) as? [String: Any] else { continue }
            guard let sha = (pull["head"] as? [String: Any])?["sha"] as? String else { return [] }
            async let runs = (try? await get("/commits/\(sha)/check-runs?per_page=100")) as? [String: Any]
            async let status = (try? await get("/commits/\(sha)/status?per_page=100")) as? [String: Any]
            return PullRequestDetailParser.checks(runs: ((await runs)?["check_runs"] as? [[String: Any]]) ?? [],
                                                  statuses: ((await status)?["statuses"] as? [[String: Any]]) ?? [])
        }
        return nil
    }

    /// The steps of a job and, once GitHub has it (a running job has none yet), the end of its log.
    static func log(pullRequest url: URL, jobID: Int) async throws -> CILog {
        guard GitHubPullRequests.isAvailable, let target = GitHubPullRequests.parse(url) else { throw CloudHelp.notSetUp("GitHub") }
        var lastError: Error = CloudHelp.notSetUp("GitHub")
        for token in GitHubPullRequests.tokens {
            let get = getter(repo: target.repo, token: token)
            do {
                guard let job = try await get("/actions/jobs/\(jobID)") as? [String: Any] else {
                    throw NookError("GitHub returned an unexpected response.")
                }
                var log = CILog(steps: CILogParser.steps(job: job))
                if let raw = await rawLog(repo: target.repo, jobID: jobID, token: token) {
                    let cleaned = CILogParser.clean(raw)
                    log.text = cleaned.text
                    log.omittedLines = cleaned.omitted
                }
                return log
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func getter(repo: String, token: String) -> @Sendable (String) async throws -> Any {
        let auth = ["Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
        return { path in
            guard let url = URL(string: "https://api.github.com/repos/\(repo)" + path) else { throw NookError("Invalid GitHub address.") }
            return try await ConnectorHTTP.json(url, headers: auth)
        }
    }

    /// GitHub answers the log request with a redirect to a short-lived download link. That link is fetched without the
    /// token, so the token never leaves api.github.com. Nil while the job still runs (GitHub has no log yet).
    private static func rawLog(repo: String, jobID: Int, token: String) async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/actions/jobs/\(jobID)/logs") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await ConnectorHTTP.patientSession.data(for: request, delegate: NoRedirect()),
              let http = response as? HTTPURLResponse else { return nil }
        if (200..<300).contains(http.statusCode) { return String(decoding: data, as: UTF8.self) }
        guard (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"),
              let download = URL(string: location), download.scheme == "https" else { return nil }
        guard let (body, answer) = try? await ConnectorHTTP.patientSession.data(from: download),
              let status = (answer as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return nil }
        return String(decoding: body, as: UTF8.self)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
