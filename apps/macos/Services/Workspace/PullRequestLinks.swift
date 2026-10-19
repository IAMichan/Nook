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
        guard let c = URLComponents(string: text), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let hostRaw = c.host, !hostRaw.isEmpty else { return nil }
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

    /// Open (or draft) and blocked by a merge conflict.
    var hasConflict: Bool { state.isOpen && conflicted }

    var id: String { "\(host.key)/\(repository.lowercased())#\(number)" }
}

enum PullRequestStack {
    /// Layers from the top of the stack down to the PRs that target a branch no linked PR owns. A PR whose base is
    /// another PR's head sits above that PR; siblings share a layer, ordered by number.
    static func order(links: [PullRequestLink]) -> [[PullRequestLink]] {
        var unique: [PullRequestLink] = []
        var seen = Set<String>()
        for link in links where seen.insert(link.id).inserted { unique.append(link) }

        func parent(of link: PullRequestLink) -> PullRequestLink? {
            guard let base = link.baseBranch, !base.isEmpty else { return nil }
            let candidates = unique.filter {
                $0.id != link.id && $0.headBranch == base && $0.host == link.host && $0.repository.lowercased() == link.repository.lowercased()
            }
            // The same head can have an old closed PR and a live one: chain through the live one.
            return candidates.max { ($0.state.isOpen ? 1 : 0, $0.number) < ($1.state.isOpen ? 1 : 0, $1.number) }
        }
        func depth(_ link: PullRequestLink) -> Int {
            var current = link, visited: Set<String> = [link.id], result = 0
            while let up = parent(of: current), visited.insert(up.id).inserted {
                result += 1
                current = up
            }
            return result
        }
        let grouped = Dictionary(grouping: unique, by: depth)
        return grouped.keys.sorted(by: >).map { key in grouped[key]!.sorted { $0.number < $1.number } }
    }

    static func isStack(links: [PullRequestLink]) -> Bool { order(links: links).count > 1 }
}

/// Whether a forge's answer about one request means "merge conflict". GitHub computes `mergeable` lazily (null on the
/// first ask), so only an explicit `false` or a `dirty` merge state counts; GitLab says so with `has_conflicts`.
enum PullRequestMergeability {
    static func githubConflicted(_ pull: [String: Any]) -> Bool {
        if (pull["mergeable_state"] as? String)?.lowercased() == "dirty" { return true }
        return (pull["mergeable"] as? Bool) == false
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
        case stack(Int)
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
        if links.count > 1, PullRequestStack.isStack(links: links) { return PullRequestBadge(glyph: .stack, label: .stack(links.count)) }
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

/// An unresolved PR holds the session open, and the newest merged/closed one decides.
enum PullRequestSettlement {
    static func allMerged(links: [PullRequestLink]) -> Bool { !links.isEmpty && links.allSatisfy { $0.state == .merged } }

    static func anyOpen(links: [PullRequestLink]) -> Bool { links.contains { $0.state.isOpen } }

    static func shouldSettle(links: [PullRequestLink], settleOnMerge: Bool = true) -> Bool {
        guard !links.isEmpty, !anyOpen(links: links) else { return false }
        let latest = links.max { ($0.updatedAt ?? .distantPast, $0.number) < ($1.updatedAt ?? .distantPast, $1.number) }!
        return latest.state == .closed || (latest.state == .merged && settleOnMerge)
    }

    /// How long a branch's answer stays fresh: an open request can be merged any moment, a branch without one may get
    /// one soon, and a merged or closed one rarely changes again.
    static func syncInterval(links: [PullRequestLink]) -> TimeInterval {
        if anyOpen(links: links) { return 30 }
        return links.isEmpty ? 60 : 900
    }

    /// Asked at most once a minute; a clock that went backwards counts as due.
    static func needsSync(lastChecked: Date?, now: Date, interval: TimeInterval = 60) -> Bool {
        guard let lastChecked else { return true }
        let elapsed = now.timeIntervalSince(lastChecked)
        return elapsed < 0 || elapsed >= interval
    }
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
