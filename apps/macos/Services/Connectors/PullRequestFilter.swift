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

/// The pull requests of one repository in an account, so the list shows every pull request of a repository together.
struct PullRequestRepoGroup: Identifiable, Equatable, Sendable {
    /// Why a pull request is in the list: it waits for your review, you wrote it, or its repository is watched.
    enum Role: Equatable, Sendable { case review, mine, watched }

    struct Row: Identifiable, Equatable, Sendable {
        let item: PullRequestItem
        let role: Role
        var id: String { item.id }
    }

    /// "owner/name".
    let repo: String
    var rows: [Row]
    var id: String { repo }
}

extension AccountPullRequests {
    /// The account's pull requests by repository. Repositories keep the order they first appear in (the ones waiting
    /// for your review first, then yours, then watched ones); within one, reviews come first, then yours, then the
    /// watched ones, each in its list's order. A pull request in more than one list shows once, in the first.
    var byRepo: [PullRequestRepoGroup] {
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
        return groups
    }
}
