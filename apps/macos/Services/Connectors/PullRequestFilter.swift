import Foundation

/// What the Pull requests list under Agents shows: a search over title, repository,
/// number, author and branch that also takes qualifiers (`label:bug`, `author:ada`, `review:approved`, see
/// `PullRequestQuery`), and the choices in the Filters dropdown: the state (open by default, closed, merged or all),
/// which group (for your review, yours, or from the watched organizations and repositories), the author, the labels,
/// drafts, the review decision, CI, and the repository. Kept across launches (`load` / `save`). Foundation only, so
/// tests can use it.
struct PullRequestFilter: Equatable, Codable, Sendable {
    enum State: String, CaseIterable, Identifiable, Codable, Sendable {
        case all, open, closed, merged
        var id: String { rawValue }
    }

    enum Scope: String, CaseIterable, Identifiable, Codable, Sendable {
        case all, reviews, mine, watched
        var id: String { rawValue }
    }

    enum Draft: String, CaseIterable, Identifiable, Codable, Sendable {
        case all, drafts, ready
        var id: String { rawValue }
    }

    /// The review decision, as the Review filter offers it.
    enum Review: String, CaseIterable, Identifiable, Codable, Sendable {
        case all, approved, changesRequested, required, noReviews
        var id: String { rawValue }
    }

    enum Status: String, CaseIterable, Identifiable, Codable, Sendable {
        case any, failing, pending, passing
        var id: String { rawValue }
    }

    var query = ""
    var state: State = .open
    var scope: Scope = .all
    /// A login, or nil for anyone.
    var author: String?
    /// Labels a pull request must all carry.
    var labels: [String] = []
    var draft: Draft = .all
    var review: Review = .all
    var status: Status = .any
    /// "owner/name", or nil for every repository.
    var repo: String?

    init(query: String = "", state: State = .open, scope: Scope = .all, author: String? = nil, labels: [String] = [],
         draft: Draft = .all, review: Review = .all, status: Status = .any, repo: String? = nil) {
        self.query = query
        self.state = state
        self.scope = scope
        self.author = author
        self.labels = labels
        self.draft = draft
        self.review = review
        self.status = status
        self.repo = repo
    }

    /// How many dropdown choices differ from the default (the search not counted), for the badge on the Filters button.
    var activeCount: Int {
        [state != .open, scope != .all, author != nil, draft != .all, review != .all, status != .any, repo != nil]
            .filter { $0 }.count + labels.count
    }

    var isActive: Bool { parsed != PullRequestQuery() || activeCount > 0 }

    /// The search, read into words and qualifiers.
    var parsed: PullRequestQuery { PullRequestQuery.parse(query) }

    /// The choices that count, a qualifier typed in the search winning over the dropdown.
    var effectiveAuthor: String? { parsed.author ?? author }
    var effectiveDraft: Draft { parsed.draft ?? draft }
    var effectiveReview: Review { parsed.review ?? review }
    var effectiveStatus: Status { parsed.checks ?? status }
    var effectiveRepo: String? { parsed.repo ?? repo }

    func matches(_ item: PullRequestItem) -> Bool {
        matches(item, parsed: parsed)
    }

    private func matches(_ item: PullRequestItem, parsed: PullRequestQuery) -> Bool {
        switch state {
        case .all: break
        case .open: if item.state != .open { return false }
        case .closed: if item.state != .closed { return false }
        case .merged: if item.state != .merged { return false }
        }
        if let author = parsed.author ?? author, item.author.lowercased() != author.lowercased() { return false }
        if let repo = parsed.repo ?? repo, item.repo.lowercased() != repo.lowercased() { return false }
        switch parsed.draft ?? draft {
        case .all: break
        case .drafts: if !item.draft { return false }
        case .ready: if item.draft { return false }
        }
        switch parsed.review ?? review {
        case .all: break
        case .approved: if item.review != .approved { return false }
        case .changesRequested: if item.review != .changesRequested { return false }
        case .required: if item.review != .required { return false }
        case .noReviews: if item.review != .none { return false }
        }
        switch parsed.checks ?? status {
        case .any: break
        case .failing: if item.ci != .failing { return false }
        case .pending: if item.ci != .pending { return false }
        case .passing: if item.ci != .passing { return false }
        }
        let held = Set(item.labels.map { $0.lowercased() })
        let groups = labels.map { [$0] } + parsed.labels
        if !groups.allSatisfy({ group in group.contains { held.contains($0.lowercased()) } }) { return false }
        if parsed.excludedLabels.contains(where: { held.contains($0.lowercased()) }) { return false }
        let words = parsed.words
        guard !words.isEmpty else { return true }
        let text = "\(item.repo)#\(item.number) \(item.title) @\(item.author) \(item.headBranch)".lowercased()
        return words.allSatisfy { word in
            // A bare number or "#12" is the pull request's number, never part of another one ("#123").
            let digits = word.hasPrefix("#") ? String(word.dropFirst()) : word
            if !digits.isEmpty, digits.allSatisfy(\.isNumber), let number = Int(digits) {
                return item.number == number || (!word.hasPrefix("#") && text.contains(word))
            }
            return text.contains(word)
        }
    }

