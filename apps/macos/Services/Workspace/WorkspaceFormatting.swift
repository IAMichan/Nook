import Foundation

/// owner/repo from a GitHub remote (https or ssh).
enum GitHubRemote {
    static func repository(from url: String) -> String? {
        var rest: Substring
        if let range = url.range(of: "github.com/") {
            rest = url[range.upperBound...]
        } else if let range = url.range(of: "github.com:") {
            rest = url[range.upperBound...]
        } else {
            return nil
        }
        if rest.hasSuffix(".git") { rest = rest.dropLast(4) }
        while rest.hasSuffix("/") { rest = rest.dropLast() }
        let parts = rest.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } }) else {
            return nil
        }
        return parts.joined(separator: "/")
    }

    /// GitHub comparison page to open a pull request, pre-filled with the branch.
    static func compareURL(repo: String, base: String, head: String) -> URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))
        guard let base = base.addingPercentEncoding(withAllowedCharacters: allowed),
              let head = head.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://github.com/\(repo)/compare/\(base)...\(head)?expand=1")
    }
}

/// Workspace formatting helpers.
enum AgentPathFormat {
    static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m \(total % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    static func cost(_ usd: Double) -> String {
        CostFormat.short(usd)
    }
}
