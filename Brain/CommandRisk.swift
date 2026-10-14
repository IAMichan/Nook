import Foundation

struct CommandAssessment {
    enum Level { case safe, review, danger }
    var level: Level
    var title: String
    var note: String
}

/// Rough assessment of a shell command an agent wants to run. This is a safety net, not a guarantee:
/// anything that is not clearly benign requires your review.
enum CommandRisk {
    private static let safeCommands: Set<String> = [
        "ls", "pwd", "cat", "head", "tail", "wc", "echo", "grep", "rg", "which", "date",
        "whoami", "tree", "file", "stat", "du", "df", "uname", "printenv"
    ]
    private static let safeGit: Set<String> = ["status", "diff", "log", "branch", "show", "remote", "rev-parse", "ls-files"]
    private static let shellMeta: [Character] = [";", "|", "&", ">", "<", "`", "$", "\n", "(", ")"]

    private static let dangerPatterns: [String] = [
        "sudo ", "rm -rf /", "rm -rf ~", "rm -rf *", "rm -fr /", "| sh", "| bash", "| zsh",
        "mkfs", "dd if=", "dd of=", ":(){", "chmod -r 777", "git push --force", "git push -f",
        "git reset --hard", "diskutil erase", "> /dev/", "launchctl unload", "defaults delete"
    ]

    static func assess(_ command: String) -> CommandAssessment {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if dangerPatterns.contains(where: { lower.contains($0) }) {
            return CommandAssessment(
                level: .danger,
                title: "This command is risky. Are you sure?",
                note: "May irreversibly alter files or system settings"
            )
        }

        if isSimpleReadOnly(trimmed) {
            return CommandAssessment(level: .safe, title: "", note: "")
        }

        let note: String
        if lower.contains("install") || lower.contains(" add ") {
            note = "Installs packages · usually reversible"
        } else if lower.hasPrefix("rm ") || lower.contains(" rm ") {
            note = "Deletes files"
        } else if lower.contains("git push") {
            note = "Pushes changes online"
        } else if lower.contains("curl") || lower.contains("wget") {
            note = "Downloads something from the internet"
        } else {
            note = "Runs a command on your Mac · please review"
        }
        return CommandAssessment(level: .review, title: "", note: note)
    }

    private static func isSimpleReadOnly(_ command: String) -> Bool {
        guard !command.isEmpty, !command.contains(where: { shellMeta.contains($0) }) else { return false }
        let words = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = words.first else { return false }
        if first == "git" {
            return words.count >= 2 && safeGit.contains(words[1])
        }
        if first == "find" {
            return !words.contains("-delete") && !words.contains("-exec") && !words.contains("-execdir")
        }
        return safeCommands.contains(first)
    }
}
