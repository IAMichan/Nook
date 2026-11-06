import Foundation

/// A pull request's changed lines by the kind of file they are in, so you see how much of a change is logic. Worked out
/// from the paths alone, by common naming conventions.
struct PullRequestChangeBreakdown: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case code, tests, mocks, generated, docs }

    struct Lines: Equatable, Sendable {
        var additions = 0
        var deletions = 0
        var isEmpty: Bool { additions == 0 && deletions == 0 }
    }

    private(set) var lines: [Kind: Lines] = [:]

    subscript(_ kind: Kind) -> Lines { lines[kind] ?? Lines() }

    /// The kinds that have changed lines, in reading order.
    var kinds: [Kind] { Kind.allCases.filter { !self[$0].isEmpty } }

    init(files: [(path: String, additions: Int, deletions: Int)]) {
        for file in files {
            var bucket = self[Self.kind(of: file.path)]
            bucket.additions += file.additions
            bucket.deletions += file.deletions
            lines[Self.kind(of: file.path)] = bucket
        }
    }

    private static let generatedFiles: Set<String> = [
        "bun.lock", "bun.lockb", "cargo.lock", "composer.lock", "deno.lock", "flake.lock", "gemfile.lock", "go.sum",
        "gradle.lockfile", "mix.lock", "npm-shrinkwrap.json", "package-lock.json", "packages.lock.json", "package.resolved",
        "pipfile.lock", "pnpm-lock.yaml", "podfile.lock", "poetry.lock", "pubspec.lock", "uv.lock", "yarn.lock",
    ]
    private static let generatedDirectories: Set<String> = ["__generated__", "_generated", "generated"]
    private static let mockDirectories: Set<String> = [
        "__fixtures__", "__mocks__", "__snapshots__", "fakes", "fixture", "fixtures", "mock", "mocks", "stubs", "testdata",
    ]
    private static let testDirectories: Set<String> = ["__tests__", "__test__", "cypress", "e2e", "evals", "spec", "specs", "test", "tests"]

    private static func matches(_ text: String, _ pattern: String, caseInsensitive: Bool = false) -> Bool {
        text.range(of: pattern, options: caseInsensitive ? [.regularExpression, .caseInsensitive] : .regularExpression) != nil
    }

    static func kind(of path: String) -> Kind {
        var parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let name = parts.popLast() ?? ""
        let directories = Set(parts.map { $0.lowercased() })
        func inside(_ names: Set<String>) -> Bool { !directories.isDisjoint(with: names) }
        if generatedFiles.contains(name.lowercased()) || inside(generatedDirectories)
            || matches(name, #"(\.generated\.|\.gen\.|\.g\.dart$|\.pb\.go$|_pb2(_grpc)?\.py$|\.pb\.(cc|h)$|\.min\.(js|css)$|\.(js|css)\.map$)"#) {
            return .generated
        }
        if inside(mockDirectories) || matches(name, #"(\.snap$|\.(mocks?|fixtures?|stubs?|fakes?)\.[^.]+$|^(mocks?|fixtures?|stubs?|fakes?)([-_.A-Z]|$))"#) {
            return .mocks
        }
        // Case-sensitive for class names: `FooTest.java` is a test class, `Latest.java` is not.
        if inside(testDirectories) || matches(name, #"(Tests?|Spec)\.(java|kt|kts|scala|groovy|cs|php|swift|m)$"#)
            || matches(name, #"(\.(test|spec|e2e|eval)\.[^.]+$|_(test|spec)\.[^.]+$|^test_.+\.py$|^conftest\.py$|^(vitest|jest)\.setup\.[^.]+$)"#, caseInsensitive: true) {
            return .tests
        }
        // Plain-text files that tools read as config or input are not prose.
        if matches(name, #"\.(md|mdx|markdown|rst|adoc|txt)$"#, caseInsensitive: true),
           !matches(name, #"^(requirements.*|constraints.*|CMakeLists|robots|llms)\.txt$"#, caseInsensitive: true) {
            return .docs
        }
        return .code
    }
}

/// The one thing to do about a pull request from the compact row beside a session: its conflict first, a draft next, then
/// failing checks, and a merge once nothing stands in the way. Nothing while checks run.
enum PullRequestRowAction: Equatable, Sendable {
    case resolve, ready, fix, merge

    static func pick(open: Bool, conflicted: Bool, draft: Bool, checks: PullRequestItem.CI) -> PullRequestRowAction? {
        guard open else { return nil }
        if conflicted { return .resolve }
        if draft { return .ready }
        switch checks {
        case .failing: return .fix
        case .pending: return nil
        case .passing, .unknown: return .merge
        }
    }
}

/// What to fetch to have a pull request here, per forge: its own branch when it lives in the repository, else the ref the
/// forge keeps for it, into a local branch named for the pull request.
struct PullRequestCheckoutPlan: Equatable, Sendable {
    let repository: String
    let number: Int
    /// What `git fetch origin` asks for.
    let ref: String
    /// The local branch.
    let branch: String
    /// Only for a branch of the repository itself: pushing goes back to the pull request.
    let tracksOrigin: Bool

    /// Where a machine keeps the fetched head, as the base of its session's own branch.
    var remoteRef: String { "refs/remotes/nook-pr/\(number)" }

    init(host: SourceControlHost, repository: String, number: Int, headBranch: String, fork: Bool) {
        self.repository = repository
        self.number = number
        if !fork, !headBranch.isEmpty {
            ref = headBranch
            branch = headBranch
            tracksOrigin = true
            return
        }
        tracksOrigin = false
        branch = "pr-\(number)"
        switch host {
        case .gitlab: ref = "merge-requests/\(number)/head"
        case .azureDevOps: ref = "pull/\(number)/merge"
        default: ref = "pull/\(number)/head"
        }
    }
}
