import Foundation

/// What a host says about merging a pull request, read along with its state.
struct PullRequestMergeFacts: Equatable, Sendable {
    /// GitHub's words, which every forge translates to: "clean", "blocked", "behind", "unstable", "dirty", "unknown".
    var state: String
    var autoMerge = false
    var baseBranch = ""
}

/// The one answer to "can this be merged?", for the badge above the composer, the hover card and the merge bar.
enum PullRequestMergeStatus: Equatable, Sendable {
    /// Open, and nothing is known about merging it.
    case open
    case ready, checking, checksRunning, checksFailing, blocked, autoMerge, conflict, draft, merged, closed
    case behind(base: String)

    init(_ glyph: PullRequestBadge.Glyph) {
        switch glyph {
        case .open, .stack: self = .open
        case .draft: self = .draft
        case .conflict: self = .conflict
        case .merged: self = .merged
        case .closed: self = .closed
        }
    }

    /// Failing and running checks go before "blocked": GitHub also blocks on required checks, and the checks are the
    /// reason worth naming then.
    init(glyph: PullRequestBadge.Glyph, checks: String?, merge: PullRequestMergeFacts?) {
        self.init(glyph)
        guard self == .open else { return }
        // The checks speak even before a read has said how merging stands: the branch sync knows only the state.
        guard let merge else {
            if checks == "failure" { self = .checksFailing } else if checks == "pending" { self = .checksRunning }
            return
        }
        if merge.autoMerge {
            self = .autoMerge
        } else if checks == "failure" || (merge.state == "unstable" && checks != "pending") {
            self = .checksFailing
        } else if checks == "pending" {
            self = .checksRunning
        } else if merge.state == "blocked" {
            self = .blocked
        } else if merge.state == "behind" {
            self = .behind(base: merge.baseBranch)
        } else if merge.state == "clean" || merge.state == "has_hooks" {
            self = .ready
        }
    }

    /// The whole reason as a key for `tr`, where the badge's word needs one.
    var noteKey: String? {
        switch self {
        case .checking: return "agents.pr.note.checking"
        case .checksRunning: return "agents.pr.note.checksRunning"
        case .checksFailing: return "agents.pr.note.unstable"
        case .blocked: return "agents.pr.note.blocked"
        case .behind: return "agents.pr.note.behind"
        case .conflict: return "agents.pr.note.conflict"
        case .draft: return "agents.pr.note.draft"
        case .open, .ready, .autoMerge, .merged, .closed: return nil
        }
    }
}

/// How one pull request looks, as the newest read anywhere in Nook said: its state, its checks and how merging stands.
struct PullRequestStatus: Equatable, Sendable {
    /// Draft, open, conflict, merged or closed (never `.stack`).
    var glyph: PullRequestBadge.Glyph
    /// "success", "failure", "pending", or empty when there are no checks; nil while no read has said.
    var checks: String?
    /// Nil while no read has said.
    var merge: PullRequestMergeFacts? = nil
    /// Its title, for a row that only knows the link (the tray above the composer). Nil while no read has said.
    var title: String? = nil

    var mergeStatus: PullRequestMergeStatus { PullRequestMergeStatus(glyph: glyph, checks: checks, merge: merge) }

    /// The glyph a request in this state shows: a conflict only while it is unresolved, and over a draft.
    static func glyph(state: PullRequestState, conflicted: Bool) -> PullRequestBadge.Glyph {
        if state.isOpen && conflicted { return .conflict }
        return PullRequestBadge.Glyph(rawValue: state.rawValue) ?? .open
    }

    /// The checks of a pull request page in the words a watch uses.
    static func checks(_ list: [PullRequestCheck]) -> String {
        let outcomes = list.map(\.outcome).filter { $0 != .skipped }
        if outcomes.isEmpty { return "" }
        if outcomes.contains(.failing) { return "failure" }
        return outcomes.contains(.pending) ? "pending" : "success"
    }

    /// The checks as a pull request list row holds them; nil while no read has said, so the row keeps the list's.
    var ci: PullRequestItem.CI? {
        switch checks {
        case "success": return .passing
        case "failure": return .failing
        case "pending": return .pending
        case "": return .unknown
        default: return nil
        }
    }
}

/// The one place every pull request status in Nook comes from, so the badge on a row, the tray above the composer and
/// the pull request page never disagree. Each read of a pull request (the branch sync, a watch, the page, the tray's own
/// look) is recorded here; the newest wins. Publishes only when what is shown changes.
@MainActor
final class PullRequestStatusStore: ObservableObject {
    static let shared = PullRequestStatusStore()

    @Published private(set) var statuses: [String: PullRequestStatus] = [:]
    private var readAt: [String: Date] = [:]
    /// When a read last said how the checks stand. The branch sync says only the state, so it orders the reads
    /// (`readAt`) but does not count for `refresh`: otherwise a sync every few seconds keeps the checks from ever
    /// being read, and the tray above the composer shows no CI at all.
    private var checksReadAt: [String: Date] = [:]
    private var inFlight = Set<String>()
    /// Reads a pull request or merge request; set by the app (GitHub or GitLab, with the connected accounts).
    var fetch: ((URL) async -> PullRequestSnapshot?)?

