import Foundation

/// Gathers the pull request reads that come in close together (a sweep of watched pull requests, the badges that wake on
/// the same beat) and sends them as one GraphQL request per account, up to `GitHubPullRequestSnapshotQuery.batchLimit`
/// at a time, as t3code's request resolver batches its summaries. Foundation only: the request itself is `send`, so tests
/// give their own.
actor GitHubSnapshotBatcher {
    /// What a read came back with.
    enum Answer: Equatable, Sendable {
        case snapshot(PullRequestSnapshot)
        /// GitHub answered, without this pull request (missing, or hidden from this account).
        case missing
        /// The request failed as a whole (network, limit, refused): the caller tries the REST read.
        case failed
    }

    /// Sends a batch body with an account's token; the decoded answer, or nil when it failed.
    typealias Send = @Sendable (_ body: Data, _ token: String) async -> [String: Any]?

    private struct Waiting {
        var repo: String
        var number: Int
        var reply: CheckedContinuation<Answer, Never>
    }

    private let window: Duration
    private let send: Send
    private var waiting: [String: [Waiting]] = [:]

    /// - Parameter window: how long the first read waits for others to join it.
    init(window: Duration = .seconds(1), send: @escaping Send) {
        self.window = window
        self.send = send
    }

    /// One pull request's snapshot, read together with the others asked for within `window` with the same token.
    func snapshot(repo: String, number: Int, token: String) async -> Answer {
        await withCheckedContinuation { reply in
            let first = waiting[token, default: []].isEmpty
            waiting[token, default: []].append(Waiting(repo: repo, number: number, reply: reply))
            guard first else { return }
            Task { await self.flush(token: token, after: window) }
        }
    }

    private func flush(token: String, after delay: Duration) async {
        try? await Task.sleep(for: delay)
        let all = waiting.removeValue(forKey: token) ?? []
        // The same pull request asked twice in one window (a badge and a watch) is read once.
        var order: [String] = []
        var groups: [String: [Waiting]] = [:]
        for item in all {
            let key = item.repo.lowercased() + "#\(item.number)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        let chunks = stride(from: 0, to: order.count, by: GitHubPullRequestSnapshotQuery.batchLimit).map {
            Array(order[$0..<min($0 + GitHubPullRequestSnapshotQuery.batchLimit, order.count)])
        }
        await withTaskGroup(of: Void.self) { group in
            for chunk in chunks {
                let items = chunk.compactMap { groups[$0]?.first }.map { (repo: $0.repo, number: $0.number) }
                let replies = chunk.map { groups[$0] ?? [] }
                group.addTask { [send] in
                    let answers = await Self.read(items, token: token, send: send)
                    for (index, waiting) in replies.enumerated() {
                        for item in waiting { item.reply.resume(returning: answers[index]) }
                    }
                }
            }
        }
    }

    private static func read(_ items: [(repo: String, number: Int)], token: String, send: Send) async -> [Answer] {
        guard let body = GitHubPullRequestSnapshotQuery.batchBody(items),
              let root = await send(body, token), root["data"] is [String: Any] else {
            return items.map { _ in .failed }
        }
        return GitHubPullRequestSnapshotQuery.parseBatch(root, count: items.count).map { $0.map(Answer.snapshot) ?? .missing }
    }
}
