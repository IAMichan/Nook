import Foundation

// The parts of updating Nook that need nothing but Foundation: where the running build came from, what changed on main
// since, whether the checkout can take the update, and how to read xcodebuild's output. `AppUpdater` drives them.

/// Where the running build of Nook came from, as the build wrote it into Info.plist (project.yml and
/// Config/stamp-source.sh). Nil for a build that was not made from a git checkout: Nook then offers no updates.
struct BuildSource: Equatable, Sendable {
    /// The full commit the build was made from.
    let commit: String
    /// The branch that was checked out, nil when detached.
    let branch: String?
    /// apps/macos in the checkout (SRCROOT), where project.yml lives.
    let projectDirectory: String
    /// Debug or Release: an update is built the same way.
    let configuration: String
    /// The Xcode that built this app, so the update uses the same one even when `xcode-select` points elsewhere.
    let developerDirectory: String?

    init?(info: [String: Any]) {
        guard let commit = info["NookSourceCommit"] as? String, Self.isCommit(commit),
              let directory = Self.value(info["NookSourceRoot"]) else { return nil }
        self.commit = commit.lowercased()
        self.branch = Self.value(info["NookSourceBranch"])
        self.projectDirectory = directory
        self.configuration = Self.value(info["NookBuildConfiguration"]) ?? "Debug"
        self.developerDirectory = Self.value(info["NookDeveloperDir"])
    }

    var shortCommit: String { String(commit.prefix(7)) }

    static func isCommit(_ text: String) -> Bool {
        text.count == 40 && text.allSatisfy(\.isHexDigit)
    }

    /// A filled-in value: empty strings and settings Xcode left unexpanded ("$(DEVELOPER_DIR)") count as missing.
    private static func value(_ any: Any?) -> String? {
        guard let text = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, !text.contains("$(") else { return nil }
        return text
    }
}

/// One change on main that the running build does not have yet: a merged pull request, or a commit made on main itself.
struct IncomingChange: Equatable, Codable, Sendable, Identifiable {
    var id: String { sha }
    let sha: String
    let title: String
    /// The pull request it merged, when the commit says so.
    let pullRequest: Int?
    let author: String
    let date: Date

    var shortSHA: String { String(sha.prefix(7)) }
}

enum UpdateLog {
    /// `git log --format`: fields split by the unit separator, commits by the record separator, so a body with any text
    /// in it can never be read as the next field.
    static let format = "%H%x1f%an%x1f%at%x1f%s%x1f%b%x1e"

