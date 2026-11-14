import Foundation

// Source control rules that do not need git or the UI: when the main checkout may fast-forward its default branch, where
// a clone goes and how it falls back from SSH to HTTPS, what a new GitHub repository may be called, and which commit a
// link in an agent's answer names. Foundation only, so each is tested on its own.

/// Keeps a project's main checkout on the latest default branch: fast-forward only, and only when nothing could be lost.
enum AutoPull {
    /// At most this often per repository: each look fetches the default branch once.
    static let interval: TimeInterval = 15 * 60

    /// Whether any folder can resolve to auto-pull on: the global default, or a project that switches it on itself
    /// (`ProjectSettings.resolve` reads only the string "on" as on). When not, the half-minute tick looks at no path.
    static func enabledAnywhere(global: Bool, overrides: ProjectOverrides) -> Bool {
        global || overrides.byProject.values.contains { $0[ProjectSettingKey.autoPull.raw] == .string("on") }
    }

    struct Facts: Equatable, Sendable {
        /// The branch the main checkout is on; nil when its HEAD is detached.
        var branch: String?
        /// The repository's default branch on its remote ("main").
        var defaultBranch: String?
        /// Tracked files with changes, staged or not.
        var dirty: Bool
        /// A merge, rebase, cherry-pick, revert or bisect is under way.
        var operationInProgress: Bool
        /// A session Nook runs works in this checkout itself (no worktree of its own).
        var sessionWorking: Bool
        /// Commits the local branch has that the remote one does not, and the other way round.
        var ahead: Int
        var behind: Int
    }

    enum Verdict: Equatable, Sendable {
        case fastForward
        case upToDate
        case skip(Reason)
    }

    enum Reason: String, Equatable, Sendable {
        case noDefaultBranch, notOnDefaultBranch, dirty, operationInProgress, sessionWorking, diverged
    }

    /// Never a merge and never a dirty tree: only a clean checkout of the default branch that is strictly behind moves.
    static func decide(_ facts: Facts) -> Verdict {
        guard let target = facts.defaultBranch, !target.isEmpty else { return .skip(.noDefaultBranch) }
        guard facts.branch == target else { return .skip(.notOnDefaultBranch) }
        if facts.operationInProgress { return .skip(.operationInProgress) }
        if facts.sessionWorking { return .skip(.sessionWorking) }
        if facts.dirty { return .skip(.dirty) }
        if facts.ahead > 0 { return facts.behind > 0 ? .skip(.diverged) : .upToDate }
        return facts.behind > 0 ? .fastForward : .upToDate
    }

    /// The files in a git directory that say an operation is under way.
    static let operationMarkers = ["MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG"]

    /// `git rev-list --left-right --count HEAD...origin/main`: "ahead\tbehind".
    static func parseCounts(_ text: String) -> (ahead: Int, behind: Int)? {
        let parts = text.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" }).compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }
}

/// Where a clone goes, and the HTTPS address to try when SSH is refused.
enum CloneLayout {
    /// The parts of a Git address: "github.com", "IAMichan", "nook".
    struct Address: Equatable, Sendable {
        var host: String
        var owner: String
        var name: String
    }

    /// Reads https://, ssh:// and scp-style (`git@host:owner/repo.git`) addresses. Nil for anything else.
    static func parse(_ url: String) -> Address? {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var host: String
        var path: String
        if clean.hasPrefix("https://") || clean.hasPrefix("http://") || clean.hasPrefix("ssh://") {
            guard let components = URLComponents(string: clean), let found = components.host, !found.isEmpty else { return nil }
            host = found
            path = components.path
        } else if let at = clean.firstIndex(of: "@"), let colon = clean[at...].firstIndex(of: ":") {
            host = String(clean[clean.index(after: at)..<colon])
            path = String(clean[clean.index(after: colon)...])
        } else {
            return nil
        }
        host = host.lowercased()
        var parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "~" }
        guard parts.count >= 2, var name = parts.popLast() else { return nil }
        if name.hasSuffix(".git") { name.removeLast(4) }
        let owner = parts.joined(separator: "/")
        guard !host.isEmpty, !owner.isEmpty, !name.isEmpty,
              ([host, name] + parts).allSatisfy({ $0 != "." && $0 != ".." && !$0.hasPrefix("-") }) else { return nil }
        return Address(host: host, owner: owner, name: name)
    }