    /// The account with only the pull requests that match. An error stays, so a failing account never disappears.
    func apply(_ account: AccountPullRequests) -> AccountPullRequests {
        let parsed = self.parsed
        let keep: (PullRequestItem) -> Bool = { matches($0, parsed: parsed) }
        var result = account
        result.reviews = scope == .all || scope == .reviews ? account.reviews.filter(keep) : []
        result.mine = scope == .all || scope == .mine ? account.mine.filter(keep) : []
        result.watched = scope == .all || scope == .watched ? account.watched.filter(keep) : []
        return result
    }

    /// The same filter with the Draft choice changed; a `draft:` typed in the search leaves it, so the
    /// choice just made is the one that counts.
    func settingDraft(_ value: Draft) -> PullRequestFilter {
        var next = clearingTyped(["draft"])
        next.draft = value
        return next
    }

    /// The same filter without the typed qualifiers named in `keys`, for a dropdown choice that replaces them.
    func clearingTyped(_ keys: Set<String>) -> PullRequestFilter {
        var next = self
        let kept = PullRequestQuery.removing(keys, from: query)
        if PullRequestQuery.parse(kept) != parsed { next.query = kept }
        return next
    }

    /// Every author in the lists, for the Author choice: most pull requests first, then by name.
    static func authors(in accounts: [AccountPullRequests]) -> [String] {
        facets(in: accounts, state: .all).authors.map(\.name)
    }

    // MARK: Kept across launches

    private static let defaultsKey = "nook.pulls.filter"

    /// The filter you left the list with, or the default one.
    static func load(from defaults: UserDefaults = .standard) -> PullRequestFilter {
        guard let data = defaults.data(forKey: defaultsKey),
              let filter = try? JSONDecoder().decode(PullRequestFilter.self, from: data) else { return PullRequestFilter() }
        return filter
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// A filter saved by an older Nook lacks the newer choices; each falls back to its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(query: try c.decodeIfPresent(String.self, forKey: .query) ?? "",
                  state: (try? c.decodeIfPresent(State.self, forKey: .state)) ?? .open,
                  scope: (try? c.decodeIfPresent(Scope.self, forKey: .scope)) ?? .all,
                  author: try? c.decodeIfPresent(String.self, forKey: .author),
                  labels: (try? c.decodeIfPresent([String].self, forKey: .labels)) ?? [],
                  draft: (try? c.decodeIfPresent(Draft.self, forKey: .draft)) ?? .all,
                  review: (try? c.decodeIfPresent(Review.self, forKey: .review)) ?? .all,
                  status: (try? c.decodeIfPresent(Status.self, forKey: .status)) ?? .any,
                  repo: try? c.decodeIfPresent(String.self, forKey: .repo))
    }
}

/// What the lists hold, counted for the Filters dropdown: the authors, the labels with their
/// colors, and the repositories, each with how many pull requests in the chosen state carry it.
struct PullRequestFacets: Equatable, Sendable {
    struct Entry: Equatable, Sendable, Identifiable {
        let name: String
        var count: Int
        /// A label's six hex digits; nil for authors, repositories and labels without a color.
        var color: String?
        var id: String { name.lowercased() }
    }

