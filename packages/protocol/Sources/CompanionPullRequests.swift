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
