import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Agents beyond the ones Nook knows by name: any agent that speaks ACP (Agent Client
// Protocol), picked from the ACP registry or entered by hand. Each runs as an account of the ACP kind ("ACP · Kiro"),
// so sessions, accounts and the model menu work as for every other agent. The agent starts through your login shell,
// so npx, uvx and tools from nvm or asdf are found exactly as in your terminal. Foundation only, so tests can use it.

/// One ACP agent you added.
struct CustomAgent: Codable, Equatable, Identifiable, Sendable {
    /// The account it runs as ("acp-kiro").
    var profileID: String
    var name: String
    /// Where it came from: its id and version in the ACP registry, nil when you entered it yourself.
    var registryID: String? = nil
    var version: String? = nil
    /// The program and its arguments ("npx", ["-y", "@kiro/acp@1.2.3"]).
    var command: String
    var arguments: [String] = []
    var environment: [String: String] = [:]
    /// The folder Nook downloaded the agent into (a registry download); removed with the agent.
    var installedAt: String? = nil

    var id: String { profileID }

    /// What the login shell runs: `exec` and every part quoted, so nothing in a name or argument is read as shell.
    var shellLine: String {
        "exec " + ([command] + arguments).map(CustomAgents.quote).joined(separator: " ")
    }
}

enum CustomAgents {
    static let defaultsKey = "agents.customAcp"

    static func load(defaults: UserDefaults = .standard) -> [CustomAgent] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([CustomAgent].self, from: data)) ?? []
    }

    static func save(_ agents: [CustomAgent], defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(agents), forKey: defaultsKey)
    }

    static func agent(for profileID: String, defaults: UserDefaults = .standard) -> CustomAgent? {
        load(defaults: defaults).first { $0.profileID == profileID }
    }

    /// Adds or replaces the agent of this account.
    static func upsert(_ agent: CustomAgent, defaults: UserDefaults = .standard) {
        var agents = load(defaults: defaults).filter { $0.profileID != agent.profileID }
        agents.append(agent)
        save(agents, defaults: defaults)
    }

    static func remove(profileID: String, defaults: UserDefaults = .standard) {
        save(load(defaults: defaults).filter { $0.profileID != profileID }, defaults: defaults)
    }

    /// A command you type ("npx -y @kiro/acp@1.2.3 --acp"): split like a shell would, with quotes. Nil when empty or
    /// when a quote is left open.
    static func parseCommand(_ line: String) -> (command: String, arguments: [String])? {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        var escaped = false
        for character in line {
            if escaped { current.append(character); escaped = false; hasToken = true; continue }
            if character == "\\" && quote != "'" { escaped = true; continue }
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" { quote = character; hasToken = true; continue }
            if character.isWhitespace {
                if hasToken { parts.append(current); current = ""; hasToken = false }
                continue
            }
            current.append(character)
            hasToken = true
        }
        guard quote == nil, !escaped else { return nil }
        if hasToken { parts.append(current) }
        guard let first = parts.first, !first.isEmpty else { return nil }
        return (first, Array(parts.dropFirst()))
    }

    /// Single quotes around anything that is not plainly safe, as the shell needs it.
    static func quote(_ part: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_"))
        if !part.isEmpty, part.unicodeScalars.allSatisfy({ safe.contains($0) }) { return part }
        return "'" + part.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The ACP registry (agentclientprotocol.com): the agents that speak ACP, with how to start each one: npx and uvx at an
/// exact version, or a download for this Mac that Nook installs after checking its SHA-256.
enum AcpRegistry {
    static let url = URL(string: "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json")!
    static let maxBytes = 1024 * 1024

    struct Entry: Equatable, Identifiable, Sendable {
        var id: String
        var name: String
        var version: String
        var description: String
        var website: String?
        /// How Nook starts it; nil when the registry only offers a download.
        var command: String?
        var arguments: [String]
        var environment: [String: String]
        /// The download for this Mac, when there is no npx or uvx way to start it.
        var binary: Binary? = nil

        var isSupported: Bool { command != nil || binary != nil }
    }

    /// A program to download: an archive (or the program itself), its checksum, and what to run from it.
    struct Binary: Equatable, Sendable {
        var archive: URL
        var sha256: String
        /// Relative to the unpacked folder ("./bin/agent").
        var command: String
        var arguments: [String]
        var environment: [String: String]

        enum Kind: Equatable, Sendable { case zip, tar, raw }

        var kind: Kind {
            let name = archive.lastPathComponent.lowercased()
            if name.hasSuffix(".zip") { return .zip }
            if [".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".tar"].contains(where: name.hasSuffix) { return .tar }
            return .raw
        }
    }

    /// The registry's name for this Mac's platform.
    static var platform: String {
        #if arch(arm64)
        return "darwin-aarch64"
        #else
        return "darwin-x86_64"
        #endif
    }

    /// A path inside the unpacked folder: relative, without "..", never a way out.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 512, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\0") else { return false }
        return !path.split(separator: "/").contains("..")
    }

    private static let runnerVersion = #"v?[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?"#
    private static let npxPackage = try! NSRegularExpression(
        pattern: #"^(?:@[^/@\s]+/[^@\s]+|[a-z0-9][a-z0-9._-]*)@"# + runnerVersion + "$", options: [.caseInsensitive])
    private static let uvxPackage = try! NSRegularExpression(
        pattern: #"^[a-z0-9][a-z0-9._-]*(?:@|==)"# + runnerVersion + "$", options: [.caseInsensitive])
    private static let agentID = try! NSRegularExpression(pattern: #"^[a-z0-9][a-z0-9._-]{0,127}$"#)

    static func parse(_ data: Data) -> [Entry] {
        guard data.count <= maxBytes,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let agents = object["agents"] as? [Any] else { return [] }
        return agents.prefix(512).compactMap { entry($0 as? [String: Any]) }
    }

    static func entry(_ raw: [String: Any]?) -> Entry? {
        guard let raw, let id = raw["id"] as? String, matches(agentID, id),
              let name = (raw["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= 160,
              let version = (raw["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty,
              let distribution = raw["distribution"] as? [String: Any] else { return nil }
        let website = (raw["website"] as? String).flatMap { isHTTPS($0) ? $0 : nil }
        var result = Entry(id: id, name: name, version: version, description: String(((raw["description"] as? String) ?? "").prefix(1024)),
                           website: website, command: nil, arguments: [], environment: [:])
        // npx first, then uvx: both start without Nook downloading a program.
        if let npx = distribution["npx"] as? [String: Any], let package = npx["package"] as? String, matches(npxPackage, package) {
            result.command = "npx"
            result.arguments = ["-y", package] + strings(npx["args"])
            result.environment = environment(npx["env"])
        } else if let uvx = distribution["uvx"] as? [String: Any], let package = uvx["package"] as? String, matches(uvxPackage, package) {
            result.command = "uvx"
            result.arguments = [package] + strings(uvx["args"])
            result.environment = environment(uvx["env"])
        } else if let binaries = distribution["binary"] as? [String: Any] {
            result.binary = binary(binaries[platform] as? [String: Any])
        }
        return result
    }

    /// A download Nook accepts: over HTTPS, with a SHA-256 to check it against, and a program inside the folder.
    static func binary(_ raw: [String: Any]?) -> Binary? {
        guard let raw, let text = raw["archive"] as? String, isHTTPS(text), let archive = URL(string: text),
              let sha = (raw["sha256"] as? String)?.lowercased(), sha.count == 64, sha.allSatisfy(\.isHexDigit),
              let command = raw["cmd"] as? String, isSafeRelativePath(command) else { return nil }
        return Binary(archive: archive, sha256: sha, command: command, arguments: strings(raw["args"]), environment: environment(raw["env"]))
    }

    /// The installed download as an agent of this account: its program in `folder`.
    static func agent(from entry: Entry, installedIn folder: String, profileID: String) -> CustomAgent? {
        guard let binary = entry.binary else { return nil }
        var relative = binary.command
        while relative.hasPrefix("./") { relative.removeFirst(2) }
        let program = (folder as NSString).appendingPathComponent(relative)
        return CustomAgent(profileID: profileID, name: entry.name, registryID: entry.id, version: entry.version, command: program,
                           arguments: binary.arguments, environment: binary.environment, installedAt: folder)
    }

    /// The registry entry as an agent of this account. Nil when Nook cannot start it.
    static func agent(from entry: Entry, profileID: String) -> CustomAgent? {
        guard let command = entry.command else { return nil }
        return CustomAgent(profileID: profileID, name: entry.name, registryID: entry.id, version: entry.version,
                           command: command, arguments: entry.arguments, environment: entry.environment)
    }

    /// The registry, fetched (at most 1 MB).
    static func fetch(session: URLSession = .shared) async throws -> [Entry] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return parse(data)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func isHTTPS(_ text: String) -> Bool {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else { return false }
        return url.user == nil && url.password == nil
    }

    private static func strings(_ value: Any?) -> [String] {
        ((value as? [Any]) ?? []).prefix(64).compactMap { ($0 as? String).flatMap { $0.count <= 1024 ? $0 : nil } }
    }

    private static func environment(_ value: Any?) -> [String: String] {
        var result: [String: String] = [:]
        for (key, raw) in (value as? [String: Any]) ?? [:] {
            guard let text = raw as? String, key.count <= 256, text.count <= 1024,
                  key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { continue }
            result[key] = text
        }
        return result
    }
}
