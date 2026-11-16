import Foundation

/// Reading what is typed for "GitHub repository". Foundation only.
enum AddProjectSource {
    /// "owner/repo", "github.com/owner/repo" or a GitHub page as the repository's HTTPS address; nil when it is not one.
    static func githubURL(_ typed: String) -> String? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("https://") || text.hasPrefix("git@") {
            let url = CloneLayout.repositoryURL(fromPage: text)
            return url.contains("github.com") ? url : nil
        }
        for prefix in ["http://", "www.", "github.com/"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ part in
            !part.isEmpty && !part.hasPrefix(".") && part.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        }) else { return nil }
        return "https://github.com/\(parts[0])/\(parts[1]).git"
    }
}
