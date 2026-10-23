import Foundation

/// Machines you can probably reach, offered when you add one: the aliases in
/// `~/.ssh/config`, the hosts in `~/.ssh/known_hosts`, and the online devices of your tailnet (`tailscale status --json`,
/// by their MagicDNS name). Nothing is contacted to find them; picking one only fills in the form.
enum RemoteHostDiscovery {
    enum Source: String, Sendable { case sshConfig, knownHosts, tailscale }

    struct Suggestion: Equatable, Identifiable, Sendable {
        var name: String
        var host: String
        var port: Int?
        var source: Source
        /// What else is known: "ubuntu@10.0.0.4" from the config, "macOS" from the tailnet.
        var detail: String?
        var id: String { "\(host):\(port ?? 0)" }
    }

    // MARK: ~/.ssh/config

    /// Each concrete `Host` alias (no wildcards or negations), with its `HostName` and `User` as detail. ssh reads the
    /// rest of the block itself, so the alias is all Nook needs.
    static func sshConfig(_ text: String) -> [Suggestion] {
        var result: [Suggestion] = []
        var aliases: [String] = []
        var hostName: String?
        var user: String?
        func flush() {
            let target = [user, hostName].compactMap { $0 }.joined(separator: "@")
            for alias in aliases {
                result.append(Suggestion(name: alias, host: alias, port: nil, source: .sshConfig, detail: target.isEmpty ? nil : target))
            }
            aliases = []
            hostName = nil
            user = nil
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let (key, value) = keyValue(line)
            switch key {
            case "host":
                flush()
                aliases = value.split(whereSeparator: \.isWhitespace).map(String.init).filter { !isPattern($0) && RemoteMachines.isValidHost($0) }
            case "match":
                flush()
            case "hostname":
                hostName = value
            case "user":
                user = value
            default:
                continue
            }
        }
        flush()
        return result
    }

    // MARK: ~/.ssh/known_hosts

    /// The hosts ssh has connected to before. Hashed entries (`|1|…`) cannot be read back and are skipped; `[host]:2222`
    /// keeps its port.
    static func knownHosts(_ text: String) -> [Suggestion] {
        var seen = Set<String>()
        var result: [Suggestion] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("@") { line = line.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? "" }
            guard let field = line.split(whereSeparator: \.isWhitespace).first, !field.hasPrefix("|") else { continue }
            for entry in field.split(separator: ",") {
                var host = String(entry)
                var port: Int?
                if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
                    let rest = host[host.index(after: close)...]
                    port = rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil
                    host = String(host[host.index(after: host.startIndex)..<close])
                }
                guard !isPattern(host), RemoteMachines.isValidHost(host), !forges.contains(host.lowercased()) else { continue }
                guard seen.insert("\(host):\(port ?? 22)").inserted else { continue }
                result.append(Suggestion(name: host, host: host, port: port == 22 ? nil : port, source: .knownHosts, detail: nil))
            }
        }
        return result
    }

    // MARK: Tailscale

    /// The other online devices of your tailnet, by MagicDNS name (`buildbox.tail1234.ts.net`). This Mac itself and
    /// offline devices are left out.
    static func tailscale(_ data: Data) -> [Suggestion] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let peers = object["Peer"] as? [String: Any] else { return [] }
        let suggestions: [Suggestion] = peers.values.compactMap { value in
            guard let peer = value as? [String: Any], peer["Online"] as? Bool == true else { return nil }
            var dns = (peer["DNSName"] as? String) ?? ""
            if dns.hasSuffix(".") { dns.removeLast() }
            let ip = (peer["TailscaleIPs"] as? [String])?.first
            guard let host = dns.isEmpty ? ip : dns, RemoteMachines.isValidHost(host) else { return nil }
            let name = (peer["HostName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host
            return Suggestion(name: name, host: host, port: nil, source: .tailscale, detail: peer["OS"] as? String)
        }
        return suggestions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// All suggestions without duplicates (the first source wins: the tailnet, then your config, then known hosts) and
    /// without the machines you already added.
    static func merge(tailscale: [Suggestion], sshConfig: [Suggestion], knownHosts: [Suggestion], existing: [RemoteMachine]) -> [Suggestion] {
        var taken = Set(existing.map { key($0.host, $0.port) })
        var result: [Suggestion] = []
        for suggestion in tailscale + sshConfig + knownHosts where taken.insert(key(suggestion.host, suggestion.port)).inserted {
            result.append(suggestion)
        }
        return result
    }

    private static func key(_ host: String, _ port: Int?) -> String {
        let bare = host.split(separator: "@").last.map(String.init) ?? host
        return "\(bare.lowercased()):\(port ?? 22)"
    }

    private static func keyValue(_ line: String) -> (String, String) {
        // `Key value`, `Key=value` and `Key = value` are all valid.
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "="))
        guard let split = line.rangeOfCharacter(from: separators) else { return (line.lowercased(), "") }
        let key = String(line[..<split.lowerBound]).lowercased()
        let value = String(line[split.lowerBound...]).trimmingCharacters(in: separators)
        return (key, value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
    }

    private static func isPattern(_ host: String) -> Bool {
        host.contains("*") || host.contains("?") || host.hasPrefix("!")
    }

    /// Git hosts ssh knows from pushing and pulling: never a machine to run an agent on.
    private static let forges: Set<String> = ["github.com", "gitlab.com", "bitbucket.org", "ssh.dev.azure.com", "vs-ssh.visualstudio.com",
                                              "codeberg.org", "git.sr.ht", "heroku.com", "ssh.github.com", "altssh.gitlab.com"]
}
