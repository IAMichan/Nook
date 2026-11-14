import Foundation

/// A repository's GitHub Actions as the Actions page shows them: its workflows (CI, Promote, Release…), their runs, and
/// the jobs of one run. Parsed from GitHub's REST answers by `WorkflowRunParser`; Foundation only, so tests can use it.
struct Workflow: Identifiable, Equatable, Codable, Sendable {
    let id: Int
    let name: String
    /// ".github/workflows/ci.yml".
    let path: String
}

struct WorkflowRun: Identifiable, Equatable, Codable, Sendable {
    let id: Int
    let workflowID: Int
    /// The workflow's name ("CI", "Promote").
    let name: String
    /// What the run is about: the commit's subject, the pull request's title, or the workflow's own run name.
    let title: String
    let number: Int
    var attempt = 1
    let branch: String
    let sha: String
    /// What started it, in GitHub's words: "push", "pull_request", "workflow_dispatch", "schedule", "release"…
    let event: String
    let actor: String
    /// "queued", "in_progress", "completed", or one of the waiting states ("waiting", "requested", "pending").
    let status: String
    /// Once completed: "success", "failure", "cancelled", "skipped", "timed_out", "action_required", "neutral"…
    let conclusion: String
    let created: Date?
    var started: Date? = nil
    var updated: Date? = nil
    let url: URL?
    /// The workflow file it ran from (".github/workflows/ci.yml"); empty when GitHub gave none.
    var path = ""

    var isCompleted: Bool { status == "completed" }
    var running: Bool { status == "in_progress" }
    /// Waits for someone to approve it (an environment with required reviewers, a first-time contributor).
    var waitsForApproval: Bool { status == "waiting" || conclusion == "action_required" }

    var outcome: PullRequestCheck.Outcome {
        guard isCompleted else { return .pending }
        if WorkflowRunParser.failed.contains(conclusion) { return .failing }
        if ["skipped", "neutral"].contains(conclusion) { return .skipped }
        return .passing
    }

    /// When it finished, for its clock; nil while it waits or runs.
    var finished: Date? { isCompleted ? updated : nil }

    /// The run as a check, so it shows the same status line and mark as a check on a pull request.
    var check: PullRequestCheck {
        PullRequestCheck(name: name, outcome: outcome, detail: isCompleted ? conclusion : status, url: url, isCheckRun: true,
                         running: running, started: started ?? created, finished: finished)
    }

    var canCancel: Bool { !isCompleted }
    var canRerun: Bool { isCompleted }
    var canRerunFailed: Bool { isCompleted && outcome == .failing }
    var shortSHA: String { String(sha.prefix(7)) }
}

struct WorkflowJob: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String
    var started: Date? = nil
    var completed: Date? = nil
    /// "…/actions/runs/{run}/job/{id}": the job's page, which `CILogParser.jobID` reads the id back from.
    let url: URL?
    var steps: Int = 0

    /// The job as a check, so it opens in `CICheckLogView` like a check on a pull request does.
    var check: PullRequestCheck {
        let outcome: PullRequestCheck.Outcome
        if status != "completed" { outcome = .pending }
        else if WorkflowRunParser.failed.contains(conclusion) { outcome = .failing }
        else if ["skipped", "neutral"].contains(conclusion) { outcome = .skipped }
        else { outcome = .passing }
        return PullRequestCheck(name: name, outcome: outcome, detail: status == "completed" ? conclusion : status, url: url,
                                isCheckRun: true, running: status == "in_progress", started: started,
                                finished: status == "completed" ? completed : nil)
    }
}

/// Why a finished run has no jobs. GitHub keeps no log and no annotation for a run that never started a job (its log
/// archive is empty), so the run view says what it can read from the run and its neighbours instead.
enum WorkflowRunNoJobs: Equatable, Sendable {
    /// Cancelled before a job started because a newer run of the same workflow on the same branch took its place (the
    /// workflow's `concurrency` group).
    case replaced(id: Int, number: Int, url: URL?)
    /// Cancelled before a job started, by someone or by another workflow.
    case cancelled
    /// GitHub could not start the workflow, nearly always an error in its file.
    case workflowError(path: String, file: URL?)
    /// Every job was skipped by its condition.
    case skipped
    /// It waits for someone to approve it.
    case approval
    /// Finished without jobs and without a reason GitHub gives.
    case empty
}

