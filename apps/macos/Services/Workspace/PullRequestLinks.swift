import Foundation

/// A pull request named by a URL, "owner/repo#12" or "#12" (no repository: it means "this project's").
struct PullRequestRef: Equatable, Sendable {
    var host: SourceControlHost?
    var hostName: String?
    /// Repository path as `RemoteRepository.path`; nil for "#12".
    var repository: String?
    var number: Int
    var url: URL?

    /// "owner/repo#12" or "#12".
    var reference: String {
        guard let repository else { return "#\(number)" }
        let shown = repository.split(separator: "/").filter { $0 != "_git" }.joined(separator: "/")
        return "\(shown)#\(number)"
    }

    static func parse(_ text: String) -> PullRequestRef? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.contains("://") { return parseURL(t) }
        guard let hash = t.lastIndex(of: "#"), let number = positive(String(t[t.index(after: hash)...])) else { return nil }
        let left = String(t[..<hash])
        if left.isEmpty { return PullRequestRef(host: nil, hostName: nil, repository: nil, number: number, url: nil) }
        let parts = left.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }) else { return nil }
        return PullRequestRef(host: nil, hostName: nil, repository: left, number: number, url: nil)
    }

    private static func positive(_ s: String) -> Int? {
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(s), n > 0 else { return nil }
        return n
    }

    /// Parses GitHub pull request and GitLab merge request URLs.
    private static func shape(_ kind: SourceControlHost, _ s: [String]) -> (repo: [String], number: Int)? {
        func at(_ i: Int) -> String? { i < s.count ? s[i] : nil }
        switch kind {
        case .github:
            guard s.count >= 4, s[2] == "pull", let n = positive(s[3]) else { return nil }
            return (Array(s[..<2]), n)
        case .bitbucket:
            guard s.count >= 4, s[2] == "pull-requests", let n = positive(s[3]) else { return nil }
            return (Array(s[..<2]), n)
        case .gitea, .forgejo, .gitcafe:
            guard s.count >= 4, s[2] == "pulls", let n = positive(s[3]) else { return nil }
            return (Array(s[..<2]), n)
        case .gitlab:
            guard let dash = s.indices.first(where: { $0 >= 2 && s[$0] == "-" && at($0 + 1) == "merge_requests" }),
                  let n = positive(at(dash + 2) ?? "") else { return nil }
            return (Array(s[..<dash]), n)
        case .azureDevOps:
            guard let git = s.firstIndex(of: "_git"), at(git + 2) == "pullrequest", let n = positive(at(git + 3) ?? "") else { return nil }
            return (Array(s[..<(git + 2)]), n)
        case .unknown:
            return nil
        }
    }

    private static func parseURL(_ text: String) -> PullRequestRef? {
        // Prose leaves punctuation on a link ("see …/pull/12." or "(…/pull/12)"); no pull request URL ends in it.
        var trimmed = Substring(text)
        while let last = trimmed.last, ".,;:!?)]}>'\"".contains(last) { trimmed.removeLast() }
        guard let c = URLComponents(string: String(trimmed)), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var hostRaw = c.host, !hostRaw.isEmpty else { return nil }
        // www.github.com serves the same pages as github.com.
        if hostRaw.lowercased().hasPrefix("www.") { hostRaw = String(hostRaw.dropFirst(4)) }
        let segments = c.path.split(separator: "/").map(String.init)
        let detected = SourceControlHost.classify(hostName: hostRaw.lowercased())
        var kind = detected
        var found = shape(detected, segments)
        if detected.isUnknown {
            // A self-hosted forge under an unrelated name still says what it is in the path.
            for guess in [SourceControlHost.gitlab, .azureDevOps, .bitbucket, .forgejo, .github] {
                if let hit = shape(guess, segments) { kind = guess; found = hit; break }
            }
        }
        guard let found else { return nil }
        var origin = "\(scheme)://\(hostRaw.lowercased())"
        if let port = c.port { origin += ":\(port)" }
        guard var repo = RemoteRepository.detect(remoteURL: origin + "/" + found.repo.joined(separator: "/")) else { return nil }
        repo.host = kind
        return PullRequestRef(host: kind, hostName: repo.hostName, repository: repo.path, number: found.number,
                              url: repo.pullRequestURL(number: found.number))
    }
}

