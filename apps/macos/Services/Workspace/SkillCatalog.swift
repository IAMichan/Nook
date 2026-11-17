import Foundation

// Skills on the internet: what a GitHub repository holds and what skills.sh finds. Everything here reads answers that
// were already fetched (`SkillFetcher` does the network), so it is tested without one. A skill is a folder with a
// SKILL.md; where that folder sits differs per repository (`skills/x`, `skills/.curated/x`, `.github/skills/x`), so the
// whole tree is searched instead of a fixed path.

/// A GitHub repository, optionally at a branch, tag or commit and narrowed to a folder.
struct SkillRepository: Equatable, Hashable, Codable, Sendable {
    var owner: String
    var name: String
    /// Branch, tag or commit; nil is the repository's default branch.
    var ref: String?
    /// Only skills in this folder (no leading or trailing slash).
    var folder: String?

    var slug: String { owner + "/" + name }

    /// "owner/repo", "owner/repo@ref", "github:owner/repo", "https://github.com/owner/repo(.git)" and
    /// "https://github.com/owner/repo/tree/<ref>/<folder>". A ref with a slash in a `tree` link cannot be told from the
    /// folder: the first part is taken as the ref, like GitHub's own short links.
    static func parse(_ text: String) -> SkillRepository? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("github:") { s.removeFirst("github:".count) }
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        var fromURL = false
        if s.hasPrefix("github.com/") { s.removeFirst("github.com/".count); fromURL = true }
        if s.hasSuffix("/") { s.removeLast() }
        var ref: String?
        if !fromURL, let at = s.lastIndex(of: "@") {
            ref = String(s[s.index(after: at)...])
            s = String(s[..<at])
        }
        var parts = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        if parts[1].hasSuffix(".git") { parts[1].removeLast(4) }
        var folder: String?
        if fromURL, parts.count >= 4, parts[2] == "tree" || parts[2] == "blob" {
            ref = parts[3]
            let rest = parts.dropFirst(4).joined(separator: "/")
            folder = rest.isEmpty ? nil : rest
            if parts[2] == "blob", folder?.hasSuffix("SKILL.md") == true {
                folder = (folder! as NSString).deletingLastPathComponent
                if folder?.isEmpty == true { folder = nil }
            }
        } else if parts.count != 2 { return nil }
        guard isName(parts[0]), isName(parts[1]) else { return nil }
        if let r = ref, r.isEmpty || r.contains("..") || r.contains(" ") { return nil }
        if let f = folder, !SkillPaths.isSafe(f) { return nil }
        return SkillRepository(owner: parts[0], name: parts[1], ref: ref, folder: folder)
    }

    /// GitHub's names: letters, digits, `-`, `_` and `.`, not only dots.
    private static func isName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 100 && s != "." && s != ".."
            && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_.".unicodeScalars.contains($0) }
    }
}

/// One answer from skills.sh's search. It names the skill and its repository, not what it does: the description comes
/// from the SKILL.md itself.
struct SkillSearchHit: Equatable, Identifiable, Sendable {
    /// "owner/repo/skill".
    var id: String
    var repository: SkillRepository
    /// The skill's id within the repository: usually its folder name, sometimes the name in its front matter.
    var skillID: String
    var name: String
    var installs: Int
}

/// A file in a skill folder as the repository's tree lists it.
struct SkillFile: Equatable, Codable, Sendable {
    /// Relative to the skill's folder.
    var path: String
    var size: Int
    /// The tree marks it executable (`100755`).
    var executable: Bool
    /// Git's blob id of its contents: an update only counts when one of these changed, not every new commit.
    var sha: String? = nil