/// What the Actions page can do to a run, each one GitHub call after your click.
enum WorkflowRunAction: String, Equatable, Sendable {
    case rerun, rerunFailed, cancel

    func path(repo: String, runID: Int) -> String {
        let run = "/repos/\(repo)/actions/runs/\(runID)"
        switch self {
        case .rerun: return run + "/rerun"
        case .rerunFailed: return run + "/rerun-failed-jobs"
        case .cancel: return run + "/cancel"
        }
    }

    /// The tool name in the action log.
    var auditTool: String {
        switch self {
        case .rerun: return "github_rerun_workflow"
        case .rerunFailed: return "github_rerun_failed_jobs"
        case .cancel: return "github_cancel_workflow"
        }
    }
}

/// Which runs the list shows, besides the workflow: everything, what still runs or waits, or what failed.
enum WorkflowRunFilter: String, CaseIterable, Sendable {
    case all, active, failed

    func matches(_ run: WorkflowRun) -> Bool {
        switch self {
        case .all: return true
        case .active: return !run.isCompleted
        case .failed: return run.outcome == .failing
        }
    }
}

/// How a repository's Actions stand at a glance, for its tab on the Actions page: something still runs, a workflow's
/// newest run failed, or how the newest run went.
struct WorkflowRepoStatus: Equatable, Sendable {
    let outcome: PullRequestCheck.Outcome
    let running: Bool
    /// Runs that still run or wait.
    let active: Int
    /// Workflows whose newest finished run failed.
    let failing: Int

    /// Nil for a repository without runs: its tab shows no mark.
    init?(runs: [WorkflowRun]) {
        guard let newest = runs.first else { return nil }
        active = runs.count(where: { !$0.isCompleted })
        failing = WorkflowRunParser.latestPerWorkflow(runs.filter(\.isCompleted)).values.count(where: { $0.outcome == .failing })
        running = runs.contains(where: \.running)
        if active > 0 { outcome = .pending }
        else if failing > 0 { outcome = .failing }
        else { outcome = newest.outcome }
    }
}

enum WorkflowRunParser {
    /// Conclusions that count as a failure: what a run or a job ends with when something is wrong.
    static let failed: Set<String> = ["failure", "timed_out", "cancelled", "action_required", "startup_failure", "stale"]

    /// The runs Nook reads at once: about two screens of a busy repository.
    static let pageSize = 40

    /// `GET /actions/runs`, or the runs of one workflow (`/actions/workflows/{id}/runs`). Without the pull requests of
    /// each run, which the list never shows: GitHub looks them up per run, and leaving them out makes its answer quicker
    /// and smaller.
    static func runsPath(workflowID: Int?) -> String {
        let base = workflowID.map { "/actions/workflows/\($0)/runs" } ?? "/actions/runs"
        return base + "?per_page=\(pageSize)&\(lean)"
    }

    static let lean = "exclude_pull_requests=true"

    /// A list with nothing to show yet is read in this many pages at once. GitHub's time grows with the page (about
    /// 0.6 s for 10 runs, 1.2 to 1.6 s for 40), so four pages of 10 side by side come in about twice as fast as one of
    /// 40. Later reads, while the list is already on screen, ask once, so polling costs one request.
    static let firstReadPages = 4

    /// The same runs as `runsPath`, as page `page` (from 1) of `firstReadPages`.
    static func runsPath(workflowID: Int?, page: Int) -> String {
        let base = workflowID.map { "/actions/workflows/\($0)/runs" } ?? "/actions/runs"
        return base + "?per_page=\(pageSize / firstReadPages)&page=\(page)&\(lean)"
    }

    /// Pages read side by side as one list, in page order. A run that started between two pages' reads pushes the
    /// others down a place, so one can be on two pages: it is kept once.
    static func merged(_ pages: [[WorkflowRun]]) -> [WorkflowRun] {
        var seen = Set<Int>()
        return pages.flatMap { $0 }.filter { seen.insert($0.id).inserted }
    }