extension PullRequestRef {
    /// A github.com pull request link as the row Nook's pull request page opens with; nil for any other forge, a
    /// GitHub Enterprise host, or "#12" without a repository. Title and author follow once GitHub answers.
    var gitHubItem: PullRequestItem? {
        guard host == .github, hostName == "github.com", let repository, !repository.isEmpty else { return nil }
        return PullRequestItem(repo: repository, number: number, title: "", url: url, draft: false, updated: nil, author: "")
    }

    static func gitHubItem(_ url: URL) -> PullRequestItem? { parse(url.absoluteString)?.gitHubItem }
}

/// Whether a tool call made or showed a pull request, so a pull request link in its output is that one: `gh pr create`,
/// `glab mr view` and the like, or a tool named for pull or merge requests. A command that merely touches a file such as
/// `PullRequestActions.swift` does not count: its output can hold any link (a test's sample `.../pull/3`).
enum PullRequestToolCall {
    private static let command = try? NSRegularExpression(
        pattern: #"(?:^|[\s;&|(`"'])(?:gh\s+pr|glab\s+mr|tea\s+(?:pr|pulls))\s+(?:create|new|view|show)\b"#,
        options: [.caseInsensitive])

    /// A forge CLI that merges or closes a pull request from the shell, in every spelling the CLI takes: `gh pr merge`,
    /// `glab mr merge` or `glab mr accept`, `tea pr merge` or `tea pulls m`, `fj pr close`, `cafe pr merge`, and Azure
    /// DevOps' `az repos pr update --status completed`. Bitbucket has no such CLI. The same list.
    private static let closing = try? NSRegularExpression(
        pattern: #"(?:^|[\s;&|(`"'])(?:gh\s+(?:pr\s+(?:merge|close)|stack\s+merge)|glab\s+mr\s+(?:merge|accept|close)|"#
            + #"tea\s+(?:pr|pulls?)\s+(?:merge|m|close)|fj\s+pr\s+(?:merge|close)|cafe\s+(?:pr|stack)\s+(?:merge|close)|"#
            + #"az\s+repos\s+pr\s+update\b[^;&|\n]*--status[\s=]+["']?(?:completed|abandoned))\b"#,
        options: [.caseInsensitive])

    static func showsPullRequest(tool: String?, command parts: [String?]) -> Bool {
        if let tool = tool?.lowercased(),
           ["pull_request", "pullrequest", "merge_request", "mergerequest"].contains(where: tool.contains) { return true }
        return matches(command, parts) || matches(closing, parts)
    }

    /// The command merged or closed a pull request, so the linked ones are read again at once instead of at the next
    /// round, and the session's row turns merged while you look.
    static func closesPullRequest(command parts: [String?]) -> Bool { matches(closing, parts) }

    /// Every text in a tool call's input (`command`, `cmd`, an argument list), for `closesPullRequest`.
    static func texts(in input: Any?) -> [String] {
        switch input {
        case let text as String: return [text]
        case let words as [String]: return words + [words.joined(separator: " ")]
        case let list as [Any]: return list.flatMap { texts(in: $0) }
        case let object as [String: Any]: return object.values.flatMap { texts(in: $0) }
        default: return []
        }
    }

    private static func matches(_ rx: NSRegularExpression?, _ parts: [String?]) -> Bool {
        guard let rx else { return false }
        return parts.compactMap { $0 }.contains { text in
            rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }
}

enum PullRequestState: String, Codable, Sendable {
    case draft, open, merged, closed

    /// A draft is still unresolved work.
    var isOpen: Bool { self == .draft || self == .open }
}

/// One pull request linked to a session. Decoding tolerates missing and unexpected fields.
struct PullRequestLink: Codable, Equatable, Sendable, Identifiable {
    var host: SourceControlHost
    var repository: String
    var number: Int
    var url: String
    var title: String?
    var state: PullRequestState
    var updatedAt: Date?
    var baseBranch: String?
    var headBranch: String?
    /// The forge reports a merge conflict with the base branch. Only meaningful while the request is open.
    var conflicted: Bool

