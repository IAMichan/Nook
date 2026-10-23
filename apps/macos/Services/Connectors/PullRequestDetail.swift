import Foundation

/// Everything about one GitHub pull request that the detail view under Agents › Pull requests shows: the description,
/// the checks of its latest commit, the conversation (reviews, comments and line comments), the commits and the changed
/// files with their diff. Parsed from the REST answers by `PullRequestDetailParser`; Foundation only, so tests can use it.
struct PullRequestDetail: Equatable, Sendable {
    enum State: String, Equatable, Sendable { case open, draft, merged, closed }

    let repo: String
    let number: Int
    let title: String
    let body: String
    let url: URL?
    let author: String
    /// Variable so the view can show a merge it just made at once, before GitHub's next answer.
    var state: State
    let baseBranch: String
    let headBranch: String
    /// The commit the view shows. A merge is sent with it, so GitHub refuses when someone pushed in the meantime.
    let headSHA: String
    let additions: Int
    let deletions: Int
    let changedFiles: Int
    let created: Date?
    let updated: Date?
    /// GitHub computes this lazily: nil while it is still working it out.
    let mergeable: Bool?
    /// GitHub's `mergeable_state`: clean, unstable, blocked, behind, dirty, draft, has_hooks or unknown.
    let mergeState: String
    var checks: [PullRequestCheck] = []
    var events: [PullRequestEvent] = []
    var commits: [PullRequestCommit] = []
    var files: [PullRequestFile] = []
    /// The merge methods the repository allows, in GitHub's order.
    var methods: [PullRequestMergeMethod] = PullRequestMergeMethod.allCases
    /// Whether the account may push to the repository, and so merge. Nil when GitHub did not say.
    var canPush: Bool? = nil
    /// The people and teams asked for a review who have not answered yet, as GitHub lists them.
    var requestedReviewers: [String] = []
    var labels: [String] = []
    /// Each label's color as six hex digits, as the list's rows have them.
    var labelColors: [String: String] = [:]
    /// GitHub's node id, for the actions only GraphQL offers (marking a draft ready for review).
    var nodeID = ""
    /// GitHub's own counts, so the lists can be read page by page at once and a tab can say how many before they load.
    var commitCount: Int? = nil
    var commentCount: Int? = nil
    var lineCommentCount: Int? = nil
    /// False until the timeline, commits and files have arrived: the summary shows first, the rest follows.
    var activityLoaded = true

    var id: String { "\(repo)#\(number)" }
    var isOpen: Bool { state == .open || state == .draft }

    /// The timeline, commits and files of a later read, on top of this summary.
    mutating func apply(_ activity: PullRequestActivity) {
        events = activity.events
        commits = activity.commits
        files = activity.files
        activityLoaded = true
    }

    /// The activity a fresh summary keeps from the read before it, until its own activity arrives.
    func keepingActivity(of old: PullRequestDetail?) -> PullRequestDetail {
        guard !activityLoaded, let old, old.activityLoaded else { return self }
        var result = self
        result.apply(PullRequestActivity(events: old.events, commits: old.commits, files: old.files))
        return result
    }