    var authors: [Entry] = []
    var labels: [Entry] = []
    var repos: [Entry] = []
}

extension PullRequestFilter {
    /// The facets of every pull request in `accounts` in `state`, each pull request counted once; most first, then by
    /// name.
    static func facets(in accounts: [AccountPullRequests], state: State) -> PullRequestFacets {
        var seen = Set<String>()
        var authors: [String: PullRequestFacets.Entry] = [:]
        var labels: [String: PullRequestFacets.Entry] = [:]
        var repos: [String: PullRequestFacets.Entry] = [:]
        func add(_ name: String, color: String? = nil, to table: inout [String: PullRequestFacets.Entry]) {
            guard !name.isEmpty else { return }
            let key = name.lowercased()
            var entry = table[key] ?? PullRequestFacets.Entry(name: name, count: 0, color: color)
            entry.count += 1
            if entry.color == nil { entry.color = color }
            table[key] = entry
        }
        for account in accounts {
            for item in account.reviews + account.mine + account.watched where seen.insert(item.id).inserted {
                switch state {
                case .all: break
                case .open: if item.state != .open { continue }
                case .closed: if item.state != .closed { continue }
                case .merged: if item.state != .merged { continue }
                }
                add(item.author, to: &authors)
                add(item.repo, to: &repos)
                for label in item.labels { add(label, color: item.labelColors[label], to: &labels) }
            }
        }
        let order: (PullRequestFacets.Entry, PullRequestFacets.Entry) -> Bool = {
            $0.count != $1.count ? $0.count > $1.count : $0.name.lowercased() < $1.name.lowercased()
        }
        return PullRequestFacets(authors: authors.values.sorted(by: order), labels: labels.values.sorted(by: order),
                                 repos: repos.values.sorted(by: order))
    }
}

/// How the list groups its rows: by why they are in it (for your review, yours, watched), or by repository.
enum PullRequestGrouping: String, CaseIterable, Identifiable, Sendable {
    case involvement, repository
    var id: String { rawValue }
}

/// In what order the list shows its rows and repositories: what waits on you first (reviews asked of you, then your
/// own pull requests with failing checks), or by when they last changed. Open ones always come before closed ones.
enum PullRequestSort: String, CaseIterable, Identifiable, Sendable {
    /// Besides what waits on you: merge readiness (approved with passing checks first, conflicts last, the
    /// smaller change first among equals), what is blocked on you, and by size.
    case attention, readiness, blockedOnMe, recent, oldest, largest, smallest
    var id: String { rawValue }
}

/// The pull requests of an account that are in the list for the same reason (see `AccountPullRequests.byRole`).
struct PullRequestRoleGroup: Identifiable, Equatable, Sendable {
    let role: PullRequestRepoGroup.Role
    var rows: [PullRequestRepoGroup.Row]
    var id: String { role.rawValue }
}

/// The pull requests of one repository in an account, so the list shows every pull request of a repository together.
struct PullRequestRepoGroup: Identifiable, Equatable, Sendable {
    /// Why a pull request is in the list: it waits for your review, you wrote it, or its repository is watched.
    enum Role: String, Equatable, Sendable { case review, mine, watched }

    struct Row: Identifiable, Equatable, Sendable {
        let item: PullRequestItem
        let role: Role
        var id: String { item.id }

        /// An open pull request someone asked you to review.
        var waitsForReview: Bool { role == .review && item.state == .open }

        /// How much it needs you: 0 waits for your review, 1 is yours with failing checks, 2 is another open one,
        /// 3 is closed or merged.
        var urgency: Int {
            guard item.state == .open else { return 3 }
            if role == .review { return 0 }
            return role == .mine && item.ci == .failing ? 1 : 2
        }

        /// How close it is to merging: 0 approved with passing checks, 1 passing checks, 2 a draft or anything else
        /// open, 3 a conflict, 4 closed or merged.
        var readiness: Int {
            guard item.state == .open else { return 4 }
            if item.conflict { return 3 }
            if item.draft { return 2 }
            if item.ci == .passing { return item.review == .approved ? 0 : 1 }
            return 2
        }