    init(host: SourceControlHost, repository: String, number: Int, url: String = "", title: String? = nil,
         state: PullRequestState = .open, updatedAt: Date? = nil, baseBranch: String? = nil, headBranch: String? = nil,
         conflicted: Bool = false) {
        self.host = host; self.repository = repository; self.number = number; self.url = url; self.title = title
        self.state = state; self.updatedAt = updatedAt; self.baseBranch = baseBranch; self.headBranch = headBranch
        self.conflicted = conflicted
    }

    private enum Keys: String, CodingKey { case host, repository, number, url, title, state, updatedAt, baseBranch, headBranch, conflicted }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        host = (try? c.decode(SourceControlHost.self, forKey: .host)) ?? .unknown("")
        repository = (try? c.decode(String.self, forKey: .repository)) ?? ""
        number = try c.decode(Int.self, forKey: .number)
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        // An unknown state from a newer build is treated as open: it blocks settling rather than ending a session early.
        state = (try? c.decode(PullRequestState.self, forKey: .state)) ?? .open
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        baseBranch = try? c.decodeIfPresent(String.self, forKey: .baseBranch)
        headBranch = try? c.decodeIfPresent(String.self, forKey: .headBranch)
        conflicted = ((try? c.decodeIfPresent(Bool.self, forKey: .conflicted)) ?? nil) ?? false
    }

    /// A request known only by its link (the watched one, one the agent printed): open until a read says otherwise. Nil
    /// for a link to no request.
    init?(url: URL) {
        guard let ref = PullRequestRef.parse(url.absoluteString), let repository = ref.repository else { return nil }
        self.init(host: ref.host ?? .unknown(ref.hostName ?? ""), repository: repository, number: ref.number, url: url.absoluteString)
    }

    /// Open (or draft) and blocked by a merge conflict.
    var hasConflict: Bool { state.isOpen && conflicted }

    var id: String { "\(host.key)/\(repository.lowercased())#\(number)" }

    /// The pull request the tray above a session's composer shows from a branch's list: an open one first, else the
    /// newest one that merged or closed, so its state stays in view after it lands. GitHub and GitLab only.
    static func shown(in links: [PullRequestLink]) -> URL? {
        let usable = links.filter { $0.host == .github || $0.host == .gitlab }
        let pick = usable.first(where: { $0.state.isOpen })
            ?? usable.max { ($0.updatedAt ?? .distantPast, $0.number) < ($1.updatedAt ?? .distantPast, $1.number) }
        return pick.flatMap { URL(string: $0.url) }
    }
}

enum PullRequestStack {
    /// Layers from the top of the stack down to the PRs that target a branch no linked PR owns. A PR whose base is
    /// another PR's head sits above that PR; siblings share a layer, ordered by number.
    static func order(links: [PullRequestLink]) -> [[PullRequestLink]] {
        var unique: [PullRequestLink] = []
        var seen = Set<String>()
        for link in links where seen.insert(link.id).inserted { unique.append(link) }

        func depth(_ link: PullRequestLink) -> Int {
            var current = link, visited: Set<String> = [link.id], result = 0
            while let up = parent(of: current, in: unique), visited.insert(up.id).inserted {
                result += 1
                current = up
            }
            return result
        }
        let grouped = Dictionary(grouping: unique, by: depth)
        return grouped.keys.sorted(by: >).map { key in grouped[key]!.sorted { $0.number < $1.number } }
    }

    static func isStack(links: [PullRequestLink]) -> Bool { order(links: links).count > 1 }

    /// The pull request this one is built on: the one of `links` whose head is its base.
    static func parent(of link: PullRequestLink, in links: [PullRequestLink]) -> PullRequestLink? {
        guard let base = link.baseBranch, !base.isEmpty else { return nil }
        let candidates = links.filter {
            $0.id != link.id && $0.headBranch == base && $0.host == link.host && $0.repository.lowercased() == link.repository.lowercased()
        }
        // The same head can have an old closed PR and a live one: chain through the live one.
        return candidates.max { ($0.state.isOpen ? 1 : 0, $0.number) < ($1.state.isOpen ? 1 : 0, $1.number) }
    }
}

/// Whether a forge's answer about one request means "merge conflict". GitHub computes `mergeable` lazily (null on the
/// first ask), so only an explicit `false` or a `dirty` merge state counts; GitLab says so with `has_conflicts`.
enum PullRequestMergeability {
    static func githubConflicted(_ pull: [String: Any]) -> Bool {
        if (pull["mergeable_state"] as? String)?.lowercased() == "dirty" { return true }
        return (pull["mergeable"] as? Bool) == false
    }