    /// Each reviewer's last say: approved or changes requested, newest first. A plain comment does not change it, a
    /// dismissal clears it.
    var verdicts: [PullRequestVerdict] {
        var latest: [String: PullRequestVerdict] = [:]
        for event in events {
            guard case .review(let state) = event.kind else { continue }
            switch state {
            case "APPROVED": latest[event.author] = PullRequestVerdict(author: event.author, approved: true, date: event.date)
            case "CHANGES_REQUESTED": latest[event.author] = PullRequestVerdict(author: event.author, approved: false, date: event.date)
            case "DISMISSED": latest[event.author] = nil
            default: break
            }
        }
        return latest.values.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// The checks counted by outcome, for the summary line ("2 failing · 1 running · 14 passed").
    var checkCounts: (failing: Int, pending: Int, passing: Int, skipped: Int) {
        checks.reduce(into: (0, 0, 0, 0)) { counts, check in
            switch check.outcome {
            case .failing: counts.0 += 1
            case .pending: counts.1 += 1
            case .passing: counts.2 += 1
            case .skipped: counts.3 += 1
            }
        }
    }
    var conflicted: Bool { mergeable == false || mergeState == "dirty" }

    /// Whether the merge button can be pressed. GitHub has the last word (branch protection, an admin bypass), so only
    /// what certainly fails is held back here.
    var canMerge: Bool { state == .open && !conflicted && canPush != false && !methods.isEmpty }

    /// The checks together: failing as soon as one fails, pending while one still runs.
    var checkSummary: PullRequestItem.CI {
        if checks.isEmpty { return .unknown }
        if checks.contains(where: { $0.outcome == .failing }) { return .failing }
        if checks.contains(where: { $0.outcome == .pending }) { return .pending }
        return .passing
    }

    /// Why the pull request cannot be merged right now, or what GitHub warns about: a key for `tr`, nil when all is well.
    var mergeNote: String? {
        switch state {
        case .merged: return "agents.pr.note.merged"
        case .closed: return "agents.pr.note.closed"
        case .draft: return "agents.pr.note.draft"
        case .open: break
        }
        if canPush == false { return "agents.pr.note.noAccess" }
        if conflicted { return "agents.pr.note.conflict" }
        switch mergeState {
        case "blocked": return "agents.pr.note.blocked"
        case "behind": return "agents.pr.note.behind"
        case "unstable": return "agents.pr.note.unstable"
        default: break
        }
        if mergeable == nil { return "agents.pr.note.checking" }
        return checkSummary == .failing ? "agents.pr.note.unstable" : nil
    }
}

/// The part of a pull request that takes the most requests to read: the timeline, the commits and the files.
struct PullRequestActivity: Equatable, Sendable {
    var events: [PullRequestEvent] = []
    var commits: [PullRequestCommit] = []
    var files: [PullRequestFile] = []
}

/// One entry on the timeline page: an event, or the commits one person added one after the other, shown as one.
enum PullRequestTimelineEntry: Identifiable, Equatable, Sendable {
    case event(PullRequestEvent)
    case commits([PullRequestEvent])

    var id: String {
        switch self {
        case .event(let event): return event.id
        case .commits(let run): return "commits-" + (run.first?.id ?? "")
        }
    }

    static func entries(_ events: [PullRequestEvent]) -> [PullRequestTimelineEntry] {
        var result: [PullRequestTimelineEntry] = []
        for event in events {
            guard case .commit = event.kind else {
                result.append(.event(event))
                continue
            }
            if case .commits(var run)? = result.last, run.last?.author == event.author {
                run.append(event)
                result[result.count - 1] = .commits(run)
            } else {
                result.append(.commits([event]))
            }
        }
        return result
    }
}

/// One reviewer's standing verdict on the pull request.
struct PullRequestVerdict: Equatable, Sendable {
    let author: String
    let approved: Bool
    let date: Date?
}

/// One check or commit status on the latest commit.
struct PullRequestCheck: Identifiable, Equatable, Sendable {
    enum Outcome: String, Equatable, Sendable { case passing, failing, pending, skipped }

    let name: String
    let outcome: Outcome
    /// The conclusion or state GitHub gave ("success", "failure", "in_progress"…), shown under the name.
    let detail: String
    let url: URL?

    var id: String { name + "|" + (url?.absoluteString ?? "") }
}

/// One entry in the timeline: a review, a comment, a comment on a line of the diff, a commit, or something that
/// happened to the pull request (a label, a review request, a force-push, the merge…).
struct PullRequestEvent: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case comment
        /// APPROVED, CHANGES_REQUESTED, COMMENTED or DISMISSED.
        case review(String)
        case lineComment(path: String, line: Int?)
        /// A commit on the branch; the body is its subject.
        case commit(sha: String)
        /// One of `PullRequestDetailParser.activityTypes` ("labeled", "merged"…) with what it is about: a label, a
        /// login, the new title, a short sha or a reference. Shown as one line: "@actor added the label bug".
        case activity(type: String, detail: String)
    }

    let id: String
    let kind: Kind
    let author: String
    let body: String
    let date: Date?
    let url: URL?
}

struct PullRequestCommit: Identifiable, Equatable, Sendable {
    let sha: String
    let message: String
    let author: String
    let date: Date?

    var id: String { sha }
    var shortSHA: String { String(sha.prefix(7)) }
    var subject: String { message.components(separatedBy: "\n").first ?? message }
}

