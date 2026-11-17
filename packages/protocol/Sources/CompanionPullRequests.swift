import Foundation

// Pull requests on the phone (docs/COMPANION.md, "Pull requests"): the ones linked to a session and the ones the Mac lists
// under Agents › Pull requests, one pull request in full (summary, checks, files with their patches), and what the phone
// may do to it through the Mac (review with comments on lines, mark files viewed, merge, work on it in a new session).
// The Mac reads the forge with its own accounts and keeps the same rules as its own pull request page; the phone never
// holds a forge token. Foundation only, so it is tested on its own.

/// One pull request in a list on the phone.
struct PullDigest: Codable, Equatable, Identifiable, Sendable {
    /// The pull request's web address: what the Mac reads and acts on it by.
    var url: String
    /// "owner/repo".
    var repo: String
    var number: Int
    var title: String
    var author: String
    /// open, draft, merged or closed.
    var state: String
    /// The checks together: passing, failing, pending or unknown.
    var ci: String
    /// What the reviews decided: none, required, approved or changesRequested.
    var review: String
    var conflict: Bool
    var additions: Int?
    var deletions: Int?
    /// When it last changed (seconds since 1970).
    var updated: Double?
    /// Where it comes from: mine, review, watched (Agents › Pull requests on the Mac) or linked (a session's).
    var group: String
    var headBranch: String?
    var baseBranch: String?
    /// The row as the Mac's shows it (`CompanionFeature.pullActions`); nil from an older Mac. Its labels with their colors
    /// (six hex digits), when it was opened (seconds since 1970), how many comments it has, and its checks that passed
    /// of how many ("28/30").
    var labels: [String]? = nil
    var labelColors: [String: String]? = nil
    var created: Double? = nil
    var comments: Int? = nil
    var checksPassed: Int? = nil
    var checksTotal: Int? = nil

    var id: String { url }

    enum Group: String, CaseIterable, Sendable { case linked, mine, review, watched }

    var isOpen: Bool { state == "open" || state == "draft" }

    /// The most a list answer carries; the open ones and the newest go first.
    static let maxList = 80

    /// What a list answer keeps: open before closed, then the newest, at most `maxList`, each url once (the first group
    /// that lists it wins, so a pull request that is both yours and linked shows once).
    static func trimmed(_ pulls: [PullDigest], limit: Int = maxList) -> [PullDigest] {
        var seen = Set<String>()
        let unique = pulls.filter { seen.insert($0.url.lowercased()).inserted }
        let order = unique.enumerated().sorted { a, b in
            if a.element.isOpen != b.element.isOpen { return a.element.isOpen }
            let left = a.element.updated ?? 0, right = b.element.updated ?? 0
            return left != right ? left > right : a.offset < b.offset
        }
        return order.prefix(limit).map(\.element)
    }
}

/// One pull request in full, as the phone's detail shows it.
struct PullDetailDigest: Codable, Equatable, Sendable {
    struct Check: Codable, Equatable, Identifiable, Sendable {
        var name: String
        /// passing, failing, pending or skipped.
        var outcome: String
        var detail: String
        var id: String { name + "|" + detail }
    }

    struct File: Codable, Equatable, Identifiable, Sendable {
        var path: String
        /// added, removed, modified, renamed…
        var status: String
        var additions: Int
        var deletions: Int
        /// The unified diff, cut at `PullDetailDigest.maxPatch` (`truncated` then); nil for a binary or too large file.
        var patch: String?
        var truncated: Bool
        /// viewed, changed (viewed, then pushed to) or unviewed, as the Mac keeps the marks.
        var viewed: String
        var id: String { path }
    }

    struct Verdict: Codable, Equatable, Sendable {
        var author: String
        var approved: Bool
    }