    /// GitHub has an answer once `mergeable` is set, or the merge state already says `dirty`.
    static func githubKnown(_ pull: [String: Any]) -> Bool {
        pull["mergeable"] is Bool || (pull["mergeable_state"] as? String)?.lowercased() == "dirty"
    }

    /// GitLab is still working it out while the merge status says so.
    static func gitlabKnown(_ item: [String: Any]) -> Bool {
        if (item["has_conflicts"] as? Bool) == true { return true }
        return !["checking", "unchecked", "preparing"].contains((item["detailed_merge_status"] as? String)?.lowercased() ?? "")
    }

    static func gitlabConflicted(_ item: [String: Any]) -> Bool {
        if (item["has_conflicts"] as? Bool) == true { return true }
        return (item["detailed_merge_status"] as? String)?.lowercased() == "conflict"
    }
}

/// What the sidebar badge shows, without any wording: the lead localises `.stack` and the state.
struct PullRequestBadge: Equatable, Sendable {
    enum Glyph: String, Sendable { case draft, open, conflict, merged, closed, stack }
    enum Label: Equatable, Sendable {
        case number(Int)
        case numberPlus(Int, extra: Int)
        /// How many pull requests the stack has, and how many of them merged.
        case stack(Int, merged: Int)
    }
    var glyph: Glyph
    var label: Label

    /// "#12" or "#12 +2"; nil for a stack, whose text is localised.
    var text: String? {
        switch label {
        case .number(let n): return "#\(n)"
        case .numberPlus(let n, let extra): return "#\(n) +\(extra)"
        case .stack: return nil
        }
    }

    static func text(links: [PullRequestLink]) -> PullRequestBadge? {
        guard !links.isEmpty else { return nil }
        if links.count > 1, PullRequestStack.isStack(links: links) {
            // A stack wears its own mark while work is left in it, then the state it ended in.
            let merged = links.filter { $0.state == .merged }.count
            let glyph: Glyph = links.contains { $0.state.isOpen } ? .stack : merged > 0 ? .merged : .closed
            return PullRequestBadge(glyph: glyph, label: .stack(links.count, merged: merged))
        }
        let primary = primaryLink(links)
        let glyph: Glyph = primary.hasConflict ? .conflict : Glyph(rawValue: primary.state.rawValue) ?? .open
        return PullRequestBadge(glyph: glyph, label: links.count == 1 ? .number(primary.number) : .numberPlus(primary.number, extra: links.count - 1))
    }

    /// Unresolved work first, then merged before closed; newest and highest number win ties.
    private static func primaryLink(_ links: [PullRequestLink]) -> PullRequestLink {
        func rank(_ l: PullRequestLink) -> Int {
            switch l.state { case .open: return 3; case .draft: return 2; case .merged: return 1; case .closed: return 0 }
        }
        return links.max {
            (rank($0), $0.updatedAt ?? .distantPast, $0.number) < (rank($1), $1.updatedAt ?? .distantPast, $1.number)
        }!
    }
}

extension PullRequestBadge {
    /// The badge of one pull request a chat knows only by its link (the watched one, the one Nook opened, one the agent
    /// printed) while the branch sync has not found it; open until a read says otherwise. Nil for a link to no request.
    static func link(_ url: URL, glyph: Glyph?) -> PullRequestBadge? {
        guard let number = PullRequestRef.parse(url.absoluteString)?.number else { return nil }
        return PullRequestBadge(glyph: glyph ?? .open, label: .number(number))
    }
}

/// The `#` list in the composer.
enum PullRequestMatch {
    static let limit = 6

    static func filter(_ list: [(number: Int, title: String)], query: String) -> [(number: Int, title: String)] {
        var q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.hasPrefix("#") { q.removeFirst() }
        if q.isEmpty { return Array(list.prefix(limit)) }
        if q.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return Array(list.filter { String($0.number).hasPrefix(q) }.prefix(limit))
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return Array(list.filter { $0.title.range(of: q, options: options) != nil }.prefix(limit))
    }
}