        /// What waits on you first: a review asked of you, then your own by what blocks it (a conflict, changes asked
        /// for, failing checks, a draft, anything else, ready to merge), then the watched ones, then closed ones.
        var blockedOnMe: Int {
            guard item.state == .open else { return 9 }
            switch role {
            case .review: return 0
            case .watched: return 8
            case .mine:
                if item.conflict { return 1 }
                if item.review == .changesRequested { return 2 }
                if item.ci == .failing { return 3 }
                if item.draft { return 4 }
                if item.ci == .passing && item.review == .approved { return 6 }
                return 5
            }
        }
    }

    /// "owner/name".
    let repo: String
    var rows: [Row]
    var id: String { repo }

    /// How many of its pull requests wait for your review.
    var waiting: Int { rows.filter(\.waitsForReview).count }
}

extension Array where Element == PullRequestRepoGroup.Row {
    /// The rows in `sort` order; rows that tie keep their order.
    func sorted(by sort: PullRequestSort) -> [Element] {
        enumerated().sorted { left, right in
            Self.precedes(left.element, right.element, sort) ?? (left.offset < right.offset)
        }.map(\.element)
    }

    /// Whether `left` comes before `right`, or nil when they tie.
    static func precedes(_ left: Element, _ right: Element, _ sort: PullRequestSort) -> Bool? {
        func key(_ row: Element) -> (Int, Double, Double) {
            let updated = row.item.updated?.timeIntervalSince1970 ?? 0
            let open = row.item.state == .open ? 0 : 1
            let size = Double(row.item.size)
            switch sort {
            case .attention: return (row.urgency, -updated, 0)
            case .readiness: return (row.readiness, size, -updated)
            case .blockedOnMe: return (row.blockedOnMe, -updated, 0)
            case .recent: return (open, -updated, 0)
            case .oldest: return (open, updated, 0)
            case .largest: return (open, -size, -updated)
            case .smallest: return (open, size, -updated)
            }
        }
        let (a, b) = (key(left), key(right))
        return a == b ? nil : a < b
    }
}

extension AccountPullRequests {
    /// The account's pull requests by repository, each repository's rows in `sort` order. Repositories follow their
    /// first row in the same order (so with `.attention` the ones with a review waiting for you lead), then their name.
    /// A pull request in more than one list shows once: as a review, else as yours, else as watched.
    func byRepo(sort: PullRequestSort = .attention) -> [PullRequestRepoGroup] {
        var groups: [PullRequestRepoGroup] = []
        var index: [String: Int] = [:]
        var seen = Set<String>()
        let tagged = reviews.map { ($0, PullRequestRepoGroup.Role.review) } + mine.map { ($0, .mine) } + watched.map { ($0, .watched) }
        for (item, role) in tagged where seen.insert(item.id).inserted {
            let row = PullRequestRepoGroup.Row(item: item, role: role)
            if let at = index[item.repo] {
                groups[at].rows.append(row)
            } else {
                index[item.repo] = groups.count
                groups.append(PullRequestRepoGroup(repo: item.repo, rows: [row]))
            }
        }
        for at in groups.indices { groups[at].rows = groups[at].rows.sorted(by: sort) }
        return groups.sorted { left, right in
            [PullRequestRepoGroup.Row].precedes(left.rows[0], right.rows[0], sort)
                ?? (left.repo.lowercased() < right.repo.lowercased())
        }
    }
}

extension AccountPullRequests {
    /// The account's pull requests by why they are in the list: the ones waiting for your review, yours, then the
    /// watched ones, each group's rows in `sort` order. A pull request in more than one list shows once, in the first;
    /// a group without rows is left out.
    func byRole(sort: PullRequestSort = .attention) -> [PullRequestRoleGroup] {
        var seen = Set<String>()
        let lists: [(PullRequestRepoGroup.Role, [PullRequestItem])] = [(.review, reviews), (.mine, mine), (.watched, watched)]
        return lists.compactMap { entry -> PullRequestRoleGroup? in
            let (role, items) = entry
            let rows = items.filter { seen.insert($0.id).inserted }
                .map { PullRequestRepoGroup.Row(item: $0, role: role) }
                .sorted(by: sort)
            return rows.isEmpty ? nil : PullRequestRoleGroup(role: role, rows: rows)
        }
    }
}
