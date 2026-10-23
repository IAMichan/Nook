import Foundation

/// The order a pull request's files read best in: the source files first, each one
/// followed by its tests; then tests without a source file in the change; then documentation; then generated files
/// (lockfiles, snapshots, build output, vendored and minified code), which nobody reads line by line.
enum PullRequestFileOrder {
    enum Kind: Int, Comparable, Sendable {
        case source, test, docs, generated
        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private static let lockfiles: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock", "cargo.lock", "gemfile.lock",
        "podfile.lock", "composer.lock", "poetry.lock", "uv.lock", "go.sum", "package.resolved", "pipfile.lock", "flake.lock",
    ]
    private static let generatedFolders = ["dist/", "build/", "vendor/", "node_modules/", "__snapshots__/", ".next/", "generated/", "gen/"]

    static func kind(_ path: String) -> Kind {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        let folders = "/" + lower
        if lockfiles.contains(name) || name.contains(".min.") || name.hasSuffix(".snap") || name.hasSuffix(".pb.go")
            || name.hasSuffix(".generated.swift") || name.hasSuffix(".g.dart")
            || generatedFolders.contains(where: { folders.contains("/" + $0) }) {
            return .generated
        }
        if isTest(lower) { return .test }
        if name.hasSuffix(".md") || name.hasSuffix(".mdx") || name.hasSuffix(".rst") || name.hasSuffix(".txt") || folders.contains("/docs/") {
            return .docs
        }
        return .source
    }

    static func isTest(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        return ("/" + lower).contains("/tests/") || ("/" + lower).contains("/test/") || ("/" + lower).contains("/__tests__/")
            || ("/" + lower).contains("/spec/")
            || stem.hasSuffix("tests") || stem.hasSuffix("test") || stem.hasSuffix("_spec") || stem.hasSuffix(".spec")
            || stem.hasPrefix("test_") || stem.hasSuffix(".test")
    }

    /// The name a test is about: `AppModelTests.swift` → `appmodel`, `parser.test.ts` → `parser`, `test_util.py` → `util`.
    static func subject(_ path: String) -> String {
        var stem = ((path.lowercased() as NSString).lastPathComponent as NSString).deletingPathExtension
        for suffix in [".test", ".spec", "_spec", "_test", "tests", "test"] where stem.hasSuffix(suffix) && stem.count > suffix.count {
            stem = String(stem.dropLast(suffix.count))
            break
        }
        if stem.hasPrefix("test_") { stem = String(stem.dropFirst(5)) }
        return stem
    }

    /// The paths in reading order.
    static func ordered(_ paths: [String]) -> [String] {
        let sources = paths.filter { kind($0) == .source }.sorted { $0.lowercased() < $1.lowercased() }
        var tests = paths.filter { kind($0) == .test }.sorted { $0.lowercased() < $1.lowercased() }
        var result: [String] = []
        for source in sources {
            result.append(source)
            let name = subject(source)
            let matching = tests.filter { subject($0) == name }
            result += matching
            tests.removeAll { matching.contains($0) }
        }
        result += tests
        result += paths.filter { kind($0) == .docs }.sorted { $0.lowercased() < $1.lowercased() }
        result += paths.filter { kind($0) == .generated }.sorted { $0.lowercased() < $1.lowercased() }
        return result
    }
}
