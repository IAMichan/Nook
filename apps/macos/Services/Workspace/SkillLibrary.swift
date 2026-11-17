import Foundation

// What Settings › Coding agents › Skills shows: the skills Nook installed, grouped over every agent folder they are in,
// whether a newer version changed them, and the repositories you browse. Foundation only, so it is tested without a UI.

/// One skill Nook installed, wherever it is: the same name from the same source in several agents' folders is one entry.
struct SkillLibraryEntry: Equatable, Identifiable, Sendable {
    struct Place: Equatable, Sendable {
        var url: URL
        /// The agents that read this folder.
        var providers: [RunProvider]
        var provenance: SkillProvenance
    }

    var id: String { scopeKey + "|" + name + "|" + source }
    var name: String
    var scope: SkillScope
    /// "owner/repo/folder".
    var source: String { places[0].provenance.repository + (places[0].provenance.folder.isEmpty ? "" : "/" + places[0].provenance.folder) }
    var repository: String { places[0].provenance.repository }
    var places: [Place]

    var providers: [RunProvider] {
        var seen = Set<RunProvider>()
        return places.flatMap(\.providers).filter { seen.insert($0).inserted }
    }

    var commit: String { places[0].provenance.commit }
    var scripts: [String] { places[0].provenance.scripts }

    private var scopeKey: String {
        switch scope {
        case .user: return "user"
        case .project(let url): return url.path
        }
    }
}

/// What changed in a skill between the copy installed and the repository now.
struct SkillChange: Equatable, Sendable {
    var added: [String]
    var removed: [String]
    var changed: [String]
    /// Scripts that are new or changed: worth a look before updating.
    var scripts: [String]

    var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }
    var count: Int { added.count + removed.count + changed.count }
}

enum SkillLibrary {
    /// Every skill Nook installed in the folders of `providers` for one scope, grouped by name and source. Agents that
    /// share a folder share its copies.
    static func entries(scope: SkillScope, providers: [RunProvider] = RunProvider.allCases, home: URL,
                        fileManager: FileManager = .default) -> [SkillLibraryEntry] {
        var byRoot: [(URL, [RunProvider])] = []
        for provider in providers {
            guard let root = SkillPlaces.root(for: provider, scope: scope, home: home)?.standardizedFileURL else { continue }
            if let i = byRoot.firstIndex(where: { $0.0 == root }) { byRoot[i].1.append(provider) } else { byRoot.append((root, [provider])) }
        }
        var groups: [String: SkillLibraryEntry] = [:]
        var order: [String] = []
        for (root, readers) in byRoot {
            for skill in SkillInstaller.installed(in: root, fileManager: fileManager) {
                let key = skill.name.lowercased() + "|" + skill.provenance.repository.lowercased() + "|" + skill.provenance.folder
                let place = SkillLibraryEntry.Place(url: skill.url, providers: readers, provenance: skill.provenance)
                if groups[key] == nil {
                    groups[key] = SkillLibraryEntry(name: skill.name, scope: scope, places: [place])
                    order.append(key)
                } else {
                    groups[key]?.places.append(place)
                }
            }
        }
        return order.compactMap { groups[$0] }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// What differs between what was installed and the skill in the repository now; nil when Nook cannot tell (a copy
    /// from before Nook kept file ids), in which case a newer commit is all it knows.
    static func change(from installed: SkillProvenance, to remote: RemoteSkill) -> SkillChange? {
        guard let old = installed.hashes else { return nil }
        let new = Dictionary(remote.files.compactMap { file in file.sha.map { (file.path, $0) } }, uniquingKeysWith: { a, _ in a })
        guard new.count == remote.files.count else { return nil }
        let added = new.keys.filter { old[$0] == nil }.sorted()
        let removed = old.keys.filter { new[$0] == nil }.sorted()
        let changed = new.keys.filter { old[$0] != nil && old[$0] != new[$0] }.sorted()
        let scriptPaths = Set(remote.scripts.map(\.path))
        return SkillChange(added: added, removed: removed, changed: changed,
                           scripts: (added + changed).filter { scriptPaths.contains($0) }.sorted())
    }
}

/// The repositories the Skills page offers to browse: two well-known collections, the ones you added, and the GitHub
/// marketplaces Claude Code already knows on this Mac.
enum SkillSources {
    static let defaults = ["anthropics/skills", "openai/skills"]

    /// GitHub repositories in Claude Code's `~/.claude/plugins/known_marketplaces.json`
    /// (`{"name": {"source": {"source": "github", "repo": "owner/repo"}}}`); other kinds (a URL, a folder) are left out.
    static func claudeMarketplaces(_ data: Data?) -> [String] {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return root.keys.sorted().compactMap { key in
            guard let entry = root[key] as? [String: Any], let source = entry["source"] as? [String: Any],
                  source["source"] as? String == "github", let repo = source["repo"] as? String,
                  let parsed = SkillRepository.parse(repo) else { return nil }
            return parsed.slug
        }
    }

    static func claudeMarketplaces(home: URL) -> [String] {
        claudeMarketplaces(FileManager.default.contents(atPath: home.appendingPathComponent(".claude/plugins/known_marketplaces.json").path))
    }

    /// Defaults, then yours, then Claude Code's, each once (case-insensitive), in that order.
    static func all(added: [String], claude: [String]) -> [SkillRepository] {
        var seen = Set<String>()
        return (defaults + added + claude).compactMap(SkillRepository.parse).filter {
            seen.insert(($0.slug + "@" + ($0.ref ?? "") + "/" + ($0.folder ?? "")).lowercased()).inserted
        }
    }

    /// What is stored for a repository you add: "owner/repo", with "@ref" and the folder when given.
    static func stored(_ repository: SkillRepository) -> String {
        guard repository.ref != nil || repository.folder != nil else { return repository.slug }
        return "https://github.com/\(repository.slug)/tree/\(repository.ref ?? "HEAD")" + (repository.folder.map { "/" + $0 } ?? "")
    }
}
