import Foundation

// Puts a skill from the internet into the folder an agent reads, and takes it out again. Nook never runs anything from
// a skill and never marks a file executable: the agent decides what to run, under its own permissions. What Nook
// installed carries a `.nook-source.json` (where it came from, at which commit), so Nook only ever updates or removes
// skills it installed itself; a skill the user put there by hand is never touched.

/// For yourself (every project) or for one project.
enum SkillScope: Equatable, Hashable, Sendable {
    case user
    case project(URL)
}

enum SkillPlaces {
    /// The skills folder an agent reads, from each agent's own documentation (November 2026). Nil when the agent has
    /// no folder Nook knows: an ACP agent you added keeps its own setup.
    static func root(for provider: RunProvider, scope: SkillScope, home: URL) -> URL? {
        let parts: (user: String, project: String)?
        switch provider {
        case .claude: parts = (".claude/skills", ".claude/skills")
        // `~/.codex/skills` is the older place; current Codex reads the shared `.agents/skills`.
        case .codex: parts = (".agents/skills", ".agents/skills")
        case .gemini: parts = (".gemini/skills", ".gemini/skills")
        case .antigravity: parts = (".gemini/config/skills", ".agents/skills")
        case .opencode: parts = (".config/opencode/skills", ".opencode/skills")
        case .cursor: parts = (".cursor/skills", ".cursor/skills")
        // Grok Build also reads Claude Code's skills; it documents no project folder of its own.
        case .grok: parts = (".grok/skills", ".claude/skills")
        case .pi: parts = (".pi/agent/skills", ".pi/skills")
        case .acp: parts = nil
        }
        guard let parts else { return nil }
        switch scope {
        case .user: return home.appendingPathComponent(parts.user, isDirectory: true)
        case .project(let folder): return folder.appendingPathComponent(parts.project, isDirectory: true)
        }
    }

