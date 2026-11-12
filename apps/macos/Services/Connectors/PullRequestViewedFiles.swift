import Foundation

/// The files of a pull request you marked as viewed, as GitHub keeps them: each mark holds the file's revision
/// at the moment you marked it, so a push that changes the file shows it as not viewed again, while untouched files stay
/// ticked. Kept on this Mac, for the 200 pull requests marked most recently.
///
/// On a forge that keeps a viewed state of its own (GitHub's "Viewed" checkbox), the marks follow it: what the forge says
/// on a read wins (`reconcile`), a toggle here is written through (`PullRequestViewedSync`), and a toggle the forge did
/// not take (offline, no access) stays here as `unsynced` until a later read sees it there or writes it again.
struct PullRequestViewedFiles: Codable, Equatable, Sendable {
    /// A mark: the revision when marked ("" a removed file, nil when the host gave none), and when.
    struct Mark: Codable, Equatable, Sendable {
        var revision: String?
        var at: Date
    }

    static let defaultsKey = "agents.pr.viewedFiles"
    static let limit = 200

    /// "owner/repo#12" → path → mark.
    private(set) var marks: [String: [String: Mark]] = [:]
    /// "owner/repo#12" → path → the state you gave it here that the forge has not confirmed yet (true: viewed).
    private(set) var unsynced: [String: [String: Bool]] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey { case marks, unsynced }

    /// Marks saved before the forge sync have no `unsynced`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        marks = try container.decodeIfPresent([String: [String: Mark]].self, forKey: .marks) ?? [:]
        unsynced = try container.decodeIfPresent([String: [String: Bool]].self, forKey: .unsynced) ?? [:]
    }

    static func key(repo: String, number: Int) -> String { "\(repo.lowercased())#\(number)" }

    /// Viewed when marked and the file is still the revision it was marked at. A mark without a revision, or a file
    /// without one now, cannot tell a change, so the mark holds.
    func isViewed(_ file: PullRequestFile, in pullRequest: String) -> Bool {
        guard let mark = marks[pullRequest]?[file.path] else { return false }
        guard let then = mark.revision, let now = file.revision else { return true }
        return then == now
    }

    enum Status: Equatable, Sendable { case unviewed, viewed, changed }

    /// Viewed, not viewed, or changed (marked viewed, then pushed to since).
    func status(_ file: PullRequestFile, in pullRequest: String) -> Status {
        guard marks[pullRequest]?[file.path] != nil else { return .unviewed }
        return isViewed(file, in: pullRequest) ? .viewed : .changed
    }

    func viewedCount(_ files: [PullRequestFile], in pullRequest: String) -> Int {
        files.filter { isViewed($0, in: pullRequest) }.count
    }

    mutating func setViewed(_ viewed: Bool, file: PullRequestFile, in pullRequest: String, now: Date = Date()) {
        if viewed {
            marks[pullRequest, default: [:]][file.path] = Mark(revision: file.revision, at: now)
        } else {
            marks[pullRequest]?[file.path] = nil
            if marks[pullRequest]?.isEmpty == true { marks[pullRequest] = nil }
        }
        trim()
    }

    // MARK: The forge's own state

    /// A toggle made here that still has to reach the forge.
    mutating func setUnsynced(_ viewed: Bool, path: String, in pullRequest: String) {
        unsynced[pullRequest, default: [:]][path] = viewed
    }

    /// The forge took the toggle: it no longer waits. Only while the waiting state is still `viewed`, so the answer to an
    /// older toggle cannot clear a newer one.
    mutating func markSynced(_ viewed: Bool, path: String, in pullRequest: String) {
        guard unsynced[pullRequest]?[path] == viewed else { return }
        unsynced[pullRequest]?[path] = nil
        if unsynced[pullRequest]?.isEmpty == true { unsynced[pullRequest] = nil }
    }

    /// Takes the forge's viewed state of `files` after a read. The forge wins, except for a toggle made here that it has
    /// not confirmed yet: that one stays as you left it and is returned, to be written again. A waiting toggle the forge
    /// now shows no longer waits. A file the forge said nothing about keeps its mark.
    ///
    /// - viewed: marked at the file's current revision.
    /// - changed (GitHub's DISMISSED: viewed, then pushed to): a mark that no longer matches, so it reads as changed.
    /// - unviewed: no mark.
    @discardableResult
    mutating func reconcile(_ remote: [String: PullRequestFileViewedState], files: [PullRequestFile], in pullRequest: String,
                            now: Date = Date()) -> [(path: String, viewed: Bool)] {
        var retry: [(path: String, viewed: Bool)] = []
        for file in files {
            guard let state = remote[file.path] else { continue }
            if let wanted = unsynced[pullRequest]?[file.path] {
                if wanted == (state == .viewed) {
                    markSynced(wanted, path: file.path, in: pullRequest)
                } else {
                    retry.append((file.path, wanted))
                }
                continue
            }
            let mark = marks[pullRequest]?[file.path]
            switch state {
            case .viewed:
                if mark == nil || mark?.revision != file.revision {
                    marks[pullRequest, default: [:]][file.path] = Mark(revision: file.revision, at: mark?.at ?? now)
                }
            case .changed:
                if status(file, in: pullRequest) != .changed {
                    marks[pullRequest, default: [:]][file.path] = Mark(revision: Self.dismissedRevision, at: mark?.at ?? now)
                }
            case .unviewed:
                marks[pullRequest]?[file.path] = nil
                if marks[pullRequest]?.isEmpty == true { marks[pullRequest] = nil }
            }
        }
        trim()
        return retry
    }

    /// The revision a mark holds when the forge says the file changed since it was viewed but not from which revision:
    /// never a real blob id, so the mark reads as changed.
    static let dismissedRevision = "dismissed"

    /// Marks of files the pull request no longer has are dropped, so a file that comes back is not viewed by itself.
    mutating func prune(_ pullRequest: String, keeping files: [PullRequestFile]) {
        guard var list = marks[pullRequest] else { return }
        let paths = Set(files.map(\.path))
        list = list.filter { paths.contains($0.key) }
        marks[pullRequest] = list.isEmpty ? nil : list
    }

    private mutating func trim() {
        guard marks.count > Self.limit else { return }
        let newest = marks.mapValues { $0.values.map(\.at).max() ?? .distantPast }
        let kept = Set(newest.sorted { $0.value > $1.value }.prefix(Self.limit).map(\.key))
        let dropped = Set(marks.keys).subtracting(kept)
        marks = marks.filter { kept.contains($0.key) }
        // A pull request that lost its marks loses what waited for its forge too.
        unsynced = unsynced.filter { !dropped.contains($0.key) }
    }

    /// The marks as last loaded or saved in this run. A pull request page asks for them each time SwiftUI makes the
    /// page again (on every redraw of the list beside it, every frame of a side panel drag), and decoding them from
    /// UserDefaults each time made those frames stutter.
    private nonisolated(unsafe) static var kept: PullRequestViewedFiles?

    static func load(defaults: UserDefaults = .standard) -> PullRequestViewedFiles {
        if defaults === UserDefaults.standard, let kept { return kept }
        let loaded = defaults.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode(PullRequestViewedFiles.self, from: $0) } ?? PullRequestViewedFiles()
        if defaults === UserDefaults.standard { kept = loaded }
        return loaded
    }

    func save(defaults: UserDefaults = .standard) {
        if defaults === UserDefaults.standard { Self.kept = self }
        defaults.setEncoded(self, forKey: Self.defaultsKey)
    }
}