/// Which session a prompt link's `pr=owner/name/123` opens: the first in `order` (newest first, archived left out) whose
/// pull requests include that one. Nil when no session works on it.
enum PromptLinkSessions {
    static func linked(_ repository: String, _ number: Int, links: [UUID: [PullRequestLink]], order: [UUID]) -> UUID? {
        let wanted = repository.lowercased()
        return order.first { id in
            (links[id] ?? []).contains { $0.number == number && $0.repository.lowercased() == wanted }
        }
    }
}

/// An unresolved PR holds the session open, and the newest merged/closed one decides.
enum PullRequestSettlement {
    static func allMerged(links: [PullRequestLink]) -> Bool { !links.isEmpty && links.allSatisfy { $0.state == .merged } }

    static func anyOpen(links: [PullRequestLink]) -> Bool { links.contains { $0.state.isOpen } }

    static func shouldSettle(links: [PullRequestLink], settleOnMerge: Bool = true) -> Bool {
        guard !links.isEmpty, !anyOpen(links: links) else { return false }
        let latest = links.max { ($0.updatedAt ?? .distantPast, $0.number) < ($1.updatedAt ?? .distantPast, $1.number) }!
        return latest.state == .closed || (latest.state == .merged && settleOnMerge)
    }

    /// What a session's requests say to the auto-settle rules: open while any is open, else how the newest one ended,
    /// but only when it landed at or after `since` (the session's start or your latest message to it): a request that
    /// closed before you wrote again does not settle the session you are busy in. Without an update time it counts.
    static func autoSettleState(links: [PullRequestLink], since: Date?) -> AutoSettlePolicy.PullRequestState {
        guard !links.isEmpty else { return .none }
        if anyOpen(links: links) { return .open }
        let latest = links.max { ($0.updatedAt ?? .distantPast, $0.number) < ($1.updatedAt ?? .distantPast, $1.number) }!
        if let since, let landed = links.compactMap(\.updatedAt).max(), landed < since { return .none }
        switch latest.state {
        case .merged: return .merged
        case .closed: return .closed
        default: return .none
        }
    }

    /// After this long a merged or closed request, or a session without any, has settled.
    static let settledAfter: TimeInterval = 24 * 60 * 60

    /// How long a branch's answer stays fresh: an open request can be merged any moment, a branch without one may get
    /// one soon, and a merged or closed one rarely changes again. Sessions stay in the list for months, so what has been
    /// quiet for a day is asked far less often: a branch without a request (`quietSince`: when its session last did
    /// anything) as often as a merged one, and a request closed long ago in a quiet session four times a day, for the odd
    /// one reopened.
    static func syncInterval(links: [PullRequestLink], quietSince: Date? = nil, now: Date = Date()) -> TimeInterval {
        if anyOpen(links: links) { return 30 }
        func settled(_ date: Date?) -> Bool { date.map { now.timeIntervalSince($0) >= settledAfter } ?? false }
        if links.isEmpty { return settled(quietSince) ? 900 : 60 }
        // Also a session at work: a merged branch that is used again can get a new request.
        return settled((links.compactMap(\.updatedAt) + [quietSince].compactMap { $0 }).max()) ? 6 * 60 * 60 : 900
    }

    /// Asked at most once a minute; a clock that went backwards counts as due.
    static func needsSync(lastChecked: Date?, now: Date, interval: TimeInterval = 60) -> Bool {
        guard let lastChecked else { return true }
        let elapsed = now.timeIntervalSince(lastChecked)
        return elapsed < 0 || elapsed >= interval
    }
}

/// Which branches one tick asks about. Each forge host is a lane of its own: requests to one host go one after the other,
/// so a long list never floods it, but a slow or unreachable GitLab server keeps only its own branches waiting.
enum PullRequestRound {
    struct Due<Job> {
        /// The forge host; empty while the folder's remote is not known yet.
        var lane: String
        var job: Job
        var open: Bool
        var last: Date
    }

    /// Per lane that is not `busy` its next jobs, open requests first and then the longest unasked. Lanes in name order.
    static func plan<Job>(_ due: [Due<Job>], busy: Set<String>, perRound: Int) -> [(lane: String, jobs: [Job])] {
        Dictionary(grouping: due.filter { !busy.contains($0.lane) }, by: \.lane)
            .sorted { $0.key < $1.key }
            .map { lane, jobs in
                (lane, jobs.sorted { ($0.open ? 0 : 1, $0.last) < ($1.open ? 0 : 1, $1.last) }.prefix(perRound).map(\.job))
            }
    }
}