    /// Hosts whose repositories are always `owner/name`, so anything below that is a page inside the repository.
    private static let twoPartHosts: Set<String> = ["github.com", "www.github.com", "bitbucket.org", "codeberg.org", "gitea.com",
                                                    "git.cafe", "staging.git.cafe"]
    /// Page routes GitHub, Gitea, Forgejo and Bitbucket serve inside a repository (`owner/repo/tree/main`).
    private static let pageRoutes: Set<String> = ["tree", "blob", "commit", "commits", "pull", "pulls", "pull-requests", "issues",
                                                  "actions", "releases", "compare", "wiki", "src", "raw", "tags", "branches"]
    /// Routes that may end the address (`owner/repo/issues`); the others are pages only with a part after them, as
    /// `owner/repo/tree` could still be a GitLab project named "tree" in a group.
    private static let listRoutes: Set<String> = ["commits", "pulls", "pull-requests", "issues", "actions", "releases", "wiki",
                                                  "tags", "branches"]

    /// The repository a URL copied from a browser is in: `https://github.com/owner/repo/tree/main` →
    /// `https://github.com/owner/repo`. GitLab pages are cut at `/-/`; on github.com, bitbucket.org, codeberg.org and
    /// the like everything below `owner/repo` goes; on other hosts (Gitea, Forgejo) a page route right after
    /// `owner/repo` does. The query and fragment are dropped. A path ending in `.git`, an ssh:// or scp-style address, and
    /// anything else that is no page come back as typed (trimmed).
    static func repositoryURL(fromPage raw: String) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = clean.lowercased()
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://"),
              var components = URLComponents(string: clean), let host = components.host?.lowercased(), !host.isEmpty else { return clean }
        var path = components.percentEncodedPath
        let dropsExtras = components.percentEncodedQuery != nil || components.percentEncodedFragment != nil
        if !(path.hasSuffix("/") ? String(path.dropLast()) : path).hasSuffix(".git") {
            var parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if let marker = parts.firstIndex(of: "-"), marker >= 3 {
                // GitLab (also self-hosted): every page of a project is below `/-/`.
                parts = Array(parts[..<marker])
            } else if twoPartHosts.contains(host), parts.count > 3, parts[1...2].allSatisfy({ !$0.isEmpty }) {
                parts = Array(parts[...2])
            } else if parts.count > 3, parts[1...2].allSatisfy({ !$0.isEmpty }), pageRoutes.contains(parts[3]) {
                let rest = parts[4...].filter { !$0.isEmpty }
                if !rest.isEmpty || listRoutes.contains(parts[3]) { parts = Array(parts[...2]) }
            }
            path = parts.joined(separator: "/")
        }
        guard path != components.percentEncodedPath || dropsExtras else { return clean }
        components.percentEncodedPath = path
        components.percentEncodedQuery = nil
        components.percentEncodedFragment = nil
        return components.string ?? clean
    }

    /// Whether a clone may go into `path`: nothing is there yet, or an empty folder (a failed clone leaves one behind).
    /// Finder's `.DS_Store` counts as empty and is removed, since `git clone` refuses a folder that holds it.
    static func prepareCloneTarget(_ path: String, fileManager fm: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return true }
        guard isDirectory.boolValue, let names = try? fm.contentsOfDirectory(atPath: path),
              names.allSatisfy({ $0 == ".DS_Store" }) else { return false }
        for name in names { try? fm.removeItem(atPath: path + "/" + name) }
        return (try? fm.contentsOfDirectory(atPath: path))?.isEmpty == true
    }

    /// The folder a clone goes into: `<parent>/<repo>`, or with the host layout `<root>/<host>/<owner>/<repo>` (as ghq
    /// lays clones out). Nil when the host layout is asked for an address it cannot read.
    static func target(url: String, parent: String, hostLayout: Bool, folderName: String) -> String? {
        let base = URL(fileURLWithPath: parent, isDirectory: true)
        guard hostLayout else { return base.appendingPathComponent(folderName).path }
        guard let address = parse(url) else { return nil }
        var folder = base.appendingPathComponent(address.host, isDirectory: true)
        for part in address.owner.split(separator: "/") { folder.appendPathComponent(String(part), isDirectory: true) }
        return folder.appendingPathComponent(folderName).path
    }

    /// The root of a host layout a project already lives in: "/Users/me/src" for "/Users/me/src/github.com/me/app".
    /// Nil when the folder is not laid out that way (its grandparent's name is not a host).
    static func layoutRoot(of project: String) -> String? {
        let parts = URL(fileURLWithPath: project).standardizedFileURL.pathComponents
        guard parts.count >= 5 else { return nil }
        let host = parts[parts.count - 3]
        guard host.contains("."), host.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else { return nil }
        return NSString.path(withComponents: Array(parts.dropLast(3)))
    }

    /// Whether the address goes over SSH (ssh:// or `git@host:path`).
    static func isSSH(_ url: String) -> Bool {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("ssh://") { return true }
        return !clean.contains("://") && clean.contains("@") && clean.contains(":")
    }

    /// The HTTPS address of an SSH one: "git@github.com:me/app.git" → "https://github.com/me/app.git". A port in an
    /// ssh:// address is SSH's own and is dropped.
    static func httpsFallback(_ url: String) -> String? {
        guard isSSH(url), let address = parse(url) else { return nil }
        return "https://\(address.host)/\(address.owner)/\(address.name).git"
    }

    /// Whether git's error says SSH itself failed (no key, an unknown host key, no connection), so HTTPS may still work.
    static func sshRefused(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return ["permission denied (publickey", "host key verification failed", "could not read from remote repository",
                "ssh: connect to host", "connection refused", "connection timed out", "no route to host",
                "ssh: could not resolve hostname", "kex_exchange_identification", "too many authentication failures"]
            .contains(where: text.contains)
    }
}