    static func parse(_ output: String) -> [IncomingChange] {
        output.split(separator: "\u{1e}").compactMap { record in
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4 else { return nil }
            let sha = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard BuildSource.isCommit(sha) else { return nil }
            let body = fields.count > 4 ? fields[4] : ""
            let described = describe(subject: fields[3], body: body)
            return IncomingChange(sha: sha, title: described.title, pullRequest: described.pullRequest,
                                  author: fields[1].trimmingCharacters(in: .whitespacesAndNewlines),
                                  date: Date(timeIntervalSince1970: TimeInterval(fields[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0))
        }
    }

    private static let mergeCommit = try! NSRegularExpression(pattern: #"^Merge pull request #(\d+) from (\S+)"#)
    private static let squashCommit = try! NSRegularExpression(pattern: #"^(.+?)\s*\(#(\d+)\)$"#)

    /// What a commit on main is about. GitHub's merge commit says "Merge pull request #12 from owner/branch" with the
    /// pull request's title as the first line of its body; a squash merge ends its subject with "(#12)".
    static func describe(subject rawSubject: String, body: String) -> (title: String, pullRequest: Int?) {
        let subject = rawSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(subject.startIndex..., in: subject)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String {
            Range(match.range(at: index), in: subject).map { String(subject[$0]) } ?? ""
        }
        if let match = mergeCommit.firstMatch(in: subject, range: range) {
            let firstLine = body.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            return (firstLine ?? branchTitle(group(match, 2)), Int(group(match, 1)))
        }
        if let match = squashCommit.firstMatch(in: subject, range: range) {
            return (group(match, 1), Int(group(match, 2)))
        }
        return (subject, nil)
    }

    /// "owner/feature/instant-autocomplete" → "instant autocomplete": the best title a merge without a body has.
    private static func branchTitle(_ reference: String) -> String {
        let last = reference.split(separator: "/").last.map(String.init) ?? reference
        return last.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }
}

/// The repository on GitHub that `origin` points to, for links to the comparison and the pull requests.
struct GitHubRepository: Equatable, Sendable {
    let owner: String
    let name: String

    /// https://github.com/owner/repo(.git), git@github.com:owner/repo.git and ssh://git@github.com/owner/repo.
    init?(remoteURL: String) {
        var text = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "ssh://", "git://"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if let at = text.firstIndex(of: "@"), text[..<at].allSatisfy({ $0 != "/" }) { text = String(text[text.index(after: at)...]) }
        guard text.lowercased().hasPrefix("github.com") else { return nil }
        text = String(text.dropFirst("github.com".count))
        guard text.first == ":" || text.first == "/" else { return nil }
        if text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix(".git") { text.removeLast(4) }
        let parts = text.dropFirst().split(separator: "/").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        owner = parts[0]
        name = parts[1]
    }

    var url: URL? { URL(string: "https://github.com/\(owner)/\(name)") }
    func compare(_ from: String, _ to: String) -> URL? { URL(string: "https://github.com/\(owner)/\(name)/compare/\(from)...\(to)") }
    func pullRequest(_ number: Int) -> URL? { URL(string: "https://github.com/\(owner)/\(name)/pull/\(number)") }
}

/// The local checkout the update goes into, read right after fetching.
struct UpdateCheckout: Equatable, Sendable {
    /// The checked-out branch, nil when detached.
    let branch: String?
    /// The branch updates come from (origin's default branch, usually main).
    let updateBranch: String
    /// `git status --porcelain` lines: uncommitted and untracked files.
    let changedFiles: [String]
    /// Commits on the checkout that main does not have: a fast-forward is impossible then.
    let localCommits: Int
    /// The checkout already sits at the new main (pulled by hand, not rebuilt yet): only a build is needed.
    let atTarget: Bool
}

/// Whether the update can go in, and what stands in the way when not.
enum UpdatePreflight: Equatable, Sendable {
    case ready
    /// Uncommitted changes: the update can set them aside (git stash) and put them back, but only when you say so.
    case needsStash(files: Int)
    case blocked(UpdateBlocker)

    static func check(_ checkout: UpdateCheckout) -> UpdatePreflight {
        guard let branch = checkout.branch else { return .blocked(.detached) }
        guard branch == checkout.updateBranch else { return .blocked(.otherBranch(branch)) }
        if checkout.localCommits > 0, !checkout.atTarget { return .blocked(.diverged(checkout.localCommits)) }
        if !checkout.changedFiles.isEmpty, !checkout.atTarget { return .needsStash(files: checkout.changedFiles.count) }
        return .ready
    }
}

enum UpdateBlocker: Equatable, Sendable {
    /// The checkout is on another branch; switching it is yours to do.
    case otherBranch(String)
    case detached
    /// Local commits on main that origin does not have.
    case diverged(Int)
}

/// The steps of an install, in order.
enum UpdateStep: Int, CaseIterable, Comparable, Sendable {
    case fetch, merge, generate, build, install, restart

    static func < (lhs: UpdateStep, rhs: UpdateStep) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What xcodebuild is doing, read from one line of its output.
enum BuildActivity: Equatable, Sendable {
    case resolvingPackages
    case compiling(String)
    case linking
    case copying
    case signing

    static func parse(_ line: String) -> BuildActivity? {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("Resolve Package Graph") || text.hasPrefix("Fetching from") || text.hasPrefix("Resolved source packages") {
            return .resolvingPackages
        }
        for prefix in ["SwiftCompile ", "CompileSwift ", "CompileC "] where text.hasPrefix(prefix) {
            // "SwiftCompile normal arm64 /path/to/File.swift (in target 'Nook' from project 'Nook')"
            let path = text.split(separator: " ").first { $0.hasPrefix("/") && ($0.hasSuffix(".swift") || $0.hasSuffix(".c") || $0.hasSuffix(".m") || $0.hasSuffix(".cpp")) }
            return path.map { BuildActivity.compiling(URL(fileURLWithPath: String($0)).lastPathComponent) }
        }
        if text.hasPrefix("Ld ") { return .linking }
        if text.hasPrefix("CpResource ") || text.hasPrefix("CopySwiftLibs ") || text.hasPrefix("ProcessInfoPlistFile ") { return .copying }
        if text.hasPrefix("CodeSign ") { return .signing }
        return nil
    }

    /// The compiler errors in a build log, without repeats, as "File.swift:12: message".
    static func errors(in log: String, limit: Int = 6) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in log.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let message: String
            if let prefix = ["xcodebuild: error: ", "error: "].first(where: { line.hasPrefix($0) }) {
                message = String(line.dropFirst(prefix.count))
            } else if let range = line.range(of: ": error: ") {
                let location = line[..<range.lowerBound].split(separator: "/").last.map(String.init) ?? ""
                // "File.swift:12:5" → "File.swift:12"
                let parts = location.split(separator: ":")
                let place = parts.count >= 2 ? "\(parts[0]):\(parts[1])" : location
                message = place.isEmpty ? String(line[range.upperBound...]) : "\(place): \(line[range.upperBound...])"
            } else {
                continue
            }
            guard seen.insert(message).inserted else { continue }
            result.append(message)
            if result.count == limit { break }
        }
        return result
    }
}

enum BuildProduct {
    /// The app `xcodebuild -showBuildSettings -json` says the Nook target builds: TARGET_BUILD_DIR/FULL_PRODUCT_NAME.
    static func path(fromBuildSettings data: Data, target: String = "Nook") -> String? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let entry = entries.first { ($0["target"] as? String) == target } ?? entries.first
        guard let settings = entry?["buildSettings"] as? [String: Any],
              let directory = settings["TARGET_BUILD_DIR"] as? String, !directory.isEmpty,
              let name = settings["FULL_PRODUCT_NAME"] as? String, !name.isEmpty else { return nil }
        return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name).path
    }
}

/// Starting Nook again once this process is gone: a small shell loop that outlives Nook, waits for its process to end
/// (a minute at most), then opens the app. The pid and the path are arguments, never part of the script text.
enum Relaunch {
    static let script = """
    pid="$1"; app="$2"; n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 300 ]; do sleep 0.2; n=$((n + 1)); done
    /usr/bin/open "$app"
    """

