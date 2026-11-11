import Foundation

/// GitHub's pull request event feeds over URLSession, with the connected GitHub accounts (see `GitHubPullRequestEvents`).
enum GitHubPullRequestEventStream {
    static let follower = PullRequestEventFollower(transport: URLSessionPullRequestEventTransport())

    /// Emits when GitHub says the pull request at `url` may have changed, and once per (re)connect. Nil for a link that
    /// is not on github.com, or without a GitHub account. Ends when GitHub refuses the feed; the sweep then reads alone.
    /// Changes that land while the reader is busy collapse into one.
    static func changes(_ url: URL) -> AsyncStream<Void>? {
        guard let target = GitHubPullRequestEvents.Target.parse(url), GitHubPullRequests.isAvailable else { return nil }
        let tokens = GitHubPullRequests.tokens
        guard !tokens.isEmpty else { return nil }
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                await follower.follow(target, tokens: tokens) { continuation.yield() }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct URLSessionPullRequestEventTransport: PullRequestEventTransport {
    /// Its own session: a stream lives for hours, and the request timeout is the silence after which it counts as dead.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = GitHubPullRequestEvents.silenceLimit
        configuration.timeoutIntervalForResource = 24 * 3600
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: RedirectCredentials.shared, delegateQueue: nil)
    }()

    private func request(_ url: URL, method: String, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        return request
    }

    func subscribe(body: Data, token: String) async throws -> (status: Int, body: Data) {
        guard let url = URL(string: GitHubPullRequestEvents.apiOrigin + "/event-subscriptions") else { throw URLError(.badURL) }
        var request = request(url, method: "POST", token: token)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 20
        let (data, response) = try await ConnectorHTTP.session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    func unsubscribe(id: String, token: String) async {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: GitHubPullRequestEvents.apiOrigin + "/event-subscriptions/" + escaped) else { return }
        var request = request(url, method: "DELETE", token: token)
        request.timeoutInterval = 20
        _ = try? await ConnectorHTTP.session.data(for: request)
    }

    func connect(_ url: URL, token: String) async throws -> (status: Int, text: AsyncThrowingStream<String, Error>) {
        // `GitHubPullRequestEvents.subscription` let only GitHub's API through; checked again, as the token goes along.
        guard GitHubPullRequestEvents.origin(url) == GitHubPullRequestEvents.apiOrigin else { throw URLError(.badURL) }
        var request = request(url, method: "GET", token: token)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = GitHubPullRequestEvents.silenceLimit
        let (bytes, response) = try await Self.session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            bytes.task.cancel()
            return (status, AsyncThrowingStream { $0.finish() })
        }
        let text = AsyncThrowingStream<String, Error> { continuation in
            let reader = Task {
                do {
                    // Whole lines only, so a character split across packets is never decoded in halves.
                    var line: [UInt8] = []
                    for try await byte in bytes {
                        line.append(byte)
                        if byte == 0x0A {
                            continuation.yield(String(decoding: line, as: UTF8.self))
                            line.removeAll(keepingCapacity: true)
                        }
                    }
                    if !line.isEmpty { continuation.yield(String(decoding: line, as: UTF8.self)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                bytes.task.cancel()
            }
        }
        return (status, text)
    }
}
