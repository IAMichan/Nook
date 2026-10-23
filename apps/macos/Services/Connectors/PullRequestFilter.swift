import Foundation

/// What the Pull requests list under Agents shows: a search over title, repository, number and author, and the choices
/// in the Filters dropdown: the state (open by default, closed, merged or all), which group (for your review, yours, or
/// from the watched organizations and repositories),
/// the author, drafts, and CI. Foundation only, so tests can use it.
struct PullRequestFilter: Equatable, Sendable {
    enum State: String, CaseIterable, Identifiable, Sendable {
        case all, open, closed, merged
        var id: String { rawValue }
    }

    enum Scope: String, CaseIterable, Identifiable, Sendable {
        case all, reviews, mine, watched
        var id: String { rawValue }
    }

    enum Draft: String, CaseIterable, Identifiable, Sendable {
        case all, drafts, ready
        var id: String { rawValue }
    }

    enum Status: String, CaseIterable, Identifiable, Sendable {
        case any, failing, pending, passing
        var id: String { rawValue }
    }

    var query = ""
    var state: State = .open
    var scope: Scope = .all
    /// A login, or nil for anyone.
    var author: String?
    var draft: Draft = .all
    var status: Status = .any

    /// How many dropdown choices differ from the default (the search not counted), for the badge on the Filters button.
    var activeCount: Int {
        [state != .open, scope != .all, author != nil, draft != .all, status != .any].filter { $0 }.count
    }

    var isActive: Bool { !words.isEmpty || activeCount > 0 }

    /// The search, in lowercase words. Every word must appear; "@ada" matches the author, "#12" the number.
    private var words: [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    func matches(_ item: PullRequestItem) -> Bool {
        switch state {
        case .all: break
        case .open: if item.state != .open { return false }
        case .closed: if item.state != .closed { return false }
        case .merged: if item.state != .merged { return false }
        }
        if let author, item.author.lowercased() != author.lowercased() { return false }
        switch draft {
        case .all: break
        case .drafts: if !item.draft { return false }
        case .ready: if item.draft { return false }
        }
        switch status {
        case .any: break
        case .failing: if item.ci != .failing { return false }
        case .pending: if item.ci != .pending { return false }
        case .passing: if item.ci != .passing { return false }
        }
        let words = self.words
        guard !words.isEmpty else { return true }
        let text = "\(item.repo)#\(item.number) \(item.title) @\(item.author)".lowercased()
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
        var result = account
        result.reviews = scope == .all || scope == .reviews ? account.reviews.filter(matches) : []
        result.mine = scope == .all || scope == .mine ? account.mine.filter(matches) : []
        result.watched = scope == .all || scope == .watched ? account.watched.filter(matches) : []
        return result
    }

    /// Every author in the lists, for the Author choice: most pull requests first, then by name.
    static func authors(in accounts: [AccountPullRequests]) -> [String] {
        var counts: [String: Int] = [:]
        for account in accounts {
            for item in account.mine + account.reviews + account.watched where !item.author.isEmpty { counts[item.author, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.lowercased() < $1.key.lowercased() }.map(\.key)
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
    /// More orders besides the default: merge readiness (approved with passing checks first, conflicts last, the
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