/// When the pull request list is read again while its panel is closed, so it is current the moment you open it (and for
/// the pickers and links that read it). Only the one quick request for the open ones per account; the slow searches for
/// the closed and watched ones wait far longer. Nothing at all while nobody is at the Mac or its displays sleep.
enum PullRequestBackgroundRefresh {
    /// Between two quiet reads at full speed; the energy plan stretches it (twice as long when light, six times paused).
    static let interval: TimeInterval = 600
    /// The closed, merged and watched rows, read along with a quiet refresh at most this often.
    static let slowInterval: TimeInterval = 1800

    static func wait(plan: EnergyPlan) -> TimeInterval { interval * plan.slowdown }

    /// Whether a quiet read is due: someone is at the Mac, and the list was not read (by the panel or a quiet read)
    /// within the stretched interval. A clock that went backwards counts as due.
    static func isDue(lastRead: Date, now: Date, plan: EnergyPlan, signals: EnergySignals) -> Bool {
        guard !signals.idle else { return false }
        let elapsed = now.timeIntervalSince(lastRead)
        return elapsed < 0 || elapsed >= wait(plan: plan)
    }
}

/// Which pull request pages are read ahead after the list was read (by the panel or a quiet read), so opening one shows
/// it at once instead of loading: the open ones that ask for your review first, then your own, newest first. One that
/// was read recently and did not change since stays as it is; even a changed one waits a few minutes, since an opened
/// page reads it again anyway. Fewer on battery, none while the energy plan pauses.
enum PullRequestDetailWarmup {
    /// What was read ahead (or shown) of a pull request: its last update as GitHub said then, and when.
    struct Seen: Equatable, Sendable {
        var updated: Date?
        var at: Date
    }

    struct Pick: Equatable, Sendable {
        var accountID: String
        var item: PullRequestItem
    }

    /// At full speed; half when light.
    static let limit = 6
    /// A pull request that did not change is read again after this.
    static let freshFor: TimeInterval = 1800
    /// One that changed waits at least this long since its last read.
    static let minimumGap: TimeInterval = 300

    static func count(plan: EnergyPlan) -> Int {
        switch plan.pace {
        case .full: return limit
        case .light: return limit / 2
        case .paused: return 0
        }
    }

    /// The pull requests to read ahead now, in order. `seen` gives what is kept of one (by account and id), nil when none.
    static func picks(accounts: [AccountPullRequests], seen: (String, String) -> Seen?, now: Date, plan: EnergyPlan) -> [Pick] {
        let room = count(plan: plan)
        guard room > 0 else { return [] }
        let newest: (PullRequestItem, PullRequestItem) -> Bool = { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
        var reviews: [Pick] = [], mine: [Pick] = []
        for account in accounts where account.error == nil {
            reviews += account.reviews.filter { $0.state == .open }.sorted(by: newest).map { Pick(accountID: account.id, item: $0) }
            mine += account.mine.filter { $0.state == .open }.sorted(by: newest).map { Pick(accountID: account.id, item: $0) }
        }
        var chosen: [Pick] = []
        var taken = Set<String>()
        for pick in reviews + mine {
            guard chosen.count < room else { break }
            let key = pick.accountID + " " + pick.item.id
            guard !taken.contains(key) else { continue }
            taken.insert(key)
            if let kept = seen(pick.accountID, pick.item.id), !isDue(kept, item: pick.item, now: now) { continue }
            chosen.append(pick)
        }
        return chosen
    }

    /// Whether a kept read is worth replacing; a clock that went backwards counts as due.
    static func isDue(_ kept: Seen, item: PullRequestItem, now: Date) -> Bool {
        let elapsed = now.timeIntervalSince(kept.at)
        if elapsed < 0 { return true }
        let changed = item.updated != nil && kept.updated != item.updated
        return elapsed >= (changed ? minimumGap : freshFor)
    }
}

/// The branches one session worked on, for the list above its composer: a branch the chat moved away from keeps its row
/// with its pull request, so a chat that made several branches and pull requests shows the state of each.
enum SessionBranches {
    /// The session left `old` for `current`: `old` joins the earlier branches (oldest first) unless it is the default
    /// branch, and `current` leaves them when the session goes back to it. Nil when there are none.
    static func leaving(_ old: String?, for current: String, earlier: [String]?, base: String?) -> [String]? {
        var list = (earlier ?? []).filter { $0 != current }
        if let old, !old.isEmpty, old != current, !BranchPolicy.isDefaultBranch(old, detectedDefault: base) {
            list.removeAll { $0 == old }
            list.append(old)
        }
        return list.isEmpty ? nil : list
    }