    /// The folders for several agents, each once: agents that read the same folder share one copy.
    static func roots(for providers: [RunProvider], scope: SkillScope, home: URL) -> [URL] {
        var seen = Set<String>()
        return providers.compactMap { root(for: $0, scope: scope, home: home) }.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

/// Where an installed skill came from, written next to its SKILL.md as `.nook-source.json`.
struct SkillProvenance: Equatable, Codable, Sendable {
    static let fileName = ".nook-source.json"

    /// "owner/repo".
    var repository: String
    /// The ref the user asked for (a branch or tag), nil for the default branch: what an update follows.
    var ref: String?
    /// Path of the skill's folder in the repository.
    var folder: String
    var commit: String
    var installedAt: Date
    var files: Int
    var scripts: [String]
    /// Each file's git blob id at install, so an update shows only when the skill itself changed.
    var hashes: [String: String]? = nil

    func sameSource(as skill: RemoteSkill) -> Bool {
        repository.lowercased() == skill.repository.slug.lowercased() && folder == skill.folder
    }
}

/// A skill Nook installed, found in an agent's folder.
struct InstalledSkill: Equatable, Identifiable, Sendable {
    var id: String { url.path }
    var name: String
    var url: URL
    var provenance: SkillProvenance
}

enum SkillInstaller {
    enum InstallError: Error, Equatable {
        case refused(SkillRefusal)
        case noName
        /// A file the tree lists did not arrive.
        case missingFile(String)
        /// A file arrived with another size than the tree says: not what was previewed.
        case sizeMismatch(String)
        /// A skill with this name is already there and Nook did not install it.
        case notFromNook(String)
        /// A skill with this name is there from another repository or folder; `replace` overrules this.
        case otherSource(String, SkillProvenance)
        case write(String)
    }

    /// Writes the skill's files into `root/<name>/`. The files are written into a hidden folder next to it first
    /// (`SkillIndex` skips names that start with a dot) and moved in at once, so an agent never sees half a skill.
    /// The same skill from the same source is replaced (an update); one from elsewhere only with `replace`.
    @discardableResult
    static func install(_ skill: RemoteSkill, files: [String: Data], into root: URL, replace: Bool = false,
                        now: Date = Date(), fileManager: FileManager = .default) throws -> URL {
        if let refusal = skill.refusal ?? SkillCatalog.limitRefusal(skill.files) { throw InstallError.refused(refusal) }
        guard let name = SkillPaths.installName(skill) else { throw InstallError.noName }
        for file in skill.files {
            guard SkillPaths.isSafe(file.path) else { throw InstallError.refused(.unsafePath(file.path)) }
            guard let data = files[file.path] else { throw InstallError.missingFile(file.path) }
            guard data.count == file.size else { throw InstallError.sizeMismatch(file.path) }
        }
        guard skill.files.contains(where: { $0.path == "SKILL.md" }) else { throw InstallError.missingFile("SKILL.md") }

        let destination = root.appendingPathComponent(name, isDirectory: true)
        var existing = false
        if fileManager.fileExists(atPath: destination.path) || isLink(destination, fileManager) {
            guard let current = provenance(at: destination, fileManager: fileManager) else { throw InstallError.notFromNook(name) }
            if !current.sameSource(as: skill) && !replace { throw InstallError.otherSource(name, current) }
            existing = true
        }

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch { throw InstallError.write(root.path) }
        let staging = root.appendingPathComponent(".nook-install-" + UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            for file in skill.files {
                let target = staging.appendingPathComponent(file.path)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                // 0644: nothing from the internet becomes executable through Nook.
                guard fileManager.createFile(atPath: target.path, contents: files[file.path], attributes: [.posixPermissions: 0o644]) else {
                    throw InstallError.write(file.path)
                }
            }
            let record = SkillProvenance(repository: skill.repository.slug, ref: skill.repository.ref, folder: skill.folder,
                                         commit: skill.commit, installedAt: now, files: skill.files.count,
                                         scripts: skill.scripts.map(\.path),
                                         hashes: hashes(skill.files))
            try encoder.encode(record).write(to: staging.appendingPathComponent(SkillProvenance.fileName), options: .atomic)
        } catch let error as InstallError { throw error } catch { throw InstallError.write(staging.path) }

        if existing {
            // The old copy steps aside under a hidden name and comes back if the new one cannot move in.
            let old = root.appendingPathComponent(".nook-old-" + UUID().uuidString, isDirectory: true)
            do { try fileManager.moveItem(at: destination, to: old) } catch { throw InstallError.write(destination.path) }
            do {
                try fileManager.moveItem(at: staging, to: destination)
            } catch {
                try? fileManager.moveItem(at: old, to: destination)
                throw InstallError.write(destination.path)
            }
            try? fileManager.removeItem(at: old)
        } else {
            do { try fileManager.moveItem(at: staging, to: destination) } catch { throw InstallError.write(destination.path) }
        }
        return destination
    }

    private static func hashes(_ files: [SkillFile]) -> [String: String]? {
        let pairs = files.compactMap { file in file.sha.map { (file.path, $0) } }
        return pairs.count == files.count && !files.isEmpty ? Dictionary(uniqueKeysWithValues: pairs) : nil
    }

    /// The skills in `root` that Nook installed.
    static func installed(in root: URL, fileManager: FileManager = .default) -> [InstalledSkill] {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        return entries.sorted().compactMap { entry in
            guard !entry.hasPrefix(".") else { return nil }
            let url = root.appendingPathComponent(entry, isDirectory: true)
            guard let record = provenance(at: url, fileManager: fileManager) else { return nil }
            return InstalledSkill(name: entry, url: url, provenance: record)
        }
    }

    enum RemoveError: Error, Equatable {
        case notFromNook(String)
        case write(String)
    }

    /// Removes a skill Nook installed. A folder without Nook's record is the user's own and stays.
    static func remove(_ name: String, from root: URL, fileManager: FileManager = .default) throws {
        guard SkillPaths.isSafe(name), !name.contains("/") else { throw RemoveError.notFromNook(name) }
        let url = root.appendingPathComponent(name, isDirectory: true)
        guard !isLink(url, fileManager), provenance(at: url, fileManager: fileManager) != nil else { throw RemoveError.notFromNook(name) }
        do { try fileManager.removeItem(at: url) } catch { throw RemoveError.write(url.path) }
    }

    /// Nook's record in a skill folder; nil for a folder Nook did not install (or a link to one somewhere else).
    static func provenance(at folder: URL, fileManager: FileManager = .default) -> SkillProvenance? {
        guard !isLink(folder, fileManager) else { return nil }
        let file = folder.appendingPathComponent(SkillProvenance.fileName)
        guard !isLink(file, fileManager), let data = fileManager.contents(atPath: file.path), data.count < 64 * 1024 else { return nil }
        return try? decoder.decode(SkillProvenance.self, from: data)
    }

    private static func isLink(_ url: URL, _ fileManager: FileManager) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
