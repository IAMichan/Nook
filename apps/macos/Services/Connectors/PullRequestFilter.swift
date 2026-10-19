import Foundation

/// What the Pull requests list under Agents shows: a search over title, repository, number and author, which group
/// (waiting for your review, or yours), and a state (failing, pending or passing CI, or drafts). Foundation only, so
/// tests can use it.
struct PullRequestFilter: Equatable, Sendable {
    enum Scope: String, CaseIterable, Identifiable, Sendable {
        case all, reviews, mine
        var id: String { rawValue }
    }

    enum Status: String, CaseIterable, Identifiable, Sendable {
        case any, failing, pending, passing, draft
        var id: String { rawValue }
    }

    var query = ""
    var scope: Scope = .all
    var status: Status = .any

    var isActive: Bool { !words.isEmpty || scope != .all || status != .any }

    /// The search, in lowercase words. Every word must appear; "@ada" matches the author, "#12" the number.
    private var words: [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    func matches(_ item: PullRequestItem) -> Bool {
        switch status {
        case .any: break
        case .draft: if !item.draft { return false }
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
        result.reviews = scope == .mine ? [] : account.reviews.filter(matches)
        result.mine = scope == .reviews ? [] : account.mine.filter(matches)
        return result
    }
}
