import Foundation

/// Which forge a git remote lives on: well-known hosts first, then a DNS label or name hint for
/// self-hosted installs, and anything else stays `unknown` instead of being guessed as GitHub.
enum SourceControlHost: Hashable, Sendable, Codable {
    case github, gitlab, bitbucket, gitea, forgejo, azureDevOps, gitcafe
    case unknown(String)

    /// Stable key for storage and for the lead's icon/name lookup.
    var key: String {
        switch self {
        case .github: return "github"
        case .gitlab: return "gitlab"
        case .bitbucket: return "bitbucket"
        case .gitea: return "gitea"
        case .forgejo: return "forgejo"
        case .azureDevOps: return "azure-devops"
        case .gitcafe: return "gitcafe"
        case .unknown(let host): return "unknown:" + host
        }
    }

    init(key: String) {
        switch key {
        case "github": self = .github
        case "gitlab": self = .gitlab
        case "bitbucket": self = .bitbucket
        case "gitea": self = .gitea
        case "forgejo": self = .forgejo
        case "azure-devops": self = .azureDevOps
        case "gitcafe": self = .gitcafe
        default: self = .unknown(key.hasPrefix("unknown:") ? String(key.dropFirst(8)) : key)
        }
    }

    init(from decoder: Decoder) throws {
        self.init(key: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }

    var isUnknown: Bool { if case .unknown = self { return true } else { return false } }

    /// The word used for a change request: GitLab calls it a merge request.
    var usesMergeRequests: Bool { self == .gitlab }

    /// `hostName` is lower case without port.
    static func classify(hostName host: String) -> SourceControlHost {
        let labels = host.split(separator: ".").map(String.init)
        func label(_ name: String) -> Bool { labels.contains(name) || host.contains(name) }
        if host == "git.cafe" || host == "staging.git.cafe" { return .gitcafe }
        if host == "codeberg.org" || label("forgejo") { return .forgejo }
        if label("gitea") { return .gitea }
        if host == "github.com" || host.hasSuffix(".ghe.com") || label("github") { return .github }
        if host == "gitlab.com" || label("gitlab") { return .gitlab }
        // ssh.dev.azure.com and vs-ssh.visualstudio.com are the SSH clone hosts.
        if host == "dev.azure.com" || host.hasSuffix(".dev.azure.com") || host.hasSuffix(".visualstudio.com") { return .azureDevOps }
        if host == "bitbucket.org" || label("bitbucket") { return .bitbucket }
        return .unknown(host)
    }

    static func detect(remoteURL: String) -> RemoteRepository? { RemoteRepository.detect(remoteURL: remoteURL) }
}

/// A repository on a forge, without credentials: nothing here can leak a token into a URL we open.
struct RemoteRepository: Hashable, Sendable {
    var host: SourceControlHost
    /// Lower case, no port.
    var hostName: String
    /// "owner/repo", "a/b/c" for GitLab subgroups, "org/project/_git/repo" for Azure DevOps.
    var path: String
    /// `scheme://host[:port]` of the web UI. SSH remotes say nothing about the web port, so they get https.
    var webOrigin: String

    var segments: [String] { path.split(separator: "/").map(String.init) }
    var name: String { segments.last ?? path }

    /// "owner/repo"; Azure drops the `_git` marker: "org/project/repo".
    var displayName: String { segments.filter { $0 != "_git" }.joined(separator: "/") }

    /// Lower case "host/path": links are matched on this, never on the URL text.
    var key: String { (hostName + "/" + path).lowercased() }

    private static let remoteSchemes: Set<String> = ["http", "https", "ssh", "git", "git+ssh", "ssh+git"]

    static func detect(remoteURL: String) -> RemoteRepository? {
        let text = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var scheme = "https"
        var port: Int?
        var hostRaw: String
        var rawPath: String
        if text.contains("://") {
            guard let c = URLComponents(string: text), let s = c.scheme?.lowercased(), remoteSchemes.contains(s),
                  let h = c.host, !h.isEmpty else { return nil }
            scheme = s
            hostRaw = h
            port = c.port
            rawPath = c.path
        } else {
            // scp-like: [user@]host:path. A bare "C:\dir" has neither a user nor a dot, so it is not a remote.
            guard let colon = text.firstIndex(of: ":") else { return nil }
            let left = String(text[..<colon])
            let right = String(text[text.index(after: colon)...])
            let hasUser = left.contains("@")
            hostRaw = hasUser ? String(left[left.index(after: left.lastIndex(of: "@")!)...]) : left
            guard !hostRaw.isEmpty, !left.contains("/"), hasUser || hostRaw.contains("."),
                  hostRaw.allSatisfy({ $0.isLetter || $0.isNumber || "-._".contains($0) }) else { return nil }
            rawPath = right
        }
        let hostName = hostRaw.lowercased()
        var parts = rawPath.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }
        if let last = parts.last, last.lowercased().hasSuffix(".git") {
            parts[parts.count - 1] = String(last.dropLast(4))
        }
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }

        let host = SourceControlHost.classify(hostName: hostName)
        let web = (scheme == "http" || scheme == "https")
        var origin = (web ? scheme : "https") + "://" + hostName
        if web, let port { origin += ":\(port)" }

