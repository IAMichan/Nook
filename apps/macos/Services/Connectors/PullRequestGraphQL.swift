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

/// The pull requests of one GitHub account: the ones you wrote, the ones for your review (open ones waiting for
/// it, closed and merged ones you reviewed), and the ones in the organizations and repositories you watch.
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
    /// The other pull requests in the watched organizations and repositories (see PullRequestWatchList).
    var watched: [PullRequestItem] = []
    /// Watched entries this account could not search (a typo, or no access with this account).
    var unreadable: [String] = []
    /// The watched search could not get through this time; the list keeps the watched rows it had. Not saved.
    var watchedFailed = false
}

extension AccountPullRequests {
    private enum CodingKeys: String, CodingKey { case id, name, login, mine, reviews, error, errorKind, watched, unreadable }

    /// A list saved before watching existed has no watched rows.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  login: try c.decode(String.self, forKey: .login), mine: try c.decode([PullRequestItem].self, forKey: .mine),
                  reviews: try c.decode([PullRequestItem].self, forKey: .reviews), error: try c.decodeIfPresent(String.self, forKey: .error),
                  errorKind: try c.decodeIfPresent(ConnectorErrorKind.self, forKey: .errorKind),
                  watched: try c.decodeIfPresent([PullRequestItem].self, forKey: .watched) ?? [],
                  unreadable: try c.decodeIfPresent([String].self, forKey: .unreadable) ?? [])
    }

    var isEmpty: Bool { mine.isEmpty && reviews.isEmpty && watched.isEmpty }
}

/// The organizations ("acme") and repositories ("acme/web") whose pull requests show in the list as well, beyond the
/// ones you wrote or review. Typed in Settings; a GitHub link works too. Foundation only, so tests can use it.
enum PullRequestWatchList {
    static let defaultsKey = "pulls.watched"
    /// Each entry costs two searches per refresh; this keeps a refresh cheap and well inside GitHub's limits.
    static let limit = 20

    /// "acme", "acme/web", "@acme", "github.com/acme/web" or "https://github.com/acme/web/pull/3" → "acme" or "acme/web";
    /// nil for anything that is not a GitHub owner or repository name.
    static func normalize(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "www.", "github.com/", "@"] where value.lowercased().hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        let parts = value.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let owner = parts.first, isOwner(owner) else { return nil }
        guard parts.count > 1 else { return owner }
        var repo = parts[1]
        if repo.lowercased().hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard isRepo(repo) else { return nil }
        return owner + "/" + repo
    }

    /// The entries added to a list, normalized, without ones already in it (GitHub names ignore case), up to `limit`.
    static func adding(_ text: String, to list: [String]) -> [String] {
        var result = list
        for piece in text.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            guard result.count < limit, let entry = normalize(String(piece)),
                  !result.contains(where: { $0.lowercased() == entry.lowercased() }) else { continue }
            result.append(entry)
        }
        return result
    }

    static func isRepository(_ entry: String) -> Bool { entry.contains("/") }

    /// The search for one entry's open or closed pull requests.
    static func search(_ entry: String, closed: Bool) -> String {
        let scope = isRepository(entry) ? "repo:" + entry : "org:" + entry
        return "is:pr \(closed ? "is:closed" : "is:open") archived:false \(scope) sort:updated-desc"
    }

    private static func isOwner(_ text: String) -> Bool {
        (1...39).contains(text.count) && !text.hasPrefix("-")
            && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" }
    }

    private static func isRepo(_ text: String) -> Bool {
        (1...100).contains(text.count) && text != "." && text != ".."
            && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_.".unicodeScalars.contains($0) }
    }
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
        guard let payload = root["data"] as? [String: Any] else { throw failure(root) }
        let login = ((payload["viewer"] as? [String: Any])?["login"] as? String) ?? ""
        return (login, rows(payload["mine"]) + rows(payload["mineClosed"]), rows(payload["reviews"]) + rows(payload["reviewsClosed"]))
    }

    /// The watched entries in one request: an open and a closed search per entry, aliased by position.
    static func watchBody(_ entries: [String]) -> Data {
        var declarations: [String] = []
        var fields: [String] = []
        var variables: [String: String] = [:]
        for (index, entry) in entries.enumerated() {
            for closed in [false, true] {
                let name = alias(index, closed: closed)
                declarations.append("$\(name): String!")
                fields.append("  \(name): search(query: $\(name), type: ISSUE, first: \(closed ? 20 : 50)) { nodes { ...row } }")
                variables[name] = PullRequestWatchList.search(entry, closed: closed)
            }
        }
        let fragment = query[query.range(of: "fragment row")!.lowerBound...]
        let text = "query NookWatchedPullRequests(\(declarations.joined(separator: ", "))) {\n\(fields.joined(separator: "\n"))\n}\n\(fragment)"
        return (try? JSONSerialization.data(withJSONObject: ["query": text, "variables": variables])) ?? Data()
    }

    /// The watched pull requests, open ones first and each newest first, every one once; and the entries GitHub would
    /// not search (the alias came back empty). Throws when the request failed as a whole.
    static func parseWatched(_ data: Data, entries: [String]) throws -> (items: [PullRequestItem], unreadable: [String]) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw NookError("GitHub returned an unexpected response.")
        }
        guard let payload = root["data"] as? [String: Any] else { throw failure(root) }
        var open: [PullRequestItem] = []
        var closed: [PullRequestItem] = []
        var unreadable: [String] = []
        for (index, entry) in entries.enumerated() {
            guard payload[alias(index, closed: false)] is [String: Any] else { unreadable.append(entry); continue }
            open += rows(payload[alias(index, closed: false)])
            closed += rows(payload[alias(index, closed: true)])
        }
        let newest: (PullRequestItem, PullRequestItem) -> Bool = { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
        var seen = Set<String>()
        let items = (open.sorted(by: newest) + closed.sorted(by: newest)).filter { seen.insert($0.id).inserted }
        return (items, unreadable)
    }

    /// GitHub's own message for a query that failed as a whole. One that ran out of time is worth asking again.
    static func failure(_ root: [String: Any]) -> NookError {
        let message = ((root["errors"] as? [[String: Any]])?.first?["message"] as? String) ?? "GitHub returned no data."
        let timedOut = message.localizedCaseInsensitiveContains("timeout") || message.localizedCaseInsensitiveContains("something went wrong")
        return NookError("GitHub: \(message)", kind: timedOut ? .network : .other)
    }

    private static func alias(_ index: Int, closed: Bool) -> String { "w\(index)" + (closed ? "Closed" : "") }

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