    /// The active workflows of `GET /actions/workflows`, by name. A disabled one runs no more, so it is no filter.
    static func workflows(_ json: Any?) -> [Workflow] {
        let list = ((json as? [String: Any])?["workflows"] as? [[String: Any]]) ?? []
        return list.compactMap { item -> Workflow? in
            guard let id = int(item["id"]), (item["state"] as? String ?? "active") == "active" else { return nil }
            return Workflow(id: id, name: (item["name"] as? String) ?? "?", path: (item["path"] as? String) ?? "")
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func runs(_ json: Any?) -> [WorkflowRun] {
        let list = ((json as? [String: Any])?["workflow_runs"] as? [[String: Any]]) ?? []
        return list.compactMap { item -> WorkflowRun? in
            guard let id = int(item["id"]) else { return nil }
            let name = (item["name"] as? String) ?? "?"
            let commit = ((item["head_commit"] as? [String: Any])?["message"] as? String)?
                .components(separatedBy: "\n").first ?? ""
            let title = [(item["display_title"] as? String) ?? "", commit, name].first { !$0.isEmpty } ?? name
            return WorkflowRun(id: id, workflowID: int(item["workflow_id"]) ?? 0, name: name, title: title,
                               number: int(item["run_number"]) ?? 0, attempt: int(item["run_attempt"]) ?? 1,
                               branch: (item["head_branch"] as? String) ?? "", sha: (item["head_sha"] as? String) ?? "",
                               event: (item["event"] as? String) ?? "", actor: login(item["triggering_actor"]) ?? login(item["actor"]) ?? "",
                               status: (item["status"] as? String) ?? "", conclusion: (item["conclusion"] as? String) ?? "",
                               created: PullRequestDetailParser.date(item["created_at"]),
                               started: PullRequestDetailParser.date(item["run_started_at"]),
                               updated: PullRequestDetailParser.date(item["updated_at"]),
                               url: (item["html_url"] as? String).flatMap(URL.init(string:)),
                               path: (item["path"] as? String) ?? "")
        }
    }

    /// The latest runs of one workflow on one branch: the neighbours of a run cancelled before its first job.
    static func branchRunsPath(workflowID: Int, branch: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
        let encoded = branch.addingPercentEncoding(withAllowedCharacters: allowed) ?? branch
        return "/actions/workflows/\(workflowID)/runs?branch=\(encoded)&per_page=30&\(lean)"
    }

    /// How long after a run was cancelled its replacement may have been created: GitHub cancels the older run within a
    /// few seconds of queueing the newer one.
    static let replacementWindow: TimeInterval = 10

    /// The run that took `run`'s place: the first newer run of the same workflow on the same branch created before (or
    /// just after) `run` was cancelled.
    static func replacement(of run: WorkflowRun, in others: [WorkflowRun]) -> WorkflowRun? {
        guard let cancelled = run.finished else { return nil }
        let latest = cancelled.addingTimeInterval(replacementWindow)
        return others
            .filter { $0.id != run.id && $0.workflowID == run.workflowID && $0.branch == run.branch && $0.number > run.number }
            .filter { ($0.created ?? .distantFuture) <= latest }
            .min { $0.number < $1.number }
    }

    /// The workflow file at the run's commit on github.com, for a run that could not start.
    static func workflowFile(repo: String, sha: String, path: String) -> URL? {
        guard path.hasPrefix(".github/"), !sha.isEmpty, isRepository(repo) else { return nil }
        // A reusable workflow's run path reads ".github/workflows/x.yml@refs/heads/main"; the file is the part before the @.
        let file = path.split(separator: "@", maxSplits: 1).first.map(String.init) ?? path
        return URL(string: "https://github.com/\(repo)/blob/\(sha)/\(file)")
    }

    /// Why `run` has no jobs, or nil while it still runs or when it has jobs. `others` are the latest runs of its
    /// workflow on its branch, to find the run that replaced a cancelled one.
    static func noJobs(repo: String, run: WorkflowRun, jobs: [WorkflowJob], others: [WorkflowRun]) -> WorkflowRunNoJobs? {
        guard run.isCompleted, jobs.isEmpty else { return nil }
        switch run.conclusion {
        case "cancelled":
            guard let newer = replacement(of: run, in: others) else { return .cancelled }
            return .replaced(id: newer.id, number: newer.number, url: newer.url)
        // A run fails without a single job only when GitHub could not start the workflow.
        case "startup_failure", "failure":
            return .workflowError(path: run.path, file: workflowFile(repo: repo, sha: run.sha, path: run.path))
        case "skipped": return .skipped
        case "action_required": return .approval
        default: return .empty
        }
    }

    /// The jobs of `GET /actions/runs/{id}/jobs`, in the order GitHub started them.
    static func jobs(_ json: Any?) -> [WorkflowJob] {
        let list = ((json as? [String: Any])?["jobs"] as? [[String: Any]]) ?? []
        return list.compactMap { item -> WorkflowJob? in
            guard let id = int(item["id"]) else { return nil }
            return WorkflowJob(id: id, name: (item["name"] as? String) ?? "?", status: (item["status"] as? String) ?? "",
                               conclusion: (item["conclusion"] as? String) ?? "",
                               started: PullRequestDetailParser.date(item["started_at"]),
                               completed: PullRequestDetailParser.date(item["completed_at"]),
                               url: (item["html_url"] as? String).flatMap(URL.init(string:)),
                               steps: ((item["steps"] as? [Any]) ?? []).count)
        }
    }

    /// "owner/repo" of each repository in `GET /user/repos`, in the order GitHub gave them.
    static func repositories(_ json: Any?) -> [String] {
        ((json as? [[String: Any]]) ?? []).compactMap { item -> String? in
            // An archived repository runs nothing any more.
            (item["archived"] as? Bool) == true ? nil : item["full_name"] as? String
        }
    }

    /// The repositories the page offers: the one you picked, those you pushed to lately, then those of your pull
    /// requests and the repositories you watch, each once (ignoring case) and in that order.
    static func candidates(selected: String?, pushed: [String], pullRequests: [String], watched: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for repo in [selected].compactMap({ $0 }) + pushed + pullRequests + watched where isRepository(repo) {
            if seen.insert(repo.lowercased()).inserted { result.append(repo) }
        }
        return result
    }

    /// The newest run of each workflow in a list that is newest first, by workflow id.
    static func latestPerWorkflow(_ runs: [WorkflowRun]) -> [Int: WorkflowRun] {
        var result: [Int: WorkflowRun] = [:]
        for run in runs where result[run.workflowID] == nil { result[run.workflowID] = run }
        return result
    }

    /// The repositories on the page's tab bar after opening `repo`: a tab that is there keeps its place, as tabs do;
    /// a new one goes first, and the last one falls off past `limit`.
    static func recent(opening repo: String, in list: [String], limit: Int = 8) -> [String] {
        if list.contains(where: { $0.caseInsensitiveCompare(repo) == .orderedSame }) { return list }
        return Array(([repo] + list).prefix(limit))
    }

    /// The repositories that match what you type in the picker: those whose name starts with it first, then those
    /// that contain it anywhere, each keeping its place. All of them for an empty search.
    static func matching(_ query: String, in repos: [String]) -> [String] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return repos }
        let hits = repos.filter { $0.lowercased().contains(text) }
        let named = hits.filter { repo in
            let lower = repo.lowercased()
            return lower.hasPrefix(text) || lower.split(separator: "/").last.map { $0.hasPrefix(text) } == true
        }
        return named + hits.filter { !named.contains($0) }
    }