    /// Code the agent can run: a script by its extension or a file the repository marks executable. The preview
    /// lists these apart, because they run with the agent's rights.
    var isScript: Bool {
        executable || SkillFile.scriptExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    static let scriptExtensions: Set<String> = [
        "py", "sh", "bash", "zsh", "fish", "js", "mjs", "cjs", "ts", "rb", "pl", "php", "lua", "ps1", "bat", "cmd",
        "applescript", "scpt", "swift", "go", "rs", "jar", "exe", "bin", "command", "tool",
    ]
}

/// A skill folder in a repository at one commit, before it is installed.
struct RemoteSkill: Equatable, Identifiable, Sendable {
    var id: String { repository.slug + "/" + folder }
    var repository: SkillRepository
    /// The commit the files are read at, so what was previewed is what is installed.
    var commit: String
    /// Path of the folder in the repository ("skills/pdf"); empty for a SKILL.md at the root.
    var folder: String
    var files: [SkillFile]
    /// From the front matter once SKILL.md was read; until then the folder's name.
    var name: String
    var description: String
    /// Why it cannot be installed (a link, a submodule, too big…), nil when it can.
    var refusal: SkillRefusal?

    var folderName: String { folder.isEmpty ? repository.name : (folder as NSString).lastPathComponent }
    var totalBytes: Int { files.reduce(0) { $0 + $1.size } }
    var scripts: [SkillFile] { files.filter(\.isScript) }

    /// Fills name and description from the SKILL.md text (only its head is read, like `SkillIndex`).
    mutating func describe(skillFile text: String) {
        let meta = SkillIndex.frontMatter(String(text.prefix(SkillIndex.maxFileBytes)))
        if let n = SkillIndex.clean(meta["name"]) { name = n }
        description = SkillIndex.clean(meta["description"]) ?? ""
    }
}

enum SkillRefusal: Equatable, Sendable {
    /// The folder holds a symbolic link, which could point anywhere on the disk.
    case link(String)
    /// The folder holds a git submodule: its files are in another repository.
    case submodule(String)
    /// A file name that would leave the folder or is not allowed (`..`, a `.git` folder…).
    case unsafePath(String)
    case fileTooLarge(String, Int)
    case tooLarge(Int)
    case tooManyFiles(Int)
}

enum SkillLimits {
    /// Room for the largest popular skills (taste-skill: 1,631 files, 36 MB, November 2026) and a bound on what a
    /// repository can make Nook download and write.
    static let maxSkillBytes = 64 * 1024 * 1024
    static let maxFileBytes = 16 * 1024 * 1024
    static let maxFiles = 2_000
    /// Larger than this, the preview says so before you install.
    static let largeSkillBytes = 5 * 1024 * 1024
}

enum SkillPaths {
    /// A relative path that stays inside its folder: no empty parts, no `.` or `..`, no `.git`, no backslashes or
    /// control characters, and not absolute.
    static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 512, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        for part in path.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part == "." || part == ".." || part.lowercased() == ".git" { return false }
        }
        return true
    }

    /// A name for the folder a skill is installed in: its folder name, else its name, reduced to safe characters.
    static func installName(_ skill: RemoteSkill) -> String? {
        for candidate in [skill.folderName, skill.name] {
            let cleaned = String(candidate.unicodeScalars.map {
                CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_.".unicodeScalars.contains($0) ? Character($0) : "-"
            }).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
            if !cleaned.isEmpty, cleaned.count <= 100 { return cleaned }
        }
        return nil
    }
}

enum SkillCatalog {
    enum ParseError: Error, Equatable {
        case notJSON
        /// GitHub cut the tree short (more than 100,000 entries or 7 MB): narrow the source to a folder.
        case truncated
    }

