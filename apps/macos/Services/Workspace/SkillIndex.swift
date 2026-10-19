import Foundation

// The `$` list of the composer: skills found on disk for the active provider. Only the front
// matter of each file is read (bounded), never the body, so a huge or hostile SKILL.md cannot cost memory or leak into the UI.

struct Skill: Equatable, Sendable, Identifiable {
    var id: String { name }
    var name: String
    var description: String
    var path: String
    /// Short label of the root it came from, e.g. ".claude/skills".
    var source: String
}

enum SkillIndex {
    static let maxFileBytes = 64 * 1024

    /// `<project>` roots come first: the first root that defines a name wins, so a project skill beats a user one.
    static func defaultRoots(home: URL, project: URL?) -> [URL] {
        var roots: [URL] = []
        if let project {
            roots.append(project.appendingPathComponent(".claude/skills", isDirectory: true))
            roots.append(project.appendingPathComponent(".agents/skills", isDirectory: true))
        }
        roots.append(home.appendingPathComponent(".claude/skills", isDirectory: true))
        roots.append(home.appendingPathComponent(".agents/skills", isDirectory: true))
        roots.append(home.appendingPathComponent(".codex/skills", isDirectory: true))
        return roots
    }

    static func scan(roots: [URL], fileManager: FileManager = .default) -> [Skill] {
        var seen = Set<String>()
        var result: [Skill] = []
        for root in roots {
            let label = root.deletingLastPathComponent().lastPathComponent + "/" + root.lastPathComponent
            guard let entries = try? fileManager.contentsOfDirectory(atPath: root.path) else { continue }
            for entry in entries.sorted() where !entry.hasPrefix(".") {
                let url = root.appendingPathComponent(entry)
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                let file: URL
                let fallback: String
                if isDir.boolValue {
                    file = url.appendingPathComponent("SKILL.md")
                    fallback = entry
                } else if entry.lowercased().hasSuffix(".md"), entry.uppercased() != "README.MD" {
                    file = url
                    fallback = String(entry.dropLast(3))
                } else { continue }
                guard let head = readHead(file, fileManager: fileManager) else { continue }
                let meta = frontMatter(head)
                let name = clean(meta["name"]) ?? fallback
                guard seen.insert(name.lowercased()).inserted else { continue }
                result.append(Skill(name: name, description: clean(meta["description"]) ?? "", path: file.path, source: label))
            }
        }
        return result.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Prefix on the name, then contains in the name, then a hit in the description.
    static func filter(_ skills: [Skill], query: String, limit: Int = 8) -> [Skill] {
        var q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.hasPrefix("$") { q.removeFirst() }
        guard !q.isEmpty else { return Array(skills.prefix(limit)) }
        let names = skills.map { $0.name.lowercased() }
        var prefix: [Skill] = [], contains: [Skill] = [], desc: [Skill] = []
        for (i, s) in skills.enumerated() {
            if names[i].hasPrefix(q) { prefix.append(s) }
            else if names[i].contains(q) { contains.append(s) }
            else if s.description.lowercased().contains(q) { desc.append(s) }
        }
        return Array((prefix + contains + desc).prefix(limit))
    }

    private static func readHead(_ url: URL, fileManager: FileManager) -> String? {
        guard fileManager.isReadableFile(atPath: url.path), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileBytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Flat `key: value` pairs between the first two `---` lines. Indented lines continue the previous value (folded
    /// `>` and literal `|` blocks too). Without a closing line the file has no usable front matter.
    static func frontMatter(_ text: String) -> [String: String] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:]
        var key: String?
        var closed = false
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { closed = true; break }
            if let k = key, line.first == " " || line.first == "\t" {
                let part = line.trimmingCharacters(in: .whitespaces)
                if !part.isEmpty { out[k] = out[k].map { $0.isEmpty ? part : $0 + " " + part } ?? part }
                continue
            }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("#") else { key = nil; continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-", ">+", "|+"].contains(v) { v = "" }
            key = k
            out[k] = v
        }
        return closed ? out : [:]
    }

    private static func clean(_ value: String?) -> String? {
        guard var v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        if v.count >= 2, let f = v.first, f == v.last, f == "\"" || f == "'" { v = String(v.dropFirst().dropLast()) }
        v = v.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }
}