    /// "owner/repo", as typed or pasted: also a github.com link to it or to a page in it. Nil for anything else.
    static func repository(from text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        if value.hasPrefix("github.com/") { value.removeFirst("github.com/".count) }
        let parts = value.split(separator: "/").prefix(2).map(String.init)
        guard parts.count == 2 else { return nil }
        let repo = parts[0] + "/" + (parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1])
        return isRepository(repo) ? repo : nil
    }

    static func isRepository(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy(allowed.contains)
        }
    }

    /// The day a run belongs to in the list, as the start of that day.
    static func day(of run: WorkflowRun, calendar: Calendar = .current) -> Date? {
        (run.created ?? run.started).map { calendar.startOfDay(for: $0) }
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func login(_ value: Any?) -> String? {
        (value as? [String: Any])?["login"] as? String
    }
}

/// One list as the Actions page read it: its workflows and runs, and when. Kept on disk for the tabs' repositories, so
/// the page opens with runs after a restart instead of a skeleton; the read that follows replaces them within a second.
struct ActionsSnapshot: Codable, Equatable, Sendable {
    var read: Date
    var workflows: [Workflow]
    var runs: [WorkflowRun]

    /// The lists by "owner/repo|workflow" (empty workflow for all of them); none when the file is missing or unreadable.
    static func load(from url: URL) -> [String: ActionsSnapshot] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: ActionsSnapshot].self, from: data)) ?? [:]
    }

    static func save(_ lists: [String: ActionsSnapshot], to url: URL) {
        guard let data = try? JSONEncoder().encode(lists) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