/// A file's viewed state as a forge keeps it for the signed-in user.
enum PullRequestFileViewedState: String, Equatable, Sendable {
    case viewed
    case unviewed
    /// Viewed, then changed by a push (GitHub's DISMISSED).
    case changed

    /// GitHub's `FileViewedState`; nil for a value it may add later.
    init?(gitHub value: String) {
        switch value {
        case "VIEWED": self = .viewed
        case "UNVIEWED": self = .unviewed
        case "DISMISSED": self = .changed
        default: return nil
        }
    }
}

/// GitHub's GraphQL for the "Viewed" checkbox of a pull request's files: the state of every file for the signed-in user
/// (`viewerViewedState`, 100 files a page), and `markFileAsViewed` / `unmarkFileAsViewed` by the pull request's node id
/// and the file's path. REST has neither. Foundation only, so the bodies and the parsing are tested on their own.
enum PullRequestViewedGraphQL {
    static let filesQuery = """
    query NookViewedFiles($owner: String!, $name: String!, $number: Int!, $after: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          files(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { path viewerViewedState } }
        }
      }
    }
    """
    static let markMutation =
        "mutation NookMarkViewed($id: ID!, $path: String!) { markFileAsViewed(input: {pullRequestId: $id, path: $path}) { clientMutationId } }"
    static let unmarkMutation =
        "mutation NookUnmarkViewed($id: ID!, $path: String!) { unmarkFileAsViewed(input: {pullRequestId: $id, path: $path}) { clientMutationId } }"
    /// GitHub lists at most 3000 files of a pull request, as many as the REST files list Nook reads.
    static let pageLimit = 30

    /// The request for one page of files; `after` is the cursor of the page before. Nil for a repository that is not
    /// "owner/name".
    static func filesBody(repo: String, number: Int, after: String? = nil) -> Data? {
        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        var variables: [String: Any] = ["owner": parts[0], "name": parts[1], "number": number]
        if let after { variables["after"] = after }
        return try? JSONSerialization.data(withJSONObject: ["query": filesQuery, "variables": variables], options: [.sortedKeys])
    }

    struct Page: Equatable {
        var states: [String: PullRequestFileViewedState]
        /// The cursor of the next page; nil on the last.
        var next: String?
    }

    /// One page of the answer; nil when GitHub answered with errors or without the pull request's files.
    static func parse(_ answer: Any?) -> Page? {
        guard let object = answer as? [String: Any], PullRequestAction.graphQLError(object) == nil,
              let data = object["data"] as? [String: Any],
              let pull = (data["repository"] as? [String: Any])?["pullRequest"] as? [String: Any],
              let files = pull["files"] as? [String: Any] else { return nil }
        var states: [String: PullRequestFileViewedState] = [:]
        for node in (files["nodes"] as? [Any]) ?? [] {
            guard let node = node as? [String: Any], let path = node["path"] as? String,
                  let state = (node["viewerViewedState"] as? String).flatMap(PullRequestFileViewedState.init(gitHub:)) else { continue }
            states[path] = state
        }
        let info = files["pageInfo"] as? [String: Any]
        let next = (info?["hasNextPage"] as? Bool) == true ? info?["endCursor"] as? String : nil
        return Page(states: states, next: next)
    }

    /// The mutation that ticks or clears the file's checkbox; nil without a node id or a path.
    static func setViewedBody(nodeID: String, path: String, viewed: Bool) -> Data? {
        guard !nodeID.isEmpty, !path.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: [
            "query": viewed ? markMutation : unmarkMutation, "variables": ["id": nodeID, "path": path],
        ], options: [.sortedKeys])
    }
}