    /// A branch the session left is empty when it has no commits beyond the base and was never pushed: nothing was done
    /// on it, so it is not listed as an earlier branch. A branch that is gone (its worktree and branch removed) and was
    /// never pushed has nothing left to show either. Unknown (a failed read of a branch that exists) counts as not empty.
    static func isEmpty(aheadOfBase: Int?, pushed: Bool, exists: Bool = true) -> Bool {
        guard !pushed else { return false }
        return !exists || aheadOfBase == 0
    }

    /// The pull requests of a branch the session left, added to the ones it left before (a newer read of the same
    /// request replaces the older one).
    static func keeping(_ left: [PullRequestLink], in earlier: [PullRequestLink]) -> [PullRequestLink] {
        var list = earlier
        for link in left where !link.url.isEmpty {
            if let index = list.firstIndex(where: { $0.url == link.url }) { list[index] = link } else { list.append(link) }
        }
        return list
    }

    struct Row: Equatable, Sendable, Identifiable {
        var branch: String?
        var pullRequest: URL?
        var isCurrent: Bool
        var id: String { (branch ?? "") + "\n" + (pullRequest?.absoluteString ?? "") }
    }

    /// The pull request the tray shows for the branch the session is on: the watched one while it can still change, else
    /// the session's open one (`open`), else the watched one that merged or closed, else the newest of `links`. A watch
    /// that ended never hides an open pull request the session made after it, as when a chat opens a new pull request
    /// from the branch of one that already merged.
    static func trayPullRequest(watch: PullRequestWatch?, open: URL?, links: [PullRequestLink]) -> URL? {
        let watched = watch.flatMap { URL(string: $0.url) }
        let live = watched.flatMap { url -> URL? in
            let stillOpen = watch?.state == "open" && (links.first { $0.url == url.absoluteString }?.state.isOpen ?? true)
            return stillOpen ? url : nil
        }
        return live ?? open ?? watched ?? PullRequestLink.shown(in: links)
    }

    /// One row per branch, oldest first and the current one last, each with its newest pull request; a pull request of an
    /// earlier branch whose name is not known gets a row of its own, and so does each other pull request of the current
    /// branch (one that merged before the session opened a new one from the same branch), just above the current row.
    /// Empty while the session has had one branch with one pull request: that pull request then shows as before. `currentPullRequest` is the one the tray would show on its own, which can
    /// be a watched request of an earlier branch; `currentLinks` are what the forge says the current branch has, so such
    /// a watch never hides the current branch's own pull request.
    static func rows(earlier: [String], earlierLinks: [PullRequestLink], current: String?, currentPullRequest: URL?,
                     currentLinks: [PullRequestLink] = []) -> [Row] {
        func newest(_ branch: String) -> URL? {
            earlierLinks.filter { $0.headBranch == branch }
                .max { ($0.updatedAt ?? .distantPast, $0.number) < ($1.updatedAt ?? .distantPast, $1.number) }
                .flatMap { URL(string: $0.url) }
        }
        let own = currentLinks.filter { $0.headBranch.map { $0 == current } ?? true }
        let picked = currentPullRequest.flatMap { url in own.contains { $0.url == url.absoluteString } ? url : nil }
            ?? PullRequestLink.shown(in: own) ?? currentPullRequest
        let names = earlier.filter { $0 != current }
        var rows = names.map { Row(branch: $0, pullRequest: newest($0), isCurrent: false) }
        for link in earlierLinks where link.headBranch.map({ !names.contains($0) && $0 != current }) ?? true {
            guard !link.url.isEmpty, let url = URL(string: link.url), url != picked,
                  !rows.contains(where: { $0.pullRequest == url }) else { continue }
            rows.append(Row(branch: link.headBranch, pullRequest: url, isCurrent: false))
        }
        for link in own.sorted(by: { $0.number < $1.number }) {
            guard !link.url.isEmpty, let url = URL(string: link.url), url != picked,
                  !rows.contains(where: { $0.pullRequest == url }) else { continue }
            rows.append(Row(branch: current, pullRequest: url, isCurrent: true))
        }
        guard !rows.isEmpty else { return [] }
        // A pull request an earlier row already shows (one still watched after the switch) is not the current one.
        let taken = Set(rows.compactMap(\.pullRequest))
        let mine = [picked, current.flatMap(newest)].compactMap { $0 }.first { !taken.contains($0) }
        rows.append(Row(branch: current, pullRequest: mine, isCurrent: true))
        return rows
    }

