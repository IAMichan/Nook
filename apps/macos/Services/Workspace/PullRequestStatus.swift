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
    /// Known repository renames learned from forge redirects (`"github/old/repo" -> "github/new/repo"`),
    /// shared with the tray and sidebar so an old remote URL and a canonical URL count as one request.
    @Published private(set) var repoAliases: [String: String] = [:]
    /// Same mapping keyed by `"host/old/repo"` (e.g. `"github.com/old/repo"`) for status keys.
    private var statusRepoAliases: [String: String] = [:]
    /// Canonical casing of renamed target repositories, keyed by `"github/new/repo"`.
    private var canonicalRepoNames: [String: String] = [:]
    /// Called once when a new repository rename is learned, so watches and linked lists collapse any duplicates.
    var onAliasRecorded: (() -> Void)?
    private var readAt: [String: Date] = [:]
    /// When a read last said how the checks stand. The branch sync says only the state, so it orders the reads
    /// (`readAt`) but does not count for `refresh`: otherwise a sync every few seconds keeps the checks from ever
    /// being read, and the tray above the composer shows no CI at all.
    private var checksReadAt: [String: Date] = [:]
    private var inFlight = Set<String>()
    /// Reads a pull request or merge request; set by the app (GitHub or GitLab, with the connected accounts).
    var fetch: ((URL) async -> PullRequestSnapshot?)?

    /// "github.com/owner/repo/pull/12" or "gitlab.example.com/group/repo/-/merge_requests/12", lowercased: the same
    /// request however its link was written (with a tab like "/files", a query, "www." or a trailing slash).
    nonisolated static func key(_ url: URL) -> String? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        let parts = url.path.split(separator: "/").map { String($0).lowercased() }
        guard let marker = parts.firstIndex(where: { $0 == "pull" || $0 == "merge_requests" }), marker + 1 < parts.count,
              Int(parts[marker + 1]) != nil else { return nil }
        return ([host] + parts[...(marker + 1)]).joined(separator: "/")
    }

    nonisolated static func key(repo: String, number: Int) -> String { "github.com/\(repo.lowercased())/pull/\(number)" }

    func status(_ url: URL) -> PullRequestStatus? { Self.key(url).map(canonicalKey).flatMap { statuses[$0] } }

    /// The canonical repository path (preserving forge casing) for `repository` on `host`, or `repository` when unchanged.
    func canonicalRepository(host: SourceControlHost, repository: String) -> String {
        var current = "\(host.key)/\(repository.lowercased())"
        var hops = 0
        var moved = false
        while let next = repoAliases[current], next != current, hops < 4 {
            current = next
            hops += 1
            moved = true
        }
        guard moved else { return repository }
        if let named = canonicalRepoNames[current] { return named }
        let prefix = host.key + "/"
        return current.hasPrefix(prefix) ? String(current.dropFirst(prefix.count)) : repository
    }

    /// Rewrites `url` to the repository's canonical name when a rename is known; returns `url` unchanged otherwise.
    func canonicalURL(_ url: URL) -> URL {
        guard let ref = PullRequestRef.parse(url.absoluteString), let host = ref.host,
              let repository = ref.repository, let hostName = ref.hostName else { return url }
        let canonical = canonicalRepository(host: host, repository: repository)
        guard canonical.lowercased() != repository.lowercased() else { return url }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let scheme = components?.scheme?.lowercased() ?? "https"
        var origin = "\(scheme)://\(hostName.lowercased())"
        if let port = components?.port { origin += ":\(port)" }
        let repo = RemoteRepository(host: host, hostName: hostName.lowercased(), path: canonical, webOrigin: origin)
        return repo.pullRequestURL(number: ref.number) ?? url
    }

    /// Records a repository rename discovered when `oldURL` redirected to `canonicalURL` for the same request.
    func recordAlias(from oldURL: URL, to canonicalURL: URL) {
        guard let oldRef = PullRequestRef.parse(oldURL.absoluteString),
              let newRef = PullRequestRef.parse(canonicalURL.absoluteString),
              let host = oldRef.host, host == newRef.host,
              let oldHost = oldRef.hostName?.lowercased(), let newHost = newRef.hostName?.lowercased(), oldHost == newHost,
              oldRef.number == newRef.number,
              let oldRepo = oldRef.repository, let newRepo = newRef.repository else { return }
        recordRepositoryAlias(host: host, hostName: oldHost, from: oldRepo, to: newRepo)
    }

    /// Learns repository renames from branch-synced links whose remote `repository` still holds the old name while their
    /// forge `url` carries the new one.
    func recordAliases(from links: [PullRequestLink]) {
        for link in links where !link.repository.isEmpty && !link.url.isEmpty {
            guard let ref = PullRequestRef.parse(link.url), let canonicalRepo = ref.repository,
                  link.repository.lowercased() != canonicalRepo.lowercased() else { continue }
            recordRepositoryAlias(host: link.host, hostName: ref.hostName?.lowercased(), from: link.repository, to: canonicalRepo)
        }
    }

    private func recordRepositoryAlias(host: SourceControlHost, hostName: String?, from oldRepo: String, to newRepo: String) {
        let oldLower = oldRepo.lowercased()
        let newLower = newRepo.lowercased()
        guard !oldLower.isEmpty, !newLower.isEmpty, oldLower != newLower else { return }
        let oldPlace = "\(host.key)/\(oldLower)"
        let newPlace = "\(host.key)/\(newLower)"
        // Avoid introducing a cycle if a caller ever passes a reversed pair.
        guard !Self.reaches(newPlace, target: oldPlace, in: repoAliases) else { return }
        var added = false
        if repoAliases[oldPlace] != newPlace {
            var next = repoAliases
            next[oldPlace] = newPlace
            repoAliases = next
            added = true
        }
        canonicalRepoNames[newPlace] = newRepo
        if let hostName, !hostName.isEmpty {
            let oldStatusRepo = "\(hostName)/\(oldLower)"
            let newStatusRepo = "\(hostName)/\(newLower)"
            if !Self.reaches(newStatusRepo, target: oldStatusRepo, in: statusRepoAliases),
               statusRepoAliases[oldStatusRepo] != newStatusRepo {
                statusRepoAliases[oldStatusRepo] = newStatusRepo
                migrateStatuses(fromRepo: oldStatusRepo, toRepo: newStatusRepo)
            }
        }
        if added { onAliasRecorded?() }
    }

    private static func reaches(_ start: String, target: String, in map: [String: String]) -> Bool {
        var current = start
        var hops = 0
        while let next = map[current], hops < 8 {
            if next == target { return true }
            current = next
            hops += 1
        }
        return false
    }

    private static func splitKey(_ key: String) -> (repo: String, tail: String)? {
        for marker in ["/-/merge_requests/", "/merge_requests/", "/pull/"] {
            if let range = key.range(of: marker) {
                return (String(key[..<range.lowerBound]), String(key[range.lowerBound...]))
            }
        }
        return nil
    }

    private func canonicalKey(_ key: String) -> String {
        guard let (repo, tail) = Self.splitKey(key) else { return key }
        var current = repo
        var hops = 0
        while let next = statusRepoAliases[current], next != current, hops < 4 {
            current = next
            hops += 1
        }
        return current + tail
    }

    /// Merges any status entries recorded under an old repository name into the canonical key so two views never disagree.
    private func migrateStatuses(fromRepo oldRepo: String, toRepo newRepo: String) {
        let prefix = oldRepo + "/"
        let keys = Set(statuses.keys).union(readAt.keys).union(checksReadAt.keys).filter { $0.hasPrefix(prefix) }
        guard !keys.isEmpty else { return }
        var next = statuses
        for oldKey in keys {
            let newKey = canonicalKey(oldKey)
            guard newKey != oldKey else { continue }
            let oldStatus = next.removeValue(forKey: oldKey)
            let oldRead = readAt.removeValue(forKey: oldKey)
            let oldChecksRead = checksReadAt.removeValue(forKey: oldKey)
            if let oldChecksRead {
                checksReadAt[newKey] = max(checksReadAt[newKey] ?? .distantPast, oldChecksRead)
            }
            guard let oldStatus else { continue }
            if let existing = next[newKey] {
                let existingRead = readAt[newKey]
                let oldWins: Bool
                if let oldRead, let existingRead {
                    oldWins = oldRead > existingRead
                } else if oldRead != nil {
                    oldWins = true
                } else if existingRead != nil {
                    oldWins = false
                } else {
                    let oldSettled = oldStatus.glyph == .merged || oldStatus.glyph == .closed
                    let existingSettled = existing.glyph == .merged || existing.glyph == .closed
                    oldWins = oldSettled && !existingSettled
                }
                let primary = oldWins ? oldStatus : existing
                let fallback = oldWins ? existing : oldStatus
                next[newKey] = PullRequestStatus(
                    glyph: primary.glyph,
                    checks: primary.checks ?? fallback.checks,
                    merge: primary.merge ?? fallback.merge,
                    title: primary.title ?? fallback.title)
                if let oldRead, oldRead > (existingRead ?? .distantPast) { readAt[newKey] = oldRead }
            } else {
                next[newKey] = oldStatus
                if let oldRead { readAt[newKey] = oldRead }
            }
        }
        if next != statuses { statuses = next }
    }

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
        guard let rawKey = key, glyph != .stack else { return }
        let key = canonicalKey(rawKey)
        guard date >= readAt[key] ?? .distantPast else { return }
        readAt[key] = date
        if checks != nil { checksReadAt[key] = date }
        let title = title.flatMap { $0.isEmpty ? nil : $0 } ?? statuses[key]?.title
        let next = PullRequestStatus(glyph: glyph, checks: checks ?? statuses[key]?.checks, merge: merge ?? statuses[key]?.merge, title: title)
        if statuses[key] != next { statuses[key] = next }
    }

    func record(url: URL, snapshot: PullRequestSnapshot, at date: Date = Date()) {
        if let canonical = snapshot.url { recordAlias(from: url, to: canonical) }
        let state: PullRequestState = snapshot.state == "merged" ? .merged : snapshot.state == "closed" ? .closed
            : snapshot.draft ? .draft : .open
        record(key: Self.key(snapshot.url ?? url), glyph: PullRequestStatus.glyph(state: state, conflicted: snapshot.conflicted),
               checks: snapshot.checks, merge: snapshot.merge, title: snapshot.title, at: date)
    }

    /// What the branch sync found: state and conflict, without checks.
    func record(_ links: [PullRequestLink], at date: Date = Date()) {
        recordAliases(from: links)
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
            guard let key = URL(string: url).flatMap(Self.key).map(canonicalKey), readAt[key] == nil else { continue }
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
        guard let rawKey = Self.key(url), let fetch else { return }
        let key = canonicalKey(rawKey)
        guard !inFlight.contains(key),
              Date().timeIntervalSince(checksReadAt[key] ?? .distantPast) >= maxAge else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        let started = Date()
        let target = canonicalURL(url)
        guard let snapshot = await fetch(target) else { return }
        record(url: target, snapshot: snapshot, at: started)
    }

    /// How often a shown pull request is read again (`follow`, in the app): every 10 seconds while it is about to change
    /// (checks running, GitHub still working out whether it merges, or no read yet), every 30 while it is open (as the
    /// pull request page does), every 15 minutes once merged or closed (one read is several requests, and a session can
    /// show a merged one all day), stretched by the energy plan.
    nonisolated static func followInterval(_ status: PullRequestStatus?, plan: EnergyPlan) -> TimeInterval {
        guard let status else { return 10 * plan.slowdown }
        if status.glyph == .merged || status.glyph == .closed { return 900 * plan.slowdown }
        return (status.isChanging ? 10 : 30) * plan.slowdown
    }

    /// `seconds` from `now`, stretched to the next whole `grid` of the clock: badges with the same interval wake on the
    /// same beat, so their reads join one batched request (`GitHubSnapshotBatcher`) instead of one each.
    nonisolated static func aligned(_ seconds: TimeInterval, now: Date, grid: TimeInterval = 10) -> TimeInterval {
        guard grid > 0, seconds > 0 else { return seconds }
        let target = now.timeIntervalSince1970 + seconds
        return (target / grid).rounded(.up) * grid - now.timeIntervalSince1970
    }

    // MARK: Waking the followers

    /// Bumped by `wakeFollowers`: every shown pull request reads again within a few seconds instead of at its next tick.
    private(set) var wakeCount = 0

    /// Something just happened that may have changed the shown pull requests (a session's turn ended: it may have pushed,
    /// merged or closed one), so each shown one reads again now rather than up to half a minute later.
    func wakeFollowers() { wakeCount &+= 1 }

    /// Whether a follower's wait between two reads ends early: you came back to the Mac, or `wakeFollowers` was called.
    /// (A window that shows again ends it too; `AttentionGate` says that without a timer.)
    nonisolated static func readEarly(wasIdle: Bool, isIdle: Bool, wakesBefore: Int, wakesNow: Int) -> Bool {
        (wasIdle && !isIdle) || wakesBefore != wakesNow
    }
}

extension PullRequestStatus {
    /// About to change by itself: checks are running, or GitHub has not yet said whether it merges (just after a push).
    var isChanging: Bool {
        guard glyph != .merged, glyph != .closed else { return false }
        return checks == nil || checks == "pending" || merge == nil || merge?.state == "unknown"
    }
}