    static func arguments(pid: Int32, appPath: String) -> [String] {
        ["-c", script, "nook-relaunch", String(pid), appPath]
    }
}

/// Environment for git, xcodegen and xcodebuild started by Nook: the places Homebrew and Mint install tools, without
/// what Xcode injects into an app it launches for debugging (DYLD_ and friends would follow xcodebuild into every tool).
enum UpdateEnvironment {
    static func make(base: [String: String], developerDirectory: String?, home: String) -> [String: String] {
        var env = base.filter { key, _ in
            !(key.hasPrefix("DYLD_") || key.hasPrefix("__XPC_") || key.hasPrefix("__XCODE_") || key == "OS_ACTIVITY_DT_MODE"
              || key == "NSUnbufferedIO" || key == "NOOK_INTERNAL")
        }
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.mint/bin", "\(home)/.local/bin"]
        let existing = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        env["PATH"] = (extra.filter { !existing.contains($0) } + existing).joined(separator: ":")
        if let developerDirectory { env["DEVELOPER_DIR"] = developerDirectory }
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }
}

/// A finished update, kept until the new build has started: it then says what came in.
struct UpdateReceipt: Codable, Equatable, Sendable {
    let from: String
    let to: String
    let changes: [IncomingChange]
    let installedAt: Date
}