    /// "github.com/owner/repo/pull/12" or "gitlab.example.com/group/repo/-/merge_requests/12", lowercased: the same
    /// request however its link was written (with a tab like "/files", a query or a trailing slash).
    nonisolated static func key(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/").map { String($0).lowercased() }
        guard let marker = parts.firstIndex(where: { $0 == "pull" || $0 == "merge_requests" }), marker + 1 < parts.count,
              Int(parts[marker + 1]) != nil else { return nil }
        return ([host] + parts[...(marker + 1)]).joined(separator: "/")
    }

    nonisolated static func key(repo: String, number: Int) -> String { "github.com/\(repo.lowercased())/pull/\(number)" }

    func status(_ url: URL) -> PullRequestStatus? { Self.key(url).flatMap { statuses[$0] } }

    /// The links with the state and conflict of the newest read, for a badge built from the branch sync.
    func current(_ links: [PullRequestLink]) -> [PullRequestLink] {
        links.map { link in
            guard let url = URL(string: link.url), let status = status(url) else { return link }
            var link = link
            switch status.glyph {
            case .conflict: link.state = link.state.isOpen ? link.state : .open; link.conflicted = true
            case .draft: link.state = .draft; link.conflicted = false
            case .open: link.state = .open; link.conflicted = false
            case .merged: link.state = .merged
            case .closed: link.state = .closed
            case .stack: break
            }
            return link
        }
    }

    // MARK: Recording reads

    /// `checks`, `merge` or `title` nil: this read does not know them, so the last known ones stay.
    func record(key: String?, glyph: PullRequestBadge.Glyph, checks: String?, merge: PullRequestMergeFacts? = nil,
                title: String? = nil, at date: Date = Date()) {
        guard let key, glyph != .stack, date >= readAt[key] ?? .distantPast else { return }
        readAt[key] = date
        if checks != nil { checksReadAt[key] = date }
        let title = title.flatMap { $0.isEmpty ? nil : $0 } ?? statuses[key]?.title
        let next = PullRequestStatus(glyph: glyph, checks: checks ?? statuses[key]?.checks, merge: merge ?? statuses[key]?.merge, title: title)
        if statuses[key] != next { statuses[key] = next }
    }

    func record(url: URL, snapshot: PullRequestSnapshot, at date: Date = Date()) {
        let state: PullRequestState = snapshot.state == "merged" ? .merged : snapshot.state == "closed" ? .closed
            : snapshot.draft ? .draft : .open
        record(key: Self.key(url), glyph: PullRequestStatus.glyph(state: state, conflicted: snapshot.conflicted),
               checks: snapshot.checks, merge: snapshot.merge, title: snapshot.title, at: date)
    }

    /// What the branch sync found: state and conflict, without checks.
    func record(_ links: [PullRequestLink], at date: Date = Date()) {
        for link in links {
            guard let url = URL(string: link.url) else { continue }
            record(key: Self.key(url), glyph: PullRequestStatus.glyph(state: link.state, conflicted: link.conflicted), checks: nil,
                   title: link.title, at: date)
        }
    }

    func record(_ detail: PullRequestDetail, at date: Date = Date()) {
        let state = PullRequestState(rawValue: detail.state.rawValue) ?? .open
        let key = detail.url.flatMap(Self.key) ?? Self.key(repo: detail.repo, number: detail.number)
        record(key: key, glyph: PullRequestStatus.glyph(state: state, conflicted: detail.conflicted),
               checks: PullRequestStatus.checks(detail.checks), merge: detail.mergeFacts, title: detail.title, at: date)
    }

    /// What Nook kept from before this launch, shown until the first read of each request: the store starts empty, and a
    /// row with nothing to go on would call a merged pull request open. No read counts as done, so every shown one is still
    /// read at once and that read wins. Where the kept copies disagree, a merged or closed one beats an older open one.
    func seed(_ kept: [(url: String, glyph: PullRequestBadge.Glyph)]) {
        var next = statuses
        for (url, glyph) in kept where glyph != .stack {
            guard let key = URL(string: url).flatMap(Self.key), readAt[key] == nil else { continue }
            let settled = glyph == .merged || glyph == .closed
            if let known = next[key]?.glyph, !settled || known == .merged || known == .closed { continue }
            next[key] = PullRequestStatus(glyph: glyph, checks: nil)
        }
        if next != statuses { statuses = next }
    }

    // MARK: Reading

    /// Reads the pull request when the last read that knew its checks is older than `maxAge`; one read at a time per
    /// request.
    func refresh(_ url: URL, maxAge: TimeInterval = 20) async {
        guard let key = Self.key(url), let fetch, !inFlight.contains(key),
              Date().timeIntervalSince(checksReadAt[key] ?? .distantPast) >= maxAge else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        let started = Date()
        guard let snapshot = await fetch(url) else { return }
        record(url: url, snapshot: snapshot, at: started)
    }

    /// How often a shown pull request is read again (`follow`, in the app): every 30 seconds while it is open (as the
    /// pull request page does), every 15 minutes once merged or closed (one read is several requests, and a session can
    /// show a merged one all day), stretched by the energy plan.
    nonisolated static func followInterval(settled: Bool, plan: EnergyPlan) -> TimeInterval {
        (settled ? 900 : 30) * plan.slowdown
    }
}