struct PullRequestFile: Identifiable, Equatable, Sendable {
    let path: String
    /// added, removed, modified, renamed, copied, changed or unchanged.
    let status: String
    let additions: Int
    let deletions: Int
    /// The unified diff. Nil for binary files and for diffs GitHub leaves out because they are too large.
    let patch: String?
    let previousPath: String?
    /// The file's blob at the pull request's head (GitHub's `sha`): "" once the file is removed, nil when the host did not
    /// say. A "viewed" mark remembers it, so the mark lapses when a push changes the file (`PullRequestViewedFiles`).
    var revision: String? = nil

    var id: String { path }
}

enum PullRequestMergeMethod: String, CaseIterable, Identifiable, Sendable {
    case merge, squash, rebase

    var id: String { rawValue }
    /// The `tr` key of its name in the menu.
    var titleKey: String { "agents.pr.method." + rawValue }
}

/// Turns GitHub's REST answers into a `PullRequestDetail`, and builds the merge request.
enum PullRequestDetailParser {
    static func detail(pull: [String: Any], repository: [String: Any]? = nil) -> PullRequestDetail? {
        guard let number = int(pull["number"]) else { return nil }
        let base = pull["base"] as? [String: Any] ?? [:]
        let head = pull["head"] as? [String: Any] ?? [:]
        let repo = ((base["repo"] as? [String: Any])?["full_name"] as? String) ?? (repository?["full_name"] as? String) ?? ""
        let merged = (pull["merged"] as? Bool) == true || pull["merged_at"] is String
        let state: PullRequestDetail.State = merged ? .merged
            : (pull["state"] as? String) != "open" ? .closed
            : (pull["draft"] as? Bool) == true ? .draft : .open
        var detail = PullRequestDetail(
            repo: repo, number: number, title: (pull["title"] as? String) ?? "Untitled",
            body: GitHubMarkdown.markdown((pull["body"] as? String) ?? ""),
            url: (pull["html_url"] as? String).flatMap(URL.init(string:)), author: login(pull["user"]), state: state,
            baseBranch: (base["ref"] as? String) ?? "", headBranch: (head["ref"] as? String) ?? "",
            headSHA: (head["sha"] as? String) ?? "", additions: int(pull["additions"]) ?? 0, deletions: int(pull["deletions"]) ?? 0,
            changedFiles: int(pull["changed_files"]) ?? 0, created: date(pull["created_at"]), updated: date(pull["updated_at"]),
            mergeable: pull["mergeable"] as? Bool, mergeState: ((pull["mergeable_state"] as? String) ?? "unknown").lowercased())
        detail.requestedReviewers = ((pull["requested_reviewers"] as? [[String: Any]]) ?? []).compactMap { $0["login"] as? String }
            + ((pull["requested_teams"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        detail.labels = ((pull["labels"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        detail.labelColors = PullRequestGraphQL.labelColors((pull["labels"] as? [[String: Any]]) ?? [])
        detail.nodeID = (pull["node_id"] as? String) ?? ""
        detail.commitCount = int(pull["commits"])
        detail.commentCount = int(pull["comments"])
        detail.lineCommentCount = int(pull["review_comments"])
        if let repository {
            detail.methods = methods(repository)
            detail.canPush = (repository["permissions"] as? [String: Any])?["push"] as? Bool
        }
        return detail
    }

    /// The methods the repository allows. GitHub only sends the `allow_*` fields to accounts with write access; a
    /// field that is missing counts as allowed.
    static func methods(_ repository: [String: Any]) -> [PullRequestMergeMethod] {
        PullRequestMergeMethod.allCases.filter { method in
            let field: String
            switch method {
            case .merge: field = "allow_merge_commit"
            case .squash: field = "allow_squash_merge"
            case .rebase: field = "allow_rebase_merge"
            }
            return (repository[field] as? Bool) ?? true
        }
    }

    /// Check runs (GitHub Actions and apps) and the older commit statuses, in one list: failing first, then running.
    static func checks(runs: [[String: Any]], statuses: [[String: Any]]) -> [PullRequestCheck] {
        var result = runs.map { run -> PullRequestCheck in
            let status = (run["status"] as? String) ?? ""
            let conclusion = (run["conclusion"] as? String) ?? ""
            let outcome: PullRequestCheck.Outcome
            if status != "completed" { outcome = .pending }
            else if ["failure", "timed_out", "cancelled", "action_required", "startup_failure", "stale"].contains(conclusion) { outcome = .failing }
            else if ["skipped", "neutral"].contains(conclusion) { outcome = .skipped }
            else { outcome = .passing }
            return PullRequestCheck(name: (run["name"] as? String) ?? "?", outcome: outcome,
                                    detail: status == "completed" ? conclusion : status,
                                    url: ((run["html_url"] as? String) ?? (run["details_url"] as? String)).flatMap(URL.init(string:)))
        }
        // The combined status lists every context once, with its latest state.
        for status in statuses {
            let state = (status["state"] as? String) ?? ""
            let outcome: PullRequestCheck.Outcome = state == "success" ? .passing : state == "pending" ? .pending : .failing
            let description = (status["description"] as? String) ?? state
            result.append(PullRequestCheck(name: (status["context"] as? String) ?? "?", outcome: outcome,
                                           detail: description.isEmpty ? state : description,
                                           url: (status["target_url"] as? String).flatMap(URL.init(string:))))
        }
        func rank(_ check: PullRequestCheck) -> Int {
            switch check.outcome { case .failing: return 0; case .pending: return 1; case .passing: return 2; case .skipped: return 3 }
        }
        return result.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// The timeline events Nook shows, by GitHub's name. Comments, reviews and commits come from their own lists, which
    /// carry more; subscriptions and mentions say nothing about the pull request itself.
    static let activityTypes: Set<String> = [
        "labeled", "unlabeled", "assigned", "unassigned", "review_requested", "review_request_removed", "renamed",
        "head_ref_force_pushed", "head_ref_deleted", "head_ref_restored", "base_ref_changed", "merged", "closed", "reopened",
        "ready_for_review", "convert_to_draft", "cross-referenced", "referenced", "milestoned", "demilestoned",
        "auto_merge_enabled", "auto_merge_disabled", "review_dismissed",
    ]

    /// The whole history as one timeline, oldest first: reviews, comments, line comments, commits, and the events of
    /// `/issues/{number}/timeline` (labels, review requests, force-pushes, the merge…). Pending reviews (not sent yet)
    /// and empty "commented" reviews (the wrapper of line comments) are left out.
    static func events(reviews: [[String: Any]], comments: [[String: Any]], lineComments: [[String: Any]],
                       timeline: [[String: Any]] = [], commits: [PullRequestCommit] = []) -> [PullRequestEvent] {
        var result: [PullRequestEvent] = []
        for commit in commits {
            result.append(PullRequestEvent(id: "commit-" + commit.sha, kind: .commit(sha: commit.sha), author: commit.author,
                                           body: commit.subject, date: commit.date, url: nil))
        }
        for (index, item) in timeline.enumerated() {
            guard let type = item["event"] as? String, activityTypes.contains(type) else { continue }
            result.append(PullRequestEvent(id: "timeline-\(int(item["id"]).map(String.init) ?? "#\(index)")",
                                           kind: .activity(type: type, detail: activityDetail(type, item)),
                                           author: login(item["actor"]), body: "", date: date(item["created_at"]), url: nil))
        }
        for review in reviews {
            let state = ((review["state"] as? String) ?? "").uppercased()
            let body = GitHubMarkdown.markdown((review["body"] as? String) ?? "")
            guard state != "PENDING", !(state == "COMMENTED" && body.isEmpty) else { continue }
            result.append(PullRequestEvent(id: "review-\(int(review["id"]) ?? result.count)", kind: .review(state),
                                           author: login(review["user"]), body: body, date: date(review["submitted_at"]),
                                           url: (review["html_url"] as? String).flatMap(URL.init(string:))))
        }
        for comment in comments {
            result.append(PullRequestEvent(id: "comment-\(int(comment["id"]) ?? result.count)", kind: .comment,
                                           author: login(comment["user"]), body: GitHubMarkdown.markdown((comment["body"] as? String) ?? ""),
                                           date: date(comment["created_at"]),
                                           url: (comment["html_url"] as? String).flatMap(URL.init(string:))))
        }
        for comment in lineComments {
            result.append(PullRequestEvent(id: "line-\(int(comment["id"]) ?? result.count)",
                                           kind: .lineComment(path: (comment["path"] as? String) ?? "",
                                                              line: int(comment["line"]) ?? int(comment["original_line"])),
                                           author: login(comment["user"]), body: GitHubMarkdown.markdown((comment["body"] as? String) ?? ""),
                                           date: date(comment["created_at"]),
                                           url: (comment["html_url"] as? String).flatMap(URL.init(string:))))
        }
        return result.enumerated().sorted {
            ($0.element.date ?? .distantPast, $0.offset) < ($1.element.date ?? .distantPast, $1.offset)
        }.map(\.element)
    }

    /// What a timeline event is about, as shown after its sentence.
    static func activityDetail(_ type: String, _ item: [String: Any]) -> String {
        func field(_ key: String, _ name: String) -> String? { (item[key] as? [String: Any])?[name] as? String }
        switch type {
        case "labeled", "unlabeled": return field("label", "name") ?? ""
        case "assigned", "unassigned": return field("assignee", "login").map { "@" + $0 } ?? ""
        case "review_requested", "review_request_removed":
            return field("requested_reviewer", "login").map { "@" + $0 } ?? field("requested_team", "name") ?? ""
        case "renamed": return field("rename", "to") ?? ""
        case "merged", "referenced": return (item["commit_id"] as? String).map { String($0.prefix(7)) } ?? ""
        case "milestoned", "demilestoned": return field("milestone", "title") ?? ""
        case "cross-referenced":
            let issue = (item["source"] as? [String: Any])?["issue"] as? [String: Any] ?? [:]
            let repo = ((issue["repository"] as? [String: Any])?["full_name"] as? String) ?? ""
            let number = int(issue["number"]).map { "#\($0)" } ?? ""
            let title = (issue["title"] as? String).map { " " + $0 } ?? ""
            return repo + number + title
        default: return ""
        }
    }

    static func commits(_ list: [[String: Any]]) -> [PullRequestCommit] {
        list.compactMap { item in
            guard let sha = item["sha"] as? String else { return nil }
            let commit = item["commit"] as? [String: Any] ?? [:]
            let gitAuthor = commit["author"] as? [String: Any] ?? [:]
            let account = login(item["author"])
            return PullRequestCommit(sha: sha, message: (commit["message"] as? String) ?? "",
                                     author: account != "?" ? account : ((gitAuthor["name"] as? String) ?? "?"),
                                     date: date(gitAuthor["date"]))
        }
    }

    static func files(_ list: [[String: Any]]) -> [PullRequestFile] {
        list.compactMap { item in
            guard let path = item["filename"] as? String else { return nil }
            return PullRequestFile(path: path, status: (item["status"] as? String) ?? "modified", additions: int(item["additions"]) ?? 0,
                                   deletions: int(item["deletions"]) ?? 0, patch: item["patch"] as? String,
                                   previousPath: item["previous_filename"] as? String,
                                   revision: (item["status"] as? String) == "removed" ? "" : item["sha"] as? String)
        }
    }

    /// How many pages of 100 a list of `count` entries takes, at least one and at most `limit`; nil when GitHub gave
    /// no count, so the pages are read one after the other until a short one.
    static func pages(count: Int?, limit: Int) -> Int? {
        guard let count else { return nil }
        return min(limit, max(1, (count + 99) / 100))
    }

    /// The body of `PUT /repos/{repo}/pulls/{number}/merge`. With `sha`, GitHub only merges that exact head.
    static func mergeBody(method: PullRequestMergeMethod, sha: String) -> [String: Any] {
        var body: [String: Any] = ["merge_method": method.rawValue]
        if !sha.isEmpty { body["sha"] = sha }
        return body
    }

    /// GitHub's refusal of a merge, in words: its own message, with the reason for the common statuses.
    static func mergeError(status: Int, object: [String: Any]) -> String {
        let message = (object["message"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        switch status {
        case 401: return "GitHub rejected the connection (401). Reconnect in Settings › Connections."
        case 403: return "GitHub did not permit the merge (403)." + (message.isEmpty ? "" : " " + message)
        case 404: return "GitHub could not find the pull request, or this account has no access to it (404)."
        case 405: return "GitHub cannot merge this pull request (405)." + (message.isEmpty ? "" : " " + message)
        case 409: return "The branch changed since you opened it (409). Look at the new commits and try again."
        case 422: return "GitHub refused the merge (422)." + (message.isEmpty ? "" : " " + message)
        default: return message.isEmpty ? "GitHub returned an error (\(status))." : "GitHub: " + message
        }
    }

    // MARK: Helpers

    private static func login(_ user: Any?) -> String { ((user as? [String: Any])?["login"] as? String) ?? "?" }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return NookDates.isoPlain.date(from: text) ?? NookDates.isoFractional.date(from: text)
    }
}