    var url: String
    var repo: String
    var number: Int
    var title: String
    /// The description, cut at `maxBody`.
    var body: String
    var author: String
    var state: String
    var baseBranch: String
    var headBranch: String
    /// The head the phone saw: a merge or a review goes only at this head, so nothing pushed since lands unseen.
    var headSHA: String
    var additions: Int
    var deletions: Int
    var changedFiles: Int
    var updated: Double?
    var checks: [Check]
    var files: [File]
    var verdicts: [Verdict]
    /// The merge methods the repository allows (merge, squash, rebase), the Mac's preferred one first.
    var methods: [String]
    /// Why it cannot be merged now (`PullMergeBlocker`); nil when it can.
    var blocker: String?
    /// The forge takes approve and request changes; without it a review is a comment.
    var verdictsAllowed: Bool
    /// The forge takes comments on lines with a review.
    var lineComments: Bool
    /// When the Mac read it (seconds since 1970), so a cached copy can say how old it is.
    var fetched: Double
    // What the Mac's Summary shows beside the description, and what the phone may do now (`CompanionFeature.pullActions`);
    // all nil from an older Mac.
    /// The people and teams asked for a review who have not answered yet.
    var reviewers: [String]? = nil
    var assignees: [String]? = nil
    var labels: [String]? = nil
    var labelColors: [String: String]? = nil
    var milestone: String? = nil
    /// The issues it closes when it merges.
    var issues: [Issue]? = nil
    /// Set while the forge merges it by itself once the checks and reviews allow it.
    var autoMerge: AutoMerge? = nil
    /// The branch is behind its base (GitHub's merge state "behind").
    var behind: Bool? = nil
    /// The head branch is gone (deleted after the merge).
    var branchDeleted: Bool? = nil
    /// When it was opened (seconds since 1970).
    var created: Double? = nil
    /// `CompanionPullAction.Kind` raw values the Mac takes for this pull request now, beyond reviews, viewed marks and
    /// the merge (`PullActionRules.allowed`). The phone offers only these.
    var actions: [String]? = nil
    /// The conversation: comments and reviews with words, oldest first, at most `maxNotes`.
    var conversation: [Note]? = nil
    /// The threads on lines of the diff, oldest first, at most `maxThreads`.
    var threads: [Thread]? = nil

    struct Issue: Codable, Equatable, Identifiable, Sendable {
        var repo: String
        var number: Int
        var title: String
        var open: Bool
        var url: String?
        var id: String { "\(repo)#\(number)" }
    }

    struct AutoMerge: Codable, Equatable, Sendable {
        /// merge, squash or rebase; nil when the forge does not say.
        var method: String?
        var by: String
    }

    /// A comment in the conversation, or a review with words (`verdict`: APPROVED, CHANGES_REQUESTED, COMMENTED).
    struct Note: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var author: String
        var body: String
        var date: Double?
        var verdict: String?
    }

    /// A thread on a line: where it is, whether it was resolved, and its comments, the first one opening it.
    struct Thread: Codable, Equatable, Identifiable, Sendable {
        /// The id of the comment that opened it, which `reply`, `resolve` and `unresolve` name (`CompanionPullAction.thread`).
        var id: String
        var path: String
        var line: Int?
        var resolved: Bool
        /// A later push changed the line, so it no longer points at the code as it is.
        var outdated: Bool
        /// The forge takes a reply on it, and resolving it.
        var canReply: Bool
        var canResolve: Bool
        var comments: [Note]
    }

    static let maxNotes = 100
    static let maxThreads = 60
    static let maxNoteBody = 4_000

    static let maxBody = 8_000
    static let maxPatch = 40 * 1024
    static let maxPatches = 150 * 1024
    static let maxFiles = 300
    static let maxChecks = 100

    /// Files with their patches cut to fit one answer: each at `maxPatch`, together at `maxPatches`. A file past the
    /// budget keeps its counts without a patch, and says it was cut.
    static func budgeted(_ files: [File], each: Int = maxPatch, total: Int = maxPatches) -> [File] {
        var used = 0
        return files.prefix(maxFiles).map { file in
            var file = file
            guard let patch = file.patch else { return file }
            var cut = patch
            if cut.utf8.count > each {
                cut = String(decoding: Array(cut.utf8.prefix(each)), as: UTF8.self)
                // Whole lines only: a half line would read as a change that is not there.
                if let end = cut.lastIndex(of: "\n") { cut = String(cut[..<end]) }
                file.truncated = true
            }
            if used + cut.utf8.count > total {
                file.patch = nil
                file.truncated = true
                return file
            }
            used += cut.utf8.count
            file.patch = cut
            return file
        }
    }
}