    /// skills.sh's `GET /api/search?q=…` answer: `{"skills": [{"id", "source", "skillId", "name", "installs"}]}`.
    /// Hits whose source is not a GitHub "owner/repo" are left out (skills.sh also lists other hosts).
    static func searchHits(_ data: Data) throws -> [SkillSearchHit] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.notJSON }
        let rows = root["skills"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let source = row["source"] as? String, let repository = SkillRepository.parse(source),
                  let skillID = (row["skillId"] as? String) ?? (row["name"] as? String), !skillID.isEmpty else { return nil }
            return SkillSearchHit(id: (row["id"] as? String) ?? source + "/" + skillID, repository: repository,
                                  skillID: skillID, name: (row["name"] as? String) ?? skillID,
                                  installs: (row["installs"] as? Int) ?? 0)
        }
    }

    /// The skills in GitHub's recursive tree (`GET /repos/{repo}/git/trees/{commit}?recursive=1`). A file belongs to
    /// the deepest skill folder above it, so a skill nested in another is its own skill and not part of the outer one.
    /// Only folders inside `repository.folder` count when it is set.
    static func skills(inTree data: Data, repository: SkillRepository, commit: String) throws -> [RemoteSkill] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["tree"] as? [[String: Any]] else { throw ParseError.notJSON }
        if root["truncated"] as? Bool == true { throw ParseError.truncated }
        func inScope(_ folder: String) -> Bool {
            guard let scope = repository.folder else { return true }
            return folder == scope || folder.hasPrefix(scope + "/")
        }

        let folders = entries.compactMap { entry -> String? in
            guard entry["type"] as? String == "blob", let path = entry["path"] as? String else { return nil }
            guard (path as NSString).lastPathComponent == "SKILL.md" else { return nil }
            let folder = (path as NSString).deletingLastPathComponent
            return inScope(folder) ? folder : nil
        }
        guard !folders.isEmpty else { return [] }
        // Deepest first, so a file is claimed by the closest skill folder above it.
        let byDepth = folders.sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
        func owner(of path: String) -> String? {
            byDepth.first { $0.isEmpty || path.hasPrefix($0 + "/") }
        }

        var files: [String: [SkillFile]] = [:]
        var refusals: [String: SkillRefusal] = [:]
        for entry in entries {
            guard let path = entry["path"] as? String, let folder = owner(of: path) else { continue }
            let relative = folder.isEmpty ? path : String(path.dropFirst(folder.count + 1))
            let type = entry["type"] as? String, mode = entry["mode"] as? String
            if type == "tree" { continue }
            if type == "commit" || mode == "160000" { refusals[folder] = refusals[folder] ?? .submodule(relative); continue }
            if mode == "120000" { refusals[folder] = refusals[folder] ?? .link(relative); continue }
            guard type == "blob" else { continue }
            if !SkillPaths.isSafe(relative) { refusals[folder] = refusals[folder] ?? .unsafePath(relative); continue }
            files[folder, default: []].append(SkillFile(path: relative, size: entry["size"] as? Int ?? 0, executable: mode == "100755",
                                                         sha: entry["sha"] as? String))
        }

        return folders.sorted().map { folder in
            let list = (files[folder] ?? []).sorted { $0.path < $1.path }
            var skill = RemoteSkill(repository: repository, commit: commit, folder: folder, files: list, name: "", description: "",
                                    refusal: refusals[folder])
            skill.name = skill.folderName
            if skill.refusal == nil { skill.refusal = limitRefusal(list) }
            return skill
        }
    }

    static func limitRefusal(_ files: [SkillFile]) -> SkillRefusal? {
        if files.count > SkillLimits.maxFiles { return .tooManyFiles(files.count) }
        if let big = files.first(where: { $0.size > SkillLimits.maxFileBytes }) { return .fileTooLarge(big.path, big.size) }
        let total = files.reduce(0) { $0 + $1.size }
        return total > SkillLimits.maxSkillBytes ? .tooLarge(total) : nil
    }

    /// The skill a search hit means: the folder named like its id, else the one whose front matter has that name.
    /// Folder names are checked first because they are known without reading any SKILL.md.
    static func match(_ hit: SkillSearchHit, in skills: [RemoteSkill]) -> RemoteSkill? {
        let id = hit.skillID.lowercased()
        return skills.first { $0.folderName.lowercased() == id }
            ?? skills.first { $0.name.lowercased() == id || $0.name.lowercased() == hit.name.lowercased() }
    }

    /// The commit sha in `GET /repos/{repo}/commits/{ref}`.
    static func commitSHA(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = root["sha"] as? String, sha.count == 40, sha.allSatisfy(\.isHexDigit) else { return nil }
        return sha.lowercased()
    }
}
