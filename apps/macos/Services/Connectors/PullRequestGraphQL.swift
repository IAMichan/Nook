import Foundation

/// One pull request in the list under Agents › Pull requests.
struct PullRequestItem: Identifiable, Equatable, Codable, Sendable {
    enum CI: String, Equatable, Codable, Sendable { case unknown, pending, passing, failing }
    /// Where the pull request stands: still open, closed without merging, or merged.
    enum State: String, Equatable, Codable, Sendable { case open, closed, merged }

    let repo: String
    let number: Int
    let title: String
    let url: URL?
    let draft: Bool
    let updated: Date?
    let author: String
    var ci: CI = .unknown
    var state: State = .open

    var id: String { "\(repo)#\(number)" }
}

extension PullRequestItem {
    private enum CodingKeys: String, CodingKey { case repo, number, title, url, draft, updated, author, ci, state }

    /// A list saved before states existed only held open pull requests.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(repo: try c.decode(String.self, forKey: .repo), number: try c.decode(Int.self, forKey: .number),
                  title: try c.decode(String.self, forKey: .title), url: try c.decodeIfPresent(URL.self, forKey: .url),
                  draft: try c.decode(Bool.self, forKey: .draft), updated: try c.decodeIfPresent(Date.self, forKey: .updated),
                  author: try c.decode(String.self, forKey: .author), ci: try c.decodeIfPresent(CI.self, forKey: .ci) ?? .unknown,
                  state: try c.decodeIfPresent(State.self, forKey: .state) ?? .open)
    }
}

/// The pull requests of one GitHub account: the ones you wrote and the ones for your review (open ones waiting for
/// it, closed and merged ones you reviewed).
struct AccountPullRequests: Identifiable, Equatable, Codable, Sendable {
    /// The account's id in `AccountRegistry` ("github", "github.werk").
    let id: String
    /// How the account is named in Nook: its label, else its login.
    let name: String
    let login: String
    var mine: [PullRequestItem]
    var reviews: [PullRequestItem]
    /// Set when this account could not be read (token rejected, no connection).
    var error: String?
    /// What kind of failure `error` is, so the view can offer the way out (signing in again for `.auth`).
    var errorKind: ConnectorErrorKind? = nil
}

/// The whole list in one GraphQL request per account: four aliased searches (yours and the ones waiting for your
/// review while open; yours and the ones you reviewed once closed or merged), your login, and each pull request's state
/// and CI as one rolled-up state of its latest commit, instead of a request per pull request. Foundation only, so tests can use it.
enum PullRequestGraphQL {
    static let query = """
    query NookPullRequests($mine: String!, $reviews: String!, $mineClosed: String!, $reviewsClosed: String!) {
      viewer { login }
      mine: search(query: $mine, type: ISSUE, first: 50) { nodes { ...row } }
      reviews: search(query: $reviews, type: ISSUE, first: 50) { nodes { ...row } }
      mineClosed: search(query: $mineClosed, type: ISSUE, first: 30) { nodes { ...row } }
      reviewsClosed: search(query: $reviewsClosed, type: ISSUE, first: 30) { nodes { ...row } }
    }
    fragment row on PullRequest {
      number title url isDraft updatedAt state
      author { login }
      repository { nameWithOwner }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    }
    """

    static func body() -> Data {
        let variables = ["mine": "is:pr is:open archived:false author:@me sort:updated-desc",
                         "reviews": "is:pr is:open archived:false review-requested:@me sort:updated-desc",
                         "mineClosed": "is:pr is:closed archived:false author:@me sort:updated-desc",
                         "reviewsClosed": "is:pr is:closed archived:false reviewed-by:@me -author:@me sort:updated-desc"]
        return (try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])) ?? Data()
    }

    /// The answer: your login and both lists, open pull requests first, then the closed and merged ones. Throws GitHub's
    /// own message when the query failed as a whole.
    static func parse(_ data: Data) throws -> (login: String, mine: [PullRequestItem], reviews: [PullRequestItem]) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw NookError("GitHub returned an unexpected response.")
        }
        guard let payload = root["data"] as? [String: Any] else {
            let message = ((root["errors"] as? [[String: Any]])?.first?["message"] as? String) ?? "GitHub returned no data."
            throw NookError("GitHub: \(message)")
        }
        let login = ((payload["viewer"] as? [String: Any])?["login"] as? String) ?? ""
        return (login, rows(payload["mine"]) + rows(payload["mineClosed"]), rows(payload["reviews"]) + rows(payload["reviewsClosed"]))
    }

    private static func rows(_ search: Any?) -> [PullRequestItem] {
        (((search as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []).compactMap { node in
            guard let number = (node["number"] as? NSNumber)?.intValue,
                  let repo = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String else { return nil }
            let commits = ((node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            let commit = commits.last?["commit"] as? [String: Any]
            let rollup = (commit?["statusCheckRollup"] as? [String: Any])?["state"] as? String
            return PullRequestItem(repo: repo, number: number, title: (node["title"] as? String) ?? "Untitled",
                                   url: (node["url"] as? String).flatMap(URL.init(string:)), draft: (node["isDraft"] as? Bool) ?? false,
                                   updated: (node["updatedAt"] as? String).flatMap(date),
                                   author: ((node["author"] as? [String: Any])?["login"] as? String) ?? "", ci: ci(rollup),
                                   state: state(node["state"] as? String))
        }
    }

    static func ci(_ state: String?) -> PullRequestItem.CI {
        switch state {
        case "SUCCESS": return .passing
        case "FAILURE", "ERROR": return .failing
        case "PENDING", "EXPECTED": return .pending
        default: return .unknown
        }
    }

    static func state(_ state: String?) -> PullRequestItem.State {
        switch state {
        case "MERGED": return .merged
        case "CLOSED": return .closed
        default: return .open
        }
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
