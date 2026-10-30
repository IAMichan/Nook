import Foundation

/// Reads a repository's GitHub Actions for the Actions page (its workflows, their runs, the jobs of a run) and re-runs or
/// cancels a run after your click. Asked with the first connected account that can read the repository.
enum GitHubActions {
    /// The token of the first account that can read `repo`.
    static func token(for repo: String) async throws -> String {
        guard GitHubPullRequests.isAvailable else { throw CloudHelp.notSetUp("GitHub") }
        var lastError: Error = CloudHelp.notSetUp("GitHub")
        for token in GitHubPullRequests.tokens {
            do {
                _ = try await get("/repos/\(repo)", token: token)
                return token
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// The repositories each account pushed to lately, most recent first, merged.
    static func pushedRepositories() async -> [String] {
        guard GitHubPullRequests.isAvailable else { return [] }
        var result: [String] = []
        for token in GitHubPullRequests.tokens {
            let json = try? await get("/user/repos?sort=pushed&per_page=40", token: token)
            result += WorkflowRunParser.repositories(json)
        }
        return result
    }

    static func workflows(repo: String, token: String) async throws -> [Workflow] {
        WorkflowRunParser.workflows(try await get("/repos/\(repo)/actions/workflows?per_page=100", token: token))
    }

    /// The latest runs of the repository, or of one of its workflows.
    static func runs(repo: String, workflowID: Int?, token: String) async throws -> [WorkflowRun] {
        WorkflowRunParser.runs(try await get("/repos/\(repo)" + WorkflowRunParser.runsPath(workflowID: workflowID), token: token))
    }

    static func run(repo: String, id: Int, token: String) async throws -> WorkflowRun {
        let json = try await get("/repos/\(repo)/actions/runs/\(id)", token: token)
        guard let run = WorkflowRunParser.runs(["workflow_runs": [json]]).first else {
            throw NookError("GitHub returned an unexpected response.")
        }
        return run
    }

    /// The jobs of the run's latest attempt.
    static func jobs(repo: String, runID: Int, token: String) async throws -> [WorkflowJob] {
        WorkflowRunParser.jobs(try await get("/repos/\(repo)/actions/runs/\(runID)/jobs?per_page=100", token: token))
    }

    /// Re-runs or cancels a run, only after your click. GitHub answers with an empty body, so this reads none; a refusal
    /// comes back in GitHub's own words.
    static func perform(_ action: WorkflowRunAction, repo: String, runID: Int, token: String) async throws {
        guard let url = URL(string: "https://api.github.com" + action.path(repo: repo, runID: runID)) else {
            throw NookError("Invalid GitHub address.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers(token) { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await ConnectorHTTP.patientSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let message = (object["message"] as? String).map { "GitHub: \($0) (\(status))" } ?? "GitHub returned an error (\(status))."
            throw NookError(message, kind: status == 401 ? .auth : ConnectorErrorKind.forHTTP(status: status))
        }
    }

    private static func headers(_ token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
    }

    private static func get(_ path: String, token: String) async throws -> Any {
        guard let url = URL(string: "https://api.github.com" + path) else { throw NookError("Invalid GitHub address.") }
        return try await ConnectorHTTP.json(url, headers: headers(token))
    }
}

/// The Actions page's list, kept between visits: the repository you picked (remembered across launches), its workflows,
/// and the latest runs of the workflow you filter on. Runs read before show at once when you come back or switch back
/// to a repository, while they are read again.
@MainActor
final class ActionsStore: ObservableObject {
    static let shared = ActionsStore()

    @Published private(set) var repo: String? {
        didSet { UserDefaults.standard.set(repo, forKey: Self.repoKey) }
    }
    /// The workflow the list shows the runs of; nil shows every workflow.
    @Published private(set) var workflowID: Int?
    @Published private(set) var workflows: [Workflow] = []
    @Published private(set) var runs: [WorkflowRun] = []
    /// Repositories typed in by hand, offered again next time.
    @Published private(set) var added: [String] {
        didSet { UserDefaults.standard.set(added, forKey: Self.addedKey) }
    }
    @Published private(set) var pushed: [String] = []
    @Published private(set) var loading = false
    /// The first read of this repository and workflow, with nothing to show yet.
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    @Published private(set) var errorKind: ConnectorErrorKind?
    @Published private(set) var lastRead: Date?

    private var tokens: [String: String] = [:]
    /// The read under way per repository and workflow.
    private var reads: [String: Task<Void, Never>] = [:]
    /// Failed reads in a row per repository and workflow.
    private var failures: [String: Int] = [:]
    private var cache: [String: (workflows: [Workflow], runs: [WorkflowRun])] = [:]
    private var pushedAt = Date.distantPast
    private static let repoKey = "nook.actions.repo"
    private static let addedKey = "nook.actions.added"

    private init() {
        repo = UserDefaults.standard.string(forKey: Self.repoKey)
        added = UserDefaults.standard.stringArray(forKey: Self.addedKey) ?? []
    }

    var available: Bool { GitHubPullRequests.isAvailable }
    var hasActiveRuns: Bool { runs.contains { !$0.isCompleted } }

    /// Opens a repository: what was read of it before shows at once, the rest follows.
    func select(_ repository: String) {
        guard repository != repo else { return }
        repo = repository
        workflowID = nil
        showCached()
        Task { await refresh() }
    }

    /// Opens a repository typed in by hand ("owner/repo" or a github.com link); false when it is neither.
    @discardableResult
    func add(_ text: String) -> Bool {
        guard let repository = WorkflowRunParser.repository(from: text) else { return false }
        if !added.contains(where: { $0.caseInsensitiveCompare(repository) == .orderedSame }) {
            added = Array(([repository] + added).prefix(12))
        }
        select(repository)
        return true
    }

    func select(workflow id: Int?) {
        guard id != workflowID else { return }
        workflowID = id
        showCached()
        Task { await refresh() }
    }

    private var cacheKey: String { (repo ?? "") + "|" + (workflowID.map(String.init) ?? "") }

    private func showCached() {
        if let kept = cache[cacheKey] {
            runs = kept.runs
            if !kept.workflows.isEmpty { workflows = kept.workflows }
            loaded = true
        } else {
            runs = []
            if workflowID == nil { workflows = [] }
            loaded = false
        }
        error = nil
        errorKind = nil
    }

    /// Reads the workflows and runs again. The read is the store's own, not the caller's: the page restarts its loop
    /// when it opens or picks a repository, and that must not cancel a request halfway and show it as an error. A
    /// second caller waits for the read already under way. A read for a repository or workflow you have since left is
    /// thrown away.
    func refresh() async {
        guard let repo else { return }
        let workflowID = self.workflowID
        let key = cacheKey
        if let running = reads[key] { return await running.value }
        let read = Task { await self.read(repo: repo, workflowID: workflowID, key: key) }
        reads[key] = read
        loading = true
        await read.value
        reads[key] = nil
        loading = !reads.isEmpty
    }

    private func read(repo: String, workflowID: Int?, key: String) async {
        do {
            let token: String
            if let known = tokens[repo] {
                token = known
            } else {
                token = try await GitHubActions.token(for: repo)
                tokens[repo] = token
            }
            async let workflows = GitHubActions.workflows(repo: repo, token: token)
            let runs = try await GitHubActions.runs(repo: repo, workflowID: workflowID, token: token)
            let list = (try? await workflows) ?? self.workflows
            failures[key] = 0
            guard repo == self.repo, workflowID == self.workflowID else { return }
            self.runs = runs
            self.workflows = list
            cache[key] = (list, runs)
            error = nil
            errorKind = nil
            lastRead = Date()
            loaded = true
        } catch {
            if Self.isCancellation(error) { return }
            // A token that worked before may have lost access; the next read tries every account again.
            tokens[repo] = nil
            let count = (failures[key] ?? 0) + 1
            failures[key] = count
            let kind = (error as? NookError)?.kind
            // A passing failure (no connection for a moment, GitHub slow to answer) is tried again once at once and
            // only shows when it happens twice in a row; a refused token shows straight away.
            if count < 2 && kind != .auth {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                return await read(repo: repo, workflowID: workflowID, key: key)
            }
            guard repo == self.repo, workflowID == self.workflowID else { return }
            loaded = true
            self.error = error.localizedDescription
            errorKind = kind
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// The repositories you pushed to lately, read again at most every ten minutes.
    func refreshRepositories() async {
        guard Date().timeIntervalSince(pushedAt) > 600 else { return }
        pushedAt = Date()
        let fresh = await GitHubActions.pushedRepositories()
        if !fresh.isEmpty { pushed = fresh }
        // Nothing picked yet: the repository you pushed to last.
        if repo == nil, let first = fresh.first { select(first) }
    }

    /// The token for a run's page: the one that read the list.
    func token(for repository: String) async throws -> String {
        if let known = tokens[repository] { return known }
        let token = try await GitHubActions.token(for: repository)
        tokens[repository] = token
        return token
    }
}