        switch host {
        case .azureDevOps:
            guard let normalized = azurePath(hostName: hostName, parts: parts) else { return nil }
            return RemoteRepository(host: host, hostName: "dev.azure.com", path: normalized.joined(separator: "/"),
                                    webOrigin: "https://dev.azure.com")
        case .gitlab:
            guard parts.count >= 2 else { return nil }
        case .unknown:
            guard parts.count >= 2 else { return nil }
        default:
            guard parts.count == 2 else { return nil }
        }
        return RemoteRepository(host: host, hostName: hostName, path: parts.joined(separator: "/"), webOrigin: origin)
    }

    /// Every Azure DevOps spelling folds into `org/project/_git/repo` on dev.azure.com.
    private static func azurePath(hostName: String, parts: [String]) -> [String]? {
        if parts.first == "v3", parts.count == 4, hostName.hasPrefix("ssh.") || hostName.hasPrefix("vs-ssh.") {
            return [parts[1], parts[2], "_git", parts[3]]
        }
        guard let git = parts.firstIndex(of: "_git"), git + 2 == parts.count, git >= 1 else { return nil }
        if hostName.hasSuffix(".visualstudio.com") {
            let org = String(hostName.split(separator: ".")[0])
            var project = Array(parts[..<git])
            if project.first?.lowercased() == "defaultcollection" { project.removeFirst() }
            guard !project.isEmpty else { return nil }
            return [org] + project + ["_git", parts[git + 1]]
        }
        return parts
    }

    // MARK: URLs

    /// Everything but unreserved characters is escaped, so `#`, `&`, `?`, spaces and newlines in a title or branch
    /// can never end a parameter early.
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// A branch name in a path keeps its slashes.
    private static func encodePath(_ value: String) -> String {
        value.split(separator: "/", omittingEmptySubsequences: false).map { encode(String($0)) }.joined(separator: "/")
    }

    private var repoBase: String { webOrigin + "/" + Self.encodePath(path) }

    private func query(_ items: [(String, String?)]) -> String {
        let pairs = items.compactMap { item -> String? in
            guard let value = item.1, !value.isEmpty || item.0 == "expand" else { return nil }
            return Self.encode(item.0) + "=" + Self.encode(value)
        }
        return pairs.isEmpty ? "" : "?" + pairs.joined(separator: "&")
    }

    private func url(_ text: String) -> URL? { URL(string: text) }

    func compareURL(base: String, head: String) -> URL? {
        let b = Self.encodePath(base), h = Self.encodePath(head)
        switch host {
        case .github, .gitea, .forgejo, .gitcafe: return url("\(repoBase)/compare/\(b)...\(h)")
        case .gitlab: return url("\(repoBase)/-/compare/\(b)...\(h)")
        // Bitbucket Cloud separates source and destination with an encoded carriage return.
        case .bitbucket: return url("\(repoBase)/branches/compare/\(Self.encode(head))%0D\(Self.encode(base))")
        case .azureDevOps: return url("\(repoBase)/branchCompare" + query([("baseVersion", "GB" + base), ("targetVersion", "GB" + head)]))
        case .unknown: return nil
        }
    }

    /// Prefilled where the forge supports it. `draft` is only expressible as a title prefix (GitLab "Draft: ",
    /// Gitea/Forgejo "WIP: "); elsewhere the user flips it on the page.
    func newPullRequestURL(base: String, head: String, title: String? = nil, body: String? = nil, draft: Bool = false) -> URL? {
        let b = Self.encodePath(base), h = Self.encodePath(head)
        switch host {
        case .github:
            return url("\(repoBase)/compare/\(b)...\(h)" + query([("expand", "1"), ("title", title), ("body", body)]))
        case .gitlab:
            let t = draft ? title.map { "Draft: " + $0 } : title
            return url("\(repoBase)/-/merge_requests/new" + query([
                ("merge_request[source_branch]", head), ("merge_request[target_branch]", base),
                ("merge_request[title]", t), ("merge_request[description]", body)]))
        case .bitbucket:
            return url("\(repoBase)/pull-requests/new" + query([("source", head), ("dest", base)]))
        case .gitea, .forgejo, .gitcafe:
            let t = draft ? title.map { "WIP: " + $0 } : title
            return url("\(repoBase)/compare/\(b)...\(h)" + query([("title", t), ("body", body)]))
        case .azureDevOps:
            return url("\(repoBase)/pullrequestcreate" + query([("sourceRef", head), ("targetRef", base)]))
        case .unknown:
            return nil
        }
    }

    func pullRequestURL(number: Int) -> URL? {
        guard number > 0 else { return nil }
        switch host {
        case .github: return url("\(repoBase)/pull/\(number)")
        case .gitlab: return url("\(repoBase)/-/merge_requests/\(number)")
        case .bitbucket: return url("\(repoBase)/pull-requests/\(number)")
        case .gitea, .forgejo, .gitcafe: return url("\(repoBase)/pulls/\(number)")
        case .azureDevOps: return url("\(repoBase)/pullrequest/\(number)")
        case .unknown: return nil
        }
    }

    func branchURL(_ branch: String) -> URL? {
        let b = Self.encodePath(branch)
        switch host {
        case .github: return url("\(repoBase)/tree/\(b)")
        case .gitlab: return url("\(repoBase)/-/tree/\(b)")
        case .bitbucket: return url("\(repoBase)/src/\(b)")
        case .gitea, .forgejo, .gitcafe: return url("\(repoBase)/src/branch/\(b)")
        case .azureDevOps: return url("\(repoBase)" + query([("version", "GB" + branch)]))
        case .unknown: return nil
        }
    }
}