/// Why a pull request cannot be merged from the phone: the same reasons as the Mac's quick merge, in this order.
enum PullMergeBlocker: String, Codable, CaseIterable, Sendable {
    case merged, closed, draft, access, conflict, checks
}

/// What the phone asks the Mac to do to a pull request (`CompanionOp.pullAct`).
struct CompanionPullAction: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// A review: approve, request changes or comment, with comments on lines (`comments`).
        case approve, requestChanges, comment
        case merge
        /// Marks one file (`path`) as viewed or not, on the Mac.
        case viewed, unviewed
        // What the Mac's action menu does (`CompanionFeature.pullActions`), only the ones `PullDetailDigest.actions` lists.
        case close, reopen
        /// A draft ready for review, and back to a draft.
        case ready, draft
        /// Auto-merge on (with `method`, or the Mac's preferred one) or off.
        case autoMergeOn, autoMergeOff
        /// The base merged into the branch, or the branch rebased on it, only at `head`.
        case updateBranch, rebaseBranch
        /// The failed jobs of the failing checks' workflow runs, run again.
        case rerunFailed
        /// The head branch deleted, after a merge or a close.
        case deleteBranch
        /// A comment in the conversation (`body`).
        case note
        /// An answer on a thread on a line (`thread`, `body`), and the thread resolved or opened again (`thread`).
        case reply, resolve, unresolve

        /// The ones that cannot be taken back from the phone, which ask first.
        var isDestructive: Bool { [.close, .deleteBranch, .merge].contains(self) }
    }

    /// A comment on a line of a review: GitHub's `side` (RIGHT for the new file, LEFT for a removed line), and
    /// `startLine` for a comment on several lines.
    struct LineComment: Codable, Equatable, Sendable {
        var path: String
        var line: Int
        var side: String
        var body: String
        var startLine: Int?
    }

    var kind: Kind
    var body: String?
    var comments: [LineComment]?
    /// merge, squash or rebase; nil takes the Mac's preferred method.
    var method: String?
    var path: String?
    /// The head the phone saw; the Mac refuses to merge or review a pull request that moved on.
    var head: String?
    /// The thread of `reply`, `resolve` and `unresolve` (`PullDetailDigest.Thread.id`).
    var thread: String? = nil

    static let maxComments = 50
    static let maxBody = 8_000

    /// Whether the action is complete enough to go: words for a request for changes or a comment (without line
    /// comments), a path for the viewed marks, a head for a merge, and comments that are on a line and not empty.
    var isValid: Bool {
        let words = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if words.count > Self.maxBody { return false }
        let notes = comments ?? []
        if notes.count > Self.maxComments { return false }
        for note in notes {
            let text = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !note.path.isEmpty, note.line > 0, !text.isEmpty, text.count <= Self.maxBody,
                  note.side == "RIGHT" || note.side == "LEFT" else { return false }
            if let start = note.startLine, start <= 0 || start > note.line { return false }
        }
        switch kind {
        case .approve: return true
        case .requestChanges: return !words.isEmpty
        case .comment: return !words.isEmpty || !notes.isEmpty
        case .merge:
            guard let head, !head.isEmpty else { return false }
            return method.map { ["merge", "squash", "rebase"].contains($0) } ?? true
        case .viewed, .unviewed: return !(path ?? "").isEmpty
        case .close, .reopen, .ready, .draft, .autoMergeOff, .rerunFailed, .deleteBranch: return true
        case .autoMergeOn: return method.map { ["merge", "squash", "rebase"].contains($0) } ?? true
        case .updateBranch, .rebaseBranch: return !(head ?? "").isEmpty
        case .note: return !words.isEmpty
        case .reply: return !(thread ?? "").isEmpty && !words.isEmpty
        case .resolve, .unresolve: return !(thread ?? "").isEmpty
        }
    }

    /// A review's words: the one written, else a word for the forge that wants some with comments on lines.
    var reviewBody: String {
        (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A new session on a pull request (`CompanionOp.pullWork`): the agent, the model and the first message; the Mac checks
/// the pull request's branch out in a worktree of its own in the folder where it has that repository.
struct PullWorkRequest: Codable, Equatable, Sendable {
    var url: String
    var agent: String
    var task: String
    var model: String?
}

/// What the phone keeps of pull requests, per Mac, so they read without a connection (`companion-pulls-<id>.json`): the
/// last lists and the last pull requests opened. Nothing in it can act: every action needs the Mac.
struct PullCache: Codable, Equatable, Sendable {
    struct Detail: Codable, Equatable, Sendable {
        var detail: PullDetailDigest
        var at: Double
    }

    /// The list of Agents › Pull requests, and when the Mac answered it.
    var list: [PullDigest] = []
    var listAt: Double?
    /// Each session's linked pull requests, by session id.
    var linked: [String: [PullDigest]] = [:]
    /// The pull requests opened most recently, by url.
    var details: [String: Detail] = [:]

    static let maxDetails = 10
    static let maxLinkedSessions = 20

    mutating func record(list: [PullDigest], at date: Date) {
        guard date.timeIntervalSince1970 >= (listAt ?? 0) else { return }
        self.list = list
        listAt = date.timeIntervalSince1970
    }

    mutating func record(linked pulls: [PullDigest], session: String) {
        linked[session] = pulls
        if linked.count > Self.maxLinkedSessions, let drop = linked.keys.sorted().first(where: { $0 != session }) {
            linked[drop] = nil
        }
    }

    /// Keeps the newest `maxDetails`; an older read never replaces a newer one.
    mutating func record(_ detail: PullDetailDigest, at date: Date) {
        let key = detail.url.lowercased()
        if let kept = details[key], kept.at > date.timeIntervalSince1970 { return }
        details[key] = Detail(detail: detail, at: date.timeIntervalSince1970)
        guard details.count > Self.maxDetails else { return }
        let oldest = details.sorted { $0.value.at < $1.value.at }.prefix(details.count - Self.maxDetails).map(\.key)
        for key in oldest { details[key] = nil }
    }

    func detail(_ url: String) -> Detail? { details[url.lowercased()] }
}

/// Which of the Mac's actions one pull request takes now, by the same rules as its action menu
/// (`PullRequestActionPanel`): the phone offers only what this lists (`PullDetailDigest.actions`).
enum PullActionRules {
    /// What the Mac knows of the pull request that decides it.
    struct Facts: Equatable, Sendable {
        /// open, draft, merged or closed.
        var state: String
        /// The forge's node id is known (GitHub's GraphQL actions need it).
        var hasNodeID = true
        var canPush: Bool? = nil
        var conflicted = false
        var behind = false
        var autoMergeOn = false
        var autoMergeAllowed = false
        var hasHeadRepository = true
        var branchDeleted = false
        /// Failing checks that belong to a workflow run the forge can run again.
        var failedRuns = 0
        /// The forge's features (`PullRequestForgeFeatures`).
        var draft = true
        var autoMerge = true
        var updateBranch = true
        var deleteBranch = true
        var threads = true
        var rerun = true
    }

    static func allowed(_ facts: Facts) -> [CompanionPullAction.Kind] {
        var kinds: [CompanionPullAction.Kind] = []
        let open = facts.state == "open" || facts.state == "draft"
        if open {
            kinds.append(.note)
            if facts.draft, facts.hasNodeID { kinds.append(facts.state == "draft" ? .ready : .draft) }
            if facts.behind, facts.updateBranch {
                kinds.append(.updateBranch)
                if facts.hasNodeID { kinds.append(.rebaseBranch) }
            }
            if facts.autoMerge, facts.hasNodeID {
                if facts.autoMergeOn {
                    kinds.append(.autoMergeOff)
                } else if facts.autoMergeAllowed, facts.state == "open", facts.canPush != false, !facts.conflicted {
                    kinds.append(.autoMergeOn)
                }
            }
            if facts.rerun, facts.failedRuns > 0, facts.canPush != false { kinds.append(.rerunFailed) }
            kinds.append(.close)
        } else {
            kinds.append(.note)
            if facts.state == "closed" { kinds.append(.reopen) }
            if facts.canPush != false, facts.hasHeadRepository, !facts.branchDeleted, facts.deleteBranch { kinds.append(.deleteBranch) }
        }
        if facts.threads { kinds += [.reply, .resolve, .unresolve] }
        return kinds
    }
}

/// The phone's pull request list as the Mac's Agents › Pull requests: the chips over it (`Attention`), the search with
/// its qualifiers (`Query`), the state, the order (`Sort`) and the grouping (`Grouping`). Foundation only, so it is tested
/// on its own; the iPhone and the Tauri companion follow the same rules.
enum PullList {
    /// The chips with a count: reviews asked of you, your own with failing checks, your own ready to merge.
    enum Attention: String, CaseIterable, Sendable {
        case review, failing, ready

        func includes(_ pull: PullDigest) -> Bool {
            guard pull.isOpen else { return false }
            switch self {
            case .review: return pull.group == PullDigest.Group.review.rawValue
            case .failing: return pull.group == PullDigest.Group.mine.rawValue && pull.ci == "failing"
            case .ready: return pull.group == PullDigest.Group.mine.rawValue && PullList.isReadyToMerge(pull)
            }
        }

        static func counts(_ pulls: [PullDigest]) -> [Attention: Int] {
            var counts: [Attention: Int] = [:]
            for attention in allCases { counts[attention] = pulls.count(where: attention.includes) }
            return counts
        }
    }

    /// The State filter: open (drafts too) by default, closed, merged, or all.
    enum State: String, CaseIterable, Sendable {
        case open, closed, merged, all

        func includes(_ pull: PullDigest) -> Bool {
            switch self {
            case .open: return pull.isOpen
            case .closed: return pull.state == "closed"
            case .merged: return pull.state == "merged"
            case .all: return true
            }
        }
    }

    /// The Mac's orders (`PullRequestSort`).
    enum Sort: String, CaseIterable, Sendable {
        case attention, readiness, blockedOnMe, recent, oldest, largest, smallest
    }

    /// The Mac's groupings (`PullRequestGrouping`): why it is in the list, or by repository.
    enum Grouping: String, CaseIterable, Sendable {
        case involvement, repository
    }

    /// The search, as the Mac reads it (`PullRequestQuery`): words over the title, repository, number, author and branch,
    /// and `label:` (`label:a,b` for either, `-label:` to leave out), `author:`, `repo:` (`-repo:`), `branch:` (or
    /// `head:`), `draft:true|false`, `review:approved|changes|required|none` and `checks:passing|failing|pending`.
    struct Query: Equatable, Sendable {
        var words: [String] = []
        var labels: [[String]] = []
        var excludedLabels: [String] = []
        var author: String?
        var repo: String?
        var excludedRepos: [String] = []
        var branch: String?
        var draft: Bool?
        var review: String?
        var checks: String?

        static func parse(_ raw: String) -> Query {
            var query = Query()
            for token in raw.split(whereSeparator: \.isWhitespace).map(String.init) {
                let negated = token.hasPrefix("-")
                let body = negated ? String(token.dropFirst()) : token
                guard let colon = body.firstIndex(of: ":"), colon != body.startIndex else {
                    query.words.append(token.lowercased())
                    continue
                }
                let key = body[..<colon].lowercased()
                let value = String(body[body.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                guard !value.isEmpty else { query.words.append(token.lowercased()); continue }
                let lower = value.lowercased()
                switch key {
                case "label":
                    let names = lower.split(separator: ",").map(String.init).filter { !$0.isEmpty }
                    if negated { query.excludedLabels += names } else { query.labels.append(names) }
                case "author" where !negated:
                    query.author = lower.hasPrefix("@") ? String(lower.dropFirst()) : lower
                case "repo":
                    if negated { query.excludedRepos.append(lower) } else { query.repo = lower }
                case "branch" where !negated, "head" where !negated:
                    query.branch = lower
                case "draft" where lower == "true" || lower == "false":
                    query.draft = (lower == "true") != negated
                case "review" where !negated:
                    switch lower {
                    case "approved": query.review = "approved"
                    case "changes", "changes-requested", "changes_requested": query.review = "changesRequested"
                    case "required", "review-required": query.review = "required"
                    case "none": query.review = "none"
                    default: query.words.append(token.lowercased())
                    }
                case "checks" where !negated, "status" where !negated:
                    switch lower {
                    case "passing", "success": query.checks = "passing"
                    case "failing", "failure": query.checks = "failing"
                    case "pending", "running": query.checks = "pending"
                    default: query.words.append(token.lowercased())
                    }
                default:
                    // A scoped label written bare ("area:ui") is a label, as on the Mac.
                    let label = body.lowercased()
                    if negated { query.excludedLabels.append(label) } else { query.labels.append([label]) }
                }
            }
            return query
        }

        var isEmpty: Bool { self == Query() }

        func matches(_ pull: PullDigest) -> Bool {
            if let author, pull.author.lowercased() != author { return false }
            if let repo, pull.repo.lowercased() != repo { return false }
            if excludedRepos.contains(pull.repo.lowercased()) { return false }
            if let branch, !(pull.headBranch ?? "").lowercased().contains(branch) { return false }
            if let draft, (pull.state == "draft") != draft { return false }
            if let review, pull.review != review { return false }
            if let checks, pull.ci != checks { return false }
            let held = Set((pull.labels ?? []).map { $0.lowercased() })
            if !labels.allSatisfy({ group in group.contains(where: held.contains) }) { return false }
            if excludedLabels.contains(where: held.contains) { return false }
            guard !words.isEmpty else { return true }
            let text = "\(pull.repo)#\(pull.number) \(pull.title) @\(pull.author) \(pull.headBranch ?? "")".lowercased()
            return words.allSatisfy { word in
                let digits = word.hasPrefix("#") ? String(word.dropFirst()) : word
                if !digits.isEmpty, digits.allSatisfy(\.isNumber), let number = Int(digits) {
                    return pull.number == number || (!word.hasPrefix("#") && text.contains(word))
                }
                return text.contains(word)
            }
        }
    }

    /// One heading of the list and its rows.
    struct Section: Equatable, Identifiable, Sendable {
        /// A `PullDigest.Group` raw value, or "owner/repo" when grouped by repository.
        var key: String
        var pulls: [PullDigest]
        var id: String { key }
    }

    /// Open, out of draft, approved, with passing checks and no conflict: nothing stands between it and its merge.
    static func isReadyToMerge(_ pull: PullDigest) -> Bool {
        pull.state == "open" && !pull.conflict && pull.ci == "passing" && pull.review == "approved"
    }

    static func size(_ pull: PullDigest) -> Int { (pull.additions ?? 0) + (pull.deletions ?? 0) }

    /// The Mac's role ranks (`PullRequestRepoGroup.Row`): how much it needs you, how near its merge, what blocks it on you.
    static func urgency(_ pull: PullDigest) -> Int {
        guard pull.isOpen else { return 3 }
        if pull.group == PullDigest.Group.review.rawValue { return 0 }
        return pull.group == PullDigest.Group.mine.rawValue && pull.ci == "failing" ? 1 : 2
    }

    static func readiness(_ pull: PullDigest) -> Int {
        guard pull.isOpen else { return 4 }
        if pull.conflict { return 3 }
        if pull.state == "draft" { return 2 }
        if pull.ci == "passing" { return pull.review == "approved" ? 0 : 1 }
        return 2
    }

    static func blockedOnMe(_ pull: PullDigest) -> Int {
        guard pull.isOpen else { return 9 }
        switch PullDigest.Group(rawValue: pull.group) {
        case .review?: return 0
        case .mine?:
            if pull.conflict { return 1 }
            if pull.review == "changesRequested" { return 2 }
            if pull.ci == "failing" { return 3 }
            if pull.state == "draft" { return 4 }
            if pull.ci == "passing" && pull.review == "approved" { return 6 }
            return 5
        default: return 8
        }
    }

    /// The rows in `sort` order; rows that tie keep their order.
    static func sorted(_ pulls: [PullDigest], by sort: Sort) -> [PullDigest] {
        func key(_ pull: PullDigest) -> (Int, Double, Double) {
            let updated = pull.updated ?? 0
            let open = pull.isOpen ? 0 : 1
            let size = Double(size(pull))
            switch sort {
            case .attention: return (urgency(pull), -updated, 0)
            case .readiness: return (readiness(pull), size, -updated)
            case .blockedOnMe: return (blockedOnMe(pull), -updated, 0)
            case .recent: return (open, -updated, 0)
            case .oldest: return (open, updated, 0)
            case .largest: return (open, -size, -updated)
            case .smallest: return (open, size, -updated)
            }
        }
        return pulls.enumerated().sorted { a, b in
            let (left, right) = (key(a.element), key(b.element))
            return left == right ? a.offset < b.offset : left < right
        }.map(\.element)
    }

    /// What the list shows: the state, the search and a chip applied, sorted, in sections. By involvement the sections
    /// are for your review, yours, watched and linked, in that order; by repository each repository follows its first row.
    static func sections(_ pulls: [PullDigest], query: String = "", state: State = .open, attention: Attention? = nil,
                         sort: Sort = .attention, grouping: Grouping = .involvement) -> [Section] {
        let parsed = Query.parse(query)
        let kept = sorted(pulls.filter { state.includes($0) && parsed.matches($0) && (attention?.includes($0) ?? true) }, by: sort)
        switch grouping {
        case .involvement:
            let order: [PullDigest.Group] = [.review, .mine, .watched, .linked]
            return order.compactMap { group in
                let rows = kept.filter { $0.group == group.rawValue }
                return rows.isEmpty ? nil : Section(key: group.rawValue, pulls: rows)
            }
        case .repository:
            var sections: [Section] = []
            var index: [String: Int] = [:]
            for pull in kept {
                let key = pull.repo.lowercased()
                if let at = index[key] { sections[at].pulls.append(pull) } else {
                    index[key] = sections.count
                    sections.append(Section(key: pull.repo, pulls: [pull]))
                }
            }
            return sections
        }
    }

    /// The pull requests the chips count: the state and search applied, not the chip itself, as on the Mac.
    static func counted(_ pulls: [PullDigest], query: String = "", state: State = .open) -> [Attention: Int] {
        let parsed = Query.parse(query)
        return Attention.counts(pulls.filter { state.includes($0) && parsed.matches($0) })
    }
}
