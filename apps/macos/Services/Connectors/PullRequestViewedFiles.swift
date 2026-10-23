import Foundation

/// The files of a pull request you marked as viewed, as GitHub keeps them: each mark holds the file's revision
/// at the moment you marked it, so a push that changes the file shows it as not viewed again, while untouched files stay
/// ticked. Kept on this Mac, for the 200 pull requests marked most recently.
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
        let kept = newest.sorted { $0.value > $1.value }.prefix(Self.limit).map(\.key)
        marks = marks.filter { kept.contains($0.key) }
    }

    static func load(defaults: UserDefaults = .standard) -> PullRequestViewedFiles {
        guard let data = defaults.data(forKey: defaultsKey) else { return PullRequestViewedFiles() }
        return (try? JSONDecoder().decode(PullRequestViewedFiles.self, from: data)) ?? PullRequestViewedFiles()
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}
