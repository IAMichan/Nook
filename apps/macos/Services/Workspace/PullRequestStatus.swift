import Foundation

/// How one pull request looks, as the newest read anywhere in Nook said: its state and its checks.
struct PullRequestStatus: Equatable, Sendable {
    /// Draft, open, conflict, merged or closed (never `.stack`).
    var glyph: PullRequestBadge.Glyph
    /// "success", "failure", "pending", or empty when there are no checks; nil while no read has said.
    var checks: String?

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
}

/// The one place every pull request status in Nook comes from, so the badge on a row, the tray above the composer and
/// the pull request page never disagree. Each read of a pull request (the branch sync, a watch, the page, the tray's own
/// look) is recorded here; the newest wins. Publishes only when what is shown changes.
@MainActor
final class PullRequestStatusStore: ObservableObject {
    static let shared = PullRequestStatusStore()

    @Published private(set) var statuses: [String: PullRequestStatus] = [:]
    private var readAt: [String: Date] = [:]
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

    /// `checks` nil: this read does not know them, so the last known ones stay.
    func record(key: String?, glyph: PullRequestBadge.Glyph, checks: String?, at date: Date = Date()) {
        guard let key, glyph != .stack, date >= readAt[key] ?? .distantPast else { return }
        readAt[key] = date
        let next = PullRequestStatus(glyph: glyph, checks: checks ?? statuses[key]?.checks)
        if statuses[key] != next { statuses[key] = next }
    }

    func record(url: URL, snapshot: PullRequestSnapshot, at date: Date = Date()) {
        let state: PullRequestState = snapshot.state == "merged" ? .merged : snapshot.state == "closed" ? .closed
            : snapshot.draft ? .draft : .open
        record(key: Self.key(url), glyph: PullRequestStatus.glyph(state: state, conflicted: snapshot.conflicted),
               checks: snapshot.checks, at: date)
    }

    /// What the branch sync found: state and conflict, without checks.
    func record(_ links: [PullRequestLink], at date: Date = Date()) {
        for link in links {
            guard let url = URL(string: link.url) else { continue }
            record(key: Self.key(url), glyph: PullRequestStatus.glyph(state: link.state, conflicted: link.conflicted), checks: nil, at: date)
        }
    }

    func record(_ detail: PullRequestDetail, at date: Date = Date()) {
        let state = PullRequestState(rawValue: detail.state.rawValue) ?? .open
        let key = detail.url.flatMap(Self.key) ?? Self.key(repo: detail.repo, number: detail.number)
        record(key: key, glyph: PullRequestStatus.glyph(state: state, conflicted: detail.conflicted),
               checks: PullRequestStatus.checks(detail.checks), at: date)
    }

    // MARK: Reading

    /// Reads the pull request when the last read is older than `maxAge`; one read at a time per request.
    func refresh(_ url: URL, maxAge: TimeInterval = 20) async {
        guard let key = Self.key(url), let fetch, !inFlight.contains(key),
              Date().timeIntervalSince(readAt[key] ?? .distantPast) >= maxAge else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        let started = Date()
        guard let snapshot = await fetch(url) else { return }
        record(url: url, snapshot: snapshot, at: started)
    }

    /// Keeps a shown pull request current until the task that runs it ends: every 30 seconds while it is open (as the
    /// pull request page does), every two minutes once merged or closed. Places showing the same one share the reads.
    static func follow(_ url: URL) async {
        while !Task.isCancelled {
            await shared.refresh(url)
            let settled = shared.status(url).map { $0.glyph == .merged || $0.glyph == .closed } ?? false
            try? await Task.sleep(for: .seconds(settled ? 120 : 30))
        }
    }
}