/// Making a GitHub repository of a local project.
enum RepositoryPublish {
    /// GitHub's rule: letters, digits, '.', '-' and '_', at most 100, and not "." or "..".
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 100, name != ".", name != ".." else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    /// The name a folder suggests: "My App (2)" → "My-App-2".
    static func suggestedName(_ folder: String) -> String {
        var result = ""
        var lastDash = false
        for character in folder {
            if character.isASCII && (character.isLetter || character.isNumber || character == "." || character == "_") {
                result.append(character)
                lastDash = false
            } else if !lastDash, !result.isEmpty {
                result.append("-")
                lastDash = true
            }
        }
        while result.hasSuffix("-") || result.hasSuffix(".") { result.removeLast() }
        let name = String(result.prefix(100))
        return isValidName(name) ? name : "project"
    }

    /// The body of `POST /user/repos` (or `/orgs/{org}/repos`).
    static func requestBody(name: String, isPrivate: Bool) -> [String: Any] {
        ["name": name, "private": isPrivate, "auto_init": false]
    }

    /// The API path that makes the repository: under your own account, or an organization's.
    static func requestPath(owner: String?) -> String {
        guard let owner = owner?.trimmingCharacters(in: .whitespaces), !owner.isEmpty else { return "/user/repos" }
        return "/orgs/\(owner)/repos"
    }

    /// Only a project without any remote is published: one that has one already belongs somewhere.
    static func canPublish(isRepository: Bool, remotes: [String]) -> Bool { !isRepository || remotes.isEmpty }

    /// A credential helper that answers git with the token from `NOOK_PUBLISH_TOKEN`, so the first push never stores it.
    static let credentialHelper = #"!f() { test "$1" = get && echo username=x-access-token && echo "password=$NOOK_PUBLISH_TOKEN"; }; f"#
}

/// A commit an agent names in its answer: a GitHub commit link, or a bare hash.
enum CommitReference {
    static let scheme = "nook-commit"

    /// A hash as an agent writes it: 7 to 40 hexadecimal characters with at least one letter and one digit, so a number
    /// or a word ("deadbeef", "1234567") is not taken for one.
    static func isHash(_ text: String) -> Bool {
        guard (7...40).contains(text.count), text.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }) else { return false }
        return text.contains(where: \.isNumber) && text.contains(where: \.isLetter)
    }

    /// The link Nook makes of a hash.
    static func link(_ hash: String) -> URL? { URL(string: "\(scheme):\(hash.lowercased())") }

    /// The hash a link names: `nook-commit:<hash>`, or a commit page on GitHub (`/owner/repo/commit/<hash>`, also inside
    /// a pull request: `/pull/12/commits/<hash>`).
    static func hash(in url: URL) -> String? {
        if url.scheme == scheme {
            let text = url.absoluteString.dropFirst(scheme.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return isHash(text) ? text : nil
        }
        guard url.scheme == "https", url.host?.lowercased() == "github.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count >= 4, parts[2] == "commit", isHash(parts[3].lowercased()) { return parts[3].lowercased() }
        if parts.count >= 6, parts[2] == "pull", parts[4] == "commits", isHash(parts[5].lowercased()) { return parts[5].lowercased() }
        return nil
    }

    /// The hashes in plain text, by range: whole words only.
    static func hashes(in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start: String.Index?
        func close(_ end: String.Index) {
            if let begin = start, isHash(String(text[begin..<end])) { result.append(begin..<end) }
            start = nil
        }
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber || character == "_" || character == "/" || character == "-" {
                if start == nil { start = index }
            } else {
                close(index)
            }
            index = text.index(after: index)
        }
        close(text.endIndex)
        return result
    }
}
