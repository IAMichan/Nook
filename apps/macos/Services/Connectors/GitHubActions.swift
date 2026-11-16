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

    /// Runs `read` with the first account that can read `repo`: `known` (the one that read it last) first, then the
    /// others. The read itself shows whether an account may read the repository, so a list costs no extra request for
    /// that. Only a refused token (401, 403) or a repository the account cannot see (404) moves on to the next account;
    /// any other failure is the read's own.
    static func reading<T: Sendable>(_ repo: String, known: String?,
                                     _ read: @Sendable (String) async throws -> T) async throws -> (value: T, token: String) {
        guard GitHubPullRequests.isAvailable else { throw CloudHelp.notSetUp("GitHub") }
        let all = GitHubPullRequests.tokens
        var lastError: Error = CloudHelp.notSetUp("GitHub")
        for token in all.filter({ $0 == known }) + all.filter({ $0 != known }) {
            do {
                return (try await read(token), token)
            } catch {
                lastError = error
                let kind = (error as? NookError)?.kind
                guard kind == .auth || kind == .config else { throw error }
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

    /// The same runs as `runs`, for a list with nothing to show yet: in `WorkflowRunParser.firstReadPages` pages asked
    /// at once, which GitHub answers about twice as fast as one large page.
    static func firstRuns(repo: String, workflowID: Int?, token: String) async throws -> [WorkflowRun] {
        let count = WorkflowRunParser.firstReadPages
        return try await withThrowingTaskGroup(of: (Int, [WorkflowRun]).self) { group in
            for page in 1...count {
                group.addTask {
                    let path = "/repos/\(repo)" + WorkflowRunParser.runsPath(workflowID: workflowID, page: page)
                    return (page, WorkflowRunParser.runs(try await get(path, token: token)))
                }
            }
            var pages: [Int: [WorkflowRun]] = [:]
            for try await (page, runs) in group { pages[page] = runs }
            return WorkflowRunParser.merged((1...count).map { pages[$0] ?? [] })
        }
    }

    static func run(repo: String, id: Int, token: String) async throws -> WorkflowRun {
        let json = try await get("/repos/\(repo)/actions/runs/\(id)", token: token)
        guard let run = WorkflowRunParser.runs(["workflow_runs": [json]]).first else {
            throw NookError("GitHub returned an unexpected response.")
        }
        return run
    }

    /// The latest runs of one workflow on one branch, to find the run that replaced one cancelled before its first job.
    static func runs(repo: String, workflowID: Int, branch: String, token: String) async throws -> [WorkflowRun] {
        WorkflowRunParser.runs(try await get("/repos/\(repo)" + WorkflowRunParser.branchRunsPath(workflowID: workflowID, branch: branch),
                                             token: token))
    }

    /// Why a finished run has no jobs. Reading its neighbours is a best effort: without them the run still reads as
    /// cancelled before it started.
    static func noJobs(repo: String, run: WorkflowRun, jobs: [WorkflowJob], token: String) async -> WorkflowRunNoJobs? {
        guard run.isCompleted, jobs.isEmpty else { return nil }
        var others: [WorkflowRun] = []
        if run.conclusion == "cancelled", !run.branch.isEmpty {
            others = (try? await runs(repo: repo, workflowID: run.workflowID, branch: run.branch, token: token)) ?? []
        }
        return WorkflowRunParser.noJobs(repo: repo, run: run, jobs: jobs, others: others)
    }

    /// The jobs of the run's latest attempt.
    static func jobs(repo: String, runID: Int, token: String) async throws -> [WorkflowJob] {
        WorkflowRunParser.jobs(try await get("/repos/\(repo)/actions/runs/\(runID)/jobs?per_page=100", token: token))
    }

    /// Re-runs or cancels a run, only after your click. GitHub answers with an empty body, so this reads none; a refusal
    /// comes back in GitHub's own words.
    static func perform(_ action: WorkflowRunAction, repo: String, runID: Int, token: String) async throws {
        _ = try await post(action.path(repo: repo, runID: runID), token: token)
    }

    /// A POST that changes something on GitHub, its answer's body returned; a refusal in GitHub's own words.
    private static func post(_ path: String, token: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: "https://api.github.com" + path) else { throw NookError("Invalid GitHub address.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        for (key, value) in headers(token) { request.setValue(value, forHTTPHeaderField: key) }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await ConnectorHTTP.patientSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let message = (object["message"] as? String).map { "GitHub: \($0) (\(status))" } ?? "GitHub returned an error (\(status))."
            throw NookError(message, kind: status == 401 ? .auth : ConnectorErrorKind.forHTTP(status: status))
        }
        return data
    }

    /// The repository's default branch, which a run form starts on.
    static func defaultBranch(repo: String, token: String) async throws -> String {
        ((try await get("/repos/\(repo)", token: token) as? [String: Any])?["default_branch"] as? String) ?? ""
    }

    /// The branches a workflow can be started on, the default branch first.
    static func branches(repo: String, defaultBranch: String, token: String) async throws -> [String] {
        WorkflowDispatch.branches(try await get("/repos/\(repo)/branches?per_page=100", token: token), defaultBranch: defaultBranch)
    }

    /// The inputs of a workflow that can be started by hand, read from its file at `ref`; nil when it cannot be (no
    /// `workflow_dispatch`, or no such file on that branch).
    static func dispatchInputs(repo: String, path: String, ref: String, token: String) async throws -> [WorkflowInput]? {
        do {
            let json = try await get(WorkflowDispatch.filePath(repo: repo, path: path, ref: ref), token: token)
            return WorkflowDispatch.fileText(json).flatMap(WorkflowDispatch.inputs)
        } catch let error as NookError where error.kind == .config {
            return nil
        }
    }

    /// Which of `workflows` can be started by hand, with their inputs, read from their files at `ref` side by side.
    /// A file that cannot be read counts as one that cannot be started.
    static func dispatchable(repo: String, workflows: [Workflow], ref: String, token: String) async -> [Int: [WorkflowInput]] {
        await withTaskGroup(of: (Int, [WorkflowInput]?).self) { group in
            for workflow in workflows where workflow.path.hasPrefix(".github/") {
                group.addTask {
                    let inputs = try? await dispatchInputs(repo: repo, path: workflow.path, ref: ref, token: token)
                    return (workflow.id, inputs ?? nil)
                }
            }
            var result: [Int: [WorkflowInput]] = [:]
            for await (id, inputs) in group { if let inputs { result[id] = inputs } }
            return result
        }
    }

    /// Starts a workflow by hand, only after your click. Returns the new run's id when GitHub gives it.
    static func dispatch(repo: String, workflowID: Int, ref: String, inputs: [WorkflowInput], values: [String: String],
                         token: String) async throws -> Int? {
        let body = WorkflowDispatch.body(ref: ref, inputs: inputs, values: values)
        let data = try await post("/repos/\(repo)/actions/workflows/\(workflowID)/dispatches", token: token,
                                  body: try JSONSerialization.data(withJSONObject: body))
        return data.isEmpty ? nil : WorkflowDispatch.runID(try? JSONSerialization.jsonObject(with: data))
    }

    private static func headers(_ token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
    }

    /// Every read is conditional: the page polls the same lists, and an unchanged one comes back as a 304 without a body,
    /// quicker and outside GitHub's rate limit.
    private static func get(_ path: String, token: String) async throws -> Any {
        guard let url = URL(string: "https://api.github.com" + path) else { throw NookError("Invalid GitHub address.") }
        return try await ConnectorHTTP.json(url, headers: headers(token), conditional: true)
    }
}

/// The Actions page's list, kept between visits: the repository you picked (remembered across launches), the
/// repositories on its tab bar, its workflows, and the latest runs of the workflow you filter on. Runs read before show
/// at once when you come back or switch back to a repository, while they are read again; the other tabs are read in the
/// background now and then, so each shows how it stands and opens without waiting.
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
    /// The repositories on the tab bar, in their order: a new one comes in first; remembered across launches.
    @Published private(set) var recent: [String] {
        didSet { UserDefaults.standard.set(recent, forKey: Self.recentKey) }
    }
    /// How each repository read so far stands, by its lowercased name, for its tab.
    @Published private(set) var statuses: [String: WorkflowRepoStatus] = [:]
    /// The repositories you pushed to were read once, so a page without a repository can say to pick one.
    @Published private(set) var repositoriesLoaded = false
    @Published private(set) var loading = false
    /// The first read of this repository and workflow, with nothing to show yet.
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    @Published private(set) var errorKind: ConnectorErrorKind?
    @Published private(set) var lastRead: Date?
    /// What can be started by hand in the open repository: its default branch and the workflows with a
    /// `workflow_dispatch` trigger, with their inputs. Nil until read.
    @Published private(set) var dispatchInfo: ActionsDispatchInfo?

    private var tokens: [String: String] = [:]
    /// The read under way per repository and workflow.
    private var reads: [String: Task<Void, Never>] = [:]
    /// Failed reads in a row per repository and workflow.
    private var failures: [String: Int] = [:]
    private var cache: [String: ActionsSnapshot] = [:]
    /// The latest write of `cache` to disk; the next one waits for it, so an older list never lands last.
    private var saving: Task<Void, Never>?
    private var pushedAt = Date.distantPast
    /// When each tab's repository was last read in the background.
    private var peekedAt: [String: Date] = [:]
    private var peeking = false
    /// What can be started by hand per repository (lowercased), read at most every ten minutes or when its workflows
    /// change.
    private var dispatchCache: [String: ActionsDispatchInfo] = [:]
    private var dispatchReads: Set<String> = []
    private static let recentKey = "nook.actions.recent"
    private static let repoKey = "nook.actions.repo"
    private static let addedKey = "nook.actions.added"

    private init() {
        let picked = UserDefaults.standard.string(forKey: Self.repoKey)
        let typed = UserDefaults.standard.stringArray(forKey: Self.addedKey) ?? []
        repo = picked
        added = typed
        // Before there were tabs: the repository you had open and the ones you typed in.
        recent = UserDefaults.standard.stringArray(forKey: Self.recentKey)
            ?? Array(WorkflowRunParser.candidates(selected: picked, pushed: typed, pullRequests: [], watched: []).prefix(8))
        // The tabs' lists as last read, so the page shows runs at once after a restart while it reads them again.
        cache = ActionsSnapshot.load(from: Self.fileURL)
        for (key, kept) in cache where key.hasSuffix("|") {
            statuses[String(key.dropLast()).lowercased()] = WorkflowRepoStatus(runs: kept.runs)
        }
        showCached()
    }

    private static var fileURL: URL { NookPaths.supportDirectory.appendingPathComponent("actions-runs.json") }

    /// Writes the lists of the tabs' repositories (all workflows) to disk, away from the main thread.
    private func save() {
        let tabs = Set(recent.map { $0.lowercased() + "|" })
        let kept = cache.filter { tabs.contains($0.key.lowercased()) }
        let previous = saving
        let url = Self.fileURL
        saving = Task.detached(priority: .utility) {
            await previous?.value
            ActionsSnapshot.save(kept, to: url)
        }
    }

    func status(of repository: String) -> WorkflowRepoStatus? { statuses[repository.lowercased()] }

    var available: Bool { GitHubPullRequests.isAvailable }
    var hasActiveRuns: Bool { runs.contains { !$0.isCompleted } }

    /// Opens a repository: what was read of it before shows at once, the rest follows.
    func select(_ repository: String) {
        recent = WorkflowRunParser.recent(opening: repository, in: recent)
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

    /// Takes a repository off the tab bar. Closing the open one opens the tab next to it.
    func close(_ repository: String) {
        guard let index = recent.firstIndex(where: { $0.caseInsensitiveCompare(repository) == .orderedSame }) else { return }
        recent.remove(at: index)
        guard repository.caseInsensitiveCompare(repo ?? "") == .orderedSame, !recent.isEmpty else { return }
        select(recent[min(index, recent.count - 1)])
    }

    /// The tab before or after the open one (`offset` −1 or 1), going round.
    func selectNeighbor(_ offset: Int) {
        guard recent.count > 1, let repo,
              let index = recent.firstIndex(where: { $0.caseInsensitiveCompare(repo) == .orderedSame }) else { return }
        select(recent[(index + offset + recent.count) % recent.count])
    }

    func select(workflow id: Int?) {
        guard id != workflowID else { return }
        workflowID = id
        showCached()
        Task { await refresh() }
    }

    private var cacheKey: String { (repo ?? "") + "|" + (workflowID.map(String.init) ?? "") }

    private func showCached() {
        dispatchInfo = repo.flatMap { dispatchCache[$0.lowercased()] }
        // A workflow not read on its own yet: its runs in the list of every workflow, at once, while its own are read.
        if cache[cacheKey] == nil, let workflowID, let repo, let all = cache[repo + "|"] {
            runs = all.runs.filter { $0.workflowID == workflowID }
            if !all.workflows.isEmpty { workflows = all.workflows }
            lastRead = nil
            loaded = !runs.isEmpty
            error = nil
            errorKind = nil
            return
        }
        if let kept = cache[cacheKey] {
            runs = kept.runs
            if !kept.workflows.isEmpty { workflows = kept.workflows }
            lastRead = kept.read
            loaded = true
        } else {
            runs = []
            if workflowID == nil { workflows = [] }
            lastRead = nil
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
            // Nothing on screen yet: the quicker read in pages. Later reads ask once, as they poll.
            let first = cache[key] == nil
            let (fetched, token) = try await GitHubActions.reading(repo, known: tokens[repo]) { token in
                async let workflows = GitHubActions.workflows(repo: repo, token: token)
                let runs = first ? try await GitHubActions.firstRuns(repo: repo, workflowID: workflowID, token: token)
                    : try await GitHubActions.runs(repo: repo, workflowID: workflowID, token: token)
                return (runs: runs, workflows: try? await workflows)
            }
            tokens[repo] = token
            let runs = fetched.runs
            let list = fetched.workflows ?? cache[key]?.workflows ?? self.workflows
            let now = Date()
            failures[key] = 0
            cache[key] = ActionsSnapshot(read: now, workflows: list, runs: runs)
            if workflowID == nil {
                statuses[repo.lowercased()] = WorkflowRepoStatus(runs: runs)
                save()
            }
            if fetched.workflows != nil { Task { await readDispatch(repo: repo, workflows: list, token: token) } }
            guard repo == self.repo, workflowID == self.workflowID else { return }
            self.runs = runs
            self.workflows = list
            error = nil
            errorKind = nil
            lastRead = now
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
        repositoriesLoaded = true
        // Nothing picked yet: the repository you pushed to last.
        if repo == nil, let first = fresh.first { select(first) }
    }

    /// Reads the other tabs' repositories in the background, one after the other and each at most every two minutes,
    /// so a tab shows how its runs stand and opens with them at once. A failure only leaves that tab without a mark.
    func peekRecent() async {
        guard available, !peeking else { return }
        peeking = true
        defer { peeking = false }
        for repository in recent where repository.caseInsensitiveCompare(repo ?? "") != .orderedSame {
            guard !Task.isCancelled else { return }
            let name = repository.lowercased()
            if let last = peekedAt[name], Date().timeIntervalSince(last) < 120 { continue }
            peekedAt[name] = Date()
            guard let fetched = try? await GitHubActions.reading(repository, known: tokens[repository], { token in
                async let workflows = GitHubActions.workflows(repo: repository, token: token)
                let runs = try await GitHubActions.runs(repo: repository, workflowID: nil, token: token)
                return (runs: runs, workflows: try? await workflows)
            }) else { continue }
            tokens[repository] = fetched.token
            let read = fetched.value
            statuses[name] = WorkflowRepoStatus(runs: read.runs)
            // The open repository's own read is the fresher one; never overwrite it with this.
            let key = repository + "|"
            if repository != repo || cache[key] == nil {
                cache[key] = ActionsSnapshot(read: Date(), workflows: read.workflows ?? cache[key]?.workflows ?? [], runs: read.runs)
            }
        }
        save()
    }

    /// Reads which workflows can be started by hand, from their files on the default branch: once, again after ten
    /// minutes, or when the workflows changed. A failure leaves what was read before.
    private func readDispatch(repo: String, workflows: [Workflow], token: String) async {
        let name = repo.lowercased()
        let ids = Set(workflows.map(\.id))
        if let known = dispatchCache[name], known.workflowIDs == ids, Date().timeIntervalSince(known.read) < 600 { return }
        guard dispatchReads.insert(name).inserted else { return }
        defer { dispatchReads.remove(name) }
        guard let branch = try? await GitHubActions.defaultBranch(repo: repo, token: token), !branch.isEmpty else { return }
        let inputs = await GitHubActions.dispatchable(repo: repo, workflows: workflows, ref: branch, token: token)
        let info = ActionsDispatchInfo(read: Date(), defaultBranch: branch, workflowIDs: ids, inputs: inputs)
        dispatchCache[name] = info
        if repo.caseInsensitiveCompare(self.repo ?? "") == .orderedSame { dispatchInfo = info }
    }

    /// The branches of the open repository a workflow can be started on, the default branch first.
    func dispatchBranches() async -> [String] {
        guard let repo, let info = dispatchInfo else { return [] }
        guard let token = try? await token(for: repo),
              let list = try? await GitHubActions.branches(repo: repo, defaultBranch: info.defaultBranch, token: token),
              !list.isEmpty else { return [info.defaultBranch] }
        return list
    }

    /// The inputs of `workflow` as its file reads on `ref`; nil when it cannot be started there. The default branch's
    /// were read already.
    func dispatchInputs(_ workflow: Workflow, ref: String) async throws -> [WorkflowInput]? {
        guard let repo else { return nil }
        if let info = dispatchInfo, ref == info.defaultBranch { return info.inputs[workflow.id] }
        let token = try await token(for: repo)
        return try await GitHubActions.dispatchInputs(repo: repo, path: workflow.path, ref: ref, token: token)
    }

    /// Starts a workflow by hand and reads the list again, so the new run shows. Returns the new run when GitHub named
    /// it and it is in the list.
    func dispatch(workflow: Workflow, ref: String, inputs: [WorkflowInput], values: [String: String]) async throws -> WorkflowRun? {
        guard let repo else { return nil }
        let token = try await token(for: repo)
        let id = try await GitHubActions.dispatch(repo: repo, workflowID: workflow.id, ref: ref, inputs: inputs, values: values,
                                                  token: token)
        // Without the run's id GitHub needs a moment before the run shows in the list.
        if id == nil { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        await refresh()
        guard let id else { return nil }
        if let listed = runs.first(where: { $0.id == id }) { return listed }
        return try? await GitHubActions.run(repo: repo, id: id, token: token)
    }

    /// The token for a run's page: the one that read the list.
    func token(for repository: String) async throws -> String {
        if let known = tokens[repository] { return known }
        let token = try await GitHubActions.token(for: repository)
        tokens[repository] = token
        return token
    }
}

/// What can be started by hand in a repository: its default branch and, per workflow with a `workflow_dispatch` trigger,
/// the inputs it asks for.
struct ActionsDispatchInfo: Equatable, Sendable {
    let read: Date
    let defaultBranch: String
    /// The workflows the files were read for, so a changed list is read again.
    let workflowIDs: Set<Int>
    let inputs: [Int: [WorkflowInput]]
}
