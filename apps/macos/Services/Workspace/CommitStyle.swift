import Foundation

/// How Nook writes a commit message and a pull request (Settings › Workspace), in one of these styles:
/// its own concise style, Conventional Commits, the style the repository already uses (read from its recent commits),
/// or your own instructions.
enum CommitStyle: String, CaseIterable, Identifiable, Sendable {
    case standard
    case conventional
    case repository
    case custom

    var id: String { rawValue }

    static let defaultsKey = "ws.commitStyle"
    static let instructionsKey = "ws.commitInstructions"

    /// Extra rules for the commit message prompt. `recentSubjects` are the repository's latest commit subjects (used by
    /// `.repository`); `instructions` your own (used by `.custom`).
    func commitRules(recentSubjects: [String], instructions: String) -> [String] {
        switch self {
        case .standard:
            return []
        case .conventional:
            return ["- use Conventional Commits for the subject (type(scope): summary); prefer the narrowest accurate type "
                    + "(feat, fix, refactor, docs, test, chore, perf, build, ci, style) and add a scope only when it is obvious from the diff"]
        case .repository:
            let examples = Self.examples(recentSubjects)
            guard !examples.isEmpty else { return [] }
            return ["- follow the style of the repository's recent commit subjects below (prefixes, casing, length, tense), "
                    + "but never copy their content", "", "Recent commit subjects:"] + examples.map { "- " + $0 }
        case .custom:
            let text = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return ["- follow these instructions from the user where they do not conflict with the rules above:", String(text.prefix(2_000))]
        }
    }

    /// Extra rules for the pull request prompt.
    func pullRequestRules(recentSubjects: [String], instructions: String) -> [String] {
        switch self {
        case .standard:
            return []
        case .conventional:
            return ["- do not force Conventional Commit syntax into the title unless the commits already use it"]
        case .repository:
            return Self.examples(recentSubjects).isEmpty ? [] : ["- follow the repository's established title style, as its commits show"]
        case .custom:
            return commitRules(recentSubjects: recentSubjects, instructions: instructions)
        }
    }

    /// Up to 15 distinct subjects, without merge commits and reverts, which say nothing about the style.
    static func examples(_ subjects: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in subjects where result.count < 15 {
            let subject = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subject.isEmpty, !subject.hasPrefix("Merge "), !subject.hasPrefix("Revert \""), seen.insert(subject).inserted else { continue }
            result.append(String(subject.prefix(120)))
        }
        return result
    }
}