    /// How many rows stay open when the list is folded: the newest earlier branch and the current one.
    static let shownWhenFolded = 3

    /// The rows the tray shows: all while `open` or while there are few, otherwise the newest `shownWhenFolded`, with the
    /// count of the folded ones and of their pull requests.
    static func folded(_ rows: [Row], open: Bool) -> (shown: [Row], hidden: Int, hiddenPullRequests: Int) {
        guard !open, rows.count > shownWhenFolded + 1 else { return (rows, 0, 0) }
        let hidden = rows.dropLast(shownWhenFolded)
        return (Array(rows.suffix(shownWhenFolded)), hidden.count, hidden.filter { $0.pullRequest != nil }.count)
    }
}

/// The pull requests behind a session row's badge and its hover card: the ones of the branch it is on now, and the ones
/// of branches (worktrees) it worked on before. A chat that opened a pull request and then moved on to a new worktree
/// keeps showing that request's state until the new branch has one of its own, and the badge counts all of them.
struct SessionPullRequests: Equatable, Sendable {
    var current: [PullRequestLink]
    /// Newest first, without the ones `current` already has.
    var earlier: [PullRequestLink]

    init(current: [PullRequestLink], earlier: [PullRequestLink] = []) {
        var seen = Set<String>()
        self.current = current.filter { seen.insert($0.id).inserted }
        self.earlier = earlier.filter { seen.insert($0.id).inserted }
            .sorted { ($0.updatedAt ?? .distantPast, $0.number) > ($1.updatedAt ?? .distantPast, $1.number) }
    }

    var all: [PullRequestLink] { current + earlier }
    var isEmpty: Bool { current.isEmpty && earlier.isEmpty }
    var badge: PullRequestBadge? { PullRequestBadge.text(links: all) }
}

enum BranchPolicy {
    enum FastForward: Equatable, Sendable { case fastForward, skipDirty, skipDiverged, upToDate }

    private static let defaults: Set<String> = ["main", "master", "trunk", "develop"]

    static func isDefaultBranch(_ name: String, detectedDefault: String? = nil) -> Bool {
        let short = normalize(name)
        if defaults.contains(short.lowercased()) { return true }
        if let detectedDefault, !detectedDefault.isEmpty { return short == normalize(detectedDefault) }
        return false
    }

    private static func normalize(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["refs/heads/", "refs/remotes/origin/", "origin/"] where n.hasPrefix(prefix) { n.removeFirst(prefix.count) }
        return n
    }

    /// "nook/fix-login-3fa2", lengthening the id slice and then counting up until no existing branch (any case) has it.
    static func suggestBranchName(task: String, id: UUID, prefix: String = WorktreeNaming.branchPrefix + "/",
                                  existing: Set<String>) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        let slug = WorktreeNaming.slug(task, limit: 32)
        let hex = id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        for length in [4, 6, 8, 12] {
            let candidate = prefix + slug + "-" + hex.prefix(length)
            if !taken.contains(candidate.lowercased()) { return candidate }
        }
        var n = 2
        while taken.contains((prefix + slug + "-" + hex.prefix(12) + "-\(n)").lowercased()) { n += 1 }
        return prefix + slug + "-" + hex.prefix(12) + "-\(n)"
    }

    /// `ahead`/`behind` are commit counts of the local default branch against its remote. Never touches a dirty
    /// checkout or a diverged branch: both would need a human.
    static func shouldFastForward(ahead: Int, behind: Int, dirty: Bool) -> FastForward {
        if behind <= 0 { return .upToDate }
        if ahead > 0 { return .skipDiverged }
        return dirty ? .skipDirty : .fastForward
    }
}
